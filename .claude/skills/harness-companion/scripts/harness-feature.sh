#!/bin/bash
# harness-feature.sh — feature_list.json management with explicit state machine
#
# Usage:
#   bash harness-feature.sh list                          # List all features
#   bash harness-feature.sh add <id> <title>              # Add a new feature
#   bash harness-feature.sh status <id> <new_status>      # Update feature status
#
# Sub-commands for status:
#   --override "<reason>"   Move a feature into 'unverified' with an audit record
#                           Requires HARNESS_OPERATOR (default: whoami).
#                           Only works for transitions INTO unverified.
#
# Allowed transitions:
#   not_started   → in_progress | blocked
#   in_progress   → passing | blocked | not_started
#   blocked       → in_progress | not_started
#   passing       → in_progress     (only when re-verification fails; not via this script)
#   unverified    → in_progress | blocked | passing
#   deprecated    → (terminal)
#
# Rules:
#   - WIP limit defaults to 1, configurable via .harness/config.json (feature_list.wip_limit)
#   - Marking 'passing' requires non-empty evidence unless --override is provided.
#   - Marking 'unverified' requires --override "<reason>"; records {by, at, reason}.
#   - 'unverified' is the only status that bypasses the passing-needs-evidence rule,
#     and it is counted separately by the auditor.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib/atomic_write.sh
source "$SKILL_DIR/_lib/atomic_write.sh"
# shellcheck source=_lib/harness_config.sh
source "$SKILL_DIR/_lib/harness_config.sh"

COMMAND="${1:-list}"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required for /harness:feature." >&2
  echo "Install: winget install jqlang.jq | brew install jq | apt-get install jq" >&2
  exit 2
fi

# --- list --------------------------------------------------------------------
list_features() {
  local dir="${1:-.}"
  cd "$dir" || return 1
  local fl="feature_list.json"
  if [ ! -f "$fl" ]; then
    echo "Error: feature_list.json not found in $(pwd)" >&2
    return 1
  fi
  if ! jq . "$fl" >/dev/null 2>&1; then
    echo "Error: $fl is not valid JSON." >&2
    return 1
  fi

  local total passing in_progress blocked not_started unverified deprecated
  total="$(jq '.features | length' "$fl")"
  passing="$(jq '[.features[] | select(.status=="passing")] | length' "$fl")"
  in_progress="$(jq '[.features[] | select(.status=="in_progress")] | length' "$fl")"
  blocked="$(jq '[.features[] | select(.status=="blocked")] | length' "$fl")"
  not_started="$(jq '[.features[] | select(.status=="not_started")] | length' "$fl")"
  unverified="$(jq '[.features[] | select(.status=="unverified")] | length' "$fl")"
  deprecated="$(jq '[.features[] | select(.status=="deprecated")] | length' "$fl")"

  echo "Features in $(basename "$PWD"):"
  echo ""
  if [ "$total" = "0" ]; then
    echo "  (no features defined)"
    echo ""
    echo "Add one with: /harness:feature add <id> <title>"
    return 0
  fi
  printf "  %-4s %-22s %-13s %s\n" "Pri" "ID" "Status" "Title"
  printf "  %-4s %-22s %-13s %s\n" "---" "----------------------" "-------------" "-----"
  while IFS=$'\t' read -r pri id status title; do
    local sym="⬜"
    case "$status" in
      passing) sym="✅" ;;
      in_progress) sym="🔄" ;;
      blocked) sym="🚫" ;;
      unverified) sym="⚠️ " ;;
      deprecated) sym="💀" ;;
    esac
    printf "  %-4s %-22s %-13s %s %s\n" "$pri" "$id" "$status" "$sym" "$title"
  done < <(jq -r '.features[] | [.priority // "-", .id, .status, .title] | @tsv' "$fl")

  echo ""
  echo "  $passing passing | $in_progress in_progress | $unverified unverified | $not_started not_started | $blocked blocked | $deprecated deprecated"
}

# --- add ---------------------------------------------------------------------
add_feature() {
  local dir="${1:-.}"
  shift
  local id="${1:?usage: harness-feature.sh add <id> <title>}"
  local title="${2:?usage: harness-feature.sh add <id> <title>}"
  local area="${3:-general}"
  local priority="${4:-99}"
  cd "$dir" || return 1
  local fl="feature_list.json"
  if [ ! -f "$fl" ]; then
    echo "Error: feature_list.json not found in $(pwd)" >&2
    return 1
  fi
  if jq -e --arg id "$id" '.features[] | select(.id == $id)' "$fl" >/dev/null 2>&1; then
    echo "Error: feature '$id' already exists." >&2
    return 1
  fi
  local today
  today="$(date +%Y-%m-%d)"
  local tmp
  tmp="$(mktemp "${fl}.tmp.XXXXXX")"
  jq --arg id "$id" --arg title "$title" --arg area "$area" \
     --argjson priority "$priority" --arg today "$today" \
     '.features += [{
        id: $id, priority: $priority, area: $area, title: $title,
        user_visible_behavior: "", status: "not_started",
        verification: [], evidence: [], notes: ""
      }]
      | .last_updated = $today' \
     "$fl" > "$tmp" && mv -f "$tmp" "$fl"
  echo "Feature '$id' added: $title (status: not_started)"
  echo "Don't forget to fill in user_visible_behavior and verification steps."
}

# --- status update -----------------------------------------------------------
# Transitions table. Echoes 0 if allowed, 1 if not.
is_allowed_transition() {
  local from="$1" to="$2"
  case "$from:$to" in
    not_started:in_progress|not_started:blocked|not_started:deprecated|\
    in_progress:passing|in_progress:blocked|in_progress:not_started|in_progress:deprecated|\
    blocked:in_progress|blocked:not_started|blocked:deprecated|\
    unverified:in_progress|unverified:blocked|unverified:passing|unverified:deprecated|\
    passing:in_progress|passing:deprecated|\
    deprecated:in_progress|deprecated:not_started) return 0 ;;
    *) return 1 ;;
  esac
}

# Build an override audit record JSON object.
build_override_record() {
  local reason="$1" by="$2" missing_json="$3"
  jq -n \
    --arg by "$by" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)" \
    --arg reason "$reason" \
    --argjson missing "$missing_json" \
    '{by: $by, at: $at, reason: $reason, missing_evidence: $missing}'
}

update_status() {
  local dir="${1:-.}"
  shift
  local id="${1:?usage: harness-feature.sh status <id> <new_status>}"
  local new_status="${2:?usage: harness-feature.sh status <id> <new_status>}"
  shift 2
  local override_reason=""
  if [ "${1:-}" = "--override" ]; then
    override_reason="${2:?--override requires a non-empty reason}"
  fi
  cd "$dir" || return 1

  if ! hc_load "$dir" 2>/dev/null; then
    echo "Note: .harness/config.json not found — using defaults." >&2
  fi

  local fl="feature_list.json"
  if [ ! -f "$fl" ]; then
    echo "Error: feature_list.json not found in $(pwd)" >&2
    return 1
  fi

  # Validate the new status.
  case "$new_status" in
    not_started|in_progress|blocked|passing|unverified|deprecated) ;;
    *)
      echo "Error: Invalid status '$new_status'." >&2
      echo "Use: not_started | in_progress | blocked | passing | unverified | deprecated" >&2
      return 1
      ;;
  esac

  # Confirm the feature exists.
  if ! jq -e --arg id "$id" '.features[] | select(.id == $id)' "$fl" >/dev/null 2>&1; then
    echo "Error: feature '$id' not found." >&2
    return 1
  fi

  local current_status
  current_status="$(jq -r --arg id "$id" '.features[] | select(.id == $id) | .status' "$fl")"

  # Enforce allowed transitions.
  if ! is_allowed_transition "$current_status" "$new_status"; then
    echo "Error: transition $current_status → $new_status is not allowed." >&2
    return 1
  fi

  # WIP check when promoting to in_progress.
  if [ "$new_status" = "in_progress" ]; then
    local wip_limit
    wip_limit="$(hc_wip_limit)"
    local other_in_progress
    other_in_progress="$(jq -r --arg id "$id" \
      '[.features[] | select(.id != $id and .status == "in_progress") | .id] | length' "$fl")"
    if [ "$other_in_progress" -ge "$wip_limit" ]; then
      echo "Error: WIP limit reached ($wip_limit). Other in_progress: $(jq -r --arg id "$id" '[.features[] | select(.id != $id and .status == "in_progress") | .id] | join(", ")' "$fl")" >&2
      return 1
    fi
  fi

  # Evidence check when promoting to passing.
  if [ "$new_status" = "passing" ]; then
    local has_evidence
    has_evidence="$(jq -r --arg id "$id" '.features[] | select(.id == $id) | (.evidence | length)' "$fl")"
    if [ "$has_evidence" = "0" ] || [ -z "$has_evidence" ]; then
      if [ -z "$override_reason" ]; then
        echo "Error: feature '$id' has no evidence. Run /harness:verify first." >&2
        echo "If you must proceed anyway, use: status $id unverified --override \"<reason>\"" >&2
        return 1
      fi
      # If --override provided, redirect to unverified instead of passing.
      echo "Note: forcing via --override → routing to 'unverified' instead of 'passing'."
      new_status="unverified"
    fi
  fi

  # unverified requires --override.
  if [ "$new_status" = "unverified" ] && [ -z "$override_reason" ]; then
    echo "Error: 'unverified' requires --override \"<reason>\"" >&2
    return 1
  fi

  local today
  today="$(date +%Y-%m-%d)"
  local tmp
  tmp="$(mktemp "${fl}.tmp.XXXXXX")"

  if [ "$new_status" = "unverified" ]; then
    local by
    by="${HARNESS_OPERATOR:-$(whoami 2>/dev/null || echo unknown)}"
    local missing_json
    missing_json="$(jq -c --arg id "$id" '
      [.features[] | select(.id == $id) | .evidence[]? | .command[0] // "?"]
      | if length == 0 then ["all_required_commands"] else . end
    ' "$fl")"
    local override_json
    override_json="$(build_override_record "$override_reason" "$by" "$missing_json")"
    jq --arg id "$id" --arg status "$new_status" --arg today "$today" \
       --argjson override "$override_json" \
       '(.features[] | select(.id == $id) | .status) = $status
        | (.features[] | select(.id == $id) | .override) = $override
        | .last_updated = $today' \
       "$fl" > "$tmp" && mv -f "$tmp" "$fl"
  else
    jq --arg id "$id" --arg status "$new_status" --arg today "$today" \
       '(.features[] | select(.id == $id) | .status) = $status
        | .last_updated = $today' \
       "$fl" > "$tmp" && mv -f "$tmp" "$fl"
  fi

  echo "Feature '$id' $current_status → $new_status"
}

# --- main dispatch -----------------------------------------------------------
case "$COMMAND" in
  list|ls)         list_features "${2:-.}" ;;
  add)             shift; add_feature "${1:-.}" "$@" ;;
  status)          shift; update_status "$@" ;;
  *)
    echo "Usage: harness-feature.sh {list|add|status} [args...]"
    echo ""
    echo "Commands:"
    echo "  list [dir]                            List all features"
    echo "  add <dir> <id> <title> [area] [pri]   Add a new feature"
    echo "  status <dir> <id> <new_status> [--override \"<reason>\"]"
    exit 1
    ;;
esac
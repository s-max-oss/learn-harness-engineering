#!/bin/bash
# harness-verify.sh — Configuration-driven verification chain with structured evidence
#
# Usage:
#   bash harness-verify.sh [feature_id] [project_dir] [--write]
#
# Behavior:
#   1. Loads .harness/config.json from project_dir. If absent → exits 2 (not_configured).
#   2. For each command in verification.commands[], evaluates applies_when.
#      - applies_when false     → result: not_applicable (counted as satisfied for passing)
#      - applies_when true + missing tool → not_configured (does NOT pass)
#      - applies_when true + runs     → passed / failed
#   3. A feature is marked passing ONLY if every command where required_for_passing=true
#      AND applies_when=true returned passed. Otherwise the previous status is preserved.
#   4. Each run appends one structured evidence record (see scripts/_lib/evidence.sh).
#   5. If the most recent evidence is stale (HEAD moved + working tree changed),
#      refuses to mark passing; the script exits 3.
#   6. --write is required to mutate feature_list.json. Without it, the script
#      performs a dry-run: collects evidence in memory and prints what WOULD happen.
#
# Exit codes:
#   0  all required commands passed; feature may be passing (or already was)
#   1  at least one required command failed
#   2  config not found, or a required command is not_configured
#   3  evidence is stale; re-run needed
#
# Zero skill-to-skill dependency. Uses only bash + the tools configured by the user.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib/atomic_write.sh
source "$SKILL_DIR/_lib/atomic_write.sh"
# shellcheck source=_lib/harness_config.sh
source "$SKILL_DIR/_lib/harness_config.sh"
# shellcheck source=_lib/evidence.sh
source "$SKILL_DIR/_lib/evidence.sh"

# Sourcing the _lib files above flips `set -e` on (they declare `set -euo pipefail`).
# We deliberately want to KEEP `-e` off in verify.sh so a non-zero exit from a
# verification command (e.g. `node -e "process.exit(7)"`) is captured into
# EXIT_CODE rather than killing the script before we can record evidence.
set +e

FEATURE_ID="${1:-}"
TARGET="${2:-.}"
WRITE="false"
for arg in "$@"; do
  case "$arg" in
    --write) WRITE="true" ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0
      ;;
  esac
done

if [ ! -d "$TARGET" ]; then
  echo "Error: directory '$TARGET' not found" >&2
  exit 2
fi

if [ -z "$FEATURE_ID" ]; then
  echo "Usage: harness-verify.sh <feature_id> [project_dir] [--write]" >&2
  echo "Refusing to run without an explicit feature id." >&2
  exit 2
fi

cd "$TARGET"
PROJECT_DIR="$(pwd)"
FL="$PROJECT_DIR/feature_list.json"

if [ ! -f "$FL" ]; then
  echo "Error: feature_list.json not found in $PROJECT_DIR" >&2
  exit 2
fi

# Load config (sets HC_TYPE).
if ! hc_load "$PROJECT_DIR"; then
  echo "Error: .harness/config.json not found in $PROJECT_DIR." >&2
  echo "Run /harness:init to scaffold one, or copy templates/.harness/config.json.<type>.example." >&2
  exit 2
fi

# v1 hard requirement: jq. Without jq, harness-verify cannot safely parse the
# config's commands[] array. We fail closed with a clear message rather than
# silently dropping verification.
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required for /harness:verify." >&2
  echo "Install: winget install jqlang.jq (Windows) | brew install jq (macOS) | apt-get install jq (Linux)" >&2
  exit 2
fi

# Quick feature existence check via pure-sh grep — avoids jq for hosts without it.
feature_exists() {
  local fid="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg id "$fid" '.features[] | select(.id == $id)' "$FL" >/dev/null 2>&1
  else
    grep -q "\"id\":[[:space:]]*\"$fid\"" "$FL" 2>/dev/null
  fi
}
if ! feature_exists "$FEATURE_ID"; then
  echo "Error: feature '$FEATURE_ID' not found in feature_list.json" >&2
  exit 2
fi

# Stale-evidence policy (v1.1):
#   - Stale evidence does NOT block re-running verify against the current HEAD.
#     A stale record means the prior evidence describes a state that no longer
#     matches HEAD; the user must re-run to refresh it.
#   - Stale evidence DOES block relying on the old record as authoritative: if
#     we would otherwise promote the feature to `passing` purely because the
#     last evidence record looks good, but that record is stale, we must refuse
#     and require a fresh verify run.
#
# Implementation: we still let the run proceed. After the run, if the new
# evidence is itself stale (i.e. ev_is_stale still says true post-run — which
# only happens when no commands actually ran), then refuse to mark passing.
#
# This replaces the prior behavior of exit 3 on pre-check, which prevented
# users from refreshing stale evidence.

LOG_DIR="$PROJECT_DIR/.harness/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Resolve a command's argv from the JSON. Echoes one quoted token per line.
# Strips CRLF so Windows-host jq output doesn't smuggle \r into argv tokens.
extract_argv() {
  local cmd_json="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$cmd_json" | jq -r '.command[]' | tr -d '\r'
  else
    # Minimal: assume command is a JSON array of strings, fallback to "node -e ..." parsing
    # of the example config. If jq is missing and config has non-trivial commands,
    # we refuse rather than guess.
    echo "extract_argv: jq missing — cannot parse complex command arrays" >&2
    return 1
  fi
}

# Resolve timeout (seconds) from JSON, default 300.
extract_timeout() {
  local cmd_json="$1"
  if command -v jq >/dev/null 2>&1; then
    local v
    v="$(printf '%s' "$cmd_json" | jq -r '.timeout_seconds // 300')"
    printf '%s' "$v"
  else
    printf '300'
  fi
}

# Returns 0 if the first argv token exists on PATH or is an absolute path.
tool_available() {
  local argv0="$1"
  if [ -z "$argv0" ]; then return 1; fi
  case "$argv0" in
    /*) [ -x "$argv0" ] ;;
    *) command -v "$argv0" >/dev/null 2>&1 ;;
  esac
}

# Build shell-quoted argv array (for human-readable summary).
quote_argv() {
  local first=1 arg
  for arg in "$@"; do
    if [ $first -eq 1 ]; then first=0; else printf ' '; fi
    printf '%s' "$(printf '%s' "$arg" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
  done
}

echo "=== Harness Verify ==="
echo "Project:  $(basename "$PROJECT_DIR")"
echo "Type:     $HC_TYPE"
echo "Feature:  $FEATURE_ID"
echo "Write:    $WRITE"
echo ""

# Iterate commands.
ALL_PASSED=true
ANY_FAILED=false
ANY_NOT_CONFIGURED=false
EVIDENCE_RECORDS=()

while IFS= read -r cmd_id; do
  [ -z "$cmd_id" ] && continue
  CMD_JSON="$(hc_command_for "$cmd_id")"
  if [ -z "$CMD_JSON" ]; then continue; fi

  APPLIES="$(hc_applies "$CMD_JSON")"
  REQUIRED="$(printf '%s' "$CMD_JSON" | grep -o '"required_for_passing":[[:space:]]*true' >/dev/null 2>&1 && echo true || echo false)"

  if [ "$APPLIES" != "true" ]; then
    echo "[skip] $cmd_id: not_applicable (predicate false)"
    continue
  fi

  # Read argv.
  ARGV_STR=""
  if command -v jq >/dev/null 2>&1; then
    ARGV_STR="$(printf '%s' "$CMD_JSON" | jq -r '.command | join(" ")' | tr -d '')"
  fi

  # Build argv array.
  ARGV=()
  while IFS= read -r tok; do
    [ -n "$tok" ] && ARGV+=("$tok")
  done <<<"$(extract_argv "$CMD_JSON" 2>/dev/null || true)"

  if [ "${#ARGV[@]}" -eq 0 ]; then
    echo "[fail] $cmd_id: cannot determine command (jq required to parse complex commands)"
    ANY_FAILED=true
    continue
  fi

  if ! tool_available "${ARGV[0]}"; then
    echo "[not-configured] $cmd_id: ${ARGV[0]} not found on PATH"
    if [ "$REQUIRED" = "true" ]; then
      ANY_NOT_CONFIGURED=true
    fi
    continue
  fi

  TIMEOUT_SECS="$(extract_timeout "$CMD_JSON")"

  LOG_FILE="$LOG_DIR/verify-$cmd_id-$(date +%Y%m%dT%H%M%SZ).log"
  START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  START_MS="$(date +%s)000"

  echo "[run]   $cmd_id: $(quote_argv "${ARGV[@]}")"

  # Run with timeout if `timeout` is available; otherwise run inline.
  EXIT_CODE=0
  if command -v timeout >/dev/null 2>&1; then
    timeout "${TIMEOUT_SECS}s" "${ARGV[@]}" >"$LOG_FILE" 2>&1
    EXIT_CODE=$?
    # timeout exits 124 on timeout.
  else
    "${ARGV[@]}" >"$LOG_FILE" 2>&1
    EXIT_CODE=$?
  fi

  END_MS="$(date +%s)000"
  DURATION_MS=$((END_MS - START_MS))

  if [ "$EXIT_CODE" = "0" ]; then
    echo "[pass]  $cmd_id (exit 0, ${DURATION_MS}ms)"
  else
    echo "[fail]  $cmd_id (exit $EXIT_CODE, ${DURATION_MS}ms) — log: $LOG_FILE"
    if [ "$REQUIRED" = "true" ]; then
      ANY_FAILED=true
    fi
  fi

  COMMIT_SHA="$(ev_git_commit)"
  TREE_STATE="$(ev_git_tree_state)"
  LOG_SHA="$(ev_file_sha256 "$LOG_FILE")"
  SUMMARY="$(printf 'command %s exited %s' "$cmd_id" "$EXIT_CODE")"

  RECORD="$(jq -n \
    --arg id "$cmd_id" \
    --argjson command "$(printf '%s' "$CMD_JSON" | jq -c '.command')" \
    --argjson exit_code "$EXIT_CODE" \
    --arg started_at "$START_TS" \
    --argjson duration_ms "$DURATION_MS" \
    --arg commit "$COMMIT_SHA" \
    --arg working_tree_state "$TREE_STATE" \
    --arg summary "$SUMMARY" \
    --arg log_artifact "$LOG_FILE" \
    --arg log_sha256 "$LOG_SHA" \
    '{
      id: $id,
      command: $command,
      exit_code: $exit_code,
      started_at: $started_at,
      duration_ms: $duration_ms,
      commit: (if $commit == "null" then null else $commit end),
      working_tree_state: $working_tree_state,
      summary: $summary,
      log_artifact: $log_artifact,
      log_sha256: (if $log_sha256 == "null" then null else $log_sha256 end)
    }' 2>/dev/null || true)"

  if [ -n "$RECORD" ]; then
    EVIDENCE_RECORDS+=("$RECORD")
  fi
done <<<"$(hc_command_ids)"

echo ""
echo "───────────────────────────────────────"

# Helper: append evidence records (if any) and bump last_updated. Used in both
# the failure and success paths so the failure trail is auditable.
_write_evidence_and_status() {
  local new_status="$1"
  if [ "$WRITE" != "true" ]; then return 0; fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "(jq missing — cannot write evidence)" >&2
    return 1
  fi
  if [ "${#EVIDENCE_RECORDS[@]}" -eq 0 ]; then return 0; fi
  local COMBINED TODAY new_content
  COMBINED="$(printf '%s\n' "${EVIDENCE_RECORDS[@]}" | jq -s '.')"
  TODAY="$(date +%Y-%m-%d)"
  if ! new_content="$(jq --arg fid "$FEATURE_ID" --argjson recs "$COMBINED" --arg today "$TODAY" \
       --arg status "$new_status" \
       '(.features[] | select(.id == $fid) | .evidence) += $recs
        | (.features[] | select(.id == $fid) | .status) = $status
        | .last_updated = $today' \
       "$FL")"; then
    echo "verify: failed to render updated JSON" >&2
    return 1
  fi
  if ! atomic_write_json "$FL" "$new_content"; then
    echo "verify: atomic_write_json failed for $FL" >&2
    return 1
  fi
}

# Decision: is the feature eligible for `passing`?
if [ "$ANY_NOT_CONFIGURED" = "true" ]; then
  _write_evidence_and_status "unverified" || true
  echo "Result: not_configured (a required command's tool is missing)"
  echo "Install the required tool, or mark the feature as 'unverified' with --override."
  exit 2
fi

if [ "$ANY_FAILED" = "true" ]; then
  # Record the failure trail so we have evidence of WHAT failed and WHEN.
  # Status stays at its current value (we don't demote a passing feature on a
  # single failed re-run; the audit will surface the new evidence as suspicious).
  _write_evidence_and_status "$(jq -r --arg fid "$FEATURE_ID" '.features[] | select(.id == $fid) | .status' "$FL")" || true
  echo "Result: FAILED (at least one required command exited non-zero)"
  exit 1
fi

# Stale-evidence guard (v1.1). We let the run proceed (commands ran above and
# produced fresh evidence). At the end, if the LATEST evidence record is still
# stale (i.e. no command actually ran to refresh the evidence — e.g. every
# command was not_applicable AND there is no git repo to give us a HEAD), then
# we refuse to mark passing on stale grounds. Note: in a git repo, if any
# command ran, its evidence.commit == current HEAD, so ev_is_stale returns
# false here. We only block when nothing refreshed the record.
if [ "${#EVIDENCE_RECORDS[@]}" -gt 0 ] && command -v jq >/dev/null 2>&1; then
  if ev_is_stale "$FEATURE_ID" 2>/dev/null | grep -q true; then
    echo "Evidence for '$FEATURE_ID' is STALE and no command ran to refresh it." >&2
    echo "Either run verify in a git repo (so HEAD anchors evidence.commit), or" >&2
    echo "mark the feature 'unverified' with --override if the old record still applies." >&2
    exit 3
  fi
fi

# All required commands passed (or were not_applicable).
if [ "$WRITE" = "true" ]; then
  if command -v jq >/dev/null 2>&1; then
    # Build combined evidence array for jq (top-level).
    if [ "${#EVIDENCE_RECORDS[@]}" -gt 0 ]; then
      COMBINED="$(printf '%s\n' "${EVIDENCE_RECORDS[@]}" | jq -s '.')"
      TODAY="$(date +%Y-%m-%d)"
      new_content="$(jq --arg fid "$FEATURE_ID" --argjson recs "$COMBINED" --arg today "$TODAY" \
         '(.features[] | select(.id == $fid) | .evidence) += $recs
          | (.features[] | select(.id == $fid) | .status) = "passing"
          | .last_updated = $today' \
         "$FL")" || { echo "verify: failed to render passing JSON" >&2; exit 1; }
      atomic_write_json "$FL" "$new_content" || { echo "verify: atomic_write_json failed" >&2; exit 1; }
      echo "Result: PASSING. feature_list.json updated."
    else
      echo "Result: nothing to record (no commands ran; min_required_for_passing is empty)."
    fi
  else
    echo "Result: PASSING, but jq is not installed — cannot update feature_list.json." >&2
    echo "Install jq to enable the --write path." >&2
    exit 0
  fi
else
  echo "Result: would-pass (dry-run). Re-run with --write to update feature_list.json."
fi

exit 0
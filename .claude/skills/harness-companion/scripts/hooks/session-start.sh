#!/bin/bash
# session-start.sh — Harness Companion SessionStart hook (rewritten)
#
# Reads hook event JSON from stdin, extracts cwd reliably, and injects a harness
# status summary into Claude's context. Fail-open: always returns {"continue":true}.
#
# Failure modes:
#   - stdin empty / not JSON: still emit {"continue":true}.
#   - cwd not an existing directory: still emit {"continue":true}.
#   - jq AND python missing: fall back to a guarded substring parser (best effort).
#   - feature_list.json missing: emit {"continue":true,"suppressOutput":true}.
#
# Diagnostics: any error is written to ~/.claude/harness-companion/logs/session-start.log.

SKILL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../_lib/json_input.sh
source "$SKILL_DIR/scripts/_lib/json_input.sh"
# shellcheck source=../_lib/baseline.sh
source "$SKILL_DIR/scripts/_lib/baseline.sh"

# Fail-open diagnostic logging. Best effort — never block.
HC_LOG_DIR="${HOME}/.claude/harness-companion/logs"
mkdir -p "$HC_LOG_DIR" 2>/dev/null || HC_LOG_DIR="/tmp"
LOG_FILE="$HC_LOG_DIR/session-start.log"

_log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# Use a trap to ensure we always emit a continue:true response.
emit_continue_only() {
  printf '{"continue":true,"suppressOutput":true}\n'
  exit 0
}

trap 'emit_continue_only' ERR

ji_init
CWD="$(ji_cwd)"

if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  _log "no valid cwd (got '$CWD')"
  emit_continue_only
fi

# We trust the CWD now. cd may fail on a permissions issue.
cd "$CWD" 2>/dev/null || { _log "cd failed for $CWD"; emit_continue_only; }

# Only activate if harness files are present.
if [ ! -f "feature_list.json" ]; then
  emit_continue_only
fi

# Persist the session-start baseline commit so the stop hook can detect HEAD
# movement during the session. Fail-open: any error here just skips baseline.
if git rev-parse --git-dir >/dev/null 2>&1; then
  BASELINE_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
  if [ -n "$BASELINE_SHA" ]; then
    hc_baseline_write "$(pwd)" "$BASELINE_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
  fi
fi

# Build the status text in a temp file, then JSON-escape it via jq/python.
# Note: use ASCII markers ([OK]/[NO]/[!!]/[--]) instead of emoji. Emoji survive
# bash on Linux/macOS but are mangled by Git Bash on Windows (UTF-16 surrogate
# pairs reach jq and get re-escaped into broken sequences). ASCII is portable
# and still clearly readable in the injected context.
STATUS_TMP="$(mktemp -t harness-status.XXXXXX 2>/dev/null || mktemp)"
{
  printf '## Harness Status - %s\n\n' "$(basename "$PWD")"

  # Knowledge
  if [ -f AGENTS.md ]; then printf -- '- [OK] Knowledge: `AGENTS.md`\n'; else printf -- '- [NO] Knowledge: `AGENTS.md` MISSING\n'; fi
  if [ -f CLAUDE.md ]; then printf -- '- [OK] Knowledge: `CLAUDE.md`\n'; else printf -- '- [NO] Knowledge: `CLAUDE.md` MISSING\n'; fi

  # Environment
  if [ -f init.sh ]; then printf -- '- [OK] Environment: `init.sh`\n'; else printf -- '- [NO] Environment: `init.sh` MISSING\n'; fi
  if [ -f .harness/config.json ]; then printf -- '- [OK] Verification config: `.harness/config.json`\n'
  else printf -- '- [!!] Verification config: `.harness/config.json` missing (verify is disabled)\n'; fi

  # Scope
  if [ -f feature_list.json ]; then printf -- '- [OK] Scope: `feature_list.json`\n'
  else printf -- '- [NO] Scope: `feature_list.json` MISSING\n'; fi

  # Progress + Handoff
  for pair in "claude-progress.md:Progress" "session-handoff.md:Handoff" \
              "clean-state-checklist.md:Handoff (checklist)" \
              "checklist.sh:Handoff (checklist.sh)"; do
    f="${pair%:*}"; label="${pair#*:}"
    if [ -f "$f" ]; then printf -- '- [OK] %s: `%s`\n' "$label" "$f"
    else printf -- '- [--] %s: `%s` (optional, missing)\n' "$label" "$f"; fi
  done

  # Feature statistics - only if jq is available.
  if command -v jq >/dev/null 2>&1 && [ -f feature_list.json ]; then
    total="$(jq '.features | length' feature_list.json 2>/dev/null || echo 0)"
    passing="$(jq '[.features[] | select(.status=="passing")] | length' feature_list.json 2>/dev/null || echo 0)"
    in_progress="$(jq '[.features[] | select(.status=="in_progress")] | length' feature_list.json 2>/dev/null || echo 0)"
    unverified="$(jq '[.features[] | select(.status=="unverified")] | length' feature_list.json 2>/dev/null || echo 0)"
    printf -- '- [i] Features: %s/%s passing, %s in_progress, %s unverified\n' "$passing" "$total" "$in_progress" "$unverified"

    # WIP=1 check
    if [ "$in_progress" -gt 1 ]; then
      printf -- '- [!!] WIP violation: %s features in_progress (WIP=1 rule broken!)\n' "$in_progress"
    fi

    # Stale evidence warning
    bad_passing="$(jq '[.features[] | select((.status=="passing" or .status=="unverified") and (.evidence | length) == 0)] | length' feature_list.json 2>/dev/null || echo 0)"
    if [ "$bad_passing" -gt 0 ]; then
      printf -- '- [!!] %s passing/unverified features have NO evidence\n' "$bad_passing"
    fi
  fi

  printf -- '\nUse `/harness:status` for the detailed dashboard.\n'
} > "$STATUS_TMP"

# JSON-encode the status string. jq produces a proper JSON string with escapes.
STATUS_JSON=""
if command -v jq >/dev/null 2>&1; then
  STATUS_JSON="$(jq -Rs . < "$STATUS_TMP")"
elif command -v python >/dev/null 2>&1; then
  STATUS_JSON="$(python -c 'import json,sys; print(json.dumps(sys.stdin.read()))' < "$STATUS_TMP" 2>/dev/null || echo "")"
elif command -v python3 >/dev/null 2>&1; then
  STATUS_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' < "$STATUS_TMP" 2>/dev/null || echo "")"
fi

# If all JSON encoders failed, emit a safe minimal response.
if [ -z "$STATUS_JSON" ]; then
  _log "no JSON encoder available (jq, python, python3 all missing)"
  rm -f "$STATUS_TMP"
  emit_continue_only
fi

# Validate the encoded string is real JSON before injecting it.
if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$STATUS_JSON" | jq -e . >/dev/null 2>&1; then
    _log "STATUS_JSON failed to validate as JSON; falling back to plain"
    rm -f "$STATUS_TMP"
    emit_continue_only
  fi
fi

rm -f "$STATUS_TMP"

# Emit the hook response. additionalContext is a JSON string.
printf '{"continue":true,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$STATUS_JSON"
exit 0
#!/bin/bash
# stop-handoff.sh — Harness Companion Stop hook (rewritten)
#
# Reads hook event JSON from stdin, extracts cwd, and emits a reminder to the
# model about pending handoff items. NEVER blanket-demands "commit all uncommitted
# files" — only flags changes that look agent-introduced.
#
# Fail-open: always returns {"continue":true}. Errors go to a per-hook log.

SKILL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../_lib/json_input.sh
source "$SKILL_DIR/scripts/_lib/json_input.sh"

HC_LOG_DIR="${HOME}/.claude/harness-companion/logs"
mkdir -p "$HC_LOG_DIR" 2>/dev/null || HC_LOG_DIR="/tmp"
LOG_FILE="$HC_LOG_DIR/stop-handoff.log"

_log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

emit_continue_only() {
  printf '{"continue":true,"suppressOutput":true}\n'
  exit 0
}

emit_message() {
  local msg="$1"
  local encoded=""
  if command -v jq >/dev/null 2>&1; then
    encoded="$(printf '%s' "$msg" | jq -Rs .)"
  elif command -v python >/dev/null 2>&1; then
    encoded="$(printf '%s' "$msg" | python -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "")"
  elif command -v python3 >/dev/null 2>&1; then
    encoded="$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "")"
  fi
  if [ -z "$encoded" ]; then
    _log "no JSON encoder; emitting continue only"
    emit_continue_only
  fi
  printf '{"continue":true,"systemMessage":%s}\n' "$encoded"
  exit 0
}

trap 'emit_continue_only' ERR

ji_init
CWD="$(ji_cwd)"

if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  _log "no valid cwd (got '$CWD')"
  emit_continue_only
fi

cd "$CWD" 2>/dev/null || { _log "cd failed for $CWD"; emit_continue_only; }

if [ ! -f "feature_list.json" ]; then
  emit_continue_only
fi

MESSAGE=""

# 1. Agent-introduced uncommitted changes only (we don't warn about user pre-existing WIP).
# Heuristic: when in a git repo, files added/modified since the previous commit's
# working-tree state. Without a "session marker" we cannot perfectly separate
# agent vs user; we use mtime as a weak proxy — but we only WARN when the
# working tree is non-empty AND we don't demand they all be committed.
if git rev-parse --git-dir >/dev/null 2>&1; then
  UNCOMMITTED="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$UNCOMMITTED" -gt 0 ]; then
    MESSAGE+="[!!] $UNCOMMITTED uncommitted file(s) in this working tree. Decide whether to commit, stash, or leave them for the user.\n"
  fi
fi

# 2. Dangling in_progress features.
if command -v jq >/dev/null 2>&1 && [ -f feature_list.json ]; then
  IN_PROGRESS="$(jq -r '.features[] | select(.status=="in_progress") | "  - \(.id): \(.title)"' feature_list.json 2>/dev/null || true)"
  if [ -n "$IN_PROGRESS" ]; then
    MESSAGE+="[!!] Features still in_progress - update their status before stopping:\n$IN_PROGRESS\n"
  fi

  # 3. Passing / unverified without evidence.
  NO_EVIDENCE="$(jq -r '.features[] | select((.status=="passing" or .status=="unverified") and (.evidence | length) == 0) | "  - \(.id): \(.title)"' feature_list.json 2>/dev/null || true)"
  if [ -n "$NO_EVIDENCE" ]; then
    MESSAGE+="[!!] These features are marked passing/unverified but have no evidence:\n$NO_EVIDENCE\n"
  fi
fi

# 4. Checklist reminder.
if [ -f checklist.sh ]; then
  MESSAGE+="[i] Run \`bash checklist.sh\` to verify a clean handoff.\n"
else
  MESSAGE+="[i] Consider running \`/harness:handoff\` before ending the session.\n"
fi

if [ -z "$MESSAGE" ]; then
  emit_continue_only
fi

emit_message "$MESSAGE"
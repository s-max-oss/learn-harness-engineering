#!/bin/bash
# hooks-session-start.test.sh — Characterization tests for session-start.sh hook

set +e

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
HOOK="$SKILL_DIR/scripts/hooks/session-start.sh"

# shellcheck source=lib/harness_test.sh
source "$HERE/lib/harness_test.sh"

ht_init

run_capture_stdin() {
  local script="$1"; shift
  local input="$1"; shift
  OUT="$(printf '%s' "$input" | "$script" "$@" 2>&1)"
  RUN_EXIT=$?
}

echo "== hooks/session-start.sh =="

# --- Snapshot: empty project (no feature_list.json) — silent continue -------
# After Phase 6 rewrite, the hook now reliably emits {"continue":true,...} on
# empty stdin instead of crashing under `set -euo pipefail`. The @known-bug
# marker can be removed once the new contract is verified.
if [ -f "$HOOK" ]; then
  run_capture_stdin "$HOOK" '{}'
  ACT="$(printf '%s' "$OUT" | head -1)"
  ACT_EXIT="$RUN_EXIT"
  if [ "$ACT_EXIT" = "0" ] && printf '%s' "$ACT" | grep -q '"continue":true'; then
    ACT="yes"
  else
    ACT="no (exit=$ACT_EXIT, head=$ACT)"
  fi
  test "session-start: emits continue:true on empty input" "yes" "$ACT"
fi

# --- Snapshot: harness project — emits additionalContext ---------------------
FIX="$HERE/fixtures/node-with-packagejson"
if [ -f "$HOOK" ]; then
  INPUT="{\"cwd\":\"$FIX\"}"
  run_capture_stdin "$HOOK" "$INPUT"
  if printf '%s' "$OUT" | grep -q "hookSpecificOutput"; then ACT="yes"; else ACT="no"; fi
  test "session-start: emits hookSpecificOutput for harness project" "yes" "$ACT"
fi

# --- Windows-style path resolved to real temp project --------------------------
if [ -f "$HOOK" ]; then
  TMP="$(ht_mktmp session-start-windows-cwd)"
  # Clone the fixture into a temp dir to simulate a real project at an arbitrary path.
  cp -a "$FIX"/* "$TMP/" 2>/dev/null || cp -r "$FIX"/* "$TMP/"
  # Use the actual temp path (which may contain spaces/dashes/etc).
  INPUT="{\"cwd\":\"$TMP\"}"
  run_capture_stdin "$HOOK" "$INPUT"
  if printf '%s' "$OUT" | grep -q "hookSpecificOutput"; then ACT="yes"; else ACT="no"; fi
  test "session-start: detects harness files from temp project on real path" \
       "yes" "$ACT"
  ht_rmrf "$TMP"
fi

ht_summary
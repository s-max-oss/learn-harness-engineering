#!/bin/bash
# hooks-stop-handoff.test.sh — Characterization tests for stop-handoff.sh hook

set +e

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
HOOK="$SKILL_DIR/scripts/hooks/stop-handoff.sh"

# shellcheck source=lib/harness_test.sh
source "$HERE/lib/harness_test.sh"

ht_init

run_capture_stdin() {
  local script="$1"; shift
  local input="$1"; shift
  OUT="$(printf '%s' "$input" | "$script" "$@" 2>&1)"
  RUN_EXIT=$?
}

echo "== hooks/stop-handoff.sh =="

# --- Empty project — silent continue -----------------------------------------
# After Phase 6 rewrite: emits {"continue":true,...} reliably on empty stdin
# instead of crashing under pipefail.
if [ -f "$HOOK" ]; then
  run_capture_stdin "$HOOK" '{}'
  ACT="$(printf '%s' "$OUT" | head -1)"
  ACT_EXIT="$RUN_EXIT"
  if [ "$ACT_EXIT" = "0" ] && printf '%s' "$ACT" | grep -q '"continue":true'; then
    ACT="yes"
  else
    ACT="no (exit=$ACT_EXIT, head=$ACT)"
  fi
  test "stop-handoff: emits continue:true on empty input" "yes" "$ACT"
fi

# --- Harness project with dangling in_progress: warns ----------------------
FIX="$HERE/fixtures/multiple-in-progress"
if [ -f "$HOOK" ]; then
  INPUT="{\"cwd\":\"$FIX\"}"
  run_capture_stdin "$HOOK" "$INPUT"
  if printf '%s' "$OUT" | grep -q "still in_progress"; then ACT="yes"; else ACT="no"; fi
  if command -v jq >/dev/null 2>&1; then
    test "stop-handoff: warns about in_progress features (with jq)" "yes" "$ACT"
  else
    # Skip on hosts without jq - we cannot assess in_progress without it.
    echo "  ⏭  stop-handoff: warns about in_progress features (skipped: no jq)"
    HT_SKIPPED=$((HT_SKIPPED + 1))
  fi
fi

# --- No blanket 'commit all' demand: distinguish agent vs user ---------------
# After Phase 6 rewrite: hook only WARNS about uncommitted files (does NOT
# demand they all be committed). It should mention the count and leave the
# decision to the user.
FIX="$HERE/fixtures/node-with-packagejson"
if [ -f "$HOOK" ]; then
  TMP="$(ht_mktmp stop-hook)"
  cp "$FIX/feature_list.json" "$TMP/feature_list.json"
  (cd "$TMP" && git init -q -b main && git add feature_list.json && \
     git -c user.email=test@test -c user.name=test commit -q -m initial) >/dev/null 2>&1
  echo "agent-introduced change" >> "$TMP/feature_list.json"
  INPUT="{\"cwd\":\"$TMP\"}"
  run_capture_stdin "$HOOK" "$INPUT"
  # New behavior: warns about uncommitted files but doesn't demand "commit all".
  if printf '%s' "$OUT" | grep -q "uncommitted file"; then ACT="yes"; else ACT="no"; fi
  test "stop-handoff: warns (but doesn't demand) about uncommitted files" "yes" "$ACT"
  if printf '%s' "$OUT" | grep -qiE 'commit all|commit everything'; then ACT="yes"; else ACT="no"; fi
  test "stop-handoff: does NOT use blanket 'commit all' language" "no" "$ACT"
  ht_rmrf "$TMP"
fi

ht_summary
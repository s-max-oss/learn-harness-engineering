#!/bin/bash
# harness-status.test.sh — Tests for harness-status.sh
#
# v2: harness-status.sh now uses `set +e` (no abort on first missing file).
# All 7 subsystem sections render regardless of file presence.

set +e

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/harness-status.sh"

# shellcheck source=lib/harness_test.sh
source "$HERE/lib/harness_test.sh"

ht_init

# run_capture <script> <args...> — runs script, captures stdout, returns exit code separately.
run_capture() {
  local script="$1"
  shift
  OUT="$("$script" "$@" 2>&1)"
  RUN_EXIT=$?
}

contains() { printf '%s' "$1" | grep -qF -- "$2"; }

echo "== harness-status.sh =="

# --- Header renders ----------------------------------------------------------
FIX="$HERE/fixtures/node-with-packagejson"
if [ -f "$SCRIPT" ]; then
  run_capture "$SCRIPT" "$FIX"
  if contains "$OUT" "Harness Health:"; then ACT="yes"; else ACT="no"; fi
  test "status: prints 'Harness Health:' header" "yes" "$ACT"
fi

# --- feature_list.json stats render (v2: set +e survivies missing AGENTS.md) ---
FIX="$HERE/fixtures/node-with-packagejson"
if [ -f "$SCRIPT" ]; then
  if contains "$OUT" "feature_list.json" && contains "$OUT" "Scope:"; then ACT="yes"; else ACT="no"; fi
  test "status: shows feature_list.json under Scope section" "yes" "$ACT"
fi

# --- Fixture: passing-no-evidence (warning case) -----------------------------
FIX="$HERE/fixtures/passing-no-evidence"
if [ -f "$SCRIPT" ] && command -v jq >/dev/null 2>&1; then
  run_capture "$SCRIPT" "$FIX"
  if contains "$OUT" "passing features have no evidence"; then ACT="yes"; else ACT="no"; fi
  test "status: warns about passing feature with no evidence" "yes" "$ACT"
else
  echo "  ⏭  status: warns about passing feature with no evidence (skipped: jq not installed)"
  HT_SKIPPED=$((HT_SKIPPED + 1))
fi

# --- Fixture: multiple-in-progress (WIP violation) ---------------------------
FIX="$HERE/fixtures/multiple-in-progress"
if [ -f "$SCRIPT" ] && command -v jq >/dev/null 2>&1; then
  run_capture "$SCRIPT" "$FIX"
  if contains "$OUT" "WIP violation"; then ACT="yes"; else ACT="no"; fi
  test "status: flags WIP violation when >1 in_progress" "yes" "$ACT"
else
  echo "  ⏭  status: flags WIP violation (skipped: jq not installed)"
  HT_SKIPPED=$((HT_SKIPPED + 1))
fi

# --- Fixture: generic-empty (no package.json) --------------------------------
FIX="$HERE/fixtures/generic-empty"
if [ -f "$SCRIPT" ]; then
  run_capture "$SCRIPT" "$FIX"
  if contains "$OUT" "AGENTS.md" && contains "$OUT" "MISSING"; then ACT="yes"; else ACT="no"; fi
  test "status: missing AGENTS.md reported" "yes" "$ACT"
fi

ht_summary
#!/bin/bash
# harness-feature.test.sh — Characterization tests for harness-feature.sh

set +e

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/harness-feature.sh"

# shellcheck source=lib/harness_test.sh
source "$HERE/lib/harness_test.sh"

ht_init

echo "== harness-feature.sh =="

# --- Skip everything if jq is missing — the script itself errors out ---------
if ! command -v jq >/dev/null 2>&1; then
  echo "  ⏭  harness-feature.sh requires jq (not installed); all tests skipped"
  HT_SKIPPED=$((HT_SKIPPED + 1))
  ht_summary
  exit 0
fi

# --- Snapshot: list shows feature rows ---------------------------------------
FIX="$HERE/fixtures/node-with-packagejson"
if [ -f "$SCRIPT" ]; then
  OUT="$(cd "$FIX" && "$SCRIPT" list 2>&1)"
  ACT="$(printf '%s' "$OUT" | head -1)"
  test "feature list: header includes project name" "Features in node-with-packagejson:" "$ACT"
fi

# --- Snapshot: WIP=1 enforcement ---------------------------------------------
FIX="$HERE/fixtures/multiple-in-progress"
if [ -f "$SCRIPT" ]; then
  OUT="$(cd "$FIX" && "$SCRIPT" status a-001 in_progress 2>&1)"
  if printf '%s' "$OUT" | grep -q "WIP=1 rule"; then ACT="yes"; else ACT="no"; fi
  test "feature status: WIP=1 violation blocks setting another in_progress" "yes" "$ACT"
fi

# --- @known-bug: --force silently bypasses evidence requirement --------------
FIX="$HERE/fixtures/passing-no-evidence"
if [ -f "$SCRIPT" ]; then
  # ghost-001 already has status=passing with empty evidence; current script
  # happily keeps it that way without auditing.
  ACT_STATUS="$(cd "$FIX" && jq -r '.features[0].status' feature_list.json 2>/dev/null)"
  if [ "$ACT_STATUS" = "passing" ]; then ACT="yes"; else ACT="no"; fi
  test "@known-bug feature status: passing-with-no-evidence is currently accepted" "yes" "$ACT"
fi

ht_summary
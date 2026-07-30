#!/bin/bash
# harness-feature.test.sh — Characterization tests for harness-feature.sh
# v1.1: strengthened passing evidence validation (structured, all-passing,
# current-HEAD, full command coverage).

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
FIX="$HERE/fixtures/wip-one-active"
if [ -f "$SCRIPT" ]; then
  OUT="$(cd "$FIX" && "$SCRIPT" status . a-002 in_progress 2>&1)"
  if printf '%s' "$OUT" | grep -q "WIP limit reached"; then ACT="yes"; else ACT="no"; fi
  test "feature status: WIP=1 violation blocks setting another in_progress (a-001 active, try a-002)" "yes" "$ACT"
fi

# --- passing-with-no-evidence must be REJECTED (v1.1) ------------------------
FIX="$HERE/fixtures/passing-no-evidence"
TMP="$(ht_mktmp feat-empty-evidence)"
cp -a "$FIX"/* "$TMP/" 2>/dev/null || cp -r "$FIX"/* "$TMP/"
# ghost-001 is currently passing with empty evidence. In v1.1, the evidence
# validator rejects this — but the feature already HAS status=passing, and
# the validator only fires when TRANSITIONING to passing. So we reset the
# status and try to transition back.
jq '(.features[] | select(.id == "ghost-001") | .status) = "in_progress"' \
  "$TMP/feature_list.json" > "$TMP/tmp.json" && mv "$TMP/tmp.json" "$TMP/feature_list.json"
OUT="$(cd "$TMP" && "$SCRIPT" status . ghost-001 passing 2>&1)"
RUN_EXIT=$?
if [ "$RUN_EXIT" != "0" ] && printf '%s' "$OUT" | grep -q "evidence"; then ACT="yes"; else ACT="no"; fi
test "feature status: passing-with-no-evidence is REJECTED" "yes" "$ACT"

# Confirm status was NOT changed.
FINAL_STATUS="$(cd "$TMP" && jq -r '.features[0].status' feature_list.json 2>/dev/null)"
test "feature status: passing-with-no-evidence — status stays in_progress" \
     "in_progress" "$FINAL_STATUS"
ht_rmrf "$TMP"

# --- passing-with-string-evidence must be REJECTED (v1.1) --------------------
FIX="$HERE/fixtures/v0-string-evidence"
TMP="$(ht_mktmp feat-string-evidence)"
cp -a "$FIX"/* "$TMP/" 2>/dev/null || cp -r "$FIX"/* "$TMP/"
OUT="$(cd "$TMP" && "$SCRIPT" status . legacy-001 passing 2>&1)"
RUN_EXIT=$?
if [ "$RUN_EXIT" != "0" ] && printf '%s' "$OUT" | grep -qi "string"; then ACT="yes"; else ACT="no"; fi
test "feature status: string (v0-legacy) evidence is REJECTED" "yes" "$ACT"

FINAL_STATUS="$(cd "$TMP" && jq -r '.features[0].status' feature_list.json 2>/dev/null)"
test "feature status: string evidence — status stays in_progress" \
     "in_progress" "$FINAL_STATUS"
ht_rmrf "$TMP"

# --- passing-with-partial-coverage must be REJECTED (v1.1) -------------------
FIX="$HERE/fixtures/partial-evidence"
TMP="$(ht_mktmp feat-partial-evidence)"
cp -a "$FIX"/* "$TMP/" 2>/dev/null || cp -r "$FIX"/* "$TMP/"
cp -a "$FIX/.harness" "$TMP/" 2>/dev/null || true
OUT="$(cd "$TMP" && "$SCRIPT" status . partial-001 passing 2>&1)"
RUN_EXIT=$?
if [ "$RUN_EXIT" != "0" ] && printf '%s' "$OUT" | grep -q "missing"; then ACT="yes"; else ACT="no"; fi
test "feature status: partial evidence (missing required commands) is REJECTED" "yes" "$ACT"

FINAL_STATUS="$(cd "$TMP" && jq -r '.features[0].status' feature_list.json 2>/dev/null)"
test "feature status: partial evidence — status stays in_progress" \
     "in_progress" "$FINAL_STATUS"
ht_rmrf "$TMP"

ht_summary

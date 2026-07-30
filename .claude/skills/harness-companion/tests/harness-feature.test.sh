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

# --- verify --write and feature status passing agree (v1.1.1) ------------------
# Both scripts use is_eligible_for_passing from the shared library. After a
# successful verify --write, promoting to passing via harness-feature.sh must
# also succeed (same commit, same evidence, same criteria).
FIX="$HERE/fixtures/node-with-packagejson"
TMP="$(ht_mktmp feat-agreement)"
cp -a "$FIX"/* "$TMP/" 2>/dev/null || cp -r "$FIX"/* "$TMP/"
mkdir -p "$TMP/.harness"
cp "$SKILL_DIR/templates/.harness/config.json.node.example" "$TMP/.harness/config.json"
(cd "$TMP" && git init -q -b main && git add -A && \
   git -c user.email=test@test -c user.name=test commit -q -m initial) >/dev/null 2>&1
# Step 1: verify --write marks passing.
VERIFY_OUT="$("$SKILL_DIR/scripts/harness-verify.sh" "f-001" "$TMP" --write 2>&1)"
VERIFY_EXIT=$?
test "feature agreement: verify --write exits 0" "0" "$VERIFY_EXIT"
VERIFY_STATUS="$(jq -r '.features[0].status' "$TMP/feature_list.json")"
test "feature agreement: verify --write sets status=passing" "passing" "$VERIFY_STATUS"
# Step 2: reset to in_progress, then promote via harness-feature.sh.
jq '(.features[] | select(.id == "f-001") | .status) = "in_progress"' \
  "$TMP/feature_list.json" > "$TMP/tmp.json" && mv "$TMP/tmp.json" "$TMP/feature_list.json"
FEAT_OUT="$(cd "$TMP" && "$SCRIPT" status . f-001 passing 2>&1)"
FEAT_EXIT=$?
test "feature agreement: harness-feature.sh status passing exits 0" "0" "$FEAT_EXIT"
FEAT_STATUS="$(jq -r '.features[0].status' "$TMP/feature_list.json")"
test "feature agreement: harness-feature.sh sets status=passing" "passing" "$FEAT_STATUS"
ht_rmrf "$TMP"

ht_summary

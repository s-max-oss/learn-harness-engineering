#!/bin/bash
# harness-verify.test.sh — Tests for the rewritten harness-verify.sh
#
# The new contract:
#   - Refuses to run without .harness/config.json (exit 2)
#   - Requires jq (exit 2 if missing)
#   - Never invokes npx tsc on non-TypeScript projects
#   - Tracks structured evidence (object with command/exit_code/started_at/...)
#   - Requires --write to mutate feature_list.json; otherwise dry-run
#   - Exits 1 if any required command fails
#   - Marks passing only if every required command passed

set +e

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/harness-verify.sh"

# shellcheck source=lib/harness_test.sh
source "$HERE/lib/harness_test.sh"

ht_init

run_capture() {
  local script="$1"; shift
  OUT="$("$script" "$@" 2>&1)"
  RUN_EXIT=$?
}

# Make a fresh tmp dir with the given fixture copied in, plus .harness/config.json
# from the matching template example.
make_tmp_with_config() {
  local fix_name="$1"
  local example_name="$2"
  local d
  d="$(ht_mktmp verify-$fix_name)"
  cp -r "$HERE/fixtures/$fix_name/." "$d/"
  mkdir -p "$d/.harness"
  cp "$SKILL_DIR/templates/.harness/$example_name" "$d/.harness/config.json"
  printf '%s' "$d"
}

HAS_JQ=0
if command -v jq >/dev/null 2>&1; then HAS_JQ=1; fi

echo "== harness-verify.sh (rewritten) =="

# --- Refuses without config.json ---------------------------------------------
FIX="$HERE/fixtures/node-with-packagejson"
run_capture "$SCRIPT" "f-001" "$FIX"
ACT="$RUN_EXIT"
test "verify: exits 2 (not_configured) when no .harness/config.json" "2" "$ACT"

# --- Without jq: exits 2 with clear error ------------------------------------
if [ "$HAS_JQ" -eq 0 ]; then
  TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
  run_capture "$SCRIPT" "f-001" "$TMP" --write
  ACT="$RUN_EXIT"
  test "verify: exits 2 when jq is missing" "2" "$ACT"
  if printf '%s' "$OUT" | grep -qi "jq is required"; then ACT="yes"; else ACT="no"; fi
  test "verify: prints 'jq is required' guidance when jq is missing" "yes" "$ACT"
  ht_rmrf "$TMP"
else
  echo "  ⏭  verify: exits 2 when jq missing (skipped: jq installed)"
  HT_SKIPPED=$((HT_SKIPPED + 1))
  echo "  ⏭  verify: prints jq-required guidance (skipped: jq installed)"
  HT_SKIPPED=$((HT_SKIPPED + 1))
fi

# --- Without jq: never invokes npx tsc on python fixture ---------------------
FIX="$HERE/fixtures/python-pyproject"
run_capture "$SCRIPT" "py-001" "$FIX"
# Script now exits 2 immediately (no config + no jq) before even considering commands.
ACT="$RUN_EXIT"
test "verify: python fixture exits 2 (no config) without invoking tsc" "2" "$ACT"
if printf '%s' "$OUT" | grep -qiE 'tsc --noEmit'; then ACT="yes"; else ACT="no"; fi
test "verify: NEVER invokes npx tsc on python fixture" "no" "$ACT"

# --- Tests below require jq to run meaningfully ------------------------------
if [ "$HAS_JQ" -eq 0 ]; then
  echo "  ⏭  Remaining verify tests require jq; skipped."
  HT_SKIPPED=$((HT_SKIPPED + 4))
  ht_summary
  exit 0
fi

# --- Without --write is a dry-run; doesn't mutate feature_list.json ---------
TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
BEFORE="$(cat "$TMP/feature_list.json")"
run_capture "$SCRIPT" "f-001" "$TMP"
AFTER="$(cat "$TMP/feature_list.json")"
test "verify: without --write leaves feature_list.json unchanged" "$BEFORE" "$AFTER"
test "verify: without --write reports 'would-pass (dry-run)'" "1" \
  "$(printf '%s' "$OUT" | grep -c 'would-pass' || true)"
ht_rmrf "$TMP"

# --- With --write, all passing → status=passing and evidence appended ------
TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
(cd "$TMP" && git init -q -b main && git add -A && \
   git -c user.email=test@test -c user.name=test commit -q -m initial) >/dev/null 2>&1
run_capture "$SCRIPT" "f-001" "$TMP" --write
test "verify: --write exits 0 on a clean node fixture" "0" "$RUN_EXIT"
test "verify: --write flips feature status to passing" \
     "passing" \
     "$(jq -r '.features[0].status' "$TMP/feature_list.json")"
test "verify: --write appends structured evidence (object, not string)" \
     "object" \
     "$(jq -r '.features[0].evidence[0] | type' "$TMP/feature_list.json")"
test "verify: evidence record has exit_code, started_at, commit" \
     "3" \
     "$(jq -r '.features[0].evidence[0] | (.exit_code, .started_at, .commit) | select(. != null) | length' "$TMP/feature_list.json" 2>/dev/null || echo 0)"
ht_rmrf "$TMP"

# --- Required command missing tool → not_configured (exit 2) -----------------
TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
cat > "$TMP/.harness/config.json" <<'JSON'
{
  "schema_version": 1,
  "project_type": "generic",
  "verification": {
    "min_required_for_passing": ["nonexistent"],
    "commands": [
      {
        "id": "nonexistent",
        "command": ["definitely-not-a-real-binary-xyz", "--version"],
        "timeout_seconds": 30,
        "required_for_passing": true
      }
    ]
  }
}
JSON
run_capture "$SCRIPT" "f-001" "$TMP" --write
test "verify: required tool missing → exits 2 (not_configured)" "2" "$RUN_EXIT"
ht_rmrf "$TMP"

ht_summary
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
# Force-execute the missing-jq branch via PATH isolation even when jq is
# installed on the host. Remove ALL jq-containing directories from PATH.
TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
PATH_NO_JQ="$PATH"
for jq_path in $(which -a jq 2>/dev/null || true); do
  JQ_DIR="$(dirname "$jq_path")"
  PATH_NO_JQ="$(echo "$PATH_NO_JQ" | tr ':' '\n' | grep -v "^${JQ_DIR}$" | paste -sd: -)"
done
OUT="$(env -i PATH="$PATH_NO_JQ" HOME="$HOME" bash "$SCRIPT" "f-001" "$TMP" --write 2>&1)"
ACT=$?
test "verify: exits 2 when jq is missing" "2" "$ACT"
if printf '%s' "$OUT" | grep -qi "jq is required"; then ACT="yes"; else ACT="no"; fi
test "verify: prints 'jq is required' guidance when jq is missing" "yes" "$ACT"
ht_rmrf "$TMP"

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
     "$(jq -r '[.features[0].evidence[0] | (.exit_code, .started_at, .commit)] | map(select(. != null)) | length' "$TMP/feature_list.json" 2>/dev/null || echo 0)"
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

# ==============================================================================
# Real-scenario tests (no skips). Each scenario reproduces a real-world failure
# mode the harness must handle correctly.
# ==============================================================================

# --- Scenario 1: paths with spaces ---------------------------------------------
# Real-world: a feature id or argv token may contain spaces. verify.sh must
# handle them without splitting or failing. We craft a command whose argv is a
# single token with a space (node -e "<script with spaces>").
TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
cat > "$TMP/.harness/config.json" <<'JSON'
{
  "schema_version": 1,
  "project_type": "node",
  "verification": {
    "min_required_for_passing": ["spaces"],
    "commands": [
      {
        "id": "spaces",
        "command": ["node", "-e", "console.log('hello world with spaces ok')"],
        "timeout_seconds": 30,
        "required_for_passing": true,
        "applies_when": { "files_any": ["package.json"] }
      }
    ]
  }
}
JSON
(cd "$TMP" && git init -q -b main && git add -A && \
   git -c user.email=test@test -c user.name=test commit -q -m initial) >/dev/null 2>&1
run_capture "$SCRIPT" "f-001" "$TMP" --write
test "verify: paths-with-spaces — argv with spaces succeeds" "0" "$RUN_EXIT"
test "verify: paths-with-spaces — feature is passing" "passing" \
     "$(jq -r '.features[0].status' "$TMP/feature_list.json")"
ht_rmrf "$TMP"

# --- Scenario 2: dirty workspace (uncommitted changes) -------------------------
# Real-world: the user has uncommitted changes at verify time. Verify must NOT
# refuse to run, but must record working_tree_state=dirty in the evidence.
TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
(cd "$TMP" && git init -q -b main && git add -A && \
   git -c user.email=test@test -c user.name=test commit -q -m initial) >/dev/null 2>&1
# Make a dirty change AFTER the initial commit.
echo "// dirty workspace marker" >> "$TMP/package.json"
run_capture "$SCRIPT" "f-001" "$TMP" --write
test "verify: dirty-workspace — succeeds despite uncommitted changes" "0" "$RUN_EXIT"
DIRTY_EVIDENCE="$(jq -r '.features[0].evidence[-1].working_tree_state' "$TMP/feature_list.json")"
test "verify: dirty-workspace — records working_tree_state=dirty" "dirty" "$DIRTY_EVIDENCE"
ht_rmrf "$TMP"

# --- Scenario 3: missing jq (force-execution by hiding jq) --------------------
# Real-world: a host without jq. We simulate by putting a directory with NO jq
# ahead of jq on PATH. verify.sh must exit 2 with a clear error and NOT touch
# feature_list.json.
TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
# Build a PATH that excludes ALL jq installations. We start from the current PATH
# and remove every directory that contains a `jq` binary (winget, ~/bin, etc.).
PATH_WITHOUT_JQ="$PATH"
for jq_path in $(which -a jq 2>/dev/null || true); do
  JQ_DIR="$(dirname "$jq_path")"
  PATH_WITHOUT_JQ="$(echo "$PATH_WITHOUT_JQ" | tr ':' '\n' | grep -v "^${JQ_DIR}$" | paste -sd: -)"
done
BEFORE="$(cat "$TMP/feature_list.json")"
OUT="$(env -i PATH="$PATH_WITHOUT_JQ" HOME="$HOME" bash "$SCRIPT" "f-001" "$TMP" --write 2>&1)"
RUN_EXIT=$?
test "verify: missing-jq — exits 2 (not_configured)" "2" "$RUN_EXIT"
test "verify: missing-jq — error message names jq" "1" \
     "$(printf '%s' "$OUT" | grep -c 'jq is required' || true)"
test "verify: missing-jq — does NOT mutate feature_list.json" "$BEFORE" \
     "$(cat "$TMP/feature_list.json")"
ht_rmrf "$TMP"

# --- Scenario 4: missing git (verify should still work) ------------------------
# Real-world: a non-git project. verify must work — git is optional. evidence
# records commit=null and working_tree_state=no_git, but the feature still gets
# marked passing when all required commands pass.
TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
# Deliberately do NOT git init. This is a non-git scenario.
run_capture "$SCRIPT" "f-001" "$TMP" --write
test "verify: missing-git — exits 0 even without git" "0" "$RUN_EXIT"
test "verify: missing-git — feature is passing" "passing" \
     "$(jq -r '.features[0].status' "$TMP/feature_list.json")"
test "verify: missing-git — records commit=null" "null" \
     "$(jq -r '.features[0].evidence[-1].commit' "$TMP/feature_list.json")"
test "verify: missing-git — records working_tree_state=no_git" "no_git" \
     "$(jq -r '.features[0].evidence[-1].working_tree_state' "$TMP/feature_list.json")"
ht_rmrf "$TMP"

# --- Scenario 5: required command fails (real exit code) -----------------------
# Real-world: a required command exits non-zero. verify.sh must exit 1, must
# NOT mark the feature as passing, must record the failure in evidence, and
# the structured record must include the real exit code.
TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
cat > "$TMP/.harness/config.json" <<'JSON'
{
  "schema_version": 1,
  "project_type": "node",
  "verification": {
    "min_required_for_passing": ["failer"],
    "commands": [
      {
        "id": "failer",
        "command": ["node", "-e", "process.exit(7)"],
        "timeout_seconds": 30,
        "required_for_passing": true,
        "applies_when": { "files_any": ["package.json"] }
      }
    ]
  }
}
JSON
(cd "$TMP" && git init -q -b main && git add -A && \
   git -c user.email=test@test -c user.name=test commit -q -m initial) >/dev/null 2>&1
run_capture "$SCRIPT" "f-001" "$TMP" --write
test "verify: test-failure — exits 1 on required failure" "1" "$RUN_EXIT"
test "verify: test-failure — feature stays not_passing (status unchanged from initial)" \
     "$(jq -r '.features[0].status' "$HERE/fixtures/node-with-packagejson/feature_list.json")" \
     "$(jq -r '.features[0].status' "$TMP/feature_list.json")"
test "verify: test-failure — evidence records real exit_code=7" "7" \
     "$(jq -r '.features[0].evidence[-1].exit_code' "$TMP/feature_list.json")"
ht_rmrf "$TMP"

# --- Scenario 6: HEAD moved after evidence was recorded → stale ---------------
# Real-world: verify ran at commit A, HEAD later moved to commit B. Re-running
# verify must refuse to mark passing (or detect the prior evidence is stale).
TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
(cd "$TMP" && git init -q -b main && git add -A && \
   git -c user.email=test@test -c user.name=test commit -q -m initial) >/dev/null 2>&1
# First verify run — should succeed at the initial commit.
run_capture "$SCRIPT" "f-001" "$TMP" --write
test "verify: HEAD-moved — initial verify succeeds" "0" "$RUN_EXIT"
FIRST_COMMIT="$(cd "$TMP" && git rev-parse --short=12 HEAD)"
test "verify: HEAD-moved — first evidence.commit equals HEAD" "$FIRST_COMMIT" \
     "$(jq -r '.features[0].evidence[-1].commit' "$TMP/feature_list.json")"
# Now move HEAD with a new commit.
echo "// follow-up commit" >> "$TMP/extra.js"
(cd "$TMP" && git add -A && \
   git -c user.email=test@test -c user.name=test commit -q -m follow-up) >/dev/null 2>&1
SECOND_COMMIT="$(cd "$TMP" && git rev-parse --short=12 HEAD)"
test "verify: HEAD-moved — HEAD is now different commit" "different" \
     "$(if [ "$FIRST_COMMIT" = "$SECOND_COMMIT" ]; then echo same; else echo different; fi)"
# Re-run verify — v1.1.1: commands actually run and produce fresh evidence against
# the new HEAD. Even though prior evidence is stale, the new evidence.commit
# equals current HEAD, so the run succeeds.
run_capture "$SCRIPT" "f-001" "$TMP" --write
test "verify: HEAD-moved — re-run at new HEAD succeeds (exit 0, fresh evidence)" "0" "$RUN_EXIT"
test "verify: HEAD-moved — new evidence.commit equals current HEAD" "$SECOND_COMMIT" \
     "$(jq -r '.features[0].evidence[-1].commit' "$TMP/feature_list.json")"
ht_rmrf "$TMP"

# --- Scenario 7: fail-then-fix-then-pass ---------------------------------------
# Real-world: a required command fails first, gets fixed, then passes on re-run.
# v1.1.1: the second run produces fresh evidence with a new run_id and succeeds.
TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
(cd "$TMP" && git init -q -b main && git add -A && \
   git -c user.email=test@test -c user.name=test commit -q -m initial) >/dev/null 2>&1
# First: a command that fails.
cat > "$TMP/.harness/config.json" <<'JSON'
{
  "schema_version": 1,
  "project_type": "node",
  "verification": {
    "min_required_for_passing": ["failer"],
    "commands": [
      {
        "id": "failer",
        "command": ["node", "-e", "process.exit(3)"],
        "timeout_seconds": 30,
        "required_for_passing": true,
        "applies_when": { "files_any": ["package.json"] }
      }
    ]
  }
}
JSON
run_capture "$SCRIPT" "f-001" "$TMP" --write
test "verify: fail-then-fix — first run with failing command exits 1" "1" "$RUN_EXIT"
FIRST_RUN_ID="$(jq -r '.features[0].evidence[-1].run_id' "$TMP/feature_list.json")"
test "verify: fail-then-fix — first evidence record has a run_id" "1" \
     "$(printf '%s' "$FIRST_RUN_ID" | grep -c 'T' || true)"
# Fix: change command to succeed.
cat > "$TMP/.harness/config.json" <<'JSON'
{
  "schema_version": 1,
  "project_type": "node",
  "verification": {
    "min_required_for_passing": ["failer"],
    "commands": [
      {
        "id": "failer",
        "command": ["node", "-e", "console.log('fixed!')"],
        "timeout_seconds": 30,
        "required_for_passing": true,
        "applies_when": { "files_any": ["package.json"] }
      }
    ]
  }
}
JSON
run_capture "$SCRIPT" "f-001" "$TMP" --write
test "verify: fail-then-fix — re-run after fix exits 0" "0" "$RUN_EXIT"
test "verify: fail-then-fix — feature status is now passing" "passing" \
     "$(jq -r '.features[0].status' "$TMP/feature_list.json")"
SECOND_RUN_ID="$(jq -r '.features[0].evidence[-1].run_id' "$TMP/feature_list.json")"
test "verify: fail-then-fix — second evidence record has a different run_id" "different" \
     "$(if [ "$FIRST_RUN_ID" = "$SECOND_RUN_ID" ]; then echo same; else echo different; fi)"
# Verify that the passing check ONLY uses the second run's records (not the first's)
test "verify: fail-then-fix — second run_id evidence has exit_code 0" "0" \
     "$(jq -r --arg rid "$SECOND_RUN_ID" \
        '.features[0].evidence[] | select(.run_id == $rid) | .exit_code' \
        "$TMP/feature_list.json")"
ht_rmrf "$TMP"

# --- Scenario 8: two incomplete runs cannot be cobbled for passing ------------
# Real-world: Run A covers typecheck only, Run B covers test only. Even though
# together they look complete, different run_ids mean the latest run (B) is
# incomplete → not eligible for passing.
FIX="$HERE/fixtures/two-runs"
TMP="$(ht_mktmp verify-two-runs)"
cp -a "$FIX"/* "$TMP/" 2>/dev/null || cp -r "$FIX"/* "$TMP/"
cp -a "$FIX/.harness" "$TMP/" 2>/dev/null || true
OUT="$(cd "$TMP" && "$SKILL_DIR/scripts/harness-feature.sh" status . two-runs-001 passing 2>&1)"
RUN_EXIT=$?
test "verify: two-runs — feature status passing is REJECTED (exit != 0)" "1" \
     "$(if [ "$RUN_EXIT" != "0" ]; then echo 1; else echo 0; fi)"
if printf '%s' "$OUT" | grep -q "missing"; then ACT="yes"; else ACT="no"; fi
test "verify: two-runs — error mentions missing commands" "yes" "$ACT"
FINAL_STATUS="$(cd "$TMP" && jq -r '.features[0].status' feature_list.json 2>/dev/null)"
test "verify: two-runs — status stays in_progress" "in_progress" "$FINAL_STATUS"
ht_rmrf "$TMP"

# --- Scenario 9: old-commit evidence does not satisfy new HEAD at feature level
# Real-world: evidence at commit A was passing. HEAD moves to commit B.
# harness-feature.sh status <id> passing must REJECT because evidence.commit ≠ HEAD.
TMP="$(make_tmp_with_config node-with-packagejson config.json.node.example)"
(cd "$TMP" && git init -q -b main && git add -A && \
   git -c user.email=test@test -c user.name=test commit -q -m initial) >/dev/null 2>&1
# Run verify at commit A → passes.
run_capture "$SCRIPT" "f-001" "$TMP" --write
test "verify: old-commit — initial verify succeeds" "0" "$RUN_EXIT"
FIRST_COMMIT="$(cd "$TMP" && git rev-parse --short=12 HEAD)"
# Move HEAD to commit B.
echo "// new commit" >> "$TMP/extra.js"
(cd "$TMP" && git add -A && \
   git -c user.email=test@test -c user.name=test commit -q -m follow-up) >/dev/null 2>&1
# Reset feature to in_progress so the state machine allows in_progress→passing.
# (verify --write already set it to passing at the old commit.)
jq '(.features[] | select(.id == "f-001") | .status) = "in_progress"' \
  "$TMP/feature_list.json" > "$TMP/tmp.json" && mv "$TMP/tmp.json" "$TMP/feature_list.json"
# Try to promote to passing via harness-feature.sh → should REJECT (stale).
OUT="$(cd "$TMP" && "$SKILL_DIR/scripts/harness-feature.sh" status . f-001 passing 2>&1)"
RUN_EXIT=$?
test "verify: old-commit — feature status passing is REJECTED after HEAD moves" "1" \
     "$(if [ "$RUN_EXIT" != "0" ]; then echo 1; else echo 0; fi)"
if printf '%s' "$OUT" | grep -q "stale"; then ACT="yes"; else ACT="no"; fi
test "verify: old-commit — error mentions stale evidence" "yes" "$ACT"
ht_rmrf "$TMP"

ht_summary
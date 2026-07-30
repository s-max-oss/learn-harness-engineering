#!/bin/bash
# migration.test.sh — End-to-end v0 → v1 migration test.
#
# Scenario: a project was using the OLD harness-companion v0 (no
# .harness/config.json, "verification" as string array on each feature). It
# upgrades to v1 (config-driven verification, structured evidence).
#
# This test runs in a freshly created temp directory under the OS temp dir
# (NOT inside the repo) so we don't pollute the test fixtures. It verifies:
#   1. v0 fixture is detected by the audit/verify scripts
#   2. After scaffolding .harness/config.json, verify works
#   3. Status/feature commands still work after the upgrade
#   4. The old `verification` string array is preserved through the upgrade
#   5. Settings migration: hooks in settings.json point at v1 scripts

set +e

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

# shellcheck source=lib/harness_test.sh
source "$HERE/lib/harness_test.sh"

ht_init

echo "== migration: v0 → v1 =="

# Set up a fresh temp directory OUTSIDE the repo so we don't pollute fixtures.
TMP_ROOT="$(mktemp -d -t harness-migration-XXXXXX)" || {
  echo "FATAL: cannot create temp dir" >&2
  exit 1
}

# Pick the v0 fixture (no .harness/config.json).
V0_FIX="$HERE/fixtures/v0-no-config"
if [ ! -d "$V0_FIX" ]; then
  echo "FATAL: v0 fixture missing at $V0_FIX" >&2
  exit 1
fi

# Copy v0 fixture to the migration workspace.
MIG_DIR="$TMP_ROOT/migration-workspace"
mkdir -p "$MIG_DIR"
cp -r "$V0_FIX/." "$MIG_DIR/"

# Initialize a git repo so the v1 scripts can record commit SHAs.
(cd "$MIG_DIR" && git init -q -b main && git add -A && \
   git -c user.email=test@test -c user.name=test commit -q -m "v0 baseline") >/dev/null 2>&1

# --- Stage 1: pre-migration state --------------------------------------------
# The v0 project has feature_list.json with a `verification` STRING ARRAY
# (no .harness/config.json yet).
test "migration: v0 fixture has feature_list.json with string-array verification" \
     "yes" \
     "$(if [ -f "$MIG_DIR/feature_list.json" ] && jq -e '.features[0].verification | type == "array"' "$MIG_DIR/feature_list.json" >/dev/null 2>&1; then echo yes; else echo no; fi)"

test "migration: v0 fixture has NO .harness/config.json yet" \
     "yes" \
     "$(if [ ! -f "$MIG_DIR/.harness/config.json" ]; then echo yes; else echo no; fi)"

# --- Stage 2: v1 verify refuses without config --------------------------------
"$SKILL_DIR/scripts/harness-verify.sh" "v0-feat-001" "$MIG_DIR" >/dev/null 2>&1
ACT_EXIT=$?
test "migration: v1 verify refuses v0 fixture (no config) — exits 2" "2" "$ACT_EXIT"

# --- Stage 3: scaffold .harness/config.json (the migration step) -------------
# In real life the user runs /harness:init or copies a template. We simulate
# that by copying the example config that ships with the skill.
mkdir -p "$MIG_DIR/.harness"
cp "$SKILL_DIR/templates/.harness/config.json.node.example" "$MIG_DIR/.harness/config.json"

test "migration: .harness/config.json now exists after migration step" \
     "yes" \
     "$(if [ -f "$MIG_DIR/.harness/config.json" ]; then echo yes; else echo no; fi)"

test "migration: config.json has schema_version field (v1 marker)" \
     "1" \
     "$(jq -r '.schema_version' "$MIG_DIR/.harness/config.json")"

# --- Stage 4: v1 verify works on the migrated project -------------------------
# The default node example config uses `node -e ...` which works in our test env.
# We must have a package.json in MIG_DIR for the applies_when.files_any predicate
# to pass.
if [ ! -f "$MIG_DIR/package.json" ]; then
  printf '{"name":"migration-test","version":"0.0.0"}\n' > "$MIG_DIR/package.json"
  (cd "$MIG_DIR" && git add -A && \
     git -c user.email=test@test -c user.name=test commit -q -m "add package.json") >/dev/null 2>&1
fi

"$SKILL_DIR/scripts/harness-verify.sh" "v0-feat-001" "$MIG_DIR" --write >/dev/null 2>&1
ACT_EXIT=$?
test "migration: v1 verify succeeds after migration (exits 0)" "0" "$ACT_EXIT"
test "migration: v1 verify flips v0-feature to passing" \
     "passing" \
     "$(jq -r '.features[] | select(.id == "v0-feat-001") | .status' "$MIG_DIR/feature_list.json")"
test "migration: v1 verify appended structured evidence (object, not string)" \
     "object" \
     "$(jq -r '.features[] | select(.id == "v0-feat-001") | .evidence[0] | type' "$MIG_DIR/feature_list.json")"

# --- Stage 5: v0 `verification` array is preserved through migration ----------
# The migration should NOT silently drop the v0 `verification` string array —
# it's the project's own documentation of what to test. We only added evidence
# and changed status.
ARRAY_TYPE_BEFORE="$(jq -r '.features[0].verification | type' "$V0_FIX/feature_list.json")"
ARRAY_TYPE_AFTER="$(jq -r '.features[] | select(.id == "v0-feat-001") | .verification | type' "$MIG_DIR/feature_list.json")"
test "migration: v0 verification string array is preserved (type unchanged)" \
     "$ARRAY_TYPE_BEFORE" "$ARRAY_TYPE_AFTER"

# --- Stage 6: v1 status/feature commands still work after migration -----------
"$SKILL_DIR/scripts/harness-status.sh" "$MIG_DIR" >/dev/null 2>&1
test "migration: harness-status works on migrated project" \
     "0" \
     "$?"
"$SKILL_DIR/scripts/harness-feature.sh" list "$MIG_DIR" >/dev/null 2>&1
test "migration: harness-feature list works on migrated project" \
     "0" \
     "$?"
"$SKILL_DIR/scripts/harness-audit.sh" "$MIG_DIR" >/dev/null 2>&1
test "migration: harness-audit works on migrated project" \
     "0" \
     "$?"

# --- Stage 7: settings.json hooks point at v1 scripts -------------------------
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  HOOK_COUNT="$(jq -r '
    [.hooks | to_entries[] | .value[] | .hooks[]
     | select(.command | test("harness-companion"; "i"))]
    | length' "$SETTINGS" 2>/dev/null || echo 0)"
  if [ "$HOOK_COUNT" -ge 1 ]; then
    ACT="wired"
  else
    ACT="not_wired"
  fi
  test "migration: settings.json has at least one harness-companion hook wired" "wired" "$ACT"
  test "migration: settings.json has BOTH SessionStart and Stop hooks wired" "2" "$HOOK_COUNT"
else
  echo "  ⏭  migration: settings.json hook check (skipped: no settings.json)"
  HT_SKIPPED=$((HT_SKIPPED + 1))
fi

# Cleanup.
rm -rf "$TMP_ROOT"

ht_summary
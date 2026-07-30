#!/bin/bash
# harness-audit.test.sh — Characterization tests for harness-audit.sh

set +e

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/harness-audit.sh"

# shellcheck source=lib/harness_test.sh
source "$HERE/lib/harness_test.sh"

ht_init

run_capture() {
  local script="$1"; shift
  OUT="$("$script" "$@" 2>&1)"
  RUN_EXIT=$?
}

echo "== harness-audit.sh =="

# --- Fixture: empty project (only feature_list.json present) -----------------
# The exact total depends on git recency (a recently committed feature_list.json
# scores higher on the recency axis). What matters is:
#   a) The output renders all 7 subsystems
#   b) Scores are content-driven (missing AGENTS.md → Knowledge < 3)
#   c) Total is deterministic across consecutive runs
FIX="$HERE/fixtures/generic-empty"
if [ -f "$SCRIPT" ]; then
  run_capture "$SCRIPT" "$FIX"
  if printf '%s' "$OUT" | grep -q "^Harness Audit:"; then ACT="yes"; else ACT="no"; fi
  test "audit: prints 'Harness Audit:' header" "yes" "$ACT"
  if printf '%s' "$OUT" | grep -q "Knowledge"; then ACT="yes"; else ACT="no"; fi
  test "audit: shows Knowledge subsystem line" "yes" "$ACT"
  # Total must be between 0 and 21 (not garbage)
  ACT_TOTAL="$(printf '%s' "$OUT" | grep -oE 'Total: [0-9]+/21' | head -1)"
  if printf '%s' "$ACT_TOTAL" | grep -qE 'Total: [0-9]+/21'; then ACT="yes"; else ACT="no"; fi
  test "audit: total is in X/21 format" "yes" "$ACT"
  # Knowledge=0 because neither AGENTS.md nor CLAUDE.md exist
  if printf '%s' "$OUT" | grep -qE '^  Knowledge +0/3'; then ACT="yes"; else ACT="no"; fi
  test "audit: Knowledge=0/3 when AGENTS.md+CLAUDE.md are missing" "yes" "$ACT"
  # Scope/Feature >=1 because feature_list.json exists (existence pass)
  if printf '%s' "$OUT" | grep -qE '^  Scope/Feature +[123]/3'; then ACT="yes"; else ACT="no"; fi
  test "audit: Scope/Feature >= 1/3 because feature_list.json exists" "yes" "$ACT"
fi

# --- Snapshot: non-determinism across consecutive runs -----------------------
FIX="$HERE/fixtures/generic-empty"
if [ -f "$SCRIPT" ]; then
  OUT1="$("$SCRIPT" "$FIX" 2>&1)"
  OUT2="$("$SCRIPT" "$FIX" 2>&1)"
  T1="$(printf '%s' "$OUT1" | grep -oE 'Total: [0-9]+/21' | head -1)"
  T2="$(printf '%s' "$OUT2" | grep -oE 'Total: [0-9]+/21' | head -1)"
  test "@known-bug-or-correct audit: total is deterministic across consecutive runs" \
       "$T1" "$T2"
fi

ht_summary
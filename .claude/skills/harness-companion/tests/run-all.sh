#!/bin/bash
# run-all.sh — Run every characterization test in tests/
#
# Exits non-zero if any test fails. Skipped tests don't fail the run.
# Designed to be safe in a non-git, no-jq, no-python environment.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

# Make all test scripts executable (idempotent).
chmod +x "$HERE"/*.sh 2>/dev/null || true

FAILED=0
TOTAL_FILES=0

for t in "$HERE"/*.test.sh; do
  [ -f "$t" ] || continue
  TOTAL_FILES=$((TOTAL_FILES + 1))
  echo ""
  echo "═══════════════════════════════════════════"
  echo "  $(basename "$t")"
  echo "═══════════════════════════════════════════"
  if bash "$t"; then
    :
  else
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "═══════════════════════════════════════════"
echo "  Test files: $TOTAL_FILES | Failed: $FAILED"
echo "═══════════════════════════════════════════"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
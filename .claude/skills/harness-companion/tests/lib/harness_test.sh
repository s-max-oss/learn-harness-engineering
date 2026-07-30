#!/bin/bash
# harness_test.sh — Tiny pure-bash test runner for harness-companion self-tests.
#
# Usage:
#   source tests/lib/harness_test.sh
#   ht_init
#   test "name" "expected" "actual"
#   test_file_contains "name" "path" "substring"
#   test_not_file_contains "name" "path" "substring"
#   test_exit_code "name" <expected_code>  <actual_code captured by caller>
#   ht_summary   # prints pass/fail counts, exits non-zero if any failed
#
# This runner is intentionally dependency-free (no jq, no python). Tests that
# require jq must be skipped on hosts without jq via ht_skip_if_no_jq.

set -u

HT_PASSED=0
HT_FAILED=0
HT_SKIPPED=0
HT_DEFERRED=0
HT_NAMES=()

ht_init() {
  HT_PASSED=0
  HT_FAILED=0
  HT_SKIPPED=0
  HT_DEFERRED=0
  HT_NAMES=()
}

# Assert two strings equal.
test() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    HT_PASSED=$((HT_PASSED + 1))
    echo "  ✅ $name"
  else
    HT_FAILED=$((HT_FAILED + 1))
    echo "  ❌ $name"
    echo "     expected: $(printf '%s' "$expected" | head -c 200)"
    echo "     actual:   $(printf '%s' "$actual" | head -c 200)"
  fi
  HT_NAMES+=("$name")
}

# Assert that a file contains a substring.
test_file_contains() {
  local name="$1" path="$2" needle="$3"
  if [ ! -f "$path" ]; then
    HT_FAILED=$((HT_FAILED + 1))
    echo "  ❌ $name (file missing: $path)"
    HT_NAMES+=("$name")
    return 0
  fi
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    HT_PASSED=$((HT_PASSED + 1))
    echo "  ✅ $name"
  else
    HT_FAILED=$((HT_FAILED + 1))
    echo "  ❌ $name (substring not found in $path: $needle)"
    HT_NAMES+=("$name")
  fi
}

# Assert that a file does NOT contain a substring.
test_not_file_contains() {
  local name="$1" path="$2" needle="$3"
  if [ ! -f "$path" ]; then
    HT_FAILED=$((HT_FAILED + 1))
    echo "  ❌ $name (file missing: $path)"
    HT_NAMES+=("$name")
    return 0
  fi
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    HT_FAILED=$((HT_FAILED + 1))
    echo "  ❌ $name (unexpected substring in $path: $needle)"
    HT_NAMES+=("$name")
  else
    HT_PASSED=$((HT_PASSED + 1))
    echo "  ✅ $name"
  fi
}

# Skip helper: skip current test when jq is absent. Call this BEFORE asserting.
ht_skip_if_no_jq() {
  local name="${1:-test}"
  if ! command -v jq >/dev/null 2>&1; then
    HT_SKIPPED=$((HT_SKIPPED + 1))
    echo "  ⏭  $name (skipped: jq not installed)"
    HT_NAMES+=("$name [skipped]")
    return 0
  fi
  return 1
}

# Deferred test: tracks a test that documents CURRENT broken behavior pending a
# future refactor. Records the result but does NOT count toward failure.
# Use this when you want to capture "what's broken right now" without breaking
# CI. Pair with a tag like "@deferred-v2" in the test name.
test_deferred() {
  local name="$1" expected="$2" actual="$3" reason="${4:-deferred to next refactor}"
  if [ "$expected" = "$actual" ]; then
    HT_DEFERRED=$((HT_DEFERRED + 1))
    echo "  🟡 $name (passes now; pending removal in next refactor)"
    echo "     reason: $reason"
  else
    HT_DEFERRED=$((HT_DEFERRED + 1))
    echo "  🟡 $name (currently fails as expected)"
    echo "     expected: $(printf '%s' "$expected" | head -c 200)"
    echo "     actual:   $(printf '%s' "$actual" | head -c 200)"
    echo "     reason:   $reason"
  fi
  HT_NAMES+=("$name [deferred]")
}

# Print summary. Returns non-zero if any failed.
ht_summary() {
  local total=$((HT_PASSED + HT_FAILED + HT_SKIPPED + HT_DEFERRED))
  echo ""
  echo "─────────────────────────────"
  echo "Passed:   $HT_PASSED"
  echo "Failed:   $HT_FAILED"
  echo "Skipped:  $HT_SKIPPED"
  echo "Deferred: $HT_DEFERRED"
  echo "Total:    $total"
  if [ "$HT_FAILED" -gt 0 ]; then
    return 1
  fi
  return 0
}

# Create a temporary directory under tests/.tmp/, return its absolute path.
ht_mktmp() {
  local prefix="${1:-fixture}"
  local d
  d="$(mktemp -d -t harness-test-${prefix}.XXXXXX 2>/dev/null || mktemp -d)"
  if [ -z "$d" ]; then
    echo "ht_mktmp: failed to create temp dir" >&2
    return 1
  fi
  printf '%s' "$d"
}

# Remove a path rm -rf-style.
ht_rmrf() {
  rm -rf "$1" 2>/dev/null || true
}
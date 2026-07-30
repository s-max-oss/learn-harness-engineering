#!/bin/bash
# passing.sh — Run-based passing eligibility for evidence records
#
# v1.1.1: Passing is determined by the LATEST COMPLETE RUN only. Evidence records
# from different runs cannot be cobbled together. Each run is identified by a
# unique run_id (timestamp-PID-RANDOM), injected by verify.sh at invocation time.
#
# Usage:
#   source passing.sh
#   RUN_ID="$(generate_run_id)"
#   is_eligible_for_passing <feature_id> <feature_list_json>
#
# is_eligible_for_passing returns 0 if the feature is eligible for "passing"
# status, 1 with an explanation on stderr otherwise. Rules:
#   1. Evidence is non-empty and structured (objects, not v0 strings)
#   2. Find the latest run_id across all evidence records
#   3. Only records sharing that run_id are considered
#   4. All considered records must have exit_code == 0
#   5. Considered records must cover all required commands (required_for_passing != false)
#   6. Latest run's commit must equal current HEAD (git repos only)

set -euo pipefail

# ---- generate_run_id -----------------------------------------------------------
# Produces a unique run identifier: timestamp-PID-RANDOM
# Example: "20260730T151257Z-12345-32767"
generate_run_id() {
  local ts pid rand
  ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)"
  pid="$$"
  rand="${RANDOM:-0}"
  printf '%s-%s-%s' "$ts" "$pid" "$rand"
}

# ---- is_eligible_for_passing ---------------------------------------------------
# Core passing-eligibility strategy shared by verify.sh and harness-feature.sh.
is_eligible_for_passing() {
  local fid="$1" fl="$2"
  local errs=0
  local cfg="${HC_CONFIG_DIR:-.}/.harness/config.json"

  # --- 1: Non-empty structured evidence ------------------------------------------
  local count has_strings
  count="$(jq -r --arg fid "$fid" \
    '[.features[] | select(.id == $fid) | .evidence[]?] | length' "$fl" 2>/dev/null || echo 0)"
  if [ "$count" = "0" ] || [ -z "$count" ]; then
    echo "Error: feature '$fid' has no evidence. Run /harness:verify first." >&2
    return 1
  fi
  has_strings="$(jq -r --arg fid "$fid" \
    '[.features[] | select(.id == $fid) | .evidence[] | select(type == "string")] | length' "$fl" 2>/dev/null || echo 0)"
  if [ "$has_strings" != "0" ]; then
    echo "Error: feature '$fid' has $has_strings string evidence record(s) (legacy v0 format)." >&2
    echo "Re-run /harness:verify to produce structured evidence records." >&2
    errs=$((errs + 1))
  fi

  # --- 2: Find the latest run_id -------------------------------------------------
  # Legacy records (no run_id) map to "__legacy__"; treated as a singleton — only
  # the very last record is checked. Modern records carry a timestamp-PID-RANDOM
  # run_id; string max() picks the lexicographically latest (newest timestamp).
  local latest_run
  latest_run="$(jq -r --arg fid "$fid" '
    [.features[] | select(.id == $fid) | .evidence[]?.run_id // "__legacy__"] | max
  ' "$fl" 2>/dev/null || echo "__legacy__")"

  # --- 3-4: Only latest-run records; all must have exit_code == 0 ---------------
  local failed
  if [ "$latest_run" = "__legacy__" ]; then
    # Legacy singleton: only the very last evidence record matters.
    failed="$(jq -r --arg fid "$fid" \
      '.features[] | select(.id == $fid) | .evidence[-1] | select(.exit_code != 0) | "1"' \
      "$fl" 2>/dev/null || echo "0")"
  else
    failed="$(jq -r --arg fid "$fid" --arg run "$latest_run" \
      '[.features[] | select(.id == $fid) | .evidence[]? | select(.run_id == $run and .exit_code != 0)] | length' \
      "$fl" 2>/dev/null || echo 0)"
  fi
  if [ "$failed" != "0" ]; then
    echo "Error: feature '$fid' has $failed evidence record(s) with non-zero exit code in the latest run." >&2
    echo "All required verification commands must pass before marking as passing." >&2
    errs=$((errs + 1))
  fi

  # --- 5: Coverage — all required commands represented in the latest run ---------
  if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    local required_ids covered_ids missing
    required_ids="$(jq -r '[.verification.commands[]? | select(.required_for_passing != false) | .id] | sort | unique | .[]' "$cfg" 2>/dev/null || true)"
    if [ "$latest_run" = "__legacy__" ]; then
      # Legacy singleton: only the last record's id.
      covered_ids="$(jq -r --arg fid "$fid" \
        '[.features[] | select(.id == $fid) | .evidence[-1].id // "?"] | sort | unique | .[]' \
        "$fl" 2>/dev/null || true)"
    else
      covered_ids="$(jq -r --arg fid "$fid" --arg run "$latest_run" \
        '[.features[] | select(.id == $fid) | .evidence[]? | select(.run_id == $run) | .id // "?"] | sort | unique | .[]' \
        "$fl" 2>/dev/null || true)"
    fi
    missing="$(comm -23 <(printf '%s' "$required_ids") <(printf '%s' "$covered_ids") 2>/dev/null || true)"
    if [ -n "$missing" ]; then
      echo "Error: evidence missing for required command(s): $(echo "$missing" | tr '\n' ' ')" >&2
      echo "Re-run /harness:verify to execute all required verification commands." >&2
      errs=$((errs + 1))
    fi
  fi

  # --- 6: Latest run's commit == current HEAD (git repos only) -------------------
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local run_commit head_commit
    if [ "$latest_run" = "__legacy__" ]; then
      run_commit="$(jq -r --arg fid "$fid" \
        '.features[] | select(.id == $fid) | (.evidence[-1].commit // "null")' "$fl" 2>/dev/null || echo "null")"
    else
      run_commit="$(jq -r --arg fid "$fid" --arg run "$latest_run" \
        '.features[] | select(.id == $fid) | .evidence[]? | select(.run_id == $run) | .commit // "null"' \
        "$fl" 2>/dev/null | head -1 || echo "null")"
    fi
    head_commit="$(git rev-parse --short=12 HEAD 2>/dev/null || echo "null")"
    if [ "$run_commit" != "null" ] && [ "$head_commit" != "null" ] \
       && [ "$run_commit" != "$head_commit" ]; then
      echo "Error: evidence is stale — proven at $run_commit, HEAD is $head_commit." >&2
      echo "Re-run /harness:verify to refresh evidence against current HEAD." >&2
      errs=$((errs + 1))
    fi
  fi

  return "$errs"
}

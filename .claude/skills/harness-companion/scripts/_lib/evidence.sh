#!/bin/bash
# evidence.sh — Build and append structured evidence records to feature_list.json
#
# Usage:
#   source evidence.sh
#   EV_CWD="/abs/project" \
#   EV_FEATURE_LIST="/abs/project/feature_list.json" \
#     ev_build_record <command_array_json> <exit_code> <started_at> <duration_ms> \
#                     <commit> <working_tree_state> <summary> <log_artifact> <log_sha256>
#
#     Prints a single JSON object representing one evidence record.
#
#   ev_append <feature_id> <record_json>     # appends record to feature's evidence array
#                                            # marks passing IF all required commands passed
#                                            # refuses if evidence is stale
#
#   ev_is_stale <feature_id>                 # echoes "true" if HEAD moved past recorded commit
#                                            # and working tree differs from record
#
# Requires jq. Fails closed (returns non-zero, prints nothing useful) if jq is absent —
# callers must check EV_HAS_JQ before using these helpers.

set -euo pipefail

EV_HAS_JQ=0
if command -v jq >/dev/null 2>&1; then
  EV_HAS_JQ=1
fi

# Compute git commit SHA, or "null" if not a git repo. Empty string is also valid input.
ev_git_commit() {
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git rev-parse --short=12 HEAD 2>/dev/null || printf 'null'
  else
    printf 'null'
  fi
}

# Compute working tree state: "clean" if no uncommitted changes, "dirty" otherwise.
# Returns "no_git" if not in a git repo.
ev_git_tree_state() {
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local count
    count="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    if [ "$count" = "0" ]; then
      printf 'clean'
    else
      printf 'dirty'
    fi
  else
    printf 'no_git'
  fi
}

# Compute SHA-256 of a file. Returns "null" if file is missing or sha256sum unavailable.
ev_file_sha256() {
  local f="$1"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    printf 'null'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  printf 'null'
}

# Build one evidence record JSON.
# Args:
#   1 command_json          e.g. ["npm","run","build"]
#   2 exit_code             integer
#   3 started_at            ISO8601 string, e.g. 2026-07-30T11:14:02Z
#   4 duration_ms           integer milliseconds
#   5 commit                git short SHA or "null"
#   6 working_tree_state    "clean" | "dirty" | "no_git"
#   7 summary               short string
#   8 log_artifact          relative path or "null"
#   9 log_sha256            sha256 hex or "null"
ev_build_record() {
  if [ "$EV_HAS_JQ" -eq 0 ]; then
    return 1
  fi
  jq -n \
    --argjson command "$1" \
    --argjson exit_code "$2" \
    --arg started_at "$3" \
    --argjson duration_ms "$4" \
    --arg commit "$5" \
    --arg working_tree_state "$6" \
    --arg summary "$7" \
    --arg log_artifact "$8" \
    --arg log_sha256 "$9" \
    '{
      command: $command,
      exit_code: $exit_code,
      started_at: $started_at,
      duration_ms: $duration_ms,
      commit: (if $commit == "null" then null else $commit end),
      working_tree_state: $working_tree_state,
      summary: $summary,
      log_artifact: (if $log_artifact == "null" then null else $log_artifact end),
      log_sha256: (if $log_sha256 == "null" then null else $log_sha256 end)
    }'
}

# Append one evidence record to a feature. Also bump last_updated.
# Args: <feature_id> <record_json>
ev_append() {
  local fid="$1"
  local record="$2"
  local fl="${EV_FEATURE_LIST:-feature_list.json}"
  if [ ! -f "$fl" ]; then
    echo "evidence: feature_list.json not found at $fl" >&2
    return 1
  fi
  if [ "$EV_HAS_JQ" -eq 0 ]; then
    echo "evidence: jq required to append structured evidence" >&2
    return 2
  fi
  local today
  today="$(date +%Y-%m-%d)"
  local tmp
  tmp="$(mktemp "${fl}.tmp.XXXXXX")"
  if ! jq --arg fid "$fid" --argjson rec "$record" --arg today "$today" \
       '(.features[] | select(.id == $fid) | .evidence) += [$rec]
        | .last_updated = $today' \
       "$fl" > "$tmp"; then
    rm -f "$tmp"
    echo "evidence: failed to rewrite feature_list.json" >&2
    return 3
  fi
  mv -f "$tmp" "$fl"
}

# Determine if the most recent evidence record for a feature is stale.
# Stale means: HEAD differs from the recorded commit AND working tree differs from
# the recorded working_tree_state. Non-git repos always return "false" (we can't
# decide staleness, so we err on the side of letting verify proceed with a warning).
ev_is_stale() {
  local fid="$1"
  local fl="${EV_FEATURE_LIST:-feature_list.json}"
  if [ ! -f "$fl" ] || [ "$EV_HAS_JQ" -eq 0 ]; then
    printf 'false'
    return 0
  fi
  local last
  last="$(jq -c --arg fid "$fid" '
    .features[] | select(.id == $fid) | .evidence | last // empty
  ' "$fl" 2>/dev/null || true)"
  if [ -z "$last" ]; then
    printf 'false'
    return 0
  fi
  local rec_commit rec_state
  rec_commit="$(printf '%s' "$last" | jq -r '.commit // "null"')"
  rec_state="$(printf '%s' "$last" | jq -r '.working_tree_state // "no_git"')"

  local current_commit
  current_commit="$(ev_git_commit)"
  local current_state
  current_state="$(ev_git_tree_state)"

  # No git → we don't claim stale.
  if [ "$rec_commit" = "null" ] || [ "$current_commit" = "null" ]; then
    printf 'false'
    return 0
  fi

  if [ "$rec_commit" != "$current_commit" ] && [ "$rec_state" != "$current_state" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}
#!/bin/bash
# baseline.sh — Persist and read per-cwd commit baselines for hook coordination.
#
# The session-start hook writes the current HEAD SHA + UTC timestamp to
# ~/.claude/harness-companion/baselines/<cwd-hash>. The stop hook reads it and
# uses the saved SHA as the "trusted baseline" for stale-evidence judgement.
#
# Why this exists: the stop hook is the LAST place where the model can be warned
# about evidence staleness. Comparing against mtime / "uncommitted files" is
# unreliable because (a) mtime is per-file and tells us nothing about commit
# progression, and (b) the user might have pre-existing dirty work. The
# session-start snapshot is exactly what we need: "at the start of this session,
# HEAD was at X".
#
# All operations are fail-open. A missing baseline is treated as "no baseline
# available" — the stop hook then falls back to current HEAD.

set -u

HC_BASELINE_DIR="${HOME}/.claude/harness-companion/baselines"
mkdir -p "$HC_BASELINE_DIR" 2>/dev/null || HC_BASELINE_DIR="/tmp"

# Hash a cwd into a deterministic filename. Uses sha256sum when available,
# otherwise a portable cksum-style fallback.
_baseline_key() {
  local cwd="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$cwd" | sha256sum | awk '{print $1}' | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$cwd" | shasum -a 256 | awk '{print $1}' | cut -c1-16
  else
    # Fallback: djb2-ish portable hash
    local h=5381 c
    while IFS= read -r -n1 c; do
      h=$(( (h * 33 + $(printf '%d' "'$c") )))
    done <<<"$cwd"
    printf '%x' "$h"
  fi
}

# Write a baseline for a cwd.
# Args: <cwd> <commit_sha> [<started_at_iso>]
hc_baseline_write() {
  local cwd="$1"
  local sha="$2"
  local ts="${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)}"
  [ -z "$cwd" ] && return 1
  [ -z "$sha" ] && return 1
  local key
  key="$(_baseline_key "$cwd")"
  local f="$HC_BASELINE_DIR/$key.json"
  # JSON-encode without depending on jq (this lib is sourced by both hooks).
  # We use printf %s for the fields and rely on no special chars in cwd/sha.
  # The cwd might contain " — that's safe in a JSON string literal.
  local escaped_cwd escaped_sha escaped_ts
  escaped_cwd="${cwd//\\/\\\\}"
  escaped_cwd="${escaped_cwd//\"/\\\"}"
  escaped_sha="${sha//\\/\\\\}"
  escaped_sha="${escaped_sha//\"/\\\"}"
  escaped_ts="${ts//\\/\\\\}"
  escaped_ts="${escaped_ts//\"/\\\"}"
  printf '{"cwd":"%s","commit":"%s","started_at":"%s"}\n' \
    "$escaped_cwd" "$escaped_sha" "$escaped_ts" > "$f" 2>/dev/null || true
}

# Read the saved commit for a cwd. Echoes the SHA, or empty string if absent.
hc_baseline_read_commit() {
  local cwd="$1"
  [ -z "$cwd" ] && { printf ''; return 0; }
  local key
  key="$(_baseline_key "$cwd")"
  local f="$HC_BASELINE_DIR/$key.json"
  if [ ! -f "$f" ]; then
    printf ''
    return 0
  fi
  # Strip optional quotes + CRLF.
  sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1
}

# Read the saved started_at timestamp for a cwd.
hc_baseline_read_at() {
  local cwd="$1"
  [ -z "$cwd" ] && { printf ''; return 0; }
  local key
  key="$(_baseline_key "$cwd")"
  local f="$HC_BASELINE_DIR/$key.json"
  if [ ! -f "$f" ]; then
    printf ''
    return 0
  fi
  sed -n 's/.*"started_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1
}

# Clear baseline (test helper).
hc_baseline_clear() {
  local cwd="$1"
  [ -z "$cwd" ] && return 0
  local key
  key="$(_baseline_key "$cwd")"
  rm -f "$HC_BASELINE_DIR/$key.json" 2>/dev/null || true
}
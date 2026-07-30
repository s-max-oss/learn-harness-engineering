#!/bin/bash
# json_input.sh — Reliable stdin JSON parsing for hooks
#
# Usage:
#   source json_input.sh
#   ji_init                       # reads stdin once, stores it in $JI_INPUT
#   ji_field <key>                # returns scalar value (string/number/bool) or empty
#   ji_cwd                        # returns cwd field, normalized to forward-slash absolute path
#
# Parsing strategy (in order, falls back on failure):
#   1. jq — preferred
#   2. python3 — robust fallback
#   3. minimal substring scan — only for fields we know are top-level strings
#
# All functions are read-only and never write to stdout (except ji_init which prints
# diagnostics to stderr). The last call's result is cached in $JI_LAST.

set -euo pipefail

JI_INPUT=""
JI_LAST=""
JI_HAVE_INPUT=0

# Read all stdin into JI_INPUT. Safe to call once per process.
ji_init() {
  if [ "$JI_HAVE_INPUT" -eq 1 ]; then
    return 0
  fi
  # Read stdin; if it's empty (e.g. hook framework sent nothing), set to empty object.
  JI_INPUT="$(cat 2>/dev/null || true)"
  if [ -z "$JI_INPUT" ]; then
    JI_INPUT='{}'
  fi
  JI_HAVE_INPUT=1
}

# Internal: emit a JSON-quoted error diagnostic on stderr and return empty.
_ji_diag() {
  echo "json_input: $1" >&2
  return 0
}

# Internal: try to extract a top-level scalar string field by key.
# Tries jq first, then python (3 or plain), then a guarded substring scan as last resort.
_ji_field_impl() {
  local key="$1"
  local val=""

  if command -v jq >/dev/null 2>&1; then
    val="$(printf '%s' "$JI_INPUT" | jq -r --arg k "$key" 'if (.[$k] // null) | type == "string" then .[$k] else empty end' 2>/dev/null || true)"
    JI_LAST="$val"
    return 0
  fi

  local py=""
  if command -v python3 >/dev/null 2>&1; then
    py="python3"
  elif command -v python >/dev/null 2>&1; then
    py="python"
  fi

  if [ -n "$py" ]; then
    val="$(JI_INPUT="$JI_INPUT" KEY="$key" "$py" -c '
import json, os, sys
try:
    data = json.loads(os.environ["JI_INPUT"])
except Exception:
    sys.exit(0)
v = data.get(os.environ["KEY"], None)
if isinstance(v, (str, int, float, bool)):
    print(v)
' 2>/dev/null || true)"
    JI_LAST="$val"
    return 0
  fi

  # Last resort: substring scan for top-level string values only.
  # Pattern matches "key":"value" where value has no unescaped quote.
  local pattern="\"$key\":\""
  local idx="${JI_INPUT#*$pattern}"
  if [ "$idx" != "$JI_INPUT" ]; then
    local end="${idx#*\"}"
    end="${end%%\"*}"
    val="$end"
  fi
  JI_LAST="$val"
  return 0
}

# Public: ji_field <key> — print scalar string value, or empty if absent/wrong type.
ji_field() {
  if [ $# -lt 1 ]; then
    _ji_diag "ji_field requires a key argument"
    return 0
  fi
  if [ "$JI_HAVE_INPUT" -eq 0 ]; then
    ji_init
  fi
  _ji_field_impl "$1"
  printf '%s' "$JI_LAST"
}

# Public: ji_cwd — return cwd field normalized to a forward-slash absolute path.
# On Windows under Git Bash, cygpath -m converts MSYS paths to mixed/Windows paths
# usable by both bash and the underlying tooling. On macOS/Linux it's a no-op.
# If cygpath is unavailable, we still attempt a sed substitution of backslashes.
ji_cwd() {
  if [ "$JI_HAVE_INPUT" -eq 0 ]; then
    ji_init
  fi
  _ji_field_impl "cwd"
  local raw="$JI_LAST"
  if [ -z "$raw" ]; then
    return 0
  fi
  if command -v cygpath >/dev/null 2>&1; then
    # -m produces mixed (Windows-style with forward slashes), more portable for
    # downstream tools that may not understand POSIX paths on Windows.
    cygpath -m "$raw" 2>/dev/null || printf '%s' "$raw"
    return 0
  fi
  # Convert backslashes to forward slashes (still useful on Linux/macOS if someone
  # pastes a Windows path; harmless if there are no backslashes).
  printf '%s' "$raw" | sed 's/\\/\//g'
}
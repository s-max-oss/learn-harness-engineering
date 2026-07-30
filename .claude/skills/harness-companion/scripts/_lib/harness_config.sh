#!/bin/bash
# harness_config.sh — Load and validate .harness/config.json
#
# Usage:
#   source harness_config.sh
#   hc_load [project_dir]                # loads config; defaults to .
#                                         # Sets HC_LOADED=1, HC_CONFIG_DIR=<dir>
#                                         # and HC_TYPE=<node|python|typescript|generic>
#   hc_command_ids                       # lists verification command ids, one per line
#   hc_command_for <id>                  # echoes JSON for one command or empty
#   hc_applies <json-command>            # echoes "true" or "false" per applies_when
#   hc_required_ids                      # lists ids marked required_for_passing: true
#   hc_min_required                      # lists ids from verification.min_required_for_passing
#   hc_wip_limit                         # echoes integer wip_limit (default 1)
#   hc_allow_force                       # echoes "true" or "false"
#   hc_force_requires                    # echoes JSON object of required override fields
#
# The loader prefers jq and falls back to a minimal grep-based parser for project_type
# only (so we can decide which template to suggest). Anything beyond that returns empty
# and the caller is expected to fail closed.

set -euo pipefail

HC_LOADED=0
HC_CONFIG_DIR=""
HC_TYPE=""

# Resolve a JSON scalar string field, preferring jq.
_hc_jq_string() {
  local file="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" 'if (.[$k] | type) == "string" then .[$k] else empty end' "$file" 2>/dev/null
    return 0
  fi
  # Minimal fallback: only top-level string scalar fields.
  local pat="\"$key\":\""
  local rest
  rest="$(grep -o "\"$key\":\"[^\"]*\"" "$file" 2>/dev/null | head -1 || true)"
  if [ -z "$rest" ]; then
    return 0
  fi
  printf '%s' "$rest" | sed "s/\"$key\":\"//; s/\"$//"
}

_hc_jq_int() {
  local file="$1" key="$2" fallback="$3"
  if command -v jq >/dev/null 2>&1; then
    local v
    v="$(jq -r --arg k "$key" 'if (.[$k] | type) == "number" then (.[$k] | tostring) else empty end' "$file" 2>/dev/null || true)"
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  fi
  printf '%s' "$fallback"
}

hc_load() {
  local dir="${1:-.}"
  if [ ! -d "$dir" ]; then
    return 1
  fi
  HC_CONFIG_DIR="$(cd "$dir" && pwd)"

  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ]; then
    HC_LOADED=0
    HC_TYPE="generic"
    return 1
  fi

  HC_TYPE="$(_hc_jq_string "$cfg" project_type)"
  if [ -z "$HC_TYPE" ]; then
    HC_TYPE="generic"
  fi
  HC_LOADED=1
  return 0
}

# List command ids from verification.commands[].
# Returns nothing if jq is unavailable — callers must check command -v jq first.
hc_command_ids() {
  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ]; then
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -r '.verification.commands[]?.id // empty' "$cfg" 2>/dev/null
  fi
}

# Echo one command object as JSON. Empty if not found or jq unavailable.
hc_command_for() {
  local id="$1"
  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ]; then
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -c --arg id "$id" '.verification.commands[] | select(.id == $id)' "$cfg" 2>/dev/null
  fi
}

# Decide whether a command applies to the current project, by evaluating its
# applies_when clause. We support two predicate shapes:
#   { files_any: ["a", "b"] }     -> true if any of those files exists in HC_CONFIG_DIR
#   { package_json_has_script: "test" } -> true if package.json has that script
# If no applies_when is present, we default to true.
hc_applies() {
  local cmd_json="$1"
  if [ -z "$cmd_json" ]; then
    printf 'false'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'true'
    return 0
  fi
  local result
  result="$(printf '%s' "$cmd_json" | jq -r '
    .applies_when as $w |
    if ($w == null) then "true"
    else
      (
        (if ($w.files_any // null) != null then
            (any($w.files_any[]; . as $f | ($ENV.HC_CONFIG_DIR + "/" + $f) | test("^/") as $_ | true))
         else null end)
        // (if ($w.package_json_has_script // null) != null then
            ((env.HC_CONFIG_DIR + "/package.json") as $pj |
             (try ($pj | @text) catch "") | false)
         else null end)
        // "false"
      ) as $r |
      if $r == null then "true" else $r end
    ' env HC_CONFIG_DIR="$HC_CONFIG_DIR" 2>/dev/null || echo "false")"

  # jq's @text/env handling differs by version. The expression above is best-effort;
  # fall back to a pure-shell reimplementation for the two predicate shapes we support.
  if [ "$result" != "true" ] && [ "$result" != "false" ]; then
    local files_any has_script
    files_any="$(printf '%s' "$cmd_json" | jq -r '.applies_when.files_any // empty' 2>/dev/null || true)"
    has_script="$(printf '%s' "$cmd_json" | jq -r '.applies_when.package_json_has_script // empty' 2>/dev/null || true)"

    if [ -n "$files_any" ]; then
      local match=0
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        if [ -e "$HC_CONFIG_DIR/$f" ]; then
          match=1
          break
        fi
      done <<EOFILES
$files_any
EOFILES
      [ "$match" -eq 1 ] && result="true" || result="false"
    elif [ -n "$has_script" ]; then
      if [ -f "$HC_CONFIG_DIR/package.json" ] && grep -q "\"$has_script\"" "$HC_CONFIG_DIR/package.json" 2>/dev/null; then
        result="true"
      else
        result="false"
      fi
    else
      result="true"
    fi
  fi

  printf '%s' "$result"
}

hc_required_ids() {
  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  jq -r '.verification.commands[] | select(.required_for_passing == true) | .id' "$cfg" 2>/dev/null
}

hc_min_required() {
  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  jq -r '.verification.min_required_for_passing[]? // empty' "$cfg" 2>/dev/null
}

hc_wip_limit() {
  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ]; then
    printf '1'
    return 0
  fi
  _hc_jq_int "$cfg" wip_limit 1
}

hc_allow_force() {
  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ]; then
    printf 'true'
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    local v
    v="$(jq -r 'if (.feature_list.allow_force // true) == true then "true" else "false" end' "$cfg" 2>/dev/null || echo "true")"
    printf '%s' "$v"
    return 0
  fi
  printf 'true'
}

hc_force_requires() {
  local cfg="$HC_CONFIG_DIR/.harness/config.json"
  if [ ! -f "$cfg" ]; then
    printf '{"reason":true,"actor":true,"timestamp":true}'
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -c '.feature_list.force_requires // {reason:true, actor:true, timestamp:true}' "$cfg" 2>/dev/null || printf '{"reason":true,"actor":true,"timestamp":true}'
    return 0
  fi
  printf '{"reason":true,"actor":true,"timestamp":true}'
}
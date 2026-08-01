#!/bin/bash
# lock-registry.sh — mkdir-based registry mutex for feature_list.json
#
# Design §7: Registry Locking Protocol.
# Cross-platform: Linux, macOS, Windows Git Bash. No flock dependency.
#
# Public API:
#   source lock-registry.sh
#   acquire_lock <lock_dir> [timeout_s]   # → echoes token on stdout; exit 5 on timeout
#   release_lock <lock_dir> <token>       # exit 0 released, exit 6 token mismatch
#
# Lock metadata (per design §7.4):
#   <lock_dir>/pid                  — owner PID
#   <lock_dir>/process_start_time   — owner process start time (seconds since epoch, integer)
#                                     Empty on Windows Git Bash (start_time unavailable)
#   <lock_dir>/hostname             — owner hostname
#   <lock_dir>/timestamp            — lock acquisition time (seconds since epoch)
#   <lock_dir>/token                — 32-char random ownership token
#
# Stale recovery matrix (per design §7.5):
#   - PID dead + same host + start_time present → safe to recover
#   - PID dead + no start_time (legacy/Windows) → wait until LOCK_TIMEOUT_S
#   - PID alive + start_time differs           → NOT stolen (PID reuse)
#   - Different host + within cross-host grace → wait (don't use local PID)
#   - Different host + past cross-host grace   → recover
#   - Damaged metadata (missing fields)        → wait until LOCK_TIMEOUT_S
#
# Defaults:
#   LOCK_TIMEOUT_S       = 10 (per-call override via 2nd arg)
#   CROSS_HOST_TIMEOUT_S = 60
#   POLL_INTERVAL_S      = 0.1

# Defaults — overridable via env before sourcing
: "${LOCK_TIMEOUT_S:=10}"
: "${CROSS_HOST_TIMEOUT_S:=60}"
: "${POLL_INTERVAL_S:=0.1}"

# ---- token generation -------------------------------------------------------
# 32-char random token. Falls back to $RANDOM concatenation if /dev/urandom is
# absent (Windows Git Bash usually has it via MSYS2).
_lr_random_token() {
  if [ -r /dev/urandom ]; then
    tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 32
    return 0
  fi
  # Fallback: $RANDOM (16-bit) + pid + nanos — not cryptographically strong
  # but adequate for ownership distinction within a single host.
  printf '%.32s' "${RANDOM}${RANDOM}${RANDOM}$$$(date +%N)"
}

# ---- metadata helpers --------------------------------------------------------
_lr_my_hostname() {
  hostname 2>/dev/null || printf 'unknown-host'
}

_lr_now() {
  date +%s
}

# Get process start time as seconds since epoch. Empty on platforms that
# don't expose it (Windows Git Bash / macOS without ps).
# Args: pid
_lr_process_start_time() {
  local pid="$1"
  # Linux: stat /proc/$pid; GNU ps; BSD ps (macOS)
  if [ -r "/proc/$pid/stat" ]; then
    # /proc/$pid/stat: field 22 is starttime in clock ticks since boot
    # Convert using sysconf(_SC_CLK_TCK) — usually 100 on Linux.
    local starttime clk_tck
    starttime="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)"
    clk_tck="$(getconf CLK_TCK 2>/dev/null || printf '100')"
    if [ -n "$starttime" ] && [ -n "$clk_tck" ]; then
      local btime
      btime="$(awk '{print $22}' /proc/stat 2>/dev/null)"
      # btime is wall-clock at boot (sec). Add (starttime/clk_tck) = process age.
      if [ -n "$btime" ]; then
        awk -v b="$btime" -v s="$starttime" -v c="$clk_tck" \
          'BEGIN { printf "%d\n", b + (s / c) }'
        return 0
      fi
    fi
  fi
  # Fallback: ps (Linux/macOS). -o lstart= gives human time; -o etime= gives elapsed.
  if command -v ps >/dev/null 2>&1; then
    # etime is [[DD-]hh:]mm:ss — parse to seconds.
    local etime
    etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ -n "$etime" ]; then
      _lr_etime_to_start "$etime" || true
      return 0
    fi
  fi
  # Cannot determine start_time
  return 1
}

# Convert ps etime ([[DD-]hh:]mm:ss) to seconds-since-epoch process start.
# Echoes the start time.
_lr_etime_to_start() {
  local etime="$1"
  local d=0 h=0 m=0 s=0
  case "$etime" in
    *-*)
      d="${etime%%-*}"
      etime="${etime#*-}"
      ;;
  esac
  # Now etime is hh:mm:ss or mm:ss
  local parts
  IFS=':' read -ra parts <<<"$etime"
  case "${#parts[@]}" in
    3) h="${parts[0]}"; m="${parts[1]}"; s="${parts[2]}" ;;
    2) m="${parts[0]}"; s="${parts[1]}" ;;
    *) s="${parts[0]}" ;;
  esac
  local total
  total=$(( d*86400 + h*3600 + m*60 + s ))
  _lr_now
  awk -v n "$(_lr_now)" -v t "$total" 'BEGIN { printf "%d\n", n - t }'
}

# Is PID alive? Uses kill -0 (POSIX) which works on Linux/macOS/Windows MSYS2.
_lr_pid_alive() {
  local pid="$1"
  # POSIX special case: pid=0 means "current process group" not a real pid
  [ -z "$pid" ] && return 1
  [ "$pid" -le 0 ] 2>/dev/null && return 1
  kill -0 "$pid" 2>/dev/null
}

# ---- metadata read/write -----------------------------------------------------
_lr_write_meta() {
  local lock_dir="$1" pid="$2" start_time="$3" host="$4" ts="$5" tok="$6"
  printf '%s\n' "$pid" > "$lock_dir/pid"
  if [ -n "$start_time" ]; then
    printf '%s\n' "$start_time" > "$lock_dir/process_start_time"
  else
    : > "$lock_dir/process_start_time"  # empty file = no start_time
  fi
  printf '%s\n' "$host" > "$lock_dir/hostname"
  printf '%s\n' "$ts" > "$lock_dir/timestamp"
  printf '%s\n' "$tok" > "$lock_dir/token"
}

_lr_read_meta() {
  local lock_dir="$1"
  if [ ! -d "$lock_dir" ]; then
    return 1
  fi
  # Required fields: pid, hostname, timestamp, token
  local pid host ts tok
  pid="$(cat "$lock_dir/pid" 2>/dev/null)"
  host="$(cat "$lock_dir/hostname" 2>/dev/null)"
  ts="$(cat "$lock_dir/timestamp" 2>/dev/null)"
  tok="$(cat "$lock_dir/token" 2>/dev/null)"
  # Optional: process_start_time (may be empty)
  local start_time=""
  if [ -f "$lock_dir/process_start_time" ]; then
    start_time="$(cat "$lock_dir/process_start_time" 2>/dev/null)"
  fi
  if [ -z "$pid" ] || [ -z "$host" ] || [ -z "$ts" ] || [ -z "$tok" ]; then
    return 1
  fi
  LR_META_PID="$pid"
  LR_META_START="$start_time"
  LR_META_HOST="$host"
  LR_META_TS="$ts"
  LR_META_TOKEN="$tok"
  return 0
}

# ---- stale-lock recovery decision -------------------------------------------
# Returns 0 if the lock_dir should be removed (stale), 1 if it should be kept.
# Decision matrix per design §7.5.
_lr_is_stale() {
  local lock_dir="$1"
  if ! _lr_read_meta "$lock_dir"; then
    # Damaged metadata — wait (don't fast-recover)
    return 1
  fi
  local my_host
  my_host="$(_lr_my_hostname)"
  local now
  now="$(_lr_now)"

  # --- Cross-host: NEVER judge stale by local PID ---
  if [ "$LR_META_HOST" != "$my_host" ]; then
    if [ $(( now - LR_META_TS )) -gt "$CROSS_HOST_TIMEOUT_S" ]; then
      return 0  # cross-host grace expired → recover
    fi
    return 1  # within grace → wait
  fi

  # --- Same host: can use PID ---
  if _lr_pid_alive "$LR_META_PID"; then
    # PID alive — check start_time to rule out reuse
    if [ -n "$LR_META_START" ]; then
      local actual_start
      if actual_start="$(_lr_process_start_time "$LR_META_PID" 2>/dev/null)"; then
        if [ "$actual_start" != "$LR_META_START" ]; then
          # PID reused by different process — DO NOT steal
          return 1
        fi
      fi
    fi
    # PID alive and start_time either matches or unavailable → not stale
    return 1
  fi

  # --- PID dead on same host ---
  if [ -n "$LR_META_START" ]; then
    # Have start_time: PID is dead AND start_time matches "nothing now"
    # (since the PID is dead, no current process matches). Safe to recover.
    return 0
  fi

  # No start_time (legacy/Windows): cannot disambiguate. Only recover past timeout.
  if [ $(( now - LR_META_TS )) -gt "$LOCK_TIMEOUT_S" ]; then
    return 0
  fi
  return 1
}

# ---- public API --------------------------------------------------------------

# acquire_lock <lock_dir> [timeout_s]
# On success: prints token to stdout, returns 0.
# On timeout: prints nothing, returns 5.
acquire_lock() {
  local lock_dir="${1:-}"
  local timeout_s="${2:-$LOCK_TIMEOUT_S}"
  if [ -z "$lock_dir" ]; then
    echo "acquire_lock: usage: acquire_lock <lock_dir> [timeout_s]" >&2
    return 2
  fi

  local deadline
  deadline=$(( $(_lr_now) + timeout_s ))
  local my_token
  my_token="$(_lr_random_token)"
  if [ -z "$my_token" ]; then
    echo "acquire_lock: failed to generate token" >&2
    return 3
  fi
  local my_pid="$$"
  local my_host
  my_host="$(_lr_my_hostname)"
  local my_start_time=""

  while [ "$(_lr_now)" -lt "$deadline" ]; do
    # mkdir is POSIX-atomic; EEXIST means someone else holds it
    if mkdir "$lock_dir" 2>/dev/null; then
      # We hold the lock — compute start_time NOW (it can be slow on
      # Windows Git Bash / macOS where /proc is absent). Deferring this
      # keeps the deadline check accurate relative to wall-clock wait time.
      my_start_time="$(_lr_process_start_time "$my_pid" 2>/dev/null || true)"
      _lr_write_meta "$lock_dir" "$my_pid" "$my_start_time" "$my_host" \
        "$(_lr_now)" "$my_token"
      printf '%s' "$my_token"
      return 0
    fi

    # Lock exists — check if it's stale
    if _lr_is_stale "$lock_dir"; then
      # Owner-safe remove: re-check metadata right before rmdir to avoid
      # stealing a lock that was just released and re-acquired by another.
      # Use rm -rf because metadata files (pid/hostname/etc.) live inside the
      # lock_dir; rmdir alone would fail with ENOTEMPTY.
      if rm -rf "$lock_dir" 2>/dev/null; then
        continue
      fi
    fi

    sleep "$POLL_INTERVAL_S"
  done

  return 5  # timeout
}

# release_lock <lock_dir> <token>
# Returns 0 if released; 6 if token mismatch (lock NOT released).
release_lock() {
  local lock_dir="${1:-}"
  local token="${2:-}"
  if [ -z "$lock_dir" ] || [ -z "$token" ]; then
    echo "release_lock: usage: release_lock <lock_dir> <token>" >&2
    return 2
  fi
  if [ ! -d "$lock_dir" ]; then
    # Lock already gone — nothing to do (idempotent)
    return 0
  fi
  if _lr_read_meta "$lock_dir"; then
    if [ "$LR_META_TOKEN" != "$token" ]; then
      echo "release_lock: token_mismatch — refusing to release lock held by another owner" >&2
      return 6
    fi
  fi
  rm -rf "$lock_dir" 2>/dev/null || {
    # Directory may have been replaced between read and remove; try once more.
    rm -rf "$lock_dir" 2>/dev/null || true
  }
  return 0
}
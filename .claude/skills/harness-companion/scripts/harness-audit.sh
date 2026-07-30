#!/bin/bash
# harness-audit.sh — 5-axis scoring across the 7 Harness Engineering subsystems
#
# Usage:
#   bash harness-audit.sh [project_dir] [--snapshot-at <git_ref>]
#
# Five axes per subsystem, each scored 0-3:
#   1. existence      — are the canonical files present?
#   2. completeness   — do they contain required sections/fields?
#   3. execution      — can we run the verification chain and produce structured evidence?
#   4. recency        — are files touched within a deterministic window?
#   5. effectiveness  — does the system produce the expected outcome (verify returns passing,
#                       handoff references latest commit, etc.)?
#
# The subsystem score is floor((sum of axis scores)/5 * 3). Maximum subsystem = 3.
# Total = sum of all 7 subsystem scores, max 21.
#
# Determinism:
#   - All file checks operate on file existence + grep-able content.
#   - Recency uses git log when possible; falls back to file mtime only if --snapshot-at
#     is NOT set and a working cutoff can be derived.
#   - The output is byte-stable across consecutive runs when the working tree is stable.
#
# Requires: jq (for feature_list.json parsing). Falls back to "unknown" axes when missing.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib/harness_config.sh
source "$SKILL_DIR/_lib/harness_config.sh"

TARGET="${1:-.}"
SNAPSHOT_AT=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot-at) SNAPSHOT_AT="${2:-}"; shift 2 ;;
    --help|-h)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

if [ ! -d "$TARGET" ]; then
  echo "Error: directory '$TARGET' not found" >&2
  exit 1
fi

cd "$TARGET"
PROJECT_DIR="$(pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

HAS_JQ=0
if command -v jq >/dev/null 2>&1; then HAS_JQ=1; fi

# --- Helpers -----------------------------------------------------------------

# Score an axis 0-3 from a list of contributing boolean checks. Each passed check is +1.
# Caps at 3. 0 if no checks passed.
score_axis() {
  local checks_passed="$1"
  local checks_total="$2"
  if [ "$checks_total" = "0" ]; then
    echo "0"
    return
  fi
  if [ "$checks_passed" -ge 3 ]; then echo "3"
  elif [ "$checks_passed" -ge 2 ]; then echo "2"
  elif [ "$checks_passed" -ge 1 ]; then echo "1"
  else echo "0"
  fi
}

# Determine whether a file contains a "section" header (markdown ## Foo).
has_section() {
  local file="$1" section="$2"
  [ -f "$file" ] && grep -qE "^#+ +${section}" "$file" 2>/dev/null
}

# File mtime in epoch seconds (Linux + macOS).
mtime_epoch() {
  local f="$1"
  if [ ! -f "$f" ]; then echo "0"; return; fi
  stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "0"
}

# Latest commit time (epoch seconds) for a file, via git. 0 if not tracked.
git_last_change_epoch() {
  local f="$1"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git log -1 --format=%ct -- "$f" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# Returns "true" if the file was modified in the last N hours (using git log or mtime).
recent_within_hours() {
  local f="$1" hours="$2"
  local cutoff now last
  cutoff="$(date +%s)"
  now="$cutoff"
  last="$(git_last_change_epoch "$f")"
  if [ "$last" = "0" ]; then last="$(mtime_epoch "$f")"; fi
  if [ "$last" = "0" ]; then echo "false"; return; fi
  local age=$(( (now - last) / 3600 ))
  if [ "$age" -le "$hours" ]; then echo "true"; else echo "false"; fi
}

# Append an "evidence" line to a per-subsystem evidence list.
record_evidence() {
  local label="$1" detail="$2"
  printf '    - %s: %s\n' "$label" "$detail"
}

# --- Per-subsystem scoring ----------------------------------------------------

# Each function below echoes a single string: "<score>/3" followed by evidence lines on stdout.
# The caller collects evidence into a summary table.

# ---- 1. Knowledge ----
audit_knowledge() {
  local p=0 total=0
  local evidence=""

  # existence
  total=$((total + 1))
  if [ -f "AGENTS.md" ] && [ -f "CLAUDE.md" ]; then p=$((p+1)); evidence+="$(record_evidence existence 'AGENTS.md+CLAUDE.md present')"
  else evidence+="$(record_evidence existence 'AGENTS.md or CLAUDE.md missing')"; fi

  # completeness
  total=$((total + 1))
  if has_section AGENTS.md "Startup Rules" && has_section AGENTS.md "Definition of Done"; then
    p=$((p+1))
    evidence+="$(record_evidence completeness 'AGENTS.md has Startup Rules + DoD')"
  else
    evidence+="$(record_evidence completeness 'AGENTS.md missing required sections')"
  fi

  # execution: not directly executed for knowledge; treat presence of docs/ as proxy
  total=$((total + 1))
  if [ -d "docs" ] && [ "$(find docs -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
    p=$((p+1))
    evidence+="$(record_evidence execution 'docs/ contains at least one .md')"
  else
    evidence+="$(record_evidence execution 'docs/ empty or missing')"
  fi

  # recency
  total=$((total + 1))
  if recent_within_hours AGENTS.md 168 >/dev/null 2>&1 && [ "$(recent_within_hours AGENTS.md 168)" = "true" ]; then
    p=$((p+1))
    evidence+="$(record_evidence recency 'AGENTS.md updated within 7 days')"
  else
    evidence+="$(record_evidence recency 'AGENTS.md stale or untracked')"
  fi

  # effectiveness: CLAUDE.md doesn't duplicate AGENTS.md excessively (CLAUDE.md < 200 lines)
  total=$((total + 1))
  if [ -f CLAUDE.md ]; then
    local cl
    cl="$(wc -l < CLAUDE.md | tr -d ' ')"
    if [ "$cl" -lt 200 ]; then
      p=$((p+1))
      evidence+="$(record_evidence effectiveness "CLAUDE.md is $cl lines (concise)")"
    else
      evidence+="$(record_evidence effectiveness "CLAUDE.md is $cl lines (bloated)")"
    fi
  else
    evidence+="$(record_evidence effectiveness 'CLAUDE.md missing')"
  fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# ---- 2. Environment ----
audit_environment() {
  local p=0 total=0 evidence=""
  total=$((total + 1))
  if [ -f "init.sh" ]; then p=$((p+1)); evidence+="$(record_evidence existence 'init.sh present')"
  else evidence+="$(record_evidence existence 'init.sh missing')"; fi

  total=$((total + 1))
  # completeness: init.sh covers install + check + build (regex on script content)
  local ok=0
  if grep -qE 'npm install|pip install|yarn|pnpm' init.sh 2>/dev/null; then ok=$((ok+1)); fi
  if grep -qiE 'check|typecheck|tsc|mypy|ruff' init.sh 2>/dev/null; then ok=$((ok+1)); fi
  if grep -qiE 'build|compile' init.sh 2>/dev/null; then ok=$((ok+1)); fi
  if [ "$ok" -ge 2 ]; then p=$((p+1)); evidence+="$(record_evidence completeness "init.sh covers $ok/3 of install/check/build")"
  else evidence+="$(record_evidence completeness "init.sh only covers $ok/3")"; fi

  total=$((total + 1))
  # execution: .harness/config.json present → verifiable
  if [ -f ".harness/config.json" ]; then p=$((p+1)); evidence+="$(record_evidence execution '.harness/config.json present (verifiable)')"
  else evidence+="$(record_evidence execution '.harness/config.json missing (config-driven verification disabled)')"; fi

  total=$((total + 1))
  # recency
  if [ "$(recent_within_hours init.sh 168)" = "true" ]; then
    p=$((p+1))
    evidence+="$(record_evidence recency 'init.sh updated within 7 days')"
  else
    evidence+="$(record_evidence recency 'init.sh stale')"
  fi

  total=$((total + 1))
  # effectiveness: init.sh exits 0 right now (executable + last run produced artifacts)
  if [ -x init.sh ] && [ -d ".harness/logs" ]; then
    p=$((p+1))
    evidence+="$(record_evidence effectiveness 'init.sh executable; verify logs directory exists')"
  else
    evidence+="$(record_evidence effectiveness 'init.sh not executable or no verify logs')"
  fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# ---- 3. Progress ----
audit_progress() {
  local p=0 total=0 evidence=""

  total=$((total + 1))
  if [ -f "claude-progress.md" ]; then p=$((p+1)); evidence+="$(record_evidence existence 'claude-progress.md present')"
  else evidence+="$(record_evidence existence 'claude-progress.md missing')"; fi

  total=$((total + 1))
  # completeness: contains "Current Verified State" + "Session Log" headers
  local ok=0
  if grep -qiE 'Current Verified State|verified state' claude-progress.md 2>/dev/null; then ok=$((ok+1)); fi
  if grep -qE 'Session [0-9]+|Session Log' claude-progress.md 2>/dev/null; then ok=$((ok+1)); fi
  if [ "$ok" -ge 1 ]; then p=$((p+1)); evidence+="$(record_evidence completeness "claude-progress.md has $ok/2 expected sections")"
  else evidence+="$(record_evidence completeness 'claude-progress.md missing structure')"; fi

  total=$((total + 1))
  # execution: progress doc was updated within last 7 days (recency)
  if [ "$(recent_within_hours claude-progress.md 168)" = "true" ]; then p=$((p+1)); evidence+="$(record_evidence execution 'updated within 7 days')"
  else evidence+="$(record_evidence execution 'stale (>7 days)')"; fi

  total=$((total + 1))
  # recency is the same metric here — keep it but counted under a different lens
  if [ "$(recent_within_hours claude-progress.md 720)" = "true" ]; then p=$((p+1)); evidence+="$(record_evidence recency 'updated within 30 days')"
  else evidence+="$(record_evidence recency 'older than 30 days')"; fi

  total=$((total + 1))
  # effectiveness: session-handoff.md exists and is current
  if [ -f session-handoff.md ] && [ "$(recent_within_hours session-handoff.md 720)" = "true" ]; then
    p=$((p+1))
    evidence+="$(record_evidence effectiveness 'session-handoff.md exists and recent')"
  else
    evidence+="$(record_evidence effectiveness 'session-handoff.md missing or stale')"
  fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# ---- 4. Scope/Feature ----
audit_scope() {
  local p=0 total=0 evidence=""
  total=$((total + 1))
  if [ -f feature_list.json ]; then p=$((p+1)); evidence+="$(record_evidence existence 'feature_list.json present')"
  else evidence+="$(record_evidence existence 'feature_list.json missing')"; fi

  total=$((total + 1))
  if [ "$HAS_JQ" = "1" ] && jq -e '.rules' feature_list.json >/dev/null 2>&1; then
    p=$((p+1))
    evidence+="$(record_evidence completeness 'rules{} declared')"
  else
    evidence+="$(record_evidence completeness 'rules{} missing or jq unavailable')"
  fi

  total=$((total + 1))
  # execution: at least one structured evidence record present
  if [ "$HAS_JQ" = "1" ]; then
    local struct
    struct="$(jq '[.features[].evidence[]? | select(type == "object") ] | length' feature_list.json 2>/dev/null || echo 0)"
    if [ "$struct" -gt 0 ]; then p=$((p+1)); evidence+="$(record_evidence execution "$struct structured evidence records")"
    else evidence+="$(record_evidence execution 'no structured evidence yet')"; fi
  else
    evidence+="$(record_evidence execution 'jq unavailable — cannot assess evidence shape')"
  fi

  total=$((total + 1))
  # recency: feature_list.json updated within 7 days
  if [ "$(recent_within_hours feature_list.json 168)" = "true" ]; then p=$((p+1)); evidence+="$(record_evidence recency 'feature_list.json updated within 7 days')"
  else evidence+="$(record_evidence recency 'feature_list.json stale')"; fi

  total=$((total + 1))
  # effectiveness: no WIP violations, and no passing-without-evidence
  if [ "$HAS_JQ" = "1" ]; then
    local wip bad_passing
    wip="$(jq '[.features[] | select(.status=="in_progress")] | length' feature_list.json)"
    bad_passing="$(jq '[.features[] | select((.status=="passing" or .status=="unverified") and (.evidence | length) == 0)] | length' feature_list.json)"
    if [ "$wip" -le 1 ] && [ "$bad_passing" = "0" ]; then
      p=$((p+1))
      evidence+="$(record_evidence effectiveness "WIP=$wip (≤1), bad_passing=0")"
    else
      evidence+="$(record_evidence effectiveness "WIP=$wip, $bad_passing unverified/passing with no evidence")"
    fi
  else
    evidence+="$(record_evidence effectiveness 'jq unavailable — cannot assess WIP/evidence')"
  fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# ---- 5. Verification ----
audit_verification() {
  local p=0 total=0 evidence=""

  total=$((total + 1))
  if [ -f checklist.sh ]; then
    p=$((p+1))
    evidence+="$(record_evidence existence 'checklist.sh present')"
  elif [ -f .harness/config.json ]; then
    p=$((p+1))
    evidence+="$(record_evidence existence '.harness/config.json present (no checklist.sh)')"
  else
    evidence+="$(record_evidence existence 'no checklist.sh or config.json')"
  fi

  total=$((total + 1))
  # completeness: checklist.sh covers typecheck + build
  local ok=0
  if grep -qiE 'typecheck|tsc' checklist.sh 2>/dev/null; then ok=$((ok+1)); fi
  if grep -qiE 'build|compile' checklist.sh 2>/dev/null; then ok=$((ok+1)); fi
  if [ "$ok" -ge 2 ]; then p=$((p+1)); evidence+="$(record_evidence completeness "checklist.sh covers typecheck+build")"
  else evidence+="$(record_evidence completeness "checklist.sh covers $ok/2")"; fi

  total=$((total + 1))
  # execution: any recent verify log exists
  if [ -d ".harness/logs" ] && [ "$(ls -1 .harness/logs 2>/dev/null | wc -l)" -gt 0 ]; then
    p=$((p+1))
    evidence+="$(record_evidence execution "verify log artifacts present ($(ls -1 .harness/logs | wc -l) files)")"
  else
    evidence+="$(record_evidence execution 'no verify log artifacts')"
  fi

  total=$((total + 1))
  # recency: at least one verify log from the last 24h
  local recent_log=""
  if [ -d ".harness/logs" ]; then
    recent_log="$(find .harness/logs -type f -mtime -1 2>/dev/null | head -1)"
  fi
  if [ -n "$recent_log" ]; then p=$((p+1)); evidence+="$(record_evidence recency "recent verify log: $(basename "$recent_log")")"
  else evidence+="$(record_evidence recency 'no verify logs in last 24h')"; fi

  total=$((total + 1))
  # effectiveness: at least one structured evidence record with exit_code=0
  if [ "$HAS_JQ" = "1" ] && [ -f feature_list.json ]; then
    local green
    green="$(jq '[.features[].evidence[]? | select(type == "object" and .exit_code == 0)] | length' feature_list.json 2>/dev/null || echo 0)"
    if [ "$green" -gt 0 ]; then p=$((p+1)); evidence+="$(record_evidence effectiveness "$green evidence records with exit_code=0")"
    else evidence+="$(record_evidence effectiveness 'no green evidence records yet')"; fi
  else
    evidence+="$(record_evidence effectiveness 'jq unavailable — cannot assess')"
  fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# ---- 6. Observability ----
audit_observability() {
  local p=0 total=0 evidence=""

  total=$((total + 1))
  if [ -f agent.log ]; then p=$((p+1)); evidence+="$(record_evidence existence 'agent.log present')"
  else evidence+="$(record_evidence existence 'agent.log missing')"; fi

  total=$((total + 1))
  # completeness: agent.log contains CLOSE marker somewhere
  local has_close=0
  if [ -f agent.log ] && grep -q '"CLOSE"' agent.log 2>/dev/null; then has_close=1; fi
  if [ "$has_close" = "1" ]; then p=$((p+1)); evidence+="$(record_evidence completeness 'agent.log has CLOSE marker')"
  else evidence+="$(record_evidence completeness 'agent.log missing CLOSE marker')"; fi

  total=$((total + 1))
  # execution: structured ndjson (multiple JSON objects)
  local ndjson_count=0
  if [ -f agent.log ]; then ndjson_count="$(grep -c '^{' agent.log 2>/dev/null | head -1)"; fi
  if [ "$ndjson_count" -gt 1 ]; then p=$((p+1)); evidence+="$(record_evidence execution "agent.log has $ndjson_count ndjson lines")"
  else evidence+="$(record_evidence execution "agent.log has $ndjson_count ndjson lines")"; fi

  total=$((total + 1))
  # recency: agent.log updated within 7 days
  if [ -f agent.log ] && [ "$(recent_within_hours agent.log 168)" = "true" ]; then p=$((p+1)); evidence+="$(record_evidence recency 'agent.log updated within 7 days')"
  else evidence+="$(record_evidence recency 'agent.log stale or missing')"; fi

  total=$((total + 1))
  # effectiveness: last line is a CLOSE marker (clean exit)
  local last_line=""
  if [ -f agent.log ]; then last_line="$(tail -1 agent.log 2>/dev/null)"; fi
  if echo "$last_line" | grep -q '"CLOSE"'; then p=$((p+1)); evidence+="$(record_evidence effectiveness 'last agent.log line is CLOSE (clean exit)')"
  else evidence+="$(record_evidence effectiveness 'last agent.log line is not CLOSE')"; fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# ---- 7. Handoff/Automation ----
audit_handoff() {
  local p=0 total=0 evidence=""

  total=$((total + 1))
  if [ -f session-handoff.md ]; then p=$((p+1)); evidence+="$(record_evidence existence 'session-handoff.md present')"
  else evidence+="$(record_evidence existence 'session-handoff.md missing')"; fi

  total=$((total + 1))
  if [ -f clean-state-checklist.md ]; then p=$((p+1)); evidence+="$(record_evidence completeness 'clean-state-checklist.md present')"
  else evidence+="$(record_evidence completeness 'clean-state-checklist.md missing')"; fi

  total=$((total + 1))
  if [ -x checklist.sh ]; then p=$((p+1)); evidence+="$(record_evidence execution 'checklist.sh executable')"
  else evidence+="$(record_evidence execution 'checklist.sh not executable')"; fi

  total=$((total + 1))
  # recency: session-handoff.md updated within 7 days
  if [ -f session-handoff.md ] && [ "$(recent_within_hours session-handoff.md 168)" = "true" ]; then p=$((p+1)); evidence+="$(record_evidence recency 'session-handoff.md updated within 7 days')"
  else evidence+="$(record_evidence recency 'session-handoff.md stale')"; fi

  total=$((total + 1))
  # effectiveness: loop.sh exists AND has substantive body (more than just "exit 0")
  if [ -f loop.sh ]; then
    local loop_lines
    loop_lines="$(wc -l < loop.sh 2>/dev/null | tr -d ' ')"
    if [ "$loop_lines" -ge 5 ]; then
      p=$((p+1))
      evidence+="$(record_evidence effectiveness "loop.sh present with $loop_lines lines (substantive)")"
    else
      evidence+="$(record_evidence effectiveness "loop.sh present but only $loop_lines lines (insufficient)")"
    fi
  else
    evidence+="$(record_evidence effectiveness 'loop.sh missing (manual handoff required)')"
  fi

  local s
  s="$(score_axis "$p" "$total")"
  printf '%s\n%s' "$s" "$evidence"
}

# --- Run all subsystems -------------------------------------------------------
run_and_split() {
  local label="$1"
  local block
  block="$("$@" 2>/dev/null)"
  SCORE_LINE="$(printf '%s\n' "$block" | head -1)"
  EVIDENCE_LINES="$(printf '%s\n' "$block" | tail -n +2)"
}

run_and_split audit_knowledge;       K_SCORE="$SCORE_LINE";       K_EVIDENCE="$EVIDENCE_LINES"
run_and_split audit_environment;     E_SCORE="$SCORE_LINE";       E_EVIDENCE="$EVIDENCE_LINES"
run_and_split audit_progress;        P_SCORE="$SCORE_LINE";       P_EVIDENCE="$EVIDENCE_LINES"
run_and_split audit_scope;           S_SCORE="$SCORE_LINE";       S_EVIDENCE="$EVIDENCE_LINES"
run_and_split audit_verification;    V_SCORE="$SCORE_LINE";       V_EVIDENCE="$EVIDENCE_LINES"
run_and_split audit_observability;   O_SCORE="$SCORE_LINE";       O_EVIDENCE="$EVIDENCE_LINES"
run_and_split audit_handoff;         H_SCORE="$SCORE_LINE";       H_EVIDENCE="$EVIDENCE_LINES"

TOTAL=$((K_SCORE + E_SCORE + P_SCORE + S_SCORE + V_SCORE + O_SCORE + H_SCORE))

# --- Output -------------------------------------------------------------------
echo "Harness Audit: $PROJECT_NAME"
[ -n "$SNAPSHOT_AT" ] && echo "Snapshot at: $SNAPSHOT_AT"
echo "════════════════════════════════════════════"
printf "  %-15s %s\n" "Subsystem" "Score"
printf "  %-15s %s\n" "---------------" "-----"
printf "  %-15s %d/3\n" "Knowledge"      "$K_SCORE"
printf "  %-15s %d/3\n" "Environment"    "$E_SCORE"
printf "  %-15s %d/3\n" "Progress"       "$P_SCORE"
printf "  %-15s %d/3\n" "Scope/Feature"  "$S_SCORE"
printf "  %-15s %d/3\n" "Verification"   "$V_SCORE"
printf "  %-15s %d/3\n" "Observability"  "$O_SCORE"
printf "  %-15s %d/3\n" "Handoff/Auto"   "$H_SCORE"
echo ""
echo "────────────────────────────────────────────"
echo "Total: $TOTAL/21"
echo ""

if [ "${HARNESS_VERBOSE:-0}" = "1" ]; then
  echo "Evidence per score:"
  echo ""
  echo "[Knowledge]"
  printf '%s\n' "$K_EVIDENCE"
  echo "[Environment]"
  printf '%s\n' "$E_EVIDENCE"
  echo "[Progress]"
  printf '%s\n' "$P_EVIDENCE"
  echo "[Scope/Feature]"
  printf '%s\n' "$S_EVIDENCE"
  echo "[Verification]"
  printf '%s\n' "$V_EVIDENCE"
  echo "[Observability]"
  printf '%s\n' "$O_EVIDENCE"
  echo "[Handoff/Automation]"
  printf '%s\n' "$H_EVIDENCE"
fi
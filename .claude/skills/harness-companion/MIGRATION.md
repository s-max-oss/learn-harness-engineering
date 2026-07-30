# MIGRATION: harness-companion v0 → v1

v1 is a **reliability-first refactor**. The user-facing commands haven't moved,
but several internal contracts changed. This document explains what broke,
why it was wrong, and how to migrate.

## TL;DR for users

If you only use `/harness:init`, `/harness:status`, `/harness:handoff` — nothing
in your workflow changes.

If you use `/harness:verify` or `/harness:feature`:

1. Install `jq` if you don't have it (the script refuses to run without it now).
2. Drop a `.harness/config.json` into any project where you ran `/harness:verify`
   before — copy `templates/.harness/config.json.node.example` (or the matching
   `.python`/`.generic` one) and edit the `verification.commands[]` list.
3. Any `feature_list.json` whose `evidence[]` contains free-text strings
   (instead of structured objects) will be rejected on promotion to `passing`.
   Re-run `/harness:verify` to regenerate proper evidence.

## Compatibility matrix

| Surface | v0 | v1 | Backward-compatible? |
|---|---|---|---|
| `/harness:init` | Templates copied to project root | Same | ✅ yes |
| `/harness:status` | Dashboard | Same (script deferred-v2) | ✅ yes |
| `/harness:feature list` | Table dump | Same | ✅ yes |
| `/harness:feature add` | Append feature | Same | ✅ yes |
| `/harness:feature status` | Free status update | Strict state machine | ⚠️ invalid transitions now refused |
| `/harness:verify` | Hardcoded `npx tsc` / `npm test` chain | Config-driven from `.harness/config.json` | ❌ requires config |
| `/harness:handoff` | Handoff doc generator | Same | ✅ yes |
| `/harness:audit` | File presence score | 5-axis score (existence/completeness/execution/recency/effectiveness) | ⚠️ scores not comparable |
| `SessionStart` hook | Often crashed on empty stdin | Always emits `{"continue":true,…}` | ✅ yes (better) |
| `Stop` hook | Demanded "commit all" | Warns but doesn't demand | ✅ yes (better) |
| Evidence format | String array | Structured object array | ❌ incompatible |

## Breaking changes

### 1. `harness-verify.sh` requires `.harness/config.json`

**v0**: Ran `npx tsc --noEmit` → `npm run build` → `npm test`. If you had a
Python project, the first step still ran (and failed with `tsc not found`).

**v1**: Loads `.harness/config.json`. Iterates `verification.commands[]`,
evaluating each command's `applies_when` predicate before running it. Python
projects run only their `pytest` / `ruff` / `mypy` chain. Node projects run
only their `tsc` / `build` / `test` chain. Generic projects get whatever the
config says.

**Migration**: Copy `templates/.harness/config.json.{node,python,generic}.example`
to `.harness/config.json` in each project. Edit the `command[]` arrays to
match your real scripts.

**Exit codes changed**:

| v0 | v1 | Meaning |
|---|---|---|
| 0 | 0 | All required commands passed |
| 1 | 1 | A required command failed |
| (silent) | 2 | Not configured (no config or no jq) |
| (silent) | 3 | Passes but evidence refs a different commit than HEAD (stale) |

### 2. Evidence records are structured objects

**v0**: Evidence was a list of free-text strings like `"2026-07-27: tests passed (42/42)"`.
The state machine only checked that the list was non-empty.

**v1.1**: Evidence is a list of JSON objects:

```json
{
  "id": "typecheck",
  "command": ["npx", "tsc", "--noEmit"],
  "exit_code": 0,
  "started_at": "2026-07-27T10:00:00Z",
  "duration_ms": 12400,
  "commit": "abc1234",
  "working_tree_state": "clean",
  "summary": "command typecheck exited 0",
  "log_artifact": ".harness/logs/verify-typecheck-20260727T100000Z.log",
  "log_sha256": "6dcd4ce23d88e..."
}
```

Promoting a feature to `passing` now requires:
1. **Structured evidence** — string records (v0 format) are rejected
2. **All passing** — every evidence record must have `exit_code: 0`
3. **Current HEAD** — the latest `evidence[-1].commit` must match the current HEAD
4. **Full coverage** — evidence must cover every command where `required_for_passing != false`

The script `harness-verify.sh` writes them; `harness-feature.sh` refuses to
honor incomplete or stale evidence.

**Migration**: Re-run `/harness:verify --write` for any feature whose
`evidence[]` is empty or contains only strings. Old strings can stay in the
array for historical reference but won't count toward `passing`.

### 3. Feature state machine is explicit

**v0**: `harness-feature.sh status <id> <new_status>` accepted any status change.
No transition table. No override requirement. WIP limit was warned about, not
enforced.

**v1**: Strict state machine. See `references/feature-state-machine.md` for the
full table. Highlights:

- Promoting to `passing` without evidence is refused (with a suggestion to run
  `/harness:verify` first or use `--override`).
- `--override "<reason>"` is required to set `unverified` and is recorded as
  an audit object on the feature (`override.by`, `override.at`, `override.reason`,
  `override.missing_evidence[]`).
- WIP=1 is enforced (configurable via `feature_list.wip_limit`).

**Migration**: If you have a workflow that depends on jumping straight to
`passing` without evidence, use `unverified --override "<reason>"` instead.
That's the audit-bypass path; the audit script will flag the feature for
re-review.

### 4. `/harness:audit` scores differently

**v0**: Score = (number of files present) / (number of files expected). High
score was easy: drop 8 files in the root.

**v1**: Score = floor((passed_checks / total_checks) × 3) per subsystem, where
checks are spread across 5 axes:

- **existence** — files present
- **completeness** — content has required sections/fields
- **execution** — verification chain runs and produces structured evidence
- **recency** — files touched within a deterministic window
- **effectiveness** — system produces the expected outcome

A perfect-execution empty-project can no longer score 3 on Knowledge.

**Migration**: Don't compare v0 scores to v1 scores. Re-baseline your project
and treat v1 scores as the new ground truth. Output is byte-deterministic
across consecutive runs, so trends over time are meaningful.

## Soft improvements

### 5. Hooks no longer crash

**v0**: `set -euo pipefail` killed hooks on empty stdin, missing `cwd`, or
Windows-style paths. The host saw exit 1 with no output — looked like a
harness bug.

**v1**: `scripts/_lib/json_input.sh` tries `jq` → `python3` → guarded substring
parser. Any error path returns `{"continue":true,"suppressOutput":true}` via a
`trap` on `ERR`. Output uses ASCII markers instead of emoji so Git Bash on
Windows doesn't mangle UTF-16 surrogate pairs.

### 6. Atomic writes everywhere

**v0**: `feature_list.json` was rewritten in place via `jq … > feature_list.json`.
A crash mid-write truncated the file.

**v1**: `scripts/_lib/atomic_write.sh` writes to `mktemp` then `mv -f` over
the target. Crash mid-write leaves the previous version intact.

### 7. No "no-op = pass"

**v0**: If `npx tsc` was missing and the fallback path returned 0, the script
recorded a passing step with empty evidence. The feature flipped to `passing`.

**v1**: The verify script exits 2 with an install hint if `jq` is missing.
If a `command[]` references a missing binary, that step records `exit_code: 127`
(not 0) and the feature does NOT flip to `passing`. There is no silent
fallback path.

## Residual risk

These are known v1 limitations tracked for v2:

| Risk | Why we shipped anyway | Mitigation in v2 (planned) |
|---|---|---|
| `harness-status.sh` aborts on first missing file (still v0 code) | Out of scope for the verify/feature/audit/hooks refactor | Rewrite to `set +e`, render all sections regardless of file presence |
| `python3` JSON fallback in hooks is GBK-encoded on Windows Python <3.6 | Affects <0.1% of hosts | Use `encoding='utf-8'` explicitly; future lint will catch this |
| Audit recency window is fixed at 168h (7d) for most files | Single global threshold is too coarse for slow projects (e.g. docs that change monthly) | Per-subsystem `recency_window_hours` config |
| WIP limit can only be configured in `.harness/config.json`, not per-feature | Multi-team repos with different cadences need per-feature override | `feature_list.wip_limit_overrides` keyed by `area` |
| No structured evidence query ("which features have evidence older than 30d?") | Reports are flat | Add `harness-evidence.sh list --older-than 30d` |
| `MIGRATION.md` migration script not yet shipped | Manual steps are short (one config file, one re-run) | `bash harness-migrate.sh` to copy the right example config based on detected project type |

## How to upgrade

```bash
# In your project root:
cp ~/.claude/skills/harness-companion/templates/.harness/config.json.node.example \
   .harness/config.json

# Edit .harness/config.json — at minimum, replace the placeholder commands with
# your actual typecheck/build/test commands. Each entry's `command[]` is an argv
# array; use `command[]` not `command` to avoid quoting bugs.

# Re-verify any feature that was previously marked passing on string evidence:
bash ~/.claude/skills/harness-companion/scripts/harness-verify.sh <feature-id> . --write

# Re-audit to get your v1 baseline score:
bash ~/.claude/skills/harness-companion/scripts/harness-audit.sh .
```

## Self-test the upgrade

After upgrading, run the skill's own test suite to confirm everything still
works in your environment:

```bash
bash ~/.claude/skills/harness-companion/tests/run-all.sh
```

Expected on a host WITH `jq`:

```
Passed:   ~70
Failed:   0
Skipped:  0
Deferred: 0
```

Expected on a host WITHOUT `jq`:
— not supported: `jq` is mandatory. Install it first.

If you see anything other than `Failed: 0`, file a bug — that means the new
contract isn't holding somewhere we didn't anticipate.
# harness-companion v2 通用化升级 — Implementation Plan

> 基于: `docs/superpowers/specs/2026-07-31-harness-companion-generalization-design.md` v5（Approved）
> 日期: 2026-07-31

---

## Phase Overview

| Phase | Name | Scope | Est. Risk |
|-------|------|-------|-----------|
| **Phase 1** | Core Refactor | Canonical evidence model + validate_run_log + workspace fingerprint + passing eligibility | Medium |
| **Phase 2** | Registry & Locking | Feature registry schema + locking protocol + atomic write hardening | Medium |
| **Phase 3** | Adapter: Claude Code | Refactor hooks to Core/Adapter architecture + contract tests | Low |
| **Phase 4** | Adapter: Codex | New adapter (install, hooks, templates) + contract tests | High |
| **Phase 5** | Integration & Migration | End-to-end tests, v1.1.2→v2 migration tooling, documentation | Medium |

---

## Phase 1: Core Refactor

### Goal
Establish the canonical evidence model (per-run NDJSON log), `validate_run_log()`, workspace fingerprint, and updated passing eligibility — all as shared core libraries consumed by both adapters.

### Implementation Steps

#### 1.1 Directory Scaffold

```
.claude/skills/harness-companion/
├── core/
│   └── lib/
│       ├── evidence.sh
│       ├── validate-run-log.sh
│       ├── workspace-fingerprint.sh
│       ├── passing.sh
│       ├── staleness.sh
│       ├── lock-registry.sh
│       ├── atomic-write.sh
│       └── json-helpers.sh
├── core/
│   ├── harness-verify.sh
│   ├── harness-feature.sh
│   ├── harness-status.sh
│   └── harness-audit.sh
├── adapters/
│   ├── claude-code/
│   │   ├── hooks/
│   │   ├── templates/
│   │   ├── install.sh
│   │   └── adapter.conf
│   └── codex/
│       ├── hooks/
│       ├── templates/
│       ├── install.sh
│       └── adapter.conf
├── templates/
├── tests/
│   ├── core/
│   ├── adapters/
│   └── golden/
└── VERSION
```

**Files to move** (from current flat `scripts/` into `core/lib/`):
- `scripts/_lib/atomic_write.sh` → `core/lib/atomic-write.sh`
- `scripts/_lib/json_input.sh` → `core/lib/json-helpers.sh`
- `scripts/_lib/harness_config.sh` → `core/lib/harness-config.sh`
- `scripts/_lib/baseline.sh` → `core/lib/baseline.sh`

**Files to create new**:
- `core/lib/evidence.sh` — per-run NDJSON log write (`write_run_event()`)
- `core/lib/validate-run-log.sh` — canonical `validate_run_log()` with all 16 checks
- `core/lib/workspace-fingerprint.sh` — `compute_workspace_fingerprint()` with NUL-delimited sort
- `core/lib/passing.sh` — rewritten `is_eligible_for_passing()` referencing canonical log
- `core/lib/staleness.sh` — three-axis staleness check
- `core/lib/lock-registry.sh` — flock + mkdir lock with metadata

**Files to rewrite**:
- `scripts/harness-verify.sh` → `core/harness-verify.sh` — generates per-run NDJSON log
- `scripts/harness-feature.sh` → `core/harness-feature.sh` — calls validate_run_log + passing

#### 1.2 `core/lib/evidence.sh`

Core function: `write_run_event(run_id, event_json)`

- Appends one JSON line to `.harness/logs/runs/<run_id>.ndjson`
- Creates parent directory if needed
- No concurrency guard needed (single-writer-per-run)
- Log artifact: per-command output to `.harness/logs/runs/<run_id>/<command_id>.log`

#### 1.3 `core/lib/validate-run-log.sh`

Implements the full 16-step `validate_run_log()` from design Section 3.1:

| Step | Check |
|------|-------|
| 1 | run_id character whitelist `[A-Za-z0-9._-]` |
| 2 | Path containment within `.harness/logs/runs/` |
| 3 | File exists + all lines parse as JSON |
| 4 | No unknown event types |
| 5 | Required fields + types + enum values per event |
| 6 | schema_version valid (integer, 1-2) |
| 7 | All events same schema_version |
| 8 | All events same run_id |
| 9 | Exactly one run_started, first non-blank line |
| 10 | required_command_ids no duplicates |
| 11 | Exactly one terminal event, last non-blank line |
| 12 | command_id uniqueness |
| 13 | Required command coverage |
| 14a-d | Count invariants (executed=passed+failed, planned=executed+skipped, planned=req_ids.length, command_completed=executed) |
| 15 | Origin–confirmation invariants |
| 16 | Association run_id matches |

Returns: `{valid: true, run_started, terminal, command_events}` or `{valid: false, reason, ...}`

#### 1.4 `core/lib/workspace-fingerprint.sh`

- `compute_workspace_fingerprint()` — design Section 11.1
- Built-in excludes: `.harness/logs/`, `.harness/.registry.lock/`, `.harness/*.tmp.*`
- Configurable `fingerprint_exclude[]` from `.harness/config.json`
- Git: `git diff --cached HEAD` (staged) + `git diff HEAD` (unstaged) + `git ls-files --others` (untracked)
- Non-git: hash over scope files
- Sorted, NUL-delimited path:hash — safe for special filenames
- Output: `"clean"` or `"sha256:<hex>"`

#### 1.5 `core/lib/passing.sh`

Rewrites `is_eligible_for_passing(feature_id, registry)` per design Section 9.1:

1. Find latest association from registry
2. `validate_run_log(run_id, assoc)` — if invalid → not eligible
3. Terminal must be `run_completed` with `overall_result = "passed"`
4. At least one required step
5. `terminal.failed_commands == 0`
6. `current_fingerprint == terminal.workspace_fingerprint_verified`
7. `current_config_hash == run_started.config_sha256`
8. VCS HEAD match (git only)

#### 1.6 `core/harness-verify.sh` Rewrite

New flow:
1. Load `.harness/config.json`
2. Generate `run_id`
3. Compute `workspace_fingerprint_initial`
4. Write `run_started` event
5. For each command in verification plan:
   - Execute, capture stdout/stderr to log artifact
   - Write `command_completed` event
6. Compute `workspace_fingerprint_verified`
7. Write terminal event (`run_completed` / `run_failed` / `run_aborted`)
8. Return exit code

#### 1.7 Tests

**New files**: `tests/core/test-validate-run-log.sh`, `tests/core/test-workspace-fingerprint.sh`, `tests/core/test-passing.sh`

**Golden files**: `tests/golden/run-log-valid.ndjson`, `tests/golden/run-log-no-terminal.ndjson`, `tests/golden/run-log-unknown-event.ndjson`, etc.

### Acceptance Criteria
- [ ] `validate_run_log` passes golden valid log
- [ ] `validate_run_log` rejects each corruption variant (≥20 cases)
- [ ] `compute_workspace_fingerprint` excludes `.harness/` artifacts
- [ ] `compute_workspace_fingerprint` stable: terminal event write does not change fingerprint
- [ ] `compute_workspace_fingerprint` handles special filenames (newlines, spaces, quotes)
- [ ] `is_eligible_for_passing` returns correct result for each scenario
- [ ] `harness-verify.sh` writes complete NDJSON log
- [ ] All existing v1.1.2 tests still pass (or explicitly migrated)

---

## Phase 2: Registry & Locking

### Goal
Feature registry schema with monotonic revision, locking protocol with flock/mkdir, and stale lock recovery.

### Implementation Steps

#### 2.1 `core/lib/lock-registry.sh`

- `acquire_lock(lock_dir, timeout_sec)` — design Section 7.5
  - Linux: `flock` first choice
  - macOS / Git Bash: `mkdir` fallback with metadata
- `release_lock(lock)` — verifies token match
- Metadata files: `pid`, `process_start_time`, `hostname`, `timestamp`, `token`
- Stale recovery with cross-host safety

#### 2.2 Feature Registry Migration

`feature_list.json` v1.1.2 → v2 schema:
```json
{
  "revision": 1,
  "features": [
    {
      "id": "feature-001",
      "status": "passing",
      "evidence_associations": [
        {
          "run_id": "20260731T151257Z-12345-32767",
          "associated_at": "2026-07-31T15:14:00Z",
          "associated_by": "user"
        }
      ]
    }
  ]
}
```

Migration: read v1.1.2 evidence array → create association entries with `run_id` from evidence → set `revision: 1`.

#### 2.3 `core/harness-feature.sh` Rewrite

- Read registry under lock
- Apply state machine transitions (design Section 1.2)
- `passing` transition calls `is_eligible_for_passing()`
- Atomic write with revision increment

#### 2.4 Tests

**New**: `tests/core/test-lock-registry.sh`
- flock acquire/release (Linux only)
- mkdir lock acquire/release
- Token mismatch rejection
- PID reuse detection
- Cross-host timeout
- Metadata damaged fallback

### Acceptance Criteria
- [ ] Lock acquire within timeout → success
- [ ] Two concurrent writers → no data loss, revision monotonic
- [ ] Stale lock (same host, PID dead) → recovered
- [ ] PID reuse (different process, same PID) → NOT stolen
- [ ] Different host → local PID not used for stale judgment
- [ ] Token mismatch → release rejected
- [ ] v1.1.2 `feature_list.json` → v2 schema migration is lossless

---

## Phase 3: Adapter — Claude Code

### Goal
Refactor existing Claude Code adapter to the Core/Adapter architecture without breaking existing users.

### Implementation Steps

#### 3.1 Hook Scripts

Move + refactor:
- `scripts/hooks/session-start.sh` → `adapters/claude-code/hooks/session-start.sh`
- `scripts/hooks/stop-handoff.sh` → `adapters/claude-code/hooks/stop-handoff.sh`

Each hook: calls core script → maps neutral outcome to Claude-specific JSON (design Section 13.3).

#### 3.2 Templates

Move:
- `templates/CLAUDE.md` → `adapters/claude-code/templates/CLAUDE.md`
- `templates/claude-progress.md` → `adapters/claude-code/templates/claude-progress.md`

#### 3.3 `install.sh`

Refactor to install from new directory structure. Register hooks in `~/.claude/settings.json`.

#### 3.4 `adapter.conf`

```ini
name=claude-code
display_name=Claude Code
protocol_version=1
knowledge_entry=CLAUDE.md
progress_file=claude-progress.md
has_session_start_hook=true
has_stop_hook=true
hook_runtime=bash
hook_directory=hooks
has_command_windows=false
```

#### 3.5 Contract Tests

`tests/adapters/test-claude-code-contract.sh`:
- grep for forbidden core logic strings in adapter scripts
- Hook output schema validation

### Acceptance Criteria
- [ ] `/harness:status` works under new directory structure
- [ ] `/harness:verify` writes canonical NDJSON log
- [ ] `/harness:feature status <id> passing` validates via `validate_run_log`
- [ ] SessionStart hook outputs valid Claude-specific JSON
- [ ] Stop hook outputs valid Claude-specific JSON
- [ ] Contract test: adapter scripts contain no core logic

---

## Phase 4: Adapter — Codex

### Goal
New adapter for Codex OS. Highest risk — Codex hook output schemas unverified.

### Implementation Steps

#### 4.1 Pre-Implementation Research

**BLOCKER**: Before writing Codex adapter code, verify:
1. Run Codex with a minimal `command` hook to capture actual hook input JSON
2. Each event's expected output format (SessionStart, Stop, PreToolUse, PostToolUse, PreCompact)
3. `config.toml` `[[hooks]]` exact TOML structure
4. `PLUGIN_ROOT` / `PLUGIN_DATA` environment variable values at hook runtime

Output: `docs/superpowers/research/codex-hook-schemas.md`

#### 4.2 Hook Scripts

- `adapters/codex/hooks/session-start.sh` + `.cmd`
- `adapters/codex/hooks/stop-handoff.sh` + `.cmd`
- `adapters/codex/hooks/pre-tool-use.sh` — exit 0 + empty stdout if schema unknown

#### 4.3 Templates

- `adapters/codex/templates/AGENTS.md`
- `adapters/codex/templates/codex-progress.md`

#### 4.4 `install.sh`

Three install modes (one config source per mode):
- Plugin: `hooks.json` in `<plugin_root>/hooks/`
- Repo-local: `hooks.json` in `<project>/.codex/`
- User inline: `config.toml` `[[hooks]]` block

#### 4.5 Contract Tests

`tests/adapters/test-codex-contract.sh`

### Acceptance Criteria
- [ ] Codex hook schemas documented (research output)
- [ ] Each hook: `bash` version runs and exits 0
- [ ] Each hook: `.cmd` version runs under Git Bash
- [ ] Hook outputs match documented Codex schemas
- [ ] Contract test: adapter scripts contain no core logic

---

## Phase 5: Integration & Migration

### Goal
End-to-end verification, migration tooling, and documentation.

### Implementation Steps

#### 5.1 End-to-End Tests

`tests/e2e/` — full workflow tests:
- Init → verify → feature promote → passing check → status
- Cross-platform: Linux, macOS, Windows Git Bash
- Multi-project: Node, Python, Rust, docs-only

#### 5.2 Migration Tool

`core/harness-migrate.sh`:
- Detect v1.1.2 installation
- Migrate `feature_list.json` to v2 schema (add revision, convert evidence→associations)
- Re-verify existing features to generate NDJSON run logs
- Preserve backups of all modified files

#### 5.3 Documentation

- Update `SKILL.md` — new commands, new directory structure
- Update `README.md` — Core/Adapter architecture overview
- Add `MIGRATION.md` entry for v1.1.2 → v2

#### 5.4 Version Bump

`VERSION` → `2.0.0`

### Acceptance Criteria
- [ ] Fresh install: full workflow passes end-to-end
- [ ] v1.1.2 migration: `harness-migrate.sh` produces valid v2 state
- [ ] After migration: `/harness:feature status <id> passing` works
- [ ] All tests pass on Linux, macOS, Windows Git Bash
- [ ] SKILL.md, README.md, MIGRATION.md updated

---

## Risk Register

| Risk | Phase | Mitigation |
|------|-------|------------|
| Codex hook output schemas unknown | 4 | Phase 4 pre-research step; do not write adapter code before schemas confirmed |
| v1.1.2 users broken by directory restructure | 3 | Symlinks for backward compat; install.sh handles both old and new paths |
| `mkdir` mutex unreliable on Windows Git Bash | 2 | Pressure-test in CI; if flaky, fallback to file-based lock with retry |
| macOS `flock` on APFS/network mounts | 2 | Test on target filesystem in Phase 1; skip flock if unreliable |
| Special filenames break fingerprint | 1 | NUL-delimited encoding; golden tests with edge-case filenames |
| Migration tool data loss | 5 | Always backup before migration; dry-run mode; golden diffs |

---

## File Manifest

### New Files (25+)

```
core/lib/evidence.sh
core/lib/validate-run-log.sh
core/lib/workspace-fingerprint.sh
core/lib/staleness.sh
core/lib/lock-registry.sh
core/harness-verify.sh          (rewrite)
core/harness-feature.sh         (rewrite)
core/harness-migrate.sh
adapters/codex/hooks/session-start.sh
adapters/codex/hooks/session-start.cmd
adapters/codex/hooks/stop-handoff.sh
adapters/codex/hooks/stop-handoff.cmd
adapters/codex/hooks/pre-tool-use.sh
adapters/codex/templates/AGENTS.md
adapters/codex/templates/codex-progress.md
adapters/codex/install.sh
adapters/codex/adapter.conf
adapters/claude-code/adapter.conf
tests/core/test-validate-run-log.sh
tests/core/test-workspace-fingerprint.sh
tests/core/test-passing.sh
tests/core/test-lock-registry.sh
tests/adapters/test-claude-code-contract.sh
tests/adapters/test-codex-contract.sh
tests/golden/*.ndjson (5-8 golden files)
```

### Moved Files

```
scripts/_lib/*.sh              → core/lib/
scripts/hooks/*.sh             → adapters/claude-code/hooks/
templates/CLAUDE.md            → adapters/claude-code/templates/
templates/claude-progress.md   → adapters/claude-code/templates/
scripts/harness-*.sh           → core/ (rewritten)
```

### Unchanged Files

```
templates/feature_list.json
templates/.harness/config.schema.json
templates/.harness/config.json.*.example
templates/init.sh
references/
```

---

## Approval Gates

| Gate | After | Requires |
|------|-------|----------|
| G1 | Phase 1 | All core tests pass; `validate_run_log` covers all 16 checks |
| G2 | Phase 2 | Lock concurrency tests pass on all 3 platforms |
| G3 | Phase 3 | Claude Code adapter contract tests pass; v1.1.2 backward compat verified |
| G4 | Phase 4 | Codex hook schemas confirmed; adapter tests pass |
| G5 | Phase 5 | E2E tests pass; migration tool verified; docs updated |

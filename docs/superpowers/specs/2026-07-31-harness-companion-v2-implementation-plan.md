# harness-companion v2 通用化升级 — Implementation Plan v2

> 基于: `docs/superpowers/specs/2026-07-31-harness-companion-generalization-design.md` v5（Approved，已冻结）
> 日期: 2026-07-31 | 修订: plan v2

---

## Plan v1 → v2 Revision Summary

| # | v1 Issue | v2 Fix |
|---|----------|--------|
| 1 | Source root at `.claude/skills/harness-companion/` (platform-specific) | Source root at `harness-companion/` (neutral). Claude/Codex installers each install to their own targets. Merged duplicate `core/` directories |
| 2 | Templates listed as Unchanged | All templates scheduled for update: revision, evidence_associations, fingerprint_exclude, verification scope, command metadata, non-Node examples |
| 3 | Migration fabricated associations from legacy evidence | Only real run_ids with canonical log that passes `validate_run_log` become associations. Legacy → `unverified` with `replay_required`. No silent re-verify. Dry-run, backup, idempotent tests |
| 4 | NUL-delimited data in Bash variables | NUL data flows through stream/temp file piped to hash. Built-in excludes cannot be overridden by user config. Terminal-stability test added |
| 5 | Codex Plugin mode missing plugin.json | Added: `.codex-plugin/plugin.json`, `hooks/hooks.json`, manifest validation, PLUGIN_ROOT path test, trust review prompt, rollback/uninstall |
| 6 | Incomplete Windows/config/contract coverage | `.cmd` tested in Windows cmd environment; config.toml backup/idempotent/conflict-safe (first release: snippet); Windows uses wrapper not symlink; contract tests are behavioral not grep-only; migration E2E distinguishes reusable vs replay_required; each gate has rollback condition |

---

## Phase Overview

| Phase | Name | Scope | Est. Risk |
|-------|------|-------|-----------|
| **Phase 1** | Core Refactor | Canonical evidence model + validate_run_log + workspace fingerprint + passing eligibility | Medium |
| **Phase 2** | Templates & Config | Update all templates for v2 schema + config.json schema revision | Low |
| **Phase 3** | Registry & Locking | Feature registry schema + locking protocol + atomic write hardening | Medium |
| **Phase 4** | Adapter: Claude Code | Refactor hooks to Core/Adapter architecture + behavioral contract tests | Low |
| **Phase 5** | Adapter: Codex | New adapter (plugin manifest, install, hooks, templates) + behavioral contract tests | High |
| **Phase 6** | Migration & Integration | v1.1.2→v2 migration tooling, E2E tests, documentation | Medium |

---

## Source Package Root

The source tree is platform-neutral. Adapter installers copy from it into their respective host locations.

```
harness-companion/                    <-- SOURCE ROOT (platform-neutral)
├── core/
│   ├── lib/
│   │   ├── evidence.sh
│   │   ├── validate-run-log.sh
│   │   ├── workspace-fingerprint.sh
│   │   ├── passing.sh
│   │   ├── staleness.sh
│   │   ├── lock-registry.sh
│   │   ├── atomic-write.sh
│   │   ├── json-helpers.sh
│   │   ├── harness-config.sh
│   │   └── baseline.sh
│   ├── harness-verify.sh
│   ├── harness-feature.sh
│   ├── harness-status.sh
│   ├── harness-audit.sh
│   └── harness-migrate.sh
├── adapters/
│   ├── claude-code/
│   │   ├── hooks/
│   │   │   ├── session-start.sh
│   │   │   └── stop-handoff.sh
│   │   ├── templates/
│   │   │   ├── CLAUDE.md
│   │   │   └── claude-progress.md
│   │   ├── install.sh
│   │   └── adapter.conf
│   └── codex/
│       ├── plugin/
│       │   └── plugin.json
│       ├── hooks/
│       │   ├── hooks.json
│       │   ├── session-start.sh
│       │   ├── session-start.cmd
│       │   ├── stop-handoff.sh
│       │   ├── stop-handoff.cmd
│       │   ├── pre-tool-use.sh
│       │   └── pre-tool-use.cmd
│       ├── wrappers/                  # Windows shim (not symlink)
│       │   └── harness-core.cmd
│       ├── templates/
│       │   ├── AGENTS.md
│       │   └── codex-progress.md
│       ├── install.sh
│       ├── uninstall.sh
│       └── adapter.conf
├── templates/                         # shared, platform-neutral
│   ├── feature_list.json
│   ├── .harness/
│   │   ├── config.schema.json
│   │   ├── config.json.node.example
│   │   ├── config.json.python.example
│   │   ├── config.json.rust.example
│   │   ├── config.json.go.example
│   │   ├── config.json.docs.example
│   │   └── config.json.generic.example
│   └── init.sh
├── tests/
│   ├── core/
│   ├── adapters/
│   ├── e2e/
│   └── golden/
├── references/
├── SKILL.md
├── README.md
├── MIGRATION.md
└── VERSION
```

**Install targets** (each adapter's `install.sh` copies from source root):

| Adapter | Mode | Install Target |
|---------|------|----------------|
| Claude Code | `--user` | `~/.claude/skills/harness-companion/` |
| Claude Code | `--project` | `<project>/.claude/skills/harness-companion/` |
| Codex | `--plugin` | `<plugin_root>/` (resolved from `PLUGIN_ROOT` or user path) |
| Codex | `--repo` | `<project>/.codex/` |
| Codex | `--user` | `~/.codex/` (generates config snippet) |

---

## Phase 1: Core Refactor

### Goal
Establish the canonical evidence model, `validate_run_log()`, workspace fingerprint, and updated passing eligibility — all as shared core libraries.

### Implementation Steps

#### 1.1 Directory Scaffold

Create `core/` and `core/lib/` under source root. Merge existing `scripts/_lib/` into `core/lib/`. Single flat `core/lib/` — no nested subdirectories.

#### 1.2 `core/lib/evidence.sh`

- `write_run_event(run_id, event_json)`: append JSON line to `.harness/logs/runs/<run_id>.ndjson`
- `generate_run_id()`: timestamp-PID-RANDOM (unchanged from v1.1.2)
- Per-command log artifacts to `.harness/logs/runs/<run_id>/<command_id>.log`
- Creates parent directories as needed

#### 1.3 `core/lib/validate-run-log.sh`

Full 16-step `validate_run_log()` as specified in design Section 3.0-3.1.

#### 1.4 `core/lib/workspace-fingerprint.sh`

`compute_workspace_fingerprint()` per design Section 11:

- **Built-in excludes** (MUST, not user-overridable): `.harness/logs/`, `.harness/.registry.lock/`, `.harness/*.tmp.*`
- **Configurable excludes**: `fingerprint_exclude[]` globs from `.harness/config.json` (default: `node_modules/`, `.git/`, `__pycache__/`, `*.pyc`, `.DS_Store`, `Thumbs.db`)
- **Git repos**: `git diff --cached HEAD` (staged) + `git diff HEAD` (unstaged) + `git ls-files --others --exclude-standard` (untracked)
- **Non-git**: hash all files under verification scope
- **Implementation note**: Bash variables MUST NOT hold NUL bytes. Build the sorted path:hash sequence into a temp file, then pipe to `sha256sum`. Use `printf '%s\0%s\0' "$path" "$hash"` per-entry into temp file.
- Output: `"clean"` or `"sha256:<hex>"`

#### 1.5 `core/lib/passing.sh`

`is_eligible_for_passing(feature_id, registry)` per design Section 9.1.

#### 1.6 `core/harness-verify.sh` Rewrite

1. Load config, detect capability level
2. Generate `run_id`
3. Compute `workspace_fingerprint_initial` (via stream/temp file, not variable)
4. Write `run_started` event
5. For each command: execute → log artifact → write `command_completed`
6. Compute `workspace_fingerprint_verified`
7. Write terminal event

#### 1.7 Tests

- `tests/core/test-validate-run-log.sh` — all 16 steps + edge cases
- `tests/core/test-workspace-fingerprint.sh` — includes:
  - Terminal append fingerprint stability (append terminal event, recompute, assert unchanged)
  - Built-in exclude immunity (user config cannot override)
  - Special filename handling (newlines, spaces, quotes via temp file)
- `tests/core/test-passing.sh` — eligibility scenarios
- Golden files: `tests/golden/run-log-valid.ndjson`, `tests/golden/run-log-*.ndjson`

### Acceptance Criteria
- [ ] `validate_run_log` passes golden valid log
- [ ] `validate_run_log` rejects each corruption variant (≥20 cases)
- [ ] `compute_workspace_fingerprint` excludes `.harness/` artifacts unconditionally
- [ ] Terminal event write does not change fingerprint (stability test)
- [ ] Special filenames handled correctly
- [ ] `is_eligible_for_passing` correct for all scenarios
- [ ] `harness-verify.sh` writes complete NDJSON log
- [ ] All v1.1.2 tests still pass (or explicitly migrated)

### Gate G1: Core — Rollback Condition
If `validate_run_log` misses any design-specified check, or fingerprint is unstable after terminal append → fix before proceeding to Phase 2.

---

## Phase 2: Templates & Config

### Goal
Update all shared templates for v2 schema. Previously listed as "Unchanged" — all require revision.

### Implementation Steps

#### 2.1 `templates/feature_list.json`

Add `revision` field and `evidence_associations` schema:
```json
{
  "revision": 1,
  "features": [
    {
      "id": "feature-001",
      "status": "not_started",
      "evidence_associations": [],
      "legacy_audit_evidence": []
    }
  ]
}
```

#### 2.2 `templates/.harness/config.schema.json`

Add new properties:
- `fingerprint_exclude` — array of glob strings (default provided)
- `verification_scope` — root-relative path for no-git fingerprinting
- `command_metadata` — per-command: `command_origin` (configured/detected), `confirmation` (not_required/pending/confirmed/rejected)
- `capability_level` — 0|1|2

#### 2.3 `templates/.harness/config.json.*.example`

Rename and expand from 3 examples (node, python, generic) to 6:
- `config.json.node.example`
- `config.json.python.example`
- `config.json.rust.example` (NEW)
- `config.json.go.example` (NEW)
- `config.json.docs.example` (NEW — 0-step, `required_commands: []`)
- `config.json.generic.example`

Each includes `fingerprint_exclude`, `verification_scope`, and `command_metadata` fields with language-appropriate defaults.

#### 2.4 `templates/init.sh`

Update to:
- Create `.harness/logs/runs/` directory
- Write v2-schema `feature_list.json` with `revision: 1`
- Copy appropriate config example based on detected project type (Node/Python/Rust/Go/docs/generic)
- Add `.harness/logs/` to `.gitignore`

#### 2.5 Tests

- `tests/core/test-templates.sh` — validate each example against schema
- `tests/core/test-init.sh` — init on each project type produces valid config

### Acceptance Criteria
- [ ] All 6 example configs validate against updated schema
- [ ] `init.sh` correctly detects project type and copies matching example
- [ ] 0-step docs project has `required_commands: []`
- [ ] `fingerprint_exclude` present in all configs with sensible defaults

### Gate G2: Templates — Rollback Condition
If any example config fails schema validation, or `init.sh` misdetects a project type → fix before Phase 3.

---

## Phase 3: Registry & Locking

### Goal
Feature registry with monotonic revision, locking protocol, stale lock recovery.

### Implementation Steps

#### 3.1 `core/lib/lock-registry.sh`

`acquire_lock(lock_dir, timeout_sec)` + `release_lock(lock)` per design Section 7.5.

#### 3.2 `core/harness-feature.sh` Rewrite

- Read registry under lock
- Apply state machine transitions (design Section 1.2)
- `passing` transition calls `is_eligible_for_passing()`
- Atomic write with revision increment
- Override audit records for `unverified` transitions

#### 3.3 Tests

`tests/core/test-lock-registry.sh` — 10 lock scenarios from design Section 7.6 + 17.3.

### Acceptance Criteria
- [ ] Lock acquire within timeout → success
- [ ] Two concurrent writers → no data loss, revision monotonic
- [ ] Stale lock recovery rules all correct
- [ ] Token mismatch → release rejected
- [ ] Cross-host: no local-PID-based stale judgment

### Gate G3: Registry — Rollback Condition
If any lock concurrency test fails, or revision skips/duplicates → fix before Phase 4.

---

## Phase 4: Adapter — Claude Code

### Goal
Refactor existing Claude Code adapter to Core/Adapter architecture. Backward compatible with v1.1.2.

### Implementation Steps

#### 4.1 Hook Scripts

Move `scripts/hooks/session-start.sh` → `adapters/claude-code/hooks/session-start.sh`
Move `scripts/hooks/stop-handoff.sh` → `adapters/claude-code/hooks/stop-handoff.sh`

Each hook:
1. Read platform hook input → normalize to env vars
2. Call core script from `$INSTALL_DIR/core/`
3. Map neutral outcome JSON → Claude-specific protocol output (design Section 13.3)
4. On error: fail-open per event mapping

#### 4.2 Templates

Move adapter-specific templates out of shared `templates/`:
- `templates/CLAUDE.md` → `adapters/claude-code/templates/CLAUDE.md`
- `templates/claude-progress.md` → `adapters/claude-code/templates/claude-progress.md`

#### 4.3 `adapters/claude-code/install.sh`

- Source root → target: copies `core/`, `templates/`, `adapters/claude-code/` contents
- `--user` → `~/.claude/skills/harness-companion/`
- `--project` → `<project>/.claude/skills/harness-companion/`
- `--symlink-core` → symlink `core/` instead of copying (dev mode). On Windows: copy, not symlink (use wrapper approach)

#### 4.4 Behavioral Contract Tests

`tests/adapters/test-claude-code-contract.sh`:

**Not** grep-only. Each test:
1. Invoke hook script with controlled input (simulated Claude hook JSON via stdin)
2. Capture stdout
3. Parse output JSON
4. Assert structural requirements:
   - SessionStart: `continue` is `true`, `hookSpecificOutput.hookEventName` = `"SessionStart"`
   - Stop: `continue` is `true`
   - Error path: `continue` is `true` (fail-open)
5. Assert absence: core logic patterns (state machine transitions, passing eligibility checks, fingerprint computation) MUST NOT appear in hook output or adapter source

### Acceptance Criteria
- [ ] `/harness:status` works under new directory structure
- [ ] `/harness:verify` writes canonical NDJSON log
- [ ] `/harness:feature status <id> passing` validates via `validate_run_log`
- [ ] SessionStart hook: valid output, fail-open on error
- [ ] Stop hook: valid output, fail-open on error
- [ ] Behavioral contract: adapter scripts pass structural output tests
- [ ] Behavioral contract: adapter scripts contain no core logic (grep + structural verify)

### Gate G4: Claude Code — Rollback Condition
If any v1.1.2 workflow breaks (init/verify/feature/status/audit/handoff), or hook output fails structural validation → fix before Phase 5.

---

## Phase 5: Adapter — Codex

### Goal
New adapter for Codex OS. Highest risk — Codex hook output schemas unverified.

### Pre-Implementation Research (BLOCKER — before any Codex code)

1. Run Codex with a minimal `type: "command"` hook; capture actual hook input JSON
2. Document each event's expected output format
3. Confirm `config.toml` `[[hooks]]` TOML structure
4. Confirm `PLUGIN_ROOT` / `PLUGIN_DATA` env var values at hook runtime
5. Output: `docs/superpowers/research/codex-hook-schemas.md`

### Implementation Steps

#### 5.1 Plugin Manifest

`adapters/codex/plugin/plugin.json`:
```json
{
  "name": "harness-companion",
  "version": "2.0.0",
  "description": "Harness Engineering skill for reliable AI coding environments",
  "author": "harness-engineering",
  "hooks": ["SessionStart", "Stop", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact"],
  "platforms": ["linux", "macos", "windows"],
  "requires_bash": true
}
```

#### 5.2 `hooks/hooks.json`

Generated at install time (not committed). Template in `adapters/codex/hooks/hooks.json.template`.

Each hook entry: `{"type": "command", "command": "bash \"<PLUGIN_ROOT>/adapters/codex/hooks/<name>.sh\""}`,
`"commandWindows": "<PLUGIN_ROOT>\\adapters\\codex\\hooks\\<name>.cmd"`.

#### 5.3 Hook Scripts

- `session-start.sh` / `.cmd` — adheres to fail-open per-event mapping (design Section 13.3)
- `stop-handoff.sh` / `.cmd` — exit 0, empty stdout
- `pre-tool-use.sh` / `.cmd` — exit 0, empty stdout (schema not yet confirmed)

Each `.sh`: bash script called via `bash "<path>"`.  
Each `.cmd`: Windows cmd wrapper that invokes `bash "<path>.sh"`. Test in actual Windows `cmd.exe` environment (not Git Bash).

#### 5.4 Windows Wrapper

`adapters/codex/wrappers/harness-core.cmd`:
```cmd
@echo off
REM Wrapper to invoke bash core from cmd.exe
REM Requires Git Bash or WSL bash on PATH
set "BASH_EXE=bash"
where %BASH_EXE% >nul 2>&1 || (
    echo harness-companion: bash not found on PATH >&2
    exit /b 0
)
"%BASH_EXE%" "%~dp0..\..\core\%~n0.sh" %*
```

All `.cmd` hook scripts delegate through this wrapper. No symlinks — copies only.

#### 5.5 `adapters/codex/install.sh`

Three modes, one config source each (design Section 14.3):

| Mode | Target | Config | Manifest Validation |
|------|--------|--------|---------------------|
| `--plugin` | `<plugin_root>/` | `hooks/hooks.json` | Validate `plugin.json` exists + version matches |
| `--repo` | `<project>/.codex/` | `hooks/hooks.json` | N/A |
| `--user` | `~/.codex/` | `config.toml` snippet | N/A |

**All modes**:
- Backup existing config before modification (`.bak-YYYYMMDD` or similar)
- Idempotent: detect already-installed hooks, skip or update
- Trust review: after install, print the hook commands that will execute, prompt user to review
- PLUGIN_ROOT path test: verify `PLUGIN_ROOT` resolves, test that `bash "<PLUGIN_ROOT>/core/harness-status.sh"` exits 0

**config.toml snippet** (first release): generate a standalone snippet file `harness-hooks.toml` for user to `include` manually, avoiding edit-in-place of live `config.toml`. Full automated merge deferred to future release when TOML editing is battle-tested.

#### 5.6 `adapters/codex/uninstall.sh`

- Remove hook registrations from `hooks.json` or `config.toml`
- Optionally remove installed files
- Restore from backup if present

#### 5.7 Behavioral Contract Tests

`tests/adapters/test-codex-contract.sh`:

1. PLUGIN_ROOT path resolution test
2. Manifest validation: `plugin.json` schema check
3. Each hook: invoke with controlled input → capture stdout → validate output per Codex event schema (once confirmed)
4. Error path: each hook exits 0, outputs empty stdout or event-minimal valid JSON
5. `.cmd` scripts: invoke in Windows `cmd.exe` environment, verify Bash core is reached
6. Assert absence of core logic patterns

### Acceptance Criteria
- [ ] Codex hook schemas documented (research output)
- [ ] `plugin.json` validates against manifest schema
- [ ] Each `.sh` hook runs and exits 0
- [ ] Each `.cmd` hook tested in Windows `cmd.exe` and reaches Bash core
- [ ] `install.sh --plugin` validates PLUGIN_ROOT path before installing
- [ ] Trust review prompt shown after install
- [ ] `uninstall.sh` removes hook registrations cleanly
- [ ] `install.sh` idempotent (second run no-op or clean update)
- [ ] Backup created before any config modification

### Gate G5: Codex — Rollback Condition
If Codex hook schemas are not confirmed by research, OR any `.cmd` fails to invoke Bash core in Windows cmd.exe → do not proceed to Phase 6 for Codex. Claude Code path can advance independently.

---

## Phase 6: Migration & Integration

### Goal
v1.1.2→v2 migration tooling, E2E tests, documentation.

### Migration Rules (Section 16 of design — MUST)

| Rule | Constraint |
|------|------------|
| Only real `run_id` with canonical log that passes `validate_run_log` → association | MUST |
| Legacy string / no-run-id evidence → `legacy_audit_evidence[]` only | MUST |
| Do NOT fabricate `run_id` or association from legacy evidence | MUST |
| v1.1.2 `passing` → `unverified` with `migration_status: "replay_required"` | MUST |
| Re-verify MUST be explicit user action (`/harness:verify`), never silent in migrate | MUST |
| Dry-run MUST be the default; `--apply` flag required for writes | MUST |
| Backup every modified file | MUST |
| Migration MUST be idempotent | MUST |

### Implementation Steps

#### 6.1 `core/harness-migrate.sh`

```
harness-migrate.sh [--dry-run] [--apply] [--project <path>]

Dry-run (default):
  1. Detect v1.1.2 installation
  2. Scan feature_list.json
  3. For each feature:
     a. If evidence has structured records with run_id:
        - Check if .harness/logs/runs/<run_id>.ndjson exists
        - If yes: run validate_run_log(run_id, assoc)
        - If valid → report "CANONICAL: <run_id> eligible for association"
        - If invalid → report "CORRUPT: <run_id> — re-verify required"
     b. If evidence has only legacy strings or no-run-id records:
        - Report "LEGACY: feature <id> — replay_required"
     c. If feature.status == "passing":
        - Report "MIGRATE: <id> passing → unverified (replay_required)"
  4. Output migration plan (no changes made)

--apply:
  1. Same scan as dry-run
  2. Backup feature_list.json → feature_list.json.bak-YYYYMMDD
  3. Rewrite registry:
     - Add revision: 1
     - For each canonical run: create evidence_associations entry
     - Move legacy evidence → legacy_audit_evidence[]
     - Set passing features → unverified, with migration_status: "replay_required"
  4. Write via atomic rename under lock
  5. Print summary: N canonical associations, M replay_required, 0 fabricated
```

#### 6.2 Integration E2E Tests

`tests/e2e/` — two distinct tracks:

**Track A: Reusable canonical run**
1. v1.1.2 project with `run_id`-tagged evidence (from v1.1.1+)
2. Run `harness-migrate.sh --apply`
3. Assert: association created, `validate_run_log` passed
4. Assert: feature can be promoted to `passing` (evidence still fresh)

**Track B: Replay required**
1. v1.1.2 project with legacy string evidence only
2. Run `harness-migrate.sh --apply`
3. Assert: `legacy_audit_evidence[]` populated, no association created
4. Assert: feature status = `unverified`, `migration_status = "replay_required"`
5. User runs `/harness:verify` → new canonical run log created
6. User runs `/harness:feature status <id> passing` → eligible

**Cross-project**: Node, Python, Rust, Go, docs-only. Cross-platform: Linux, macOS, Windows Git Bash.

#### 6.3 Idempotent Migration Tests

- Run `harness-migrate.sh --apply` twice → second run is no-op
- Run `harness-migrate.sh --dry-run` after `--apply` → reports "up to date"
- Migration on already-migrated v2 registry → detected, skipped

#### 6.4 Documentation

- Update `SKILL.md` — new commands (`/harness:migrate`), new directory structure
- Update `README.md` — Core/Adapter architecture overview
- Update `MIGRATION.md` — v1.1.2 → v2 migration guide

#### 6.5 Version Bump

`VERSION` → `2.0.0`

### Acceptance Criteria
- [ ] Dry-run reports correct migration plan for v1.1.2 project
- [ ] `--apply` never fabricates run_id or association
- [ ] Legacy passing → `unverified` + `replay_required`
- [ ] Canonical runs with valid logs → associations created
- [ ] Corrupt/missing canonical logs → reported, not associated
- [ ] Migration is idempotent
- [ ] All files backed up before modification
- [ ] E2E Track A: reusable canonical run passes
- [ ] E2E Track B: replay_required → re-verify → passing works
- [ ] All tests pass on Linux, macOS, Windows Git Bash

### Gate G6: Migration — Rollback Condition
If migration fabricates any association without a valid canonical log, or silently re-verifies, or is not idempotent → fix before release.

---

## Risk Register

| Risk | Phase | Mitigation |
|------|-------|------------|
| Codex hook output schemas unknown | 5 | BLOCKER gate: pre-research required before writing adapter code |
| v1.1.2 users broken by directory restructure | 4 | install.sh copies to same target; `--symlink-core` optional |
| `mkdir` mutex unreliable on Windows Git Bash | 3 | Pressure-test in CI; file-based retry fallback |
| macOS `flock` on APFS/network mounts | 3 | Test on target filesystem; skip flock if unreliable |
| Special filenames break fingerprint | 1 | NUL-delimited via temp file; golden tests with edge-case filenames |
| Migration fabricates associations | 6 | Only `run_id` with valid canonical log; dry-run default |
| `.cmd` cannot reach Bash in Windows cmd.exe | 5 | Test in actual cmd.exe; graceful degradation to exit 0 |
| TOML edit-in-place corrupts user config | 5 | First release: snippet file only; no automated merge |

---

## File Manifest

### New Files (30+)

```
core/lib/evidence.sh
core/lib/validate-run-log.sh
core/lib/workspace-fingerprint.sh
core/lib/staleness.sh
core/lib/lock-registry.sh
core/harness-verify.sh              (rewrite)
core/harness-feature.sh             (rewrite)
core/harness-migrate.sh
adapters/codex/plugin/plugin.json
adapters/codex/hooks/hooks.json.template
adapters/codex/hooks/session-start.sh
adapters/codex/hooks/session-start.cmd
adapters/codex/hooks/stop-handoff.sh
adapters/codex/hooks/stop-handoff.cmd
adapters/codex/hooks/pre-tool-use.sh
adapters/codex/hooks/pre-tool-use.cmd
adapters/codex/wrappers/harness-core.cmd
adapters/codex/templates/AGENTS.md
adapters/codex/templates/codex-progress.md
adapters/codex/install.sh
adapters/codex/uninstall.sh
adapters/codex/adapter.conf
adapters/claude-code/adapter.conf
templates/.harness/config.json.rust.example
templates/.harness/config.json.go.example
templates/.harness/config.json.docs.example
tests/core/test-validate-run-log.sh
tests/core/test-workspace-fingerprint.sh
tests/core/test-passing.sh
tests/core/test-lock-registry.sh
tests/core/test-templates.sh
tests/core/test-init.sh
tests/adapters/test-claude-code-contract.sh
tests/adapters/test-codex-contract.sh
tests/e2e/test-migration-reusable.sh
tests/e2e/test-migration-replay-required.sh
tests/golden/*.ndjson (5-8 files)
```

### Moved Files
```
scripts/_lib/*.sh              → core/lib/
scripts/hooks/*.sh             → adapters/claude-code/hooks/
templates/CLAUDE.md            → adapters/claude-code/templates/
templates/claude-progress.md   → adapters/claude-code/templates/
scripts/harness-*.sh           → core/ (rewritten)
```

### Updated Files (was "Unchanged" in v1 plan)
```
templates/feature_list.json          → add revision, evidence_associations, legacy_audit_evidence
templates/.harness/config.schema.json → add fingerprint_exclude, verification_scope, command_metadata
templates/.harness/config.json.node.example     → add v2 fields
templates/.harness/config.json.python.example   → add v2 fields
templates/.harness/config.json.generic.example  → add v2 fields
templates/init.sh                               → v2 schema, project-type detection
```

---

## Approval Gates

| Gate | After | Requires | Rollback Condition |
|------|-------|----------|-------------------|
| **G1** | Phase 1 | All core tests pass; `validate_run_log` 16/16; fingerprint stable after terminal append | Missing check or unstable fingerprint → fix before Phase 2 |
| **G2** | Phase 2 | All 6 example configs validate; `init.sh` detects project types correctly | Schema validation failure or misdetection → fix before Phase 3 |
| **G3** | Phase 3 | Lock concurrency tests pass all 3 platforms; revision monotonic | Lock test failure or revision skip → fix before Phase 4 |
| **G4** | Phase 4 | Claude Code adapter behavioral contract tests pass; v1.1.2 backward compat verified | Any v1.1.2 workflow broken or hook output invalid → fix before Phase 5 |
| **G5** | Phase 5 | Codex hook schemas confirmed; `.cmd` reaches Bash in cmd.exe; plugin.json validates | Schemas unconfirmed or cmd.exe failure → Codex path halted; Claude Code continues independently |
| **G6** | Phase 6 | Migration never fabricates; E2E Tracks A+B pass; idempotent; all 3 platforms | Fabrication, silent re-verify, or non-idempotent → fix before release |

---

## Requirement Traceability Matrix

| Design Section | Requirement | Implementation Task | Test | Gate |
|---------------|-------------|---------------------|------|------|
| 1.2 Feature State Machine | 6 states, 13 transitions, WIP limit | Phase 3: `core/harness-feature.sh` | `tests/core/test-passing.sh` | G3 |
| 1.3 Fail-Closed | Exit 2/5/127, passing=false on validation failure | Phase 1: `core/lib/passing.sh`, `core/lib/validate-run-log.sh` | `tests/core/test-passing.sh` | G1 |
| 2.2 Event Types | run_started, command_completed, run_completed, run_failed, run_aborted | Phase 1: `core/lib/evidence.sh`, `core/harness-verify.sh` | `tests/golden/*.ndjson` | G1 |
| 2.2 Terminal Counts | planned/executed/passed/failed/skipped with 4 invariants | Phase 1: `core/lib/validate-run-log.sh` steps 14a-d | `tests/core/test-validate-run-log.sh` | G1 |
| 2.3 Terminal Rules | Exactly one terminal, last line, no_checks allowed | Phase 1: `core/lib/validate-run-log.sh` steps 9-11 | `tests/core/test-validate-run-log.sh` | G1 |
| 2.4 Feature Association | run_id in registry, evidence in canonical log | Phase 3: registry schema; Phase 6: migration | `tests/core/test-passing.sh`, `tests/e2e/` | G3, G6 |
| 3.0 Event Field Validation | Unknown events rejected, required fields/types/enums | Phase 1: `core/lib/validate-run-log.sh` steps 4-5 | `tests/core/test-validate-run-log.sh` | G1 |
| 3.0 Origin–Confirmation | configured→not_required, detected→confirmed | Phase 1: `core/lib/validate-run-log.sh` step 15 | `tests/core/test-validate-run-log.sh` | G1 |
| 3.1 run_id Validation | Whitelist, path traversal, required_command_ids no dupes | Phase 1: `core/lib/validate-run-log.sh` steps 1-2, 10 | `tests/core/test-validate-run-log.sh` | G1 |
| 5 Capability Maturity | Cumulative L2⊃L1⊃L0, capability-based detection | Phase 1-2: `core/harness-verify.sh`, `templates/init.sh` | `tests/core/test-init.sh` | G1, G2 |
| 6.2 Architecture Invariant | Adapter MUST NOT contain business semantics | Phase 4-5: behavioral contract tests | `tests/adapters/test-*-contract.sh` | G4, G5 |
| 7 Registry Locking | Monotonic revision, flock/mkdir, stale recovery, cross-host | Phase 3: `core/lib/lock-registry.sh` | `tests/core/test-lock-registry.sh` | G3 |
| 8 Run Log Concurrency | Different run_id = different file = zero contention | Phase 1: `core/lib/evidence.sh` | `tests/core/test-passing.sh` | G1 |
| 9 Passing Eligibility | 8-step check including validate_run_log + staleness | Phase 1: `core/lib/passing.sh` | `tests/core/test-passing.sh` | G1 |
| 10 Evidence Staleness | Workspace + config + VCS three-axis | Phase 1: `core/lib/staleness.sh` | `tests/core/test-passing.sh` | G1 |
| 11 Workspace Fingerprint | Built-in excludes, NUL-delimited, staged+unstaged+untracked, no-git scope hash | Phase 1: `core/lib/workspace-fingerprint.sh` | `tests/core/test-workspace-fingerprint.sh` | G1 |
| 11.0 Self-Artifact Exclusion | `.harness/` unconditionally excluded, not user-overridable | Phase 1: `core/lib/workspace-fingerprint.sh` | `tests/core/test-workspace-fingerprint.sh` (built-in exclude immunity) | G1 |
| 11.0 Terminal Stability | Terminal event append does not change fingerprint | Phase 1: `core/lib/workspace-fingerprint.sh` | `tests/core/test-workspace-fingerprint.sh` | G1 |
| 11.0 NUL Implementation | NUL data via stream/temp file, not Bash variable | Phase 1: `core/lib/workspace-fingerprint.sh` | `tests/core/test-workspace-fingerprint.sh` (special filenames) | G1 |
| 12 Verification Plan | command_origin, confirmation, 0-step no_checks | Phase 2: `templates/.harness/config.schema.json` | `tests/core/test-templates.sh` | G2 |
| 13.3 Hook Fail-Open | Core neutral outcome, adapter per-event mapping, no universal fallback | Phase 4-5: adapter hooks | `tests/adapters/test-*-contract.sh` | G4, G5 |
| 14 Codex Adapter | Plugin manifest, hooks.json, single config source, PLUGIN_ROOT, PreCompact | Phase 5: `adapters/codex/` | `tests/adapters/test-codex-contract.sh` | G5 |
| 14.4 commandWindows | .cmd depends on Bash runtime, wrapper not symlink | Phase 5: `.cmd` hooks + `wrappers/` | `tests/adapters/test-codex-contract.sh` (cmd.exe) | G5 |
| 14.3 Single Config Source | Per-mode unique config, no dual generation | Phase 5: `install.sh` modes | `tests/adapters/test-codex-contract.sh` | G5 |
| 16 Backward Compat | Read v1.1.2, write v2, no silent overwrite, idempotent | Phase 6: `core/harness-migrate.sh` | `tests/e2e/test-migration-*.sh` | G6 |
| 16 Level 1→2 Migration | Canonical logs only, legacy→audit, passing→unverified, no auto-associate | Phase 6: `core/harness-migrate.sh` | `tests/e2e/test-migration-replay-required.sh` | G6 |
| 16 Migration Safety | Dry-run default, backup, idempotent, no fabrication | Phase 6: `core/harness-migrate.sh` | `tests/e2e/test-migration-*.sh` | G6 |
| 17 Test Matrix | ~45 scenarios across 6 categories | All phases | All test files | G1-G6 |

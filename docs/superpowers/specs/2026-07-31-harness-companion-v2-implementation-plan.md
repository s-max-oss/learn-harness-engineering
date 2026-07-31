# harness-companion v2 通用化升级 — Implementation Plan v3

> 基于: `docs/superpowers/specs/2026-07-31-harness-companion-generalization-design.md` v5（Approved，已冻结）
> 日期: 2026-07-31 | 修订: plan v3

---

## Plan v2 → v3 Revision Summary

| # | v2 Issue | v3 Fix |
|---|----------|--------|
| 1 | Codex manifest at `adapters/codex/plugin/plugin.json`; declared `hooks`, `platforms`, `requires_bash`; `author` as string | Manifest at `.codex-plugin/plugin.json` (plugin root); use plugin-creator scaffold; `author` as object; remove `hooks` (Codex discovers `hooks/hooks.json` by default), `platforms`, `requires_bash` |
| 2 | `hooks/hooks.json` generated at install time; `PLUGIN_ROOT` used during install; uninstall claimed to remove config.toml edits | `hooks/hooks.json` is committed package artifact; `PLUGIN_ROOT` only at hook runtime; plugin mode via marketplace workflow; repo-local/user are independent modes; user mode produces manual-merge TOML snippet only; uninstall only removes what it created |
| 3 | `capability_level` as user field in config.schema.json | `capability_level` computed by core (not user-configurable); L1 allows `no_checks`; passing requires ≥1 executed step. Explanatory errata synced to plan/schema/tests |
| 4 | Old `scripts/` paths deleted; no v1 compat | Thin wrappers kept at `scripts/harness-*.sh` + `scripts/hooks/*.sh` forwarding to new paths; Windows: copies only; G4 adds old-path behavioral compat tests; wrappers contain zero business logic |
| 5a | `git diff HEAD` for unstaged | `git diff` (working tree vs index, no double-count of staged) |
| 5b | NUL temp file location unspecified | Temp file created outside fingerprint scope (`mktemp` in system tmpdir) |
| 5c | `harness-core.cmd` used `%~n0.sh` (resolves to wrapper name) | Eliminated wrapper; each `.cmd` hook bakes explicit path to its `.sh` sibling |
| 5d | Migration backup: `feature_list.json.bak-YYYYMMDD` (overwrites same-day) | `feature_list.json.bak-<ISO-timestamp>` (unique, never overwrites) |

---

## Phase Overview

| Phase | Name | Scope | Est. Risk |
|-------|------|-------|-----------|
| **Phase 1** | Core Refactor | Canonical evidence model + validate_run_log + workspace fingerprint + passing eligibility | Medium |
| **Phase 2** | Templates & Config | Update all templates for v2 schema + config.json schema revision | Low |
| **Phase 3** | Registry & Locking | Feature registry schema + locking protocol + atomic write hardening | Medium |
| **Phase 4** | Adapter: Claude Code | Refactor hooks to Core/Adapter + v1 compat wrappers + behavioral contract tests | Low |
| **Phase 5** | Adapter: Codex | Plugin manifest, hooks artifact, hook scripts, install modes + behavioral contract tests | High |
| **Phase 6** | Migration & Integration | v1.1.2→v2 migration tooling, E2E tests, documentation | Medium |

---

## Design Errata (explanatory — design is frozen)

### E1: `capability_level` computation

`capability_level` is **computed by core**, not a user-configurable field in `.harness/config.json`.

| Capability | Detection |
|------------|-----------|
| Level 0 | `knowledge_entry` file exists (CLAUDE.md / AGENTS.md via adapter) |
| Level 1 | L0 + `.harness/config.json` exists with verification plan (0+ commands) |
| Level 2 | L1 + `feature_list.json` exists with registry schema (`revision` field) |

The `capability_level` field in `run_started` event records the computed level at run time.

### E2: `no_checks` at Level 1

Level 1 supports projects with zero required verification commands (e.g. docs-only).

- `harness-verify.sh` on a 0-step project: writes `run_started` + `run_completed` with `overall_result: "no_checks"` and `planned_commands: 0`
- `is_eligible_for_passing()` rejects `no_checks` (step 4: `required_command_ids.length == 0 → not eligible`)
- Status display distinguishes "N steps passed" from "no verification steps configured"
- This is consistent with design Sections 2.3, 9.1, 12.3

---

## Source Package Root

The source tree is platform-neutral. Adapter installers copy from it into their respective host locations.

```
harness-companion/                          <-- SOURCE / PLUGIN ROOT (platform-neutral)
│
├── .codex-plugin/                          # Codex plugin manifest (Phase 5)
│   └── plugin.json
│
├── hooks/                                  # Codex hooks registry (committed artifact)
│   └── hooks.json
│
├── skills/                                 # Codex skill entry
│   └── harness-companion/
│       └── SKILL.md
│
├── core/                                   # Semantic core (shared)
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
│
├── scripts/                                # v1 compat wrappers (Phase 4)
│   ├── harness-verify.sh                   # → core/harness-verify.sh
│   ├── harness-feature.sh                  # → core/harness-feature.sh
│   ├── harness-status.sh                   # → core/harness-status.sh
│   ├── harness-audit.sh                    # → core/harness-audit.sh
│   └── hooks/
│       ├── session-start.sh                # → adapters/claude-code/hooks/
│       └── stop-handoff.sh                 # → adapters/claude-code/hooks/
│
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
│       ├── hooks/
│       │   ├── session-start.sh
│       │   ├── session-start.cmd
│       │   ├── stop-handoff.sh
│       │   ├── stop-handoff.cmd
│       │   ├── pre-tool-use.sh
│       │   └── pre-tool-use.cmd
│       ├── templates/
│       │   ├── AGENTS.md
│       │   └── codex-progress.md
│       ├── install.sh
│       ├── uninstall.sh
│       └── adapter.conf
│
├── templates/                              # shared, platform-neutral
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
│
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

| Adapter | Mode | Install Mechanism | Target |
|---------|------|-------------------|--------|
| Claude Code | `--user` | `install.sh` copies files | `~/.claude/skills/harness-companion/` |
| Claude Code | `--project` | `install.sh` copies files | `<project>/.claude/skills/harness-companion/` |
| Codex | Plugin | Codex marketplace / `codex plugin install` | `<plugin_root>/` (entire source tree is the plugin) |
| Codex | `--repo` | `install.sh` copies `hooks/hooks.json` + `core/` + `adapters/codex/` | `<project>/.codex/` |
| Codex | `--user` | `install.sh` writes TOML snippet file for manual merge | `~/.codex/` (snippet only) |

**Key distinctions**:

- **`PLUGIN_ROOT`**: only available at hook runtime (set by Codex). Install scripts do NOT use `PLUGIN_ROOT` — they resolve paths from their own `$SCRIPT_DIR` or user-provided arguments.
- **`hooks/hooks.json`**: committed artifact in source tree. References scripts at `<PLUGIN_ROOT>/adapters/codex/hooks/<name>.sh`. Not generated at install time.
- **Plugin mode**: installed via Codex plugin workflow (local marketplace or `codex plugin install`). The source tree IS the plugin — no file copying by our install script.
- **Repo-local**: independent mode. `install.sh --repo` copies needed files to `<project>/.codex/`.
- **User mode**: independent mode. `install.sh --user` writes a standalone TOML snippet to `~/.codex/harness-hooks.toml` with instructions for manual merge. Does NOT auto-edit `~/.codex/config.toml`.

---

## Phase 1: Core Refactor

### Goal
Establish the canonical evidence model, `validate_run_log()`, workspace fingerprint, and updated passing eligibility.

### Implementation Steps

#### 1.1 Directory Scaffold

Create `core/` and `core/lib/` under source root. Merge existing `scripts/_lib/` into `core/lib/`. Single flat `core/lib/`.

#### 1.2 `core/lib/evidence.sh`

- `write_run_event(run_id, event_json)`: append JSON line to `.harness/logs/runs/<run_id>.ndjson`
- `generate_run_id()`: timestamp-PID-RANDOM (unchanged from v1.1.2)
- Per-command log artifacts to `.harness/logs/runs/<run_id>/<command_id>.log`

#### 1.3 `core/lib/validate-run-log.sh`

Full 16-step `validate_run_log()` as specified in design Section 3.0-3.1.

#### 1.4 `core/lib/workspace-fingerprint.sh`

`compute_workspace_fingerprint()` per design Section 11.

**Git diff split (corrected)**:

| Layer | Command | Captures |
|-------|---------|----------|
| staged | `git diff --cached HEAD` | Changes between HEAD and index |
| unstaged | `git diff` | Changes between index and working tree |

These are complementary and non-overlapping. (`git diff HEAD` would include both, duplicating staged changes.)

**Built-in excludes** (MUST, not user-overridable): `.harness/logs/`, `.harness/.registry.lock/`, `.harness/*.tmp.*`

**NUL-delimited implementation**:
- Bash variables MUST NOT hold NUL bytes
- Build sorted path:hash entries into a temp file created outside fingerprint scope:
  `tmpfile=$(mktemp)` or `tmpfile=$(mktemp -t harness-fp-XXXXXX)` depending on platform
- Write with `printf '%s\0%s\0' "$path" "$hash" >> "$tmpfile"`
- Pipe temp file to `sha256sum`: `sha256sum < "$tmpfile"`
- Cleanup temp file after hash

#### 1.5 `core/lib/passing.sh`

`is_eligible_for_passing(feature_id, registry)` per design Section 9.1.

#### 1.6 `core/harness-verify.sh` Rewrite

1. Load `.harness/config.json`
2. Core computes `capability_level` (not read from user config)
3. Generate `run_id`
4. Compute `workspace_fingerprint_initial` (NUL via temp file outside scope)
5. Write `run_started` event (with computed `capability_level`)
6. For each command: execute → log artifact → write `command_completed`
7. Compute `workspace_fingerprint_verified`
8. Write terminal event (`run_completed` with `overall_result: "no_checks"` if 0 commands)

#### 1.7 Tests

- `tests/core/test-validate-run-log.sh` — all 16 steps + edge cases
- `tests/core/test-workspace-fingerprint.sh`:
  - Terminal append stability
  - Built-in exclude immunity (user config cannot override)
  - Special filename handling (NUL via temp file, not variable)
  - staged vs unstaged non-overlap: staged-only change vs unstaged-only change produce different fingerprints
- `tests/core/test-passing.sh`:
  - 0-step → `no_checks` → not eligible for passing
  - 1+ steps → `passed` → eligible (if fresh)
- Golden files: `tests/golden/run-log-valid.ndjson`, `tests/golden/run-log-no-checks.ndjson`, etc.

### Acceptance Criteria
- [ ] `validate_run_log` passes golden valid log; rejects ≥20 corruption variants
- [ ] `compute_workspace_fingerprint` excludes `.harness/` unconditionally; user `fingerprint_exclude[]` cannot override
- [ ] Terminal event write does not change fingerprint (stability)
- [ ] Special filenames handled correctly (NUL via temp file)
- [ ] `git diff --cached HEAD` + `git diff` produce non-overlapping coverage
- [ ] `is_eligible_for_passing` rejects `no_checks`; accepts `passed` with ≥1 step
- [ ] `harness-verify.sh` writes complete NDJSON log with computed `capability_level`

### Gate G1: Core — Rollback Condition
If `validate_run_log` misses any design check, fingerprint unstable after terminal append, or staged/unstaged overlap → fix before Phase 2.

---

## Phase 2: Templates & Config

### Goal
Update all shared templates for v2 schema.

### Implementation Steps

#### 2.1 `templates/feature_list.json`

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

Add properties:
- `fingerprint_exclude` — glob array (default: `["node_modules/", ".git/", "__pycache__/", "*.pyc", ".DS_Store", "Thumbs.db"]`)
- `verification_scope` — root-relative path for no-git fingerprint scope
- Per-command: `command_origin` (`configured`|`detected`), `confirmation` (`not_required`|`pending`|`confirmed`|`rejected`)

**Removed** from schema: `capability_level` (computed by core, not user field — see Errata E1).

#### 2.3 `templates/.harness/config.json.*.example`

6 examples: `node`, `python`, `rust`, `go`, `docs`, `generic`.

`docs.example`: `"required_commands": []` — 0-step project, produces `no_checks`.

#### 2.4 `templates/init.sh`

- Create `.harness/logs/runs/` directory
- Write v2 `feature_list.json` with `revision: 1`
- Detect project type → copy matching config example
- Add `.harness/logs/` to `.gitignore`

#### 2.5 Tests

- `tests/core/test-templates.sh` — validate each example against schema
- `tests/core/test-init.sh` — init on each project type; assert `docs` gets `required_commands: []`

### Acceptance Criteria
- [ ] All 6 example configs validate against schema
- [ ] No `capability_level` field in any config example
- [ ] `init.sh` correctly detects project type
- [ ] 0-step docs project has `required_commands: []`

### Gate G2: Templates — Rollback Condition
If any example fails schema validation, or `capability_level` appears as user field → fix before Phase 3.

---

## Phase 3: Registry & Locking

(Unchanged from plan v2 — no revisions requested.)

---

## Phase 4: Adapter — Claude Code

### Goal
Refactor to Core/Adapter architecture. Backward compatible with v1.1.2 via thin wrappers.

### Implementation Steps

#### 4.1 Hook Scripts (new paths)

`adapters/claude-code/hooks/session-start.sh`, `stop-handoff.sh`:
1. Read platform hook input → normalize
2. Call core from `$SCRIPT_DIR/../../../core/`
3. Map neutral outcome → Claude protocol output (design Section 13.3)
4. Error: fail-open per event mapping

#### 4.2 v1 Compatibility Wrappers

Keep thin forwarding wrappers at old paths. These MUST contain zero business logic.

`scripts/harness-verify.sh`:
```bash
#!/bin/bash
# v1 compat wrapper — forwards to new core path
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/../core/$(basename "$0")" "$@"
```

`scripts/harness-feature.sh`, `scripts/harness-status.sh`, `scripts/harness-audit.sh`: identical pattern.

`scripts/hooks/session-start.sh`:
```bash
#!/bin/bash
# v1 compat wrapper — forwards to new adapter path
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/../../adapters/claude-code/hooks/$(basename "$0")" "$@"
```

`scripts/hooks/stop-handoff.sh`: identical pattern.

**Windows**: wrappers are copies, not symlinks. No `ln -s` anywhere in install or source.

#### 4.3 `adapters/claude-code/install.sh`

- Copies `core/`, `templates/`, `adapters/claude-code/` to target
- Also copies `scripts/` wrappers (for v1 compat)
- `--user` → `~/.claude/skills/harness-companion/`
- `--project` → `<project>/.claude/skills/harness-companion/`
- Dev mode: `--symlink-core` → symlink (Linux/macOS only; Windows: copy)

#### 4.4 Behavioral Contract Tests

`tests/adapters/test-claude-code-contract.sh`:

1. **Structural output tests**: invoke hook with controlled input → parse output → assert correct JSON shape
2. **Fail-open tests**: error input → assert `continue: true`
3. **v1 compat tests**: invoke via old `scripts/` paths → assert same behavior as new `adapters/` paths
4. **Business logic absence**: grep for forbidden patterns (state machine transitions, passing eligibility, fingerprint computation) — none found in adapter scripts or wrappers
5. **Wrapper purity**: assert wrappers contain only `SCRIPT_DIR` + `exec bash` + path resolution

### Acceptance Criteria
- [ ] `/harness:status` works under new structure
- [ ] `/harness:verify` writes canonical NDJSON log
- [ ] `/harness:feature status <id> passing` validates via `validate_run_log`
- [ ] SessionStart/Stop hooks: valid output, fail-open on error
- [ ] v1 compat: invoking via `scripts/` paths produces identical behavior
- [ ] Behavioral contract: adapter + wrapper scripts contain no core logic
- [ ] Wrapper purity: each wrapper ≤5 lines excluding comments

### Gate G4: Claude Code — Rollback Condition
If any v1.1.2 workflow breaks, hook output fails structural validation, old `scripts/` paths don't work, or wrappers contain business logic → fix before Phase 5.

---

## Phase 5: Adapter — Codex

### Goal
New adapter for Codex OS. Highest risk — Codex hook output schemas unverified.

### Pre-Implementation Research (BLOCKER — before any Codex code)

1. Run Codex with a minimal `type: "command"` hook; capture actual hook input JSON
2. Document each event's expected output format
3. Confirm `config.toml` `[[hooks]]` TOML structure
4. Confirm `PLUGIN_ROOT` / `PLUGIN_DATA` env var values at hook runtime
5. Verify Codex plugin-creator scaffold output (for `plugin.json` schema compliance)
6. Output: `docs/superpowers/research/codex-hook-schemas.md`

### Implementation Steps

#### 5.1 Plugin Manifest

`.codex-plugin/plugin.json` (at plugin root — Codex discovers it here):

```json
{
  "name": "harness-companion",
  "version": "2.0.0",
  "description": "Harness Engineering skill for reliable AI coding environments",
  "author": {
    "name": "harness-engineering"
  }
}
```

Generated via Codex plugin-creator scaffold (`codex plugin init` or equivalent). Fields conform to Codex plugin manifest schema:
- `author` is an object, not a string
- No `hooks` field — Codex discovers hooks via `<plugin_root>/hooks/hooks.json` by default
- No `platforms` — not in Codex schema
- No `requires_bash` — not in Codex schema

#### 5.2 Plugin Validation

`tests/adapters/test-codex-plugin-validate.sh`:
1. Validate `plugin.json` against Codex manifest schema (using `codex plugin validate` or schema check)
2. Validate `hooks/hooks.json` references existing script files
3. Validate `skills/harness-companion/SKILL.md` exists and is valid markdown

#### 5.3 `hooks/hooks.json` (committed artifact)

At plugin root. NOT generated at install time. References scripts at hook-runtime paths:

```json
{
  "hooks": [
    {
      "event": "SessionStart",
      "type": "command",
      "command": "bash \"<PLUGIN_ROOT>/adapters/codex/hooks/session-start.sh\"",
      "commandWindows": "<PLUGIN_ROOT>\\adapters\\codex\\hooks\\session-start.cmd",
      "timeout": 5000
    },
    {
      "event": "Stop",
      "type": "command",
      "command": "bash \"<PLUGIN_ROOT>/adapters/codex/hooks/stop-handoff.sh\"",
      "commandWindows": "<PLUGIN_ROOT>\\adapters\\codex\\hooks\\stop-handoff.cmd",
      "timeout": 5000
    },
    {
      "event": "PreToolUse",
      "type": "command",
      "command": "bash \"<PLUGIN_ROOT>/adapters/codex/hooks/pre-tool-use.sh\"",
      "commandWindows": "<PLUGIN_ROOT>\\adapters\\codex\\hooks\\pre-tool-use.cmd",
      "timeout": 5000
    }
  ]
}
```

`<PLUGIN_ROOT>` is resolved by Codex at hook runtime. Not substituted at install time.

#### 5.4 `skills/harness-companion/SKILL.md`

Codex skill entry point. Follows Codex skill format. Contains harness-companion slash commands and usage. Separate from the top-level `SKILL.md` (which is the repo overview).

#### 5.5 Hook Scripts

Each `.sh`: bash script, calls core, maps neutral outcome per design Section 13.3.
Each `.cmd`: Windows cmd script calling `.sh` via bash. **No wrapper** — explicit path baked in:

`session-start.cmd`:
```cmd
@echo off
REM Requires Git Bash or WSL bash on PATH
where bash >nul 2>&1 || exit /b 0
set "SCRIPT_DIR=%~dp0"
bash "%SCRIPT_DIR%session-start.sh"
```

Test in actual Windows `cmd.exe` environment (not Git Bash).

#### 5.6 `adapters/codex/install.sh`

Three independent modes:

| Mode | Flag | What it does |
|------|------|-------------|
| **Plugin** | N/A | Installed via Codex marketplace / `codex plugin install`. Our `install.sh` not used for plugin mode. |
| **Repo-local** | `--repo [path]` | Copies `hooks/hooks.json` (with `<PLUGIN_ROOT>` replaced by absolute path), `core/`, `adapters/codex/` to `<project>/.codex/` |
| **User** | `--user` | Writes `~/.codex/harness-hooks.toml` snippet file + instructions for manual merge into `~/.codex/config.toml` |

**User mode snippet** (`harness-hooks.toml`):
```toml
# harness-companion v2 hooks
# Merge this into your ~/.codex/config.toml [[hooks]] section manually.
[[hooks]]
event = "SessionStart"
type = "command"
command = "bash \"<INSTALL_PATH>/adapters/codex/hooks/session-start.sh\""
commandWindows = "<INSTALL_PATH>\\adapters\\codex\\hooks\\session-start.cmd"
timeout = 5000
```
`<INSTALL_PATH>` is resolved to an absolute path at snippet generation time.

**All modes**: backup before modification; idempotent (detect existing, skip or update); trust review (print hook commands, prompt user).

#### 5.7 `adapters/codex/uninstall.sh`

- **Repo-local**: removes `<project>/.codex/hooks/hooks.json` + harness files; restores backup if present
- **User**: prints instructions for removing TOML snippet (does NOT auto-edit `config.toml` — it never wrote there)
- **Plugin**: prints "uninstall via Codex marketplace" (uninstall script does not touch plugin-managed files)

Uninstall MUST NOT claim to remove content it never automatically created.

#### 5.8 Behavioral Contract Tests

`tests/adapters/test-codex-contract.sh`:

1. Plugin manifest validation (Phase 5.2)
2. `hooks/hooks.json` references valid script paths
3. Each `.sh` hook: invoke with controlled input → validate output per confirmed schema
4. Error path: exits 0, empty stdout or event-minimal valid JSON
5. Each `.cmd`: invoke in Windows `cmd.exe` → bash reached → hook executes
6. Assert absence of core logic in adapter scripts

### Acceptance Criteria
- [ ] Codex hook schemas documented (research output)
- [ ] `plugin.json` validates against Codex manifest schema
- [ ] `hooks/hooks.json` committed, not generated at install
- [ ] `skills/harness-companion/SKILL.md` present and valid
- [ ] Each `.sh` hook exits 0
- [ ] Each `.cmd` hook tested in Windows `cmd.exe`, reaches bash
- [ ] Repo-local install: `hooks/hooks.json` has absolute paths
- [ ] User install: snippet file only; no auto-edit of `config.toml`
- [ ] Uninstall: only removes what it created; user mode prints instructions
- [ ] Trust review prompt after install
- [ ] Idempotent; backup created before modification

### Gate G5: Codex — Rollback Condition
If Codex hook schemas unconfirmed, `plugin.json` fails Codex manifest validation, or any `.cmd` cannot reach bash in cmd.exe → Codex path halted. Claude Code path advances independently.

---

## Phase 6: Migration & Integration

(Content unchanged from plan v2 except backup filename fix noted below.)

### Migration Rules (design Section 16 — MUST)

| Rule | Constraint |
|------|------------|
| Only real `run_id` with canonical log that passes `validate_run_log` → association | MUST |
| Legacy string / no-run-id evidence → `legacy_audit_evidence[]` only | MUST |
| Do NOT fabricate `run_id` or association from legacy evidence | MUST |
| v1.1.2 `passing` → `unverified` with `migration_status: "replay_required"` | MUST |
| Re-verify MUST be explicit user action (`/harness:verify`), never silent in migrate | MUST |
| Dry-run MUST be the default; `--apply` flag required for writes | MUST |
| Backup every modified file with **unique timestamped filename** | MUST |
| Migration MUST be idempotent | MUST |

### Backup Filename (corrected)

```
feature_list.json.bak-20260731T151257Z   ← ISO timestamp, never overwrites
```

NOT `feature_list.json.bak-YYYYMMDD` (would overwrite if run twice same day).

### Implementation Steps (abbreviated — full detail in plan v2)

#### 6.1 `core/harness-migrate.sh`

- Dry-run default; `--apply` required for writes
- Scans evidence → canonical (valid log) vs legacy (audit only)
- Passing → `unverified` + `replay_required`
- Never fabricates associations
- Backup: `<filename>.bak-<ISO8601-timestamp>`

#### 6.2 E2E Tests

**Track A: Reusable canonical run** — v1.1.2 with valid run_id → association created → eligible for passing (if fresh).

**Track B: Replay required** — legacy evidence → `legacy_audit_evidence[]` → `unverified` → user re-verifies → eligible.

#### 6.3 Idempotent + Backup Tests

- `--apply` twice → second run no-op
- `--dry-run` after `--apply` → "up to date"
- Backup filename unique: two `--apply` runs → two distinct backup files

### Acceptance Criteria (unchanged from v2 plan)

### Gate G6: Migration — Rollback Condition
If migration fabricates any association, silently re-verifies, overwrites backups, or is not idempotent → fix before release.

---

## Risk Register

| Risk | Phase | Mitigation |
|------|-------|------------|
| Codex hook output schemas unknown | 5 | BLOCKER gate: pre-research required |
| v1.1.2 users broken by directory restructure | 4 | Thin wrappers at old `scripts/` paths |
| `mkdir` mutex unreliable on Windows Git Bash | 3 | Pressure-test in CI; file-based retry |
| macOS `flock` on APFS/network mounts | 3 | Test on target filesystem |
| Special filenames break fingerprint | 1 | NUL-delimited via temp file outside scope; golden tests |
| Migration fabricates associations | 6 | Only valid canonical logs; dry-run default |
| `.cmd` cannot reach Bash in Windows cmd.exe | 5 | Test in actual cmd.exe; exit 0 fallback |
| TOML edit corrupts user config | 5 | Snippet file only; no automated merge |
| Backup filename collision | 6 | ISO-timestamp suffix, never overwrites |

---

## File Manifest

### New Files

```
.codex-plugin/plugin.json
hooks/hooks.json
skills/harness-companion/SKILL.md
core/lib/evidence.sh
core/lib/validate-run-log.sh
core/lib/workspace-fingerprint.sh
core/lib/staleness.sh
core/lib/lock-registry.sh
core/harness-verify.sh              (rewrite)
core/harness-feature.sh             (rewrite)
core/harness-migrate.sh
adapters/codex/hooks/session-start.sh
adapters/codex/hooks/session-start.cmd
adapters/codex/hooks/stop-handoff.sh
adapters/codex/hooks/stop-handoff.cmd
adapters/codex/hooks/pre-tool-use.sh
adapters/codex/hooks/pre-tool-use.cmd
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
tests/adapters/test-codex-plugin-validate.sh
tests/e2e/test-migration-reusable.sh
tests/e2e/test-migration-replay-required.sh
tests/golden/*.ndjson (5-8 files)
```

### v1 Compat Wrappers (kept, not deleted)

```
scripts/harness-verify.sh           → forwards to core/harness-verify.sh
scripts/harness-feature.sh          → forwards to core/harness-feature.sh
scripts/harness-status.sh           → forwards to core/harness-status.sh
scripts/harness-audit.sh            → forwards to core/harness-audit.sh
scripts/hooks/session-start.sh      → forwards to adapters/claude-code/hooks/session-start.sh
scripts/hooks/stop-handoff.sh       → forwards to adapters/claude-code/hooks/stop-handoff.sh
```

### Moved Files
```
scripts/_lib/*.sh              → core/lib/
templates/CLAUDE.md            → adapters/claude-code/templates/
templates/claude-progress.md   → adapters/claude-code/templates/
```

### Updated Files
```
templates/feature_list.json          → revision, evidence_associations, legacy_audit_evidence
templates/.harness/config.schema.json → fingerprint_exclude, verification_scope, command_metadata (no capability_level)
templates/.harness/config.json.node.example
templates/.harness/config.json.python.example
templates/.harness/config.json.generic.example
templates/init.sh                    → v2 schema, project-type detection
```

---

## Approval Gates

| Gate | After | Requires | Rollback Condition |
|------|-------|----------|-------------------|
| **G1** | Phase 1 | All core tests pass; `validate_run_log` 16/16; fingerprint stable; staged/unstaged non-overlapping; NUL via temp file | Missing check, unstable fingerprint, or staged/unstaged overlap → fix before Phase 2 |
| **G2** | Phase 2 | All 6 example configs validate; no `capability_level` user field; `init.sh` project detection correct | Schema failure or `capability_level` as user field → fix before Phase 3 |
| **G3** | Phase 3 | Lock concurrency tests pass all 3 platforms; revision monotonic | Lock failure or revision skip → fix before Phase 4 |
| **G4** | Phase 4 | Claude Code behavioral contract; v1 compat wrappers work; old-path behavioral equivalence; wrappers ≤5 lines, no business logic | Any v1.1.2 workflow broken, wrappers fail forwarding, or contain business logic → fix before Phase 5 |
| **G5** | Phase 5 | Codex hook schemas confirmed; `plugin.json` validates; `hooks/hooks.json` committed artifact; `.cmd` reaches bash in cmd.exe; plugin validation gate passes | Schemas unconfirmed, manifest invalid, or cmd.exe failure → Codex halted; Claude Code continues |
| **G6** | Phase 6 | Migration never fabricates; E2E Tracks A+B pass; idempotent; backup filenames unique; all 3 platforms | Fabrication, silent re-verify, non-idempotent, or backup collision → fix before release |
| **G5b** | Phase 5 (plugin) | Plugin validation: `plugin.json` schema, `hooks/hooks.json` paths, `SKILL.md` present | Any validation failure → fix before plugin release |

---

## Requirement Traceability Matrix

| Design § | Requirement | Task | Test | Gate |
|----------|-------------|------|------|------|
| 1.2 | 6 states, 13 transitions, WIP limit | Ph3: `harness-feature.sh` | `test-passing.sh` | G3 |
| 1.3 | Fail-closed: exit 2/5/127, passing=false on validation failure | Ph1: `passing.sh`, `validate-run-log.sh` | `test-passing.sh` | G1 |
| 2.2 | 5 event types | Ph1: `evidence.sh`, `harness-verify.sh` | `golden/*.ndjson` | G1 |
| 2.2 | Terminal counts: planned/executed/passed/failed/skipped + 4 invariants | Ph1: `validate-run-log.sh` step 14a-d | `test-validate-run-log.sh` | G1 |
| 2.3 | Exactly one terminal, last line, `no_checks` allowed | Ph1: `validate-run-log.sh` step 9-11 | `test-validate-run-log.sh` | G1 |
| 2.4 | run_id in registry, evidence canonical | Ph3: registry; Ph6: migration | `test-passing.sh`, `e2e/` | G3, G6 |
| 3.0 | Unknown events rejected, field/type/enum validation | Ph1: `validate-run-log.sh` step 4-5 | `test-validate-run-log.sh` | G1 |
| 3.0 | configured→not_required, detected→confirmed | Ph1: `validate-run-log.sh` step 15 | `test-validate-run-log.sh` | G1 |
| 3.1 | run_id whitelist, path traversal, no duplicate required_command_ids | Ph1: `validate-run-log.sh` step 1-2, 10 | `test-validate-run-log.sh` | G1 |
| 5 (E1) | capability_level computed by core, not user field; L1 allows no_checks | Ph1: `harness-verify.sh`; Ph2: schema (no field) | `test-passing.sh`, `test-templates.sh` | G1, G2 |
| 6.2 | Adapter MUST NOT contain business semantics | Ph4-5: behavioral contract; Ph4: wrapper purity | `test-*-contract.sh` | G4, G5 |
| 7 | Monotonic revision, flock/mkdir, stale recovery, cross-host | Ph3: `lock-registry.sh` | `test-lock-registry.sh` | G3 |
| 8 | Different run_id = different file = zero contention | Ph1: `evidence.sh` | `test-passing.sh` | G1 |
| 9 | 8-step passing eligibility; no_checks rejected | Ph1: `passing.sh` | `test-passing.sh` | G1 |
| 10 | Workspace + config + VCS three-axis staleness | Ph1: `staleness.sh` | `test-passing.sh` | G1 |
| 11 | Built-in excludes, NUL-delimited via temp file, staged+unstaged non-overlapping | Ph1: `workspace-fingerprint.sh` | `test-workspace-fingerprint.sh` | G1 |
| 11.0 | `.harness/` unconditional exclusion, not user-overridable | Ph1: `workspace-fingerprint.sh` | `test-workspace-fingerprint.sh` | G1 |
| 11.0 | Terminal append fingerprint stability | Ph1: `workspace-fingerprint.sh` | `test-workspace-fingerprint.sh` | G1 |
| 11.0 | NUL via temp file outside scope; staged=`diff --cached HEAD`, unstaged=`diff` | Ph1: `workspace-fingerprint.sh` | `test-workspace-fingerprint.sh` | G1 |
| 12 | command_origin, confirmation, 0-step no_checks | Ph2: `config.schema.json` | `test-templates.sh` | G2 |
| 13.3 | Core neutral outcome, adapter per-event mapping, no universal fallback | Ph4-5: adapter hooks | `test-*-contract.sh` | G4, G5 |
| 14 | Plugin manifest at `.codex-plugin/plugin.json`; author object; no hooks/platforms/requires_bash | Ph5: `plugin.json` | `test-codex-plugin-validate.sh` | G5b |
| 14 | `hooks/hooks.json` committed artifact; `skills/harness-companion/SKILL.md` | Ph5: committed files | `test-codex-plugin-validate.sh` | G5b |
| 14 | PLUGIN_ROOT only at hook runtime; plugin via marketplace; repo/user independent | Ph5: install modes | `test-codex-contract.sh` | G5 |
| 14.4 | .cmd explicit path, tested in cmd.exe; no symlinks | Ph5: `.cmd` hooks | `test-codex-contract.sh` (cmd.exe) | G5 |
| 14.3 | Per-mode unique config; user = snippet only; uninstall only removes own artifacts | Ph5: `install.sh`, `uninstall.sh` | `test-codex-contract.sh` | G5 |
| 16 | Read v1.1.2, write v2, no silent overwrite, idempotent, unique backup filenames | Ph6: `harness-migrate.sh` | `e2e/test-migration-*.sh` | G6 |
| 16 | Canonical logs only, legacy→audit, passing→unverified, no auto-associate | Ph6: `harness-migrate.sh` | `e2e/test-migration-replay-required.sh` | G6 |
| 16 | Dry-run default, backup unique, idempotent, no fabrication | Ph6: `harness-migrate.sh` | `e2e/test-migration-*.sh` | G6 |
| — | v1 compat: old `scripts/` paths forward correctly; wrappers contain no business logic | Ph4: wrappers | `test-claude-code-contract.sh` (v1 paths) | G4 |
| 17 | ~45 scenarios across 6 categories | All phases | All test files | G1-G6 |

---
name: harness-companion
description: Use when working on projects that have harness engineering files (feature_list.json, AGENTS.md, init.sh) — when the user wants to set up or audit Harness Engineering practices, drive an evidence-backed feature pipeline, surface stale evidence or WIP violations at session start, hand off cleanly between sessions, or run the 7-subsystem health / 5-axis audit dashboard. v2 splits the runtime into core/ (business semantics) and adapters/ (host protocol mapping), with v1 compat wrappers preserved.
---

# Harness Companion

A Core/Adapter refactor of the v1.1.2 Harness Engineering skill. The runtime now lives in two layers:

- **`core/`** — business semantics only. Plain-text status composition, WIP=1 detection, passing-without-evidence detection, stale-evidence comparison against SessionStart baseline, handoff warnings, and the 7-subsystem × 5-axis audit dashboard. No protocol awareness.
- **`adapters/claude-code/`** — host protocol mapping. Reads stdin, parses cwd, calls core, JSON-encodes, wraps in the Claude Code envelope, fail-open on error. Currently the only adapter (Codex in Phase 5).

## When to use

- The user is in a project that has harness files (`feature_list.json`, `AGENTS.md`, `init.sh`)
- They want to bootstrap / audit / drive / verify / hand off a Harness Engineering workflow
- They need to interpret the 7-subsytem health dashboard or the 5-axis audit
- They want to surface stale evidence or WIP violations at session boundaries

## When NOT to use

- Projects without any harness files (the skill will see no `feature_list.json` and emit `suppressOutput`)
- Pure refactor / business-logic tasks (the skill is a meta-tool about the workflow, not the work)

## Commands

| Command | Purpose |
|---------|---------|
| `/harness:init` | Bootstrap harness files in a project (AGENTS.md, CLAUDE.md, init.sh, feature_list.json) |
| `/harness:status` | Compact 7-subsystem health dashboard. Cheap to run, run often. |
| `/harness:feature <id> <status> [evidence...]` | Update a feature in `feature_list.json` with a structured evidence record |
| `/harness:verify` | Run the verification chain (config-driven or `checklist.sh`) and capture evidence |
| `/harness:handoff` | Render handoff warnings (uncommitted files, dangling `in_progress`, passing-without-evidence, stale evidence, checklist reminder) |
| `/harness:audit` | Detailed 5-axis scoring per subsystem. Total out of 21. Verbose mode via `HARNESS_VERBOSE=1`. |

## Architecture (v2)

```
harness-companion/
├── core/                              # Business semantics — no protocol awareness
│   ├── harness-{verify,feature,status,audit}.sh   # CLI entrypoints
│   └── lib/                           # Shared helpers (json-helpers, baseline, evidence, status-renderer, ...)
├── adapters/
│   └── claude-code/                   # Host protocol mapping
│       ├── install.sh                 # Installs core + adapter + v1 wrappers
│       └── hooks/
│           ├── session-start.sh       # SessionStart → status text via core
│           └── stop-handoff.sh        # Stop → handoff warnings via core
├── scripts/                           # v1 compat wrappers (≤5 lines, only `SCRIPT_DIR + exec bash`)
│   ├── harness-{verify,feature,status,audit}.sh
│   └── hooks/{session-start,stop-handoff}.sh
├── templates/                         # Feature list, AGENTS.md, init.sh templates
├── tests/                             # Per-file runnable tests
└── SKILL.md                           # This file
```

### Boundaries (Design v5 §6.2)

| Concern | Owner |
|---------|-------|
| Status text rendering (file checks, feature stats, WIP=1, passing-without-evidence) | `core/lib/status-renderer.sh` |
| Handoff warnings (uncommitted files, dangling `in_progress`, stale evidence, checklist reminder) | `core/lib/status-renderer.sh` |
| SessionStart baseline persistence | `core/lib/baseline.sh` |
| Stale-evidence comparison vs baseline | `core/lib/status-renderer.sh` |
| Claude Code JSON envelope wrapping | `adapters/claude-code/hooks/*.sh` |
| Fail-open trap (`{"continue":true,"suppressOutput":true}`) | `adapters/claude-code/hooks/*.sh` |

**Hard constraint:** adapters do host protocol mapping only. Business semantics stay in `core/`. Adapters MUST NOT contain `.status=="passing"` filters, WIP detection, evidence comparison, or `fingerprint` logic — those are checked by the contract tests.

## v1 compatibility

v1.1.2 callers keep working unchanged. The `scripts/harness-*.sh` and `scripts/hooks/*.sh` wrappers are 4-line forwarders:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/../core/$(basename "$0")" "$@"
```

Identity is guaranteed by the contract test (`tests/adapters/test-claude-code-contract.sh` G3) — byte-for-byte equal output between direct core invocation and wrapper invocation.

## Hook envelopes (Claude Code)

**SessionStart:**
```json
{"continue":true,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<status text as JSON string>"}}
```

**Stop (with warnings):**
```json
{"continue":true,"systemMessage":"<handoff warnings as JSON string>"}
```

**Stop (no warnings) — fail-open:**
```json
{"continue":true,"suppressOutput":true}
```

**Failure paths — fail-open:**
```json
{"continue":true,"suppressOutput":true}
```

Any error in the adapter (cd failed, jq missing, baseline write blocked, etc.) → `{"continue":true,"suppressOutput":true}` and never block the host.

## Installation

```sh
# User-level (~/.claude/skills/harness-companion/) — default
bash adapters/claude-code/install.sh --user

# Project-level (./.claude/skills/harness-companion/)
bash adapters/claude-code/install.sh --project

# Symlink core/ (Linux/macOS only; Windows always copies)
bash adapters/claude-code/install.sh --user --symlink-core
```

The install script:
1. Copies `core/` (or symlinks with `--symlink-core`)
2. Copies `templates/`
3. Copies `adapters/claude-code/`
4. Copies `scripts/` v1 compat wrappers
5. Stamps `install-receipt.json` with `installed_at`, source commit, and SHA-256 integrity hashes
6. Registers `SessionStart` and `Stop` hooks in the appropriate `settings.json`:
   - `--user` → `~/.claude/settings.json`
   - `--project` → `<project>/.claude/settings.json`
   - Existing `hooks` block is **merged** (existing entries preserved)
   - A unique timestamped backup of `settings.json` is written before any modification
   - Repeated installs are idempotent (no duplicate hook entries)

After install, restart Claude Code to load hooks.

## See also

- `core/lib/status-renderer.sh` — reusable plain-text rendering
- `core/lib/baseline.sh` — SessionStart baseline persistence
- `core/lib/evidence.sh` — evidence record validation
- `core/lib/json-helpers.sh` — stdin JSON parsing helpers
- `tests/adapters/test-claude-code-contract.sh` — adapter contract tests (G1–G7)
- `tests/core/` — core unit + integration tests
- `docs/superpowers/specs/2026-07-31-harness-companion-v2-implementation-plan.md` — design and plan
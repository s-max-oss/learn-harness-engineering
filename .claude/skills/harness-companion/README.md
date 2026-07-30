# Harness Companion

> 🇨🇳 [简体中文](./README.zh-CN.md)

A [Claude Code](https://claude.ai/code) skill that automates Harness Engineering — the practice of building reliable coding environments for AI agents. It combines **automatic lifecycle hooks** with **interactive slash commands** to keep your project's harness files healthy.

## What It Does

| Layer | How | What |
|-------|-----|------|
| **Hooks** (automatic) | SessionStart + Stop events | Checks harness readiness on session start, reminds about handoff on session end |
| **Commands** (interactive) | 6 slash commands | Init harness scaffold, view health dashboard, manage features, run verification, generate handoff, audit all 7 subsystems |

## Quick Start

### Install

```bash
# 1. Clone this repo into your Claude Code skills directory
git clone https://github.com/s-max-oss/harness-companion.git ~/.claude/skills/harness-companion

# 2. Run the install script to register hooks
bash ~/.claude/skills/harness-companion/install.sh
```

### Commands

| Command | What It Does |
|---------|--------------|
| `/harness:init` | Generate harness scaffold from templates (AGENTS.md, CLAUDE.md, feature_list.json, init.sh, +4 optional) |
| `/harness:status` | Dashboard of file existence, feature progress, WIP=1 state, stale docs |
| `/harness:feature` | List / add / update features in `feature_list.json` (with strict state machine) |
| `/harness:verify` | Run config-driven verification (`.harness/config.json`), write structured evidence |
| `/harness:handoff` | Generate `session-handoff.md`, run checklist verification |
| `/harness:audit` | Score all 7 harness subsystems on 5 axes (existence / completeness / execution / recency / effectiveness), 0–21 total |

## The 7 Subsystems

Harness Companion is built around the 7 subsystems from the [Learn Harness Engineering](https://github.com/walkinglabs/learn-harness-engineering) course:

| # | Subsystem | Files |
|---|-----------|-------|
| 1 | **Knowledge** | `AGENTS.md`, `CLAUDE.md`, `docs/` |
| 2 | **Environment** | `init.sh` |
| 3 | **Progress** | `claude-progress.md` |
| 4 | **Scope/Feature** | `feature_list.json` |
| 5 | **Verification** | `checklist.sh`, test suite |
| 6 | **Observability** | `agent.log`, `evaluator-rubric.md` |
| 7 | **Handoff/Automation** | `session-handoff.md`, `clean-state-checklist.md`, `loop.sh` |

## Requirements

- [Claude Code](https://claude.ai/code) CLI
- Git Bash (Windows) / bash (macOS/Linux)
- `jq` — **required** for `/harness:verify` and `/harness:feature`. The scripts
  fail closed with an install hint if `jq` is missing. See `docs/INSTALL.md` for
  the one-line installer (`winget install jqlang.jq` / `brew install jq` /
  `apt-get install jq`).
- Optional: `python3` (used as a JSON-encode fallback by the hooks when `jq`
  is absent; not required)

## File Structure

```
harness-companion/
├── SKILL.md                  # Main skill document (6 workflows)
├── README.md                 # English readme (this file)
├── README.zh-CN.md           # 简体中文说明
├── LICENSE                   # MIT
├── install.sh                # One-command install + hook registration
├── scripts/
│   ├── harness-init.sh       # Scaffold generator
│   ├── harness-status.sh     # Health dashboard
│   ├── harness-feature.sh    # Feature list CRUD
│   ├── harness-verify.sh     # Verification chain runner
│   ├── harness-handoff.sh    # Session handoff generator
│   ├── harness-audit.sh      # 7-subsystem auditor
│   └── hooks/
│       ├── session-start.sh  # SessionStart hook
│       └── stop-handoff.sh   # Stop hook
├── references/
│   ├── harness-files.md      # Full format reference
│   ├── subsystems-mapping.md # Subsystems ↔ files ↔ lessons
│   ├── verification-config.md   # `.harness/config.json` schema (v1)
│   └── feature-state-machine.md # Allowed transitions, evidence rules, override audit
├── scripts/
│   └── _lib/                 # Shared bash library (atomic_write, json_input, harness_config, evidence)
└── templates/
    ├── .harness/
    │   ├── config.json.node.example
    │   ├── config.json.python.example
    │   ├── config.json.generic.example
    │   └── schema/config.schema.json
    └── harness file templates (copy-paste ready)
        ├── AGENTS.md
        ├── CLAUDE.md
        ├── feature_list.json
        ├── init.sh
        ├── claude-progress.md
        ├── session-handoff.md
        ├── clean-state-checklist.md
        └── checklist.sh
└── tests/
    ├── run-all.sh            # Run all characterization tests
    ├── lib/harness_test.sh   # Pure-bash test runner
    ├── *.test.sh             # 6 test files
    └── fixtures/             # 6 minimal project fixtures
```

## How Hooks Work

Two hooks run automatically — no slash command needed:

- **SessionStart**: Detects harness files → reports health status → injects context into Claude's system prompt
- **Stop**: Checks for uncommitted changes → detects dangling in_progress features → reminds to run checklist.sh

Hooks are **non-blocking** (always return `{"continue":true}`) and **gracefully skip** non-harness projects (no `feature_list.json` → silent exit). They use a structured JSON parser (`scripts/_lib/json_input.sh`) that prefers `jq`, falls back to `python3`, and never crashes on Windows-style paths.

## Recent changes (v1)

- **`/harness:verify` is now config-driven.** The hardcoded `npm/npx tsc` chain
  was removed. Drop a `.harness/config.json` (use `templates/.harness/config.json.node.example`
  as a starter) and the script picks up its commands from there. Project type
  no longer determines whether `tsc` runs — Python and generic projects can
  coexist with Node/TS projects in the same workspace.
- **Evidence is structured, not free text.** Each verified command writes a
  JSON object with `id` / `command[]` / `exit_code` / `started_at` /
  `duration_seconds` / `commit` / `log_hash` into the feature's `evidence[]`.
  Strings are rejected on `passing` transitions.
- **Feature state machine is explicit.** The full transition table is in
  `references/feature-state-machine.md`. Any transition not on the list is
  refused (no warnings). Promoting to `passing` without evidence requires
  `--override "<reason>"`, which records an audit object on the feature.
- **`/harness:audit` scores on 5 axes** (existence / completeness / execution /
  recency / effectiveness), not file presence. The output is byte-deterministic
  across consecutive runs and supports `--snapshot-at <git_ref>` for historical
  scoring.
- **Self-tests live in `tests/`.** `bash tests/run-all.sh` exercises verify,
  feature, audit, status, and both hooks. Tests skip cleanly when `jq` is
  missing so CI on bare hosts still passes.
- **Hooks parse JSON reliably.** The `set -euo pipefail` crash on Windows-style
  `cwd` paths is fixed. Output uses ASCII markers (`[OK]`/`[NO]`/`[!!]`/`[--]`)
  so emoji survive Git Bash → jq → Claude Code without surrogate-pair mojibake.

See `MIGRATION.md` for what changed relative to v0 and how to upgrade.

## License

MIT — see [LICENSE](./LICENSE)

# Harness Companion

> **Version:** 2.0.0-rc.1 — see [CHANGELOG.md](CHANGELOG.md)

A structured engineering workflow for AI coding agents. Tracks features
via `feature_list.json`, associates each "passing" feature with evidence
(run logs, commits, fixtures), scores project health across 7 subsystems
on 5 axes, enforces WIP=1, injects a status snapshot at session start,
and emits handoff warnings at session stop.

This is the **v2 layout** — a `core/` engine is wrapped by thin
**per-host adapters**. v1.1.2 callers can keep using the old `scripts/`
paths via the v1 compat wrappers.

```
harness-companion/
├── core/                 # business semantics (plain text, no protocol)
├── adapters/
│   ├── claude-code/      # Claude Code SessionStart + Stop mapping
│   └── codex/            # Codex CLI plugin/hooks mapping
├── scripts/              # v1.1.2 compat wrappers (zero business logic)
├── templates/            # canonical config templates
├── hooks/                # Codex event-keyed hook registry
├── .codex-plugin/        # Codex marketplace manifest
├── SKILL.md              # Claude Code skill definition
└── tests/                # contract + regression suites
```

## Which host are you on?

| Host | Adapter | Status |
|---|---|---|
| **Claude Code** | `adapters/claude-code/` | Supported (Phase 4) |
| **Codex CLI** | `adapters/codex/` | Supported (Phase 5b) |

If you use both, install both — they share `core/` but register different
hooks in each host's settings.

## Installation

Both adapters ship an `install.sh` that supports a small set of modes.
Choose the mode that matches where you want the install to land.

### Mode: `--user` (global, default)

Installs to your **user-level config dir**, so the adapter activates for
every project you open with that host.

```sh
# Claude Code
bash adapters/claude-code/install.sh --user

# Codex
bash adapters/codex/install.sh --user
```

**Use when:** you want the workflow in every project on this machine
without re-installing.

### Mode: `--project` / `--repo` (per-project)

Installs into the **current project's config dir**, so only this project
sees the adapter. Safe for repos where you don't want to mutate global
config.

```sh
# Claude Code
cd <your-project>
bash <harness-companion>/adapters/claude-code/install.sh --project

# Codex
cd <your-project>
bash <harness-companion>/adapters/codex/install.sh --repo
```

**Use when:** you're trying Harness Engineering in a single project, or
working on a team that hasn't standardized on it yet.

### Mode: plugin (Codex only)

Codex has a separate "plugin marketplace" install path that this script
does **not** handle. Run the script with no `--user` / `--repo` flag and
follow the printed instructions to register the repo via the Codex
marketplace.

```sh
bash adapters/codex/install.sh          # prints Codex marketplace instructions
```

**Use when:** you want Codex to discover the plugin via its built-in
plugin manager rather than via repo-local hooks.

### Optional: `--symlink-core` (Claude Code, Linux/macOS)

Symlinks `core/` into the install target instead of copying it. Lets you
edit `core/` in the source tree and see changes immediately in the
installed copy. **Ignored on Windows** (Windows always copies).

```sh
bash adapters/claude-code/install.sh --user --symlink-core
```

## Platform requirements

### All platforms

- `bash` 4+ on PATH (Git Bash on Windows; system bash on Linux/macOS)
- Python 3.x OR `jq` OR PowerShell (for JSON encoding — see below)

### Windows specifically

- **Git for Windows** must be installed and `bash.exe` on PATH. The
  Codex `.cmd` wrappers locate `bash.exe` via `where`, then build a
  POSIX `PATH=/usr/bin:/bin:$PATH` inside the bash subprocess before
  invoking the hook script. Without Git Bash, Codex `commandWindows`
  hooks will not run.
- **Recommended**: install Git for Windows via the official installer
  (ships with `bash`, `dirname`, `cygpath`, and often `jq`).

### JSON runtime fallback

Hooks need to wrap plain-text status into a JSON envelope. The shared
helper (`core/lib/json-encode.sh`) probes each candidate runtime by
**executing a real JSON round-trip** (not just `command -v`), so a stub
`py.exe` that prints "No installed Python found!" is correctly skipped.

| Order | Runtime | Probe |
|---|---|---|
| 1 | `python3` | `python3 -c 'import json,sys; print(json.dumps("ok"))'` |
| 2 | `python`  | `python -c 'import json,sys; print(json.dumps("ok"))'` |
| 3 | `py -3`   | `py -3 -c 'import json,sys; print(json.dumps("ok"))'` |
| 4 | `jq`      | `echo '{}' | jq -e .` |
| 5 | `powershell` | `ConvertTo-Json -Compress` round-trip |

The first probe that exits 0 wins. **PowerShell is recommended on Windows**
because it ships with the OS and is more reliable than third-party
runtimes. Install `python3` or `jq` only if PowerShell is unavailable.

## What each hook does

| Hook | Behavior |
|---|---|
| **SessionStart** (Claude Code + Codex) | Renders the 7-subsystem health dashboard and the 5-axis audit score; injects as `hookSpecificOutput.additionalContext` (Codex) or session-start context (Claude Code). Persists a baseline SHA for stale-evidence comparison. |
| **Stop** (Claude Code + Codex) | Emits handoff warnings for: dangling `in_progress` features (WIP>1), passing-without-evidence, uncommitted files, stale evidence vs baseline, checklist reminder. Output as `systemMessage` (Codex) or session context (Claude Code). |
| **PreToolUse** (Codex only) | **Permissive fail-open** today — returns `{"continue":true}` with a "policy not enabled" notice. Enforcement of tool policies is a future phase; the hook is wired up but does not yet block. |

## Running the test suites

All test scripts are self-contained bash and run from the
`harness-companion/` directory.

```sh
# Codex adapter contract (122 checks)
bash tests/adapters/test-codex-contract.sh

# Codex adapter install modes (42 checks)
bash tests/adapters/test-codex-install-modes.sh

# Claude Code adapter contract (141 checks)
bash tests/adapters/test-claude-code-contract.sh

# Core regression (11 suites, ~277 checks)
for t in tests/core/test-*.sh; do bash "$t"; done

# Codex marketplace validator (PyYAML required at runtime)
python3 "$HOME/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py" .
```

The Codex contract suite invokes the `.cmd` wrappers via real
`cmd.exe` under three runtime scenarios (normal Python, no Python at all,
and a broken-py.exe stub) to verify the runtime probe correctly falls
through to `jq` or `powershell` when needed.

## Known limitations (rc.1)

- **PreToolUse is permissive fail-open.** The hook runs but does not
  block any tool call. Status field: `pretooluse_status=policy_not_enabled`.
- **Windows Codex sandbox is degraded.** `commandWindows` wrappers need
  Git Bash on PATH; without it Codex hooks will not execute.
- **No CI workflow** for harness-companion test suites yet. Local
  regression must be run before tagging a release. The Codex marketplace
  validator requires `PyYAML` at runtime — install it via
  `pip install PyYAML` if your environment does not have it.
- **`validate_plugin.py` requires PyYAML.** The harness-companion
  contract treats `ModuleNotFoundError: yaml` as a failure, not a
  pass-by-omission. Install before running:
  `pip install PyYAML`.

## License

MIT — see repository root.
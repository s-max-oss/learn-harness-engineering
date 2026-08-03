---
name: harness-companion
description: Harness Engineering — reliable AI coding environments via project-local contracts (Phase 5 Codex adapter)
---

# harness-companion (Codex)

Project-local contract for AI-assisted engineering work. Mirrors the
Claude Code adapter's `SKILL.md` semantics but uses Codex-targeted
conventions: `AGENTS.md` (knowledge entry), `codex-progress.md` (progress),
and Codex hook events (SessionStart, Stop, PreToolUse).

## When to Use

Activate this skill when working in a project that contains:
- `feature_list.json` (canonical feature registry, schema v2)
- `.harness/config.json` (verification config)
- `AGENTS.md` (this skill's knowledge entry)

## Slash Commands

- `/harness:status` — read-only status snapshot via `bash core/harness-status.sh`
- `/harness:feature add <id> <title>` — register a new feature
- `/harness:verify <feature_id>` — produce evidence association
- `/harness:audit` — 5-axis subsystem audit

## Hook Surface (Phase 5a)

| Hook | Phase 5a behavior |
|------|-------------------|
| `SessionStart` | fail-open (empty stdout) — schema unconfirmed |
| `Stop` | fail-open (empty stdout) — schema unconfirmed |
| `PreToolUse` | fail-open (empty stdout) — schema unconfirmed |

Per design §13.3, fail-open is the only correct behavior until Codex CLI
research produces `docs/superpowers/research/codex-hook-schemas.md`.

## References

- `docs/superpowers/specs/2026-07-31-harness-companion-generalization-design.md` §13, §14
- `docs/superpowers/specs/2026-07-31-harness-companion-v2-implementation-plan.md` §5
- `docs/superpowers/plans/2026-08-01-harness-companion-phase5-codex.md`

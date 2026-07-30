# Feature State Machine

`feature_list.json` features move through a small set of states. Transitions
that aren't on this list are rejected by `harness-feature.sh status` — no
warnings, no override.

## States

| State | Meaning |
|---|---|
| `not_started` | Feature is in the spec but work has not begun. |
| `in_progress` | Exactly one feature is in_progress at any time (WIP=1 default). |
| `blocked` | Work can't continue. The `notes` field should record the blocker. |
| `passing` | Verification has succeeded; `evidence[]` is non-empty. |
| `unverified` | Manually marked; audit-only. Bypasses the evidence-required rule. |
| `deprecated` | Retired from scope. Terminal unless reactivated. |

## Allowed transitions

```
not_started   → in_progress | blocked | deprecated
in_progress   → passing | blocked | not_started | deprecated
blocked       → in_progress | not_started | deprecated
unverified    → in_progress | blocked | passing | deprecated
passing       → in_progress | deprecated
deprecated    → in_progress | not_started
```

Anything else exits non-zero with a message naming the rejected edge. There
is no `--force` flag — the only way to bypass a transition is to
re-`add` the feature, which is rarely what you want.

## Why these specific edges

- **`not_started → in_progress | blocked | deprecated`**: every feature must
  start by being claimed, refused, or killed.
- **`in_progress → passing | blocked | not_started | deprecated`**: a feature
  in motion can finish, get stuck, be rolled back, or be retired. It cannot
  jump straight to `passing` without evidence (see below).
- **`blocked → in_progress | not_started | deprecated`**: you don't "complete"
  a blocker; you resolve it (move back into motion) or kill the work.
- **`unverified → in_progress | blocked | passing | deprecated`**: `unverified`
  is a holding pen for features that need re-review. They can move forward
  or be re-done.
- **`passing → in_progress | deprecated`**: once verified, a feature only
  leaves `passing` if re-verification failed or it's retired. There is no
  way to "unverify" — that's what `in_progress` is for.
- **`deprecated → in_progress | not_started`**: deprecated features can be
  revived, but never go directly to `passing`. Re-run verify first.

## Evidence requirement

Promoting to `passing` requires `evidence[]` to be non-empty. The evidence
records must be **structured objects** with at least `command`, `exit_code`,
and `started_at`. A feature whose `evidence[]` is empty or contains only
strings will be refused.

If `verify` hasn't been run yet, the script exits with this message:

```
Error: feature 'f-001' has no evidence. Run /harness:verify first.
If you must proceed anyway, use: status f-001 unverified --override "<reason>"
```

If `--override "<reason>"` is provided AND the requested status is `passing`,
the script **routes the transition to `unverified`** instead. This is by
design: `unverified` is the only "I know what I'm doing" exit, and it
records an audit object.

## Override audit record

When `--override "<reason>"` is used, the feature gets:

```json
"override": {
  "by": "<HARNESS_OPERATOR or whoami>",
  "at": "2026-07-27T10:00:00Z",
  "reason": "ship-blocking regression in f-002",
  "missing_evidence": ["typecheck", "build"]
}
```

`HARNESS_OPERATOR` env var overrides `whoami` so CI scripts can attribute
overrides correctly (e.g. `HARNESS_OPERATOR=ci-bot bash harness-feature.sh …`).

The audit script reports any features with an `override` field whose
`evidence[]` is still empty — those are "passing on a promise" and worth
reviewing.

## WIP limit

The number of features in `in_progress` cannot exceed `feature_list.wip_limit`
from `.harness/config.json` (default `1`). Attempting to start a third
in-progress feature exits non-zero and names the existing in-progress
features so you can finish or roll one back first.

There is no `--force` flag. The override record above is for evidence gaps,
not WIP violations. To start a second feature, finish (or block) the first.

## Atomic writes

Every status mutation writes via `mktemp + mv -f` (see
`scripts/_lib/atomic_write.sh`). A crash mid-write leaves the previous
`feature_list.json` intact rather than truncating it. This is the only way
multi-session agents should be mutating this file — never edit it from your
editor while `verify` is running.

## Examples

```bash
# Claim work
bash scripts/harness-feature.sh status f-001 in_progress

# Run verification
bash scripts/harness-verify.sh f-001 . --write

# Promote (now allowed because evidence exists)
bash scripts/harness-feature.sh status f-001 passing

# Without verify: route to unverified instead
bash scripts/harness-feature.sh status f-001 unverified --override "merged despite missing CI"

# Re-verify after a regression
bash scripts/harness-verify.sh f-001 . --write     # may exit 1
bash scripts/harness-feature.sh status f-001 in_progress   # passing → in_progress
# … fix the regression …
bash scripts/harness-verify.sh f-001 . --write
bash scripts/harness-feature.sh status f-001 passing
```
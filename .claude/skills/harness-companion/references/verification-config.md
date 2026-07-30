# Verification Config (`.harness/config.json`)

`/harness:verify` is now config-driven. It loads `.harness/config.json` from the
project root, iterates `verification.commands[]`, and only runs commands whose
`applies_when` predicate matches the project state.

This replaces the v0 hardcoded `npx tsc --noEmit` / `npm run build` / `npm test`
fallbacks that mis-fired on Python and generic projects.

## Schema (v1)

```json
{
  "schema_version": 1,
  "project_type": "node | python | generic",
  "verification": {
    "min_required_for_passing": ["typecheck", "build"],
    "commands": [
      {
        "id": "typecheck",
        "command": ["npx", "tsc", "--noEmit"],
        "timeout_seconds": 180,
        "required_for_passing": true,
        "applies_when": { "package_json_has_script": "typecheck" }
      }
    ]
  },
  "feature_list": {
    "wip_limit": 1,
    "allow_force_passing": false,
    "force_requires": ["override_reason"]
  }
}
```

### `schema_version`

Must equal `1`. Future breaking changes will bump this and the script will
refuse to load mismatched configs.

### `project_type`

Enum: `node | python | generic`. Used by `harness-init.sh` to pick a starter
template and by the audit script to score Environment completeness.

### `verification.commands[]`

Each command is an argv array (NOT a shell string). Use `command[]` so quoting
is unambiguous.

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Unique within this config. Used in evidence records and audit logs. |
| `command` | yes | Argv array. Run as `command[0] command[1] …` (no shell interpolation). |
| `timeout_seconds` | yes | Hard cap. Commands exceeding this are killed and reported as `failed`. |
| `required_for_passing` | yes | If `true`, the feature cannot reach `passing` unless this command's exit code is 0. |
| `applies_when` | no | Predicate. If absent, the command always applies. |

`applies_when` is one of:

- `{ "files_any": ["package.json", "tsconfig.json"] }` — true iff at least one
  of these files exists at the project root.
- `{ "package_json_has_script": "typecheck" }` — true iff `package.json`
  exists and has a `scripts.typecheck` field.

Predicates are evaluated by `scripts/_lib/harness_config.sh`. The script
refuses to silently skip a required command on a predicate miss — it reports
`not_applicable` so you can fix the predicate or the file layout.

### `verification.min_required_for_passing`

Optional array of command `id`s. A feature reaches `passing` only if **every**
id listed here passed. Defaults to "all commands with `required_for_passing: true`."

### `feature_list.wip_limit`

Default `1`. `harness-feature.sh status <id> in_progress` is rejected if the
limit is already reached.

### `feature_list.allow_force_passing`

Default `false`. When `true`, `--override "<reason>"` can promote a feature
directly to `passing` even without evidence. Audit records the override.

### `feature_list.force_requires`

Default `["override_reason"]`. List of fields every override must include.
For example, `["override_reason", "ticket_id"]` to demand ticket context.

## Evidence records

Each verified command writes one structured record into the feature's
`evidence[]`:

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
  "log_sha256": "6dcd4ce23d88e…",
  "run_id": "20260730T151257Z-12345-32767"
}
```

v1.1.1 passing validation (latest-run-only):
1. Evidence objects (string evidence from v0 is rejected)
2. Only records from the **latest `run_id`** are considered
3. All considered records have `exit_code: 0`
4. Considered records cover every `required_for_passing != false` command
5. Latest run's `.commit` matches current HEAD (git repos only)

Records from different historical runs cannot be combined to satisfy passing
requirements.

The audit script and feature state machine read these records. Do not write
hand-crafted string evidence — `harness-feature.sh` will refuse a `passing`
transition that lacks structured, complete, current evidence.

## Status outcomes

`harness-verify.sh` exits with one of four codes:

| Code | Meaning |
|---|---|
| 0 | All required commands passed; `--write` flipped feature to `passing` |
| 1 | A required command failed; nothing mutated |
| 2 | Not configured (no `.harness/config.json` or `jq` missing) |
| 3 | Stale — no commands ran and previous evidence.commit ≠ HEAD; re-run verify |

`--write` is required to mutate `feature_list.json`. Without it, the script
runs everything, prints a "would-pass (dry-run)" summary, and exits without
changing any file. This prevents accidental state corruption in CI scripts.

## Hard requirements

- **`jq` is mandatory.** The script exits 2 with a clear install message if
  `jq` is missing. Do not add a fallback that pretends things passed.
- **`.harness/config.json` must exist** or the script exits 2 immediately.
- **No shell strings in `command[]`.** Use argv arrays to avoid quoting bugs.
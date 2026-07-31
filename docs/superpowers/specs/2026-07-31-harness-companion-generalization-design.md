# harness-companion 通用化升级 — 方案设计 v5

> 状态: **Approved** | 日期: 2026-07-31 | 修订: v5（含勘误）
> v4 (已撤回) → v5: 最终 correctness 修订
> v5 勘误: workspace fingerprint 自排除 + NUL-delimited、validate_run_log 字段/枚举验证、mkdir lock metadata + 跨主机恢复规则

---

## 决策摘要

| 决策 | 结论 |
|------|------|
| Codex adapter | 路径 A：Bash command hooks + 共享 Bash core |
| Level 1 verify | 路径 B：`.harness/logs/runs/<run_id>.ndjson` |
| Capability 模型 | 累积 maturity：Level 2 ⊃ Level 1 ⊃ Level 0 |
| Evidence 模型 | Per-run immutable NDJSON：`run_started` → `command_completed` × N → terminal |
| execution_status | 由 event type 表达，不作为独立字段 |
| Registry versioning | 单调递增 revision（非 content_hash） |

---

## v4 → v5 变更摘要

| # | v4 问题 | v5 修正 |
|---|---------|---------|
| 1 | workspace fingerprint：仅在 old ≠ clean 时计算；不覆盖 staged/untracked；no-git 固定返回 "no_git"；terminal event 不保存 fingerprint | 始终计算 current fingerprint；包含 staged + unstaged + untracked；no-git 对 verification scope 计算内容 hash；`run_started` 保存 initial fingerprint，terminal event 保存 verified fingerprint，passing 比较 current 与 terminal verified |
| 2 | 无 canonical run log 验证函数 | 新增 `validate_run_log()`：run_id 白名单、路径穿越防护、event 结构完整性、command_id 唯一性、coverage、confirmation、schema_version。任一失败 → passing=false |
| 3 | content_hash 自引用；lock 实现未区分平台 | 改为单调递增 revision；Linux 优先 flock，macOS/Git Bash 用 mkdir lock fallback；mkdir lock metadata 含 PID/hostname/timestamp/ownership token；stale lock recovery 验证 ownership |
| 4 | Codex fail-open：PreToolUse 输出 continue；未确认 schema 时 fallback 到 `{"continue":true}` | 删除 PreToolUse 的 continue 输出；未确认 schema 时 exit 0 + empty stdout；每个 event 只输出官方支持字段；PreCompaction → PreCompact |
| 5a | `execution_status` 作为独立字段 | 删除。`command_completed` event type 即表达执行完成 |
| 5b | `run_completed` 是否允许 `overall_result=no_checks` | 允许。`run_completed` 仅表示 run 正常结束。passing eligibility 额外检查 `overall_result == "passed"` |
| 5c | `schema_version` 作用域不明确 | 每个 run log 一个 `schema_version`（定义于 `run_started`） |
| 5d | `commandWindows` 未说明依赖 | 明确标注：commandWindows .cmd 脚本仍依赖可用 Bash runtime（调用 core） |

---

## 目录

1. [Semantic Core Invariants](#1-semantic-core-invariants)
2. [Canonical Evidence Data Model](#2-canonical-evidence-data-model)
3. [Canonical Run Log Validation](#3-canonical-run-log-validation)
4. [通用语义 vs 首期 Runtime](#4-通用语义-vs-首期-runtime)
5. [Capability Maturity Model](#5-capability-maturity-model)
6. [Architecture: Core/Adapter](#6-architecture-coreadapter)
7. [Registry Locking Protocol](#7-registry-locking-protocol)
8. [Run Log Concurrency Protocol](#8-run-log-concurrency-protocol)
9. [Passing Eligibility](#9-passing-eligibility)
10. [Evidence Staleness](#10-evidence-staleness)
11. [Workspace Fingerprint](#11-workspace-fingerprint)
12. [Verification Plan](#12-verification-plan)
13. [Hook Fail-Open Contract](#13-hook-fail-open-contract)
14. [Codex Adapter Design](#14-codex-adapter-design)
15. [安全模型](#15-安全模型)
16. [向后兼容与迁移](#16-向后兼容与迁移)
17. [测试矩阵](#17-测试矩阵)
18. [风险与未验证假设](#18-风险与未验证假设)
19. [Non-Goals](#19-non-goals)
20. [附录](#20-附录)

---

## 1. Semantic Core Invariants

### 1.1 Evidence Schema

Evidence 以 per-run immutable NDJSON log 存储：`.harness/logs/runs/<run_id>.ndjson`。

### 1.2 Feature State Machine（Level 2）

状态：`not_started`, `in_progress`, `blocked`, `passing`, `unverified`, `deprecated`

合法 transition（未列出即拒绝）：

| from | to | 条件 |
|------|----|------|
| `not_started` | `in_progress` | WIP limit 未超 |
| `not_started` | `blocked` | — |
| `in_progress` | `passing` | `is_eligible_for_passing()` = true |
| `in_progress` | `blocked` | — |
| `in_progress` | `unverified` | `--override` 提供 reason |
| `blocked` | `in_progress` | WIP limit 未超 |
| `blocked` | `unverified` | `--override` 提供 reason |
| `passing` | `in_progress` | — |
| `passing` | `deprecated` | — |
| `unverified` | `in_progress` | — |
| `unverified` | `deprecated` | — |
| any | `deprecated` | — |

### 1.3 Fail-Closed 语义

| 场景 | Exit code |
|------|-----------|
| jq 不可用 | 2 |
| `.harness/config.json` 不存在（Level 1+） | 2 |
| 验证命令二进制不存在 | 该 step exit_code = 127，terminal = `run_failed` |
| 所有 evidence 的 run_id 为 null（Level 2） | 2 |
| Registry lock 获取 timeout | 5 |
| `validate_run_log()` 返回 non-null error | passing eligibility = false |
| Association 指向不存在/损坏的 run log | passing eligibility = false |
| 0 required steps 执行 | `overall_result = "no_checks"` → passing eligibility = false |

### 1.4 原子写入

所有 mutation MUST 通过 temp file + atomic rename（详见第 7 节锁定协议）。

### 1.5 Architecture Invariant

Adapter MUST NOT 包含业务语义。详见第 6.2 节。

---

## 2. Canonical Evidence Data Model

### 2.1 Schema Version

`schema_version` 定义于 `run_started` event。同一 run 内所有 event SHALL 遵守该版本的 schema。当前值为 `2`。

### 2.2 Event Types

#### `run_started` — 每个 run 的第一个 event（MUST 为第一行）

```json
{
  "event": "run_started",
  "schema_version": 2,
  "run_id": "20260731T151257Z-12345-32767",
  "started_at": "2026-07-31T15:12:57Z",
  "project_root": "/abs/path/to/project",
  "vcs_revision": "abc1234def56",
  "vcs_revision_source": "git",
  "workspace_fingerprint_initial": "sha256:abcd1234...",
  "config_sha256": "sha256:efgh5678...",
  "required_command_ids": ["typecheck", "unit-test"],
  "capability_level": 1,
  "feature_id": null
}
```

`workspace_fingerprint_initial` 计算方式见第 11 节。

#### `command_completed` — 每个 verification step 完成后

```json
{
  "event": "command_completed",
  "schema_version": 2,
  "run_id": "20260731T151257Z-12345-32767",
  "command_id": "typecheck",
  "command": ["npx", "tsc", "--noEmit"],
  "command_origin": "configured",
  "confirmation": "not_required",
  "exit_code": 0,
  "started_at": "2026-07-31T15:12:57Z",
  "duration_ms": 12400,
  "log_artifact": ".harness/logs/runs/20260731T151257Z-12345-32767/typecheck.log",
  "log_sha256": "sha256:ijkl9012..."
}
```

`command_completed` event type 即表达执行完成（无论 exit_code）。不存在独立的 `execution_status` 字段。

#### `run_completed` — 全部 required commands 执行完毕且全部通过

```json
{
  "event": "run_completed",
  "schema_version": 2,
  "run_id": "20260731T151257Z-12345-32767",
  "completed_at": "2026-07-31T15:13:12Z",
  "overall_result": "passed",
  "workspace_fingerprint_verified": "sha256:abcd1234...",
  "planned_commands": 2,
  "executed_commands": 2,
  "passed_commands": 2,
  "failed_commands": 0,
  "skipped_commands": 0
}
```

`workspace_fingerprint_verified`：terminal event 写入时的 fingerprint。Passing eligibility 比较此项与当前 fingerprint。

**Terminal count invariants**（MUST hold）：
- `executed_commands = passed_commands + failed_commands`
- `planned_commands = executed_commands + skipped_commands`
- `command_completed` event 数量 = `executed_commands`

#### `run_failed` — 至少一个 required command 失败

```json
{
  "event": "run_failed",
  "schema_version": 2,
  "run_id": "20260731T151257Z-12345-32767",
  "completed_at": "2026-07-31T15:13:12Z",
  "overall_result": "failed",
  "workspace_fingerprint_verified": "sha256:abcd1234...",
  "planned_commands": 2,
  "executed_commands": 2,
  "passed_commands": 1,
  "failed_commands": 1,
  "skipped_commands": 0,
  "failed_command_ids": ["unit-test"]
}
```

#### `run_aborted` — 外部中断

```json
{
  "event": "run_aborted",
  "schema_version": 2,
  "run_id": "20260731T151257Z-12345-32767",
  "completed_at": "2026-07-31T15:13:02Z",
  "overall_result": "aborted",
  "workspace_fingerprint_verified": null,
  "abort_reason": "timeout",
  "planned_commands": 2,
  "executed_commands": 1,
  "passed_commands": 1,
  "failed_commands": 0,
  "skipped_commands": 1
}
```

### 2.3 Terminal Event Rules

| 规则 | 约束 |
|------|------|
| 每个 run log MUST 包含恰好一个 terminal event | MUST |
| Terminal event MUST 为 log 的最后一行 | MUST |
| `run_started` MUST 为 log 的第一行 | MUST |
| `run_completed` 允许 `overall_result: "no_checks"`（0 required steps 时） | 此时 passing eligibility 因 required_command_ids 为空而返回 false |
| 0 required steps 时 `overall_result` SHALL 为 `"no_checks"` | MUST NOT 为 `"passed"` |

### 2.4 Feature Association Schema（Level 2）

```json
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
```

Feature registry 不复制 evidence。Passing eligibility 通过 `run_id` → canonical log file → `validate_run_log()` 获取。

---

## 3. Canonical Run Log Validation

### 3.0 Canonical Event Set & Field Definitions

**Valid event types**：`run_started`, `command_completed`, `run_completed`, `run_failed`, `run_aborted`。任何不在该集合中的 `event` 值 MUST 被拒绝。

**Per-event required fields and types**：

```
run_started REQUIRED:
    event: string = "run_started"
    schema_version: integer (≥1)
    run_id: string
    started_at: string (ISO 8601)
    project_root: string
    vcs_revision: string|null
    vcs_revision_source: string|null
    workspace_fingerprint_initial: string
    config_sha256: string
    required_command_ids: string[] (no duplicates)
    capability_level: integer (0|1|2)
    feature_id: string|null

command_completed REQUIRED:
    event: string = "command_completed"
    schema_version: integer
    run_id: string
    command_id: string (non-empty)
    command: string[] (non-empty)
    command_origin: string ∈ {"configured", "detected"}
    confirmation: string ∈ {"not_required", "pending", "confirmed", "rejected"}
    exit_code: integer
    started_at: string (ISO 8601)
    duration_ms: integer (≥0)

run_completed | run_failed | run_aborted REQUIRED:
    event: string ∈ {"run_completed", "run_failed", "run_aborted"}
    schema_version: integer
    run_id: string
    completed_at: string (ISO 8601)
    overall_result: string ∈ {"passed", "no_checks"} (run_completed)
                   | string ∈ {"failed"}              (run_failed)
                   | string ∈ {"aborted"}             (run_aborted)
    workspace_fingerprint_verified: string|null
    planned_commands: integer (≥0)
    executed_commands: integer (≥0)
    passed_commands: integer (≥0)
    failed_commands: integer (≥0)
    skipped_commands: integer (≥0)
    failed_command_ids: string[] (required for run_failed)
    abort_reason: string (required for run_aborted)
```

**Origin–confirmation invariants**：

| `command_origin` | 合法 `confirmation` |
|------------------|---------------------|
| `configured` | `not_required` ONLY |
| `detected` | `confirmed` ONLY（执行后） |

`detected` + `confirmation=pending` 的 `command_completed` MUST NOT 存在 — 因为 pending 表示尚未执行。

### 3.1 `validate_run_log(run_id, association)` 伪代码

```
KNOWN_EVENTS = {"run_started", "command_completed", "run_completed", "run_failed", "run_aborted"}

function validate_run_log(run_id, assoc):
    // ---- 1: run_id character whitelist ----
    if !run_id.matches(/^[A-Za-z0-9._-]+$/):
        return {valid: false, reason: "run_id_invalid_characters"}
    if run_id.contains("..") || run_id.startsWith("/") || run_id.startsWith("\\"):
        return {valid: false, reason: "run_id_path_traversal"}
    
    // ---- 2: Resolved path must be inside runs/ ----
    log_path = resolve(".harness/logs/runs/" + run_id + ".ndjson")
    if !log_path.startsWith(resolve(".harness/logs/runs/")):
        return {valid: false, reason: "log_path_escape"}
    
    // ---- 3: File must exist and be parseable ----
    if !file_exists(log_path):
        return {valid: false, reason: "run_log_missing", run_id: run_id}
    
    lines = read_all_lines(log_path)
    events = []
    for i, line in enumerate(lines):
        if line.trim() == "":
            continue  // skip blank lines
        ev = parse_json(line)
        if ev == null:
            return {valid: false, reason: "unparseable_line", line: i+1}
        events.append(ev)
    
    if events.length == 0:
        return {valid: false, reason: "empty_log"}
    
    // ---- 4: Reject unknown event types ----
    for i, ev in enumerate(events):
        if !KNOWN_EVENTS.contains(ev.event):
            return {valid: false, reason: "unknown_event_type",
                    event: ev.event, line: i+1}
    
    // ---- 5: Validate required fields and types per event ----
    for i, ev in enumerate(events):
        err = validate_event_fields(ev)  // checks required fields, types, enum values
        if err != null:
            return {valid: false, reason: "invalid_event_fields",
                    line: i+1, detail: err}
    
    // ---- 6: schema_version valid ----
    sv = events[0].schema_version
    if sv == null || typeof(sv) != "integer" || sv < 1 || sv > 2:
        return {valid: false, reason: "invalid_schema_version", found: sv}
    
    // ---- 7: All events have same schema_version ----
    for ev in events:
        if ev.schema_version != sv:
            return {valid: false, reason: "mixed_schema_version"}
    
    // ---- 8: All events have matching run_id ----
    for ev in events:
        if ev.run_id != run_id:
            return {valid: false, reason: "run_id_mismatch",
                    event_run_id: ev.run_id, file_run_id: run_id}
    
    // ---- 9: Exactly one run_started, must be first non-blank event ----
    if events[0].event != "run_started":
        return {valid: false, reason: "first_event_not_run_started",
                found: events[0].event}
    
    started_count = events.filter(e -> e.event == "run_started").length
    if started_count != 1:
        return {valid: false, reason: "run_started_count",
                expected: 1, found: started_count}
    
    // ---- 10: required_command_ids must not have duplicates ----
    run_started = events[0]
    req_ids = run_started.required_command_ids
    if req_ids.length != Set(req_ids).size:
        return {valid: false, reason: "duplicate_required_command_id"}
    
    // ---- 11: Exactly one terminal event, must be last non-blank event ----
    last = events[events.length - 1]
    if !last.event.matches(/^run_(completed|failed|aborted)$/):
        return {valid: false, reason: "last_event_not_terminal",
                found: last.event}
    
    terminal_events = events.filter(e -> e.event.matches(/^run_(completed|failed|aborted)$/))
    if terminal_events.length != 1:
        return {valid: false, reason: "terminal_event_count",
                expected: 1, found: terminal_events.length}
    
    // ---- 12: command_id uniqueness ----
    command_events = events.filter(e -> e.event == "command_completed")
    seen_ids = Set()
    for ce in command_events:
        if seen_ids.has(ce.command_id):
            return {valid: false, reason: "duplicate_command_id",
                    command_id: ce.command_id}
        seen_ids.add(ce.command_id)
    
    // ---- 13: Required command coverage ----
    completed_ids = command_events.map(e -> e.command_id)
    for req_id in req_ids:
        if !completed_ids.contains(req_id):
            return {valid: false, reason: "missing_required_command",
                    command_id: req_id}
    
    // ---- 14: Terminal count invariants ----
    terminal = terminal_events[0]
    
    // 14a: executed = passed + failed
    if terminal.executed_commands != terminal.passed_commands + terminal.failed_commands:
        return {valid: false, reason: "executed_count_invariant",
                executed: terminal.executed_commands,
                passed: terminal.passed_commands,
                failed: terminal.failed_commands}
    
    // 14b: planned = executed + skipped
    if terminal.planned_commands != terminal.executed_commands + terminal.skipped_commands:
        return {valid: false, reason: "planned_count_invariant",
                planned: terminal.planned_commands,
                executed: terminal.executed_commands,
                skipped: terminal.skipped_commands}
    
    // 14c: planned = required_command_ids.length
    if terminal.planned_commands != req_ids.length:
        return {valid: false, reason: "planned_vs_required_mismatch",
                planned: terminal.planned_commands,
                required: req_ids.length}
    
    // 14d: command_completed events = executed
    if command_events.length != terminal.executed_commands:
        return {valid: false, reason: "command_event_count_mismatch",
                command_events: command_events.length,
                executed: terminal.executed_commands}
    
    // ---- 15: Origin–confirmation invariants ----
    for ce in command_events:
        if ce.command_origin == "configured" && ce.confirmation != "not_required":
            return {valid: false, reason: "configured_confirmation_invalid",
                    command_id: ce.command_id, confirmation: ce.confirmation}
        if ce.command_origin == "detected" && ce.confirmation != "confirmed":
            return {valid: false, reason: "detected_command_not_confirmed",
                    command_id: ce.command_id, confirmation: ce.confirmation}
    
    // ---- 16: association run_id matches filename ----
    if assoc.run_id != run_id:
        return {valid: false, reason: "association_run_id_mismatch"}
    
    return {valid: true, run_started: run_started, terminal: terminal,
            command_events: command_events}
```

### 3.2 验证失败行为

`validate_run_log()` 返回 non-`{valid: true}` 时：

- `is_eligible_for_passing()` MUST 返回 false
- Error reason MUST 写入 stderr
- 这是 fail-closed 语义：不确定 → 拒绝

---

## 4. 通用语义 vs 首期 Runtime

```
┌─────────────────────────────────────────────────────────┐
│  Adapter Layer（每个 platform 不同）                      │
│  - Hook 事件映射 → 环境变量 → 调用 core                   │
│  - 输入规范化、输出转换（中立 outcome → host 协议）         │
│  - Host-specific 安装、降级、trust                        │
├─────────────────────────────────────────────────────────┤
│  Semantic Core（MUST）                                    │
│  - 第 1 节 invariants                                     │
│  - Event schema（第 2 节）                                │
│  - validate_run_log()（第 3 节）                          │
│  - Capability maturity（第 5 节）                         │
│  - Passing eligibility（第 9 节）                        │
│  - Workspace fingerprint（第 11 节）                      │
│  - Registry locking（第 7 节）                            │
│  - 安全边界（第 15 节）                                   │
├─────────────────────────────────────────────────────────┤
│  Reference Runtime（首期，可替换）                         │
│  - Language: bash 3.2+                                   │
│  - JSON: jq 1.6+                                         │
│  - Lock: flock (Linux) / mkdir (macOS, Git Bash)         │
│  - Hash: sha256sum / shasum -a 256                       │
│  - ID: date-PID-RANDOM                                   │
└─────────────────────────────────────────────────────────┘
```

---

## 5. Capability Maturity Model

累积模型：Level 2 ⊃ Level 1 ⊃ Level 0。

| 能力 | L0 | L1 | L2 |
|------|:--:|:--:|:--:|
| Knowledge guidance | ✅ | ✅ | ✅ |
| Verification plan 可发现 | — | ✅ | ✅ |
| Per-run immutable evidence log | — | ✅ | ✅ |
| ≥1 required step 可执行 | — | ✅ | ✅ |
| Feature registry | — | — | ✅ |
| Feature state machine | — | — | ✅ |
| Evidence association | — | — | ✅ |
| WIP tracking | — | — | ✅ |

**判定方式**（capability-based，非文件名 checklist）：

| Level | 判定条件 |
|-------|---------|
| 0 | 存在 knowledge_entry（adapter 声明）或等效知识指引机制 |
| 1 | L0 + 存在可发现 verification plan（`.harness/config.json` 或等效）且至少一个 required step 可执行 |
| 2 | L1 + 存在 feature registry（`feature_list.json` 或等效） |

---

## 6. Architecture: Core/Adapter

### 6.1 目录结构

```
harness-companion/
├── core/
│   ├── lib/
│   │   ├── state-machine.sh
│   │   ├── evidence.sh              # per-run NDJSON log 写入
│   │   ├── validate-run-log.sh      # canonical run log 验证
│   │   ├── passing.sh               # passing eligibility
│   │   ├── staleness.sh             # fingerprint + config 检测
│   │   ├── workspace-fingerprint.sh # fingerprint 计算（含 untracked）
│   │   ├── lock-registry.sh         # flock / mkdir lock
│   │   ├── atomic-write.sh
│   │   └── json-helpers.sh
│   ├── harness-feature.sh
│   ├── harness-verify.sh
│   ├── harness-status.sh
│   └── harness-audit.sh
│
├── adapters/
│   ├── claude-code/
│   │   ├── hooks/session-start.sh, stop-handoff.sh
│   │   ├── templates/CLAUDE.md, claude-progress.md
│   │   ├── install.sh
│   │   └── adapter.conf
│   │
│   └── codex/
│       ├── hooks/
│       │   ├── session-start.sh, session-start.cmd
│       │   ├── stop-handoff.sh, stop-handoff.cmd
│       │   └── pre-tool-use.sh      # exit 0 + empty stdout if schema unknown
│       ├── templates/AGENTS.md, codex-progress.md
│       ├── install.sh
│       └── adapter.conf
│
├── templates/                       # 共享（平台无关）
│   ├── feature_list.json
│   ├── .harness/
│   │   ├── config.schema.json
│   │   └── config.json.*.example
│   └── init.sh
│
├── tests/
│   ├── core/
│   ├── adapters/
│   └── golden/
│
└── VERSION
```

### 6.2 Architecture Invariant

Adapter MUST NOT 包含：状态机、WIP 判定、passing eligibility、evidence staleness、fingerprint 计算、run_id 生成、`validate_run_log()`。

Adapter 允许：host 事件映射 → 环境变量 → 调用 core → 中立 outcome → host 协议格式。

Contract tests MUST 断言 adapter 不包含 core 逻辑的字符串片段。

### 6.3 Adapter Contract Tables

#### Claude Code

| 职责 | 实现 | 约束 |
|------|------|------|
| Hook 映射 | Bash → `~/.claude/settings.json` | 第 13 节 |
| SessionStart | 调用 core → Claude-specific JSON | fail-open |
| Stop | 调用 core → Claude-specific JSON | SHOULD 提示 |
| 模板 | `CLAUDE.md`, `claude-progress.md` | 默认值 |
| 安装 | `~/.claude/skills/harness-companion/` | MUST 备份 settings.json |

#### Codex

| 职责 | 实现 | 约束 |
|------|------|------|
| Hook 映射 | Bash `type: "command"` | 第 13-14 节 |
| 配置来源 | 按模式唯一（第 14.3 节） | MUST NOT 同层重复 |
| SessionStart | 调用 core → Codex event-specific JSON | fail-open |
| Stop | 调用 core → Codex event-specific JSON | SHOULD 提示 |
| PreToolUse | 调用 core → 未确认 schema 时 exit 0 + empty stdout | 第 13.3 节 |
| Windows 备选 | `commandWindows` → `.cmd` 脚本（调用 Bash core） | 依赖可用 Bash runtime |
| 模板 | `AGENTS.md`, `codex-progress.md` | AGENTS.md 是 Codex 默认 |
| 安装 | 按模式决定路径 | MUST 备份现有配置 |
| 降级 | Hook disabled/untrusted → explicit | MUST 说明原因 |

---

## 7. Registry Locking Protocol

### 7.1 Versioning

使用**单调递增 revision**（整数），不采用 content_hash 自引用。

```
feature_list.json:
{
  "revision": 42,
  "features": [...]
}
```

每次 mutation 将 revision 递增 1。Read-modify-write 时验证 revision 未变。

### 7.2 Protocol

```
REGISTRY_FILE = feature_list.json
REGISTRY_LOCK_DIR = .harness/.registry.lock
LOCK_TIMEOUT_S = 10

update_registry(modification_fn):
    // Step 1: Acquire lock
    lock = acquire_lock(REGISTRY_LOCK_DIR, timeout=LOCK_TIMEOUT_S)
    if lock == null:
        exit 5  // lock_timeout
    
    // Step 2: Read current under lock
    current = read_file(REGISTRY_FILE)
    if current == null:
        // File doesn't exist yet (first init)
        current = '{"revision": 0, "features": []}'
    expected_revision = current.revision
    
    // Step 3: Apply modification
    new_content = modification_fn(current)
    if new_content == null:
        release_lock(lock)
        return error
    
    // Step 4: Verify revision unchanged + increment
    if new_content.revision != expected_revision:
        // modification_fn didn't preserve revision
        release_lock(lock)
        return error
    new_content.revision = expected_revision + 1
    
    // Step 5: Atomic write under lock
    temp = REGISTRY_FILE + ".tmp." + pid
    write_file(temp, new_content)
    rename(temp, REGISTRY_FILE)
    
    // Step 6: Release lock
    release_lock(lock)
    return {ok: true, revision: new_content.revision}
```

### 7.3 Lock 实现

| Platform | 方法 | 说明 |
|----------|------|------|
| **Linux** | `flock(2)` via `flock` command | 首选。内核级排他锁 |
| **macOS** | `mkdir` lock fallback | macOS `flock` 在部分文件系统上不可靠 |
| **Windows Git Bash** | `mkdir` lock fallback | MSYS2 不支持 `flock` |

### 7.4 `mkdir` Lock Metadata

```
.harness/.registry.lock/
├── pid                 # Lock 持有者 PID
├── process_start_time  # Unix epoch (seconds) — PID 启动时间，用于区分 PID 重用
├── hostname            # 主机名
├── timestamp           # Unix epoch (seconds) — lock 获取时间
└── token               # 随机 32-char ownership token
```

**Owner-safe release**：只有持有正确 `token` 的进程可以释放 lock。释放时验证 `token` 匹配，不匹配则拒绝释放（防止误删他人 lock）。

### 7.5 Stale Lock Recovery

恢复决策矩阵：

| 场景 | 条件 | 动作 |
|------|------|------|
| **PID dead** | `metadata.pid` 不存在于当前系统 + `metadata.hostname == my_hostname` + `metadata.process_start_time` 对应的进程不存在 | 可恢复。移除 lock_dir，重试 mkdir |
| **PID reuse** | `metadata.pid` 存在于当前系统 BUT `process_start_time(pid) != metadata.process_start_time` | MUST NOT 恢复。这是不同进程重用了同一 PID |
| **Different host** | `metadata.hostname != my_hostname` | MUST NOT 仅凭本机 PID 判定 stale。不同主机的 PID 空间独立。仅当 `now() - metadata.timestamp > cross_host_timeout`（默认 60s）时才视为 stale |
| **Metadata damaged** | 无法读取 pid/hostname/timestamp 中任一字段 | MUST NOT 恢复。损坏的 metadata 无法安全验证 ownership。退回到 timeout |
| **Owner token mismatch** | lock_dir 存在但 token 不匹配 | MUST NOT 释放（release 时）或恢复（acquire 时）。属于其他进程 |
| **Same PID, different token** | `metadata.pid == my_pid` BUT `metadata.token != my_token` | MUST NOT 恢复。另一个进程（可能是 fork 前的父进程）持有 lock |
| **Lock expired** | 以上均不满足 + `now() - metadata.timestamp > LOCK_TIMEOUT_S` | 可恢复。超时兜底 |

```
acquire_lock(lock_dir, timeout):
    deadline = now() + timeout
    my_token = random_token(32)
    while now() < deadline:
        if mkdir(lock_dir) succeeds:
            write_lock_metadata(lock_dir, pid=my_pid,
                process_start_time=my_process_start_time,
                hostname=my_hostname,
                timestamp=now(), token=my_token)
            return {dir: lock_dir, token: my_token}
        
        metadata = read_lock_metadata(lock_dir)
        if metadata == null:
            sleep(100ms); continue   // race: other process creating metadata
        
        // --- Cross-host: NEVER judge stale by local PID ---
        if metadata.hostname != my_hostname:
            if now() - metadata.timestamp > CROSS_HOST_TIMEOUT_S:
                rmdir(lock_dir)      // cross-host timeout fallback
                continue
            sleep(100ms); continue   // still within cross-host grace window
        
        // --- Same host: can use PID ---
        if metadata.hostname == my_hostname:
            if !is_pid_alive(metadata.pid):
                // PID not alive — verify it's not a reuse
                if metadata.process_start_time != null:
                    // We have start_time: can disambiguate PID reuse
                    // (PID dead + start_time doesn't match anything = safe)
                    rmdir(lock_dir); continue
                else:
                    // No start_time (legacy metadata): cannot disambiguate
                    // ONLY recover if past LOCK_TIMEOUT_S
                    if now() - metadata.timestamp > LOCK_TIMEOUT_S:
                        rmdir(lock_dir); continue
                    sleep(100ms); continue
            else:
                // PID alive — check start_time to rule out reuse
                actual_start = process_start_time(metadata.pid)
                if actual_start != metadata.process_start_time:
                    // PID reused by different process — do NOT steal
                    sleep(100ms); continue
        
        // --- Local timeout fallback ---
        if now() - metadata.timestamp > LOCK_TIMEOUT_S:
            rmdir(lock_dir); continue
        
        sleep(100ms)
    
    return null  // timeout

release_lock(lock):
    metadata = read_lock_metadata(lock.dir)
    if metadata != null && metadata.token != lock.token:
        return {error: "token_mismatch"}  // 不释放他人 lock
    rmdir(lock.dir)
    return {ok: true}
```

### 7.6 Lock Protocol Tests

```
test_flock_linux:
    (skip if no flock)
    1. 进程 A 获取 lock，sleep 3s
    2. 进程 B 尝试获取 lock → 阻塞
    3. 进程 A 释放 → B 获取成功
    4. 断言: registry 包含 A 和 B 的修改

test_mkdir_lock_fallback:
    1. 进程 A mkdir(lock_dir) 成功
    2. 进程 B mkdir(lock_dir) 失败（已存在）
    3. 进程 A 写入 registry，rmdir(lock_dir)
    4. 进程 B mkdir 重试成功
    5. 断言: B 读取到 A 的修改（revision 已递增）

test_stale_lock_recovery:
    1. 创建 lock_dir，写入 dead PID 的 metadata（含 process_start_time）
    2. 进程 C 同主机，检测到 PID dead + start_time 匹配 → 恢复
    3. 断言: C 成功获取 lock

test_owner_token_mismatch_no_release:
    1. 进程 A 获取 lock（token=T_A）
    2. 进程 B 尝试 release_lock(lock_dir, token=T_B)
    3. 断言: release 被拒绝（token 不匹配）
    4. 断言: lock_dir 仍存在

test_pid_reuse_not_stolen:
    1. 进程 A 获取 lock，记录 metadata（PID=P, start_time=S_A, token=T_A）
    2. 进程 A 崩溃（PID=P 消失）
    3. 新进程 B 启动，恰好分配到 PID=P（start_time=S_B ≠ S_A）
    4. 进程 C 检测到 PID=P 存活 BUT process_start_time(P) = S_B ≠ S_A
    5. 断言: C 不窃取 lock

test_different_host_timeout:
    1. 主机 X 创建 lock_dir（hostname=X, timestamp=now）
    2. 主机 Y 检测到 lock_dir，hostname ≠ Y
    3. 在 CROSS_HOST_TIMEOUT_S 内：Y 不恢复 lock
    4. 超过 CROSS_HOST_TIMEOUT_S 后：Y 恢复 lock
    5. 断言: registry 无冲突

test_different_host_no_local_pid_check:
    1. 主机 X 创建 lock_dir（hostname=X, pid=42）
    2. 主机 Y 上恰好 PID 42 不存在
    3. 断言: Y MUST NOT 因为本地 PID 42 不存在而恢复 lock
    4. Y 仅在 CROSS_HOST_TIMEOUT_S 后恢复

test_metadata_damaged_no_recovery:
    1. 创建 lock_dir，写入 pid 但缺少 hostname
    2. 进程 C 尝试获取 lock → 无法验证 ownership
    3. 断言: C 不退回到"直接恢复"，必须等到 LOCK_TIMEOUT_S

test_lock_timeout:
    1. 进程 A 获取 lock，sleep 15s
    2. 进程 B timeout=2s → exit 5

test_revision_monotonic:
    1. 连续 5 次 mutation
    2. 断言: revision 严格递增，无跳跃重复
```

---

## 8. Run Log Concurrency Protocol

Per-run immutable log：`.harness/logs/runs/<run_id>.ndjson`。

不同 `run_id` → 不同文件 → 零竞争。同一 run 内 command 顺序执行 → 单线程写入。

```
write_run_event(run_id, event_json):
    log_path = ".harness/logs/runs/" + run_id + ".ndjson"
    append_line(log_path, event_json + "\n")
```

### Protocol Tests

```
test_concurrent_runs_different_files:
    1. run A (RA) + run B (RB) 并发执行
    2. 断言: RA.ndjson 和 RB.ndjson 均完整且互不包含

test_same_run_sequential:
    1. run_started → command_completed ×2 → run_completed
    2. 断言: 文件 4 行，顺序正确

test_no_terminal → incomplete:
    1. run_started + command_completed（无 terminal）
    2. validate_run_log() → {valid: false, reason: "terminal_event_count", found: 0}

test_multiple_terminals → corrupted:
    1. run_started + run_completed + run_completed（追加第二个）
    2. validate_run_log() → {valid: false, reason: "terminal_event_count", found: 2}

test_terminal_not_last → corrupted:
    1. run_started + run_completed + command_completed
    2. validate_run_log() → {valid: false, reason: "last_event_not_terminal"}
```

---

## 9. Passing Eligibility

### 9.1 `is_eligible_for_passing(feature_id, feature_registry)` 伪代码

```
function is_eligible_for_passing(feature_id, registry):
    // Step 1: Find latest association
    feature = registry.features.find(f -> f.id == feature_id)
    if feature == null:
        return {eligible: false, reason: "feature_not_found"}
    
    assoc = feature.evidence_associations?.last()
    if assoc == null:
        return {eligible: false, reason: "no_evidence_association"}
    
    run_id = assoc.run_id
    
    // Step 2: Canonical validation (ALL structural checks)
    validation = validate_run_log(run_id, assoc)
    if !validation.valid:
        return {eligible: false, reason: "run_log_invalid",
                detail: validation.reason, run_id: run_id}
    
    run_started = validation.run_started
    terminal = validation.terminal
    commands = validation.command_events
    
    // Step 3: Terminal must be run_completed with overall_result="passed"
    if terminal.event != "run_completed":
        return {eligible: false, reason: "run_not_completed",
                terminal: terminal.event}
    if terminal.overall_result != "passed":
        return {eligible: false, reason: "overall_result_not_passed",
                result: terminal.overall_result}
    
    // Step 4: At least one required step
    if run_started.required_command_ids.length == 0:
        return {eligible: false, reason: "no_required_steps"}
    
    // Step 5: All commands passed (terminal.failed_commands == 0 already verified
    //         by validate_run_log count invariants; explicit safety check)
    if terminal.failed_commands != 0:
        return {eligible: false, reason: "command_failed",
                failed_count: terminal.failed_commands}
    
    // Step 6: Evidence staleness — workspace fingerprint
    //         Compare CURRENT fingerprint with TERMINAL verified fingerprint
    current_fingerprint = compute_workspace_fingerprint()
    verified_fingerprint = terminal.workspace_fingerprint_verified
    
    if current_fingerprint != verified_fingerprint:
        return {eligible: false, reason: "workspace_changed_since_verification",
                current: current_fingerprint,
                verified: verified_fingerprint}
    
    // Step 7: Evidence staleness — config_sha256
    current_config_hash = sha256_file(".harness/config.json")
    if run_started.config_sha256 != current_config_hash:
        return {eligible: false, reason: "config_changed_since_run",
                run_config: run_started.config_sha256,
                current_config: current_config_hash}
    
    // Step 8: VCS HEAD match (git repos only)
    if run_started.vcs_revision != null && is_git_repo():
        current_head = git("rev-parse --short=12 HEAD")
        if run_started.vcs_revision != current_head:
            return {eligible: false, reason: "vcs_moved_since_run",
                    run_rev: run_started.vcs_revision,
                    head: current_head}
    
    return {eligible: true, run_id: run_id}
```

---

## 10. Evidence Staleness

### 三轴检测

| 轴 | 存储位置 | 比较对象 | 判定 |
|----|---------|---------|------|
| Workspace | `terminal.workspace_fingerprint_verified` | `compute_workspace_fingerprint()` | 不匹配 → stale |
| Config | `run_started.config_sha256` | `sha256(.harness/config.json)` | 不匹配 → stale |
| VCS | `run_started.vcs_revision` | `git rev-parse HEAD` | 不匹配 → stale（仅 git 项目） |

所有三条 MUST 全部匹配，passing 才成立。

---

## 11. Workspace Fingerprint

### 11.0 Harness Self-Artifact Exclusion

Fingerprint 计算 MUST 无条件排除 harness 自身运行产物，确保 terminal event 追加后 fingerprint 保持稳定：

**Built-in exclude list**（MUST，不可覆盖）：
- `.harness/logs/` — run logs 目录（含所有 `runs/*.ndjson` 和 per-command log artifacts）
- `.harness/.registry.lock/` — registry lock 目录
- `.harness/*.tmp.*` — temp 文件
- `.harness/logs/runs/` — 等同于 `.harness/logs/` 的显式冗余

**Configurable exclude**（`.harness/config.json` 中 `fingerprint_exclude[]`，glob 数组）：
- 默认值：`["node_modules/", ".git/", "__pycache__/", "*.pyc", ".DS_Store", "Thumbs.db"]`
- 项目可追加，不可移除 built-in 条目
- 示例追加：`["dist/", "coverage/", ".next/"]`

### 11.1 计算算法

**核心原则**：使用排序、NUL-delimited 的路径/hash 序列，确保特殊文件名（含换行符、空格、引号）不会破坏 fingerprint 完整性。

```
compute_workspace_fingerprint():
    exclude_globs = BUILTIN_EXCLUDES + config.fingerprint_exclude[]
    
    if is_git_repo():
        // --- Staged changes (git diff --cached) ---
        staged = git("diff --cached HEAD -- . :/")
        
        // --- Unstaged changes (git diff, not --cached) ---
        unstaged = git("diff HEAD -- . :/")
        
        // --- Untracked files within verification scope ---
        untracked_files = git("ls-files --others --exclude-standard")
        
        // Build sorted, NUL-delimited path:hash sequence
        entries = []
        for f in untracked_files:
            if is_excluded(f, exclude_globs): continue
            if !is_within_verification_scope(f): continue
            entries.append({path: f, hash: sha256_file(f)})
        
        // Sort by path for deterministic ordering
        entries.sort_by(path)
        
        // NUL-delimited: path\0hash\0
        untracked_blob = ""
        for e in entries:
            untracked_blob += e.path + "\0" + e.hash + "\0"
        
        combined = staged + "\0---STAGED---\0" \
                 + unstaged + "\0---UNSTAGED---\0" \
                 + untracked_blob
        
        if combined == "\0---STAGED---\0\0---UNSTAGED---\0":
            return "clean"
        return "sha256:" + sha256(combined)
    
    else:
        // No VCS: hash configurable verification scope
        scope = get_verification_scope()  // from config, default = project_root
        files = list_all_files(scope, exclude=exclude_globs)
        entries = []
        for f in files:
            entries.append({path: f, hash: sha256_file(f)})
        entries.sort_by(path)
        
        blob = ""
        for e in entries:
            blob += e.path + "\0" + e.hash + "\0"
        
        return "sha256:" + sha256(blob)
```

### 11.2 Fingerprint 存储

| Event | 字段 | 说明 |
|-------|------|------|
| `run_started` | `workspace_fingerprint_initial` | Run 开始时的 workspace 状态 |
| Terminal | `workspace_fingerprint_verified` | Run 结束时的 workspace 状态（terminal event 写入后取样） |

**Terminal fingerprint 稳定性**：因为 harness 自身产物（`.harness/logs/`, `.harness/.registry.lock/`, `.harness/*.tmp.*`）已被无条件排除，追加 terminal event 到 run log 不改变 fingerprint。`workspace_fingerprint_initial == workspace_fingerprint_verified` 当且仅当 verification commands 未修改工作区文件。

### 11.3 比较逻辑

Passing eligibility 始终计算 `current = compute_workspace_fingerprint()`，与 `terminal.workspace_fingerprint_verified` 比较。

| Current | Verified | 结果 |
|---------|----------|------|
| `"clean"` | `"clean"` | ✅ |
| `"sha256:<H>"` | `"sha256:<H>"` | ✅（相同 dirty state） |
| `"sha256:<H1>"` | `"sha256:<H2>"` | ❌ dirty 内容已变化 |
| `"sha256:<H>"` | `"clean"` | ❌ 当前 dirty，但 run 时是 clean |
| `"clean"` | `"sha256:<H>"` | ❌ 当前 clean，但 run 时是 dirty |

---

## 12. Verification Plan

### 12.1 Command Metadata

每个 verification command 携带：

| 字段 | 值 | 说明 |
|------|-----|------|
| `command_origin` | `configured` / `detected` | 来源 |
| `confirmation` | `not_required` / `pending` / `confirmed` / `rejected` | 确认状态 |

执行状态由 event type 表达：`command_completed` event 即表示命令执行完成。

### 12.2 约束

| 规则 | 约束 |
|------|------|
| `detected` + `confirmation=pending` → MUST NOT 执行 | MUST |
| 高成本命令（`npm install`, `docker build`）MUST NOT 自动探测 | MUST |
| 有副作用命令（`publish`, `deploy`）MUST NOT 出现在 plan 除非显式配置 | MUST |
| 0 required steps → `overall_result = "no_checks"` | MUST |

### 12.3 0-Step 项目

文档项目、数据项目 MUST 能被检测为 Level 1，但：
- `overall_result` SHALL 为 `"no_checks"`（非 `"passed"`）
- Status 面板 SHALL 区分 "上次验证通过（N steps）" 和 "无可用验证步骤"
- `"no_checks"` SHALL NOT 使 passing eligibility 为 true

---

## 13. Hook Fail-Open Contract

### 13.1 分层模型

```
Adapter:  接收 platform hook input
          → 转换为环境变量
          → 调用 core script
          → 获取 core 中立 outcome (JSON to stdout)
          → 映射为 host-specific 协议输出
          → 错误时: 输出该 event 的最小合法协议格式

Core:     执行业务逻辑
          → 输出中立 outcome JSON: {"status":"ok"|"error", ...}
          → 不感知 host hook 协议
```

### 13.2 Core Neutral Outcome

```json
{"status": "ok", "payload": {...}}
{"status": "error", "error_code": "CONFIG_MISSING", "message": "..."}
```

### 13.3 Adapter 映射

**Claude Code**：

| Hook Event | Core Outcome | Adapter Output |
|------------|-------------|----------------|
| SessionStart | ok | `{"continue":true, "hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<payload>"}}` |
| SessionStart | error | `{"continue":true, "suppressOutput":true}` |
| Stop | any | `{"continue":true}` + optional `systemMessage` |

**Codex**：

| Hook Event | Core Outcome | Adapter Output |
|------------|-------------|----------------|
| SessionStart | ok | Codex-specific output（字段名待 prototype 验证） |
| SessionStart | error | Exit 0, empty stdout |
| Stop | any | Exit 0, empty stdout |
| PreToolUse | ok | Exit 0, empty stdout（除非确认了 Codex schema） |
| PreToolUse | error | Exit 0, empty stdout |
| PostToolUse | any | Exit 0, empty stdout |
| PreCompact | any | Exit 0, empty stdout |

**规则**：
- 每个 event MUST 只输出官方支持的字段
- `{"continue":true}` MUST NOT 作为所有 event 的通用 fallback
- 未确认 Codex event schema 时，MUST exit 0 + empty stdout
- PreCompaction → `PreCompact`（Codex 官方名称）

---

## 14. Codex Adapter Design

### 14.1 支持的 Hook Events（官方集合）

| Event | harness 使用 |
|-------|-------------|
| `SessionStart` | ✅ status 摘要 |
| `Stop` | ✅ handoff 提示 |
| `UserPromptSubmit` | MAY（future） |
| `PreToolUse` | MAY（future） |
| `PostToolUse` | MAY（future） |
| `PreCompact` | MAY（future） |

`Notification`, `Checkpoint` 等 MUST NOT 出现在能力标志中。

### 14.2 环境变量

| 变量 | 优先级 |
|------|--------|
| `PLUGIN_ROOT` | **首选**（Codex 原生） |
| `PLUGIN_DATA` | **首选**（Codex 原生） |
| `CLAUDE_PLUGIN_ROOT` | 兼容回退（仅在 PLUGIN_ROOT 不存在时） |

### 14.3 每层唯一配置来源

| 安装模式 | 配置文件 | 路径 |
|---------|---------|------|
| Plugin（`.codex-plugin/`） | `hooks.json` | `<plugin_root>/hooks/hooks.json` |
| Repo-local（项目内 `.codex/`） | `hooks.json` | `<project>/.codex/hooks.json` |
| User inline（全局配置） | `config.toml` | `~/.codex/config.toml` `[[hooks]]` 块 |

MUST NOT 在同一层同时生成 `hooks.json` 和 `config.toml` hooks。

### 14.4 `commandWindows`

`.cmd` 脚本调用 Bash core（例如 `bash "<PLUGIN_ROOT>/core/harness-status.sh"`）。

**依赖声明**：`commandWindows` 脚本 MUST 有可用的 Bash runtime（Git Bash 或 WSL）。如果 Bash 不可用，SHALL 降级为 explicit invocation。

### 14.5 adapter.conf

```ini
name=codex
display_name=Codex OS
protocol_version=1

# File mapping
knowledge_entry=AGENTS.md
progress_file=codex-progress.md

# Capabilities (official event set only)
has_session_start_hook=true
has_stop_hook=true
has_user_prompt_submit_hook=true
has_pre_tool_use_hook=true
has_post_tool_use_hook=true
has_pre_compact_hook=true

# Hook implementation
hook_runtime=bash
hook_directory=hooks
has_command_windows=true
command_windows_requires_bash=true     # commandWindows 依赖 Bash runtime

# Degradation
fallback_workflow=explicit
windows_sandbox_degraded=true

# Install (one per mode, never combined)
plugin_config_type=hooks_json
repo_local_config_type=hooks_json
user_inline_config_type=config_toml
```

---

## 15. 安全模型

| 规则 | 约束 |
|------|------|
| 不得使用 `eval` 拼接未验证输入 | MUST |
| 命令来自 `command[]` 数组（argv） | MUST |
| 每个 command 独立 timeout（默认 300s） | MUST |
| 环境变量写入 evidence 时过滤 secrets | MUST |
| 完整环境变量 MUST NOT 写入 evidence | MUST |
| Log 写入前 SHOULD 扫描 secret pattern | SHOULD |
| Log 文件 SHOULD 加入 `.gitignore` | SHOULD |

---

## 16. 向后兼容与迁移

| 数据类型 | 策略 |
|---------|------|
| v1.1.2 `feature_list.json` | 读取兼容。写入时升级 schema |
| 旧字符串 evidence | `run_id: null`。不参与 passing。保留供审计 |
| 旧 hook/config 文件 | MUST NOT 覆盖。提示手工迁移 |
| 迁移原则 | 读取兼容、写入新格式、不静默覆盖、幂等 |

### Level 1 → Level 2 迁移

| 规则 | 约束 |
|------|------|
| Run logs 保持完整不变 | MUST |
| 创建 registry 不重写历史 | MUST |
| 只能由用户显式关联 `run_id` → feature | MUST |
| 不得自动推断关联 | MUST |
| Level 1 `passed` 不得自动升级为 feature passing | MUST |

---

## 17. 测试矩阵

### 17.1 Evidence Staleness（Fingerprint）

- clean run → 当前 dirty → stale
- dirty(H) run → 当前 dirty(H) → 通过（相同 dirty state）
- dirty(H1) run → 当前 dirty(H2) → stale（dirty 内容变化）
- untracked 文件新增/修改 → stale
- staged-only 修改 → stale
- unstaged 修改 → stale
- 多个文件组合修改 → stale
- no-git 文件修改 → stale
- command 修改工作区 → terminal fingerprint 捕获修改 → 与 current 比较
- clean → clean → 通过
- **terminal event 追加后 fingerprint 仍稳定**：run log 写入不改变 fingerprint
- **特殊文件名**（含换行符、空格、引号）→ fingerprint 正确且 deterministic
- **fingerprint_exclude[] glob 匹配** → 排除的文件不影响 fingerprint

### 17.2 Run Log Validation

- run_id 含 `..` → 拒绝（路径穿越）
- run_id 含 `/` → 拒绝
- run_id 含 `\` → 拒绝
- run_id 含非白名单字符 → 拒绝
- event.run_id 与文件名不一致 → 拒绝
- run_started 不是第一行 → 拒绝
- 0 个 terminal event → 拒绝
- ≥2 个 terminal event → 拒绝
- terminal 不是最后一行 → 拒绝
- duplicate command_id → 拒绝
- detected + confirmation=pending → 拒绝
- required command 未覆盖 → 拒绝
- schema_version 无效 → 拒绝
- schema_version 混合 → 拒绝
- **unknown event type → 拒绝**
- **run_started 缺少必填字段 → 拒绝**
- **command_completed 字段类型错误（exit_code 为 string） → 拒绝**
- **command_origin 不在 enum 内 → 拒绝**
- **confirmation 不在 enum 内 → 拒绝**
- **configured + confirmation=confirmed → 拒绝**（configured 只能用 not_required）
- **detected + confirmation=not_required → 拒绝**（detected 只能用 confirmed）
- **required_command_ids 重复 → 拒绝**
- **executed ≠ passed + failed → 拒绝**
- **planned ≠ executed + skipped → 拒绝**
- **planned ≠ required_command_ids.length → 拒绝**
- **command_completed.length ≠ executed → 拒绝**

### 17.3 Registry Locking

- flock (Linux) 正常获取/释放
- mkdir lock (macOS/Git Bash) 正常获取/释放
- lock timeout → exit 5
- stale lock recovery（验证 ownership，同主机 PID dead + start_time 匹配）
- PID 重用不窃取 lock（start_time 不匹配）
- owner token mismatch → release 被拒绝
- 不同主机不凭本机 PID 判断 stale → 仅 cross_host_timeout 后恢复
- metadata 损坏 → 不恢复，退回到 LOCK_TIMEOUT_S
- 两个 writer → 无丢失
- revision 单调递增

### 17.4 Codex Fail-Open

- SessionStart error → exit 0 + empty stdout
- Stop error → exit 0 + empty stdout
- PreToolUse → exit 0 + empty stdout（schema 未确认时）
- PreCompact fail → exit 0 + empty stdout

### 17.5 Core Contract

- 0-step plan → overall_result = "no_checks"，passing = false
- Level 0/1/2 累积判定
- 状态机全部合法 + 拒绝非法
- fail-closed 全部场景

### 17.6 Project Diversity

- Node / Python / Rust / Go / Makefile / justfile / 文档项目
- 无 Git / monorepo / 路径含空格和 Unicode

---

## 18. 风险与未验证假设

### 已确认

- ✅ Codex 使用 AGENTS.md
- ✅ Codex hooks 配置在 `config.toml`（TOML）
- ✅ Codex hooks 支持 `type: "command"`
- ✅ Codex 原生环境变量：`PLUGIN_ROOT`, `PLUGIN_DATA`

### 仍未验证（Phase 3 prototype 必需）

| 假设 | 影响 | 验证时机 |
|------|------|---------|
| Codex **各 event** 的 exact JSON output schema（SessionStart, Stop, PreToolUse, PostToolUse, PreCompact） | adapter 输出格式。每个 event 只输出官方字段 | Phase 3 前 |
| `config.toml` `[[hooks]]` block exact schema | 自动配置生成 | Phase 3 前 |
| Codex Windows sandbox hook 可靠性 | Windows 降级策略 | Phase 3 前 |
| Git Bash `mkdir` 作为 mutex 的可靠性 | Windows lock | Phase 2 前 |
| macOS `flock` 在目标文件系统上的可靠性 | macOS lock 选择 | Phase 1 |

---

## 19. Non-Goals

- PowerShell native / cmd.exe runtime
- Codex Node.js adapter
- 3+ adapter 的 machine-readable protocol
- 自动推断 Level 1 evidence → feature 关联
- 自动执行未经确认的 detected 命令
- Audit 绑定特定文件名
- 从 hook 输出反推 feature status

---

## 20. 附录

### 附录 A：Canonical Log Event Schema

```
event ∈ {"run_started", "command_completed", "run_completed", "run_failed", "run_aborted"}
schema_version = 2（定义于 run_started，同一 run 内所有 event 相同）

run_started:
    run_id, schema_version, started_at, project_root,
    vcs_revision, vcs_revision_source,
    workspace_fingerprint_initial, config_sha256,
    required_command_ids[] (no duplicates), capability_level, feature_id?

command_completed:
    run_id, schema_version, command_id, command[],
    command_origin ∈ {"configured", "detected"},
    confirmation ∈ {"not_required", "pending", "confirmed", "rejected"},
    exit_code, started_at, duration_ms, log_artifact?, log_sha256?

Origin–confirmation invariants:
    configured → confirmation = "not_required"
    detected   → confirmation = "confirmed"

run_completed | run_failed | run_aborted:
    run_id, schema_version, completed_at, overall_result,
    workspace_fingerprint_verified,
    planned_commands, executed_commands, passed_commands, failed_commands, skipped_commands,
    failed_command_ids[]? (run_failed), abort_reason? (run_aborted)

Count invariants (MUST hold for all terminal events):
    executed_commands = passed_commands + failed_commands
    planned_commands = executed_commands + skipped_commands
    planned_commands = required_command_ids.length
    command_completed event count = executed_commands
```

### 附录 B：Feature Association Schema

```
feature.evidence_associations[]:
    run_id: string      → .harness/logs/runs/<run_id>.ndjson
    associated_at: ISO 8601
    associated_by: "user"
```

### 附录 C：约束级别标记

| 标记 | 含义 |
|------|------|
| **MUST** / **MUST NOT** | 硬约束 |
| **SHOULD** / **SHOULD NOT** | 推荐，偏离需理由 |
| **MAY** | 可选 |
| **SHALL** | MUST 同义词（伪代码中） |

---

> **状态**：有条件通过，等待最终审批。

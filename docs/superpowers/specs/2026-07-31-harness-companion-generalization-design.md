# harness-companion 通用化升级 — 方案设计 v4

> 状态: **等待审批** | 日期: 2026-07-31 | 修订: v4
> v3 (已撤回) → v4: correctness 修订

---

## 决策摘要

| 决策 | 结论 |
|------|------|
| Codex adapter 投入深度 | **路径 A**：Bash command hooks + 共享 Bash core。不引入 Node.js runtime |
| Level 1 verify 行为 | **路径 B**：写入 `.harness/logs/runs/<run_id>.ndjson`，不创建临时 feature，不修改 feature status |
| Capability 模型 | **累积 maturity**：Level 2 ⊃ Level 1 ⊃ Level 0 |
| Evidence 模型 | **Per-run immutable NDJSON log**：`run_started` → `command_completed` × N → `run_completed \| run_failed \| run_aborted` |

---

## v3 → v4 变更摘要

| # | v3 问题 | v4 修正 |
|---|---------|---------|
| 1 | 三种冲突的 evidence 数据模型（flat record、单行 run、多事件） | 统一为 canonical per-run NDJSON event log（`run_started` / `command_completed` / `run_completed \| run_failed \| run_aborted`）。Feature registry 只存 run association，不复制 evidence |
| 2 | `command_source` 混入 `executed` 状态 | 拆分为 `command_origin` (configured/detected) + `confirmation` (not_required/pending/confirmed/rejected) + `execution_status` (not_started/running/completed/failed/aborted) |
| 3 | Level 1 允许 0 verification steps 时 `overall_result: "passed"` | 0 required steps → `no_checks`。至少需要一个实际执行的 required step |
| 4 | NDJSON 并发追加依赖 PIPE_BUF 推断和 "temp+rename per record" | Per-run immutable log：`.harness/logs/runs/<run_id>.ndjson`。不同 run_id = 不同文件，零竞争 |
| 5 | Registry CAS 仅用 `last_updated` 比较，存在 TOCTOU | 重新设计：lock + re-read + hash compare + atomic rename。版本号使用 content hash |
| 6 | Evidence staleness 仅检查 HEAD match | 增加 `workspace_fingerprint`（dirty tree 检测）+ `config_sha256`（配置变更检测） |
| 7 | Codex 同时生成 hooks.json 和 config.toml | 按安装模式选择唯一配置来源：plugin → `hooks/hooks.json`，repo-local → `.codex/hooks.json`，user inline → `~/.codex/config.toml` |
| 8 | 声明了 unsupported 的 `has_notification_hook`, `has_checkpoint_hook` | 删除。使用官方事件集合。PLUGIN_ROOT/PLUGIN_DATA 首选，CLAUDE_PLUGIN_ROOT 为兼容回退 |
| 9 | Hook fail-open 统一要求 `{"continue": true}`，但 Codex 部分事件不接受该字段 | Core 返回中立 outcome。Adapter 根据 host + event 映射到合法协议格式 |
| 10 | Level 模型同时暗示累积和独立存在 | 明确为累积 maturity：Level 2 ⊃ Level 1 ⊃ Level 0 |

---

## 目录

1. [Semantic Core Invariants](#1-semantic-core-invariants)
2. [Canonical Evidence Data Model](#2-canonical-evidence-data-model)
3. [通用语义 vs 首期 Runtime](#3-通用语义-vs-首期-runtime)
4. [Capability Maturity Model](#4-capability-maturity-model)
5. [Architecture: Core/Adapter](#5-architecture-coreadapter)
6. [Registry Locking Protocol](#6-registry-locking-protocol)
7. [Run Log Concurrency Protocol](#7-run-log-concurrency-protocol)
8. [Passing Eligibility](#8-passing-eligibility)
9. [Evidence Staleness](#9-evidence-staleness)
10. [Verification Plan & Command Source](#10-verification-plan--command-source)
11. [Hook Fail-Open Contract](#11-hook-fail-open-contract)
12. [Codex Adapter Design](#12-codex-adapter-design)
13. [安全模型](#13-安全模型)
14. [向后兼容与数据迁移](#14-向后兼容与数据迁移)
15. [Level 1 → Level 2 迁移](#15-level-1--level-2-迁移)
16. [分阶段实施计划](#16-分阶段实施计划)
17. [测试矩阵](#17-测试矩阵)
18. [风险与未验证假设](#18-风险与未验证假设)
19. [Non-Goals](#19-non-goals)
20. [附录](#20-附录)

---

## 1. Semantic Core Invariants

以下规则 MUST 被所有 platform adapter 和 runtime 实现遵守。违反任一条即破坏 correctness。

### 1.1 Evidence Schema

Evidence 以 per-run immutable NDJSON log 存储。每条 event 是独立的 NDJSON 行。Canonical schema 见第 2 节。

### 1.2 Feature State Machine（Level 2）

状态集合：`not_started`, `in_progress`, `blocked`, `passing`, `unverified`, `deprecated`

合法 transition（MUST 显式枚举，未列出即拒绝）：

| from | to | 条件 |
|------|----|------|
| `not_started` | `in_progress` | WIP limit 未超 |
| `not_started` | `blocked` | — |
| `in_progress` | `passing` | `is_eligible_for_passing()` 返回 true（见第 8 节） |
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
| 验证命令二进制不存在 | 该 step exit_code = 127，run status = `run_failed` |
| 所有 evidence 的 run_id 为 null（Level 2） | 2 |
| Registry lock 获取失败（timeout） | 5 |
| Missing terminal event in log | passing eligibility 返回 false |
| Multiple terminal events in log | passing eligibility 返回 false（fail-closed） |
| Association 指向不存在的 run log | passing eligibility 返回 false |
| Association 指向损坏的 run log（不可解析） | passing eligibility 返回 false |
| 0 required steps 执行 | overall_result = `no_checks`, not `passed` |

### 1.4 原子写入

所有 mutation（registry、config）MUST 通过 temp file + rename。见第 6 节锁定协议。

### 1.5 Architecture Invariant：Adapter 不得包含业务语义

以下逻辑 MUST 只存在于 `core/`。任何 adapter MUST NOT 包含或重新实现：
- Feature 状态机 transition
- WIP limit 判定
- Passing eligibility 计算（第 8 节伪代码）
- Evidence staleness 判定（第 9 节）
- run_id 生成或验证

Adapter 的允许职责（MUST NOT 超出）：
1. Host 事件映射（接收 platform 输入 → 环境变量 → 调用 core）
2. 输入规范化（平台特定路径、JSON 字段名差异）
3. 调用 core（通过环境变量）
4. 输出转换（core 中立 outcome → platform hook 协议格式，见第 11 节）
5. Host-specific 安装和降级

---

## 2. Canonical Evidence Data Model

### 2.1 Per-Run Immutable Log

每个 verification run 写入独立文件：

```
.harness/logs/runs/<run_id>.ndjson
```

文件是 immutable NDJSON：创建后只追加，run 终止后绝不修改。

### 2.2 Event Types

#### `run_started` — 每个 run 的第一个 event

```json
{
  "event": "run_started",
  "schema_version": 2,
  "run_id": "20260731T151257Z-12345-32767",
  "started_at": "2026-07-31T15:12:57Z",
  "project_root": "/abs/path/to/project",
  "vcs_revision": "abc1234def56",
  "vcs_revision_source": "git",
  "workspace_fingerprint": "sha256:6dcd4ce...",
  "config_sha256": "sha256:abcd1234...",
  "required_command_ids": ["typecheck", "unit-test"],
  "capability_level": 1,
  "feature_id": null
}
```

| 字段 | 说明 |
|------|------|
| `workspace_fingerprint` | 工作区状态指纹。clean tree → `"clean"`；dirty tree → `"sha256:<hash of git diff HEAD>"`；无 VCS → `"no_git"` |
| `config_sha256` | `.harness/config.json` 的 SHA-256。用于检测配置变更后的 evidence staleness |
| `required_command_ids` | 本次 run 计划执行的 required command id 列表（`required_for_passing != false`） |
| `feature_id` | Level 2 时关联的 feature id。Level 1 时为 null |

#### `command_completed` — 每个 verification step 完成后

```json
{
  "event": "command_completed",
  "run_id": "20260731T151257Z-12345-32767",
  "command_id": "typecheck",
  "command": ["npx", "tsc", "--noEmit"],
  "command_origin": "configured",
  "confirmation": "not_required",
  "exit_code": 0,
  "started_at": "2026-07-31T15:12:57Z",
  "duration_ms": 12400,
  "log_artifact": ".harness/logs/runs/20260731T151257Z-12345-32767/typecheck.log",
  "log_sha256": "sha256:efgh5678..."
}
```

| 字段 | 说明 |
|------|------|
| `command_origin` | `configured`（用户显式配置）或 `detected`（从项目 manifest 探测） |
| `confirmation` | `not_required`（origin=configured 时）、`pending`、`confirmed`、`rejected` |

#### `run_completed` — 全部 required commands 通过

```json
{
  "event": "run_completed",
  "run_id": "20260731T151257Z-12345-32767",
  "completed_at": "2026-07-31T15:13:12Z",
  "overall_result": "passed",
  "total_commands": 2,
  "passed_commands": 2,
  "failed_commands": 0,
  "skipped_commands": 0
}
```

#### `run_failed` — 至少一个 required command 失败

```json
{
  "event": "run_failed",
  "run_id": "20260731T151257Z-12345-32767",
  "completed_at": "2026-07-31T15:13:12Z",
  "overall_result": "failed",
  "total_commands": 2,
  "passed_commands": 1,
  "failed_commands": 1,
  "skipped_commands": 0,
  "failed_command_ids": ["unit-test"]
}
```

#### `run_aborted` — 外部中断（SIGTERM、超时等）

```json
{
  "event": "run_aborted",
  "run_id": "20260731T151257Z-12345-32767",
  "completed_at": "2026-07-31T15:13:02Z",
  "overall_result": "aborted",
  "abort_reason": "timeout",
  "total_commands": 2,
  "passed_commands": 1,
  "failed_commands": 0,
  "skipped_commands": 1
}
```

### 2.3 Terminal Event Rules

- 每个 run log MUST 以恰好一个 terminal event 结束：`run_completed`、`run_failed` 或 `run_aborted`
- 存在 0 个 terminal event → incomplete run → passing eligibility MUST 返回 false
- 存在 ≥2 个 terminal event → corrupted log → passing eligibility MUST 返回 false（fail-closed）
- `run_started` 后没有 `command_completed` → incomplete run → MUST 退出前写入 `run_aborted`
- 0 required steps → overall_result SHALL 为 `no_checks`。MUST NOT 为 `passed`

### 2.4 Feature Association Schema（Level 2）

Feature registry 不复制 evidence。只保存 association：

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

`is_eligible_for_passing()` 通过 `run_id` 查询 canonical log file 获取 evidence。见第 8 节伪代码。

---

## 3. 通用语义 vs 首期 Runtime

```
┌─────────────────────────────────────────────────────────┐
│  Adapter Layer（每个 platform 不同）                      │
│  - Hook 事件映射 → 调用 core                              │
│  - 输入规范化、输出转换（中立 outcome → host 协议）         │
│  - Host-specific 安装、降级、trust 流程                   │
├─────────────────────────────────────────────────────────┤
│  Semantic Core（MUST — 通用）                             │
│  - 第 1 节全部 invariants                                 │
│  - Evidence event schema（第 2 节）                       │
│  - Capability maturity 判定（第 4 节）                    │
│  - Passing eligibility（第 8 节）                        │
│  - Evidence staleness（第 9 节）                          │
│  - Registry locking（第 6 节）                            │
│  - 安全边界（第 13 节）                                   │
├─────────────────────────────────────────────────────────┤
│  Reference Runtime（首期实现，可替换）                      │
│  - Language: bash 3.2+                                   │
│  - JSON: jq 1.6+                                         │
│  - Atomic write: mktemp + mv                             │
│  - Lock: flock (Linux/macOS) / mkdir (Git Bash fallback) │
│  - Hash: sha256sum / shasum -a 256                       │
│  - Unique ID: date-PID-RANDOM                            │
└─────────────────────────────────────────────────────────┘
```

| 概念 | 含义 | 约束级别 |
|------|------|---------|
| **通用语义** | invariants + event schema + passing 逻辑 + staleness + lock 协议 | MUST |
| **首期 Reference Runtime** | bash + jq 实现 | 默认实现。future runtime MAY 完全替换 |
| **首期支持环境** | Linux bash 5.x, macOS bash 3.2+, Windows Git Bash / WSL | 已验证环境 |
| **不支持** | cmd.exe, PowerShell native, 无 jq 环境 | 明确标记为 unsupported |

---

## 4. Capability Maturity Model

Level 采用**累积成熟度模型**：Level 2 ⊃ Level 1 ⊃ Level 0。高层级包含低层级的全部能力。

### Level 0：Knowledge Guidance

**能力**：Agent 可发现项目知识和操作指令。

**判定**：存在 adapter 声明的 knowledge_entry 文件，或等效的知识指引机制。

**可用**：`/harness:status`（基础 Knowledge），`/harness:audit`（Knowledge 子系统）

### Level 1：Project Verification

**能力**（含 Level 0 全部 +）：

- 可发现 verification plan（`.harness/config.json` 或等效）
- 可执行 verification commands
- 结果写入 per-run immutable log：`.harness/logs/runs/<run_id>.ndjson`
- 至少一个 `required_for_passing != false` 的 command 实际执行
- Status 面板报告最近 run 状态

**判定**：Level 0 + verification plan 存在且可执行。

**可用**：Level 0 + `/harness:verify`（项目级）

**约束**：
- MUST NOT 创建/修改 feature registry
- `overall_result` 仅反映项目级 run 状态
- Level 1 的 `passed` MUST NOT 被解释为任何 feature 的 passing

### Level 2：Feature-Driven Development

**能力**（含 Level 1 全部 +）：

- Feature registry（`feature_list.json` 或等效）
- Feature state machine（1.2 节）
- Evidence-to-feature association（2.4 节）
- Passing eligibility 基于 canonical log（第 8 节）
- WIP tracking

**判定**：Level 1 + feature registry 存在。

**可用**：全部 6 个命令

### 能力总结

| 能力 | L0 | L1 | L2 |
|------|:--:|:--:|:--:|
| Knowledge guidance | ✅ | ✅ | ✅ |
| 可发现 verification plan | — | ✅ | ✅ |
| Per-run immutable evidence log | — | ✅ | ✅ |
| ≥1 required step 执行 | — | ✅ | ✅ |
| Feature registry | — | — | ✅ |
| Feature state machine | — | — | ✅ |
| Evidence association | — | — | ✅ |
| WIP tracking | — | — | ✅ |
| `/harness:status` | ✅ | ✅ | ✅ |
| `/harness:verify` | — | ✅ | ✅ |
| `/harness:feature` | — | — | ✅ |
| `/harness:audit` | ✅ | ✅ | ✅ |

---

## 5. Architecture: Core/Adapter

### 5.1 目录结构

```
harness-companion/
├── core/
│   ├── lib/
│   │   ├── state-machine.sh
│   │   ├── evidence.sh              # run log 写入（per-run NDJSON）
│   │   ├── passing.sh               # passing eligibility（查询 canonical log）
│   │   ├── staleness.sh             # workspace_fingerprint + config_sha256 检测
│   │   ├── lock-registry.sh         # registry locking protocol
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
│       │   ├── session-start.sh
│       │   ├── session-start.cmd    # commandWindows 备选
│       │   ├── stop-handoff.sh
│       │   └── stop-handoff.cmd
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

### 5.2 Adapter Contract Tables

#### Claude Code Adapter

| 职责 | 实现 | 约束 |
|------|------|------|
| Hook 事件映射 | Bash → `~/.claude/settings.json` | 第 11 节 fail-open contract |
| SessionStart | 调用 `core/harness-status.sh` → 输出 Claude-specific JSON | MUST fail-open |
| Stop | 调用 core → 输出 Claude-specific JSON | SHOULD 提示不阻塞 |
| 模板 | `CLAUDE.md`, `claude-progress.md` | 默认值 |
| 安装 | `~/.claude/skills/harness-companion/` | MUST 备份 settings.json |

#### Codex Adapter

| 职责 | 实现 | 约束 |
|------|------|------|
| Hook 事件映射 | Bash `type: "command"` | 第 11 节 fail-open contract per event |
| 配置来源 | 按安装模式唯一（第 12.3 节） | MUST NOT 同一层重复注册 |
| SessionStart | 调用 core → 输出 Codex event-specific JSON | MUST fail-open |
| Stop | 调用 core → 输出 Codex event-specific JSON | SHOULD 提示不阻塞 |
| Windows 备选 | `commandWindows` → `.cmd` 脚本 | Git Bash 不可用时 |
| 模板 | `AGENTS.md`, `codex-progress.md` | AGENTS.md 是 Codex 默认 |
| 安装 | 按模式决定路径 | MUST 备份现有配置 |
| 降级 | Hook disabled/untrusted/unavailable → explicit | MUST 说明原因和影响 |

---

## 6. Registry Locking Protocol

### 6.1 问题

v3 的 CAS 设计存在 TOCTOU：`last_updated` 比较和 atomic rename 之间有窗口。timestamp-based 版本号在分布式场景不准确。

### 6.2 Protocol

```
REGISTRY_LOCK = .harness/.registry.lock
REGISTRY_FILE = feature_list.json
LOCK_TIMEOUT_S = 10

update_registry(modification_fn):
    // Step 1: Acquire lock
    lock_fd = acquire_lock(REGISTRY_LOCK, timeout=LOCK_TIMEOUT_S)
    if lock_fd == null:
        exit 5  // lock_timeout
    
    // Step 2: Re-read under lock (NOT before lock)
    current_content = read_file(REGISTRY_FILE)
    current_hash = sha256(current_content)
    
    // Step 3: Apply modification
    new_content = modification_fn(current_content)
    if new_content == null:
        // modification_fn rejected (e.g., invalid transition)
        release_lock(lock_fd)
        return error
    
    // Step 4: Write to temp + atomic rename (still under lock)
    temp_file = REGISTRY_FILE + ".tmp." + pid
    write_file(temp_file, new_content)
    rename(temp_file, REGISTRY_FILE)   // atomic on same filesystem
    
    // Step 5: Release lock
    release_lock(lock_fd)
    return success
```

### 6.3 Lock 实现（reference runtime）

| Platform | 实现 |
|----------|------|
| Linux, macOS | `flock(2)` via `flock` command |
| Windows Git Bash | `mkdir` 原子性作为 mutex（`mkdir .registry.lock 2>/dev/null` 成功 = 获取锁） |
| 通用 fallback | `mkdir`-based mutex |

### 6.4 Versioning

- 不使用 `last_updated` timestamp 作为版本号
- 使用 `content_hash`（SHA-256 of file content）作为版本标识
- `content_hash` 存储在 registry JSON 的顶层字段
- Lock 持有者在步骤 2 读取 `current_hash`，步骤 4 写入 `new_content`（包含更新后的 `content_hash`）

### 6.5 Lock 协议测试

```
test_lock_timeout:
    1. 进程 A 获取锁，sleep 15s
    2. 进程 B 尝试获取锁（timeout=2s）
    3. 断言: 进程 B exit 5 (lock_timeout)

test_lock_no_lost_update:
    1. 进程 A 获取锁，读取 registry (hash=H1)，修改 feature-1→passing
    2. 进程 A 持有锁期间，进程 B 排队等待
    3. 进程 A 写入 (hash=H2)，释放锁
    4. 进程 B 获取锁，重新读取 registry (hash=H2，包含 A 的修改)
    5. 进程 B 修改 feature-2→in_progress
    6. 进程 B 写入 (hash=H3)
    7. 断言: feature-1=passing AND feature-2=in_progress

test_lock_crash_recovery:
    1. 进程 A 获取锁，写入 temp 文件
    2. 进程 A 在 rename 前 crash
    3. 进程 B 获取锁（stale lock 检测：PID 存活检查）
    4. 断言: registry 未被损坏
    5. 断言: temp 文件被清理或忽略
```

---

## 7. Run Log Concurrency Protocol

### 7.1 设计原则

**Per-run immutable log**：不同 run_id = 不同文件。零并发竞争。

### 7.2 Protocol

```
RUN_LOG_DIR = .harness/logs/runs/

write_run_event(run_id, event_json):
    log_path = RUN_LOG_DIR + run_id + ".ndjson"
    
    // Within a single run, commands execute sequentially.
    // No concurrent writes to the same run log.
    append_line(log_path, event_json + "\n")
    
    // The file is created on first write.
    // After the terminal event, the file MUST NOT be written again.
```

### 7.3 并发保证

| 场景 | 保证 |
|------|------|
| 两个并发 run（不同 run_id） | 写入不同文件。零竞争 |
| 同一 run 内多个 command | Command 顺序执行。单线程写入 |
| Crash 后重试同一 feature | 新的 run_id = 新文件。旧文件保留 |
| 两个 agent 并发 verify 同一 feature | 各自不同的 run_id → 不同文件 → 零竞争 |

### 7.4 Incomplete Run 检测

```
is_run_complete(run_id):
    log = read_all_lines(RUN_LOG_DIR + run_id + ".ndjson")
    terminal_events = log.filter(e -> e.event in ["run_completed", "run_failed", "run_aborted"])
    
    if terminal_events.length == 0:
        return {status: "incomplete", reason: "no_terminal_event"}
    if terminal_events.length > 1:
        return {status: "corrupted", reason: "multiple_terminal_events"}
    return {status: "complete", terminal: terminal_events[0]}
```

### 7.5 Protocol Tests

```
test_concurrent_runs_different_files:
    1. 启动 run A (run_id=RA): 写入 RA.ndjson
    2. 同时启动 run B (run_id=RB): 写入 RB.ndjson
    3. 断言: 两个文件均存在且完整
    4. 断言: RA.ndjson 和 RB.ndjson 互不包含对方的数据

test_same_run_sequential_commands:
    1. 写入 run_started
    2. 写入 command_completed (typecheck)
    3. 写入 command_completed (unit-test)
    4. 写入 run_completed
    5. 断言: 文件有恰好 4 行，顺序正确

test_no_terminal_event:
    1. 写入 run_started
    2. 写入 command_completed
    3. (不写入 terminal event)
    4. 断言: is_run_complete() = {status: "incomplete"}

test_multiple_terminal_events:
    1. 写入 run_started + run_completed
    2. 追加 run_completed (第二个)
    3. 断言: is_run_complete() = {status: "corrupted"}
    4. 断言: passing eligibility = false

test_0_required_steps_not_passed:
    1. 写入 run_started (required_command_ids=[])
    2. 写入 run_completed (overall_result="no_checks", total_commands=0)
    3. 断言: overall_result != "passed"
    4. 断言: passing eligibility = false
```

---

## 8. Passing Eligibility

### 8.1 伪代码（Level 2 调用）

```
function is_eligible_for_passing(feature_id, feature_registry, config):
    // Step 1: Find association
    assoc = feature_registry.features
        .find(f => f.id == feature_id)
        ?.evidence_associations
        ?.last()
    
    if assoc == null:
        return {eligible: false, reason: "no_evidence_association"}
    
    run_id = assoc.run_id
    log_path = ".harness/logs/runs/" + run_id + ".ndjson"
    
    // Step 2: Run log must exist and be parseable
    if !file_exists(log_path):
        return {eligible: false, reason: "run_log_missing", run_id: run_id}
    
    events = parse_ndjson(log_path)
    if events == null:
        return {eligible: false, reason: "run_log_corrupted", run_id: run_id}
    
    // Step 3: Exactly one terminal event
    terminal_events = events.filter(e -> e.event in
        ["run_completed", "run_failed", "run_aborted"])
    
    if terminal_events.length == 0:
        return {eligible: false, reason: "run_incomplete", run_id: run_id}
    if terminal_events.length > 1:
        return {eligible: false, reason: "run_log_corrupted_multiple_terminals",
                run_id: run_id}
    
    terminal = terminal_events[0]
    
    // Step 4: Terminal must be run_completed with passed
    if terminal.event != "run_completed":
        return {eligible: false, reason: "run_not_passed",
                run_id: run_id, terminal_event: terminal.event}
    if terminal.overall_result != "passed":
        return {eligible: false, reason: "overall_result_not_passed",
                run_id: run_id, overall_result: terminal.overall_result}
    
    // Step 5: At least one required step executed
    run_started = events.find(e -> e.event == "run_started")
    if run_started.required_command_ids.length == 0:
        return {eligible: false, reason: "no_required_steps", run_id: run_id}
    
    // Step 6: Evidence staleness — workspace_fingerprint
    if run_started.workspace_fingerprint != "clean":
        // Evidence was generated on a dirty tree. Reject unless the
        // current dirty state matches the fingerprint exactly.
        current_fingerprint = compute_workspace_fingerprint()
        if current_fingerprint != run_started.workspace_fingerprint:
            return {eligible: false, reason: "workspace_changed_since_run",
                    run_id: run_id,
                    run_fingerprint: run_started.workspace_fingerprint,
                    current_fingerprint: current_fingerprint}
    
    // Step 7: Evidence staleness — config_sha256
    current_config_hash = sha256_file(".harness/config.json")
    if run_started.config_sha256 != current_config_hash:
        return {eligible: false, reason: "config_changed_since_run",
                run_id: run_id,
                run_config_sha256: run_started.config_sha256,
                current_config_sha256: current_config_hash}
    
    // Step 8: Coverage — all required commands represented
    completed_ids = events
        .filter(e -> e.event == "command_completed")
        .map(e -> e.command_id)
    required_ids = run_started.required_command_ids
    missing = required_ids.filter(id -> !completed_ids.contains(id))
    if missing.length > 0:
        return {eligible: false, reason: "missing_command_coverage",
                run_id: run_id, missing: missing}
    
    // Step 9: All command exit codes must be 0
    failed = events
        .filter(e -> e.event == "command_completed" && e.exit_code != 0)
    if failed.length > 0:
        return {eligible: false, reason: "command_failed",
                run_id: run_id,
                failed_commands: failed.map(e -> e.command_id)}
    
    // Step 10: HEAD match (git repos only)
    if run_started.vcs_revision != null && is_git_repo():
        current_head = git("rev-parse --short=12 HEAD")
        if run_started.vcs_revision != current_head:
            return {eligible: false, reason: "vcs_moved_since_run",
                    run_id: run_id,
                    run_revision: run_started.vcs_revision,
                    current_head: current_head}
    
    return {eligible: true, run_id: run_id}
```

### 8.2 workspace_fingerprint 计算

```
compute_workspace_fingerprint():
    if !is_git_repo():
        return "no_git"
    
    if git("diff --quiet HEAD"):
        return "clean"
    
    diff_content = git("diff HEAD")
    return "sha256:" + sha256(diff_content)
```

---

## 9. Evidence Staleness

### 9.1 检测维度

| 维度 | 方法 | 存储位置 |
|------|------|---------|
| VCS revision | `git rev-parse HEAD` | `run_started.vcs_revision` |
| Workspace dirtiness | `workspace_fingerprint`（9.2 节） | `run_started.workspace_fingerprint` |
| Config integrity | `config_sha256`（9.3 节） | `run_started.config_sha256` |

### 9.2 Workspace Fingerprint

```
clean tree:  fingerprint = "clean"
dirty tree:  fingerprint = "sha256:" + sha256(git diff HEAD)
no git:      fingerprint = "no_git"
```

Passing eligibility 规则：

| Run fingerprint | Current state | 结果 |
|-----------------|---------------|------|
| `"clean"` | clean | ✅ pass |
| `"clean"` | dirty | ❌ stale（当前 dirty，但 run 执行时是 clean） |
| `"sha256:<H>"` | `"sha256:<H>"` | ✅ pass（相同 dirty state） |
| `"sha256:<H>"` | `"sha256:<H2>"` | ❌ stale（dirty 内容已变化） |
| `"no_git"` | no_git | ✅ pass |

### 9.3 Config Integrity

`config_sha256` = SHA-256 of `.harness/config.json` content at run time.

Passing eligibility MUST verify `run_started.config_sha256 == sha256(current_config)`。

这防止了以下场景：
- 用户在 run 后修改了 verification commands（删除、重排、增补）
- 用户在 run 后修改了 `required_for_passing` 标记
- 旧的 passing evidence 被误用于新的验证配置

---

## 10. Verification Plan & Command Source

### 10.1 Command 元数据拆分

每个 verification command 携带三个独立字段：

| 字段 | 值 | 说明 |
|------|-----|------|
| `command_origin` | `configured` | 用户显式配置于 `.harness/config.json` |
| | `detected` | 从项目 manifest 探测（package.json, Makefile 等） |
| `confirmation` | `not_required` | origin=configured 时自动确认 |
| | `pending` | detected 但等待用户确认 |
| | `confirmed` | 用户已确认 |
| | `rejected` | 用户拒绝 |
| `execution_status` | `not_started` | 未执行 |
| | `running` | 正在执行 |
| | `completed` | 执行成功结束（exit_code 可能非 0） |
| | `failed` | 执行异常（启动失败、超时等，非 exit_code 意义上的失败） |
| | `aborted` | 外部中断 |

### 10.2 探测行为约束

| 规则 | 约束 |
|------|------|
| `detected` + `confirmation=pending` 的命令 MUST NOT 自动执行 | MUST |
| 高成本命令（`npm install`, `docker build`）MUST NOT 被自动探测 | MUST |
| 有副作用的命令（`publish`, `deploy`）MUST NOT 出现在 verification plan 除非用户显式配置 | MUST |
| `command_origin` 和 `confirmation` 写入 `command_completed` event | MUST |
| 0 required steps → `overall_result = "no_checks"` | MUST |

### 10.3 0-Step 项目

文档项目、数据项目、研究项目 MUST 能被 Level 1 检测，但：
- 如果没有 `required_for_passing != false` 的 verification step，`overall_result` SHALL 为 `"no_checks"`
- `"no_checks"` SHALL NOT 被解释为 `"passed"`
- Status 面板 SHALL 区分 "上次验证通过（N steps）" 和 "无可用验证步骤"

---

## 11. Hook Fail-Open Contract

### 11.1 分层责任

```
┌────────────────────────────────────────┐
│  Adapter: 接收 hook 输入                │
│  → 调用 core（环境变量）                 │
│  → 获取 core 中立 outcome               │
│  → 映射为 host-specific 协议输出         │
│  → 错误处理: 生成合法协议格式              │
├────────────────────────────────────────┤
│  Core: 执行业务逻辑                      │
│  → 返回中立 outcome JSON                 │
│  → 不感知 host hook 协议格式              │
│  → 异常时返回 error outcome              │
└────────────────────────────────────────┘
```

### 11.2 Core Neutral Outcome Format

Core 脚本 SHALL 输出以下 JSON 到 stdout：

```json
{
  "status": "ok" | "error",
  "error_code": null | "CONFIG_MISSING" | "JQ_MISSING" | "INTERNAL",
  "message": "human-readable summary",
  "payload": { ... }
}
```

`payload` 内容由具体命令决定（status 面板数据、verification 结果等）。

### 11.3 Adapter 映射规则

**Claude Code adapter**：

| Hook Event | Core Outcome | Adapter Output |
|------------|-------------|----------------|
| SessionStart | status="ok" | `{"continue":true, "hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<payload>"}}` |
| SessionStart | status="error" | `{"continue":true, "suppressOutput":true}` |
| Stop | any | `{"continue":true, "systemMessage":"..."}` 或 `{"continue":true}` |

**Codex adapter**：

Codex hook 事件的输出协议各不相同，adapter MUST 根据事件类型选择合法格式：

| Hook Event | Core Outcome | Adapter Output |
|------------|-------------|----------------|
| SessionStart | status="ok" | `{"continue":true, "hookSpecificOutput":{...}}` |
| SessionStart | status="error" | `{"continue":true}` |
| Stop | any | `{"continue":true}` |
| PreToolUse | status="ok" | `{"continue":true, "hookSpecificOutput":{...}}` (if permissions supported) |
| PreToolUse | status="error" | `{"continue":true}` |
| PostToolUse | any | `{"continue":true}` |

**规则**：
- 如果 adapter 不确定某个 event 的合法协议格式，MUST 输出 `{"continue":true}` 并 suppressOutput
- Adapter MUST NOT 为 "对称性" 在所有 event 上输出相同的结构
- Codex 各 event 的 exact 输出字段名 MUST 在 Phase 3 prototype 中验证

---

## 12. Codex Adapter Design

### 12.1 支持的 Hook Events（官方集合）

基于 Codex 官方文档确认的 hook 事件：

| Event | 是否用于 harness-companion |
|-------|--------------------------|
| `SessionStart` | ✅ 注入 status 摘要 |
| `Stop` | ✅ 注入 handoff 提示 |
| `UserPromptSubmit` | MAY（future：验证用户 prompt 内容） |
| `PreToolUse` | MAY（future：工具调用前检查） |
| `PostToolUse` | MAY（future：工具调用后日志） |
| `PreCompaction` | MAY（future：压缩前保存上下文） |

不在官方集合中的事件（如 `Notification`、`Checkpoint`）MUST NOT 出现在 `adapter.conf` 的能力标志中。

### 12.2 环境变量

| 变量 | 来源 | 说明 |
|------|------|------|
| `PLUGIN_ROOT` | Codex 原生 | 插件根目录。**首选** |
| `PLUGIN_DATA` | Codex 原生 | 插件数据目录。**首选** |
| `CLAUDE_PLUGIN_ROOT` | Codex 兼容层 | Claude Code 兼容性变量。**仅作为回退** |

Adapter 脚本 MUST 优先使用 `PLUGIN_ROOT`/`PLUGIN_DATA`；仅在它们不存在时 fallback 到 `CLAUDE_PLUGIN_ROOT`。

### 12.3 每层唯一配置来源

Codex adapter 的 hook 注册 MUST NOT 在同一配置层重复注册。按安装模式选择**唯一**配置目标：

| 安装模式 | 配置来源 | 文件路径 |
|---------|---------|---------|
| **Plugin**（`.codex-plugin/`） | `hooks.json` | `<plugin_root>/hooks/hooks.json` |
| **Repo-local**（项目内 `.codex/`） | `hooks.json` | `<project>/.codex/hooks.json` |
| **User inline**（全局配置） | `config.toml` | `~/.codex/config.toml` `[[hooks]]` 块 |

规则：
- 同一层 MUST NOT 同时生成 `hooks.json` 和 `config.toml hooks`
- `install.sh` MUST 检测安装模式并写入对应的唯一配置
- 如果检测到已有配置（任何格式），MUST 提示手工迁移而非覆盖

### 12.4 Codex adapter.conf

```ini
name=codex
display_name=Codex OS
protocol_version=1

# File mapping
# Codex default project instruction file is AGENTS.md
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
has_command_windows=true              # commandWindows .cmd fallback

# Degradation modes
fallback_workflow=explicit
windows_sandbox_degraded=true

# Install targets (one per mode, never combined)
plugin_config_type=hooks_json
repo_local_config_type=hooks_json
user_inline_config_type=config_toml
```

---

## 13. 安全模型

### 13.1 Hook Trust

- Hook 运行项目内命令。Codex hooks MUST 在 untrusted 状态下降级为 explicit invocation
- 未获信任时，MUST NOT 自动运行

### 13.2 命令执行安全

| 规则 | 约束 |
|------|------|
| 不得使用 `eval` 拼接未验证输入 | MUST |
| 命令来自 `command[]` 数组（argv），不是 shell 字符串 | MUST |
| 每个 command 独立 timeout（默认 300s） | MUST |
| 命令输出大小限制（默认 10MB） | SHOULD |
| 环境变量写入 evidence 时过滤 secrets（`*_TOKEN`, `*_SECRET`, `*_KEY`） | MUST |
| 完整环境变量 MUST NOT 写入 evidence | MUST |

### 13.3 日志安全

- `log_artifact` 指向命令日志文件。Log MAY 包含 stdout/stderr
- Log 写入前 SHOULD 扫描 secret pattern 并 redact
- Log 文件 SHOULD 加入 `.gitignore`

---

## 14. 向后兼容与数据迁移

| 数据类型 | 策略 |
|---------|------|
| v1.1.2 `feature_list.json` | 读取兼容。写入时使用 v2 schema + association |
| 旧字符串 evidence | `run_id: null`。不参与 passing。保留于数组供审计 |
| 旧 `agent.log` | 读取兼容。不再主动写入 |
| 旧 hook 配置 | 不覆盖。提示手工迁移 |
| 用户自定义模板 | MUST NOT 覆盖。检测冲突并提示 diff |
| `.harness/config.json` | 读取兼容旧 schema。写入升级 |

原则：**读取兼容、写入新格式**。**不静默覆盖**。**幂等迁移**。

---

## 15. Level 1 → Level 2 迁移

| 规则 | 约束 |
|------|------|
| Level 1 run logs（`runs/*.ndjson`）保持完整不变 | MUST |
| 创建 registry 不重写历史日志 | MUST |
| 历史 `run_id` 只能由用户显式关联到 feature | MUST |
| 不得根据时间、分支名、commit 自动推断关联 | MUST |
| Level 1 `overall_result: "passed"` 不得自动升级为 feature passing | MUST |

迁移操作：
1. `/harness:init --level 2` → 创建 `feature_list.json`
2. 用户创建 features：`/harness:feature add <id>`
3. 用户显式关联：`/harness:feature associate <feature-id> <run_id>`
4. 关联记录写入 `evidence_associations[]`

---

## 16. 分阶段实施计划

| Phase | 内容 | 前置条件 |
|-------|------|---------|
| 0 | 冻结 v1.1.2，创建 v2 分支 | — |
| 1 | Core：event log 写入 + lock 协议 + passing 逻辑 + staleness | — |
| 2 | Claude Code adapter | Phase 1 |
| 3 | Codex adapter（Bash-only，按 12.3 节配置） | Phase 2 + Codex hook 协议 prototype |
| 4 | 迁移工具 + 文档 | Phase 2 |
| 5 | 验证 + 发布 | Phase 4 |

---

## 17. 测试矩阵

### 17.1 Core Contract

- Level 0/1/2 累积判定
- 状态机全部合法 transition + 拒绝非法
- 0-step plan → `no_checks`，not `passed`
- 所有 `run_id` null → `replay_required`
- fail-closed 全部场景

### 17.2 Evidence Staleness

- clean → dirty：旧 evidence 失效
- dirty(H1) → dirty(H2)：旧 evidence 失效
- dirty(H) → dirty(H)：相同 dirty state，evidence 有效
- config 修改后旧 evidence 失效
- config 不变，evidence 有效
- HEAD 移动后旧 evidence 失效

### 17.3 Concurrency & Locking

- 两个 writer 同时更新 registry → lock 保证无丢失
- lock timeout → exit 5
- 两个 run 并发 → 不同文件，零竞争
- 同一 run 内 command 顺序 → 文件完整
- started 无 terminal → incomplete，passing=false
- 同 run 多个 terminal → corrupted，passing=false
- association 指向不存在 run → passing=false
- association 指向损坏 run → passing=false
- crash 后 lock 可恢复（stale PID 检测）

### 17.4 Project Diversity

- Node / Python / Rust / Go / Makefile / justfile / 文档项目
- 无 Git 项目 / monorepo / 路径含空格和 Unicode

### 17.5 Host Adapters

- Claude Code SessionStart / Stop 输出格式
- Codex SessionStart / Stop 输出格式（per-event schema）
- Codex hooks.json 生成 / config.toml `[[hooks]]` 生成
- 同一 Codex 安装模式不重复注册
- Codex hooks disabled / untrusted → 降级
- Codex commandWindows .cmd 备选

### 17.6 Migration

- 旧 feature_list.json 读取兼容
- 字符串 evidence → run_id: null
- 用户文件不被覆盖
- Level 1 → Level 2 日志不变、手动关联
- 重复迁移幂等

---

## 18. 风险与未验证假设

### 已确认

- ✅ Codex 使用 AGENTS.md，不是 CLAUDE.md 或 CODEX.md
- ✅ Codex hooks 配置在 `config.toml`（TOML），不是 `settings.json`
- ✅ Codex hooks 支持 `type: "command"`
- ✅ Codex 原生环境变量：`PLUGIN_ROOT`, `PLUGIN_DATA`

### 未验证（需 Phase 3 prototype）

| 假设 | 影响 | 验证时机 |
|------|------|---------|
| Codex 各 hook event 的 exact JSON output schema | adapter 输出格式 | Phase 3 前 |
| `config.toml` `[[hooks]]` block exact schema | 自动配置生成 | Phase 3 前 |
| Codex Windows sandbox hook 可靠性 | Windows 降级策略 | Phase 3 前 |
| Git Bash `mkdir` 锁可靠性 | Windows lock fallback | Phase 2 前 |
| macOS bash 3.2 行为一致性 | core 兼容性 | Phase 1 |

---

## 19. Non-Goals

- PowerShell native / cmd.exe runtime
- Codex Node.js adapter（门槛未达到）
- 3+ adapter 的 machine-readable protocol
- 自动推断 Level 1 历史 evidence → feature 关联
- 自动执行未经确认的 detected 命令
- Audit 绑定特定文件名
- 从 hook 输出反推 feature status

---

## 20. 附录

### 附录 A：Canonical Log Event Schema（摘要）

```
event: "run_started" | "command_completed" | "run_completed" | "run_failed" | "run_aborted"
schema_version: 2

run_started:
    run_id, started_at, project_root, vcs_revision, vcs_revision_source,
    workspace_fingerprint, config_sha256, required_command_ids[],
    capability_level, feature_id?

command_completed:
    run_id, command_id, command[], command_origin, confirmation,
    exit_code, started_at, duration_ms, log_artifact?, log_sha256?

run_completed | run_failed | run_aborted:
    run_id, completed_at, overall_result,
    total_commands, passed_commands, failed_commands, skipped_commands,
    failed_command_ids[]? (run_failed only),
    abort_reason? (run_aborted only)
```

### 附录 B：Feature Association Schema（摘要）

```
feature.evidence_associations[]:
    run_id: string        -- references .harness/logs/runs/<run_id>.ndjson
    associated_at: string -- ISO 8601
    associated_by: string -- "user"
```

### 附录 C：v1.1.2 已知限制

| 限制 | v2 处理 |
|------|---------|
| status.sh abort on missing files | v2 rewrite: `set +e` |
| Audit recency window 固定 | 改为能力评估 |
| 无结构化 evidence 查询 | NDJSON log 使外部查询成为可能 |

### 附录 D：约束级别标记

| 标记 | 含义 |
|------|------|
| **MUST** / **MUST NOT** | 硬约束。不可违反 |
| **SHOULD** / **SHOULD NOT** | 推荐。偏离需要理由 |
| **MAY** | 可选实现 |
| **SHALL** | MUST 的同义词（用于伪代码） |

---

> **状态**：等待审批。确认 v4 后进入实现计划。

# harness-companion 通用化升级 — 方案设计 v3

> 状态: **等待审批** | 日期: 2026-07-31 | 修订: v3
> v2 (已撤回) → v3: 设计评审修订

---

## 决策摘要

| 决策 | 结论 | 理由 |
|------|------|------|
| Codex adapter 投入深度 | **路径 A**：Bash command hooks + 共享 Bash core。不引入 Node.js runtime | Codex hooks 支持 `type: "command"`；双 runtime 会形成双测试矩阵；首期不需要 Node.js |
| Level 1 verify 行为 | **路径 B**：写入 `.harness/logs/verification.ndjson`，不创建临时 feature，不修改 feature status | 项目级验证结果应持久化但不与 feature 混淆；升级到 Level 2 后可由用户显式关联 |

---

## v2 → v3 变更摘要

| # | 变更 | 涉及章节 |
|---|------|---------|
| 1 | 删除 CODEX.md 作为 Codex 知识入口。Codex 默认使用 AGENTS.md | 全文 |
| 2 | Codex adapter 改为纯 Bash command hooks，删除全部 Node.js .mjs 代码和引用 | 4.2, 4.3, 5.2, 7 |
| 3 | 区分"通用语义"（MUST）和"首期 runtime 环境"（默认实现，可替换） | 2, 3 |
| 4 | Capability level 改为能力判定，不再是固定文件套餐 | 5.1 |
| 5 | 新增权威状态层级：registry → log → dashboard → hooks | 5.5 |
| 6 | 新增 Architecture Invariant：adapter 不得包含业务语义 | 5.6 |
| 7 | 新增安全模型 | 8 |
| 8 | 并发设计细化：run 生命周期、NDJSON 追加语义、incomplete run 识别 | 6 |
| 9 | 新增 Level 1 verification ndjson 完整 schema | 5.4 |
| 10 | 新增 verification plan 灵活性：detected/configured/confirmed/executed | 5.3 |
| 11 | 新增 Level 1 → Level 2 迁移路径 | 9.2 |
| 12 | 新增向后兼容策略（读取兼容、写入新格式） | 9.1 |
| 13 | Audit 改为能力评估，不再按固定文件名机械评分 | 5.7 |
| 14 | 全文使用 MUST/SHOULD/MAY 标记约束强度 | 全文 |
| 15 | 新增 Claude Code / Codex adapter contract 对比表 | 5.2 |
| 16 | 扩展测试矩阵：project diversity, failure, migration | 11 |
| 17 | 新增 non-goals | 13 |
| 18 | 新增全文一致性检查结果 | 附录 C |

---

## 目录

1. [Semantic Core Invariants（不可变语义核心）](#1-semantic-core-invariants不可变语义核心)
2. [通用语义 vs 首期 Runtime 环境](#2-通用语义-vs-首期-runtime-环境)
3. [合理边界](#3-合理边界)
4. [架构方案：Core/Adapter Architecture](#4-架构方案-coreadapter-architecture)
5. [推荐方案详细设计](#5-推荐方案详细设计)
6. [并发与 Run 生命周期](#6-并发与-run-生命周期)
7. [安全模型](#7-安全模型)
8. [向后兼容与数据迁移](#8-向后兼容与数据迁移)
9. [Level 1 → Level 2 迁移路径](#9-level-1--level-2-迁移路径)
10. [分阶段实施计划](#10-分阶段实施计划)
11. [测试矩阵](#11-测试矩阵)
12. [风险与未验证假设](#12-风险与未验证假设)
13. [Non-Goals](#13-non-goals)
14. [附录](#14-附录)

---

## 1. Semantic Core Invariants（不可变语义核心）

以下规则是 harness-companion 的 **MUST-level invariants**。任何 platform adapter、runtime 实现、未来版本都 MUST 遵守。违反任一条即破坏 correctness。

### 1.1 Evidence Schema

每条 evidence record MUST 包含以下字段：

| 字段 | 类型 | 语义 |
|------|------|------|
| `schema_version` | integer | evidence schema 版本号 |
| `run_id` | string \| null | 本次 verification run 的唯一标识。`null` 仅用于 legacy 迁移 |
| `command_id` | string | 执行的 verification command 的 id |
| `command` | string[] | 实际执行的命令（argv 数组） |
| `exit_code` | integer | 进程退出码 |
| `started_at` | string (ISO 8601) | 命令开始时间 |
| `duration_ms` | integer | 执行耗时（毫秒） |
| `commit` | string \| null | VCS revision（不可获得时为 null） |
| `working_tree_state` | string | `clean` / `dirty` / `no_git` |
| `command_source` | string | `configured` / `detected` / `confirmed` / `executed`（命令来源） |

### 1.2 Passing Eligibility（Level 2 专属）

`is_eligible_for_passing(feature_id)` MUST 满足全部条件：

1. **Non-empty structured evidence**：feature 的 evidence records 非空
2. **Latest run only**：最新 run 由 evidence 数组的**最后一个非 null run_id 的 structured record** 决定。数组位置 = 时序
3. **Single-run integrity**：只有与最新 run 共享 `run_id` 的 records 参与计算
4. **All exit_code == 0**：参与计算的全部 records exit_code MUST 为 0
5. **Full coverage**：参与计算的 records 的 `command_id` 集合 MUST 覆盖 config 中所有 `required_for_passing != false` 的命令
6. **HEAD match**（git 项目）：最新 run 的 commit MUST 等于当前 HEAD
7. **No cross-run cobbling**：不同 run_id 的 records 不得组合

### 1.3 Feature State Machine（Level 2 专属）

状态集合：`not_started`, `in_progress`, `blocked`, `passing`, `unverified`, `deprecated`

合法 transition（MUST 显式枚举）：

| from | to | 条件 |
|------|----|------|
| `not_started` | `in_progress` | WIP limit 未超 |
| `not_started` | `blocked` | — |
| `in_progress` | `passing` | `is_eligible_for_passing()` 返回 true |
| `in_progress` | `blocked` | — |
| `in_progress` | `unverified` | `--override` 提供 reason |
| `blocked` | `in_progress` | WIP limit 未超 |
| `blocked` | `unverified` | `--override` 提供 reason |
| `passing` | `in_progress` | — |
| `passing` | `deprecated` | — |
| `unverified` | `in_progress` | — |
| `unverified` | `deprecated` | — |
| any | `deprecated` | — |

未列出的 transition MUST 被拒绝。

### 1.4 Fail-Closed 语义

以下场景 MUST exit non-zero，MUST NOT 静默成功：

| 场景 | Exit code |
|------|-----------|
| jq 不可用 | 2 |
| `.harness/config.json` 不存在（Level 1+） | 2 |
| 验证命令不存在 | 1（该 step 的 exit_code = 127） |
| `replay_required`（所有 evidence 的 run_id 为 null） | 2 |
| CAS 冲突超过最大重试次数 | 4 |

### 1.5 Hook Fail-Open

Hook 脚本 MUST 在失败时返回 `{"continue": true}`。Hook 失败 MUST NOT 阻塞 agent session。

### 1.6 原子写入

所有 mutation（registry、log、config）MUST 通过原子写入（temp file + rename）。MUST NOT 原地覆盖。

### 1.7 Override 审计

每次 `--override` bypass MUST 记录 `{by, at, reason, missing_evidence[]}`。

---

## 2. 通用语义 vs 首期 Runtime 环境

### 2.1 分层模型

```
┌─────────────────────────────────────────────────────────┐
│  Adapter Layer（每个 platform 不同）                      │
│  - Hook 事件映射                                         │
│  - 输入规范化、输出转换                                    │
│  - Host-specific 安装和降级                               │
├─────────────────────────────────────────────────────────┤
│  Semantic Core（MUST — 通用、不依赖任何 platform/runtime）  │
│  - 第 1 节全部 invariants                                 │
│  - Capability contracts（Level 0/1/2）                   │
│  - 权威状态层级                                          │
│  - Evidence schema                                       │
│  - 安全边界                                              │
├─────────────────────────────────────────────────────────┤
│  Reference Runtime（首期实现，可替换）                      │
│  - Language: bash 3.2+                                   │
│  - JSON processor: jq 1.6+                               │
│  - Atomic write: mktemp + mv                             │
│  - Unique ID: date-PID-RANDOM                            │
│  - File hash: sha256sum / shasum -a 256                  │
│  - Path normalization: cygpath / sed                     │
│  - Concurrency: CAS + append-only NDJSON                 │
└─────────────────────────────────────────────────────────┘
```

### 2.2 关键区分

| 概念 | 含义 | 约束级别 |
|------|------|---------|
| **通用语义** | 第 1 节的全部 invariants、capability contracts、权威状态层级、evidence schema | MUST — 所有 platform 和 runtime 实现都必须遵守 |
| **首期 Reference Runtime** | bash 3.2+ + jq 1.6+ 的具体实现 | 默认实现。future runtime MAY 完全替换 |
| **首期支持环境** | Linux bash 5.x, macOS bash 3.2+, Windows Git Bash, WSL | 已验证环境。其他环境 MAY 在后续版本支持 |
| **不支持** | Windows cmd.exe, PowerShell native, 无 jq 环境 | 明确标记为 unsupported |

"通用"不等于"所有平台已实现"。它意味着 semantic core 不依赖特定 platform 或 runtime，且 adapter 接口设计允许新增 platform 支持而不修改 core。

---

## 3. 合理边界

### 3.1 支持矩阵

| 维度 | 首期支持 | 约束级别 |
|------|---------|---------|
| Agent 平台 | Claude Code, Codex | MUST |
| 操作系统 | Linux, macOS, Windows (Git Bash / WSL) | 首期 MUST |
| Shell | bash 3.2+ (POSIX sh 子集) | 首期 MUST |
| 项目类型 | Node/TS, Python, Rust/Go, Make/just, 文档项目, monorepo, 无 Git | SHOULD（通过 verification plan 灵活性实现） |
| VCS | Git (clean/dirty), 无 VCS | MUST |
| 工作模式 | Level 0 (knowledge only), Level 1 (project verify), Level 2 (feature-driven) | MUST |

### 3.2 明确排除

| 排除项 | 理由 |
|--------|------|
| Windows cmd.exe / PowerShell native | 核心依赖 bash。Git Bash / WSL 是前提条件 |
| 无 jq 环境 | jq 是 reference runtime 的必需依赖。future runtime MAY 移除 |
| 自动将配置外命令推断为 verification plan（未确认时） | 安全边界。不得静默执行高成本或有副作用的命令 |
| 自动推断 Level 1 历史 run 与 feature 的关联 | 升级到 Level 2 后仅允许用户显式关联 |

---

## 4. 架构方案：Core/Adapter Architecture

### 4.1 目录结构

```
harness-companion/
├── core/                              # Semantic core + reference bash runtime
│   ├── lib/
│   │   ├── state-machine.sh           # 状态机（纯逻辑）
│   │   ├── evidence.sh                # evidence 构建 + staleness
│   │   ├── passing.sh                 # passing eligibility（run_id null 处理）
│   │   ├── atomic-write.sh            # mktemp+mv
│   │   ├── json-helpers.sh            # jq 封装
│   │   └── concurrency.sh             # CAS + NDJSON append
│   ├── harness-feature.sh             # feature CRUD
│   ├── harness-verify.sh              # config-driven 验证链
│   ├── harness-status.sh              # 健康面板（派生视图）
│   └── harness-audit.sh               # 审计（能力评估）
│
├── adapters/
│   ├── claude-code/
│   │   ├── hooks/                     # Bash hooks
│   │   │   ├── session-start.sh
│   │   │   └── stop-handoff.sh
│   │   ├── templates/                 # Claude 专属模板
│   │   │   ├── CLAUDE.md
│   │   │   └── claude-progress.md
│   │   ├── install.sh
│   │   └── adapter.conf
│   │
│   └── codex/
│       ├── hooks/                     # Bash hooks (Codex type: "command")
│       │   ├── session-start.sh
│       │   ├── session-start.cmd      # Windows commandWindows 备选
│       │   ├── stop-handoff.sh
│       │   └── stop-handoff.cmd
│       ├── hooks.json                 # Codex hooks 配置
│       ├── templates/                 # Codex 专属模板
│       │   ├── AGENTS.md              # Codex 默认项目指令文件
│       │   └── codex-progress.md
│       ├── install.sh
│       └── adapter.conf
│
├── templates/                         # 共享项目模板（平台无关）
│   ├── feature_list.json
│   ├── .harness/
│   │   ├── config.schema.json
│   │   ├── config.json.node.example
│   │   ├── config.json.python.example
│   │   ├── config.json.rust.example
│   │   └── config.json.generic.example
│   ├── init.sh
│   └── AGENTS.md                      # 通用 agent 操作手册
│
├── tests/
│   ├── core/                          # 核心语义测试
│   ├── adapters/                      # adapter contract tests
│   │   ├── claude-code/
│   │   └── codex/
│   └── golden/                        # golden tests
│
└── VERSION
```

### 4.2 adapter.conf 格式

**Claude Code adapter**（`adapters/claude-code/adapter.conf`）：

```ini
name=claude-code
display_name=Claude Code
protocol_version=1

# File mapping
knowledge_entry=CLAUDE.md
agent_entry=AGENTS.md
progress_file=claude-progress.md

# Capabilities
has_session_start_hook=true
has_stop_hook=true
has_user_prompt_submit_hook=true
has_pre_tool_use_hook=true
has_post_tool_use_hook=true
has_pre_compact_hook=true

# Hook implementation
hook_runtime=bash
hook_directory=hooks

# Install target
install_config_path=~/.claude/settings.json
install_config_format=json
install_skill_format=claude-skill
```

**Codex adapter**（`adapters/codex/adapter.conf`）：

```ini
name=codex
display_name=Codex OS
protocol_version=1

# File mapping
# Codex 默认项目指令文件是 AGENTS.md
knowledge_entry=AGENTS.md
progress_file=codex-progress.md

# Capabilities (research-confirmed)
has_session_start_hook=true
has_stop_hook=true
has_user_prompt_submit_hook=true
has_pre_tool_use_hook=true
has_post_tool_use_hook=true
has_pre_compact_hook=true
has_notification_hook=true
has_checkpoint_hook=true

# Hook implementation
# Codex supports type: "command" — no Node.js required
hook_runtime=bash
hook_directory=hooks
has_command_windows=true              # Windows commandWindows 备选

# Degradation modes
# hooks disabled / untrusted / unavailable → explicit invocation
fallback_workflow=explicit
windows_sandbox_degraded=true         # Codex Windows sandbox hooks MAY be unreliable

# Install target
# Codex hooks configured in config.toml (TOML format, NOT JSON settings.json)
install_config_path=~/.codex/config.toml
install_config_format=toml
# Also provide hooks.json for Codex hooks directory convention
install_hooks_json=true
```

### 4.3 首个 Adapter 引入 Node.js runtime 的门槛

当前决策：Codex adapter 使用 Bash command hooks（不引入 Node.js）。

引入 Node.js runtime 的 MUST 满足的门槛（不因"对称性"或"理论可移植性"触发）：

1. 经 prototype 验证，某个 Codex hook 行为的正确性**无法**由 Bash adapter 实现
2. 该行为影响 core invariant 的验证（不是可选的增强功能）
3. 经评估，修改 core 为 runtime-agnostic 的成本低于维护双 runtime

这些条件未满足时，Codex adapter MUST 保持 Bash-only。

---

## 5. 推荐方案详细设计

### 5.1 Capability Levels（能力判定，非文件套餐）

Level 由**可用能力**决定，不由特定文件名或文件存在性判定。以下模板文件名是推荐默认值，但 SHOULD NOT 被硬编码为唯一判定条件。

#### Level 0：Knowledge Guidance

**能力**：
- Agent 可发现并读取项目知识和操作指令
- Status 面板可报告 Knowledge 子系统状态

**判定**（满足任一即可）：
- 项目根目录存在 adapter 声明的 knowledge_entry 文件（Claude: `CLAUDE.md`, Codex: `AGENTS.md`）
- 或 agent 平台通过其他机制（如 plugin 配置的 `model_instructions_file`）提供了等效的知识指引

**可用命令**：`/harness:status`（基础），`/harness:audit`（Knowledge 子系统）

**MUST NOT**：
- 强制要求特定文件名
- 自动创建 feature registry

#### Level 1：Project Verification（无 feature tracking）

**能力**：
- 发现并执行 verification plan
- 将项目级验证结果持久化为结构化 evidence
- Status 面板可报告最近验证状态

**判定**：
- 存在可发现的 verification plan（见 5.3 节），且
- verification 命令可执行并产生可持久化的 evidence

**数据存储**：`.harness/logs/verification.ndjson`（见 5.4 节）

**可用命令**：Level 0 + `/harness:verify`（项目级，不关联 feature）

**MUST NOT**：
- 创建 feature registry
- 修改任何 feature status
- 将项目级 passing 推断为任何 feature 的 passing
- 静默执行未经用户确认的 detected 命令

#### Level 2：Feature-Driven Development（完整 harness）

**能力**：
- Level 1 全部能力
- Feature registry 管理（CRUD + 状态机）
- Evidence-to-feature association
- WIP tracking

**判定**：
- 存在 feature registry（默认为 `feature_list.json`），且
- 项目处于 Level 1 能力状态

**权威状态源**：feature registry

**可用命令**：全部 6 个命令

#### 能力总结

| 能力 | Level 0 | Level 1 | Level 2 |
|------|:-------:|:-------:|:-------:|
| Knowledge guidance | ✅ | ✅ | ✅ |
| 可发现的 verification plan | — | ✅ | ✅ |
| 项目级 evidence（ndjson） | — | ✅ | ✅ |
| Feature registry | — | — | ✅ |
| Feature state machine | — | — | ✅ |
| Evidence-to-feature association | — | — | ✅ |
| `/harness:status` | ✅ 基础 | ✅ | ✅ |
| `/harness:verify` | — | ✅ | ✅ |
| `/harness:feature` | — | — | ✅ |
| `/harness:audit` | ✅ 部分 | ✅ | ✅ |

### 5.2 Adapter Contract Tables

#### Claude Code Adapter

| 职责 | 实现方式 | 约束 |
|------|---------|------|
| Hook 事件映射 | Bash 脚本 → `~/.claude/settings.json` 的 hooks 配置 | MUST fail-open |
| SessionStart 注入 | `session-start.sh` → `additionalContext` | 派生视图，非权威状态 |
| Stop 提醒 | `stop-handoff.sh` → `systemMessage` | SHOULD 提示但不阻塞 |
| 项目模板 | `CLAUDE.md`, `claude-progress.md` | 推荐默认值 |
| 安装 | `install.sh` → `~/.claude/skills/harness-companion/` | MUST 备份 settings.json |
| 降级 | N/A（hooks 是 Claude Code 原生能力） | — |

#### Codex Adapter

| 职责 | 实现方式 | 约束 |
|------|---------|------|
| Hook 事件映射 | Bash 脚本 → `config.toml` `[[hooks]]` 块，`type: "command"` | MUST fail-open |
| SessionStart 注入 | `session-start.sh` → hook output | 字段名待 prototype 验证 |
| Stop 提醒 | `stop-handoff.sh` → hook output | SHOULD 提示但不阻塞 |
| Windows 备选 | `commandWindows` 提供 `.cmd` 备选脚本 | Git Bash 不可用时的降级路径 |
| Hook 配置 | 同时提供 `hooks.json` 和 `config.toml` 配置 | 适配 Codex 不同的 hook 发现机制 |
| 项目模板 | `AGENTS.md`, `codex-progress.md` | AGENTS.md 是 Codex 默认项目指令文件 |
| 安装 | `install.sh` → 目标路径取决于 Codex skill/plugin 模式 | MUST 备份现有配置 |
| 降级 | Hook disabled / untrusted / unavailable → 显式工作流模式 | MUST 清晰说明降级原因和受影响功能 |

**Hook 不可用时的降级说明**（MUST 在 install 输出和 README 中呈现）：

| 条件 | 影响 | 操作 |
|------|------|------|
| hooks disabled（用户关闭） | SessionStart 状态注入不可用 | 手动 `/harness:status` |
| hooks untrusted（Codex 信任流程未完成） | 所有自动 hook 不可用 | 完成信任流程或使用显式命令 |
| Windows sandbox（Codex 已知限制） | hooks 可能不触发 | 使用 `commandWindows` 备选或显式命令 |
| hooks 配置缺失 | 同 disabled | 运行 install.sh 注册 hooks |

### 5.3 Verification Plan 设计

#### 命令来源优先级

验证命令 MUST NOT 被硬编码（如固定 `npx tsc --noEmit` → `npm run build` → `npm test`）。

命令来源按优先级：

1. **configured**：用户显式配置于 `.harness/config.json`
2. **detected**：从项目 manifest 探测（`package.json` scripts, `pyproject.toml`, `Makefile`, `justfile`, `Cargo.toml` 等）
3. **confirmed**：探测结果经用户确认（交互式确认或一次性 approve）
4. **executed**：已执行（此时命令来源记录为实际来源）

#### 允许的 Verification Steps

Verification plan MAY 包含任意数量和任意命名的 steps，包括但不限于：

```
lint, typecheck, unit-test, integration-test, build, 
package, e2e-test, security-audit, docs-check, 
domain-specific-validation, ...
```

没有 build step 的项目（文档、数据、基础设施、研究项目）MUST 也能使用 Level 1。

#### 探测行为约束

- **detected** 状态：探测结果 MAY 被输出为建议，但 MUST NOT 在未经用户确认时执行
- 高成本命令（如 `npm install`, `docker build`）MUST NOT 被自动探测为 verification step
- 有副作用的命令（如写入外部服务的 `publish`, `deploy`）MUST NOT 出现在 verification plan 中，除非用户显式配置
- 证据 record 的 `command_source` 字段 MUST 记录命令来源

### 5.4 Level 1 Verification 设计

#### 数据存储

Level 1 验证结果写入：

```
.harness/logs/verification.ndjson
```

每行一条 JSON record（NDJSON 格式）。Append-only。

#### Verification Record Schema

每条 record MUST 包含：

```json
{
  "schema_version": 1,
  "run_id": "20260731T151257Z-12345-32767",
  "started_at": "2026-07-31T15:12:57Z",
  "completed_at": "2026-07-31T15:13:12Z",
  "run_status": "completed",
  "project_root": "/path/to/project",
  "vcs_revision": "abc1234def56",
  "vcs_revision_null_reason": null,
  "config_summary": {
    "config_path": ".harness/config.json",
    "config_sha256": "6dcd4ce23d88e...",
    "command_count": 3
  },
  "commands": [
    {
      "command_id": "typecheck",
      "command": ["npx", "tsc", "--noEmit"],
      "command_source": "configured",
      "exit_code": 0,
      "started_at": "2026-07-31T15:12:57Z",
      "duration_ms": 12400,
      "log_artifact": ".harness/logs/verify-typecheck-20260731T151257Z.log",
      "log_sha256": "abcd1234..."
    }
  ],
  "overall_result": "passed",
  "log_artifact": null,
  "log_sha256": null
}
```

#### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `run_id` | string | 本次 run 的唯一标识。MUST 全局唯一 |
| `run_status` | string | `started` / `completed` / `failed` / `aborted` |
| `vcs_revision` | string \| null | VCS revision。不可获得时为 null |
| `vcs_revision_null_reason` | string \| null | 当 `vcs_revision` 为 null 时说明原因（如 `"no_git"`） |
| `command_source` | string | 命令来源：`configured` / `detected` / `confirmed` / `executed` |
| `overall_result` | string | `passed` / `failed` / `aborted` |

#### Level 1 Passing 语义

- `overall_result: "passed"` 表示**本次项目级 verification run 的全部命令 exit_code 为 0**
- 它 MUST NOT 被解释为任何 feature 的 passing 状态
- 它 MAY 被 Level 2 feature 通过显式关联引用，但 MUST NOT 自动推断关联
- 失败的 run（`overall_result: "failed"`）MUST 同样写入 log，不得丢弃

### 5.5 权威状态层级

以下规则 MUST 在整个系统中保持一致：

| 层级 | 数据 | 角色 |
|------|------|------|
| **权威状态** | Feature registry (`feature_list.json`) | Feature lifecycle 的 single source of truth |
| **运行事实** | Verification log (`verification.ndjson` / feature_events.jsonl) | Append-only 的运行记录。不可修改 |
| **引用关系** | Evidence association（feature 中的 `evidence[].run_id`） | Feature 与 verification run 的关联 |
| **派生视图** | Dashboard / status 输出 | 从权威状态 + 运行事实计算得出。不具备独立修改能力 |
| **提示/上下文** | Hook 输出（SessionStart status, Stop warnings） | 只读信息。不是权威状态。不影响 passing eligibility |

**禁止的模式**：
- 在 registry、log、dashboard、handoff 文档中复制多份可独立修改的 passing 状态
- 从 hook 输出反推 feature status
- Dashboard 显示与 registry 不一致的状态

### 5.6 Architecture Invariant：Adapter 不得包含业务语义

**MUST**：以下规则只能存在于 `core/` 中。任何 adapter MUST NOT 包含或重新实现：

- Feature 状态机 transition 逻辑
- WIP limit 判定
- Passing eligibility 计算
- Evidence validity 判断
- Verification result 语义（什么叫 "passed"）
- Override audit 逻辑
- run_id 生成或验证规则

**Adapter 的允许职责**（MUST NOT 超出）：

1. Host 事件映射（接收 platform hook 输入 → 转化为环境变量 → 调用 core）
2. 输入规范化（平台特定路径分隔符、JSON 字段名差异）
3. 调用 core（通过环境变量传递配置 → 执行 core 脚本）
4. 输出转换（core 的输出 → platform 期望的 hook 协议格式）
5. Host-specific 安装和降级处理

**Contract test 验证**：每个 adapter 的测试 MUST 断言：
- adapter 输出的 feature 状态与 core 计算一致
- adapter 不包含业务逻辑的特定字符串（如 `is_eligible_for_passing` 函数体）

### 5.7 Audit 设计：基于能力评估

Audit MUST 评估**能力是否存在**，而不是按特定文件名机械评分。

#### 评估维度

| 子系统 | 评估方式 | 高置信度探测入口（SHOULD，不是唯一方式） |
|--------|---------|------------------------------------------|
| Knowledge | Agent 能否找到项目知识和操作指令 | adapter 声明的 knowledge_entry 文件 |
| Environment | 开发环境是否可复现 | `init.sh`, `Makefile`, `justfile`, `Taskfile`, CI workflow |
| Progress | 是否有工作记录机制 | 进度文件（任意名称），handoff 文档 |
| Scope/Feature | 是否有 work-item tracking | `feature_list.json`, YAML registry, SQLite, 外部 issue tracker |
| Verification | 是否有可执行的验证链 | `.harness/config.json`, `package.json` scripts, `Makefile` targets |
| Observability | 是否有运行记录 | `verification.ndjson`, 测试报告, CI 日志 |
| Handoff | 是否有结构化交接文档 | 任意结构化交接文档（不限文件名） |

#### 评分原则

- 探测入口（默认文件名）是 SHOULD 级别的高置信度提示，不是 MUST 级别的唯一合格实现
- 如果项目通过等效方式实现了能力（如用 `Makefile` 而非 `init.sh`），SHOULD 给予相同评分
- Audit 输出 MUST 区分 "能力存在但实现方式非默认" 和 "能力缺失"

---

## 6. 并发与 Run 生命周期

### 6.1 Run 状态模型

每个 verification run MUST 经过以下状态之一：

```
started → completed   （全部命令执行成功）
started → failed      （至少一个命令 exit_code != 0，或执行过程异常）
started → aborted     （外部中断，如 SIGTERM、超时）
```

`started` 状态 MUST 在 run 开始时写入（marker record）。

### 6.2 Run ID 唯一性

`run_id` MUST 全局唯一。生成方式（reference runtime）：

```
timestamp-PID-RANDOM
```

`run_id` 格式是 runtime 实现细节。任何产生全局唯一标识的算法 MAY 使用。

### 6.3 NDJSON 并发追加

`verification.ndjson` 是 NDJSON 格式（每行一条 JSON record）。并发追加：

- 单行写入 + `\n` 终止
- 底层文件系统 `O_APPEND` 或等效原子追加
- 单行 MUST ≤ 操作系统原子写入上限（通常 ≤ PIPE_BUF，但 NDJSON 记录 > PIPE_BUF 时依赖行级完整性）
- 如果 OS 不支持原子行追加，MAY 退化为 逐行 atomic write（temp + rename per record）
- MAY 在 append 后读取并验证写入行的完整性

### 6.4 Feature Registry 并发（CAS）

Level 2 registry 更新使用 CAS（Compare-and-Swap）：

1. 读取 `feature_list.json`，记录 `last_updated`
2. 在内存中修改
3. 读取当前 `feature_list.json` 的 `last_updated`
4. 如果不一致 → CONFLICT → retry（最多 3 次，每次随机 10-100ms jitter）
5. 如果一致 → atomic write 新内容
6. 3 次失败 → exit 4

### 6.5 日志成功但 Registry 关联失败的恢复

场景：verification 执行成功，evidence 写入了 ndjson，但 feature registry CAS 更新失败。

恢复策略：

1. ndjson 中的 evidence record 是持久化的运行事实
2. Registry 更新失败时 MUST 报错，exit non-zero
3. 用户可以手动重试关联：`/harness:feature associate <feature-id> <run_id>`
4. 下次 verify 也会自然覆盖（新的 evidence 在数组中排后面）

### 6.6 Incomplete Run 识别

- 存在 marker record `run_status: "started"` 但没有对应 `run_status: "completed"` / `"failed"` / `"aborted"` 的 run → incomplete
- Status 面板 SHOULD 警告 incomplete run
- Incomplete run 的 evidence MUST NOT 参与 passing eligibility
- Cleanup：MAY 提供 `harness-log-cleanup.sh` 标记或移除 incomplete run

### 6.7 同一 Run 的重复提交

同一 `run_id` 的 evidence records MAY 多次追加（例如逐 command 写入），但 `run_status` 的最终状态（completed/failed/aborted）MUST 只写入一次。

---

## 7. 安全模型

### 7.1 Hook Trust

- Hook 运行项目内命令，MUST 遵守 platform 的 trust 机制
- Codex hook trust 流程：untrusted hooks MUST NOT 自动运行。用户 MUST 显式信任后才能激活 hook 模式
- 未获信任时，MUST 降级为 explicit invocation 模式

### 7.2 命令执行安全

| 规则 | 约束级别 |
|------|---------|
| 不得使用 `eval` 拼接未验证的用户输入 | MUST |
| 命令来自 `config.json` 的 `command[]` 数组（argv），不是 shell 字符串 | MUST |
| 每个 command 有独立 timeout（默认 300s，可配置） | MUST |
| 命令输出大小限制（默认 10MB，可配置） | SHOULD |
| 环境变量写入 evidence 时 MUST 过滤 secrets（基于已知 key pattern 如 `*_TOKEN`, `*_SECRET`, `*_KEY`） | MUST |
| 完整环境变量 MUST NOT 写入 evidence | MUST |

### 7.3 日志安全

- evidence 中的 `log_artifact` 指向日志文件路径
- log 文件 MAY 包含命令的 stdout/stderr
- Log 写入前 SHOULD 扫描常见 secret pattern 并 redact
- Log 文件 SHOULD 加入 `.gitignore`

### 7.4 Hook 失败不能伪装为验证通过

- Hook 自身的失败（crash, timeout）MUST NOT 被报告为 "verification passed"
- Hook 输出中的 `continue: true` 仅表示 hook 不阻塞 session，不等于验证通过
- Verification status 只能由 `harness-verify.sh` 的 exit code + evidence log 决定

---

## 8. 向后兼容与数据迁移

### 8.1 兼容策略

| 数据类型 | 策略 |
|---------|------|
| v1.1.2 `feature_list.json` | 读取兼容：识别旧字段。写入新格式：添加 `schema_version`、`last_updated` |
| 旧字符串 evidence (`evidence[]` 中的 string) | 读取时标记为 `run_id: null`，不参与 passing。写入时使用新格式 |
| 旧 `agent.log` | 读取兼容。不再主动写入（新数据走 ndjson） |
| `Codex-progress.md` (旧) | 读取兼容。继续写入当 adapter 声明了 progress_file |
| 旧 hook 配置 | 不覆盖。install 时检测已有配置并提示手动迁移 |
| 用户自定义模板 | MUST NOT 覆盖。init 时检测冲突并提示 diff |
| `.harness/config.json` | 读取兼容旧 schema。写入时升级到新 schema_version |

### 8.2 迁移原则

- **读取兼容、写入新格式**：MUST 能读取旧版本数据。写入时 MUST 使用当前 schema_version
- **不静默覆盖**：init、install、migrate MUST 在目标文件已存在时提示，不静默替换
- **幂等迁移**：重复运行迁移 MUST 产生相同结果

### 8.3 旧数据与 passing eligibility

- v0 字符串 evidence → `run_id: null` → 不参与 passing
- v1.1.0 structured evidence 无 `run_id` → `run_id: null` → 不参与 passing
- 所有 `run_id: null` → `replay_required`（exit 2，提示重新 verify）
- 重新 verify 后产生有 `run_id` 的 evidence → 旧 records 保留于数组（审计用途）
- 旧 records 不得被删除或修改

---

## 9. Level 1 → Level 2 迁移路径

### 9.1 迁移规则

| 规则 | 约束 |
|------|------|
| 原 Level 1 `verification.ndjson` 保持完整不变 | MUST |
| 创建 feature registry 不重写历史日志 | MUST |
| 历史 `run_id` 只能由用户显式关联到新 feature | MUST |
| 不得根据时间、分支名或 commit message 自动推断关联 | MUST |
| 旧项目级 `overall_result: "passed"` 不得自动升级为 feature passing | MUST |
| `schema_version` 迁移必须幂等 | MUST |

### 9.2 迁移操作

用户从 Level 1 升级到 Level 2：

1. 运行 `/harness:init --level 2`（或 `--with-registry`）
2. 创建 `feature_list.json`
3. 用户自行创建 features（`/harness:feature add <id>`）
4. 用户显式关联历史 evidence：`/harness:feature associate <feature-id> <run_id>`
5. 关联操作记录为 `association` 事件（写入 evidence log）

---

## 10. 分阶段实施计划

### Phase 0：冻结 + 基线

- 标记 `v1.1.2-frozen` tag
- 创建 `feat/harness-companion-v2` 分支
- v1 测试在 CI 中持续运行

### Phase 1：核心提取 + 并发基础设施（最小风险）

- 创建 `core/` 目录，迁移库文件（环境变量参数化）
- 实现 CAS + NDJSON append 并发基础设施
- 处理 `run_id: null` → `replay_required`
- 核心测试 ≥ 90 passed, 0 failed
- 运行时目录：`~/.harness-companion/`

### Phase 2：Claude Code Adapter

- 从 v1.1.2 hooks/templates 迁移
- `adapter.conf` + semantic tests

### Phase 3：Codex Adapter（Bash-only）

**前置条件**：Codex hook 协议 prototype 验证完成（附录 B 中标记的假设已验证或确认可接受风险）

- Bash command hooks（`type: "command"`）
- `commandWindows` `.cmd` 备选脚本
- `hooks.json` + `config.toml` 配置生成
- 降级策略（hooks disabled/untrusted/unavailable）
- 模板：`AGENTS.md`, `codex-progress.md`

### Phase 4：迁移工具 + 文档

### Phase 5：验证 + 发布

---

## 11. 测试矩阵

### 11.1 Core Contract Tests

| 测试 | 覆盖规则 |
|------|---------|
| Level 0 能力判定（无 config, 无 registry） | Level 判定逻辑 |
| Level 1 能力判定（有 config, 无 registry） | Level 判定逻辑 |
| Level 2 能力判定（有 config, 有 registry） | Level 判定逻辑 |
| Level 1 verify 产生 ndjson | 5.4 |
| Level 1 overall_result = "passed" 不产生 feature status | 5.4 passing 语义 |
| Level 2 evidence 只能引用真实 run_id | 1.2 |
| Adapter 不包含 WIP/evidence 业务逻辑 | 5.6 contract test |
| 状态机全部合法 transition | 1.3 |
| 状态机会拒绝未列出的 transition | 1.3 |
| 全部 evidence run_id 为 null → replay_required | 1.2 |
| fail-closed 场景（missing jq, missing config, missing command） | 1.4 |

### 11.2 Project Diversity Tests

| 项目类型 | 验证点 |
|---------|--------|
| Node/TypeScript | 探测 package.json scripts |
| Python | 探测 pyproject.toml / setup.cfg |
| Rust | 探测 Cargo.toml |
| Go | 探测 go.mod / Makefile |
| Makefile-only | 探测 Makefile targets |
| justfile-only | 探测 justfile recipes |
| 文档项目（无 build step） | Level 1 可用，0 verification steps |
| 无 Git 项目 | vcs_revision = null, null_reason = "no_git" |
| Monorepo（子目录启动） | project_root 正确 |
| 路径含空格和 Unicode | 路径处理正确 |

### 11.3 Host Adapter Tests

| 测试 | Platform |
|------|---------|
| SessionStart hook 输出正确 platform 格式 | Claude Code |
| Stop hook 输出正确 platform 格式 | Claude Code |
| Hook 模板包含 CLAUDE.md（非 AGENTS.md 作为知识入口） | Claude Code |
| SessionStart hook 输出正确 platform 格式 | Codex |
| Stop hook 输出正确 platform 格式 | Codex |
| hooks.json 结构正确 | Codex |
| config.toml `[[hooks]]` 块正确 | Codex |
| hooks disabled → 降级提示 | Codex |
| hooks untrusted → 降级提示 | Codex |
| hookless explicit invocation 可用 | Codex |
| commandWindows .cmd 脚本可执行 | Codex |
| Git Bash / WSL 均可运行 | Codex (Windows) |

### 11.4 Failure and Concurrency Tests

| 测试 | 验证点 |
|------|--------|
| 命令不存在 → exit 127，不伪装通过 | 1.4, 7.4 |
| jq 不存在 → exit 2 | 1.4 |
| verification 中途终止 → incomplete run | 6.1, 6.6 |
| hook timeout → fail-open, continue: true | 1.5, 7.4 |
| 日志目录不可写 → 明确报错 | 7.4 |
| CAS 冲突 → retry 成功 | 6.4 |
| CAS 3 次冲突 → exit 4 | 6.4 |
| 两个 verify 并发 → 两条独立 evidence 均保留 | 6.3 |
| 日志成功但 registry 关联失败 → 报错 + 手动恢复路径 | 6.5 |
| 同一 run_id 重复追加 → 不损坏数据 | 6.7 |
| 重复迁移 → 幂等 | 8.2 |

### 11.5 Migration Tests

| 测试 | 验证点 |
|------|--------|
| 旧 feature_list.json（v1.1.2 schema） | 读取兼容，写入升级 |
| 字符串 evidence 数组 | run_id: null，不参与 passing |
| 已有 AGENTS.md 不被 init 覆盖 | 8.2 |
| Level 1 → Level 2：原 ndjson 不变 | 9.1 |
| Level 1 → Level 2：手动关联 run_id 到 feature | 9.2 |
| 重复迁移结果一致 | 8.2 |

---

## 12. 风险与未验证假设

### 12.1 主要风险

| 风险 | 缓解 |
|------|------|
| Codex hook output 字段名与 Claude Code 不同 | Phase 3 前 prototype 验证 |
| Codex Windows sandbox hook 不可靠 | 降级到 explicit invocation + commandWindows 备选 |
| macOS bash 3.2 语法限制 | CI 中测试 macOS bash 3.2 |
| Evidence NDJSON log 无限增长 | 初期无需压缩。提供 `harness-log-compress.sh` 维护工具 |

### 12.2 经研究确认（不再是不确定的假设）

- ✅ Codex 有 SessionStart/Stop hooks
- ✅ Codex hooks 配置在 `~/.codex/config.toml`（TOML），不是 `settings.json`
- ✅ Codex 使用 `AGENTS.md` 作为项目指令文件，不使用 `CLAUDE.md`
- ✅ Codex hooks 支持 `type: "command"`（可以调用 Bash 脚本，不需要 Node.js）
- ✅ Codex 有 `commandWindows` 用于 Windows-specific 命令

### 12.3 仍未验证

| 假设 | 影响 | 验证时机 |
|------|------|---------|
| Codex hook JSON output 的 exact 字段名 | adapter hook 输出格式 | Phase 3 前 |
| `config.toml` `[[hooks]]` 块的 exact schema | 自动生成配置 | Phase 3 前 |
| Codex `CLAUDE_PLUGIN_ROOT` 兼容在最新版本中仍有效 | bash adapter 可复用 Claude hook 脚本结构 | Phase 3 前 |
| Codex Windows sandbox hook 不可靠的具体条件 | Windows 降级策略 | Phase 3 前 |
| `.codex-plugin/plugin.json` 完整 schema | 插件方式安装 | Phase 3 前 |
| macOS bash 3.2 下 `date -u +%Y-%m-%dT%H:%M:%SZ` 行为 | run_id 格式 | Phase 1 |

---

## 13. Non-Goals

以下明确**不在**本次设计的范围内：

- 支持 PowerShell native / cmd.exe 作为 runtime shell
- Codex adapter 的 Node.js runtime（门槛未达到，见 4.3 节）
- 3+ adapter 的 machine-readable capability protocol（2 adapters 时不需要）
- 自动将历史 Level 1 verification 结果推断为 feature passing 状态
- 自动探测并执行未确认的 verification 命令
- 将 Audit 绑定到特定文件名
- 从 hook 输出反推 feature status

---

## 14. 附录

### 附录 A：全文一致性检查结果

对以下关键词进行了全文搜索和矛盾修正：

| 关键词 | 搜索结果 | 一致性 |
|--------|---------|--------|
| `AGENTS.md` | 出现在 Codex adapter（知识入口）、Claude Code adapter（通用 agent 指令）、共享模板 | ✅ 一致：Codex 的 knowledge_entry 是 AGENTS.md，Claude 的 agent_entry 也是 AGENTS.md，两者角色不同 |
| `CODEX.md` | 不出现在本文中（v2 中曾出现 16 次，已全部删除） | ✅ Codex 不使用 CODEX.md 作为默认项目指令文件 |
| `settings.json` | 仅出现在 Claude Code adapter 的 install_config_path | ✅ Codex adapter 使用 config.toml |
| `config.toml` | 出现在 Codex adapter install_config_path | ✅ 与 Codex 实际配置格式一致 |
| `hooks.json` | 出现在 Codex adapter（hooks.json 作为 Codex hooks 发现机制的备选配置） | ✅ 与 Codex hooks 目录约定一致 |
| `Node.js` / `.mjs` | 不出现在本文中（v2 中曾出现于 Codex adapter 代码示例，已全部删除） | ✅ Codex adapter 使用 Bash-only |
| `bash` | 出现在 reference runtime 声明中，Codex adapter hook_runtime=bash | ✅ 一致 |
| `jq` | 出现在 reference runtime 声明中，fail-closed 规则中 | ✅ 一致 |
| `feature_list.json` | 出现在 Level 2 判定（默认 registry 文件名） | ✅ SHOULD 级别，非 MUST |
| `passing` | 出现在语义不变表中（MUST 规则），Level 2 专属 | ✅ 与 Level 1 的 `overall_result` 明确区分 |
| `run_id` | 出现在 evidence schema、passing eligibility、并发设计、Level 1 ndjson | ✅ 语义一致 |

### 附录 B：v1.1.2 已知限制（不变）

来自 v1.1.2 MIGRATION.md 的 residual risk 表（与本设计无关的部分略）：

| 限制 | v2 处理 |
|------|---------|
| `harness-status.sh` 在缺失文件时 abort | v2 已在 status v2 rewrite 中修复（`set +e`） |
| Audit recency window 全局固定 | 不在本设计范围。v2 audit 已改为能力评估 |
| 无结构化 evidence 查询 | 不在本设计范围。ndjson log 使外部查询成为可能 |

### 附录 C：设计粒度说明

本文使用以下约束级别标记：

| 标记 | 含义 | 示例 |
|------|------|------|
| **MUST** | 不可违反的硬约束 | "adapter MUST NOT 包含 WIP 判定逻辑" |
| **MUST NOT** | 严禁的行为 | "MUST NOT 静默成功" |
| **SHOULD** | 推荐遵守，偏离需要理由 | "SHOULD 扫描 secret pattern" |
| **SHOULD NOT** | 推荐避免 | "SHOULD NOT 硬编码为唯一判定条件" |
| **MAY** | 可选实现 | "MAY 提供 log 压缩工具" |

实现细节（函数拆分、helper 文件边界、错误消息措辞、不影响 contract 的目录细节）留给实现阶段决定，不出现在本设计中。

---

> **状态**：等待用户审批。确认 v3 设计后，进入实现计划。

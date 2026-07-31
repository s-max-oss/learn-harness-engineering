# harness-companion 通用化升级 — 方案设计

> 状态: **等待审批** | 日期: 2026-07-31 | 版本: v1 (Draft)

---

## 目录

1. [对现状的批判性分析](#1-对现状的批判性分析)
2. ["通用"的合理边界](#2-通用的合理边界)
3. [备选架构方案](#3-备选架构方案)
4. [推荐方案及理由](#4-推荐方案及理由)
5. [分阶段迁移计划](#5-分阶段迁移计划)
6. [验证方法设计](#6-验证方法设计)
7. [风险和待决策问题](#7-风险和待决策问题)

---

## 1. 对现状的批判性分析

v1.1.2 是一个经过充分验证的可靠实现（87/87 测试通过），但其设计明显偏向 Claude Code + Bash/Unix + Git + Node/TypeScript + 单 agent 软件项目。以下将当前设计中的内容分为三类。

### 1.1 第 1 类：真正平台无关的 Harness Engineering 原则

这些是 v1.1.2 中**已经正确实现**、**不应改变**的核心设计原则：

| 原则 | 当前实现 | 评价 |
|------|---------|------|
| **结构化 evidence** | JSON 对象 `{id, exit_code, commit, run_id, ...}` | 设计优秀。应保留并作为跨平台交换格式 |
| **run_id 分组** | timestamp-PID-RANDOM，append-only 数组位置判定最新 run | 正确。`run_id` 生成器是唯一需适配的 OS 相关点 |
| **fail-closed** | 缺失 jq/config 时 exit 2，不伪造成功 | 核心原则。必须保留 |
| **原子写入** | mktemp + mv（同目录同文件系统） | POSIX 语义，跨平台可行。保留 |
| **状态机** | 6 状态 + 显式 transition table + evidence gate | 纯粹的逻辑规则，与平台无关。保留 |
| **WIP 限制** | 可配置 (`wip_limit`)，默认 1 | 项目级策略，与平台无关。保留 |
| **override 审计记录** | `{by, at, reason, missing_evidence[]}` | 审计模式正确。保留 |
| **hook fail-open** | trap ERR → `{"continue":true}` | 正确。hook 不应阻塞 agent |
| **dry-run 默认** | `--write` 才写文件 | 安全设计。保留 |
| **latest-run-only passing** | 不允许跨 run 拼凑 evidence | 正确。保留 |
| **完整性验证** | `install-receipt.json` 含所有脚本的 SHA-256 | 保留并扩展到 adapter 文件 |

### 1.2 第 2 类：Claude Code 专属能力或约定

这些是**与 Claude Code 绑定**的元素，需要参数化或隔离到 adapter：

| 元素 | 文件/位置 | Claude 专属程度 | 问题描述 |
|------|-----------|----------------|---------|
| `CLAUDE.md` 作为必选文件 | `SKILL.md`, `init.sh` 模板, `session-start.sh`, `harness-files.md`, `harness-status.sh` | **高** | 与 `AGENTS.md` 一起成为最小 harness 的 4 个必选文件之一。Codex 使用不同的入口文件 |
| `claude-progress.md` 命名 | 文件名本身, `SKILL.md`, 模板, `harness-files.md` | **高** | 带 Claude 平台命名的 progress 文件 |
| `~/.claude/settings.json` hook 注册 | `install.sh`, `SKILL.md`, `README.md` | **高** | 仅 Claude Code 有这个文件路径 |
| `~/.claude/skills/` 安装路径 | `install.sh`, `README.md` | **高** | Claude Code skill 目录约定 |
| `~/.claude/harness-companion/` 运行时目录 | `baseline.sh`, `session-start.sh`, `stop-handoff.sh` | **中** | baseline 和日志路径。可以参数化 |
| SessionStart/Stop hook 协议 | `hooks/*.sh` 输出 `{"continue":true,...}` 格式 | **高** | 各 agent 平台的 hook/plugin 协议不同 |
| `additionalContext` / `systemMessage` 注入 | `session-start.sh` → `additionalContext`, `stop-handoff.sh` → `systemMessage` | **高** | Claude Code 特定字段 |
| `/harness:xxx` 斜杠命令 | `SKILL.md` | **中** | Claude Code skill 命令格式。其他平台有不同的命令机制 |
| `bash init.sh` 作为标准启动路径 | `SKILL.md`, 模板, `harness-files.md` | **中** | 脚本语言绑定。Python 项目可能用 `make init` 或 `tox` |
| `npm` 命令示例 | 模板 `CLAUDE.md`, `init.sh` 模板, `harness-files.md` | **中** | 课程示例（Electron/TS），但文档将其呈现为接近通用 |
| `agent.log` `CLOSE` marker | `harness-status.sh`, `stop-handoff.sh`, `harness-files.md` | **低** | CLOSE 语义本身是通用的，但 `agent.log` 的 NDJSON 格式假设 agent 会写它 |
| "Claude Code" 品牌 | `README.md` 首句, `SKILL.md` | **低-中** | 文档中的品牌提及 |

### 1.3 第 3 类：来自课程示例、但不应成为普遍要求的实现细节

这些是**来自 `learn-harness-engineering` 课程的合理示例**，但在当前设计中**被过度推广为通用要求**：

| 元素 | 为什么是课程相关的 | 为什么不应普遍化 |
|------|-------------------|-----------------|
| **7 子系统分类** | Knowledge/Environment/Progress/Scope/Verification/Observability/Handoff 来自课程第 3 课 | 子系统数量、名称、分组是课程教学工具。一个嵌入式 C 项目的 "Environment" 子系统含义与 Electron 项目完全不同 |
| **4 文件最小 harness = AGENTS.md + CLAUDE.md + feature_list.json + init.sh** | 课程项目是 Claude Code + Node/TS + Electron | 通用最小 harness 应该只有 `feature_list.json`（scope） + 一个知识入口文件（名称可配）。其他文件按需 |
| **Git 作为接近必需** | 几乎所有示例和检查都以 git 为中心 | `evidence.commit`、`git rev-parse`、baseline 都以 git 为默认 VCS。非 git 项目被当做 "降级模式" 处理 |
| **feature-driven workflow** | WIP=1, `feature_list.json` 的 feature 粒度假设 | 不是所有项目都以 feature 为单位工作。配置管理仓库、数据工程 pipeline、研究项目有不同粒度 |
| **Git commit freshness** | evidence 的 staleness 以 commit 匹配判定 | 对于无 commit 习惯的项目，这个检查无意义。应该是可选的 |
| **Node/TypeScript 工具链** | 模板中 `npm install`, `npx tsc`, `npm test` | Python、Rust、Go、C 项目需要不同的工具链。v1 已通过 config-driven verify 解决，但模板和文档仍有偏见 |
| **`bash init.sh` 作为入口** | 课程项目用 bash 统一入口 | Python 项目可能更喜欢 `make init` 或 `tox`。bash 本身就是一个依赖 |
| **Electron 架构** | 模板 `AGENTS.md` 和 `CLAUDE.md` 中的 main/preload/renderer 层 | 只有 Electron 项目需要这个分层 |
| **`logger.ts` / `loop.sh`** | 文档和 audit 中提到 | 课程示例中的具体文件名，不应该成为标准 |
| **NDJSON agent.log** | 课程中 `agent.log` 格式定为 `{"ts":...,"step":N,"action":"WRITE"}` | 格式选择是合理的，但不是唯一正确的 |

---

## 2. "通用"的合理边界

### 2.1 应支持的维度

| 维度 | v2 目标 | 理由 |
|------|---------|------|
| **Agent 平台** | Claude Code、Codex | 用户明确提到的两个平台。其他平台在需求出现时按相同模式接入，但不预先支持 |
| **操作系统** | Linux、macOS、Windows（含 Git Bash 和 WSL） | 覆盖 99% 的开发场景 |
| **Shell** | bash（POSIX sh 子集）、PowerShell（仅限 Windows native 场景的薄适配层） | bash 是通用胶水语言，但 Windows native 用户不应被要求安装 Git Bash |
| **项目类型** | Node/TypeScript、Python、generic（无特定工具链假设） | 当前 fixture 已有这三类。Rust/Go 后续按需接入 |
| **VCS** | Git、无 VCS | Git 是当前唯一支持的 VCS，但不应该成为必需 |
| **工作模式** | feature-driven（WIP=1）、task-driven（多任务并发）、continuous（无明确 feature 边界） | 当前只支持 feature-driven |
| **Agent 数量** | 单 agent、多 agent 并发（共享 `feature_list.json`） | 当前设计假设单 agent，但原子写入已部分解决并发问题 |

### 2.2 不支持的（明确排除）

| 排除项 | 理由 |
|--------|------|
| 非英语 harness 文件内容 | 文档已有多语言，但 harness 文件本身的结构化字段和 CLI 输出保持英文 |
| Windows cmd.exe / PowerShell 作为主 shell | 核心用 POSIX sh 编写。Windows 通过 Git Bash 或 WSL 支持 |
| SVN / Mercurial / Perforce | Git 是唯一的版本控制集成。其他 VCS 降级为 `commit: null` |
| 移动端 / 嵌入式开发环境 | 工具链差异过大，不在 scope |
| CI/CD 深度集成（Jenkins/GitHub Actions 插件） | harness-companion 是开发者工作站工具，CI 集成是独立关注点 |
| 非 JSON 的 evidence 格式 | JSON 是交换格式。不需要 YAML/TOML/XML |
| 远程 agent / 非本地文件系统 | 所有脚本假设本地文件访问 |

### 2.3 避免过度复杂化的策略

1. **核心/适配器分离但不过度抽象**：只有真正在不同平台间变化的点才通过适配器处理
2. **约定优于配置**：默认行为覆盖 80% 场景，配置文件覆盖剩余 20%
3. **渐进式接入**：一个项目可以只使用 harness-companion 的部分功能，不需要全量 7 子系统
4. **不在核心中包含平台专属文件**：Claude/Codex 的 hook 文件和模板放在各自的适配器目录中
5. **不为"未来可能"的平台预先设计**：只用 2 个 adapter 验证接口，在第 3 个平台出现前不做"未来兼容"

---

## 3. 备选架构方案

### 3.1 方案 A：最小参数化（Conservative Parameterization）

**核心思路**：保持 v1.1.2 的单体 bash 架构，通过配置文件和少量参数化消除硬编码。

**核心抽象**：
- 所有脚本保持不变，但将硬编码的文件名、路径、平台名称改为从 `.harness/config.json` 读取
- `.harness/config.json` 新增 `platform` 和 `project` 段：

```json
{
  "schema_version": 2,
  "platform": {
    "type": "claude-code",
    "knowledge_entry": "CLAUDE.md",
    "progress_file": "claude-progress.md",
    "hooks_dir": "~/.claude/settings.json"
  },
  "project": {
    "vcs": "git",
    "work_mode": "feature-driven",
    "wip_limit": 1
  },
  "verification": { }
}
```

- 模板目录按平台组织：`templates/claude-code/`、`templates/codex/`

**平台接入**：
- 修改 `install.sh`，根据 `--platform claude-code|codex` 选择模板和 hook 注册目标
- 每个平台的 hook 协议适配在独立的 hooks 子目录中

**配置、状态、evidence 共享**：
- evidence 格式不变（JSON，跨平台）
- `feature_list.json` 格式不变
- 运行时目录从 `~/.claude/harness-companion/` 改为 `~/.harness-companion/`

**安装、升级、版本漂移**：
- `install-receipt.json` 记录平台类型
- 升级脚本检查平台类型，只更新匹配的适配器
- 版本号统一管理

**优点**：
- 改动最小，风险最低
- 所有 v1.1.2 已验证的可靠性保持完整
- 4-6 周可实现

**代价**：
- 未解决平台专属文件伪装成通用核心的问题（`CLAUDE.md` 模板仍为核心模板，只是按平台选择）
- `.harness/config.json` 会膨胀，混合关注点
- 添加第 3 个平台需要修改核心脚本（新增 case 分支）

**主要风险**：中等。可能演变成 "大配置文件" 模式，平台差异散落在配置的各个角落。这正是"不得用名称全局替换生成其他平台版本"试图防止的模式。

---

### 3.2 方案 B：Core/Adapter Architecture（核心/适配器架构）

**核心思路**：将 v1.1.2 重构为三层——通用核心（Harness Engine）、平台适配器、共享项目模板。

**目录结构**：

```
harness-companion/
├── core/                         # Harness Engine（平台无关）
│   ├── lib/
│   │   ├── state-machine.sh      # 状态机（纯逻辑）
│   │   ├── evidence.sh           # 结构化 evidence
│   │   ├── passing.sh            # passing eligibility
│   │   ├── atomic-write.sh       # 原子写入
│   │   └── json-helpers.sh       # JSON 操作（jq 封装）
│   ├── harness-feature.sh        # feature CRUD（无平台假设）
│   ├── harness-verify.sh         # 验证链（config-driven，已通用）
│   ├── harness-status.sh         # 状态面板（文件名从环境变量读取）
│   └── harness-audit.sh          # 审计（5-axis，参数化文件列表）
│
├── adapters/                     # 平台适配器
│   ├── claude-code/
│   │   ├── hooks/
│   │   │   ├── session-start.sh
│   │   │   └── stop-handoff.sh
│   │   ├── templates/
│   │   │   ├── CLAUDE.md
│   │   │   ├── claude-progress.md
│   │   │   └── AGENTS.md
│   │   ├── install.sh            # Claude Code 特定安装
│   │   └── adapter.conf          # 适配器元数据
│   │
│   └── codex/
│       ├── hooks/
│       ├── templates/
│       ├── install.sh
│       └── adapter.conf
│
├── templates/                    # 共享项目模板（平台无关）
│   ├── feature_list.json
│   ├── .harness/
│   │   ├── config.schema.json
│   │   ├── config.json.node.example
│   │   ├── config.json.python.example
│   │   └── config.json.generic.example
│   ├── init.sh                   # 通用版（参数化工具链）
│   └── AGENTS.md                 # 通用 agent 操作手册
│
├── tests/                        # 核心测试 + 适配器测试
│   ├── core/
│   └── adapters/
│       ├── claude-code/
│       └── codex/
│
└── shared/                       # 跨适配器共享定义
    └── harness-protocol.json     # Agent-platform 交互协议定义
```

**harness-protocol.json**：定义 agent 平台需要实现的接口
```json
{
  "protocol_version": 1,
  "capabilities": {
    "hooks": {
      "session_start": { "input": "stdin JSON", "output": "stdout JSON" },
      "session_stop": { "input": "stdin JSON", "output": "stdout JSON" }
    },
    "commands": {
      "format": "slash_command | tool_call | native",
      "namespaces": ["harness"]
    },
    "context_injection": {
      "method": "additionalContext | systemMessage | file_reference"
    }
  }
}
```

**adapter.conf 格式**（每个 adapter 必须提供）：
```
name=claude-code
protocol_version=1
knowledge_entry=CLAUDE.md
agent_entry=AGENTS.md
progress_file=claude-progress.md
history_enabled=true
```

**跨平台运行方式**：
- 核心脚本 (`core/`) 通过环境变量获知当前平台和文件映射：
  - `HARNESS_PLATFORM` — 当前平台名称
  - `HARNESS_KNOWLEDGE_ENTRY` — 知识入口文件名（默认 `AGENTS.md`）
  - `HARNESS_PROGRESS_FILE` — progress 文件名（默认 `progress.md`）
  - `HARNESS_CONFIG_DIR` — 配置目录（默认 `.harness`）
  - `HARNESS_FEATURE_FILE` — feature 文件名（默认 `feature_list.json`）
- 平台特定 hook 脚本设置这些环境变量后调用核心脚本
- 平台特定文件（`CLAUDE.md` vs Codex 的对应物）由 adapter 的 `templates/` 提供

**配置、状态、evidence 共享**：
- evidence 格式完全共享（JSON schema 在 `core/` 中定义）
- `feature_list.json` 共享
- `.harness/config.json` 不再包含平台特定字段
- 运行时目录：`~/.harness-companion/`（平台无关）

**优点**：
- 核心与平台彻底分离，添加新平台只需写 adapter
- 不会出现机械字符串替换的问题（adapter 独立维护，非代码生成）
- evidence 格式和 passing 规则由核心统一管理，不会版本漂移
- 核心逻辑可以独立测试和升级

**代价**：
- 重构工作量适中（~4-6 周）
- 核心/adapter 间的接口需要仔细设计
- 当前 ~1800 行 bash 代码需要重组织

**主要风险**：中低。接口设计如果过重会增加维护成本，但两个 adapter 足以验证接口的合理性。

---

### 3.3 方案 C：Harness Protocol Standard（协议标准）

**核心思路**：不只做一个工具，而是定义一个类似 LSP 的 "Harness Engineering Protocol"（HEP）。harness-companion 是协议的参考实现。任何 agent 平台实现 HEP 客户端即可获得所有 harness 能力。

**目录结构**：

```
harness-engineering/
├── hep-spec/                     # 协议规范（独立仓库）
│   ├── HEP.md                    # 协议核心规范
│   ├── hep-schema.json           # 所有消息的 JSON Schema
│   └── conformance-tests/        # 协议一致性测试
│
├── harness-companion/            # HEP 参考实现
│   ├── hep-server/              # 轻量服务器（stdio 或 localhost HTTP）
│   └── hep-cli/                 # CLI 工具（fallback）
│
└── platform-plugins/            # 平台插件
    ├── claude-code-plugin/
    └── codex-plugin/
```

**跨平台运行方式**：
- HEP server 通过 stdio 或 localhost HTTP 提供服务
- Agent 平台的 hook system 调用 HEP client → HEP server
- HEP server 处理所有核心逻辑（状态机、evidence、passing、audit）

**优点**：
- 最大程度的平台独立性
- 协议版本管理正式化
- 一致性测试确保所有平台行为一致
- 其他 agent 平台可以独立实现 HEP 客户端

**代价**：
- 工作量极大（协议设计 + 参考实现 + 2 个平台插件 = 至少 2-3 个月）
- Server 进程管理增加运维复杂度
- 过度设计风险高——当前只有 2 个目标平台
- bash 作为 server 实现语言不理想，需要引入 Node 或 Python 运行时依赖

**主要风险**：**极高**。LSP 花了 5 年才成熟。HEP 在只有 2 个平台时设计协议标准会导致过度抽象、错误抽象，并且需要多次破坏性协议变更才能收敛。

---

## 4. 推荐方案及理由

### 推荐：方案 B — Core/Adapter Architecture

#### 4.1 为什么不是方案 A？

方案 A 看似"最安全"，但它回避了核心问题：**平台专属文件伪装成通用核心**。方案 A 的 `.harness/config.json` 会变成一个"什么都能配"的大配置文件，每增加一个平台就要在核心脚本中加 case 分支。这正是用户说的 "不得用名称全局替换生成其他平台版本" 试图防止的模式。

#### 4.2 为什么不是方案 C？

方案 C 在只有 2 个目标平台时是严重过度设计。协议标准化需要至少 4-5 个异构实现才能收敛出正确的抽象。现在定义 HEP 会导致：
- 错误的抽象（因为没有足够的 diversity 来验证）
- 沉重的维护负担（server 进程管理、协议版本协商、向后兼容）
- bash 作为 server 的尴尬（或者引入新的运行时依赖，违反 bash-only 原则）

#### 4.3 方案 B 为什么正确？

方案 B 的核心洞察是：**v1.1.2 已经实现了正确的核心逻辑**（状态机、evidence、passing、原子写入、fail-closed），只是这些逻辑被包裹在 Claude Code 特定的文件命名、路径约定和 hook 协议中。方案 B 的工作主要是**分离**而非**重写**。

方案 B 的三个关键设计决策：

1. **Adapter 是独立维护的，不是代码生成的**。Claude Code adapter 和 Codex adapter 各自独立演进自己的模板和 hook，不会出现 "先写 Claude 版本，然后 `sed s/Claude/Codex/` 生成 Codex 版本" 的问题。

2. **核心脚本通过环境变量而非配置文件找到 adapter 的文件映射**。`harness-status.sh` 不读配置文件来知道 "progress 文件名是什么"，而是由 adapter 的 hook 在启动时通过环境变量注入。这意味着添加平台不需要修改核心脚本的任何一行。

3. **Adapter 是薄的**。一个 adapter 包含：
   - 平台特定的文件模板（2-4 个 markdown 文件）
   - 平台特定的 hook 脚本（2 个）
   - `adapter.conf`（~10 行元数据）
   - 安装脚本

#### 4.4 关键实现约束

从 v1.1.2 继承并强化的约束：

| 约束 | 实现方式 |
|------|---------|
| 平台专属文件不被伪装成通用核心 | Claude-specific 的 `CLAUDE.md` 模板只在 `adapters/claude-code/templates/` 中 |
| 不得用名称全局替换生成其他平台版本 | 各 adapter 独立维护，不共享 commit history |
| 缺失能力必须明确报告，不能伪造成功 | 保持 fail-closed（exit 2），adapter 缺失时报告具体缺失项 |
| passing 必须基于最新完整验证证据 | 保持 `is_eligible_for_passing` 的最新-run-only 语义 |
| 原子写入、结构化 evidence、run_id 和 fail-closed 行为 | 完全保留，代码直接迁移到 `core/lib/` |
| 文档承诺必须有测试支撑 | 每个 adapter 独立测试，核心有回归测试 |
| 不为"通用"一次性支持所有可能平台 | 只做 Claude Code + Codex，第 3 个平台由需求驱动 |
| 不先写大量代码再解释架构 | v1.1.2 核心逻辑直接迁移，核心脚本改动以重组织为主 |

---

## 5. 分阶段迁移计划

### 阶段 0：冻结 + 基线（预估：1 周）

**目标**：保护 v1 用户，建立开发基线。

- [ ] v1.1.2 代码冻结（当前 `.claude/skills/harness-companion/` 作为 v1 基线，标记 git tag `v1.1.2-frozen`）
- [ ] v2 开发分支创建（`feat/harness-companion-v2`）
- [ ] v1→v2 evidence 兼容性测试矩阵建立
- [ ] 当前全局安装版保持不变，确保用户工作不受影响
- [ ] CI 配置：v1 测试套件在 v1 分支持续运行

**不覆盖用户文件**：v1 全局安装版和项目级 harness 文件不受任何影响。

### 阶段 1：核心提取（预估：2-3 周）

**目标**：从 v1.1.2 提取平台无关核心。

**具体任务**：

- [ ] 创建 `core/` 目录结构
- [ ] 从 v1.1.2 提取核心库，去除 Claude 特定引用：
  - `core/lib/state-machine.sh` — 从 `harness-feature.sh` 提取 `is_allowed_transition()` 和 transition table
  - `core/lib/evidence.sh` — 保持 `ev_build_record`, `ev_append`, `ev_is_stale`, `ev_git_commit`, `ev_git_tree_state`, `ev_file_sha256`
  - `core/lib/passing.sh` — 保持 `is_eligible_for_passing()` 和 `generate_run_id()`
  - `core/lib/atomic-write.sh` — 保持 `atomic_write()`, `atomic_write_json()`
  - `core/lib/json-helpers.sh` — 合并 `json_input.sh` + `harness_config.sh` 的通用部分
- [ ] 提取核心命令脚本，参数化文件路径引用为环境变量：
  - `core/harness-feature.sh` — 使用 `$HARNESS_FEATURE_FILE`, `$HARNESS_CONFIG_DIR`
  - `core/harness-verify.sh` — 使用 `$HARNESS_FEATURE_FILE`, `$HARNESS_CONFIG_DIR`
  - `core/harness-status.sh` — 使用 `$HARNESS_KNOWLEDGE_ENTRY`, `$HARNESS_PROGRESS_FILE`
  - `core/harness-audit.sh` — 使用 `$HARNESS_KNOWLEDGE_ENTRY`, `$HARNESS_PROGRESS_FILE`
- [ ] 核心脚本不再硬编码任何文件名（`CLAUDE.md` → 读取 `$HARNESS_KNOWLEDGE_ENTRY` 的值）
- [ ] 运行时目录从 `~/.claude/harness-companion/` 迁移到 `~/.harness-companion/`
- [ ] 核心测试套件迁移到 `tests/core/`，确保 v1 的 87 tests 等价覆盖

**验收标准**：核心测试全部通过，核心脚本中不含字符串 "Claude" 或 "Codex"（注释和文档字符串除外）。

### 阶段 2：Claude Code Adapter（预估：1-2 周）

**目标**：将 v1.1.2 的 Claude Code 特定部分提取为独立 adapter。

**具体任务**：

- [ ] 创建 `adapters/claude-code/` 目录
- [ ] 创建 `adapter.conf`：
  ```
  name=claude-code
  protocol_version=1
  knowledge_entry=CLAUDE.md
  agent_entry=AGENTS.md
  progress_file=claude-progress.md
  history_enabled=true
  ```
- [ ] 迁移现有 hooks：`session-start.sh`、`stop-handoff.sh`
  - Hook 脚本在内部设置环境变量（`HARNESS_PLATFORM=claude-code`, `HARNESS_KNOWLEDGE_ENTRY=CLAUDE.md` 等）后调用核心
- [ ] 迁移 Claude-specific 模板：`CLAUDE.md`、`claude-progress.md`、`AGENTS.md`
- [ ] 迁移 `install.sh`：注册 Claude Code hooks 到 `~/.claude/settings.json`
- [ ] Claude Code adapter 测试（`tests/adapters/claude-code/`）

**验收标准**：Claude Code adapter 测试全部通过，v1 项目的 behavior 完全保持。

### 阶段 3：Codex Adapter（预估：1-2 周）

**目标**：创建 Codex 平台适配器。

**具体任务**：

- [ ] 研究 Codex 的 hook/plugin 协议
- [ ] 创建 `adapters/codex/` 目录
- [ ] 编写 Codex 特定 hooks（输出格式符合 Codex 的 platform protocol）
- [ ] 编写 Codex 特定模板（知识入口文件、progress 文件按 Codex 约定命名）
- [ ] 创建 `adapter.conf`
- [ ] Codex adapter 测试
- [ ] 跨平台 evidence 兼容性验证：
  - Claude Code 写入的 evidence → Codex 正确读取和验证
  - Codex 写入的 evidence → Claude Code 正确读取和验证

**验收标准**：Codex adapter 测试全部通过，跨平台 evidence 兼容性验证通过。

**防止机械字符串替换**：Codex adapter 的每个文件都是**独立编写**的，不经过任何 `sed s/Claude/Codex/` 转换。通过 CI 检查确保 adapter 间没有相同的文件 hash。

### 阶段 4：迁移工具 + 文档（预估：1 周）

**目标**：为用户提供平滑的 v1→v2 迁移路径。

**具体任务**：

- [ ] `v1-to-v2-migrate.sh`：检测现有 v1 项目，迁移到 v2 结构
  - 不覆盖用户已有的 `feature_list.json`、`AGENTS.md` 等
  - 不破坏旧 evidence（只添加 `run_id` 如果缺失，不删除字段）
  - 备份每个被修改的文件到 `.harness/backups/v1/`
  - 打印清晰的变更报告
- [ ] `v2-to-v1-rollback.sh`：从备份恢复 v1 状态
- [ ] 更新 `MIGRATION.md`（v1→v2 迁移指南）
- [ ] 更新 `README.md`、`README.zh-CN.md`、`SKILL.md`
- [ ] 更新 `install.sh`（支持 `--platform claude-code|codex --user|--project`）

**验收标准**：迁移脚本在 `migration.test.sh` 的全量 fixture 上运行，所有 fixture 迁移后核心测试通过。

### 阶段 5：验证 + 发布（预估：1 周）

**目标**：全面验证后正式发布。

- [ ] 完整的跨平台验证（见第 6 部分验证矩阵）
- [ ] Release checklist 逐项确认
- [ ] 全局安装版在 v2 验证完成前保持 v1.1.2（用户不受影响）
- [ ] 发布 v2.0.0，标记 git tag
- [ ] 安装指南更新

---

## 6. 验证方法设计

### 6.1 Agent 平台语义正确性

```
测试文件：tests/adapters/platform-semantics.test.sh

测试用例：
  - 断言 Claude Code adapter 模板包含 CLAUDE.md（不是 CODEX.md 或 codex.md）
  - 断言 Codex adapter 模板包含 Codex 约定的文件（不是 CLAUDE.md）
  - 断言核心脚本不包含字符串 "Claude" 或 "Codex"（注释和文档字符串除外）
  - 断言 adapter A 的模板不包含对方平台的品牌字符串

测试文件：tests/adapters/no-mechanical-replacement.test.sh

测试用例：
  - 检查 git diff：adapter 的模板文件之间没有相同的文件 hash
  - 检查 git log：没有 "s/Claude/Codex/" 或 "s/claude/codex/" 类型的 commit message
  - 断言每个 adapter 模板文件有独立的 git history（不是从另一个 adapter 复制而来）
```

### 6.2 操作系统差异

```
测试文件：tests/core/os-compatibility.test.sh

测试矩阵：
  - Linux (Ubuntu):    bash 5.x, GNU coreutils
  - macOS:             bash 3.2+ (注意 bash 版本差异), BSD stat, BSD mktemp
  - Windows Git Bash:  MSYS2 bash, cygpath -m 路径转换
  - Windows WSL:       Ubuntu bash（行为应与 Linux 一致）

关键差异点覆盖：
  - stat -c %Y (Linux) vs stat -f %m (macOS) — 在 atomic_write.sh 和 status.sh 中
  - mktemp 模板语法 — Linux 支持后缀 X，macOS 必须在末尾
  - date -u 可用性 — macOS 的 date 不支持 -u 的某些格式组合
  - sha256sum vs shasum -a 256 — Linux 有 sha256sum，macOS 只有 shasum
  - /tmp vs TMPDIR — macOS 的 TMPDIR 是 per-user 的
  - cygpath -m 路径转换 — 仅 Windows Git Bash
  - 路径分隔符 — 核心脚本统一使用 `/`（POSIX），Windows adapter 负责转换
```

### 6.3 项目类型

```
测试文件：tests/core/project-types.test.sh

测试场景：
  - Node/TypeScript 项目（package.json 存在，含 scripts 字段）
  - Python 项目（pyproject.toml 或 requirements.txt 存在）
  - Generic 项目（无特定工具链标记文件）
  - 混合项目（monorepo: 同时有 package.json 和 pyproject.toml）

每个场景验证：
  - verify 命令选择正确（applies_when 谓词工作）
  - init.sh 模板生成正确的工具链命令
  - config.json 示例被正确选择
```

### 6.4 VCS 场景

```
测试文件：tests/core/vcs-scenarios.test.sh

测试场景：
  - Git 仓库（clean working tree）
  - Git 仓库（dirty working tree — 有未提交的修改）
  - 非 Git 目录（evidence.commit = null）
  - Git 仓库但 HEAD 已移动（stale evidence 检测）
  - Git 仓库在子目录中（非项目根目录）

验证：
  - evidence.commit = null 在非 git 场景
  - working_tree_state = "no_git" / "clean" / "dirty"
  - stale check 在非 git 场景返回 false（不能决定 staleness → 不阻塞）
  - 非 git 项目的 passing eligibility 跳过 commit-match 检查
```

### 6.5 Agent 并发

```
测试文件：tests/core/concurrency.test.sh

测试场景：
  - 两个 agent 同时运行 verify --write（相同 feature）
  - 两个 agent 同时更新不同 feature 的 status
  - 两个 agent 同时更新同一 feature 的 status

验证：
  - 原子写入无 race condition（feature_list.json 不截断）
  - run_id 唯一性（不同 agent 进程的 run_id 不冲突）
  - 最终状态一致（不是损坏的 JSON）
  - 测试工具：使用后台 bash 进程（&）模拟并发，用 wait 收集结果
```

### 6.6 安装、升级、回滚和完整性

```
测试文件：tests/lifecycle/install-upgrade-rollback.test.sh

安装场景：
  - 全新安装 v2（无 v1 环境）
  - v2 安装到已有 v1 全局安装的环境（不覆盖、不冲突）
  - --user vs --project 模式
  - install-receipt.json 的 SHA-256 验证（所有已安装文件 hash 匹配）

升级场景：
  - v1 项目通过 migrate.sh 升级到 v2
  - 升级后 feature_list.json 结构正确
  - v1 evidence 在 v2 下可读、可通过 passing eligibility 检查
  - v1 feature_list.json 在 v2 下正常工作（状态机不变）

回滚场景：
  - v2→v1 回滚脚本恢复原始状态
  - 回滚后 v1 测试套件通过
  - 回滚不留下 v2 残留文件

完整性：
  - install-receipt.json 的 SHA-256 验证
  - 所有 adapter 文件在安装后 hash 匹配
  - 核心文件不被 adapter 安装覆盖
```

### 6.7 完整验证矩阵

| 维度 | 变量 | 测试文件 | 最低通过标准 |
|------|------|---------|------------|
| Agent 平台 | Claude Code, Codex | `tests/adapters/platform-*.test.sh` | 2 个平台全部通过 |
| OS | Linux (Ubuntu), macOS, Windows (Git Bash, WSL) | `tests/core/os-*.test.sh` | 至少 2 个 OS 通过（CI 限制） |
| 项目类型 | Node, Python, Generic | `tests/core/project-types.test.sh` | 3 个类型全部通过 |
| VCS | Git (clean/dirty), no-VCS | `tests/core/vcs-scenarios.test.sh` | 3 个场景全部通过 |
| 工作模式 | feature-driven, continuous | `tests/core/work-modes.test.sh` | 2 个模式全部通过 |
| 并发 | 单 agent, 双 agent 同时写 | `tests/core/concurrency.test.sh` | 无 race condition |
| 生命周期 | 安装, 升级, 回滚, 完整性 | `tests/lifecycle/*.test.sh` | 4 个场景全部通过 |

**CI 策略**：
- Linux (Ubuntu) 上运行完整测试套件（所有维度）
- macOS 和 Windows 上运行核心 + OS 兼容性测试
- 每个 PR 运行：核心测试 + 受影响的 adapter 测试
- 发布前：完整验证矩阵（手动或 CI 全矩阵）

---

## 7. 风险和待决策问题

### 7.1 需要您确认的设计决策

**决策 1：Agent 平台范围**

方案 B 假设只支持 Claude Code + Codex 两个平台。如果近期（6 个月内）可能加入第 3 个平台（如 GitHub Copilot Chat 或 Cursor），adapter 接口需要更正式的设计（如 `adapter.conf` 中定义更完整的 capability 声明）。

→ **请确认：v2 目标平台是 Claude Code + Codex 两个，第 3 个平台由需求驱动，不预先设计。**

**决策 2：最小 harness 文件的定义**

方案 B 中，核心的最小 harness 只有 `feature_list.json` + 一个知识入口文件（名称由 adapter 的 `knowledge_entry` 决定）。这意味着 `AGENTS.md` 和 `CLAUDE.md` 作为**两个独立文件**的要求会改变：
- Claude Code adapter：知识入口文件 = `CLAUDE.md`，agent 操作手册 = `AGENTS.md`（两个文件）
- Codex adapter：知识入口文件 = Codex 约定的文件名（可能只有一个文件）
- Generic / 非 agent 项目：知识入口文件 = `AGENTS.md`（一个文件）

→ **请确认：不再要求所有项目必须有 `AGENTS.md` + `CLAUDE.md` 两个文件。最小 harness 是 `feature_list.json` + 平台定义的知识入口文件。**

**决策 3：运行时依赖**

方案 B 保持纯 bash + jq 依赖，不引入 Node 或 Python 作为运行时。Python 只在 hook JSON 解析时作为 jq 的 fallback（保持 v1 行为）。

→ **请确认：v2 保持 bash + jq（+ python3 JSON fallback），不引入新的运行时依赖。**

**决策 4：运行时目录路径**

运行时目录从 `~/.claude/harness-companion/` 移出。候选路径：
- `~/.harness-companion/` — 简单直接，但与 XDG 不兼容
- `~/.config/harness-companion/`（Linux）、`~/Library/Application Support/harness-companion/`（macOS）— XDG 兼容但路径不一致
- 环境变量 `HARNESS_HOME`（默认 `~/.harness-companion/`）— 最灵活

→ **请确认：运行时目录策略。**

**决策 5：v1 与 v2 的共存策略**

阶段 0-4 期间：
- 用户使用 v1.1.2 的全局安装版（不变）
- 开发在 `feat/harness-companion-v2` 分支进行
- v2 发布时：是一次性替换 v1 全局安装版，还是并行安装（`harness-companion2`）？

→ **请确认：v2 发布后的安装策略。**

### 7.2 主要风险

| 风险 | 可能性 | 影响 | 缓解措施 |
|------|--------|------|---------|
| 核心/adapter 接口设计不充分，第 3 个平台接入时需要改动核心 | 中 | 中 | 先用 2 个 adapter 验证接口，明确文档说明"接口稳定但不承诺永久不变" |
| bash 版本差异导致跨 OS 行为不一致 | 中 | 中 | 核心库限制在 POSIX sh 子集，避免 bash 4+ 专有特性（关联数组等）。CI 上测试 bash 3.2 (macOS) 和 5.x (Linux) |
| v1→v2 迁移时破坏用户 evidence | 低 | 高 | 迁移脚本只有添加字段（`run_id`），不删除或重命名现有字段。迁移前自动备份 |
| adapter 模板独立维护导致两个 adapter 模板内容不一致 | 中 | 低 | 共享模板（如 `feature_list.json`）提取到 `templates/`。adapter 只维护平台专属模板。交叉 review |
| Windows native（无 Git Bash）用户无法使用 | 高 | 中 | 明确文档说明 Git Bash 或 WSL 是 Windows 上的前提条件。不接受"原生 cmd.exe 支持"作为需求 |
| 核心脚本的环境变量接口被 adapter 误用 | 低 | 中 | 核心脚本在启动时验证所有必需环境变量已设置，缺失时 exit 2 并报告具体缺失项 |

### 7.3 残余风险（v2 已知限制，tracked for v3）

| 限制 | 为什么 v2 不修 | v3 计划 |
|------|--------------|---------|
| 非 Git VCS 的 commit 跟踪 | 需求不明确，没有用户请求 | 如有需求：`evidence.commit` 抽象为 VCS adapter |
| 多语言 harness 文件内容 | 文档已多语言，harness 结构字段仍英文 | 如有需求：国际化 CLI 输出和状态消息 |
| CI/CD 插件 | 独立关注点 | 如有需求：GitHub Actions / GitLab CI 集成 |
| Windows PowerShell adapter | 开发成本高，WSL/Git Bash 覆盖 | 如有需求：PowerShell adapter（薄封装层调用 bash 核心） |

---

## 附录：文件变更摘要

### v1.1.2 → v2.0.0 文件迁移映射

| v1.1.2 路径 | v2.0.0 路径 | 说明 |
|------------|------------|------|
| `scripts/_lib/atomic_write.sh` | `core/lib/atomic-write.sh` | 迁移到核心，无改动 |
| `scripts/_lib/evidence.sh` | `core/lib/evidence.sh` | 迁移到核心，小改（移除 Claude-specific 日志路径） |
| `scripts/_lib/passing.sh` | `core/lib/passing.sh` | 迁移到核心，无改动 |
| `scripts/_lib/baseline.sh` | `core/lib/baseline.sh` | 迁移到核心，路径从 `~/.claude/` 改为 `~/.harness-companion/` |
| `scripts/_lib/json_input.sh` | `core/lib/json-helpers.sh` | 合并 `harness_config.sh` 的通用部分 |
| `scripts/harness-feature.sh` | `core/harness-feature.sh` | 参数化文件引用 |
| `scripts/harness-verify.sh` | `core/harness-verify.sh` | 参数化文件引用 |
| `scripts/harness-status.sh` | `core/harness-status.sh` | 参数化文件引用 |
| `scripts/harness-audit.sh` | `core/harness-audit.sh` | 参数化文件引用 |
| `scripts/hooks/session-start.sh` | `adapters/claude-code/hooks/session-start.sh` | 移至 adapter |
| `scripts/hooks/stop-handoff.sh` | `adapters/claude-code/hooks/stop-handoff.sh` | 移至 adapter |
| `templates/CLAUDE.md` | `adapters/claude-code/templates/CLAUDE.md` | 移至 adapter |
| `templates/claude-progress.md` | `adapters/claude-code/templates/claude-progress.md` | 移至 adapter |
| `templates/AGENTS.md` | `templates/AGENTS.md` + `adapters/claude-code/templates/AGENTS.md` | 通用模板内容 + Claude-specific 定制 |
| `templates/init.sh` | `templates/init.sh` | 参数化工具链引用 |
| `templates/feature_list.json` | `templates/feature_list.json` | 格式不变 |
| `templates/.harness/*` | `templates/.harness/*` | 格式不变 |
| `install.sh` | `adapters/claude-code/install.sh` + `install.sh`（根级） | 根级 install.sh 委托给 adapter |
| `references/*` | `references/*` | 更新引用，移除 Claude-specific 示例 |
| `tests/*` | `tests/core/*` + `tests/adapters/*` | 重组，新增 adapter 测试 |
| — | `adapters/codex/` | 全新 |
| — | `shared/harness-protocol.json` | 全新 |
| — | `v1-to-v2-migrate.sh` | 全新 |
| — | `v2-to-v1-rollback.sh` | 全新 |

---

> **审批状态**：等待用户审阅第 7.1 节的 5 个决策点。
>
> 确认后将进入详细实现计划（通过 `superpowers:writing-plans` skill）。

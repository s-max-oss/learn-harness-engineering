# harness-companion 通用化升级 — 方案设计（修订稿 v2）

> 状态: **等待审批** | 日期: 2026-07-31 | 修订: v2  
> 上一版: v1 (已撤回) | 变更摘要见附录 A

---

## 变更摘要（v1 → v2）

| 修订点 | v1 问题 | v2 修正 |
|--------|---------|---------|
| 1. Windows 范围 | 前后矛盾：同时出现 "Windows（含 Git Bash 和 WSL）" 和 "PowerShell 薄适配层" | 明确只支持 Git Bash / WSL；删除 PowerShell 相关内容 |
| 2. 语义 core vs runtime | core 定义混入了 jq/mktemp/mv 等实现细节 | 区分 immutable contracts 和 replaceable runtime |
| 3. 最小 harness | 强制 feature_list.json + 知识入口文件 | capability-based：work-item registry 按模式启用 |
| 4. Adapter 维护 | 以 hash 不同、独立 git history 证明非机械替换 | adapter manifest + semantic/golden tests 验证平台差异；允许复用 |
| 5. harness-protocol.json | 预先设计了机器可读协议 | 删除；改用最小 adapter contract；说明升级条件 |
| 6. Codex 能力 | 预设 Codex 有 SessionStart/Stop hooks（与 Claude 相同） | 基于调研确认：Codex 有类似 hooks 但实现不同（Node.js）；增加降级方案 |
| 7. 并发一致性 | 仅提到原子写入，未处理 lost update | 三个方案比较（flock / CAS / append-only log），推荐 CAS + evidence log |
| 8. Evidence 迁移 | 暗示可为历史 evidence 推断 run_id | 明确禁止；legacy 标记为 `run_id: null`，重新验证后才生成 |
| 9. 测试基线 | 写为 ~83 tests | 更正为 90 passed, 0 failed, 0 skipped, 0 deferred |
| 10. 决策点 | 5 个决策点混入可自行调研的技术问题 | 精简为 2 个真正需要用户决定的产品取舍 |

已解决的矛盾：Windows PowerShell 提及、AGENTS.md+CLAUDE.md 双文件强制、harness-protocol.json 过度设计、hash 验证 adapter 独立性。

仍为假设、尚未验证的内容：见附录 B。

---

## 目录

1. [对现状的批判性分析](#1-对现状的批判性分析)
2. [语义核心与可替换运行时](#2-语义核心与可替换运行时)
3. ["通用"的合理边界](#3-通用的合理边界)
4. [备选架构方案](#4-备选架构方案)
5. [推荐方案：Core/Adapter Architecture](#5-推荐方案-coreadapter-architecture)
6. [并发一致性设计](#6-并发一致性设计)
7. [分阶段迁移计划](#7-分阶段迁移计划)
8. [验证方法设计](#8-验证方法设计)
9. [风险和待决策问题](#9-风险和待决策问题)
10. [附录](#10-附录)

---

## 1. 对现状的批判性分析

v1.1.2 基线: **90 passed, 0 failed, 0 skipped, 0 deferred**（当前实测）。

### 1.1 第 1 类：语义核心 — 不可变的 Harness Engineering 原则

这些是**改变即破坏 correctness** 的规则。无论 runtime 是 bash+jq 还是 Node.js+SQLite，这些 contract 必须保持不变：

| 原则 | 当前实现 | 核心语义 | 是否可改变实现 |
|------|---------|---------|--------------|
| **结构化 evidence** | jq 构建 JSON 对象 | 每条 evidence 必须有 `{id, exit_code, started_at, commit, run_id}` 字段。字段是 required 还是 optional 由 schema 定义 | ✅ 可以用任何 JSON 库构建 |
| **run_id 分组** | `date -u +%Y%m%dT%H%M%SZ`-`$$`-`$RANDOM` | 唯一标识一次 verify 调用。append-only 数组位置判定时序 | ✅ 可以用任何唯一 ID 生成器 |
| **latest-run-only passing** | `is_eligible_for_passing()` 取数组最后一个 structured record 的 run_id | 不允许跨 run 拼凑 evidence。只计算最新完整 run | ✅ 实现可换，策略不可变 |
| **fail-closed** | exit 2 on missing config/jq，exit 1 on real failures | 不确定 → 失败。不伪造成功。不静默降级 | ✅ 实现可换，行为不可变 |
| **状态机 transitions** | `is_allowed_transition()` 的 case 匹配 | 显式 transition table。未列出的边一律拒绝 | ✅ 实现可换，table 内容可演进 |
| **原子写入** | mktemp + mv | 写入要么全部成功，要么完全不发生。不截断 | ✅ 实现可换（rename(2)、WAL 等） |
| **override 审计** | `build_override_record()` → feature.override 字段 | 每次 bypass 记录 `{by, at, reason, missing_evidence[]}` | ✅ 实现可换，字段不可变 |
| **hook fail-open** | trap ERR → `{"continue":true}` | hook 失败绝不阻塞 agent session | ✅ 实现可换 |
| **dry-run 默认** | `--write` flag | 不传 `--write` 不修改任何文件 | ✅ 实现可换 |
| **完整性验证** | install-receipt.json SHA-256 | 已安装文件可验证 | ✅ hash 算法和验证方式可换 |

### 1.2 第 2 类：可替换的 Runtime 实现细节

这些是**当前实现方式，不是语义**。替换 runtime 时，这些可以全部改变，只保持第 1 类的 contract 不变：

| 当前实现 | 所属层 | 替换为其他 runtime 时 |
|----------|--------|---------------------|
| bash 4+ | Runtime shell | Node.js、Python、编译型均可 |
| jq | JSON 处理 | 任何 JSON 库（Python json、Node.js JSON、jq 的不同版本） |
| mktemp + mv | 原子写入 | rename(2)、SQLite WAL、LMDB 事务 |
| date +%Y%m%dT%H%M%SZ | run_id 时间戳 | Date.now()、process.hrtime()、UUID v7 |
| sha256sum/shasum | 文件 hash | crypto.createHash('sha256')、hashlib.sha256 |
| cygpath -m | Windows 路径 | Node.js path 模块、Python pathlib |
| `~/.harness-companion/` | 运行时目录 | XDG_DATA_HOME、%APPDATA%、任意可配路径 |
| stat -c %Y / stat -f %m | 文件 mtime | fs.statSync().mtimeMs、os.path.getmtime |
| printf '%s' + grep + sed | 字符串处理 | 任何语言的字符串库 |

### 1.3 第 3 类：来自课程示例、但不应成为普遍要求的实现细节

（与 v1 相同，此处从略。完整列表见 v1 设计稿第 1.3 节。关键结论：7 子系统分类、Git commit freshness、npm 工具链、Electron 架构、agent.log 格式均为课程示例，不应普遍化。）

### 1.4 已知的机械替换事故（来自 `.agents/` 目录）

`.agents/skills/harness-companion/SKILL.md` 揭示了典型的机械替换故障：

```diff
- 最小 harness: AGENTS.md + CLAUDE.md + feature_list.json + init.sh
+ 最小 harness: AGENTS.md + AGENTS.md + feature_list.json + init.sh     ← 重复！

- progress 文件: claude-progress.md
+ progress 文件: Codex-progress.md

- hooks 配置路径: ~/.claude/settings.json
+ hooks 配置路径: ~/.Codex/settings.json
  ← 双重错误：① Codex 配置是 config.toml (TOML)，不是 settings.json (JSON)
                 ② 路径前缀是 ~/.codex/，不是 ~/.Codex/
```

这是 `sed s/CLAUDE/AGENTS/g` + `sed s/claude/Codex/g` 的结果。第三行暴露了更深的问题：**它假设 Claude Code 的文件格式（JSON settings.json）在 Codex 中也一样**——但实际上 Codex 的 hook 配置在 `~/.codex/config.toml` 中用 `[[hooks]]` TOML 块。机械替换无法捕获这种格式级差异。

该 `.agents/` 副本同时丢失了所有 v1 特性（状态机、结构化 evidence、config-driven verify、5-axis audit、`_lib/`、测试套件），且 SKILL.md 只有 218 行 vs `.claude/` 版本的 272 行。这是 v2 必须防止的模式。

---

## 2. 语义核心与可替换运行时

### 2.1 分层模型

```
┌──────────────────────────────────────────────┐
│              Adapter Layer                     │
│  (platform hooks, templates, install logic)    │
│  Claude Code: bash hooks → ~/.claude/          │
│  Codex:       Node.js hooks → .codex-plugin/   │
├──────────────────────────────────────────────┤
│              Core Semantics (immutable)         │
│  - State machine transitions                   │
│  - Passing eligibility (latest-run-only)       │
│  - Evidence record schema                      │
│  - Fail-closed error semantics                 │
│  - Override audit record format                │
├──────────────────────────────────────────────┤
│              Core Runtime (replaceable)         │
│  - Shell: bash (current)                       │
│  - JSON: jq (current)                          │
│  - Atomic write: mktemp+mv (current)           │
│  - Unique ID: date+PID+RANDOM (current)        │
│  - File hash: sha256sum/shasum (current)       │
│  - Time: date -u / date +%s (current)          │
│  - Path normalization: cygpath/sed (current)   │
└──────────────────────────────────────────────┘
```

### 2.2 替换 Runtime 时保持不变的 Contract

如果将来用 Node.js 替换 bash+runtime，以下 contract 不会变：

1. **Evidence schema**：JSON 对象的字段名、类型、required/optional 标记
2. **State machine**：状态集合和合法 transition 集合
3. **Passing eligibility**：latest-run-only、all-exit-zero、full-coverage、HEAD-match（git 时）
4. **Exit codes**：0 = pass, 1 = fail, 2 = not_configured, 3 = stale
5. **`feature_list.json` 结构**：顶层 `features[]` 数组，每个 feature 有 `id, status, evidence[], override?`
6. **`.harness/config.json` schema**：verification.commands[] 结构和 applies_when 语义
7. **Override audit**：`{by, at, reason, missing_evidence[]}` 格式

### 2.3 替换 Runtime 时会改变的内容

1. **实现语言**：bash → Node.js / Python / Rust
2. **依赖**：jq → 内置 JSON（`JSON.parse`/`JSON.stringify` 或 `json` 标准库）
3. **原子写入**：mktemp+mv → 平台原生 API（如 Node.js `writeFileSync(tmp) + renameSync`）
4. **并发控制**：取决于选择的方案（见第 6 节）
5. **安装方式**：`git clone + bash install.sh` → npm/pip/brew package
6. **平台 hook 格式**：CLI hook 输出格式跟随平台

---

## 3. "通用"的合理边界

### 3.1 应支持

| 维度 | v2 目标 |
|------|---------|
| **Agent 平台** | Claude Code、Codex（各含 hook 模式和显式工作流模式） |
| **操作系统** | Linux（bash 5.x）、macOS（bash 3.2+）、Windows（Git Bash / WSL） |
| **Shell** | bash（POSIX sh 子集）。**不支持** Windows cmd.exe/PowerShell 作为主 shell |
| **项目类型** | Node/TypeScript、Python、generic |
| **VCS** | Git、无 VCS |
| **工作模式** | feature-driven（WIP-tracked）、task-driven（多并发）、continuous（无 registry） |
| **Agent 数量** | 单 agent、多 agent 并发 |

### 3.2 Windows 范围（已解决矛盾）

**v2 只支持：**
- **Windows Git Bash**（MSYS2 bash，作为 Claude Code / Codex 的终端环境）
- **Windows WSL**（作为完整的 Linux 开发环境）

**不支持：**
- Windows cmd.exe
- Windows PowerShell（5.x 或 7.x）
- 不带 Git Bash 的 Windows native 环境

**理由：**
1. 核心 runtime 是 bash+jq，这两个在 Git Bash 和 WSL 上可用
2. cmd.exe/PowerShell 不支持 POSIX shell 脚本，需要完全重写核心
3. Codex 在 Windows sandbox 环境下 hooks 可能不可靠（见 web 调研证据）——这不是我们的问题，是 Codex 平台的问题
4. Git Bash 在 Windows 上已是标准开发工具（与 Git for Windows 一起安装）

**文档承诺**：README 中明确列出前提条件：`bash 3.2+, jq 1.6+, git 2.0+（可选）`。Windows 用户需通过 Git Bash 或 WSL 运行。

### 3.3 不支持（明确排除）

（与 v1 相同，补充一项：）

| 排除项 | 理由 |
|--------|------|
| Windows cmd.exe / PowerShell native | bash 依赖不可移除。Git Bash / WSL 是前提条件 |

### 3.4 避免过度复杂化

（与 v1 相同，4 条策略不变。）

---

## 4. 备选架构方案

### 4.1 方案 A：最小参数化

（概要同 v1。核心问题未解决：平台专属文件仍在核心中，通过配置文件选择；无法防止机械替换。）

**结论**：不推荐。

### 4.2 方案 B：Core/Adapter Architecture（修订）

**核心变化**（与 v1 方案 B 的差异）：

1. **删除了 `harness-protocol.json`**：两个 adapter 不需要机器可读协议。Adapter 通过 `adapter.conf` 声明能力，通过 semantic tests 验证行为。

2. **Codex adapter 基于真实调研**：
   - Codex 有 SessionStart/Stop/UserPromptSubmit/PreToolUse/PostToolUse/PreCompact hooks
   - Codex hook 脚本官方格式是 **Node.js（`.mjs`/`.js`）**，不是 bash
   - Codex 注入 `CLAUDE_PLUGIN_ROOT` 环境变量以兼容 Claude Code 插件
   - 部分 Codex 插件（如 agents-deck）采用 **hookless 模式**（tail 日志文件），在 Windows sandbox 中更可靠
   - **结论**：Codex adapter 需要同时支持两种模式——Node.js hook 模式（主路径）和显式工作流模式（hookless 降级）

3. **并发控制**：补充了完整的并发一致性设计（见第 6 节）。

4. **Evidence 迁移**：明确禁止伪造 run_id（见第 5.4 节）。

**目录结构（修订）**：

```
harness-companion/
├── core/                         # 语义核心 + bash runtime
│   ├── lib/
│   │   ├── state-machine.sh      # 状态机（纯逻辑，无平台依赖）
│   │   ├── evidence.sh           # evidence 构建 + staleness 检查
│   │   ├── passing.sh            # passing eligibility 策略
│   │   ├── atomic-write.sh       # mktemp+mv 原子写入
│   │   ├── json-helpers.sh       # jq 封装（JSON 解析/构建）
│   │   └── concurrency.sh        # [新增] CAS + 锁 并发控制
│   ├── harness-feature.sh        # feature CRUD（通过环境变量获取文件名）
│   ├── harness-verify.sh         # config-driven 验证链
│   ├── harness-status.sh         # 健康面板
│   └── harness-audit.sh          # 审计
│
├── adapters/
│   ├── claude-code/
│   │   ├── hooks/                # bash hooks（来自 v1.1.2）
│   │   │   ├── session-start.sh
│   │   │   └── stop-handoff.sh
│   │   ├── templates/            # Claude 特定模板
│   │   │   ├── CLAUDE.md
│   │   │   ├── AGENTS.md
│   │   │   └── claude-progress.md
│   │   ├── install.sh
│   │   └── adapter.conf
│   │
│   └── codex/
│       ├── hooks/                # Node.js hooks（Codex 官方格式）
│       │   ├── session-start.mjs
│       │   └── stop-handoff.mjs
│       ├── hooks-bash/           # bash hooks（通过 CLAUDE_PLUGIN_ROOT 兼容）
│       │   ├── session-start.sh
│       │   └── stop-handoff.sh
│       ├── templates/            # Codex 特定模板
│       │   ├── CODEX.md          # Codex 知识入口
│       │   ├── AGENTS.md
│       │   └── codex-progress.md
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
│   ├── init.sh
│   └── AGENTS.md                 # 通用 agent 操作手册
│
├── tests/
│   ├── core/                     # 核心语义测试
│   ├── adapters/                 # adapter 行为测试
│   │   ├── claude-code/
│   │   └── codex/
│   └── golden/                   # [新增] golden tests
│
└── VERSION
```

### 4.3 adapter.conf 格式（修订）

```
# adapter.conf — Adapter manifest
# 所有字段均为必需，除非标注 (optional)

name=codex
display_name=Codex OS
protocol_version=1

# ---- File mapping ----
knowledge_entry=CODEX.md
agent_entry=AGENTS.md
progress_file=codex-progress.md

# ---- Capability flags ----
# Codex supports ~10 hook events (research-confirmed):
# SessionStart, Stop, UserPromptSubmit, PreToolUse, PostToolUse,
# PreCompaction, Notification, Checkpoint, SubagentStart, SubagentStop
has_session_start_hook=true
has_stop_hook=true
has_user_prompt_submit_hook=true
has_pre_tool_use_hook=true
has_post_tool_use_hook=true
has_pre_compact_hook=true
has_notification_hook=true
has_checkpoint_hook=true
has_subagent_lifecycle_hooks=true

# ---- Hook implementation ----
hook_runtime=nodejs                  # nodejs | bash | both
hook_directory=hooks                 # relative to adapter root
# NOTE: Codex hooks are configured in config.toml (TOML format, NOT JSON settings.json)

# ---- Degradation mode (when hooks unavailable) ----
fallback_workflow=explicit           # explicit = user runs /harness:xxx manually
                                     # tail-log = read session logs (experimental)

# ---- Install target ----
install_config_path=~/.codex/config.toml         # hooks configured via [[hooks]] blocks in TOML
install_config_format=toml                        # toml (Codex) | json (Claude Code)
install_plugin_format=codex-plugin               # codex-plugin | claude-skill | manual
```

### 4.4 Adapter 维护策略（修订）

**v1 的错误思路**：通过检查 adapter 文件 hash 不同、git history 独立来"证明"非机械替换。这是把实现手段当成验证目标。

**v2 的正确思路**：

1. **允许复用**：adapter 之间可以共享逻辑片段、模板结构、测试用例。机械禁止复用会导致代码重复和 drift。
2. **验证非机械替换的方式**：
   - **Semantic tests**：每个 adapter 有专属的 golden test 断言其输出符合该平台的语义（如 "Codex adapter 的输出包含 `CODEX.md` 而非 `CLAUDE.md`"）
   - **Adapter manifest**：`adapter.conf` 声明该 adapter 的文件映射和能力集
   - **跨平台 evidence 兼容性测试**：Claude adapter 写入的 evidence 能被 Codex adapter 读取并正确评估 passing eligibility
3. **不要求的手段**：
   - ❌ 不检查文件 hash 是否相同
   - ❌ 不检查 git history 是否独立
   - ❌ 不禁止 adapter 间存在相同内容的文件（如果有意共享）

### 4.5 方案 C：Harness Protocol Standard

（同 v1，不推荐。两个 adapter 不需要协议标准。）

---

## 5. 推荐方案：Core/Adapter Architecture（修订）

### 5.1 最小 Harness 的重新定义

**v1 的错误**：最小 harness = 4 个固定文件（`AGENTS.md + CLAUDE.md + feature_list.json + init.sh`）。这把 courseware 示例提升为通用要求。

**v2 的定义**：Harness 能力分为三级，项目按需启用。

#### Level 0：Knowledge Only（无 registry）

**要求**：一个知识入口文件（名称由 adapter 决定）

```
项目根目录:
  CODEX.md    （或 CLAUDE.md）  ← 唯一必需文件
```

**适用场景**：
- 配置管理仓库
- 文档项目
- 研究/探索性项目
- 任何无需跟踪 work item 的项目

**可用功能**：`/harness:status`（仅报告文件存在性），`/harness:audit`（仅评分 Knowledge 子系统）

#### Level 1：Knowledge + Verification（无 feature tracking）

**要求**：Level 0 + `.harness/config.json` + 验证脚本

```
项目根目录:
  CODEX.md
  .harness/
    config.json          ← 验证命令定义
```

**适用场景**：
- 有 CI/CD 流水线、不需要细粒度 feature tracking 的项目
- task-driven 工作模式（多任务并发，无 WIP 限制）

**可用功能**：Level 0 + `/harness:verify`（不挂钩 feature status）

#### Level 2：Knowledge + Registry + Verification（完整 harness）

**要求**：Level 1 + `feature_list.json`

```
项目根目录:
  CODEX.md
  .harness/
    config.json
  feature_list.json      ← work-item registry
```

**适用场景**：
- feature-driven 工作模式
- 需要 WIP 跟踪、evidence 审计的项目

**可用功能**：完整 6 个命令

#### Level 3：完整 harness + 自动化（hooks + progress）

**要求**：Level 2 + progress 文件 + hooks 配置

**可用功能**：Level 2 + 自动 SessionStart 状态注入 + Stop 提醒

**总结**：

| 能力 | Level 0 | Level 1 | Level 2 | Level 3 |
|------|---------|---------|---------|---------|
| Knowledge 入口文件 | ✅ | ✅ | ✅ | ✅ |
| .harness/config.json | — | ✅ | ✅ | ✅ |
| feature_list.json | — | — | ✅ | ✅ |
| Progress 文件 | — | — | — | ✅ |
| Hooks 配置 | — | — | — | ✅ |
| `/harness:status` | ✅ (基础) | ✅ | ✅ | ✅ |
| `/harness:verify` | — | ✅ (无 feature) | ✅ | ✅ |
| `/harness:feature` | — | — | ✅ | ✅ |
| `/harness:audit` | ✅ (部分) | ✅ | ✅ | ✅ |
| SessionStart 自动注入 | — | — | — | ✅ |
| Stop 提醒 | — | — | — | ✅ |

### 5.2 Codex Adapter 设计（基于真实调研）

**调研来源**：web 搜索 + `.agents/` 目录分析

**确认的事实**：
- Codex 支持 ~10 个 hook 事件：`SessionStart`, `Stop`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `Notification`, `Checkpoint`, `SubagentStart`, `SubagentStop`
- Codex hook 脚本官方格式是 Node.js（`.mjs`/`.js`）
- Codex hook 配置在 `~/.codex/config.toml`（TOML 格式），使用 `[[hooks]]` 块 —— **不是** JSON `settings.json`
- Codex 注入 `CLAUDE_PLUGIN_ROOT` 环境变量以兼容 Claude Code 插件
- Codex 有 `.codex-plugin/plugin.json` 插件 manifest 格式
- Codex 使用 `AGENTS.md` 作为自定义指令文件（与 Claude Code 的 `CLAUDE.md` 等价）
- Codex hooks 在 Windows sandbox 环境下可能不可靠（已知问题）
- 部分插件采用 log-tail 降级方案

**Codex adapter 双模式设计**：

| 模式 | 适用条件 | Hook 脚本 | 安装方式 |
|------|---------|----------|---------|
| **Hook 模式**（主路径） | hooks 可用（Linux/macOS/非 sandbox Windows） | Node.js `.mjs`（调用核心 bash 脚本） | `.codex-plugin/` + `codex plugin install` |
| **显式工作流模式**（降级） | hooks 不可用（sandbox Windows、用户未配置） | 无自动 hooks | 仅安装核心脚本和模板，用户手动运行 `/harness:xxx` |

**Hook 模式的 Codex hook 脚本**（Node.js `.mjs`，非 bash）：

```javascript
// adapters/codex/hooks/session-start.mjs
import { execSync } from 'child_process';

// 调用核心 bash 脚本，获取 harness status
const status = execSync(
  `HARNESS_PLATFORM=codex \
   HARNESS_KNOWLEDGE_ENTRY=CODEX.md \
   HARNESS_PROGRESS_FILE=codex-progress.md \
   bash ${PLUGIN_ROOT}/core/harness-status.sh`,
  { encoding: 'utf-8' }
);

// 输出 Codex hook 协议格式
process.stdout.write(JSON.stringify({
  continue: true,
  hookSpecificOutput: {
    hookEventName: 'SessionStart',
    additionalContext: status
  }
}) + '\n');
```

**关键设计决策**：
- Codex Node.js hooks 是 ~20 行薄封装，设置环境变量后调用核心 bash 脚本
- 不将核心逻辑移植到 JavaScript——核心逻辑保持在 `core/` 中
- 如果 Codex 的 bash hook 兼容性（通过 `CLAUDE_PLUGIN_ROOT`）在目标环境中工作，也可以直接使用 bash hooks（`hooks-bash/`）

**Codex adapter 仍为假设的部分**（完整列表见附录 B）：
- Codex hook 输出的 exact JSON 字段名（`additionalContext` vs 其他命名）
- `config.toml` 中 `[[hooks]]` 块的 exact schema
- Codex bash hook 兼容性（`CLAUDE_PLUGIN_ROOT`）是否在最新版本中仍有效
- `.codex-plugin/plugin.json` 的完整 schema
- Codex Windows sandbox hook 不可靠的具体触发条件

### 5.3 Adapter Contract 替代 harness-protocol.json

**v1 的错误**：设计了 `harness-protocol.json` 作为机器可读协议。两个 adapter 不需要这个。

**v2 的方案**：最小 adapter contract 由以下组成：

1. **`adapter.conf`**（见 4.3 节）— 声明文件映射和能力标志
2. **环境变量接口**（核心 ↔ adapter）：
   - `HARNESS_PLATFORM` — adapter 名称
   - `HARNESS_KNOWLEDGE_ENTRY` — 知识入口文件名
   - `HARNESS_AGENT_ENTRY` — agent 操作手册文件名
   - `HARNESS_PROGRESS_FILE` — progress 文件名
   - `HARNESS_CONFIG_DIR` — 配置目录（默认 `.harness`）
   - `HARNESS_FEATURE_FILE` — feature registry 文件名（默认 `feature_list.json`）
   - `HARNESS_RUNTIME_DIR` — 运行时数据目录（默认 `~/.harness-companion`）
3. **Semantic tests** — 验证 adapter 行为

**升级为正式 capability schema 的条件**（不预先实现）：

- ≥ 3 个 adapter 需要互操作
- 出现 adapter 能力差异需要可编程检测（而非人工看 `adapter.conf`）
- 有第三方需要实现 adapter（不是我们维护）

### 5.4 Evidence 迁移策略（修订）

**v1 的错误**：暗示可以为 v0/v1 历史 evidence 推断或补造 `run_id`。

**v2 的规则**：

1. **历史 evidence 绝不伪造 run_id**。
   - v0 字符串 evidence → `run_id` 字段不存在 → 读取时视为 `run_id: null`
   - v1.1.0 之前的 structured evidence（无 `run_id` 字段）→ 读取时视为 `run_id: null`
   - `run_id: null` 的 evidence 记录**不参与** passing eligibility 计算
   
2. **`is_eligible_for_passing()` 处理 `run_id: null`**：
   - 取最后一个 `run_id` 非 null 的 structured record 作为最新 run
   - 如果所有 structured records 的 `run_id` 都是 null，视为 **replay_required**
   - `replay_required` 状态：不能标记 `passing`，exit 2（not_configured equivalent），stderr 输出 "Re-run /harness:verify to generate run_id-tagged evidence"

3. **合法性恢复**：
   - 只有重新运行 `/harness:verify --write` 才能生成带真实 `run_id` 的 evidence
   - 旧 evidence 保留在数组中（不删除），标记为 `run_id: null`，供审计查阅

4. **`harness-feature.sh status <id> passing`** 在面对 `replay_required` 时：
   - 拒绝 transition，输出 "This feature's evidence lacks run_id. Re-run /harness:verify --write first."
   - `--override` 路由到 `unverified`（保持现有行为）

---

## 6. 并发一致性设计

### 6.1 问题定义

`atomic_write_json`（mktemp + mv）保证**写入不截断文件**，但不保证**两个并发写入不互相覆盖**。

场景：
1. Agent A 读取 `feature_list.json`（状态：feature-1 = in_progress）
2. Agent B 读取 `feature_list.json`（状态：feature-1 = in_progress）
3. Agent A 将 feature-1 改为 passing，写入成功
4. Agent B 将 feature-2 改为 in_progress，写入成功
5. **Agent A 的修改被覆盖**，feature-1 回到 in_progress

### 6.2 方案比较

#### 方案 C1：Advisory File Locking（flock）

每个 mutation 在执行前获取排他锁，完成后释放。

```
lock_acquire .harness/feature_list.lock
  read feature_list.json
  modify in memory
  atomic_write feature_list.json
lock_release .harness/feature_list.lock
```

| 优点 | 缺点 |
|------|------|
| POSIX 标准，Linux/macOS/Git Bash 均支持 | 崩溃时锁可能残留（需要 stale lock 检测） |
| 实现简单（~20 行 bash） | 不适用于 NFS（flock 在 NFS 上不可靠） |
| 没有重试逻辑（拿不到锁就等） | 锁竞争时串行化所有写入 |
| 完全防止 lost update | 不防止死锁（但我们的场景中锁持有时间极短） |

**Stale lock 处理**：
- 锁文件记录 PID + 时间戳
- 获取锁时检查持有者 PID 是否仍存活
- 如果持有者已死且锁超过 30 秒，强制抢占

#### 方案 C2：Compare-and-Swap（乐观并发）

每次写入携带"我读取时的 `last_updated` 值"。如果文件的当前 `last_updated` 不一致，说明有人抢先写了，本次写入被拒绝。

```
read feature_list.json → 记录 last_updated = "2026-07-31"
modify in memory
try_write:
  current = read feature_list.json
  if current.last_updated != "2026-07-31":
    reject ("concurrent modification, retry")
  else:
    new.last_updated = now()
    atomic_write new
```

| 优点 | 缺点 |
|------|------|
| 无锁，不阻塞其他写入 | 冲突时需要重试（re-read + re-modify + re-write） |
| 适用于 NFS（无文件锁依赖） | retry 可能多次（高并发时） |
| 简单（~30 行 bash + jq） | 需要 `last_updated` 字段有足够精度 |
| 在低并发场景（2-3 agent）几乎无冲突 | 不保证 fairness（某个 agent 可能饿死） |

**Retry 策略**：
- 最多重试 3 次
- 每次重试前 sleep 随机 10-100ms（避免活锁）
- 3 次失败后 exit 4（concurrent_modification）

#### 方案 C3：Append-Only Evidence Log

Evidence 是主要的并发写入目标。将其改为 append-only log，feature_list.json 从 log 重建。

```
# 写入 evidence（无冲突）
echo '{"feature_id":"f-001","run_id":"...","evidence":{...}}' >> .harness/log/feature_events.jsonl

# 读取 evidence（重建）
jq -s '[.[] | select(.feature_id=="f-001") | .evidence]' .harness/log/feature_events.jsonl

# Status transitions 仍走 CAS 或 lock
```

| 优点 | 缺点 |
|------|------|
| evidence 写入天然无冲突（append） | feature status 变更仍需冲突解决 |
| 完整的审计日志 | log 会随时间增长（需要周期性压缩） |
| 可重建任意历史状态 | 读取性能随 log 增长而下降 |
| 最符合 "evidence 是 append-only" 的语义 | 两套写入路径（log 用于 evidence，CAS 用于 status） |

### 6.3 推荐：方案 C3（Append-Only Evidence Log）+ 方案 C2（CAS for Status Transitions）

**推荐理由**：

1. **Evidence 用 append-only log**：
   - Evidence 本身就是 append-only（v1.1.2 的语义）
   - Append 天然无冲突，不需要任何锁或 CAS
   - 提供完整的审计 trail（谁在什么时候写了什么 evidence）

2. **Status transitions 用 CAS**：
   - Status transitions 频率低（每小时最多几次）
   - CAS 的 retry 开销在低频率下可忽略
   - 不需要锁文件管理（stale lock、死锁等）
   - 与 `last_updated` 字段结合自然

3. **为什么不是 flock？**
   - flock 在 Git Bash on Windows 上有已知问题
   - Stale lock 检测增加复杂度
   - 对于低频率的 status transition，CAS 更简单

**具体实现**：

```bash
# --- Evidence: append-only log ---
ev_append_v2() {
  local fid="$1" record="$2" run_id="$3"
  local log="$HARNESS_CONFIG_DIR/.harness/log/feature_events.jsonl"
  local entry
  entry="$(jq -n --arg fid "$fid" --arg run_id "$run_id" \
    --argjson rec "$record" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{type:"evidence", feature_id:$fid, run_id:$run_id, timestamp:$ts, evidence:$rec}')"
  printf '%s\n' "$entry" >> "$log"
  # 异步触发 feature_list.json 重建（或等待下次 status 读取时重建）
}

# --- Status transition: CAS ---
cas_update_status() {
  local fid="$1" new_status="$2" fl="$3"
  local max_retries=3 retry=0
  
  while [ $retry -lt $max_retries ]; do
    local expected
    expected="$(jq -r '.last_updated // "never"' "$fl")"
    
    local new_content
    new_content="$(jq --arg fid "$fid" --arg status "$new_status" \
      --arg expected "$expected" --arg today "$(date +%Y-%m-%d)" \
      'if .last_updated != $expected then
         "CONFLICT"
       else
         (.features[] | select(.id == $fid) | .status) = $status
         | .last_updated = $today
       end' "$fl")"
    
    if [ "$new_content" = "CONFLICT" ]; then
      retry=$((retry + 1))
      sleep "0.$((RANDOM % 10 + 1))"  # 10-100ms jitter
      continue
    fi
    
    atomic_write_json "$fl" "$new_content" && return 0
    retry=$((retry + 1))
  done
  
  echo "Error: concurrent modification after $max_retries retries" >&2
  return 4  # concurrent_modification
}
```

**测试设计**：

```
test: 两个并发 verify --write 都成功写入 evidence
  1. 启动 agent A: verify f-001 --write（后台）
  2. 启动 agent B: verify f-002 --write（后台）
  3. wait A B
  4. 断言: feature_events.jsonl 中有两条 evidence 记录
  5. 断言: f-001.status = passing（如果 verify 通过）
  6. 断言: f-002.status = passing（如果 verify 通过）
  7. 断言: 没有丢失任何一条 evidence

test: 两个并发 status transition，CAS 正确拒绝后重试
  1. Agent A 读取 feature_list.json（last_updated = "2026-07-31"）
  2. Agent B 成功写入（last_updated 变为 "2026-07-31-v2"）
  3. Agent A 尝试写入（携带 expected = "2026-07-31"）
  4. 断言: Agent A 的写入被拒绝（CONFLICT）
  5. 断言: Agent A 重试成功（re-read, re-apply, re-write）
  6. 断言: 最终状态包含 A 和 B 的修改
```

---

## 7. 分阶段迁移计划

### Phase 0：冻结 + 基线（1 周）

- [ ] v1.1.2 代码冻结，标记 git tag `v1.1.2-frozen`
- [ ] v2 开发分支 `feat/harness-companion-v2`
- [ ] CI 配置：v1 测试套件在 v1 分支持续运行
- [ ] 当前全局安装版保持 v1.1.2（用户不受影响）

### Phase 1：核心提取 + 并发基础设施**（最小风险 Phase 1）**

**这是唯一一个可以立即开始、不需要更多调研的 Phase。**

- [ ] 创建 `core/` 目录结构
- [ ] 从 v1.1.2 迁移核心库，改为环境变量参数化：
  - `core/lib/state-machine.sh`
  - `core/lib/evidence.sh`（改动：`run_id` 生成方式不变，但调用改为从 `ev_append_v2` → 写 append-only log）
  - `core/lib/passing.sh`（改动：处理 `run_id: null` → `replay_required`）
  - `core/lib/atomic-write.sh`（不变）
  - `core/lib/json-helpers.sh`（合并 `json_input.sh` + `harness_config.sh` 通用部分）
  - `core/lib/concurrency.sh`（新增：CAS update + append-only event log）
- [ ] 迁移核心命令脚本：
  - `core/harness-feature.sh`（改动：status transition 走 CAS）
  - `core/harness-verify.sh`（改动：evidence 走 append-only log）
  - `core/harness-status.sh`（改动：文件检测使用环境变量）
  - `core/harness-audit.sh`（改动：文件检测使用环境变量）
- [ ] 运行时目录迁移到 `~/.harness-companion/`
- [ ] 核心测试套件：迁移 + 新增并发测试 + 新增 `run_id: null` 行为测试
- [ ] 目标：核心测试 ≥90 passed, 0 failed

**Phase 1 的风险最小，因为它只是重组织 + 添加并发基础设施。v1.1.2 的逻辑不动。**

### Phase 2：Claude Code Adapter（1-2 周）

（同 v1 设计，略。）

### Phase 3：Codex Adapter（1-2 周）

**在 Phase 2 完成后开始。需要在此之前完成 Codex hook 协议的 prototype 验证。**

- [ ] 编写 Codex Node.js hooks（`session-start.mjs`, `stop-handoff.mjs`）— 薄封装，调用核心
- [ ] 编写 Codex bash hooks 作为备选（通过 `CLAUDE_PLUGIN_ROOT` 兼容）
- [ ] 编写 Codex 模板：`CODEX.md`, `codex-progress.md`
- [ ] Codex `adapter.conf`
- [ ] Codex adapter semantic tests
- [ ] 跨平台 evidence 兼容性验证

### Phase 4：迁移工具 + 文档（1 周）

（同 v1 设计。）

### Phase 5：验证 + 发布（1 周）

（同 v1 设计。）

---

## 8. 验证方法设计

### 8.1 平台语义正确性

```
测试：adapters/<platform>/semantic.test.sh

对每个 adapter：
  - 断言 adapter 模板包含正确的知识入口文件名（不包含其他平台的）
  - 断言 adapter.conf 声明的 knowledge_entry 与模板文件名一致
  - 断言 adapter 模板不包含对方平台的品牌名（"Claude" vs "Codex"）
  - Golden test：给定相同的 feature_list.json + .harness/config.json，
    Claude adapter 和 Codex adapter 的 status 输出格式不同（各自平台格式），
    但语义相同（相同的 passing count、WIP count）
```

### 8.2 操作系统差异

（同 v1 设计。补充：Windows Git Bash 是必须通过的测试环境。）

### 8.3 项目类型 × 工作模式

```
测试：core/work-modes.test.sh

  Level 0 (Knowledge Only):
    - 仅 CODEX.md 存在 → status 报告 Knowledge OK, Scope N/A
    - verify 在这个模式下不可用（exit 2）

  Level 1 (Knowledge + Verification):
    - CODEX.md + .harness/config.json → status 报告 Verification OK
    - verify 运行成功（不挂钩 feature status）
    - feature 命令不可用（exit 2: "feature_list.json not found"）

  Level 2 (Feature-Driven):
    - 完整 harness → 所有命令可用
    - WIP=1 规则生效

  Level 2 (Task-Driven, 无 WIP 限制):
    - .harness/config.json 中 feature_list.wip_limit = 0 → 不限制并发
```

### 8.4 VCS 场景

（同 v1 设计。）

### 8.5 Agent 并发（新增重点）

```
测试：core/concurrency.test.sh

  1. 并发 evidence 写入不丢失:
     启动 2 个后台 verify 进程（不同 feature）
     等待完成
     断言 feature_events.jsonl 包含 2 个不同 run_id 的所有 evidence
     断言两条记录都存在（无一被覆盖）

  2. 并发 status transition CAS 正确:
     模拟冲突写入场景（手动设置 last_updated 不匹配）
     断言 CAS 拒绝写入
     断言重试后成功
     断言最终 feature_list.json 包含两个 agent 的修改

  3. 同 feature 并发 verify 不损坏文件:
     2 个进程同时 verify 同一个 feature
     断言 feature_list.json 是合法 JSON
     断言 evidence log 包含两轮的记录
     断言 feature status 最终稳定在某个合法状态

  4. CAS 重试上限:
     连续 3 次 CONFLICT → exit 4
     断言 exit code = 4
     断言 stderr 包含 "concurrent modification"
```

### 8.6 安装、升级、回滚

（同 v1 设计。）

### 8.7 完整验证矩阵

| 维度 | 变量 | 最低通过标准 |
|------|------|------------|
| Agent 平台 | Claude Code, Codex | 2 个平台 semantic tests 全部通过 |
| 工作模式 | Level 0/1/2 | 3 个 level 全部通过 |
| OS | Linux (Ubuntu), macOS, Windows (Git Bash) | ≥2 OS（Linux + macOS 或 Linux + Windows）|
| 项目类型 | Node, Python, Generic | 3 个类型全部通过 |
| VCS | Git (clean/dirty), no-VCS | 3 个场景全部通过 |
| 并发 | evidence 并发写, status CAS, 同 feature 并发, CAS 上限 | 4 个场景全部通过 |
| 生命周期 | 安装, 升级, 回滚, 完整性 | 4 个场景全部通过 |

---

## 9. 风险和待决策问题

### 9.1 需要您决定的产品取舍（仅 2 个）

**决策 1：Codex adapter 的投入深度**

Codex adapter 有两种级别的投入：

- **A) 默认路径**：只做 bash hooks（利用 Codex 的 `CLAUDE_PLUGIN_ROOT` 兼容）+ 显式工作流降级。Phase 3 约 1 周。
- **B) 完整路径**：做 Node.js `.mjs` hooks（官方格式）+ bash hooks 备选 + 显式工作流降级。Phase 3 约 2 周。

路径 A 的风险：如果 Codex 的 bash hook 兼容性在后续版本中移除或退化，adapter 只能降级到显式工作流模式。路径 B 更稳健但投入更大。

→ **您的选择？**

**决策 2：Level 0 项目（无 registry）的 verify 行为**

当项目没有 `feature_list.json` 但有 `.harness/config.json` 时（Level 1），`/harness:verify` 应该：

- **A)** 要求用户提供一个 feature ID（临时），运行后输出结果但不记录到任何 feature。纯一次性验证。
- **B)** 运行验证命令，将结果写入 `.harness/logs/` 但不关联 feature。不涉及 feature_list.json。
- **C)** 要求在 Level 2 才能使用 `/harness:verify`。Level 1 只能手动运行 config 中定义的命令。

→ **您的选择？**

### 9.2 我已做出的技术决策（无需用户确认）

以下问题通过调研或推理可以自行决定，不再抛给用户：

| 问题 | 决策 | 依据 |
|------|------|------|
| Windows 范围 | 仅 Git Bash / WSL | bash 依赖不可移除。cmd.exe/PowerShell 需完全重写，ROI 为负 |
| 并发方案 | Append-only evidence log + CAS for status | 分析见第 6 节。对低并发场景最优 |
| Evidence 迁移 | 绝不伪造 run_id。replay_required | 伪造 run_id 破坏信任链。re-verify 的成本低于伪造的风险 |
| Adapter 维护 | 允许复用片段，semantic tests 验证 | hash diff 验证是手段而非目标 |
| harness-protocol.json | 删除。≥3 adapter 时重新评估 | 两个 adapter 不需要机器可读协议 |
| jq 依赖 | 保留。在 v2 中仍是必需 | jq 在 Git Bash/macOS/Linux 上均可一行安装 |

### 9.3 主要风险

| 风险 | 可能性 | 缓解 |
|------|--------|------|
| Codex hook 协议细节与假设不符 | 中 | Phase 3 前先做 prototype：用 Codex 实测 `.mjs` hook 的输出格式 |
| 并发 CAS 在高频场景下 retry 耗尽 | 低 | status transition 是低频操作（每小时几次）。3 次 retry + jitter 在 2-3 agent 并发时足够 |
| Evidence append-only log 无限增长 | 低 | 初期无需压缩。一个 feature 100 次 verify = ~200KB log。提供 `harness-log-compress.sh` 作为维护工具 |
| macOS bash 3.2 不支持某些语法 | 中 | 核心库限制在 POSIX sh 子集。CI 中测试 macOS bash 3.2 |

---

## 10. 附录

### 附录 A：v1 → v2 变更摘要

| 章节 | 变更 |
|------|------|
| 1.1 | 重构为 "语义核心"（immutable contracts）vs "runtime 实现"（replaceable）|
| 1.4 | 新增：`.agents/` 目录中机械替换事故的证据 |
| 2 | 全新：语义核心与可替换运行时的分层模型 |
| 3.2 | 修订：Windows 仅支持 Git Bash / WSL；删除 PowerShell 和 cmd.exe |
| 5.1 | 重写：最小 harness 从 4 固定文件改为 4 级能力模型 |
| 5.2 | 重写：Codex adapter 基于真实调研（Node.js hooks + bash 备选 + 降级）|
| 5.3 | 修订：删除 `harness-protocol.json`；改用最小 adapter contract |
| 5.4 | 修订：禁止伪造 run_id；`replay_required` 状态 |
| 6 | 全新：并发一致性设计（3 方案比较，推荐 CAS + append-only log）|
| 7 | 修订：Phase 1 标记为 "最小风险"，Phase 3 增加 prototype 前置条件 |
| 9.1 | 精简：从 5 个决策点缩减为 2 个真正需要用户决定的 |
| 9.2 | 全新：我已做出的技术决策及依据 |
| 附录 B | 全新：仍未验证的假设 |

### 附录 B：仍未验证的假设

以下内容基于调研和推理，但**尚未通过 prototype 或实机测试验证**。进入对应 Phase 前必须验证。

**经研究确认（不再是不确定的假设）**：
- ✅ Codex 有 SessionStart/Stop hooks —— 官方文档确认
- ✅ Codex hooks 配置在 `~/.codex/config.toml`（TOML），**不是** `settings.json`（JSON）
- ✅ Codex 使用 `AGENTS.md` 作为自定义指令文件，不使用 `CLAUDE.md`
- ✅ Codex hook 脚本官方格式是 Node.js `.mjs`/`.js`

**仍未验证的内容**：

| 假设 | 影响 | 验证方法 | 验证时机 |
|------|------|---------|---------|
| Codex hook 输出的 exact JSON 字段名（`additionalContext` vs `systemMessage` vs 其他命名） | Codex adapter hook 输出格式 | 在 Codex 中运行最小 `.mjs` hook，捕获 stdout 检查实际字段名 | Phase 3 前 |
| `config.toml` 中 `[[hooks]]` 块的 exact schema（每个事件类型如何映射到脚本路径） | Codex adapter 安装器需要生成正确的 TOML 配置 | 查阅 Codex 官方 hooks 文档的 config.toml 章节 | Phase 3 前 |
| Codex bash hook 兼容性（`CLAUDE_PLUGIN_ROOT`）在最新版本中仍有效 | Codex adapter 可用 bash hooks 作为备选 | 在 Codex 中测试 v1.1.2 的 session-start.sh | Phase 3 前 |
| Codex Windows sandbox hook 不可靠的具体触发条件和表现形式 | 决定 Codex adapter 在 Windows 上的默认降级策略 | 在 Windows sandbox 中测试 hook 是否能启动并输出 | Phase 3 前 |
| `.codex-plugin/plugin.json` 完整 schema（字段列表、必填项、版本号） | Codex adapter 安装逻辑 | 查阅 Codex 插件文档或逆向已有 Codex 插件 | Phase 3 前 |
| Git Bash `flock` 可用性 | 如果未来需要 flock 作为并发备选方案 | `flock --version` 在 Git Bash 中 | Phase 2 前（备选验证） |
| macOS bash 3.2 下 `date -u +%Y-%m-%dT%H:%M:%SZ` 行为 | run_id 时间戳格式一致性 | macOS CI 运行核心测试套件 | Phase 1 |
| Codex hook `hookSpecificOutput` 顶层 key 是否存在，以及 `additionalContext` 嵌套路径 | hook 注入 harness status 的方式 | 对比 Claude Code hook 输出 JSON vs Codex hook 输出 JSON | Phase 3 前 |

---

> **状态**：等待用户审批。确认第 9.1 节的 2 个决策 + 整体方向后，进入实现计划（`superpowers:writing-plans`）。

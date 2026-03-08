# Symphony (Claude Code Integration Fork)

Fork 自 [openai/symphony](https://github.com/openai/symphony)，目标是将底层编码 Agent 从 Codex app-server 替换为 Claude Code subprocess。

## 项目概述

Symphony 是一个自动化编码 Agent 编排服务：轮询 Linear Issue Tracker，为每个 Issue 创建隔离工作区，调度 AI 编码 Agent 自动完成开发任务。

## 技术栈

- **语言**: Elixir 1.19+ / Erlang OTP 28
- **框架**: Phoenix 1.8 + Phoenix LiveView 1.1（Dashboard）
- **HTTP Server**: Bandit 1.10
- **依赖管理**: Mix + Hex
- **核心依赖**:
  - `jason` — JSON 编解码
  - `yaml_elixir` — YAML 解析（WORKFLOW.md front-matter）
  - `solid` — Liquid 模板渲染（提示词模板）
  - `nimble_options` — 类型化配置校验
  - `req` — HTTP 客户端（Linear GraphQL API）
  - `claude_agent_sdk` — Claude Code Elixir SDK（**新增**）
- **外部服务**: Linear（Issue Tracker）、Claude Code CLI

## 项目结构

```
symphony/
├── SPEC.md                          # 语言无关的完整规范文档
├── README.md                        # 项目说明
├── CLAUDE.md                        # 本文件 - 项目开发指南
├── STATUS.md                        # 开发进度追踪
├── .claude/plans/                   # 实施计划文档
│
├── elixir/                          # Elixir 参考实现（主要工作目录）
│   ├── mix.exs                      # 项目定义 + 依赖
│   ├── WORKFLOW.md                  # 编排配置（YAML front-matter + 提示词模板）
│   ├── AGENTS.md                    # Agent 文档
│   ├── Makefile                     # 构建自动化
│   │
│   ├── config/
│   │   └── config.exs               # 应用配置
│   │
│   ├── lib/
│   │   ├── symphony_elixir.ex       # 应用入口
│   │   └── symphony_elixir/
│   │       ├── cli.ex               # CLI 入口（escript main_module）
│   │       ├── config.ex            # WORKFLOW.md 配置解析 + 类型化 accessor
│   │       ├── workflow.ex           # WORKFLOW.md 加载器（front-matter + prompt 分离）
│   │       ├── workflow_store.ex     # GenServer 缓存 + 文件变更检测 + 热重载
│   │       ├── orchestrator.ex       # 核心编排器 GenServer（轮询/调度/并发/重试/Token统计）
│   │       ├── agent_runner.ex       # 单 Issue 执行：workspace → prompt → agent session → 多轮
│   │       ├── workspace.ex          # 隔离工作区管理（创建/清理/Hook/路径安全）
│   │       ├── prompt_builder.ex     # Liquid 模板渲染（issue + attempt 注入）
│   │       ├── tracker.ex            # Tracker 抽象层
│   │       ├── http_server.ex        # HTTP Server 启动
│   │       ├── status_dashboard.ex   # 终端状态面板
│   │       ├── log_file.ex           # 日志文件管理
│   │       ├── specs_check.ex        # 规范检查
│   │       │
│   │       ├── codex/                # [原有] Codex app-server 集成
│   │       │   ├── app_server.ex     # JSON-RPC 2.0 客户端（stdio）
│   │       │   └── dynamic_tool.ex   # 客户端工具（linear_graphql）
│   │       │
│   │       ├── claude_code/          # [已完成] Claude Code 集成
│   │       │   ├── client.ex         # Streaming API 客户端（~320 行）
│   │       │   └── mcp_linear.ex     # Linear MCP server 配置生成
│   │       │
│   │       ├── linear/               # Linear API 集成
│   │       │   ├── client.ex         # GraphQL 客户端（分页/标准化）
│   │       │   ├── adapter.ex        # 数据适配
│   │       │   └── issue.ex          # Issue 数据结构
│   │       │
│   │       └── tracker/
│   │           └── memory.ex         # 内存 Tracker（测试用）
│   │
│   ├── lib/symphony_elixir_web/      # Phoenix Web 层
│   │   ├── endpoint.ex              # HTTP 端点
│   │   ├── router.ex                # 路由
│   │   ├── live/
│   │   │   └── dashboard_live.ex    # LiveView Dashboard
│   │   ├── controllers/
│   │   │   ├── observability_api_controller.ex  # REST API (/api/v1/*)
│   │   │   └── static_asset_controller.ex
│   │   └── ...
│   │
│   ├── priv/static/
│   │   └── dashboard.css            # Dashboard 样式
│   │
│   └── test/                        # ExUnit 测试
│       ├── test_helper.exs
│       ├── support/
│       └── symphony_elixir/
│           ├── app_server_test.exs
│           ├── core_test.exs
│           ├── cli_test.exs
│           ├── dynamic_tool_test.exs
│           ├── extensions_test.exs
│           ├── workspace_and_config_test.exs
│           └── ...
│
└── .codex/                          # Codex skills
    ├── skills/
    │   ├── commit/SKILL.md
    │   ├── push/SKILL.md
    │   ├── pull/SKILL.md
    │   ├── land/SKILL.md + land_watch.py
    │   ├── linear/SKILL.md
    │   └── debug/SKILL.md
    └── worktree_init.sh
```

## 关键命令

所有命令在 `elixir/` 目录下执行：

```bash
# 环境准备
cd ~/Projects/symphony/elixir
mix deps.get                      # 安装依赖
mix compile                       # 编译

# 测试
mix test                          # 运行全部测试
mix test test/symphony_elixir/app_server_test.exs  # 运行单个测试文件
mix test --trace                  # 详细输出

# 代码质量
mix lint                          # credo --strict + specs.check
mix credo --strict                # 静态分析
mix dialyzer                      # 类型检查

# 构建 & 运行
mix build                         # 构建 escript (bin/symphony)
./bin/symphony                    # 运行（需要 WORKFLOW.md + LINEAR_API_KEY）
./bin/symphony --port 4000        # 带 HTTP Dashboard

# Claude Code 后端开发运行
CLAUDECODE="" LINEAR_API_KEY="$KEY" \
  elixir -e 'Application.put_env(:symphony_elixir, :server_port_override, 4000)' \
  -S mix run --no-halt

# 清理
mix deps.clean --all              # 清理依赖
mix clean                         # 清理编译产物
```

## 核心架构 — 六层模型

```
Policy        — WORKFLOW.md（提示词模板 + 配置）
Configuration — Config（类型化 accessor + $ENV + 热重载）
Coordination  — Orchestrator（轮询/调度/并发/重试/Token 统计）
Execution     — AgentRunner + AppServer/ClaudeCode.Client + Workspace
Integration   — Linear GraphQL Client
Observability — HTTP Dashboard + REST API + 日志
```

## 编排流程

1. 启动 → 校验配置 → 清理终态工作区 → 启动轮询
2. 每个 Tick（默认 30s）：协调 → 校验 → 拉取候选 Issue → 排序 → 调度
3. 每次 Dispatch：创建工作区 → Hook → 渲染提示词 → 启动 Agent 会话 → 多轮执行
4. Worker 退出：正常 → 1s continuation retry；异常 → 指数退避重试

## 开发约定

- 配置通过 `WORKFLOW.md` YAML front-matter，支持 `$ENV_VAR` 引用和 `~` 路径展开
- 所有 Issue 状态比较需 trim + downcase 标准化
- Workspace 路径必须在 `workspace.root` 内，路径字符仅允许 `[A-Za-z0-9._-]`
- 事件消息格式：`%{event: atom, timestamp: DateTime, session_id: binary, usage: map}`
- Agent 后端通过 `agent.backend` 配置切换（`"codex"` / `"claude_code"`）
- Claude Code 后端运行需设置 `CLAUDECODE=""` 环境变量（绕过嵌套检测）
- Claude Code 使用 control_client 传输（因 `permission_mode: :bypass_permissions`）
- **permission_mode 必须为 `bypassPermissions`**：`dontAsk` 会自动拒绝 MCP 工具和 Bash，导致 agent 死循环
- Token 追踪：累加器模式（per-turn 累加），Result 消息优先取完整 usage
- MCP Linear：优先使用 SDK in-process MCP server（`create_sdk_mcp_server`），binary 缺失时自动 fallback
- GitHub 仓库：`slatwater/symphony-claude`（v1/v2/v3），`slatwater/symphony` 已删除
- **版本发布规则**：每次向 GitHub 推送新版本（tag）后，必须同步更新 `STATUS.md`（进度/验证结果/版本历史）和 `CLAUDE.md`（如有架构/约定变更）

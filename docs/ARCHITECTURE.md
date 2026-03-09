# 架构详情

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
  - `req` — HTTP 客户端（GitHub REST API）
  - `claude_agent_sdk` — Claude Code Elixir SDK
- **外部服务**: GitHub Issues（Issue Tracker）、Claude Code CLI

## 六层模型

```
Policy        — WORKFLOW.md（提示词模板 + 配置）
Configuration — Config（类型化 accessor + $ENV + 热重载）
Coordination  — Orchestrator（轮询/调度/并发/重试/Token 统计）
Execution     — AgentRunner + AppServer/ClaudeCode.Client + Workspace
Integration   — GitHub REST API Client
Observability — HTTP Dashboard + Agent 事件流 + 历史回放 + REST API + 日志
```

## 编排流程

1. 启动 → 校验配置 → 清理终态工作区 → 启动轮询
2. 每个 Tick（默认 30s）：协调 → 校验 → 拉取候选 Issue → 排序 → 调度
3. 每次 Dispatch：创建工作区 → Hook → 渲染提示词 → 启动 Agent 会话 → 多轮执行
4. Worker 退出：正常 → 1s continuation retry；异常 → 指数退避重试

## 目录职责

```
symphony/
├── CLAUDE.md              # 开发指南（必读）
├── STATUS.md              # 开发进度追踪
├── SPEC.md                # 语言无关的完整规范
├── docs/                  # 架构详情（本文件）
│
├── elixir/                # Elixir 实现（主要工作目录）
│   ├── WORKFLOW.md        # 编排配置（YAML front-matter + 提示词模板）
│   ├── lib/symphony_elixir/
│   │   ├── config.ex          # 配置解析 + accessor
│   │   ├── orchestrator.ex    # 核心编排器（轮询/调度/并发/重试）
│   │   ├── agent_runner.ex    # 单 Issue 执行（workspace → agent → 多轮）
│   │   ├── workspace.ex       # 隔离工作区管理
│   │   ├── prompt_builder.ex  # Liquid 模板渲染
│   │   ├── codex/             # Codex app-server 集成（原有）
│   │   ├── claude_code/       # Claude Code 集成（v3+）
│   │   │   └── client.ex      # Streaming API 客户端
│   │   └── github/            # GitHub REST API 客户端
│   │   └── event_store.ex    # ETS 事件存储 + JSON 持久化
│   ├── lib/symphony_elixir_web/  # Phoenix Web 层
│   │   └── live/
│   │       ├── dashboard_live.ex  # 主 Dashboard（运行状态 + Token 统计）
│   │       ├── agent_log_live.ex  # 实时 Agent 事件流（/agent/:id）
│   │       └── history_live.ex    # 历史会话浏览 + 回放（/history）
│   └── test/                     # ExUnit 测试
│
└── .codex/                # Codex skills（commit/push/pull/land）
```

## Token 追踪架构

```
Anthropic API (prompt caching)
  ├─ input_tokens              (未缓存，全价)
  ├─ cache_read_input_tokens   (缓存读取，10% 价格)
  ├─ cache_creation_input_tokens (缓存写入，125% 价格)
  └─ output_tokens
        ↓
ClaudeCode.Client (累加器模式)
  ├─ sum_input_tokens()    → 合计 3 个 input 字段
  ├─ message_start         → turn_input = sum_input_tokens
  ├─ message_delta         → 更新 turn_output + turn_input
  ├─ message_stop          → accumulated += turn
  ├─ maybe_drain_result    → 从邮箱 drain Result 消息 (500ms)
  └─ finalize_usage        → prefer Result, fallback accumulated
      ├─ input_tokens            (总量，向后兼容)
      ├─ input_tokens_uncached
      ├─ cache_read_input_tokens
      └─ cache_creation_input_tokens
        ↓
Orchestrator / Dashboard / REST API
```

## 实时可观测性架构（v3.3）

```
Claude Code stream events
  │
  ├─ text_delta        → :text_output（Agent 思考文本）
  ├─ tool_use_start    → 缓存 tool name
  ├─ tool_input_delta  → 累积 JSON 片段
  ├─ content_block_stop→ :tool_use（拼装完整输入 → summarize_tool_input）
  ├─ message_stop      → :turn_completed（Token 统计）
  │
  ▼
Orchestrator.record_agent_event
  ├─ humanize_update   → 人类可读消息（Bash 显示命令，Read/Write 显示路径）
  ├─ filter noise      → 跳过无 tool_name 的 :notification
  │
  ▼
EventStore (ETS)                PubSub broadcast
  ├─ append/2          ───→    agent:events:{issue_id}
  ├─ persist_session/2         agent:events:all
  │   └→ log/sessions/*.json
  │
  ▼
AgentLogLive (/agent/:id)      HistoryLive (/history)
  ├─ 实时订阅 PubSub           ├─ 加载 JSON 文件
  ├─ 过滤 (tool/text/turn/err) ├─ 定时回放 (50-2000ms)
  └─ 文本聚合 (连续 text 合并)  └─ 会话列表
```

## 协议差异（Codex vs Claude Code）

| 维度 | Codex app-server | Claude Code subprocess |
|---|---|---|
| 协议 | JSON-RPC 2.0 | NDJSON stream-json |
| 启动 | 3-phase 握手 | 进程启动即就绪 |
| 权限 | 运行时 approval | 启动时 `--permission-mode` |
| Token | 流式累积事件 | message_start/delta + result |
| 工具 | DynamicTool | MCP server 或内置工具 |
| 传输 | 固定 | 根据 Options 自动选 CLI 或 control_client |

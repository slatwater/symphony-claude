# Symphony — Claude Code Integration Fork

自动化编码 Agent 编排服务：轮询 Linear Issue → 创建隔离工作区 → 调度 Claude Code Agent 自动完成开发任务。

> **开始前先读 `STATUS.md`**，了解当前进度和已知限制。
> 架构详情见 `docs/ARCHITECTURE.md`。

## 目录速查

| 目录 | 职责 |
|---|---|
| `elixir/lib/symphony_elixir/` | 核心逻辑（编排/Agent/配置/工作区） |
| `elixir/lib/symphony_elixir/claude_code/` | Claude Code 集成（client + MCP） |
| `elixir/lib/symphony_elixir/codex/` | Codex 集成（原有，备用后端） |
| `elixir/lib/symphony_elixir/linear/` | Linear API 客户端 |
| `elixir/lib/symphony_elixir/event_store.ex` | ETS 事件存储 + JSON 会话持久化 |
| `elixir/lib/symphony_elixir_web/` | Phoenix Web 层（Dashboard + Agent 事件流 + 历史回放 + REST API） |
| `elixir/lib/symphony_elixir_web/live/` | LiveView 页面（Dashboard + AgentLogLive + HistoryLive） |
| `elixir/WORKFLOW.md` | 编排配置 + 提示词模板 |

## 关键命令

所有命令在 `elixir/` 目录下执行：

```bash
mix deps.get && mix compile          # 环境准备
mix test                             # 测试
mix lint                             # credo --strict + specs.check
make all                             # CI 全流程（format + lint + test + coverage + dialyzer）

# Claude Code 后端运行
CLAUDECODE="" LINEAR_API_KEY="$KEY" \
  elixir -e 'Application.put_env(:symphony_elixir, :server_port_override, 4000)' \
  -S mix run --no-halt
```

## 开发约定

### 配置与数据

- 配置通过 `WORKFLOW.md` YAML front-matter，支持 `$ENV_VAR` 引用和 `~` 路径展开
- Agent 后端通过 `agent.backend` 切换（`"codex"` / `"claude_code"`）
- 所有 Issue 状态比较需 trim + downcase 标准化
- Workspace 路径必须在 `workspace.root` 内，字符仅允许 `[A-Za-z0-9._-]`

### Claude Code 后端

- 运行需设置 `CLAUDECODE=""` 环境变量（绕过嵌套检测）
- 使用 control_client 传输（因 `permission_mode: :bypass_permissions`）
- **permission_mode 必须为 `bypassPermissions`**：`dontAsk` 会拒绝 MCP/Bash，导致死循环
- MCP Linear：优先 SDK in-process MCP server，binary 缺失时自动 fallback

### Token 追踪

- 累加器模式（per-turn 累加），Result 消息优先取完整 usage
- `sum_input_tokens` 合计 `input_tokens` + `cache_read_input_tokens` + `cache_creation_input_tokens`
- `finalize_usage` 输出含 cache breakdown（`input_tokens_uncached` / `cache_read_input_tokens` / `cache_creation_input_tokens`）

### 可观测性

- `EventStore`：ETS GenServer，per-issue 事件累积（max 500），完成时 JSON 持久化到 `log/sessions/`
- Agent 事件流：`/agent/:issue_identifier` 实时展示工具调用（含输入摘要）、Agent 文本输出、Turn/Token 统计
- 历史回放：`/history` 浏览已完成会话，支持按真实时间间隔回放
- PubSub：`agent:events:{issue_id}` per-agent 事件、`agent:events:all` 全局事件

### 版本发布

- GitHub 仓库：`slatwater/symphony-claude`（v1/v2/v3/v3.1/v3.2/v3.3）
- 每次推送新 tag 后，必须同步更新 `STATUS.md` 和 `CLAUDE.md`（如有变更）

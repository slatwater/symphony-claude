# 开发进度 — Claude Code 集成

> 目标：将 Symphony Elixir 实现的底层编码 Agent 从 Codex app-server 替换为 Claude Code subprocess
>
> 上次更新：2026-03-06

## 总体进度

```
Phase 1: 依赖与配置基础    [▓▓▓▓▓▓▓▓▓▓] 100% — 依赖已加，Config 已扩展
Phase 2: ClaudeCode.Client  [▓▓▓▓▓▓▓▓▓▓] 100% — 核心模块 + Token 追踪修复
Phase 3: AgentRunner 适配   [▓▓▓▓▓▓▓▓▓▓] 100% — 动态后端分派已完成
Phase 4: Orchestrator 微调  [▓▓▓▓▓▓▓▓▓▓] 100% — extract_token_usage 已兼容
Phase 5: Linear MCP 工具    [▓▓▓▓▓▓▓▓▓▓] 100% — McpLinear 配置生成 + 缺失检测
Phase 6: WORKFLOW.md 更新   [▓▓▓▓▓▓▓▓▓▓] 100% — claude: 段 + after_create hook
Phase 7: Dry-run 端到端验证 [▓▓▓▓▓▓▓▓░░]  80% — 已通过：轮询→调度→Agent运行→Token追踪
Phase 8: 单元测试           [▓▓░░░░░░░░]  20% — 编译通过，mix test 因 lazy_html NIF 受阻
```

**当前状态：端到端 dry-run 通过，Agent 可成功执行 Linear 任务并报告 token usage**

## Dry-run 验证结果（2026-03-06）

| 验证项 | 结果 | 说明 |
|---|---|---|
| 服务启动 | Pass | `mix run --no-halt --port 4000`，Dashboard 可访问 |
| Linear 轮询 | Pass | 正确拉取 project `codex-e0f360a28d29` 的 active issues |
| Issue 调度 | Pass | COD-7 (Todo) 被自动 dispatch 到 worker |
| 工作区创建 | Pass | `~/code/symphony-workspaces/COD-7` + git init + hook |
| Claude Code 会话 | Pass | Streaming session 启动成功，control_client 路径 |
| Agent 执行 | Pass | Agent 完成代码修改、git commit、更新 Linear workpad |
| Token 追踪 | Pass | output_tokens 持续增长，Orchestrator 正确计入 |
| Web Dashboard | Pass | http://127.0.0.1:4000/ 实时显示运行状态 |
| REST API | Pass | `/api/v1/state` 返回 token / event / session 数据 |

### 已知限制

| 限制 | 原因 | 影响 |
|---|---|---|
| `input_tokens` 偏低 | control_client 路径的 `message_start` 事件不含完整 API usage | 仅影响 input 统计，output_tokens 准确 |
| 无 GitHub 推送 | 测试工作区用 `git init`（无 remote） | Agent 无法 push/PR，会报 blocker |
| 无 Linear MCP 工具 | `priv/mcp/linear_mcp_server` 二进制不存在 | Agent 无法直接调用 Linear API（使用 CLI fallback） |

## 模块级状态

### 已完成

| 模块 | 状态 | 说明 |
|---|---|---|
| 项目 Clone & 环境 | Done | Elixir 1.19 + OTP 28，mix compile 通过 |
| `mix.exs` 依赖添加 | Done | `claude_agent_sdk ~> 0.15` 已添加，`ignore_modules` 已更新 |
| `config.ex` 扩展 | Done | `agent.backend` + `claude.*` 配置段 + accessor 函数 + validation |
| `ClaudeCode.Client` | Done | Streaming API + Token usage 多源提取 + result 消息处理 |
| `ClaudeCode.McpLinear` | Done | MCP 配置生成 + binary 存在性检查（缺失时 graceful skip） |
| `AgentRunner` 适配 | Done | `agent_backend/0` 动态分派，替换硬编码 `AppServer` 调用 |
| `Orchestrator` 微调 | Done | `extract_token_usage/1` 新增直接 `integer_token_map?` 识别 |
| `WORKFLOW.md` | Done | `agent.backend: claude_code` + `claude:` 配置段 + local hook |

### 待完成

| 模块 | 文件 | 说明 |
|---|---|---|
| Client 测试 | `test/symphony_elixir/claude_code/client_test.exs` | 仿照 `app_server_test.exs`，fake claude 脚本 + stream events |
| Config 测试 | `test/symphony_elixir/workspace_and_config_test.exs` | 新增 `claude.*` 和 `agent.backend` 测试 |
| Linear MCP 二进制 | `priv/mcp/linear_mcp_server` | 需提供或构建 Linear MCP server 可执行文件 |
| input_tokens 精度 | `client.ex` | 从 `result` Message 获取完整 usage（已有 handler，待验证） |

### 不改动（保留原样）

| 模块 | 说明 |
|---|---|
| `codex/app_server.ex` | 原有 Codex 客户端，`agent.backend: codex` 时使用 |
| `codex/dynamic_tool.ex` | `linear_graphql` 工具实现 |
| `orchestrator.ex` 主体 | 事件消费、stall 检测、retry 逻辑均兼容 |
| `prompt_builder.ex` | 模板渲染逻辑不变 |
| `workspace.ex` | 工作区管理不变 |
| `linear/` 全部 | Linear API 客户端不变 |
| Web 层全部 | Dashboard、API、Router 不变 |

## 改动文件清单

| 文件 | 操作 | 说明 |
|---|---|---|
| `lib/symphony_elixir/config.ex` | 修改 | +claude.* 配置段 + agent.backend + accessor + validation |
| `lib/symphony_elixir/claude_code/client.ex` | **新建** | Claude Code subprocess 客户端（~320 行） |
| `lib/symphony_elixir/claude_code/mcp_linear.ex` | **新建** | Linear MCP server 配置生成 + 存在性检查（~50 行） |
| `lib/symphony_elixir/agent_runner.ex` | 修改 | 动态后端分派（~15 行改动） |
| `lib/symphony_elixir/orchestrator.ex` | 修改 | `extract_token_usage` 新增直接 usage 识别（~10 行改动） |
| `WORKFLOW.md` | 修改 | agent.backend + claude 配置段 + after_create local hook |

## 关键设计决策

1. **双后端支持**：通过 `agent.backend` 配置切换，不删除 Codex 代码
2. **API 兼容**：`ClaudeCode.Client` 暴露与 `Codex.AppServer` 相同接口
3. **事件兼容**：事件格式匹配 Orchestrator 预期，仅微调 token 识别逻辑
4. **使用 `claude_agent_sdk`**：hex.pm v0.15+ Streaming API 作为传输层
5. **SDK 选择**：使用 Streaming API（而非 batch query API）以支持多轮对话
6. **Control Client 路径**：`permission_mode: :bypass_permissions` 触发 control_client 传输
7. **Token 多源提取**：message_start.usage + message_delta.raw_event.usage + result Message.data.usage
8. **MCP 优雅降级**：binary 不存在时跳过 MCP 配置，避免 CLI 启动超时

## 协议差异备忘

| 维度 | Codex app-server | Claude Code subprocess |
|---|---|---|
| 协议 | JSON-RPC 2.0 | NDJSON stream-json |
| 启动 | 3-phase 握手 (initialize → thread/start → turn/start) | 进程启动即就绪，system.init 消息 |
| Turn | `turn/start` → `turn/completed` | 写入 user 消息 → 等待 result 消息 |
| 权限 | 运行时 approval request 处理 | 启动时声明 `--permission-mode` |
| Token | 流式累积事件 | message_start/delta + result 消息 |
| 工具 | `item/tool/call` → DynamicTool | MCP server 或内置工具 |
| 传输选择 | 固定 | StreamingRouter 根据 Options 自动选择 CLI 或 control_client |

## Token 追踪架构

```
Claude CLI (stream-json)
  │
  ├─ message_start  ─→ EventParser ─→ {usage: {input_tokens, output_tokens=0}}
  ├─ message_delta   ─→ EventParser ─→ {raw_event["usage"]: {output_tokens}}
  ├─ message_stop    ─→ EventParser ─→ turn_completed 事件
  └─ result Message  ─→ control_client ─→ {type: :message, message: %{data: %{usage: ...}}}
        │
        ▼
  ClaudeCode.Client
    ├─ maybe_update_usage (merge, not replace)
    ├─ emit_event(:turn_completed, method: :turn_completed, usage: normalized)
    │
    ▼
  Orchestrator.extract_token_usage
    ├─ 1. 直接检查 update[:usage] → integer_token_map? ✓ (新增)
    └─ 2. 原有 Codex 深层嵌套路径 (fallback)
```

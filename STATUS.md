# 开发进度 — Claude Code 集成

> 目标：将 Symphony Elixir 实现的底层编码 Agent 从 Codex app-server 替换为 Claude Code subprocess
>
> 上次更新：2026-03-09

## 总体进度

```
Phase 1: 依赖与配置基础    [▓▓▓▓▓▓▓▓▓▓] 100% — 依赖已加，Config 已扩展
Phase 2: ClaudeCode.Client  [▓▓▓▓▓▓▓▓▓▓] 100% — 核心模块 + Token 追踪修复（累加器模式）
Phase 3: AgentRunner 适配   [▓▓▓▓▓▓▓▓▓▓] 100% — 动态后端分派已完成
Phase 4: Orchestrator 微调  [▓▓▓▓▓▓▓▓▓▓] 100% — extract_token_usage 已兼容
Phase 5: Linear MCP 工具    [▓▓▓▓▓▓▓▓▓▓] 100% — McpLinear + SDK in-process MCP fallback
Phase 6: WORKFLOW.md 更新   [▓▓▓▓▓▓▓▓▓▓] 100% — claude: 段 + after_create hook
Phase 7: Dry-run 端到端验证 [▓▓▓▓▓▓▓▓▓▓] 100% — COD-7/COD-8 端到端通过
Phase 8: 单元测试           [▓▓░░░░░░░░]  20% — 编译通过，mix test 因 lazy_html NIF 受阻
Phase 9: 实时可观测性       [▓▓▓▓▓▓▓▓▓▓] 100% — EventStore + Agent 流程图 + 历史回放
```

**当前状态：生产可用 — Agent 自主完成 Linear 任务（Todo → In Review），单任务 ~1-7 分钟，水平流程图可观测**

## 端到端验证结果（2026-03-08）

### COD-7: Add Claude Code integration note to README
| 指标 | 结果 |
|---|---|
| 耗时 | ~68 秒（1 轮完成） |
| Token | 3,337 total (out=3,327, in=15) |
| 工具调用 | 11 次（Linear GraphQL + Bash + Read/Glob） |
| 最终状态 | In Progress → **In Review** |

### COD-8: Add CONTRIBUTING.md with development setup guide
| 指标 | 结果 |
|---|---|
| 耗时 | ~7 分钟（1 轮完成） |
| Token | 9,240 total (out=9,202, in=48) |
| 产出 | CONTRIBUTING.md (70 行，含 4 个必要章节) |
| 最终状态 | Todo → In Progress → **In Review** |

### COD-19: Add hello.txt with greeting message
| 指标 | 结果 |
|---|---|
| 耗时 | ~2 分钟 |
| 产出 | hello.txt + PR #8 |
| 最终状态 | Todo → In Progress → **In Review** |
| 事件流验证 | 43 事件，工具调用显示实际命令，文本输出正确聚合 |

### COD-20: Add README.md with project description
| 指标 | 结果 |
|---|---|
| 耗时 | ~2 分钟 |
| 产出 | README.md 更新 + PR #9 |
| 最终状态 | Todo → In Progress → **In Review** |
| 事件持久化 | 128 事件 → `log/sessions/*.json` ✓ |

### 全链路验证
| 验证项 | 结果 | 说明 |
|---|---|---|
| 服务启动 | Pass | `CLAUDECODE="" mix run --no-halt`，Dashboard 可访问 |
| Linear 轮询 | Pass | 正确拉取 project `codex-e0f360a28d29` 的 active issues |
| Issue 调度 | Pass | COD-7/COD-8/COD-19/COD-20 自动 dispatch 到 worker |
| 工作区创建 | Pass | `~/code/symphony-workspaces/COD-*` + git init + hook |
| Claude Code 会话 | Pass | control_client 路径，bypassPermissions 模式 |
| MCP Linear | Pass | SDK in-process MCP (无需外部 binary) |
| Agent 执行 | Pass | 代码修改 + git commit + PR 检查 + Linear workpad 更新 |
| Token 追踪 | Pass | 累加器模式，output_tokens 准确，Result 消息优先 |
| Web Dashboard | Pass | http://127.0.0.1:4000/ 实时显示运行状态 |
| Agent 流程图 | Pass | `/agent/:id` 水平流程图（事件→阶段聚合 + 卡片/箭头 UI + 点击展开） |
| 历史回放 | Pass | `/history` 浏览已完成会话 + 定时回放 |
| 事件持久化 | Pass | agent 完成时自动保存到 `log/sessions/*.json` |
| REST API | Pass | `/api/v1/state` 返回 token / event / session 数据 |

### 已知限制

| 限制 | 原因 | 影响 |
|---|---|---|
| `input_tokens` 偏低 | **已修复并验证** — 根因为 prompt caching：`sum_input_tokens` 合计 `input_tokens` + `cache_read` + `cache_creation` | 从 34 → 252,392 |
| `lazy_html` NIF 下载失败 | proxy/网络限制 | 影响 `mix test`，不影响运行 |

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

| `EventStore` | Done | ETS 事件存储 + JSON 持久化（per-issue 事件累积 → `log/sessions/`） |
| `AgentLogLive` | Done | Per-agent 水平流程图 LiveView（事件聚合为阶段卡片 + 箭头，点击展开详情） |
| `HistoryLive` | Done | 历史会话浏览 + 定时回放 LiveView |
| `ObservabilityPubSub` | Done | 新增 per-agent 和全局 agent 事件 PubSub topic |

### 待完成

| 模块 | 文件 | 说明 |
|---|---|---|
| Client 测试 | `test/symphony_elixir/claude_code/client_test.exs` | 仿照 `app_server_test.exs`，fake claude 脚本 + stream events |
| Config 测试 | `test/symphony_elixir/workspace_and_config_test.exs` | 新增 `claude.*` 和 `agent.backend` 测试 |
| input_tokens 精度 | `client.ex` | **已修复已验证** — `sum_input_tokens` 合计 3 个字段 + `maybe_drain_result` drain Result 消息 |

### 不改动（保留原样）

| 模块 | 说明 |
|---|---|
| `codex/app_server.ex` | 原有 Codex 客户端，`agent.backend: codex` 时使用 |
| `codex/dynamic_tool.ex` | `linear_graphql` 工具实现 |
| `orchestrator.ex` 主体 | 事件消费、stall 检测、retry 逻辑均兼容 |
| `prompt_builder.ex` | 模板渲染逻辑不变 |
| `workspace.ex` | 工作区管理不变 |
| `linear/` 全部 | Linear API 客户端不变 |
| Web 层（v3.2） | Dashboard、API、Router 不变 |
| Tauri 桌面客户端 | Done | Tauri v2 包装 Phoenix（系统托盘 + 等待就绪 + Cmd 缩放） |

## 改动文件清单

| 文件 | 操作 | 说明 |
|---|---|---|
| `lib/symphony_elixir/config.ex` | 修改 | +claude.* 配置段 + agent.backend + accessor + validation |
| `lib/symphony_elixir/claude_code/client.ex` | **新建** | Claude Code subprocess 客户端 |
| `lib/symphony_elixir/claude_code/mcp_linear.ex` | **新建** | Linear MCP server 配置生成 + 存在性检查 |
| `lib/symphony_elixir/agent_runner.ex` | 修改 | 动态后端分派 |
| `lib/symphony_elixir/orchestrator.ex` | 修改 | +extract_token_usage + record_agent_event + persist 修复 |
| `WORKFLOW.md` | 修改 | agent.backend + claude 配置段 + after_create local hook |
| `lib/symphony_elixir/event_store.ex` | **新建** | ETS 事件存储 + JSON 持久化 |
| `lib/symphony_elixir_web/live/agent_log_live.ex` | **新建** | Agent 水平流程图 LiveView（v3.4 重写为阶段聚合 + 卡片/箭头） |
| `lib/symphony_elixir_web/live/history_live.ex` | **新建** | 历史会话浏览 + 回放 LiveView |
| `lib/symphony_elixir_web/observability_pubsub.ex` | 修改 | +per-agent 事件 PubSub topic |
| `lib/symphony_elixir_web/router.ex` | 修改 | +`/agent/:id` + `/history` 路由 |
| `lib/symphony_elixir_web/components/layouts.ex` | 修改 | +AutoScroll JS hook + Cmd 缩放脚本 |
| `lib/symphony_elixir_web/live/dashboard_live.ex` | 修改 | +Live Log 链接 + History 入口 |
| `lib/symphony_elixir.ex` | 修改 | +EventStore supervision |
| `priv/static/dashboard.css` | 修改 | +流程图 UI 样式（卡片/箭头/状态条） |
| `desktop/` | **新建** | Tauri v2 桌面客户端（Cargo + Rust src + icons + package.json） |

## 关键设计决策

1. **双后端支持**：通过 `agent.backend` 配置切换，不删除 Codex 代码
2. **API 兼容**：`ClaudeCode.Client` 暴露与 `Codex.AppServer` 相同接口
3. **事件兼容**：事件格式匹配 Orchestrator 预期，仅微调 token 识别逻辑
4. **使用 `claude_agent_sdk`**：hex.pm v0.15+ Streaming API 作为传输层
5. **SDK 选择**：使用 Streaming API（而非 batch query API）以支持多轮对话
6. **Control Client 路径**：`permission_mode: :bypass_permissions` 触发 control_client 传输
7. **Token 累加器模式**：per-turn 累加 input/output，Result 消息优先取完整 usage
8. **MCP SDK fallback**：binary 不存在时使用 `ClaudeAgentSDK.create_sdk_mcp_server` 提供 in-process Linear 工具
9. **bypassPermissions 必须**：`dontAsk` 模式会自动拒绝 MCP/Bash 工具，导致 agent 死循环

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
  ClaudeCode.Client (累加器模式)
    ├─ stream_acc: accumulated_input/output + turn_input/output + result_usage
    ├─ message_start  → 记录 turn_input
    ├─ message_delta  → 更新 turn_output (取最大值)
    ├─ message_stop   → accumulated += turn, 重置 turn
    ├─ result Message → 保存 result_usage (优先级最高)
    ├─ finalize_usage → prefer result_usage, fallback to accumulated
    ├─ emit_event(:turn_completed, usage: normalized)
    │
    ▼
  Orchestrator.extract_token_usage
    ├─ 1. 直接检查 update[:usage] → integer_token_map? ✓ (新增)
    └─ 2. 原有 Codex 深层嵌套路径 (fallback)
```

## 版本历史

| 版本 | 日期 | 说明 |
|---|---|---|
| v1 | 2026-03-06 | 初始 Claude Code 集成（Phase 1-6 完成） |
| v2 | 2026-03-07 | Token 追踪修复 + MCP SDK fallback + permission mode 调整 |
| v3 | 2026-03-08 | 恢复 bypassPermissions，端到端验证通过（COD-7/COD-8） |
| v3.1 | 2026-03-08 | Label 路由：`local` 标签走轻量流程（直接 Done），默认走 PR 流程；after_create hook 改为 git clone |
| v3.2 | 2026-03-08 | 修复 input_tokens 偏低：`sum_input_tokens` 合计 cache 字段 + `maybe_drain_result` drain Result 消息 + `finalize_usage` cache breakdown 字段 + CI 修绿（format/credo/test/coverage）+ agent_runner 参数重构 + 14 个单元测试 |
| v3.3 | 2026-03-09 | 实时可观测性：EventStore + Agent 事件流 LiveView + 历史回放 + 工具输入摘要 + 文本聚合 + 会话持久化 |
| v3.4 | 2026-03-09 | Agent 流程图：AgentLogLive 重写为水平流程图（事件聚合为阶段节点 + 卡片/箭头 UI + 点击展开详情 + 持久化会话回退加载修复） |
| v3.5 | 2026-03-09 | Tauri v2 桌面客户端（系统托盘 + 自动启停 Phoenix + Cmd 缩放）+ Session History Issue 列显示序号+标题 |

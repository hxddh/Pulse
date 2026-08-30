# 12.0 Codex runtime 取证（2026-08-30）

## 结论

Codex 可以成为 12.0 的第二个受管 runtime，但安全边界必须是官方 **App Server v2 over
stdio**，不是 `codex exec --json`。

- `exec --json` 是稳定的非交互 JSONL：有 `thread.started`、turn/item 生命周期、token、
  `thread_id` 和 `exec resume`，适合 CI 或一次性自动化。
- `exec` 不提供父进程可回答的审批协议；当前实现会拒绝 command/file approval 与用户输入
  请求，并取消 MCP elicitation。它无法满足 Pulse「完整请求旁才有 Allow」。
- App Server 是官方 rich-client embedding surface，使用双向 JSON-RPC 2.0（wire 上省略
  `jsonrpc`）和 stdio JSONL；它提供 thread/turn/item、resume、interrupt，以及 server →
  client 的 command/file permission requests。
- App Server 没有协议版本协商；schema 与 Codex binary 版本绑定。因此 Pulse 必须记录版本、
  只使用 stable v2 子集、用该版本生成的 JSON Schema 做 fixture，并对未知形状拒绝 Allow。

官方来源：

- [Non-interactive mode](https://developers.openai.com/codex/noninteractive)
- [CLI reference](https://developers.openai.com/codex/cli/reference)
- [App Server](https://developers.openai.com/codex/app-server)
- [App Server protocol README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
- [Codex source](https://github.com/openai/codex/tree/main/codex-rs/app-server-protocol)

## 当前 binary 证据（Linux，仅协议层）

在当前 orb 临时安装 npm `latest` 的官方 `@openai/codex@0.151.0`，没有复用或输出任何
认证信息。实际执行结果：

- `codex --version` → `codex-cli 0.151.0`；
- `codex app-server generate-json-schema` 成功；
- stable v2 schema bundle SHA-256：
  `2442b15801bc019ad55987ad03e0f0ae60c51417825b9b6d708db640e6c2651c`；
- 真实 stdio `initialize`（`experimentalApi=false`）握手成功，响应字段为
  `codexHome / platformFamily / platformOs / userAgent`；
- schema 确认 `thread/start`、`thread/resume`、`turn/start`、`turn/interrupt` 与
  thread/turn/item notifications；
- command approval 必填关联键是 `threadId / turnId / itemId / startedAtMs`，完整
  `command / cwd` 仍是 nullable，因此 Pulse 的 Allow 必须额外要求它们实际在场；
- file approval request 确实不带 diff，只能与 `item/started.fileChange` 关联；
- schema 中确实存在 `acceptForSession` 与 policy amendments，Pulse 必须主动不暴露；
- permission grant 默认 scope 是 `turn`，但 Pulse 仍只回所请求集合的子集。

这证明 decoder 可以针对真实 0.151.0 schema 开始，不证明 macOS sandbox、登录、网络授权、
实际 agent turn 或子进程回收；下方真机门不变。版本号和 checksum 是取证基线，不是承诺
永远只支持 0.151.0。

## 已由公开契约确认

| P0 问题 | 结论 | Pulse 采用的证据 |
| --- | --- | --- |
| 结构化输出 | 可行 | stable v2 `thread/*`、`turn/*`、`item/*` notifications |
| continuation | 可行 | 持久 `thread.id`；`thread/resume` |
| 回合终态 | 可行 | `turn/completed.turn.status`，不是 EOF 或最后一段文字 |
| cancel | 可行 | `turn/interrupt` → terminal `interrupted` |
| command approval | 条件可行 | 关联 `item/started.commandExecution` 与 server request |
| file approval | 条件可行 | request 自身无 diff；必须关联先到的 `fileChange.changes` |
| network permission | 独立形状 | 展示 host/protocol/port，不冒充 shell command |
| MCP elicitation | 有协议但 12.0 不接 | 需要额外 schema/form UI 与 capability opt-in |
| schema compatibility | 无协商 | `generate-json-schema` 产物与 binary 精确绑定 |
| transport | 可行 | 仅 stdio；WebSocket 是 experimental / unsupported |

## 最小协议子集

Pulse 只实现：

1. `initialize` → `initialized`，`experimentalApi=false`；
2. `thread/start` / `thread/resume`；
3. `turn/start` / `turn/interrupt`；
4. `thread/started`、`turn/started`、`turn/completed`；
5. `item/started`、必要 deltas、`item/completed`；
6. `item/commandExecution/requestApproval`；
7. `item/fileChange/requestApproval`；
8. `serverRequest/resolved`；
9. stdio/process shutdown。

不启用 experimental API，不接 account、rate limit、goal、plugins、apps、process、filesystem、
dynamic tools、MCP elicitation 或 WebSocket。Pulse 复用用户已有的 Codex CLI 登录；未登录只
显示 runtime 不可用，不新增账户产品面。

## 审批纪律

### Command

Allow 的必要条件：

- request id、thread id、turn id、item id 全部可关联；
- 同 item 的完整 `command` 与 `cwd` 已收到且未被截断；
- request 仍未被 `serverRequest/resolved`、turn completion 或 interrupt 清掉；
- UI 展示完整命令，用户在该表面点击。

仅有 `reason`、friendly `commandActions` 或摘要时没有 Allow。

### File change

审批 request 不重复 diff。只有先收到并保留同 `itemId` 的完整 `fileChange.changes`，UI
展示全部 path/kind/diff 后才有 Allow。关联丢失、顺序异常、内容超出展示上限或解析失败，
只能 Deny/Cancel。

### Network / permissions

网络授权是自己的完整请求表面（host、protocol、port 与 scope）；不能拿可能为空的 command
预览代替。`request_permissions` 的 grant 只能是所请求集合的子集。

Pulse v1 只回单次 `accept / decline / cancel`：永不使用 `acceptForSession`、exec-policy
amendment 或 network-policy amendment。后几种会把一次用户判断扩大成规则，违反无
always-allow / 无判断转移。

### 失败

未知 server request、缺关联 item、malformed JSON、EOF、App Server crash、版本不兼容与
超时全部等价为**没有 Allow**。若 request id 仍可回答则 decline/cancel；连接已死就如实把
turn 标 interrupted/failed，不推断厂商执行了什么。

## Runtime 生命周期结论

Claude 当前是「每回合一个 child，session id resume」；Codex App Server 是「Candidate
期间一个长寿双向 child，thread id resume」。因此共同接缝不能是 `executable + argv +
consume(line)`。共同接缝应是 runtime session 操作：start/resume、send turn、cancel、回答
审批、shutdown，并向 Fleet 发标准化事件；每家自己拥有进程拓扑与 wire decoder。

Codex Candidate 持久化至少绑定：Codex version、thread id、canonical worktree root。resume
前再次 canonicalize 并逐字匹配；不允许把旧 thread 静默续到另一目录。

## 当前未完成的真机证据

当前 orb 是 Linux，且没有 `codex` / `claude` binary；本文件没有把公开文档冒充执行证据。
以下仍是 12.0 的发布阻断项，必须在真实 macOS 完成：

- 记录 `codex --version` 与该 binary 生成的 stable JSON Schema；
- start → edit → command failure → final answer 的完整脱敏 stream fixture；
- thread resume 同 worktree 成功、换 worktree 被 Pulse 拒绝；
- command Allow / Deny / timeout；
- file-change Allow / Deny / 丢失关联 fail-closed；
- network request 的完整实际形状；
- interrupt、App Server crash、malformed/unknown request；
- MCP startup 正常、失败与 resume 不得无限无输出（外层 watchdog 必须能中止）；
- Pulse 退出后无残留 App Server/agent 子进程。

这些通过之前，可以实现纯 decoder fixture 与 Claude 零行为 runtime 重构，但不能把 Codex
标为可用，更不能发布 12.0。

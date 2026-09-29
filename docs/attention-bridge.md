# Attention 桥 —— 让名单外的工具点亮「需要你」

Pulse 的 **hooks 安装器只覆盖 Claude Code 和 Codex**，这是刻意的：
维护一个 30+ agent 的 hook 安装器，等于替每个工具维护它的配置格式。

其他 agent 有两条路：

1. **什么都不做** —— 格式有来源可查的 agent，harvest 会从它们的会话文件里认出 `pending`
   （Kimi、OpenCode、Gemini、Cline…… 见 README 的支持矩阵）；格式「未核实」的 agent
   （Cursor、Droid、Amp……）23.0 起不再从 harvest 推断等待；
2. **走这座桥** —— 想要 hooks 级别的准确度（明确的授权 / 输入等待，而不是猜），
   让工具在等待时按 **Attention Protocol**（v3，每行八列；23.0 起六列 / 七列的旧行不再读取）写一行 TSV。

**契约正文：** [`attention-protocol.md`](attention-protocol.md)（header、八列
（第七列 `host` 留空且被忽略、第八列 `front` 留空即未知）、kind 白名单、raise / clear）。桥接进来的等待在 Tray 上标注为 `hooks`，与
Claude / Codex 同级。

---

## 谁最需要这座桥

下列 Agent 的 `waitingSource` 为 **none**：本机没有 hooks，也没有可靠的
`skill=pending` 路径。Pulse 只会显示 Running，并在托盘 / Support 指向这里 ——
**不会伪造 Waiting**：

| Agent id | 产品 |
| --- | --- |
| `replit` | Replit |
| `devin` | Devin |
| `warpAgent` | Warp Agent |
| `trae` | Trae |
| `antigravity` | Antigravity |
| `junie` | Junie |
| `zcode` | ZCode |
| `cursor` | Cursor（23.0：格式未核实，不从 harvest 推断等待） |
| `amp` / `amazonQ` / `cascade` / `windsurf` / `augment` / `zedAgent` / `kiro` / `droid` / `commandCode` | 同上（23.0） |
| `aider` | Aider（20.0：历史写在项目目录，里面没有等待信号） |
| `continue_` | Continue（20.0：待批准的工具调用与普通调用在磁盘上无法区分） |

App 里没有桥接工具（23.0 删除了设置里的样本与工具包按钮）：桥接作者直接按
协议写行，或调用 `pulse-hook`。「安装连接」只合并 Claude / Codex 官方 hooks。

**原生 hook：** Claude / Codex 的官方 Waiting 通路是
`~/Library/Application Support/Pulse/pulse-hook` → `PulseBar --hook …`，
与 `AttentionIO` 同一 flock/TSV 契约，写完一行立即退出，从不扣留。

**session 身份：** Attention 行若带明确 `session`，优先挂到同 id 行；若现有行
都已占用*别的* session，Pulse 会**新建** Waiting 行，而不会 smear 到兄弟会话
（0.60）。仅有空 session 的进程行可以收养该 wait。`cwd` 回退只在未写 session
时生效。

**可运行样本：** [`docs/samples/attention-bridge/`](samples/attention-bridge/)
（通用 `raise.sh` + `raise-replit.sh` … `raise-junie.sh` + `clear.sh`）——优先
调用 `pulse-hook`，否则直接追加 TSV；不是 hook 安装器扩展。

深链 / Focus 精度边界：[`docs/landing-hosts.md`](landing-hosts.md)。

---

## 文件

```
~/Library/Application Support/Pulse/attention.tsv
```

制表符分隔，八列 —— 完整白名单与 header 见
[`attention-protocol.md`](attention-protocol.md)：

| 列 | 内容 |
| --- | --- |
| `agent` | Pulse 的 agent id：`droid`、`kimi`、`replit`、`devin`… |
| `kind` | 白名单（v3）：阻塞 `permission` · `question` · `waiting`；轮到你 `turn`；已解决 `done`；`subagent_*` |
| `ms` | Unix 毫秒时间戳 |
| `message` | 一句原因，无制表符和换行 |
| `session` | 可选，会话 id —— 有它才能挂到正确的会话行 |
| `cwd` | 可选，项目路径 |
| `host` | 留空；读取端忽略 |
| `front` | 可选：`1` 提示窗口在最前、`0` 不在、留空未知 |

Pulse 的读取规则：

- 同一 `(agent, session)` **后写覆盖先写**；
- `done` 清除该会话（`session` 留空则清除该 agent 全部）；
- `turn`（16.0）表示「做完了、轮到你」：清掉该会话的阻塞等待（20 秒宽限内不清掉刚发生的
  阻塞），并把会话标为「轮到你」—— 这**不点红灯**，只在托盘里安静计数；旧的 `stop`、
  `idle_prompt` 现在都按 `turn` 读；
- 未知 kind **不写、不亮**（No fake Waiting）；
- 超过 **30 分钟**的条目自动过期；
- 文件保留最近 80 行。

---

## 写入方式

### 推荐：原生 `pulse-hook`

设置里安装连接后，Application Support 里会有可执行的
`pulse-hook`（转调 `PulseBar --hook`）：

```bash
HOOK="$HOME/Library/Application Support/Pulse/pulse-hook"

# 从 JSON 取 kind / message / session / cwd
echo '{"notification_type":"permission","message":"Approve shell","session_id":"abc","cwd":"'"$PWD"'"}' \
  | "$HOOK" replit

# 或者直接用 argv 给 kind
"$HOOK" junie permission
```

清除等待：

```bash
"$HOOK" replit done
echo '{"session_id":"abc"}' | "$HOOK" replit done
```

### 退路：纯 shell 追加

只在无法调用 `pulse-hook` 时用。**有竞态**，且不做行数回收：

```bash
PULSE="$HOME/Library/Application Support/Pulse"
mkdir -p "$PULSE"
ms=$(($(date +%s) * 1000))
printf 'replit\tpermission\t%s\tApprove tool\tsess1\t%s\t\t\n' "$ms" "$PWD" \
  >> "$PULSE/attention.tsv"
```

---

## 各家 hook 配方（20.0，按厂商文档核对）

这些 Agent 有自己的 hook 系统，但 Pulse 的安装器只管 Claude 与 Codex —— 下面是**你自己**
加进各家配置的片段。三条规则贯穿全部：

- **argv 里写明 kind。** 各家的事件名大小写不同（`stop`、`agentStop`、`preToolUse`）；
  20.0 起 `pulse-hook` 把认不出的事件名当作未知、**不写不亮**，但只有 argv 里的 kind
  才能保证落到对的类别。
- **永远不要接「批准之前」的事件。** Copilot 的 `permissionRequest`、Cursor 的
  `beforeShellExecution`、Kiro / Droid 的 `PreToolUse` 都在厂商自己的规则与自动批准**之前**
  触发 —— 接了就是伪造等待。也不要把非 Claude 的 `PermissionRequest` 接进来。
- **Grok Build 默认会执行 `~/.claude/settings.json` 里的 hooks。** 20.0 起 `pulse-hook`
  凭 `GROK_HOOK_EVENT` / `GROK_SESSION_ID` 把这些调用记在 Grok 名下，不需要另配。

**GitHub Copilot CLI** —— `~/.copilot/hooks/pulse.json`
（github/docs `copilot/reference/hooks-reference.md`）：

```json
{"version":1,"hooks":{
 "notification":[{"type":"command","matcher":"permission_prompt|elicitation_dialog",
   "bash":"\"$HOME/Library/Application Support/Pulse/pulse-hook\" copilot","timeoutSec":5}],
 "agentStop":[{"type":"command","bash":"\"$HOME/Library/Application Support/Pulse/pulse-hook\" copilot turn","timeoutSec":5}],
 "userPromptSubmitted":[{"type":"command","bash":"\"$HOME/Library/Application Support/Pulse/pulse-hook\" copilot prompt","timeoutSec":5}]}}
```

`matcher` 必须排除 `agent_completed` / `agent_idle`（那是后台子代理，不是你的回合）。

**Factory Droid** —— `~/.factory/hooks.json`（Factory docs `reference/hooks-reference.mdx`）：

```json
{"hooks":{
 "Notification":[{"hooks":[{"type":"command","command":"in=$(cat); printf %s \"$in\" | grep -q '\"notification_type\"' && printf %s \"$in\" | \"$HOME/Library/Application Support/Pulse/pulse-hook\" droid; exit 0"}]}],
 "Stop":[{"hooks":[{"type":"command","command":"\"$HOME/Library/Application Support/Pulse/pulse-hook\" droid turn"}]}],
 "UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"$HOME/Library/Application Support/Pulse/pulse-hook\" droid prompt"}]}]}}
```

Droid 的「输入框空闲 60 秒」也走 Notification；没有 `notification_type` 的那种会被上面的
守卫丢掉（20.0 起接收端也不再把它当成等待）。

**Qwen Code** —— `~/.qwen/settings.json` 的 `hooks`（Claude 兼容，QwenLM/qwen-code
`docs/users/features/hooks.md`）：`Notification`（matcher `permission_prompt|idle_prompt`）、
`Stop`、`UserPromptSubmit` 各接 `pulse-hook qwen`；**不要**接 `PermissionRequest`。
Qwen Code 目前不在 Pulse 的名录里：它的行会以桥接的方式出现，没有会话采集。

**Cursor Agent CLI** —— `~/.cursor/hooks.json`：`stop` → `pulse-hook cursor turn`，
`beforeSubmitPrompt` → `pulse-hook cursor prompt`。Cursor 没有「需要你批准」的事件，
所以这里只有「轮到你」；CLI 是否触发这些 hook 各方说法不一，需要真机确认。

**Kiro** —— `.kiro/hooks/pulse.json`：`Stop` → `pulse-hook kiro turn`，
`UserPromptSubmit` → `pulse-hook kiro prompt`。同样没有阻塞类事件。

**Amp** —— 插件 `~/.config/amp/plugins/pulse.ts` 订阅 `ctx.thread.state`：
`awaiting-approval` → `pulse-hook amp permission`，从 `running` 回到 `idle` → `turn`，
从 `awaiting-approval` 回到 `running` → `done`。不要接 `tool.call`（批准之前）。

## 界面上会怎样

写入后 Pulse 通常在一秒内亮灯 —— `AttentionWatcher` 盯着这个文件，
不必等下一个探测周期。

- Glance 变红并呼吸
- Tray 里对应会话置顶，带原因、时长和 `hooks` 标签
- 若开了 Waiting 通知，会发一条：标题 `{Agent} · {项目}`，正文 `{原因} · {消息}`

`session` 列写对了，等待就挂在正确的会话行上；写空了，Pulse 会挂到该 agent
当前最合适的一行。

---

## 边界

- **不要**把安装器扩成覆盖所有 agent —— 这座桥就是为了避免那件事。
- 名单内有 `harvestPending` 的 agent 在没有 TSV 行时，仍走 harvest `pending`，二者不冲突。
- 只写真实的等待。Pulse 的核心承诺是「亮了就真的在等你」，
  伪造一条等待损害的是整个产品的可信度。

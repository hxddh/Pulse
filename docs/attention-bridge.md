# Attention 桥 —— 七个 Agent 的官方 hook 怎样点亮 Pulse

Pulse 只支持七个主流 Agent，每个都只走厂商**自己文档里**的 hook、插件或扩展：

| Agent | 装在哪里 | 形态 | 会不会报告「需要你」 |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/settings.json` 的 `hooks` | 命令 hook，全部 `async: true` | 会（PermissionRequest、Notification 权限 / 提问） |
| Codex | `~/.codex/hooks.json`（从不碰 `config.toml`） | 命令 hook（`async`） | **不会**：它的 PermissionRequest 在自己的自动审查之前触发，装了就是假等待 |
| Gemini CLI | `~/.gemini/settings.json` 的 `hooks` | 命令 hook | 会（Notification `ToolPermission`） |
| Copilot CLI | `~/.copilot/hooks/pulse.json`（Pulse 独占这个文件） | 命令 hook | 会（notification `permission_prompt` / `elicitation_dialog`） |
| OpenCode | `~/.config/opencode/plugins/pulse.js`（Pulse 独占） | 插件，只用 `event` | 会（`permission.asked` / `question.asked`） |
| Cursor | `~/.cursor/hooks.json` | 命令 hook | **不会**：没有不拦截的等待事件 |
| Pi | `~/.pi/agent/extensions/pulse.js`（Pulse 独占） | 扩展 | 会（`ui_prompt_start` / `ui_prompt_end`） |

每个事件映射成 Pulse 的哪种状态，见 [`attention-protocol.md`](attention-protocol.md) 的「Per-agent mapping」；
读的是厂商哪份文档或哪个提交，见 [`vendor-formats.json`](vendor-formats.json) 里每个 Agent 的 `hooks`。

## 规则（写死的）

- **只装观察型事件。** 从不装 PreToolUse、beforeShellExecution、BeforeTool、`tool.execute.before`、
  `tool_call`、permissionRequest 这类能拦截或改变决定的 hook（`HookContract.gatingEvents`），
  也从不返回任何决定：`pulse-hook` 什么都不打印、立即 `exit 0`。Claude 与 Codex 的条目另加
  `async`，厂商本身就不会等它、也不会读它的输出。
- **逐字节可逆。** 第一次写某个文件前，Pulse 把它原来的字节（或「原本不存在」）记进
  `~/Library/Application Support/Pulse/hook-installs.json`。移除时若文件仍是 Pulse 写下的样子，
  就原样还原（原本不存在的文件和目录一并删掉）；若你之后改过它，只删带 Pulse 标记的条目，其余保留。
  「Pulse 标记」只认完整的 `pulse-hook` 命令（路径以 `/pulse-hook` 结尾或单独这个词），
  你自己的 `impulse-hook.sh` 不算。不合法的 JSON、带注释的 JSONC、`hooks` 结构不是「事件 → 数组」
  的文件都不改，并说明原因；CRLF 换行与 UTF-8 BOM 原样保留；你留着的空事件 `[]` 也留着。
  Codex 只写 `hooks.json`，`config.toml` 一个字节都不动。不是 Pulse 写的同名插件文件不覆盖。
- **只装在这台 Mac 上有的 Agent。** 厂商目录（`~/.claude`、`~/.gemini`…）不存在就不装；托盘的设置卡
  也只提这些 Agent。某个 Agent 装失败了，设置卡不再提它，改说失败原因。
- **不假装等待。** Codex 与 Cursor 只显示「运行中」与「轮到你」，设置里明说「不会报告它在等你」；
  有人经 `pulse-hook` 或脚本替它们写阻塞行，接收器直接拒收。

## 写入方式

推荐原生 `pulse-hook`（安装器写的就是它）：

```bash
HOOK="$HOME/Library/Application Support/Pulse/pulse-hook"
# 厂商事件名 + 厂商 JSON（安装后各家 hook 就是这样调用的）
echo '{"session_id":"s1","cwd":"'"$PWD"'","hook_event_name":"Notification","notification_type":"ToolPermission","message":"Allow run_shell_command?"}' \
  | "$HOOK" gemini Notification
# 或者直接用协议里的词
echo '{"session_id":"s1","message":"Approve deploy?"}' | "$HOOK" claude permission
echo '{"session_id":"s1"}' | "$HOOK" claude done
```

所有事件都写进**同一个事件日志** `~/Library/Application Support/Pulse/events.tsv`：只追加、
每个 hook 事件一行（开始、提交、工具、阻塞、空闲、回合结束、解决、结束），按写入顺序；文件 0600，
超过 1 MiB 时压缩并换一代表头——每个会话留最近的行和两小时内的全部行，开着的阻塞连同它之后的行
一行不丢，正在追加的那一行也不丢。Pulse 启动时先把整份日志重放一遍，再画第一次托盘；之后只读新写的字节。

脚本也请走 `pulse-hook`：它在日志的排他锁下追加一整行；直接 `>>` 可能和同时写入的 hook 交错，
而 macOS 没有 `flock(1)`。见 [`samples/attention-bridge/raise.sh`](samples/attention-bridge/raise.sh)。

hook 自己会记下 Agent 的进程号（沿父进程链找到第一个符合目录进程规则的祖先；找不到就不写 —— 从不拿
直接父进程，那通常是跑完 hook 就退出的 `sh -c`；父进程已经退出、被 launchd 收养时也不写），以及落地句柄：`tmux:%3`、
`iterm:<ITERM_SESSION_ID>`、`tty:/dev/ttys004`、`term:<TERM_PROGRAM>`。不 fork、不跑 `ps`，只用
`sysctl` 与环境变量。Pulse 之后若发现这个进程号已经换成了别的程序（或是在会话之后才启动的进程），
就当会话已结束。

## 界面上会怎样

- 阻塞（`permission` / `question`）：红灯、通知（开着的话）、行上第二行写出问的是什么。
- 回合结束（`turn`）：安静的「轮到你」，不红、不通知；回合结束事件带的原话是「最后的消息」，
  以错误结束的（`tool` 列为 `error`）是「错误」。
- 工具运行（`tool`）：运行中的行第二行安静地写上一步（工具 · 目标 · 多久前）；提示事件带的原文是标题。
  不读 token、用量、费用字段。
- 设置 → Hooks 就是诊断：这台 Mac 上的每个 Agent 一行——已安装 / 未安装 / 安装失败及原因，
  最近一次事件是多久前，缺 hook 的给一个安装按钮；不在这台 Mac 上的 Agent 合成一行；
  Codex 与 Cursor 注明「不会报告它在等你」。「复制报告」把这些与通知授权一起写成纯文本。

## 边界

- 不在托盘里批准或拒绝；回答永远在厂商自己的提示里。
- 名单之外的工具不受支持：`pulse-hook` 拒收未知 Agent。

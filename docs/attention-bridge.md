# Attention 桥 —— 七个 Agent 的官方 hook 怎样点亮 Pulse

24.0（Exact）起，Pulse 只支持七个主流 Agent，每个都只走厂商**自己文档里**的 hook、插件或扩展：

| Agent | 装在哪里 | 形态 | 会不会报告「需要你」 |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/settings.json` 的 `hooks` | 命令 hook，全部 `async: true` | 会（PermissionRequest、Notification 权限 / 提问） |
| Codex | `~/.codex/hooks.json` + `config.toml` 的 `notify` | 命令 hook（`async`） | **不会**：它的 PermissionRequest 在自己的自动审查之前触发，装了就是假等待 |
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
  不合法的 JSON 不改；不是 Pulse 写的同名插件文件不覆盖。
- **只装在这台 Mac 上有的 Agent。** 厂商目录（`~/.claude`、`~/.gemini`…）不存在就不装。
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

退路是按 v4（十列）直接往 `attention.tsv` 追加一行，见
[`samples/attention-bridge/raise.sh`](samples/attention-bridge/raise.sh)。

hook 自己会记下 Agent 的进程号（沿父进程链找到第一个符合目录进程规则的祖先，找不到就用直接父进程）、
会话 transcript 路径，以及落地句柄：`tmux:%3`、`iterm:<ITERM_SESSION_ID>`、`tty:/dev/ttys004`、
`term:<TERM_PROGRAM>`。不 fork、不跑 `ps`，只用 `sysctl` 与环境变量。

## 界面上会怎样

- 阻塞（`permission` / `question`）：红灯、通知（开着的话）、行上第二行写出问的是什么。
- 回合结束（`turn`）：安静的「轮到你」，不红、不通知。
- 设置 → Hooks：每个 Agent 一行——已安装 / 未安装 / 这台 Mac 上没有，最近一次事件是多久前；
  Codex 与 Cursor 注明「不会报告它在等你」。
- 诊断 → 自检：每个 Agent 一条「hooks 已安装」、一条「hooks 到达 Pulse」；发现 Pulse 条目挂在
  会拦截的事件上（旧版的 PreToolUse、Codex 的 PermissionRequest）就提示重新安装。

## 边界

- 不在托盘里批准或拒绝；回答永远在厂商自己的提示里。
- 名单之外的工具不受支持：`pulse-hook` 拒收未知 Agent。

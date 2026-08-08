# Attention 桥 —— 让名单外的工具点亮「需要你」

Pulse 的 **hooks 安装器只覆盖 Claude Code 和 Codex**，这是刻意的：
维护一个 30+ agent 的 hook 安装器，等于替每个工具维护它的配置格式。

其他 agent 有两条路：

1. **什么都不做** —— harvest 会尽力从它们的会话文件里认出 `pending`
   （Cursor、Droid、Kimi、OpenCode…… 见 README 的支持矩阵）；
2. **走这座桥** —— 想要 hooks 级别的准确度（明确的授权 / 输入等待，而不是猜），
   让工具在等待时按 **Attention Protocol v1** 写一行 TSV。

**契约正文：** [`attention-protocol.md`](attention-protocol.md)（header、六列、
kind 白名单、raise / clear）。桥接进来的等待在 Tray 上标注为 `hooks`，与
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

设置 → Waiting signals →「安装连接」写入原生 `pulse-hook`（**无需 Python**）；
「打开 Attention 文件夹」到达写入目录；同区「写入样本 Waiting」会为**全部七个**
Waiting-none Agent（replit / devin / warpAgent / trae / antigravity / junie / zcode）各追加
一行可清除的样本（`pulse-sample` 会话）——不扩 hook 安装器。

**原生 hook：** Claude / Codex 的官方 Waiting 通路是
`~/Library/Application Support/Pulse/pulse-hook` → `PulseBar --hook …`，
与 `AttentionIO` 同一 flock/TSV 契约。旧的 `pulse_hook.py` 仍可识别与卸载，但
新安装优先原生。

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

制表符分隔，六列 —— 完整白名单与 header 见
[`attention-protocol.md`](attention-protocol.md)：

| 列 | 内容 |
| --- | --- |
| `agent` | Pulse 的 agent id：`droid`、`kimi`、`replit`、`devin`… |
| `kind` | 白名单：`permission` · `idle_prompt` · `waiting` · `done` · `stop` · `subagent_*` |
| `ms` | Unix 毫秒时间戳 |
| `message` | 一句原因，无制表符和换行 |
| `session` | 可选，会话 id —— 有它才能挂到正确的会话行 |
| `cwd` | 可选，项目路径 |

Pulse 的读取规则：

- 同一 `(agent, session)` **后写覆盖先写**；
- `done` 清除该会话（`session` 留空则清除该 agent 全部）；
- `stop` 也清除，但**20 秒宽限内**不会清掉刚发生的 `permission` / `idle_prompt`
  —— Claude 常常先发 idle_prompt 紧接着发 Stop；
- 未知 kind **不写、不亮**（No fake Waiting）；
- 超过 **30 分钟**的条目自动过期；
- 文件保留最近 80 行。

---

## 写入方式

### 推荐：原生 `pulse-hook`（无需 Python）

Settings → Waiting signals → 安装连接后，Application Support 里会有可执行的
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

### 兼容：旧 `pulse_hook.py`

仍随 app seed；probe / uninstall 认它。新安装优先原生 launcher。

```bash
HOOK="$HOME/Library/Application Support/Pulse/pulse_hook.py"
python3 "$HOOK" replit permission   # 仅当你已有 Python 且仍指向旧脚本时
```

### 退路：纯 shell 追加

只在无法调用 `pulse-hook` 时用。**有竞态**，且不做行数回收：

```bash
PULSE="$HOME/Library/Application Support/Pulse"
mkdir -p "$PULSE"
ms=$(($(date +%s) * 1000))
printf 'replit\tpermission\t%s\tApprove tool\tsess1\t%s\n' "$ms" "$PWD" \
  >> "$PULSE/attention.tsv"
```

---

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

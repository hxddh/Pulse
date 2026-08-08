# Attention 桥 —— 让名单外的工具点亮「需要你」

Pulse 的 **hooks 安装器只覆盖 Claude Code 和 Codex**，这是刻意的：
维护一个 30+ agent 的 hook 安装器，等于替每个工具维护它的配置格式。

其他 agent 有两条路：

1. **什么都不做** —— harvest 会尽力从它们的会话文件里认出 `pending`
   （Cursor、Droid、Kimi、OpenCode…… 见 README 的支持矩阵）；
2. **走这座桥** —— 想要 hooks 级别的准确度（明确的授权 / 输入等待，而不是猜），
   让工具在等待时写一行 TSV。

桥接进来的等待，在 Tray 上标注为 `hooks`，与 Claude / Codex 同级。

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

设置 → Waiting signals →「打开 Attention 文件夹」可直接到达写入目录；
同区「写入样本 Waiting」会为**全部六个** Waiting-none Agent
（replit / devin / warpAgent / trae / antigravity / junie）各追加一行可清除的
样本（`pulse-sample` 会话）——不扩 hook 安装器。

**可运行样本：** [`docs/samples/attention-bridge/`](samples/attention-bridge/)
（`raise-replit.sh` … `raise-junie.sh` + `clear.sh`）——只演示 TSV 写入，
不是 hook 安装器扩展。

深链 / Focus 精度边界：[`docs/landing-hosts.md`](landing-hosts.md)。

---

## 文件

```
~/Library/Application Support/Pulse/attention.tsv
```

制表符分隔，六列：

| 列 | 内容 |
| --- | --- |
| `agent` | Pulse 的 agent id：`droid`、`kimi`、`replit`、`devin`… |
| `kind` | `permission` · `idle_prompt` / `waiting` · `done` · `stop` |
| `ms` | Unix 毫秒时间戳 |
| `message` | 一句原因，无制表符和换行 |
| `session` | 可选，会话 id —— 有它才能挂到正确的会话行 |
| `cwd` | 可选，项目路径 |

Pulse 的读取规则：

- 同一 `(agent, session)` **后写覆盖先写**；
- `done` 清除该会话（`session` 留空则清除该 agent 全部）；
- `stop` 也清除，但**20 秒宽限内**不会清掉刚发生的 `permission` / `idle_prompt`
  —— Claude 常常先发 idle_prompt 紧接着发 Stop；
- 超过 **30 分钟**的条目自动过期；
- 文件保留最近 80 行。

---

## 写入方式

### 推荐：调用 `pulse_hook.py`

它已经在 app 包里，处理了 flock、字段规范化和行数上限：

```bash
HOOK="/Applications/Pulse.app/Contents/Resources/pulse_hook.py"

# 从 JSON 取 kind / message / session / cwd
echo '{"notification_type":"permission","message":"Approve shell","session_id":"abc","cwd":"'"$PWD"'"}' \
  | python3 "$HOOK" replit

# 或者直接用 argv 给 kind
python3 "$HOOK" junie permission
```

清除等待：

```bash
# 该 agent 全部会话
python3 "$HOOK" replit done

# 仅某个会话 —— session id 只能走 stdin JSON，argv 形态表达不了
echo '{"session_id":"abc"}' | python3 "$HOOK" replit done
```

### 退路：纯 shell 追加

只在无法调用 Python 时用。**有竞态**，且不做行数回收：

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

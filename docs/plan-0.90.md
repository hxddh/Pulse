# 0.90 计划 —— Waiting Reach / 等待可达

## 先说这份评估的局限

0.80–0.82 把托盘观测做实。同章再挖 harvest 收益变薄。本版换章：**Waiting-none
舰队从「只会 Running」变成可完成的打断通路** —— Attention Protocol 从文档变成
产品漏斗。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。
Composer / 会话深链仍见 [`landing-hosts.md`](landing-hosts.md) Blocked —— 本版不挖。

**诚实前提：**

- 不伪造 Waiting；Waiting-none 只走 Attention Protocol。
- **不扩** Claude/Codex hook 安装器。
- 托盘无 approve/deny；无额度 HUD；builder 保持纯。

---

## 现状盘点（0.82.0）

| 主题 | 状态 | 0.90 动作 |
| --- | --- | --- |
| Attention Protocol + pulse-hook | 已有 | 漏斗第一步「确保 launcher」与 Claude/Codex 安装拆开 |
| Settings 样本 Write/Clear | 已有 | Reach 聚焦时按 Agent 写样本；复制 raise 命令 |
| Support → Waiting signals 深链 | 已有（0.70） | 落地一屏检查清单，不只橙条 |
| docs/samples/attention-bridge | 仓库样本 | 种子到 Application Support；clear.sh 含 zcode |
| 空态 | 文案 only | 链到 Waiting signals（不是装 Claude hooks） |
| Composer 深链 | Blocked | 明确不做 |

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | Reach 漏斗 UI | Settings → Waiting signals 在 `settingsFocusWaitingSignals` 时显示步骤：确保 pulse-hook → 打开文件夹 → 写样本 → 见红灯 |
| P0-2 | Launcher-only | `ensurePulseHookLauncher()` 只写 `pulse-hook`，不改 Claude/Codex 配置 |
| P0-3 | 聚焦样本 | 有 `settingsFocusWaitingAgent` 时「为该 Agent 写样本」；可复制 raise 命令 |
| P0-4 | 桥接交付物 | `~/Library/Application Support/Pulse/attention-bridge/` 种子 raise.sh + clear.sh（含 zcode） |
| P0-5 | 入口 | Support repair / tray nudge / 空态 深链带上 `focusWaitingAgent`（能推断时） |
| P0-6 | 场景 AC + 测试 | EXPERIENCE；SupportHealth / PulseHook / sample 回归 |

### P1

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | attention-bridge.md | 指向应用内 kit + 漏斗 |
| P1-2 | EXPERIENCE 版本戳 | 对齐 0.90.0 |

### P2

假 stable 插队说明；八门禁对 0.90.0。

### 明确不做

假 Waiting、扩 hooks 安装器、composer 深链、cache→session、额度 HUD、托盘批准、假 1.0。

# 0.64 计划 —— Go-Look Closure / 打断闭环

## 先说这份评估的局限

0.60–0.63 让灯可信（红可达、绿/橙不装假）。本版换轴：**点了通知必须落到
那一行** —— notify → 最佳 Focus → 托盘选中/滚到该行。不碰 Stable Gate /
composer 深链 / 1.0。

无 Apple Developer ID → Stable Gate 仍外部 blocked。

**诚实前提：**

- 不伪造 Waiting；不扩 Agent / hooks；托盘无 approve/deny；无额度 HUD。
- 不承诺 composer / 会话深链；Focus 仍按既有分级。
- Builder 保持纯；0.60–0.63 门闩与 Live Continuity 保留。

---

## 逐项清单（验收时逐一比对）

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | 通知 → 托盘选中 | `rowKey` 经 `focusAgent` 写入 `pendingRevealRowKey`，托盘打开后选中并滚到该行 |
| P0-2 | Store↔Panel 桥 | 一次性 `pendingRevealRowKey`；TrayPanel 应用后清除 |
| P0-3 | EXPERIENCE W + 单测 | 点 Waiting 横幅 / Focus 动作 → 托盘开 → **该行**选中 |
| P0-4 | 多 Waiting 摘要 | 精确 `rowKey`；回退 `rowKeys[0]` 并选中，不 silent smear |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | 软双落点 | Waiting：尝试宿主 Focus **且** 托盘 reveal+select（不因 Focus 成功丢行身份） |
| P1-2 | 「去看看」诚实 | notifFocus 文案对齐「去看 Pulse / 该行」，非假会话深链 |
| P1-3 | 热键 / 最长等待 | `focusFirstWaiting` / `focusOldestWait` / 热键走同一 reveal-select |
| P1-4 | 回归 | Attention、Live stall、native hooks、Glance 优先级 |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Stable Gate 插队 | CHANGELOG：无 Apple ID 不切 stable |
| P2-2 | 能量预算 | 不加深 harvest walk |
| P2-3 | Support（轻） | 可点明 notify→row 闭环已接 |

### 明确不做

假 1.0 / 假 stable、composer 深链、扩 hooks、托盘批准、额度 HUD、伪造 Waiting。

---

## 顺序

P0-2 pendingReveal → P0-1/P1-1 focusAgent → P0-4 摘要 → TrayPanel 应用 →
P1-3 热键/最长等待 → 场景 W → 0.64.0。

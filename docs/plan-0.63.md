# 0.63 计划 —— Live Continuity / 绿灯可信

## 先说这份评估的局限

0.60–0.62 让红灯可达且有门闩。本版换轴：**绿 / 橙不得说谎** —— 混合舰队、
无活动时长、仅进程观测，不能在菜单栏装成健康 Running。不碰 Stable Gate /
composer 深链 / 1.0。

无 Apple Developer ID → Stable Gate 仍外部 blocked。

**诚实前提：**

- 停滞 ≠ Waiting；不伪造 Waiting。
- 不扩 Agent；不扩 hooks；托盘无 approve/deny；无额度 HUD。
- Builder 保持纯；Attention / Hook 0.60–0.62 门闩保留。
- 无时间戳 ≠ 沉默证据（不把未知年龄硬标 stalled 行），但 Glance 不得装健康绿。

---

## 逐项清单（验收时逐一比对）

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | 混合舰队 Glance | `running + stalled` → 橙（stalled 优先于健康绿）；Waiting 仍最高 |
| P0-2 | 停滞钟认 live 信号 | `stalled` / `lastActivity` 取 `max(harvestMs, activityChangedMs)` |
| P0-3 | 薄 Running 不装健康绿 | process-only / `harvestMs==0` 单独在跑 → Glance 橙，不进 healthy green |
| P0-4 | EXPERIENCE V + 单测 | stall-only 橙；混合不绿；信号前进不假停滞；薄 Running 不绿 |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | Support 活动诚实 | 有活动年龄或 unknown；live stalled 可见 |
| P1-2 | Glance 文案 | 最坏非 Waiting 为 stall 时 tooltip/title 带无活动时长 |
| P1-3 | 假阳性边界 | 关 stall 阈值仍生效；Waiting 不双标 stalled |
| P1-4 | 回归 | Attention 身份、Waiting-none、native hooks、Focus |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Stable Gate 插队 | CHANGELOG：无 Apple ID 不切 stable |
| P2-2 | 能量预算 | 不加深 harvest walk |

### 明确不做

额度 HUD、托盘 approve/deny、扩 Agent、扩 hooks、伪造 Waiting、假 stable、
composer 深链、把未知年龄写成假 Waiting、1.0。

---

## 顺序

P0-2 stalled 时钟 → P0-1/P0-3 Glance 优先级 → P0-4 场景 V/单测 → P1 → 0.63.0。

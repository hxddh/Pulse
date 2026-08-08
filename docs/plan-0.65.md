# 0.65 计划 —— Fleet Coverage / ZCode

## 先说这份评估的局限

0.60–0.64 闭环了灯与打断。本版换轴：**舰队诚实扩员** —— 接入 Z.ai ZCode ADE
（Probe + best-effort harvest + Waiting-none），不扩 Claude/Codex hooks，不碰
Stable Gate / composer 深链 / 1.0。

无 Apple Developer ID → Stable Gate 仍外部 blocked。

**诚实前提：**

- 不伪造 Waiting；Waiting-none 只走 Attention Protocol。
- 不扩 Agent 安装器越过 Claude / Codex。
- Builder 保持纯；0.60–0.64 回归保留。

---

## 逐项清单（验收时逐一比对）

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | `AgentID.zcode` | displayName ZCode；`bestEffortCache`；`waitingSource=.none`；app-data opt-in |
| P0-2 | Probe + Host | ProcessProbe 认 ZCode；`HostAppKind.zcode`（`ZCode.app`） |
| P0-3 | Harvest 根 | `~/.zcode` + `Library/Application Support/ZCode`（native + legacy scan） |
| P0-4 | 图标 + Attention | 几何标；`raise-zcode.sh`；样本覆盖全部 Waiting-none |
| P0-5 | 门禁与文档 | README 矩阵、coverage/matrix/harvest_stats、EXPERIENCE/attention-bridge |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | 别名 | `z-code` / `ZCode` → `.zcode` |
| P1-2 | observability | docs + Support 与矩阵一致 |
| P1-3 | 回归 | Attention / Live / Go-Look / hooks |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Stable Gate 插队 | CHANGELOG：无 Apple ID 不切 stable |
| P2-2 | 能量预算 | 有界 walk，不加深 |

### 明确不做

假 Waiting、扩 hooks、composer 深链、假 1.0、额度 HUD、托盘 approve/deny。

---

## 顺序

P0-1 enum → P0-2/3 probe/harvest → P0-4 图标/样本 → 门禁 → 0.65.0。

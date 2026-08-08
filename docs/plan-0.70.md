# 0.70 计划 —— Contract Honesty / 契约诚实

## 先说这份评估的局限

0.60–0.65 Continuity 弧已闭环（Waiting → Hooks → Attention → Live → Go-Look →
ZCode）。本版是**下一章里程碑**：灯已可信，但规格 / Support / 矩阵 / 样本名单
在舰队扩员后仍可能说谎或滞后。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**；不碰
composer 深链。

**诚实前提：**

- 不伪造 Waiting；Waiting-none 只走 Attention Protocol。
- 不扩 Agent 安装器越过 Claude / Codex。
- Builder 保持纯；0.60–0.65 回归保留。
- 未公证包绝不能标 `stable` / Gatekeeper-ready。

---

## 为什么是 0.70 而不是 0.66 / 1.0

| 版本 | 判断 |
| --- | --- |
| **0.70** | Continuity 章收束后的契约章；与 0.50 / 0.60 同级跳跃 |
| 0.66 | 仅文档漂移不够「大版本」 |
| 1.0 | 无公证 stable → 禁止 |

---

## 逐项清单（验收时逐一比对）

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | Waiting-none 单一真源 | `AgentID.waitingNoneAgents`；样本/L10n/Support 派生，不手抄七名单 |
| P0-2 | Support 深度不遮盖 | Waiting-none 仍露出 harvest 深度（cache thin/partial），不把 ZCode 写成「仅 Waiting 不可用」 |
| P0-3 | Attention Reach | Support `openAttentionBridge` 带上该 Agent 名聚焦 Waiting signals |
| P0-4 | 规格对齐 | EXPERIENCE / observability-matrix：**32** Agent；场景 **Y** |
| P0-5 | 诊断与门禁 | safe report 列 waitingNone；matrix_check 拒「31 个用户可见」漂移 |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | About / 通道 | preview · signed 仍明示非 Gatekeeper-ready |
| P1-2 | 回归 | 0.60–0.65 Attention / Live / Go-Look / ZCode |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Stable Gate 插队 | CHANGELOG：无 Apple ID 不切 stable |
| P2-2 | 能量预算 | 不加深 |

### 明确不做

假 Waiting、扩 hooks、composer 深链、假 1.0 / 假 stable、额度 HUD、托盘
approve/deny。

---

## 顺序

P0-1 真源 → P0-2/3 Support → P0-4 文档 → P0-5 门禁 → 0.70.0。

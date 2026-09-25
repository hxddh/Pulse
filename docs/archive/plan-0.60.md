# 0.60 计划 —— Waiting Continuity / 等待连续

## 先说这份评估的局限

0.55–0.59 闭环了「看 → 回 → 落地 → 事实 → 舰队证据 → Limited 有料」。
本版回到产品本职：**红灯（Waiting）在舰队上可达且可信** —— 不扩 Claude/Codex
hook 安装器，不伪造 Waiting，不碰 composer 深链 / Stable Gate。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。

**诚实前提：**

- 不扩 Agent；不扩 hook 安装器越过 Claude / Codex。
- 不伪造 Waiting；托盘无 approve/deny；无额度 HUD。
- `bestEffortCache` **永不**升格为 `.session`；Waiting-none **永不**从 harvest 抬 pending。
- Attention 带明确 session 却对不上时，**不得 smear 到兄弟行**。
- Builder 保持纯。

---

## 逐项清单（验收时逐一比对）

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | harvestPending 审计 | Cline/Roo/Cascade 等：显式 ask/block 字段 + ask tool → pending；`depending` 仍否；Waiting-none 仍不抬 |
| P0-2 | Attention 挂靠身份 | 有 session 且候选均已占用别的 session → 新建 Waiting 行，不点亮兄弟；空 session 进程行可收养；cwd 仅在无 session 时回退 |
| P0-3 | 一键修复路径 | Support/Tray → Waiting signals；样本写/清六 Agent；文案可跟 |
| P0-4 | EXPERIENCE 场景 S + 文档 | AGENTS/attention-bridge/matrix 对齐 0.60 |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | pending 回归矩阵 | depending 否；awaiting_user / ask_followup / askResponse 是 |
| P1-2 | soft-dismiss × harvest pending | 已有 clearedPending 回归保留 |
| P1-3 | 通知带原因 | hooks Waiting 通知含 message |
| P1-4 | isSessionPath 回归 | Pi sessions/、Goose session.json |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Stable Gate 插队 | CHANGELOG：无 Apple ID 不切 stable |
| P2-2 | Focus / Cache / Settings 回归 | 单测绿 |
| P2-3 | 能量预算 | 不加深无界 walk |

### 明确不做

额度 HUD、托盘 approve/deny、扩 Agent、扩 hooks、伪造 Waiting、假 stable、
composer 深链、SIGKILL helper、扫描期 Apple Events。

---

## 顺序

P0-2 Attention 身份门闩 → P0-1 pending 抽取 → P0-3 修复路径文案 →
测试 / 场景 S → 0.60.0。

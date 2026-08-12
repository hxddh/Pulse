# 0.94 计划 —— Waiting Proof / 等待可证

## 先说这份评估的局限

0.90 让 Waiting-none「能写样本见红灯」；0.93 让离开再回「能点名落到行」。
用户 JTBD 仍缺一环：**声称有 Waiting 的路径，真 ask/block 时是否一定亮、清是否一定灭**。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。
Composer 深链仍 Blocked —— 本版不挖。

**诚实前提：**

- 不伪造 Waiting；不扩 hooks 安装器（只 Claude/Codex）；不升格 cache→session。
- harvest pending 只认显式 ask/block / 整词 phase / 厂商旗，不靠子串瞎猜。
- Waiting-none 永不从 harvest 抬 pending；只经 Attention。
- builder 保持纯；无额度 HUD；托盘无 approve/deny。

---

## 现状盘点（0.93.0）

| 主题 | 状态 | 0.94 动作 |
| --- | --- | --- |
| Cline/Roo/Cascade harvest | 0.60 已审 | **举证链** harvest→Waiting→dismiss→再亮 |
| 泛化 `pendingPhase` | 多数 `.harvestPending` | 补显式旗/工具；漏报审计 |
| Attention raise/clear | 样本漏斗已有 | 非样本路径证明 raise→行→clear |
| Waiting-none 在跑 | Support/nudge | 托盘一行可扫到 Reach |
| soft-dismiss / clearWaiting | 可用 | 生命周期与 waitSignal 对齐 |
| Look Closure | 已有 | 保留；本版不扩 |

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | harvestPending 举证矩阵 | Cline/Roo/Cascade（+ Cursor 旗）显式 ask → `skill=pending` → builder Waiting；`depending`/已答/Waiting-none 永不抬 |
| P0-2 | 漏报加固 | 补显式 bool / ask-tool 标记；不靠新子串推断 |
| P0-3 | Attention raise→行→clear | 非样本：raise 精确点亮 → dismiss/clear 熄灭；不 smear |
| P0-4 | Waiting-none 诚实 nextStep | 在跑时托盘可直达 Waiting signals（带 focusWaitingAgent） |
| P0-5 | 清除生命周期 | soft-dismiss 认 `waitSignal=.pending`；`clearWaiting` 只压 harvest pending；自然清除仍 `clearedPendingKeys` |
| P0-6 | 场景 AG + 测试 | EXPERIENCE **AG**；WaitingProof / SnapshotBuilder / Native / Support 回归 |
| P0-7 | 交付物 | plan；CHANGELOG `## 0.94.0`；semver；AGENTS/README；门禁；草稿 PR；**等「发布」** |

### P1

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | EXPERIENCE 版本戳 | 对齐 0.94.0 |
| P1-2 | 更多 cache Agent 形状 | 若现场再报漏报，按同契约补 fixture |

### P2

假 stable 插队；八门禁对 0.94.0。

### 明确不做

假 Waiting、扩 hooks、composer 深链、cache→session、假 1.0、额度 HUD、托盘 approve/deny、Glance「离开有变」大章。

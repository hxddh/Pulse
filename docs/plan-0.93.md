# 0.93 计划 —— Look Closure / 回看闭环

## 先说这份评估的局限

0.92 把行内事实所有权做清，并交了 Look Continuity 指纹——但 notice **只有计数**，
一点即清，不点名、不滚到行。EXPERIENCE AE「什么动了」仍半兑现。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。
Composer 深链仍 Blocked —— 本版不挖。

**诚实前提：**

- 不伪造 Waiting；不扩 hooks；不升格 cache→session。
- Look Closure 只陈述关闭期间**已观测到的变化**，不从 motion 推断 Waiting。
- 复用 Go-Look `pendingRevealRowKey`，不另造深链。
- builder 保持纯；无额度 HUD；托盘无 approve/deny。

---

## 现状盘点（0.92.0）

| 主题 | 状态 | 0.93 动作 |
| --- | --- | --- |
| Look Continuity 指纹 | 已有 | 保留；具名事件 |
| notice | 计数 · 一点即清 | 具名 + reveal |
| Go-Look | Waiting 通知闭环 | notice 复用同一桥 |
| 行级标记 | 无 | 受影响行短暂标记至确认 |
| quiet-live 双份 telemetry | 小残留 | 本版不挖（非回看主题） |

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | 具名 delta | notice 列出 Agent/会话（最多 2–3 +「+N」），不只计数；不发明 Waiting |
| P0-2 | notice → reveal | 点击走 `pendingRevealRowKey`（复用 Go-Look）；优先可揭示行 |
| P0-3 | 优先级 | 新等待 → 已结束等待 → 有变化会话 |
| P0-4 | 行级标记 | 受影响行有短暂「离开后有变」直至确认；不与 Waiting 芯片抢位 |
| P0-5 | 诚实 diff | 只陈述指纹已观测字段；不推断 Waiting |
| P0-6 | 场景 AF + 测试 | close→变→reopen→具名+reveal；单元测试 |
| P0-7 | 交付物 | EXPERIENCE **AF**；plan；CHANGELOG `## 0.93.0`；semver；AGENTS/README；门禁；草稿 PR；**等「发布」** |

### P1

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | EXPERIENCE 版本戳 | 对齐 0.93.0 |
| P1-2 | refresh 后重算 | 若 trayOpen 刷新后指纹仍在，可再应用一次具名 delta |

### P2

假 stable 插队；八门禁对 0.93.0。

### 明确不做

假 Waiting、扩 hooks、composer 深链、cache→session、假 1.0、额度 HUD、托盘 approve/deny、Waiting Proof 大章。

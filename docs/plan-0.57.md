# 0.57 计划 —— Fact Continuity / 事实连续

## 先说这份评估的局限

0.55–0.56 把「点一下能回去、且不吹牛精度」做完了。0.56.1 暴露的真缺口是：
**回去之后托盘行仍可能是空壳**（Claude 有行无事实、幽灵 Settings、假次行）。
composer / 会话深链已在 [`docs/landing-hosts.md`](landing-hosts.md) 标 Blocked——本版不挖。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。

**诚实前提：**

- 不扩 Agent；不扩 hook 安装器越过 Claude / Codex。
- 不伪造 Waiting；托盘无 approve/deny；无额度 HUD。
- 不承诺 composer/tab 深链；不把 Finder「打开目录」冒充 Focus。
- 扫描期不枚举全机 `runningApplications`、不隐式弹 TCC。
- Builder 保持纯。

---

## 逐项清单（验收时逐一比对）

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | Claude 事实硬化：tool_use / cwd / merge + **subagent 目录计数** | fixture：最新 tool、encoded cwd、subRunning/subTotal；无空壳次行 |
| P0-2 | Codex + Cursor 对称审计 | Codex 原生拒绝 tool-arg title；Cursor App Data 下 Goal/cwd/pending 可见，薄则 Limited+nextStep |
| P0-3 | 托盘空壳禁令 | 无动态事实 → 次行省略；无溢出 → 无 gutter；仅进程文案不重复；EXPERIENCE 场景 O |
| P0-4 | Settings 表面根治 | 去掉 SwiftUI `Settings { EmptyView() }`，AppKit-only 启动；更新后 Finder 打开不弹空白窗（场景 P） |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | harvest merge 语义入库 | architecture：session stamp → re-merge、tool 后写覆盖 |
| P1-2 | 高流量 cache 抽检叙事 | matrix：Windsurf/Cascade/Cline/Roo/Warp 薄则 Limited，不升格假 session |
| P1-3 | Support 薄 vs 深一眼可读 | bestEffortCache / waitingSource.none 与 README matrix 一致 |
| P1-4 | EXPERIENCE / AGENTS / plan 对齐 0.57 | 版本指针；场景 O（旗舰事实）与 P（无幽灵 Settings） |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Stable Gate 插队说明 | CHANGELOG：无 Apple ID 不切 stable |
| P2-2 | 标题 / Focus / 0.56.1 回归保留 | 单测绿 |
| P2-3 | 删除死 L10n `noProgressSignal` | 无引用 |

### 明确不做

额度 HUD、托盘 approve/deny、扩 Agent、扩 hooks、伪造 Waiting、假 stable、
composer 深链、SIGKILL helper、扫描期 Apple Events。

---

## 顺序

P0-4 Settings AppKit-only → P0-1 Claude subagents → P0-2 Codex/Cursor 测试 →
P0-3 托盘禁令核对 → P1 文档 / Support → P2 → 0.57.0。

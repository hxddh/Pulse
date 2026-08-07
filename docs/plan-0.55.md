# 0.55 计划 —— Return Continuity / 回到现场

## 先说这份评估的局限

0.54.2 把托盘标题与 Latest 通道做完之后，红灯「抬头」已成立；相对同类产品
（AgentCue / Clyde / claude-status）的最大落差是 **点一下回到正确表面**。
无 Apple Developer ID → Stable Gate 仍外部 blocked，本版不假装公证。

**诚实前提：**

- 不扩 Agent；不扩 hook 安装器越过 Claude / Codex。
- 不伪造 Waiting；托盘无 approve/deny；无额度 HUD。
- Terminal/iTerm 自动化 **默认关闭**，仅显式 opt-in 后才广告 `.tty`。
- 宿主 App 聚焦只用 `NSWorkspace` / 已运行实例 activate，扫描期不枚举全机
  `runningApplications`、不隐式弹 TCC。

---

## 逐项清单（验收时逐一比对）

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | Focus 能力诚实：Support / 行级标明可聚焦 vs 仅观测 | Support 有 Focus 事实；无句柄行不画成按钮 |
| P0-2 | 通知 / 「跳到等待」路径审计：有句柄则 focus，否则托盘 | 单测或代码路径明确；不静默失败 |
| P0-3 | 无 TCC 宿主聚焦：Cursor / VS Code / Windsurf / Zed / Trae 等 `NSWorkspace` | `FocusTier.hostApp`；Warp 保持 |
| P0-4 | `architecture.md` 会话预算 500/500；EXPERIENCE 英雄/Focus 文案对齐实现 | 文档与代码一致 |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | Settings 显式 opt-in「允许聚焦 Terminal / iTerm 标签」 | 默认 off；开启后才返回 `.tty` |
| P1-2 | Waiting / 行动作文案分级：Focus Warp / Focus 宿主 / Focus TTY / 仅打开托盘 | L10n；不可聚焦不伪装按钮 |
| P1-3 | 设置里 Automation 说明；与快捷键同区 | 文案诚实提可能弹 TCC |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Attention 桥六 Agent 示例脚本（replit/devin/warpAgent/trae/antigravity/junie） | `docs/samples/attention-bridge/` + attention-bridge.md 链 |
| P2-2 | 标题边角：与 tool 同名 / 文件名过滤回归单测保留并补 host 标题 | 单测绿 |
| P2-3 | Stable Gate 插队说明：无 Apple ID 时本版不切 stable | CHANGELOG / plan 写明 |

### 明确不做

额度 HUD、托盘 approve/deny、扩 Agent、扩 hooks、伪造 Waiting、假 stable、
SIGKILL helper、扫描期 Apple Events。

---

## 顺序

P0-3 宿主聚焦 → P0-1/P0-2 诚实与路径 → P1 Automation → P1 文案 → P0-4 文档 →
P2 样本与 CHANGELOG → 0.55.0 发版准备。

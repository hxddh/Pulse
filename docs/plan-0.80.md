# 0.80 计划 —— Tray Legibility / 托盘可读

## 先说这份评估的局限

0.70 收了契约漂移。用户反馈：**下拉托盘里每个 Agent 行有效信息太少**。
Continuity 把假 Waiting / 假进度 / 空 chrome 砍干净后，矫枉过正——动态事实
（tokens、模型、最近动作、开始时间）仍进 Details / a11y，默认行扫不到。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。

**诚实前提：**

- 不伪造 Waiting / 进度占位；无事实则整行消失。
- 不发明 goal / tool；不升格 cache→session。
- 无额度 HUD、无托盘 approve/deny、不扩 hooks。
- Builder 保持纯。

---

## 根因（不是缺 harvest）

| 层 | 现状 |
| --- | --- |
| Harvest / `AgentRow` | tokens、model、tool、subagents、progress 常有 |
| `rowObservationLine` | 已算，但 **`AgentRowButton` 不渲染** |
| `rowSignalLine` | 生命周期+变化+稳定事实挤 **1 行 · prefix(3)**，tokens 常被挤掉 |
| `usefulAction` | 拒绝 Bash/Shell/exec —— 与 EXPERIENCE「最近动作：执行命令」冲突 |
| Session age | 有动态证据时常隐藏「始于…」 |

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | 默认渲染观测行 | `AgentRowButton` 在信号行下画出 `rowObservationLine`（有数据才出现） |
| P0-2 | 观测行合同 | 最多 4 事实：model[/mode] · tokens · 最强进度/子任务/错误 · records；与 EXPERIENCE 示例对齐 |
| P0-3 | 信号行只谈运动 | lifecycle + change（+ 停滞/进程龄）；**不**再与观测抢 model/tokens |
| P0-4 | 次行补全 | Bash 类人话「最近动作」；`始于…` 在 1m–24h 可见 |
| P0-5 | 子任务芯片 | `subTotal>0` 时可见（不仅 `subRunning>0`） |
| P0-6 | 场景 Z + 门禁/测试 | EXPERIENCE **Z**；ResourceLookupTests 对齐新 IA |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | 富 Limited cache | goal+cwd/tool 时次行+观测不空壳 |
| P1-2 | compact 模式 | 有事实时不砍观测行；标题仍最多 2 行 |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Stable Gate 插队 | 无 Apple ID 不切 stable |
| P2-2 | 删死 private 或接线 | `metrics`/`nowLine`/`activityChange` 仅服务 a11y/观测，不制造第三套叙事 |

### 明确不做

Stat strip / 卡片 / 行底色编码、假 Waiting、额度 HUD、Details 才见核心运动事实、
扩 hooks、composer 深链、假 1.0。

---

## 顺序

P0-2/3 重建行合同 → P0-1 UI → P0-4/5 次行/芯片 → 测试/场景 Z → 0.80.0。

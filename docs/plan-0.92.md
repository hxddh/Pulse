# 0.92 计划 —— Row Clarity / 行清晰

## 先说这份评估的局限

0.91 给了默认行一句叙事，但**没有事实所有权**：story / 次行 / 信号 / 芯片 /
等待详情 / Limited 身份标签仍会互相复述。用户感到「信息变多了，却更吵」。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。
Composer 深链仍 Blocked —— 本版不挖。

**诚实前提：**

- 不伪造 Waiting；不扩 hooks；不升格 cache→session。
- last tool 永不冒充 Now；story 可引用「最近动作」但须标明历史。
- builder 保持纯；无额度 HUD；托盘无 approve/deny。
- Look Continuity 只陈述关闭期间**已观测到的变化**，不推断 Waiting。

---

## 现状盘点（0.91.0）

| 主题 | 状态 | 0.92 动作 |
| --- | --- | --- |
| `rowStoryLine` | 已有，但与次行/信号叠 | 事实所有权：story 占叙事 |
| Waiting 芯片 + story + 详情 | 种类·时长·来源三重 | 芯片 / 详情分工 |
| Limited 身份 + story | `observationQualitySummary` 双份 | 只出现一次 |
| Look Continuity | 仅 resolved-wait 计数 | 关闭指纹 → 重开「什么动了」 |
| Details | 无 story / Changed | 与托盘叙事对齐 |
| 仅进程 / 薄 cache | 套话摘要 | age · 最强事实 · nextStep |
| 拥挤 ≥5 | story `lineLimit(1)` | 叙事优先可读 |

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | 事实所有权 | Story 拥有 phase / 工具 gist / Changed；次行 = 路径·年龄（story 已有则不再「最近动作」）；信号在 story 已带 Now/Changed 时让位 |
| P0-2 | Waiting / Limited 去重 | Waiting：芯片 = 种类·时长；等待详情 = 消息优先；Limited 质量摘要只出现一次（身份**或** story） |
| P0-3 | Look Continuity | 托盘关闭打指纹；重开回答「离开后什么动了」（超出 resolved-wait 计数） |
| P0-4 | Details 对齐 | 详情审视器展示同一 `rowStoryLine` + Changed |
| P0-5 | 不透明可观测 | cache/process story = 证据年龄 · 最强事实 · nextStep；仍 Limited；不伪造 Now/Waiting；不升格 session |
| P0-6 | 拥挤优雅 | ≥5 行优先可读 story；删死 props；子任务芯片本地化；Settings Reach 滚到 Waiting；空态可推断时带 `focusWaitingAgent` |
| P0-7 | 交付物 | EXPERIENCE **AE**；反重叠测试；本 plan；CHANGELOG `## 0.92.0`；semver；AGENTS/README；门禁；草稿 PR；**等「发布」再 release** |

### P1

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | EXPERIENCE 版本戳 | 对齐 0.92.0 |
| P1-2 | 指纹字段扩展 | 若后续需要 tokens/progress 细粒度，再扩 |

### P2

假 stable 插队；八门禁对 0.92.0。

### 明确不做

假 Waiting、tool→Now、扩 hooks、composer 深链、cache→session、假 1.0、托盘 approve/deny、额度 HUD。

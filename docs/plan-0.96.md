# 0.96 计划 —— Return Truth / 回看诚实

## 先说这份评估的局限

0.94/0.95 把 Waiting 亮灭做实。用户 JTBD 下一环：**离开再回时，灯和 notice 必须说真话**。
0.93 交了具名 Look Closure，但刷新后再算、等待世代、Glance 宽预算仍假。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。
Composer 深链仍 Blocked —— 本版不挖。

**诚实前提：**

- 不伪造 Waiting；不扩 hooks；不升格 cache→session。
- Look 只陈述指纹已观测字段；新等待世代优先于「已结束」。
- builder 保持纯；无额度 HUD；托盘无 approve/deny。

---

## 现状盘点（0.95.0）

| 主题 | 缺陷 | 0.96 动作 |
| --- | --- | --- |
| Look 时机 | `trayDidAppear` 刷新前用旧 `cachedAll` | 扫描完成后再算 |
| 等待世代 | 指纹无 `waitSinceMs` | 同行新等待优先 |
| ended+moved | 结束等待再进「有变化」 | ended key 不双计 |
| Glance 宽 | ≤8 显示宽未实现 | 超限降级数量/时长 |
| 样本 Go-Look | 写完立刻在旧行上 reveal | 行出现后再点名 |
| 进程收养 | 不改 rowKey，下一拍丢 snooze | 收养即重键并迁移 |
| Attention 80 行 | 未决 raise 被挤掉 | 压缩保留未决 |
| Details / 行 | 缺口截断、Changed/观测双份 | 可行动缺口优先；去重 |

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | 刷新后重算 Look | `trayOpen` 扫描完成后再 `applyLookContinuity` |
| P0-2 | 等待世代 | 指纹含 `waitSinceMs`；同 key 新等待优先于 ended |
| P0-3 | ended 不双计 | ended 的 key 不再进 moved |
| P0-4 | Glance 宽预算 | 显示宽 >8 降级 `1 · 4m` / `1`；Idle 仍空；`Claude…` 仍可 |
| P0-5 | 样本 raise 闭环 | 样本行出现后再 `requestTrayReveal(rowKey:)` |
| P0-6 | 场景 AI + 测试 | EXPERIENCE **AI**；ReturnTruth 回归 |
| P0-7 | 交付物 | plan；CHANGELOG；semver；AGENTS/README；门禁；草稿 PR；**等「发布」** |

### P1

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | 进程→session 重键 | Attention 收养即 `sessionKey`；snooze/dismiss/ledger 迁移 |
| P1-2 | Attention 压缩 | 80 行上限保留未决 raise（无 done 不挤掉） |

### P2

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Details 缺口 | 可行动 `use_attention_bridge` / `enable_app_data` 优先于 truncation |
| P2-2 | quiet 行 | story 不重复 observation 的 model/tokens |
| P2-3 | cache 标签 | story 不再复述 identity 的 Local cache |
| P2-4 | Details Waiting/Changed | story 已有 Changed 则不另起一句；Waiting 卡只留一条理由 |

### 明确不做

假 Waiting、扩 hooks、composer 深链、cache→session、假 1.0、额度 HUD、托盘 approve/deny、行叙事大改、Windsurf 产品身份合并。

# 0.91 计划 —— Row Story / 行叙事

## 先说这份评估的局限

0.80–0.82 让字段可见；0.90 让 Waiting-none 可打断。用户仍说「缺少有效信息」——
根因已换：**行在列遥测，不在讲「这个会话在干什么」**。再挖 harvest 收益变薄。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。
Composer 深链仍 Blocked —— 本版不挖。

**诚实前提：**

- 不伪造 Waiting；不扩 hooks；不升格 cache→session。
- last tool 永不冒充 Now；story 可引用「最近动作」但须标明历史。
- builder 保持纯；无额度 HUD；托盘无 approve/deny。

---

## 现状盘点（0.90.0）

| 主题 | 状态 | 0.91 动作 |
| --- | --- | --- |
| 观测行 model/tokens | 已有 | 保留；不替代叙事 |
| Quiet live 空 Now | 诚实但像「没干活」 | story 回落最近动作·观测 |
| `activityChange` | 无 tool/phase/task | 纳入 Changed |
| 仅进程 / 薄 cache | 检测套话 | story = 证据 + 下一步 |
| 默认行 IA | 多行碎字段 | 插入一句 `rowStoryLine` |

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | `rowStoryLine` | 有话才出现；Waiting / 进程 / 薄 cache / quiet live / 有 phase 各有诚实合成 |
| P0-2 | Changed | tool / phase / task 变化进入 `AgentActivityChange` 与信号行 |
| P0-3 | 托盘接线 | `AgentRowButton` 在 hero 与次行之间渲染 story；a11y 纳入 |
| P0-4 | 场景 AD + 测试 | EXPERIENCE；ResourceLookup + SnapshotBuilder |
| P0-5 | 版本 / 文档 | 0.91.0；CHANGELOG；plan 指针 |

### P1

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | Look Continuity 指纹 | 可选：托盘关闭快照（若时间紧可延后） |
| P1-2 | EXPERIENCE 版本戳 | 对齐 0.91.0 |

### P2

假 stable 插队；八门禁对 0.91.0。

### 明确不做

假 Waiting、tool→Now、扩 hooks、composer 深链、cache→session、假 1.0。

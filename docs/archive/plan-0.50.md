# 0.50 计划 —— Signal Quality / 有效观测

## 先说这份评估的局限

第三方报告建议下个版本定为 0.50.0「Signal Quality」。主题正确，但报告按绿地清单
写了 Waiting、权限、安装、检查器等条目——那些在 0.49.0 / 0.49.1 已经交付。

**这一版的诚实前提：**

- 0.49.1 完成了可靠性闭环（bounded harvest、Waiting 账本、Support Health、
  事务更新、按 Agent 权限）。
- 0.50.0 不再扩 Agent 名单，而是让现有 31 个 Agent 更深、更可信、更可操作。
- 报告里已交付的能力只做加固验收，不重做。

读代码能发现「没接线」；截图才能发现「看起来不对」。P1 托盘/检查器视觉项
仍以真机截图为最终验收。

---

## 现状盘点（0.49.1）

| 报告主题 | 状态 | 0.50 动作 |
| --- | --- | --- |
| 31 Agent 采集隔离 / schema 2 | 已交付 | 加固 + fixture |
| Support Health / 检查器 / 人类语义 | 已交付 | P1 能力卡片加深 |
| Waiting 账本 / 并发 / 通知去重 | 已交付 | 详情时间线补齐 |
| 托盘搜索 ≤128 / 默认 12 行 | 部分 | 索引扩展到 500 |
| 「Limited data」无解释 | 部分 | 质量信封驱动文案 |
| 异常退出提示 | 有，二元且会话内不消失 | 分类 + 可消失 |
| `/Applications` 单副本 | 大部分 | zig-out / 回滚身份 |
| 默认不弹权限 / 按 Agent 说明 | 已交付 | 定向重扫 |

真正撑起 0.50.0 的五件事：

1. 命名观测质量信封（facts / missing / freshness / confidence）
2. 会话索引扩展到可搜 500 + 筛选 / 分页
3. 退出原因分类 + 健康启动后可消失的恢复提示
4. 权限变更后只重扫受影响 Agent
5. 当前 App / zig-out / 回滚副本身份澄清

---

## P0 · 必须完成

### P0-1 观测质量信封

**缺口**：行上已有 task / workspace / phase / model 等字段，但没有命名结构把
「有什么 / 缺什么 / 多新鲜 / 多可信」绑在一起。托盘仍会出现无解释的
Limited / Process only。

**做法**：

- `ObservationQuality`：`facts`、`missing[(key, reason, nextStep)]`、
  `freshnessMs` / `freshnessSource`、`confidence`（high / medium / low）
- 由 `NativeActivityHarvest` 构行时填充；UI 用信封驱动文案，禁止无原因空洞
- 15 个 `bestEffortCache` Agent：专项适配 + 真实 fixture；缺口必须写 `missing`

**验收**：有观测的 Agent 至少展示有效任务、工作区、活动、证据，或 missing
带原因；不再出现无解释的 Limited data。

### P0-2 全量会话索引

**缺口**：ingest 256 / retain 128 / glance 12。搜索只覆盖 retain 窗口；
无独立 Agent / 阶段 / 结果筛选；详情检查器绑在 glance 的 `snapshot.rows`。

**做法**：

- glance 仍 12 行；搜索可见上限提到 500/Agent，分页或按需加载
- 压力夹具：4 / 20 / 100 / 500
- 显示「全部 N」；增加 Agent / 阶段 / 结果筛选
- 详情解析搜索命中行时不依赖 glance 窗口

**验收**：500 会话可搜；100 不丢；托盘 glance 仍轻量。

### P0-3 Waiting 与恢复提示闭环

**缺口**：`LaunchRecovery` 只有 `cleanShutdown` 二元；横幅会话内不消失；
Waiting 详情未完整展示账本时间线。

**做法**：

- 退出类别：`crash` / `forceQuit` / `systemRestart` / `updateReplace` / `unknown`
- 正常更新替换不报异常退出；健康启动或用户关闭后横幅清除
- Waiting 详情：queued / notified / ack / snooze / resolved + 阻塞原因 +
  通知状态 + 下一步

**验收**：一次正常重启后无异常退出误报；10 个同时 Waiting 不丢、不重复、
重启后状态不丢。

### P0-4 单安装副本保证

**缺口**：`InstallTruth` 扫 `/Applications` 与 `~/Applications`，不区分
zig-out 构建产物与回滚库身份。

**做法**：

- 分类：`currentInstalled` / `buildArtifact` / `rollback` / `orphanDuplicate`
- 更新成功清理可见旧副本；失败可恢复（沿用事务路径）
- 构建产物标为开发构建，不擅自删除用户开发目录

**验收**：更新前后 `/Applications` 只有一个用户安装 Pulse。

### P0-5 权限体验

**缺口**：`setAppDataAccess` 触发全量 `refresh`。

**做法**：只调度受影响 Agent 的 supervisor 刷新。保持默认永不弹权限、
拒绝后不循环索取、设置说明读什么 / 多什么 / 跳过留什么。

**验收**：权限变化后只重扫受影响 Agent；不重复索取。

---

## P1 · 显著提升产品力

- Agent Details 升级为会话检查器：阶段时间线、模型、进度、错误、文件、
  等待证据、数据新鲜度
- Tool / Skill 默认人类语义；原始名只在诊断层
- 托盘布局：长中文、深浅色、VoiceOver、键盘导航
- 「最近变化」表面统一
- 状态栏灯可解释提示（为什么橙/红、持续多久、谁最优先）
- Support Health 按 Agent 能力卡片，不只状态枚举

---

## P2 · 长期稳定性和发布

- 31 Agent × 权限拒绝、损坏 JSON、锁库、超时、睡眠唤醒、崩溃恢复、
  100+ 会话的 CI 矩阵
- 资源 / CPU / 内存 / 扫描耗时 / 通知延迟预算纳入回归门禁
- 安全诊断包：字段覆盖率、采集失败时间线、协议版本、权限状态（继续脱敏）
- 保持 preview / ad-hoc；有 Developer 账户后切 stable
- 真实 SwiftUI 截图回归；不引入 Figma 作为前置

---

## 验收标准

- 31/31 Agent 都有运行态健康结果
- 每个有观测的 Agent 至少展示有效任务、工作区、活动、证据；缺失字段有原因
- 500 个会话仍可搜索，100 个会话不丢失
- 10 个同时 Waiting 不丢通知、不重复通知、重启后状态不丢
- 一次正常重启后不再出现异常退出提示
- 更新前后 `/Applications` 只有一个 Pulse
- 浅色、深色、中文、VoiceOver 和键盘导航均通过截图/自动化验收

---

## 明确不做

- 额度 / 费用 / reset HUD
- 托盘内批准 / 拒绝
- 后台远程账号体系
- 桌面宠物和纯装饰动画
- 继续扩 Agent 名单（本版冻结 31）

---

## 顺序

P0-1（质量信封）是主干——Limited 文案、cache fixture、健康度卡片都依赖它。
P0-2（会话索引）与 P0-3（退出/Waiting）可并行。
P0-4、P0-5 独立，可并行。
P1 / P2 在 P0 验收后推进。

版本号与 CHANGELOG `## 0.50.0` 在功能可验收时再写；发布门禁拒绝无该段的发布。

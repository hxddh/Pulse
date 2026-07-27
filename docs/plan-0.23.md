# Pulse 0.23.0 计划 — 「可信」

基线：0.22.0（已发布，`v0.22.0` @ `ba1ef1f`）。

## 主张

0.22.0 是一次大投放：能耗重构 + 10 项产品缺口 + 全部审计修复，约 2,500 行改动。
但它们全部压在一个 **382 行、零测试覆盖** 的核心（`StatusStore.applyScan`）上。

现有 55 个测试覆盖的是外围 —— 解析器、节奏策略、格式化。核心一行都没测到：

| 符号 | 测试引用数 |
| --- | --- |
| `applyScan` | 0 |
| `matchAttentionRow` | 0 |
| `recordResolvedWaits` | 0 |
| `loadSettings` / `saveSettings` | 0 |

**0.23 的任务是让 0.22 的承诺可验证，不是继续加功能。** 在未测试的核心上叠功能，
是在复利式地积累风险。本版本不引入新的用户可见能力（修好一个已损坏的除外）。

---

> **进度**：P0 全部完成 —— P0-1 / P0-2 共 57 个新测试（全量 107），
> P0-3 由仓库转 public 解决。下一步是 P1。

## P0 — 必须

### 1. 把 `applyScan` 变成可测的，然后测它 — ✅ 已完成

**为什么是它。** 它是整个产品的逻辑所在：多会话去重、每 Agent 上限与 `hiddenSessions`
记账、live 进程只挂一行、cursor/cursorAgent 合并、attention 匹配、Waiting 边沿、
通知边沿、等待历史、排序、glance 编码。`docs/review-0.21.md` 把它列为最高回归风险，
0.22.0 没有动它。

**为什么现在测不了。** 它只改 5 个状态（`cachedAll` / `snapshot` / `knownWaitingKeys` /
`lastAppliedTicket` / `lastProcessSignature`），但埋着 6 类副作用：

| 副作用 | 后果 |
| --- | --- |
| `Date()` | 非确定性 |
| `TerminalFocus.Environment.current()` | 枚举运行中应用 |
| `FileManager.fileExists` | 读磁盘 |
| `PulseNotify.post*` | 真发系统通知 |
| `rescheduleTimer()` | 起定时器 |
| `DebugLog.write` | 写磁盘 |

加上 `fileprivate` + `@MainActor` + 经 `AppServices.store` 单例回调，测试无从下手。

**做法。** 抽出 `SnapshotBuilder`（纯函数）：

- 注入 `nowMs`、`TerminalFocus.Environment`、`pathExists` 闭包、`lang`、相对时间串；
- **返回意图而非执行**：`newlyWaiting` / `resolvedWaits` / `wentIdle` / `debugNotes`，
  由 `StatusStore` 外壳按设置（安静时段、静音、开关、seeded）决定发不发通知；
- `dismissedPendingKeys` 的清除改为返回 `clearedPendingKeys`，由外壳应用。

`StatusStore` 退化成薄壳：拥有定时器、I/O、通知与设置，调用 builder。

**已交付：** `SnapshotBuilder.swift`（纯函数，`Context` 注入外部世界，
返回边沿意图而非直接执行）+ 34 个测试。`applyScan` 381 → 115 行。
数据流见 [`architecture.md`](architecture.md)。

**覆盖：** 多会话去重与 key 唯一化 · 每 Agent 上限与 `hiddenSessions`
只记在首行 · live 进程只挂一行不涂抹 · cursor/cursorAgent 合并 · attention 按
session / cwd / 兜底三级匹配 · 陈旧 harvest 丢弃 · pending → Waiting 与软忽略 ·
Waiting 边沿（首扫只播种不通知）· idle 边沿 · harvest fresh/skipped/failed 三态 ·
等待历史记录 · 排序（Waiting → 有标题 → live → recent → 优先级）· glance 四态编码。

### 2. 设置读写 + 迁移的测试 — ✅ 已完成

0.22 把安静时段从整点改成分钟，附带一段 hours → minutes 迁移逻辑 ——
**零测试，且在每个老用户升级后的首次启动上跑一次**。错了就是静默丢掉用户配置，
且不可逆。

**已交付：** `PulseSettings.swift`（值 + 解析 + 序列化 + 安静时段判定，
全部不碰 Application Support）+ 23 个测试。

覆盖：旧版整点文件正确迁移 · 分钟键优先于遗留键（22:30 不会退回 22:00）·
0.22 写出的文件不重复迁移 · 完整往返是恒等 · `mute` 列表丢弃未知 agent ·
枚举解析失败回落默认 · 非数字分钟保留默认而非归零 · 垃圾行只损失自己 ·
解析与序列化两端都 clamp · 安静时段半开区间且可跨午夜。

### 3. 更新检查目前是永久失败状态 — ✅ 已解决

仓库曾是 private，而 `UpdateCheck` 发的是匿名请求，GitHub 对匿名请求返回 404，
于是每个用户的「关于」面板都长期显示「检查失败 · HTTP 404」——
比没有这个功能更糟，它看起来像 bug。

**解法：仓库已转 public**（2026-07-27）。`releases/latest` 现在匿名可读，
功能无需改一行代码即生效。

私有部署仍可用 `Info.plist` 的 `PulseUpdateFeed` 指向可匿名访问的 feed。

---

## P1 — 应该

### 4. 能耗埋点

0.22 CHANGELOG 里「28,800 → 2,880 次/天」是**算出来的，不是测出来的**。
既然已经写进公开的 Release 说明，就该让它自证：诊断信息增加
「过去一小时 N 次 probe / M 次 harvest / harvest 平均耗时 / 停表时长」。
成本极低，同时让 bug 报告有用得多。

### 5. VoiceOver 中文

`GlanceKind.accessibilityLabel` 仍是硬编码英文（`Idle` / `Running` /
`Needs attention` / `Error`），中文用户的旁白读到的是英文。顺带审一遍其余 a11y 串。

### 6. 合并到 main

`release.yml` 不在默认分支，所以 `workflow_dispatch` 不可用，三条触发路径只有两条真正
能走。合并后应把 release 触发的分支范围从 `**` 收窄。

---

## P2 — 可选

### 7. 签名与公证

把 Developer ID 放进仓库 secret（`PULSE_SIGN_IDENTITY` / `PULSE_NOTARY_PROFILE`），
完整跑通一次公证链路。现在 DMG 是 ad-hoc，别人要右键打开。

### 8. harvest 调试通道

`activity_scan.py` 有 32 处 `except Exception` 静默吞异常，导致
「为什么 Cursor 没显示」根本无法排查。加 `PULSE_HARVEST_DEBUG=1`，
报告每个采集器找到了什么、在哪一步放弃。

---

## 顺带发现（本次评估中新看到的）

- **`headerDetail` 永远显示「刚刚」。** `snap.updatedAt = Date()` 之后立刻
  `relative(snap.updatedAt)`，差值恒 < 5 秒，所以永远落在 `justNow` 分支。
  EXPERIENCE.md §4 写的「下行仅相对时间」实际上是一个常量。
  修法要么让 tray 打开时重算，要么承认它不携带信息并移除。
  **这正是一个 builder 测试会立刻抓到的东西** —— 算作 P0-1 的佐证。

---

## 明确不做

| 项 | 理由 |
| --- | --- |
| 远程 / devcontainer agent 可见性 | 真正的能力边界（Pulse 只看本机进程与文件），`attention.tsv` 已是现成抓手，但改动大，等核心有测试再说 |
| 托盘内 approve / deny | `AGENTS.md` 写死的非目标 |
| 继续扩 agent 名单 | 32 个已超出可验证范围 |
| 配额 / 费用 HUD | `EXPERIENCE.md` 非目标 |

---

## 验收

- `swift test` 覆盖 `SnapshotBuilder` 全部分支，`StatusStore` 只剩 I/O 与策略 ✅；
- 设置迁移有测试，老用户升级不丢配置 ✅；
- 「关于」面板不再对所有人显示永久错误 ✅；
- CHANGELOG 的能耗数字可由用户自己粘贴的诊断信息佐证。

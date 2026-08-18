# 2.2 基线深度 review

> 上一份是 `docs/review-1.2.md`，它列的 13 项缺陷已在 2.2 全部关闭。这份是在
> **2.2.0（`1d60ac3`）** 的代码上重新做的一遍，每一条都给了 file:line，并且都是
> 在当前代码上复核过的，不是从旧结论顺延下来的。
>
> 结构债 S1（声明式 adapter 契约）与 S2（StatusStore 拆分）仍然开着 —— 它们不是
> 缺陷，是下一个新轴的先决条件。S2 这一版又长了：1.2 时 4548 行，2.2 时 4896 行。

---

## 一句话

**这一轮找到的东西有一条共同的形状：产品在它没测到的地方说了话，或者在它该说话的
地方沉默。** 七条里有三条是「说了没测到的数」，两条是「点了没反应」，一条是
「答应做的事没做」，一条是「最该保护的文件保护得最差」。

---

## D-1 · 一半没测到的 token 被写成 0

`StatusStore.swift` 六处，形如 `input.isEmpty ? "0" : input`。

`AgentRow.compactToken(0)` 返回 `""`（Models.swift:999），而六个调用点又把这个 `""`
翻译回字面量 `0`。于是一个只上报 output token 的厂商，行上写的是 `↑0 ↓4.2k` ——
**声称这一轮消耗了零个输入 token**，而这个数字没有任何东西测过。

这正是 2.2 刚给 CPU 立的规矩（「未知是 -1 不是 0；『测到了它闲着』与『还没采到』是
两个答案」）的同一类违反，而且发生在产品里被看得最多的那一行。

**修法**：一个 `tokenPair(input:output:scope:)`，只印测到的那一半；两半都没有整条
事实消失。三种语域（`compact` / `reported` / `latestCall`）各自多两句单边措辞 ——
**不能为了省事把语域丢掉**，「最近一次模型调用」和「整场累计」是两个数，2.1 专门
为此把它们分开写过。

## D-2 · 会话错误数在行动起来时整个消失

`StatusStore.swift` `rowObservationLine` / `rowSignalLine` / `rowStoryLine`。

三处条件叠在一起，凑出一个洞：

1. 观测行的**故障层**（第 1 层，最高优先级）条件是 `change == nil` —— 行上只要有
   任何变化就整层让位；
2. 让位的对象是信号行的「紧急伴随」，可它嵌在 `if !changed.isEmpty` 里面，而
   `changed` 被 `storyOwnsChange(row)` 清空 —— 那个函数对**每一个有真实标题的行**
   都返回 true，也就是绝大多数行；
3. 叙事行 `rowStoryLine` 接管了变化，但它从头到尾**不提 errors**。

结果：一个有 7 次会话错误、同时工具刚变过的普通会话，**三行里一行都不说**。故障之所以
排在第 1 层就是因为它不该被运动挤掉，而它恰恰只在会话活跃时消失。

顺带：信号行的伴随只认 `row.errors`（读窗口内），不认 `row.sessionErrors`（整场），
所以即便它能跑，也看不见窗口外的错误。

**修法**：故障只有**一个**归属 —— 观测行。唯一的例外是 process-only 行（它根本没有
观测行），由信号行接。唯一的抑制条件是「变化本身就是错误变化」，那时增量是新闻，
再报总数就是同一件事说两遍。

## D-3 · 合并掉的 refresh 把 agentFilter 丢了

`StatusStore.swift` `refresh(reason:agentFilter:)` / `finishScanFlight()`。

扫描在飞时，第二个 refresh 只把 `reason` 存进 `pendingRefreshReason`，重放时调用
`refresh(reason:)` —— **scope 没了**。而 scoped 重扫存在的理由，代码自己的注释写得
很清楚：「Permission toggles force the affected Agent(s) even if the supervisor
would otherwise defer them.」

所以：在扫描进行中打开某个 Agent 的数据源开关 → 重放成全量扫描 → supervisor 照样
把它 defer 掉 → **那个 Agent 要等退避到期才会被读**。用户看到的是「我开了，然后
什么也没发生」。

**修法**：pending 请求带上 filter 并正确合并 —— 两个 scoped 请求取并集，任何一个
全量请求吸收掉 scoped 的。

## D-4 · 装着用户自己的话的两个文件，是权限最松的

- `AttentionLedger.save()` —— 写临时文件（进程 umask，Mac 上 0644）后 `replaceItemAt`，
  **全程没有设置过任何 mode**。而这个文件存的是 session **标题**（`row.usefulTask`，
  最长 160 字，就是用户自己写的话）、项目名、等待种类。
- `AttentionIO.swift:262` —— `attention.tsv` 以 `O_CREAT, 0o644` 创建；
  `src/pulse_hook.py` 那侧是 `path.open("a+")`，同样 0644。这个文件存的是 agent 请求
  执行的**命令**和它所在的**目录**。

同一个目录下的 respond spool 一直是 0600，session digest 在 2.2 刚被修成
「从第一个字节起就是 0600」，而 digest 按设计只存计数与厂商工具名 —— **存散文最多的
两个文件，保护最弱。**

**修法**：抽出 `PrivateFile`，三处共用；`attention.tsv` 改 0600 创建，并通过已经拿在
手里的 fd 把老文件 `fchmod` 下来（创建模式管不到已存在的文件，而不加迁移就等于永远
不生效）；别人拥有的文件一律不动。Swift 与 Python 两侧同步改。

## D-5 · 启动时永远不知道屏幕已经锁着 / 显示器已经睡了

`ProbeSchedule.swift` `Power.current` 把 `displayAsleep` 与 `screenLocked` 硬编码成
`false`，而 `PowerMonitor.start()` 用它做初值（PowerMonitor.swift:8,17）。

于是 Pulse 在**锁屏状态下重启**（崩溃恢复、更新替换、无头 Mac），永远不会 park ——
能告诉它的那条通知已经发过了，接下来会到的是 `screenIsUnlocked`，而那正是本该恢复
轮询的时刻。省电是 EXPERIENCE 里的**硬约束**（「常驻菜单栏工具被系统标记为耗电大户
等于定位破产」），这条路径直接绕过了它，而且崩溃恢复与更新重启恰好是没人看着的两条。

**修法**：启动时问真实状态（`CGDisplayIsAsleep` / `CGSessionCopyCurrentDictionary`），
两个查询都 fail 回今天的假设 —— 无头 runner、拿不到 session 字典、显示器不可用，都
是「照旧」，不会凭空 park。

## D-6 · 写不出去的判决什么都不说

`StatusStoreRespond.swift` `writeRespondVerdict`。

`decide()` 拒绝（`canOfferAllow` 为假）或 `RespondSpool.writeVerdict` 失败（缺逐 host
密钥、磁盘错误）时，唯一的出口是 `DebugLog.write`。界面**没有任何变化**。

「拒绝」这个按钮，产品文档里写的是**永远可用**，因为拒绝没读全的东西是安全的。一个
静默失败的拒绝按钮，和一个坏掉的按钮长得一模一样。场景 AR 要求「判决送达与否 Pulse
不谎报」—— 什么都不说没通过同一条测试。

**修法**：三种失败各给一句人话，仍然 fail-open（远端回到厂商自己的提示，句子里就
这么写）。

## D-7 · 失败的 Focus 和坏掉的按钮长得一样

`StatusStore.swift` `primaryAction` / `focusTerminal` —— `TerminalFocus.focus(row:)`
**返回了它到底有没有够着**，两个调用点都 `_ =` 扔掉。

焦点句柄是产生这一行的那次扫描推导出来的，窗口可能在扫描与点击之间关掉、工作区可能
被移走、Shortcuts 自动化可能被撤销。这时行**提供了**这个动作，点下去毫无反应。

**修法**：够不着就说一句，并触发一次重扫 —— 下一行要么带一个能用的句柄，要么干脆
不再提供这个动作。

## D-8 · `rowSignalMetric` 尾部是永远跑不到的第二套事实排序

`StatusStore.swift`。它唯一的调用点在 `rowSignalLine` 的 `if row.isStalled` 里面，而
函数体第二个分支就是 `if row.isStalled { return ... }` —— **之后的三十行没有任何输入
能到达**。

那三十行是 `errors → outcome → progress → subagents → files → context → tokens` 的
完整排序，也就是 `rowObservationLine` 的第二份拷贝：任何屏幕都显示不出来，却会被
以后读代码的人当真，也会和真正在用的那份悄悄分叉。

**修法**：删掉死代码，函数改名为它实际是的东西（`stalledRowMetric`）。

---

## 顺手加固（不是缺陷，是同一颗地雷的其余引信）

`Dictionary(uniqueKeysWithValues:)` 在重复键上是 **trap**，不是覆盖。这件事在
`waitingDeliveryRows` 的注释里写得很清楚，因为它**已经让菜单栏崩过一次**。同样的
写法还剩五处（StatusStore 四处、SnapshotBuilder 一处），今天安全只是因为 builder
恰好把行放在字典里返回 —— 那是当前实现的性质，不是契约，而失败模式是整个菜单栏消失。

统一走 `byRowKey` / `uniquingKeysWith`。

---

## 复核过、判定不是缺陷的

| 项 | 结论 |
| --- | --- |
| `isInQuietHours` 跨午夜 | 正确（`start > end` 时用 `或`）；且只抑制空闲通知，与标签一致 |
| `progressPercent` / `bytesPerMinute` / `projectedDailyHarvests` 的 `Int(_: Double)` | 三处都在转换**之前**夹紧，不会 trap |
| `cpuPercent` 的 `Int(rounded())` | 上游已被 `maxCPUPercent` 夹到 1600 |
| 观测行故障层用 `change == nil` 抑制重复 | 意图对，条件错 —— 见 D-2 |
| `AttentionLedger.reconcile` 清 snooze | 已正确处理（`snoozedUntilMs = 0`） |
| `matchRespondInbound` 在 session 为空时落到 `rows.first` | 判决由 request id + 内容摘要 + agent + host 四向绑定，错配只会放错按钮位置，不会送错判决 |
| L10n 覆盖 | 490 个 key，en/zh 双侧齐全，格式符数量一致 |

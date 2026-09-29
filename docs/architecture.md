# 架构

数据从「机器上有个进程」走到「菜单栏亮红灯」的完整路径。

```
  ┌─ ProcessProbe ──┐   ps -axo，进程 → AgentID，解析 TTY、Warp 与宿主 IDE 父进程
  │                 │
  ├─ ActivityHarvest┤   Swift 原生 bounded reader（唯一采集器）
  │                 │
  └─ AttentionReader┘   读 attention.tsv（hooks 写的）
           │
           ▼
    SnapshotBuilder        纯函数：合并、去重、排序、编码状态、算边沿
           │
           ▼
      ScanEngine           定时器与节奏、后台扫描、扫描间簿记（23.0）
           │  land(结果)
           ▼
      StatusStore          视图读的唯一 @Observable 模型：快照、行、设置、少量 UI 标志、intent
           │               ├─ WaitNotifier       「需要你」横幅：规划、发送、限流、去向、点击（23.0）
           │               ├─ settings.json      设置（Codable，0600，23.0）
           │               └─ session-log.json   每会话状态段 + 等待记录与通知去向（23.0）
           ▼
   StatusItem（StatusPanelController：灯形 = snapshot.lamp，tooltip = 一句规则；按键 → TrayKeys）
   / TrayPanelViews（列表 + SessionDetailView，状态在 TrayUI）/ SettingsViews / DiagnosticsViews（诊断 + 活动）
```

## 模块（12.0 起，12.3 收齐）

```
PulseBar/Sources/
  PulseCore/     内核库。只 import Foundation（+ CryptoKit / CoreGraphics），严格并发 + warnings-as-errors。
                 AgentCatalog（每 Agent 的全部非解析事实）· PrivateFile / SafeRead
                 · ProcessIO · ContentSanitizer · TranscriptReader · AttentionProtocol
                 · ProbeSchedule · ProbeStats · DebugLog · Guarded
  PulseHarvest/  采集库，依赖 Core。NativeActivityHarvest（扫描与遍历）· 厂商方言
                 （TranscriptDialect + HarvestCodex / Pi / Claude / SmallDialects）· HarvestDatabases
                 · ActivityHarvest · ProcessProbe · HarvestSupervisor · HarvestMemory（ScanMemory）
                 · AttentionIO · ActivitySpool · TitleHeuristics · HarvestVocabulary
  PulseBar/      可执行。builder、ScanEngine、StatusStore、WaitNotifier、Explain、
                 WaitingDelivery、视图、hook 入口。
                 15.0 起表面是纯值：视图只渲染值、发 intent，由 StatusStore 执行；
                 SurfaceFixtures 的每个夹具在 CI 里经 SurfaceCapture 渲染成 PNG
                 （scripts/qa_surfaces.sh）。17.0：托盘行的脸同样是纯值（TrayRowModel →
                 TrayRowFace）。23.0：会话发生过什么只记一处 —— SessionLog（纯值）
                 与 SessionLogStore（读写）。
                 PulseCoreExports.swift 以 @_exported 引入两个库。
```

> **22.0 删除了 `PulseManaged`**（受管会话：ManagedRuntime、Session / Runner / Fleet、
> Worktree、权限 MCP 服务、AcceptanceRunner、WorkspaceEffect、EvidenceBook、Mission）、
> Core 里的 `AcceptanceEvidence` 与 `ProcessIO.runCheck`，以及 App 里的指挥台、Mission /
> 工作副本验收卡、跨机器 Respond、舰队快照（`fleet.d/`）与远端收件箱（`attention.d/`）。
> 一个状态灯应该看着编排器，而不是成为编排器。
>
> **23.0 继续做减法**：更新器只剩「检查 GitHub Releases、打开发布页」；删除了设置迁移与
> `LegacyCleanup`、「稍后」、离开期间的回看与等待历史、会话摘要（`SessionDigest`）与
> `SessionSource` 接缝。

三个 target 全部在完整并发检查下零警告并开启 warnings-as-errors（12.4）。
依赖只能向下：没有一个库引用得到 `StatusStore`、AppKit 或任何视图，这由编译器保证，
不靠 review。库成员是 `package` 可见（Core 是 `public`）。每个 Agent 的全部非解析事实
（进程规则、采集根目录、别名、Waiting / 采集等级、单字母标记）只在
`AgentCatalog.swift` 的一条 `AgentSpec` 里；`scripts/catalog_check.py` 扫描所有 target，
防止按 Agent 分支的表在别处重新长出来。

19.0 起 `StatusStore` 是 `@Observable`：视图只因它的 body 实际读到的属性变化而重绘，
不再因 store 上任何一个 `@Published` 被写而整体失效。23.0 把原来约 100 个属性的 store 拆成三份：

- **`ScanEngine`**（`@MainActor`，不被观察）：探测定时器与 `ProbeSchedule` 节奏；在后台队列跑
  `ProcessProbe`、`ActivityHarvest`、`AttentionReader`、`ClaudeAgentsProbe`、`ActivitySpool`；
  合并部分采集、保存采集器健康、`HarvestSupervisor`、`ProbeStats` 与各种扫描间缓存；调用纯函数
  `SnapshotBuilder`，把结果交给 `StatusStore.land`。它不持有也不写任何 UI 状态。
- **`WaitNotifier`**（`@MainActor`，不被观察）：横幅的规划（`WaitingDelivery`）、发送
  （`PulseNotify`）、限流、欠账、去向与点击写进 `SessionLog`，以及点横幅回到对应行。
- **`StatusStore`**（`@Observable`）：只放视图要读的 —— `snapshot`、`cachedAll`、`settings`、
  `logRevision`、`settingsFocus`、`diagnostics` 与几个状态标志（共 17 个被观察属性），外加视图
  发出的 intent（聚焦、忽略、静音、打开设置、安装 hooks……），这些 intent 再委托给引擎、
  通知器或服务。`land` 与各个 `land…` 方法只在值变化时赋值。

扫描路径因此只在值变化时写被观察的属性（`ScanQuietTests` 逐个跟踪每个被观察属性，超过 25 个
即失败）。设置窗口不读 `snapshot` 或行，所以扫描不重绘它（`surface_check.py` 把守）；AppKit 侧
（状态栏图标）用 `ObservationLoop` 只跟随 `snapshot`。测试用 `store.engine.applyScan(...)` 驱动一轮扫描。

## 三个来源

### ProcessProbe（便宜，常跑）

一次 `ps -axo pid=,ppid=,tty=,args=`，按规则表把命令行匹配到 `AgentID`。
每条规则有 basename、路径特征串和排除串——排除串是必需的，
`amp` 要躲开系统的 `AMPLibraryAgent`，`pi` 要躲开 `pip`。

顺着 ppid 链向上找，回答三件事：真实 TTY 是什么（进程自己常是 `??`），
是不是跑在 Warp 里，以及父进程是否是 Cursor / VS Code / Windsurf / Zed / Trae /
Antigravity。Focus 精度：Warp / 宿主仅 App、有绝对 cwd 时宿主工作区
（`open -a Host.app <cwd>`）、opt-in 后的终端标签。扫描期只用 `ps`，
不枚举 `NSRunningApplication`；activate / open 发生在用户点击之后。
详见 [`docs/landing-hosts.md`](landing-hosts.md)。

`signature()` 给出这一轮的进程指纹。指纹没变，说明会话数据大概率也没变，
昂贵的 harvest 就能跳过。

### ActivityHarvest（昂贵，按需）

`NativeActivityHarvest` 用 Foundation 读取各 Agent 自己的本地文件——Claude 的
`~/.claude/projects/*/*.jsonl`、Codex 的 rollout、Cursor 的 session/cache、OpenCode 的
JSON……每个 Agent 一个 bounded adapter，直接生成 Swift `Row` 和 `CollectorHealth`。
不稳定的 SQLite/私有 schema 只标为 cache，不猜成结构化会话。

窗口读取只看得到会话记录的头尾。23.0 删除了 1.1 起那份持久的会话摘要
（`session-digests.json`）：它读中间那段来给出精确记录数、工具序列、整场 token 与增长速率，
却没有一个画面还在用这些数。现在超出窗口的会话记录数报未知（数量不估算），其余事实只来自窗口。

0.99 删除了旧版 `src/activity_scan.py`：它自 0.48 起就不是运行时通路，却仍占 11,470 行、
一道门禁和一条逐字节同步检查，并让文档误以为存在一道并不存在的防线。现在只有一个采集器。

两条硬约束，都是踩过坑之后加的：

- **逐 agent 隔离**。native reader 对每个 Agent 单独计时、限制深度/文件/行数；损坏文件只影响
  自身，其余 30 个用户可见 Agent 仍返回健康结果。
- **边跑边读**。native reader 不启动外部解释器；显式 legacy 模式仍由 Swift 独立线程排空
  stdout/stderr，并对每个 collector 设置 1.2–2.0 秒硬上限。超时保留已完成的 JSON 行，
  未到达的 adapter 继续沿用上一份有效事实，并在健康度窗口标为扫描未完成。

  Native row 不经过外部 wire；字段在 `ActivityHarvest.Row` 内按类型校验和敏感信息清洗。
  显式 legacy 模式才启用 schema 2 JSON，未知 schema 直接进入 failed health，不会把错位字段
  渲染成有效内容。读取受保护的 App Support/App Group 需要按 Agent 明确授权；native reader
  在访问前做 lexical TCC gate，ProcessProbe 的 lsof 也只接收已授权 Agent 的 PID。

legacy 超时不再丢弃已有结果：完整的行留下、被截断的最后一行丢掉；native adapter
按自己的时间预算直接返回已解析事实。

#### Harvest merge（事实连续）

一个会话文件常被拆成多条 Fact（用户 prompt、多次 `tool_use`、cwd 碎片）。
Adapter 在补齐路径派生的 `sessionID` / Claude encoded cwd / subagent 计数之后，
会对同一文件的碎片 **再跑一次 merge**，否则盖章同一 session id 会把身份压扁，
最早的碎片会永远抢走最新动作。

合并规则（`NativeActivityHarvest.merge`）：

- **identity**：同一 `(session / path)` 收成一行
- **task / cwd / project / model…**：先写优先（空才填）
- **tool：后写非空覆盖** —— Claude 的 `tool_use` 出现在用户 prompt 之后；
  prefer-first 会让行永远停在空动作
- **tokens / progress / subRunning / subTotal**：取 max
- Codex 无类型的 head/compat 行：保留 cwd/tool/tokens，**不把裸 `title`
  升成 task**（那是 plan/registry 标签，不是用户目标）
- **`bestEffortCache` 永不输出 `.session` 证据** —— 即使路径针或 SQLite 行
  看起来像 structured；薄索引保持 Limited + Support depth「cache / index」
- **pending 词表按整词/短语匹配** —— `depending` 不得因包含 `pending` 子串
  而假抬 Waiting（Goose 历史坑）

`HarvestSupervisor` 在 `ScanEngine` 里为每个 Agent 保存独立的失败次数、下次重试、熔断截止和最后错误；
一次 partial scan 只更新已到达的 adapter，下一次只探测已到期的 Agent，全部退避时做一个半开探测。

### AttentionReader（事件驱动）

`~/Library/Application Support/Pulse/attention.tsv`，由原生 `pulse-hook` /
`PulseBar --hook`（`PulseHookReceiver`）写入，或按 Attention Protocol v4
（每行十列：多了 pid、transcript、落地句柄）直接追加。24.0 起每个 Agent 的 hook 都以
`pulse-hook <agent> <厂商事件名>` 调用，接收器按 Agent 把厂商事件与载荷映射成
start / working / 阻塞 / 轮到你 / done / end。契约见
[`attention-protocol.md`](attention-protocol.md)；产品政策见
[`attention-bridge.md`](attention-bridge.md)。

规则（v3 起，v4 沿用）：同一 `(agent, session)` 后写的覆盖先写的；`done`、`start`、`working`、`end` 清除；`turn`
（Claude 的 Stop / idle_prompt、Codex 的 agent-turn-complete）清掉阻塞等待并标记「轮到你」，
但 20 秒宽限内不清掉刚发生的阻塞等待。「轮到你」不点红灯，只进托盘计数（`AgentRow.yourTurn`）；
`front` 列记下提示窗口当时是否在最前，在最前的阻塞等待只亮灯、不发通知。
未知 kind 拒绝写入且读者忽略（永不自由文本 Waiting）。超过 30 分钟的条目直接过期。

`AttentionWatcher` 用 `DispatchSource` 盯着这个文件，写入即触发刷新，
所以红灯不用等下一个探测周期。

## SnapshotBuilder（纯函数）

合并核心。0.23 之前它埋在 `StatusStore.applyScan` 里，382 行，零测试覆盖。

它做的事：

1. 进程按 agent 收敛（24.0：`cursor-agent` 命令行本来就按 Cursor 的进程规则认）
2. harvest 行建会话行；键由 `RowIdentity` 一次定下、之后不再改变（`agent|<会话 id>`，没有 id
   时是会话文件路径或「目录 + 开始时间」的哈希，键里不带路径）；同一会话的多个文件合并成一行，
   无法区分的两个会话加 `~2` 后缀；每 Agent 的 500 条采集输入保留 500 条，
   超出部分精确计入未显示数量；面板 glance 默认全局前 12 行
3. 陈旧 harvest 丢弃；同 Agent 没有任何新鲜记录且进程仍在时，只允许一个未完成记录
   按工作区匹配 / 最近活动降级为上下文；subagent 仍在运行的记录不视为陈旧
4. `skill=pending` → Waiting，除非用户软忽略过
5. attention 两级匹配：session id（精确，或唯一前缀；多个前缀视为歧义、不点灯）→ cwd（点名了
   别的会话时只落到没有会话 id 的行上）；从不落到进程行上；都不中时阻塞事件建一个 hook 行，键同它
   点名的会话（`agent|<会话 id>`，所以会话文件出现后还是同一行），没点名会话时是
   `agent|hook:<cwd 哈希>`；「回合结束」不建行
6. live 进程**只挂到一行**（等待优先、未完成优先、同目录优先、最新优先），不在兄弟会话间涂抹；
   该 Agent 没有任何会话 / hook 行时才建一个短命的进程行 `agent|pid:<pid>` —— 它不「升级」，
   会话行出现时它就不再被建出来
7. 每行只有一个状态（`RowState`）：`.blocked(RowWait)`（hook / pending / `claude agents`）、
   `.processOnly`、`.yourTurn(sinceMs:)`（hook 报告回合结束且会话此后没动）、`.running`（进程在、
   显式运行阶段或子代理在跑，且回合未完成）、`.recent`；停滞只对 `.running` 按扫描时钟判定
8. 解析 focus 分级；进程探测补充可验证的工作目录（每轮一次，不在视图里）
9. 排序：Waiting（最久的在前）→ 分区 → 有会话标题 → live → agent 优先级 → 键（全序，同一个世界
   总是同一个顺序）
10. 编码 glance 状态、标题（只在有等待时：数量 · 最久时长）、tooltip、header；**灯的解释**
   `LampExplanation` 23.0 起只是一句规则（就是整个 tooltip），`LampFace.glance` 给出菜单栏的
   灯形（与行同一套：实心 / 环 / 空心 / 虚线；仅进程是灰色虚线，永不橙），存为 `snapshot.lamp`
11. 算边沿：键不会变，所以新的 Waiting 就是等待键集合之差，不需要跟随改名
12. 计数未显示的会话：`staleHidden` 只算最近 24 小时里停下的（`staleHiddenWindowMs`）

一行说什么只由 `Explain`（纯值）决定：`headline`（托盘主行：等待行 任务→项目→「需要你」；进程行
诚实短语；会话行 任务→新鲜原话→项目→会话短语）、`why`（哪条证据让它处在这个状态、从何时起）、
`source`（会话文件 / 应用数据 / 仅 hook / 仅进程）、`state` 与 `ask`。`TrayRowModel`、详情页的
`DetailModel` 与 `LampExplanation` 都用它的话，所以三处永远一致。

**它不做任何有副作用的事。** 时钟、终端环境、路径存在性判断都从 `Context` 注入；
想让外界做的事——发通知、写日志、清除某个 key——全部作为数据返回。
这就是为什么它能被专门的纯逻辑回归测试覆盖，并可在完整 XCTest 环境中独立验证。

## 会话记录（SessionLog，23.0）与 StatusStore（外壳）

AttentionReader 仍读取 agent-owned 的 attention.tsv；Pulse 自己记下的一切只在一个文件里：
`session-log.json`（与 attention.tsv 同目录，`PULSE_HOME` 一起搬；经 `PrivateFile` 以 `0600`
写入）。23.0 之前这件事分在四个互相重叠的文件里 —— `attention-ledger.json`（等待与通知去向）、
`attention-history.json`（每条 hook 事件的副本，供「为什么」与导出）、`session-timeline.json`
（状态段）和 `dismissed-pending.json`（软忽略） —— 外加 store 上的 `knownWaitingKeys` 与一个冻结
行副本的通知队列。它们会彼此不一致，也确实不一致过。23.0 不迁移：启动时把这四个旧文件删掉，
不读。

`SessionLog` 是纯值，按 row key 存：

- **状态段**（`TimelineSpan`）：running / thin / stalled / blocked / turn / recent，依据
  hook / pending / vendor / harvest / process，起止时间（没有证据时钟时记扫描时刻、标
  `exact = false`）。
- **等待记录**（`SessionLog.Wait`）：`id`（`rowKey|扫描时刻`，通知带着它）、kind、标题
  （`usefulTask`，脱敏，≤ 160 字）、`raisedMs`、`queuedMs`（欠一条横幅）、`notifiedMs`、
  `outcome` / `outcomeMs`（`posted` / `summary`，或 `WaitingDelivery.SkipReason` 的原始值）、
  `clickedMs`、`dismissedMs`（软忽略另记 `holdsDismissal`）、`resolvedMs`。

由它导出的集合就是 store 从前各存一份的东西：`waitingKeys`（上一轮的等待边沿基线）、
`suppressedKeys`（交给 builder 的软忽略）、`queuedKeys`（欠横幅的等待，每轮从**当前行**重建）、
`dismissedKeys`，以及全局限流锚点 `lastNotificationMs` 与首次扫描的 `baselineEstablished`。

边界：至多 128 个会话、每个 48 段、每个 16 条已解决等待；关上的段与已解决的等待 24 小时后清掉；
开着的段与未解决的等待是「现在」，从不被上限挤掉。退出时开着的段在重启后第一轮扫描按上次写盘
时刻（`savedAtMs`）关上；此后任何不在当前行里的会话都没有开着的段。行的键从不改变
（`RowIdentity`），所以没有历史需要合并；23.0 的 schema 2 不读键规则不同的旧文件。

**扫描静默**：每次修改都经 `StatusStore.updateLog`：只有持久内容真的变了，被观察的
`logRevision`（登记在 `ScanQuietTests`）才前进、`SessionLogStore` 才写盘（1.5 秒防抖；发横幅前的
「欠一条」与忽略立即写；退出时 flush）。异步到达的通知结局与点击同样走这里，所以详情页的
「这条通知」会跟着更新。点击按横幅携带的等待 `id` 记账，不按 row key 记到最新的那条。

读它的视图只经 `logRevision` 订阅：详情页的 `TimelineStripView`、`NotificationAuditModel`
（「这条通知发生了什么」），都经 `DetailModel` 交给 `SessionDetailFace`；诊断窗口的
`ActivityLogModel`（状态段与通知去向合成一条倒序记录，按 Agent 过滤）。时间一律经
`LogClock`：今天 `HH:mm`，一周内 `周一 HH:mm` / `Mon HH:mm`，更早 `M/d HH:mm`。自检的「hook
真的触发过」直接读 attention.tsv 每个 Agent 最新的一行（`AttentionIO.latestEvents`）。

`ScanEngine`、`WaitNotifier` 与 `StatusStore` 一起拥有 builder 刻意不碰的东西：

- **定时器与节奏**。`ProbeSchedule` 给出间隔，`PowerMonitor` 提供息屏 / 锁屏 /
  低电量状态。息屏即停表——attention 文件变化仍会唤醒。
- **通知策略**。builder 报告边沿，`WaitNotifier` 决定要不要发：按 agent 静音（行菜单）、在最前、
  开关、授权、首扫只播种不通知（否则启动时会为所有已有的等待刷屏）；每个决定都作为去向写进会话记录（`SessionLog`）。
  安静时段与声音 22.0 起交给 macOS 的专注模式与通知设置。
- **设置**。`PulseSettings` 是 `Codable` 值，存为 `settings.json`（与 attention.tsv 同目录，`PULSE_HOME` 一起搬；经 `PrivateFile` 以 `0600` 写入；
  缺字段取默认、未知值取默认）。改设置只走 `StatusStore.set(_:_:)`：值变了才写盘并应用（登录项、
  快捷键、横幅按钮语言、重扫），且只在 `start()` 读过设置之后。23.0 不迁移：发现旧的
  `settings.txt` 直接删掉、用默认值。「全部空闲时通知」已删除。
- **权限边界**。受保护的应用数据默认关闭，由**一个**开关 `readProtectedAppData` 打开：打开后所有
  `requiresAppDataOptIn` 的 Agent 都会被读取（23.0 删除了逐 Agent 的范围）。
- **动作**。可靠 Focus、安装 / 移除 hooks、复制报告、忽略 / 静音。

## 视图

`StatusPanelController` 拥有原生状态项和单表面 `NSPanel`；其中承载
`TrayPanel`（23.0：一行一个会话的列表 + 一行「为什么 + 新鲜度」的 Header + 至多一条提示 + 底部按键提示；
→ 进入 `SessionDetailView`，← / Esc 返回），`SettingsView` 是一页七组的偏好（`SettingsModel`；
深链经 `settingsFocus.token` 滚到对应一节），`DiagnosticsView` 是诊断窗口（`DiagnosticsModel`）。
托盘每次打开的状态（过滤、选中、详情页、冻结的顺序、列表高度预算）在 `TrayUI`；面板的按键监视器
把每个键交给纯函数 `TrayKeys.reduce`，所以 Esc 在详情页、无结果的过滤和空列表里都有效，⌫ 只编辑过滤框。
行与菜单栏的灯形都来自 `LampFace`（`LampShapeView` / `PulseBrand.statusBarIcon` 绘制）。SwiftUI 视图都标了
`@MainActor`——SwiftUI 只有 `body` 隐式主 actor 隔离，
辅助计算属性不是，调 store 的 `@MainActor` 方法会编译失败。

视图里不做 I/O。focus 分级和目录存在性在扫描时算好存进 `AgentRow`，
此前它们在 `estimateHeight` 里，意味着每行每次重绘都遍历一遍运行中的应用并 stat 磁盘。

## 版本身份

`PulseVersion.semver` 是唯一真源。`package.sh` 把 git short sha 与构建日期写进
`Info.plist`，运行时读回，于是有三档：

| channel | 判据 | 显示 |
| --- | --- | --- |
| `release` | bundle 版本 == 编译版本 | `Pulse 0.65.0` |
| `dev` | 无 bundle 版本（`swift run`） | `Pulse 0.65.0-dev` |
| `mismatch` | 两者不一致 | `0.65.0≠0.64.0` + 橙色警告 |

`PulseDistributionChannel` 另标记分发通道：`preview`（ad-hoc）、`signed`（Developer ID
未公证）、`stable`（公证成功，`PulseNotarized=true`）。无 Apple Developer ID 时 GitHub
仍可将当前 semver 标为 **Latest**，但 Info.plist **不得**写 `stable`，About 保持
preview/signed；只有 notarized 才能自称 Gatekeeper-ready。
更新检查只问 GitHub Releases 有没有更新的版本；有就显示「vX 可用」和一个打开发布页的按钮。
Pulse 不下载、不校验、不替换自己（23.0 删除了下载、DMG 校验、原地安装与回滚）。

`mismatch` 针对的是菜单栏应用的高频陷阱：装了新版，旧的还在跑。

## Native 是运行时真源

`NativeActivityHarvest.swift` 是唯一采集器（下一阶段删除），七个 Agent 都有
Swift descriptor、权限边界、bounded file walk 和健康结果。0.99 起没有第二个实现，
也没有任何路径会为了观测会话去 fork 解释器。

hooks 按用户选择安装（24.0）：七个 Agent 各走厂商文档里的 hook / 插件 / 扩展，全部调用原生
`pulse-hook`（无需 Python），只装观察型事件，移除时逐字节还原（`HooksInstaller` +
`hook-installs.json`）。缺少 Python 不影响 native harvest、hook install，或 self-test。

## 门禁

| 脚本 | 守什么 |
| --- | --- |
| `version_check.py` | 版本只有一个真源，CHANGELOG 与 README 徽标跟随 |
| `catalog_check.py` | 23.0 合并原来的四个目录门禁：每个 `AgentID` 一条 spec、别处不长出按 Agent 的表；每个 Agent 都有 harvest 接线；Cursor worker 被拒、`lsof` 输出不看退出码；AppleScript 只在 Automation 授权后；README 支持矩阵 == 目录；每个 Agent 的格式有出处（`docs/vendor-formats.json`），未核实的格式没有 Waiting |
| `make_agent_icons.py --check` | 每个 `AgentID` 都有图标，且与生成器逐字节一致 |
| `appearance_check.py` | 没有把随外观变化的值冻进常量（0.27.1 因此丢了深色模式） |
| `surface_check.py` | 表面渲染值、不碰 store；fixture 与截图清单一致 |
| `scenario_map.py` | `docs/scenarios.md` 点名的测试套件与方法都存在 |
| `--native-fixture-test` | native 端到端墙：厂商真实布局 → 真扫描器 → 断言主行**取值**（CI + `package.sh`） |
| `resource_budget_check.py` | native fixture 墙钟 + RSS 上限（env 可调） |
| `package_check.py` | 打出来的 `.app` 能找到自己的资源 |

前六个由 `scripts/gates.sh` 一次跑完；全部都在 `package.sh` 和 CI 里。

测试（`PulseBar/Tests/PulseBarTests/`）按组件分文件（23.0）：`CoreTests`（目录、有界 IO、进程）、
`HarvestTests`、`TranscriptTests`、`VendorFormatTests`（按厂商源码造的夹具）、`AttentionTests`
（读取器、协议、hook 接收器、安装器、`claude agents`）、`BuilderTests`、`ExplainTests`、
`SessionLogTests`、`NotifierTests`、`TrayTests`、`SettingsTests`、`DiagnosticsTests`、`EngineTests`。
新测试放进它所测组件的文件，不再按发版建文件；`docs/scenarios.md` 按套件名与方法名点名。加上 `swift test`、`--selftest` 与 `--native-fixture-test`，
这是全部自动防线。

**主行 / 解析类回归只属于 `--native-fixture-test` 与 `swift test`**：那里用厂商真实布局
断言主行取值。0.99 之前还有第八道门禁 `harvest_stats_check.py`，它跑的是 legacy Python
通路、看不见 native 回归，却被文档描述成端到端真实采集 —— 这正是 0.96.1 / 0.97.0 /
0.97.1 / 0.97.2 四连发都能全绿出厂的原因。门禁连同它守护的那份代码一起删了。

**门禁只能守它真正执行的东西。** `harvest_stats_check.py` 的 0.28.0 版本
自称「跑真实 harvester」，实际只调 helper 再数源码字符串——而字符串计数
分不出「接线」和「接了但下游被砍掉」，于是 Cascade 与 Amp 两条数据丢失
全程绿灯出厂。凡是加门禁，先把它要防的那个 bug 放回去，确认它会红。

# 架构

数据从「Agent 的 hook 报了一件事」走到「菜单栏亮红灯」的完整路径（24.0：事件核心）。

```
  pulse-hook / 插件 / 扩展 ──► attention.tsv（v4 十列）· activity.d/<agent>-<session>.json
           │  AttentionWatcher（DispatchSource，写入即触发）
           ▼
      ScanEngine            只把 attention.tsv 里没见过的行按文件顺序交给会话簿；活动文件按 activityMs 去重
           │
           ▼
      SessionBook           纯值 reducer：apply(event) → 工作中 / 需要你 / 轮到你 / 结束
           │   ◄── AgentProcesses（libproc，每 30 秒 + 启动 / 唤醒）· ProcessExitWatch（每个会话 pid 一个退出源）
           │   ◄── TranscriptSummaryReader（轮到你 / 需要你 / 打开详情时有界读一次，离开主线程，按大小与 mtime 缓存）
           ▼
    SessionProjection       纯函数：会话 + 进程 + 会话摘要 → AgentRow（仅进程行、落地句柄、停滞、最近）
           │
           ▼
    SnapshotBuilder         纯函数（很薄）：排序、窗口、灯、标题、边沿
           │  land(结果)
           ▼
      StatusStore          视图读的唯一 @Observable 模型：快照、行、设置、少量 UI 标志、intent
           │               ├─ WaitNotifier       「需要你」横幅：规划、发送、限流、去向、点击（23.0）
           │               ├─ settings.json      设置（Codable，0600，23.0）
           │               └─ session-log.json   每会话状态段 + 等待记录与通知去向（schema 3）
           ▼
   StatusItem（StatusPanelController：灯形 = snapshot.lamp，tooltip = 一句规则；按键 → TrayKeys）
   / TrayPanelViews（列表 + SessionDetailView，状态在 TrayUI）/ SettingsViews / DiagnosticsViews（诊断 + 活动）
```

## 模块（12.0 起，24.0 瘦身）

```
PulseBar/Sources/
  PulseCore/     内核库。只 import Foundation（+ CryptoKit / CoreGraphics），严格并发 + warnings-as-errors。
                 AgentCatalog（每 Agent 的全部事实：进程规则、别名、Waiting、hook 契约）· PrivateFile / SafeRead
                 · ProcessIO · ContentSanitizer · TranscriptReader（有界尾读）· AttentionProtocol
                 · ProbeSchedule · DebugLog · Guarded
  PulseHarvest/  事件与进程库，依赖 Core。AttentionIO · ActivitySpool · AgentProcesses（libproc）
                 · TranscriptSummary（六种会话文件方言：标题、最后的消息、模型、最后的错误）
                 · RowIdentity · TitleHeuristics · HostAppKind
  PulseBar/      可执行。SessionBook / SessionProjection、SnapshotBuilder、ScanEngine、ProcessExitWatch、
                 StatusStore、WaitNotifier、Explain、WaitingDelivery、视图、hook 入口。
                 15.0 起表面是纯值：视图只渲染值、发 intent，由 StatusStore 执行；
                 SurfaceFixtures 的每个夹具在 CI 里经 SurfaceCapture 渲染成 PNG
                 （scripts/qa_surfaces.sh）。23.0：会话发生过什么只记一处 —— SessionLog（纯值）
                 与 SessionLogStore（读写）。
                 PulseCoreExports.swift 以 @_exported 引入两个库。
```

> **22.0 删除了 `PulseManaged`**（受管会话、Worktree、权限 MCP 服务、Mission……）与指挥台。
> 一个状态灯应该看着编排器，而不是成为编排器。
>
> **23.0 继续做减法**：更新器只剩「检查 GitHub Releases、打开发布页」；删除了设置迁移、
> 离开期间的回看、会话摘要与 `SessionSource` 接缝。
>
> **24.0 删除了会话文件扫描层**：`NativeActivityHarvest`、`ActivityHarvest`、`HarvestSupervisor`、
> `HarvestMemory`、`HarvestDatabases`（SQLite）、各厂商 harvest 方言、`ClaudeAgentsProbe`、`ProbeStats`、
> `ps` / `lsof` 的 `ProcessProbe`、`--native-fixture-test` 墙与 `resource_budget_check.py`，以及
> 「读取应用数据」开关。状态只来自事件。

三个 target 全部在完整并发检查下零警告并开启 warnings-as-errors（12.4）。
依赖只能向下：没有一个库引用得到 `StatusStore`、AppKit 或任何视图，这由编译器保证，
不靠 review。库成员是 `package` 可见（Core 是 `public`）。每个 Agent 的全部事实
（进程规则、别名、Waiting、hook 契约、单字母标记）只在 `AgentCatalog.swift` 的一条 `AgentSpec` 里；
`scripts/catalog_check.py` 扫描所有 target，防止按 Agent 分支的表在别处重新长出来。

19.0 起 `StatusStore` 是 `@Observable`：视图只因它的 body 实际读到的属性变化而重绘。
23.0 把 store 拆成三份：

- **`ScanEngine`**（`@MainActor`，不被观察）：持有 `SessionBook`、见过的 attention 行、最近一次有效的
  进程列表、会话摘要缓存与两个便宜的定时器；在后台队列读 attention.tsv、`activity.d/`、进程表与会话文件；
  调用纯函数 `SessionProjection` 与 `SnapshotBuilder`，把结果交给 `StatusStore.land`。它不持有也不写任何 UI 状态。
- **`WaitNotifier`**（`@MainActor`，不被观察）：横幅的规划（`WaitingDelivery`）、发送
  （`PulseNotify`）、限流、欠账、去向与点击写进 `SessionLog`，以及点横幅回到对应行。
- **`StatusStore`**（`@Observable`）：只放视图要读的 —— `snapshot`、`cachedAll`、`settings`、
  `logRevision`、`settingsFocus`、`diagnostics` 与几个状态标志，外加视图发出的 intent
  （聚焦、忽略、静音、打开设置、安装 hooks、打开详情……）。`land` 只在值变化时赋值。

更新路径因此只在值变化时写被观察的属性（`ScanQuietTests` 逐个跟踪每个被观察属性，超过 25 个
即失败）。设置窗口不读 `snapshot` 或行（`surface_check.py` 把守）；AppKit 侧（状态栏图标）用
`ObservationLoop` 只跟随 `snapshot`。测试用 `store.engine.apply(records:nowMs:)` 与 `engine.project(nowMs:)`
驱动一轮。

## 三个来源

### 事件（主干）

`~/Library/Application Support/Pulse/attention.tsv`，由原生 `pulse-hook` /
`PulseBar --hook`（`PulseHookReceiver`）写入，或按 Attention Protocol v4
（每行十列：agent、kind、ms、message、session、cwd、front、pid、transcript、landing）直接追加。
每个 Agent 的 hook 都以 `pulse-hook <agent> <厂商事件名>` 调用，接收器按 Agent 把厂商事件与载荷
映射成 start / working / 阻塞（permission / question / waiting）/ turn / done / end。契约见
[`attention-protocol.md`](attention-protocol.md)；产品政策见 [`attention-bridge.md`](attention-bridge.md)。
活动事件（Claude 的 `PostToolUse` / `UserPromptSubmit` 等）写 `activity.d/`，每会话一个状态文件。

`AttentionWatcher` 用 `DispatchSource` 盯着这两处，写入即触发读取。引擎把整份 attention.tsv 读回，
只把**没见过的行**按文件顺序交给会话簿（压缩后的文件不重放）；活动文件整份重读，会话簿按
`activityMs` 去重。

### 进程（便宜，每 30 秒）

`AgentProcesses` 用 libproc：`proc_listallpids` 列出本用户的进程，`PROC_PIDTBSDINFO` 取父进程、
TTY 与开始时间，`proc_pidpath` 与 `KERN_PROCARGS2` 取可执行路径与参数，按 `AgentCatalog` 的进程
规则匹配到 `AgentID`（排除串必需：`pi` 要躲开 `pip`，`cursor-agent` 常驻 worker 不算会话）。
包装进程与它的子进程收成一个家族（取最上层的 pid）。顺着父进程链回答：真实 TTY、是否在 Warp 里、
宿主 App；`PROC_PIDVNODEPATHINFO` 给出工作目录。不起 `ps` / `lsof` 子进程。

它只在启动、唤醒与每 30 秒跑一次（`ProbeSchedule.processScan`，低电量加倍，息屏停表），用来：
找出没有会话认领的进程（仅进程行 —— Pulse 启动前就在跑的会话，直到它的下一个事件）；以及知道
会话的 pid 还在不在。每个会话 pid 另有一个 `DispatchSource.makeProcessSource(.exit)`
（`ProcessExitWatch`），退出即结束会话，不等下一次扫描。**一次失败的扫描保留上一份有效列表。**

### 会话文件（按需）

`TranscriptSummaryReader` 只在会话轮到你、需要你，或用户打开详情页时读一次它的会话文件：小文件整读，
大文件读头 64 KB + 尾 256 KB 并丢掉撕裂的边缘；在后台队列读，按（路径、大小、mtime）缓存。
六种方言（Claude、Codex、Gemini、Pi、Copilot、Cursor）各给出标题、最后的消息、模型与最后的错误；
OpenCode 没有会话文件，用它的事件自带的内容。读不到文件只是行少了标题，**从不移除会话**。

## SessionBook（纯值 reducer）

`SessionBook.apply(_ record: AttentionRecord, nowMs:) -> Bool` 是状态唯一改变的地方；键由
`RowIdentity` 一次定下：`agent|<会话 id>`，hook 不点名会话时 `agent|hook:<cwd 哈希>`。

- 状态：`.idle`（刚开始 / 在提示处）、`.working`、`.blocked(Block)`、`.yourTurn(sinceMs:)`、`.ended(atMs:)`。
- `start` → idle（进行中的保持 working）；`working` → working；阻塞 → blocked（`waiting: .none` 的
  Agent 的阻塞行拒收）；`turn` → 轮到你（阻塞后 20 秒内不清；提示窗口在最前时算已看见 → idle）；
  `done` → 清掉阻塞 / 轮到你；`end` → ended。子代理事件从不改变状态；未来戳拒收；
  不点名会话的 `turn` 与 `done` / `end` 不造会话。
- `apply(activity:nowMs:)`：同一会话在提问之后的活动熄灭等待（回答发生在厂商自己的提示里）。
- `processExited(pid:atMs:)`、`endSessions(whosePidIsDead:)`、`prune(nowMs:)`（一天没动静的忘掉，至多 256 个）。

## SessionProjection 与 SnapshotBuilder（纯函数）

`SessionProjection.rows(book:processes:transcripts:context:)` 把会话投影成 `AgentRow`：

1. 知道 pid 的会话只在进程活着时算在跑；不知道 pid 的会话 30 分钟没有事件就是 `.recent`
   （`RecentReason.quiet`，`Explain.why` 这样说）；轮到你超过 30 分钟也是 `.recent`。
2. 会话认领它 pid 所在的进程家族；没有 pid 的未结束会话认领同目录的进程；没被认领的进程家族
   是仅进程行 `agent|pid:<pid>`（灰色虚线灯，永不橙、不装绿）。
3. 标题与最后的消息来自会话摘要，否则来自 `turn` 事件带的原话；落地句柄先取事件的 landing 列，
   进程（TTY / Warp / 宿主）只补它没说的；`LandingPlan.make` 据此排出落地步骤（见 `docs/landing-hosts.md`）。
4. 停滞（橙）只给报告过自己在干活的会话（有活动时钟）：Codex / Gemini / Copilot 的 hook 没有逐工具
   事件，安静不算停滞。
5. 最近停下的会话 45 分钟后离开列表，`staleHidden` 只计最近 24 小时里停下的。

`SnapshotBuilder.build(rows:staleHidden:previous:context:)` 只做排序（Waiting 最久在前 → 状态 →
键，全序）、12 行窗口、灯（`LampFace.glance`）、标题（只在有等待时：数量 · 最久时长）、tooltip
（`LampExplanation` 一句规则）与边沿（新的 Waiting 就是等待键集合之差）。

一行说什么只由 `Explain`（纯值）决定：`headline`、`why`（哪条证据让它处在这个状态、从何时起）、
`source`（hook / 仅进程）、`state` 与 `ask`。`TrayRowModel`、详情页的 `DetailModel` 与
`LampExplanation` 都用它的话，所以三处永远一致。

**它们都不做有副作用的事。** 时钟、终端环境都从 `Context` 注入；想让外界做的事作为数据返回。

## 会话记录（SessionLog，23.0）与 StatusStore（外壳）

attention.tsv 归 hook 所有；Pulse 自己记下的一切只在一个文件里：
`session-log.json`（与 attention.tsv 同目录，`PULSE_HOME` 一起搬；经 `PrivateFile` 以 `0600`
写入）。23.0 之前这件事分在四个互相重叠的文件里 —— `attention-ledger.json`（等待与通知去向）、
`attention-history.json`（每条 hook 事件的副本，供「为什么」与导出）、`session-timeline.json`
（状态段）和 `dismissed-pending.json`（软忽略） —— 外加 store 上的 `knownWaitingKeys` 与一个冻结
行副本的通知队列。它们会彼此不一致，也确实不一致过。23.0 不迁移：启动时把这四个旧文件删掉，
不读。

`SessionLog` 是纯值，按 row key 存：

- **状态段**（`TimelineSpan`）：running / thin / stalled / blocked / turn / recent，依据
  hook / process（24.0），起止时间（没有证据时钟时记扫描时刻、标
  `exact = false`）。
- **等待记录**（`SessionLog.Wait`）：`id`（`rowKey|扫描时刻`，通知带着它）、kind、标题
  （`usefulTask`，脱敏，≤ 160 字）、`raisedMs`、`queuedMs`（欠一条横幅）、`notifiedMs`、
  `outcome` / `outcomeMs`（`posted` / `summary`，或 `WaitingDelivery.SkipReason` 的原始值）、
  `clickedMs`、`dismissedMs`、`resolvedMs`。24.0 删除了软忽略：忽略总是写一条 `done`，会话簿据此清掉等待。

由它导出的集合就是 store 从前各存一份的东西：`waitingKeys`（上一轮的等待边沿基线）、
`queuedKeys`（欠横幅的等待，每轮从**当前行**重建）、
`dismissedKeys`，以及全局限流锚点 `lastNotificationMs` 与首次扫描的 `baselineEstablished`。

边界：至多 128 个会话、每个 48 段、每个 16 条已解决等待；关上的段与已解决的等待 24 小时后清掉；
开着的段与未解决的等待是「现在」，从不被上限挤掉。退出时开着的段在重启后第一轮扫描按上次写盘
时刻（`savedAtMs`）关上；此后任何不在当前行里的会话都没有开着的段。行的键从不改变
（`RowIdentity`），所以没有历史需要合并；24.0 的 schema 3 不读旧文件。

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

- **节奏**。没有固定的探测间隔：事件文件一变就处理。`ProbeSchedule.tick` 只是一个便宜的时钟
  （托盘打开或屏上有秒级等待时 5 秒，否则 60 秒，没有会话时停表），用来推进「最近」「停滞」与相对时间；
  `ProbeSchedule.processScan` 是 30 秒一次的进程查看。`PowerMonitor` 提供息屏 / 锁屏 / 低电量状态：
  低电量加倍，息屏停表 —— attention 文件变化仍会唤醒。
- **通知策略**。builder 报告边沿，`WaitNotifier` 决定要不要发：按 agent 静音（行菜单）、在最前、
  开关、授权、首扫只播种不通知（否则启动时会为所有已有的等待刷屏）；每个决定都作为去向写进会话记录（`SessionLog`）。
  安静时段与声音 22.0 起交给 macOS 的专注模式与通知设置。
- **设置**。`PulseSettings` 是 `Codable` 值，存为 `settings.json`（与 attention.tsv 同目录，`PULSE_HOME` 一起搬；经 `PrivateFile` 以 `0600` 写入；
  缺字段取默认、未知值取默认）。改设置只走 `StatusStore.set(_:_:)`：值变了才写盘并应用（登录项、
  快捷键、横幅按钮语言、重扫），且只在 `start()` 读过设置之后。23.0 不迁移：发现旧的
  `settings.txt` 直接删掉、用默认值。「全部空闲时通知」已删除。
- **权限边界**。24.0 不读任何受保护的应用数据，也没有这个开关；旧 `settings.json` 里的
  `readProtectedAppData` 被忽略。
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

## 事件是运行时真源

七个 Agent 的状态都来自它们自己的 hook / 插件 / 扩展。hooks 按用户选择安装：全部调用原生
`pulse-hook`（无需 Python），只装观察型事件，移除时逐字节还原（`HooksInstaller` +
`hook-installs.json`）。没有任何路径会为了观测会话去 fork 解释器；缺少 Python 不影响 app、
hook 安装或 self-test。

## 门禁

| 脚本 | 守什么 |
| --- | --- |
| `version_check.py` | 版本只有一个真源，CHANGELOG 与 README 徽标跟随 |
| `catalog_check.py` | 每个 `AgentID` 一条 spec、别处不长出按 Agent 的表；Cursor worker 被拒；进程只经 libproc（不起 `ps` / `lsof`），被删的采集文件不回来；AppleScript 只在 Automation 授权后；README 矩阵的 Waiting 列 == 目录；每个 Agent 的 hook 契约有出处与测试（`docs/vendor-formats.json`） |
| `make_agent_icons.py --check` | 每个 `AgentID` 都有图标，且与生成器逐字节一致 |
| `appearance_check.py` | 没有把随外观变化的值冻进常量（0.27.1 因此丢了深色模式） |
| `surface_check.py` | 表面渲染值、不碰 store；fixture 与截图清单一致 |
| `scenario_map.py` | `docs/scenarios.md` 点名的测试套件与方法都存在 |
| `package_check.py` | 打出来的 `.app` 能找到自己的资源 |

前六个由 `scripts/gates.sh` 一次跑完；全部都在 `package.sh` 和 CI 里。

测试（`PulseBar/Tests/PulseBarTests/`）按组件分文件（23.0）：`CoreTests`（目录、有界 IO、libproc 进程）、
`TranscriptTests`（有界尾读与六种会话文件方言）、`VendorFormatTests`（hook 契约与漂移）、`AttentionTests`
（会话簿读 attention、协议、hook 接收器、安装器）、`SessionTests`（七个 Agent 的真值表、投影、仅进程行、
builder、身份）、`ExplainTests`、`SessionLogTests`、`NotifierTests`、`TrayTests`、`SettingsTests`、
`DiagnosticsTests`、`EngineTests`（扫描静默、事件馈送、节奏）。新测试放进它所测组件的文件，不再按发版建文件；
`docs/scenarios.md` 按套件名与方法名点名。加上 `swift test` 与 `--selftest`，这是全部自动防线。

**门禁只能守它真正执行的东西。** 0.99 删掉的 `harvest_stats_check.py` 自称「跑真实 harvester」，
实际只数源码字符串，于是数据丢失全程绿灯出厂。凡是加门禁，先把它要防的那个 bug 放回去，确认它会红。

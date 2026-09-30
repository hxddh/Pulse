# 架构

数据从「Agent 的 hook 报了一件事」走到「菜单栏亮红灯」的完整路径。

```
  pulse-hook / 插件 / 扩展 ──► events.tsv（v5 十一列，只追加，每个 hook 事件一行）
           │  AttentionWatcher（一个 DispatchSource，写入即触发）
           ▼
      ScanEngine            启动时整份重放、再第一次投影；之后只按游标读新字节，逐行按顺序交给会话簿
           │
           ▼
      SessionBook           纯值 reducer：apply(event) → 工作中 / 需要你 / 轮到你 / 结束，外加最后 5 步、标题、本回合时钟
           │   ◄── AgentProcesses（libproc，启动 / 唤醒 / 未知 pid 时 + 30 秒起退避到 5 分钟）· ProcessExitWatch（每个会话 pid 一个退出源）
           ▼
      TrayState.project     纯函数：会话 + 进程 → 行、灯、菜单栏标题、计数、新的等待边沿、较早隐藏数
           │  land(结果)
           ▼
      StatusStore          视图读的唯一 @Observable 模型：快照、行、设置、少量 UI 标志、intent
           │               ├─ WaitNotifier + WaitLedger 「需要你」横幅：规划、发送、限流、撤回、点击（只在内存里）
           │               └─ settings.json      设置（Codable，0600）
           ▼
   StatusItem（StatusPanelController：灯形 = snapshot.lamp，tooltip = 一句规则；按键 → TrayKeys）
   / TrayPanelViews（列表 + SessionDetailView，状态在 TrayUI）/ SettingsViews（设置；Hooks 一节就是诊断）
```

## 模块

```
PulseBar/Sources/
  PulseCore/     内核库。只 import Foundation（+ CryptoKit / CoreGraphics）。
                 AgentCatalog（每 Agent 的全部事实：进程规则、别名、Waiting、hook 契约）· PrivateFile / SafeRead
                 · ProcessIO · ContentSanitizer · AttentionProtocol · ProbeSchedule · DebugLog · Guarded
  PulseHarvest/  事件与进程库，依赖 Core。EventLog（追加、按游标读、压缩、按位置认出已应用的行）
                 · AgentProcesses（libproc）· RowIdentity · TitleHeuristics（标题：提示词的清洗与取舍）· HostAppKind
  PulseApp/      应用库，依赖两个库并拥有资源（图标与品牌图，经 PulseResources 找，从不用 Bundle.module）。
                 SessionBook、TrayState、ScanEngine、ProcessExitWatch、StatusStore、WaitNotifier、WaitLedger、
                 WaitingDelivery、hook 入口与安装器、全部视图。表面是纯值：视图只渲染值、发 intent，
                 由 StatusStore 执行。PulseCoreExports.swift 以 @_exported 引入两个库。
  PulseBar/      出厂可执行：PulseBarLauncher 只调用 PulseBarMain.main()。
  PulseQA/       QA 可执行（只在 debug 构建）：SurfaceFixtures、SurfaceCapture、StatusStoreFixture、
                 TrayPreviewWindowController 与 QADriver（--capture-surfaces、--tray-fixture、--capture-*）。
                 经 @testable import PulseApp 进入应用内部；从不打包。
```

五个 target 都在 Swift 6 语言模式下；四个产品 target（除测试）开启 warnings-as-errors。
依赖只能向下：没有一个库引用得到 `StatusStore`、AppKit 或任何视图，这由编译器保证，
不靠 review。库成员是 `package` 可见（Core 是 `public`）。每个 Agent 的全部事实
（进程规则、别名、Waiting、hook 契约、单字母标记）只在 `AgentCatalog.swift` 的一条 `AgentSpec` 里；
`scripts/catalog_check.py` 扫描所有 target，防止按 Agent 分支的表在别处重新长出来。
QA 代码不进产品：`surface_check.py` 不让 QA 文件回到 `PulseApp`，`package_check.py` 在出厂二进制里
找到 QA 专用的命令行参数就失败。

`StatusStore` 是 `@Observable`：视图只因它的 body 实际读到的属性变化而重绘。状态分三份：

- **`ScanEngine`**（`@MainActor`，不被观察）：持有 `SessionBook`、事件日志的游标（这一代的表头与
  已应用到的字节）与这一代按顺序已应用过的行、最近一次有效的进程列表、上一轮开着的等待
  （给下一轮算边沿）、一个读失败时的重试（5 秒起翻倍到 60 秒，同时只有一个）与两个便宜的定时器；
  在后台队列读事件日志与进程表；调用纯函数 `TrayState.project`，把结果交给 `StatusStore.land` ——
  事件读出的、只动了行的安静事实（上一步、时钟，`TrayState.quietSignature`）的投影每拍至多落地一次，
  一阵工具行不会让托盘每行重绘一次。它不持有也不写任何 UI 状态。
- **`WaitNotifier`**（`@MainActor`，不被观察）：横幅的规划（`WaitingDelivery`）、发送
  （`PulseNotify`）、限流与点横幅回到对应行；记账在纯值 `WaitLedger` 里，只在内存。
- **`StatusStore`**（`@Observable`）：只放视图要读的 —— `snapshot`、`cachedAll`、`settings`、
  `settingsFocus` 与几个状态标志，外加视图发出的 intent（聚焦、忽略、静音、打开设置、安装 hooks、
  复制报告……）。`land` 只在值变化时赋值。

更新路径因此只在值变化时写被观察的属性（`ScanQuietTests` 逐个跟踪每个被观察属性，超过 25 个
即失败）。设置窗口不读 `snapshot` 或行（`surface_check.py` 把守）；AppKit 侧（状态栏图标）用
`ObservationLoop` 只跟随 `snapshot`。测试用 `store.engine.apply(records:nowMs:)` 与 `engine.project(nowMs:)`
驱动一轮。

## 两个来源

### 事件（主干）

`~/Library/Application Support/Pulse/events.tsv` —— **一个**只追加的事件日志（`EventLog`），由原生
`pulse-hook` / `PulseBar --hook`（`PulseHookReceiver`）在排他 `flock` 下追加，或按 Attention Protocol v5
（每行十一列：agent、kind、ms、message、session、cwd、front、pid、保留列（写空、不读）、landing、tool）直接追加。
每个 Agent 的 hook 都以 `pulse-hook <agent> <厂商事件名>` 调用，接收器按 Agent 把厂商事件与载荷
映射成 start / working / tool / 阻塞（permission / question / waiting）/ turn / idle / done / end，
每个事件一行、带自己的时间戳；提示事件带提示原文（标题的来源），工具事件带工具与目标（上一步），
回合事件带最后一句话或错误。契约见 [`attention-protocol.md`](attention-protocol.md)；产品政策见
[`attention-bridge.md`](attention-bridge.md)。

文件有界：追加会让它超过 1 MiB 时先压缩并换一代表头 —— 每个会话（无会话的按 Agent + 目录）留最近
64 行与两小时内的全部行，一天没动静的会话整组丢掉，开着的阻塞连同它之后的行永不丢，正在追加的那一行
永远留下。只按 `\n` 字节分行。

`AttentionWatcher` 用一个 `DispatchSource` 盯着它，写入即触发读取。**启动时**引擎把整份日志读一遍、
逐行应用到会话簿，然后才第一次投影（这次投影是横幅基线）；之后只读游标之后的完整行。表头的「代」
变了（被压缩重写）或文件比游标短时整份再读，已应用过的行按位置认出（`EventLog.unapplied`：重写保持
顺序，每一行对上下一个同文的已应用行；对不上的才是新的）、不重放，同样的一行写两次就应用两次。
**读失败或读到空不改变任何状态** —— 游标与已应用的行都保留，被回答过的阻塞不会因为重读而再红；
文件不存在就是空日志。

### 进程（便宜，按需）

`AgentProcesses` 用 libproc：`proc_listallpids` 列出本用户的进程，`PROC_PIDTBSDINFO` 取父进程、
TTY 与开始时间，`proc_pidpath` 与 `KERN_PROCARGS2` 取可执行路径与参数，按 `AgentCatalog` 的进程
规则匹配到 `AgentID`（排除串必需：`pi` 要躲开 `pip` —— 只看程序本身，`pi ./pipeline.ts` 仍是 Pi；
`cursor-agent` 常驻 worker 按参数排除，不算会话；路径片段
只匹配程序本身 —— 可执行文件，解释器（node / bun / deno）则加上它的脚本 —— 且必须落在
路径分段边界上：`/opt/homebrew/bin/pinentry-mac` 不是 Pi，`claude-*` 辅助程序不是 Claude）。
一次遍历只分配一个 `KERN_ARGMAX` 大小的参数缓冲区（hook 查父链时也一样）。
包装进程与它的子进程收成一个家族（取最上层的 pid）。顺着父进程链回答：真实 TTY、是否在 Warp 里、
宿主 App；`PROC_PIDVNODEPATHINFO` 给出工作目录。不起 `ps` / `lsof` 子进程。

它只在有理由时跑：启动、唤醒、hook 报出一个上次扫描没见过的活 pid，以及一个一次性计时器 ——
30 秒起，每次扫到同一批进程就加倍，封顶 5 分钟，有变化就回到 30 秒
（`ProbeSchedule.processScan(power:quietScans:)`，低电量加倍，息屏停表）。用来：
找出没有会话认领的进程（仅进程行 —— Pulse 启动前就在跑的会话，直到它的下一个事件）；以及知道
会话的 pid 还在不在。每个会话 pid 另有一个 `DispatchSource.makeProcessSource(.exit)`
（`ProcessExitWatch`），退出即结束会话，不等下一次扫描。启动重放与每次扫描还核对会话记下的 pid
是否仍是那个进程（`AgentProcesses.stillRuns`：换成了别的 Agent、或在第一次报出这个 pid 的事件之后才
启动的，都算 pid 被复用 —— 会话已结束）。**一次失败的扫描保留上一份有效列表。**

不读任何厂商文件：没有会话文件、没有 transcript。token、上下文、费用、模型与套餐不显示 —— 这是
决定，`catalog_check` 不放行读这些字段的代码。

## SessionBook（纯值 reducer）

`SessionBook.apply(_ record: AttentionRecord, nowMs:) -> Bool` 是状态唯一改变的地方；键由
`RowIdentity` 一次定下：`agent|<会话 id>`，hook 不点名会话时 `agent|hook:<cwd 哈希>`。

- 状态：`.idle`（刚开始 / 在提示处）、`.working`、`.blocked(Block)`、`.yourTurn(sinceMs:)`、`.ended(atMs:)`。
- `start` → idle（进行中的保持 working）；`working` → working；阻塞 → blocked（`waiting: .none` 的
  Agent 的阻塞行拒收；20 秒内同类的再次提出算同一次，保留第一次的时钟与更具体的那句问题）；`turn` → 轮到你
  （阻塞后 20 秒内**暂存不丢**：宽限期满时由下一个事件或时钟落地，或在早于它的回答到达时立即落地 ——
  被拒绝的权限不会让红灯一直亮；提示窗口在最前时算已看见 → idle）；`idle`（Claude 的 `idle_prompt`）
  只在会话仍在工作或阻塞时算轮到你，从不复活已看过的回合；`done` → 清掉阻塞 / 轮到你（早于当前
  状态的 `done` 不算）；`end` → ended。未来戳拒收；不点名会话的 `turn` 与 `done` / `end` 不造会话；
  协议之外的词不造会话。
- 每个会话还记下：最后 5 个点名工具的 `tool` 行（`Step`：工具、目标、时间）；开始本回合的提示的时间
  （没见到提示时是让它动起来的那一步）；第一条说了事的提示（标题，至多 120 字）与最近的提示；回合事件
  带的最后一句话；`tool` = `error` 的回合带的错误（下一条提示清掉）。全部由启动重放重建，不另存。
- `tool` 行：同一会话在提问之后的工具活动熄灭等待（回答发生在厂商自己的提示里）；提问与工具行都
  点名工具时，只有同一个工具算回答（并行的别的工具结束不算）。每一行都应用，答案前后的并行工具不会
  把它盖掉。
- `settleHeldTurns(nowMs:)`：时钟（每次投影）落地宽限期已满的暂存回合。
- `processExited(pid:atMs:)`、`endSessions(whoseProcessIsGone:)`（死掉或被复用的 pid；会话记着第一次报出
  当前 pid 的时刻 `pidSinceMs`）、`prune(nowMs:)`（一天没动静的忘掉，至多 256 个）。

## TrayState（纯函数）

`TrayState.project(book:processes:context:)` 把会话簿变成托盘，分两步：

`sessionRows` 把会话投影成 `AgentRow`：

1. 知道 pid 的会话只在进程活着时算在跑；不知道 pid 的会话 30 分钟没有事件就是 `.recent`
   （`RecentReason.quiet`，`TrayRowModel.why` 这样说）；轮到你超过 30 分钟也是 `.recent`。
2. 会话认领它 pid 所在的进程家族；没有 pid 的未结束会话认领同目录的进程；没被认领的进程家族
   是仅进程行 `agent|pid:<pid>`（灰色虚线灯，永不橙、不装绿）。
3. 标题、最后的消息、错误、最近几步与本回合时钟都来自会话自己的事件；落地句柄先取事件的 landing 列，
   进程（TTY / Warp / 宿主）只补它没说的；`LandingPlan.make` 据此排出落地步骤（见 `docs/landing-hosts.md`）。
4. 停滞（橙）只给 hook 契约里有逐工具事件的 Agent（`HookContract.reportsToolActivity`：Claude /
   Codex `PostToolUse`、Gemini `AfterTool`、Copilot `postToolUse`、Pi `tool_execution_end`），且会话
   报告过活动；Cursor / OpenCode 只在提示与回复结束时说话，长回合的安静不算停滞。
5. 最近停下的会话 45 分钟后离开列表，`staleHidden` 只计最近 24 小时里停下的。

`assemble` 做排序（Waiting 最久在前 → 状态 → 键，全序）、12 行窗口、灯（`LampFace.glance`）、
菜单栏标题（只在有等待时：数量 · 最久时长）、tooltip（`TrayState.lampRule` / `lampSentence` 一句规则）、
计数（`TrayState.Counts`，每轮投影只数一次，放在 `PulseSnapshot.counts`：灯、托盘头部、VoiceOver 播报与状态项的闪烁都读它），以及**边沿**：上一轮没在等的行，或同一行上的新一次提问（会话在旧提问之后动过，
或超过 20 秒）—— `newlyBlocked`。它把本轮开着的等待（`waitingSince`）交回，`ScanEngine` 下一轮
作为 `previousWaits` 传进来。

一行说什么由 `TrayRowModel` 上的纯函数决定：`headline`、`why`（哪条证据让它处在这个状态、从何时起）、
`stateText`、`ask`，以及步骤与时间的说法；详情页的 `DetailModel` 用同样的函数，所以托盘行与详情页
永远一致。灯的一句规则是 `TrayState.lampRule` / `lampSentence`。Pulse 怎么读一个会话（事实来自 hook
还是只有进程、前往是否精确、进程是否在盯、最近事件）不在详情页上，在「复制报告」里（`SettingsModel.ReportSession`）。

**它们都不做有副作用的事。** 时钟、语言、终端自动化设置都从 `Context` 注入；想让外界做的事作为数据返回。

## 横幅与 StatusStore（外壳）

事件日志 `events.tsv` 归 hook 所有（Pulse 只往里追加忽略时的 `done`）；Pulse 自己**不存会话记录**。
更早版本留下的 `attention.tsv`、`activity.d/`、`session-log.json`、`attention-ledger.json`、`attention-history.json`、`session-timeline.json`、
`dismissed-pending.json` 在启动时删掉，从不读取。

横幅要记住的东西在 `WaitLedger`（纯值，只在内存）：每个开着的等待（按 row key）欠不欠横幅、发没发出、
有没有被忽略，以及限流的锚点（上一条被接受的横幅）。每轮 `reconcile(rows:edges:)`：没在等的行没有
等待，所以解决了的等待不再欠横幅；边沿上的行换成一条新的等待，不继承旧的忽略。启动时重放事件日志
之后的第一次投影是**基线**（重放完成前不投影）：启动时已经在等的不发横幅，30 秒后也不补发。重启后记账从零开始 —— 需要跨启动的
只有 hook 自己的文件。

它也记下每条横幅的 id（`bannerID(rowKey:)` / `summaryID(rowKeys:)`）：等待关上（被回答、被忽略、会话结束）时，
`reconcile` / `dismiss` / `markNotified` 返回要撤回的 id —— 一条横幅只在它点名的某个等待还开着时留着——
`WaitNotifier` 交给 `PulseNotify.withdraw`。点横幅时 `openWait(rowKey:summaryRowKeys:)` 找它点名的、还开着的等待，
找不到就只打开托盘。提示在最前时发生的等待先不发；`WaitingDelivery.deferred` 在它开满 30 秒时交出来，
`WaitNotifier` 那时问一次它的 App 是否仍在最前（`promptInFront`，沿会话进程的父链），不在就标 `frontDue`，
补发一次。

`ScanEngine`、`WaitNotifier` 与 `StatusStore` 一起拥有纯函数刻意不碰的东西：

- **节奏**。没有固定的探测间隔：事件文件一变就处理。`ProbeSchedule.tick` 只是一个便宜的时钟
  （托盘打开或屏上有秒级等待时 5 秒，否则 60 秒，没有会话时停表），用来推进「最近」「停滞」与相对时间；
  `ProbeSchedule.processScan` 是进程查看的退避节奏。`PowerMonitor` 提供息屏 / 锁屏 / 低电量状态：
  低电量加倍，息屏停表 —— 事件日志变化仍会唤醒。
- **通知策略**。投影报告边沿，`WaitNotifier` 决定要不要发：按 agent 静音（行菜单）、在最前、
  开关、授权、限流（3 秒），多于三个同时到达合成一条汇总；Notification Center 接受了才算发出，
  被拒的留着欠账重试。安静时段与声音交给 macOS 的专注模式与通知设置。
- **设置**。`PulseSettings` 是 `Codable` 值，存为 `settings.json`（与 events.tsv 同目录，`PULSE_HOME`
  一起搬；经 `PrivateFile` 以 `0600` 写入；缺字段取默认、未知值取默认）。改设置只走
  `StatusStore.set(_:_:)` / `update(_:)`：值变了才写盘，并只应用变了的那项需要的
  （`StatusStore.effects(from:to:)`：快捷键只为快捷键、登录项只为登录项、语言与终端自动化重新投影，
  静音与通知开关什么都不用做），且只在 `start()` 读过设置之后。`allowTerminalAutomation` 没有设置项，只在 `settings.json` 里改，报告会写出它的值。
- **诊断**。没有诊断窗口：设置的 Hooks 一节每个在这台 Mac 上的 Agent 一行（已安装 / 未安装 / 失败原因、
  「最近事件 N 前」来自 `ScanEngine.latestHookEventMs`、修复按钮），不在的合成一行；「复制报告」
  （`SettingsModel.report`，纯函数）给出版本、每个 Agent 的安装状态与最近事件、通知授权、终端自动化与
  登录项，不含路径、会话或项目。
- **动作**。可靠 Focus、安装 / 移除 hooks、复制报告、忽略 / 静音。

## 视图

`StatusPanelController` 拥有原生状态项和单表面 `NSPanel`；其中承载
`TrayPanel`（一行一个会话的列表 + 一行彩色计数的 Header + 至多一条提示 + 底部按键提示；
→ 进入 `SessionDetailView`，← / Esc 返回），`SettingsView` 是一页五组的偏好（`SettingsModel`；
深链经 `settingsFocus.token` 滚到对应一节）。托盘每次打开的状态（选中、详情页、冻结的顺序、
列表高度预算）在 `TrayUI`；面板的按键监视器把每个键交给纯函数 `TrayKeys.reduce`，所以 Esc 在详情页与
空列表里都有效。行与菜单栏的灯形都来自 `LampFace`（`LampShapeView` / `PulseBrand.statusBarIcon` 绘制）。
SwiftUI 视图都标了 `@MainActor`——SwiftUI 只有 `body` 隐式主 actor 隔离，辅助计算属性不是，
调 store 的 `@MainActor` 方法会编译失败。

视图里不做 I/O。落地计划在投影时算好存进 `AgentRow`。

## 版本身份

`PulseVersion.semver` 是唯一真源。`package.sh` 把 git short sha 与构建日期写进
`Info.plist`，运行时读回，于是有三档：

| channel | 判据 | 显示 |
| --- | --- | --- |
| `release` | bundle 版本 == 编译版本 | `Pulse x.y.z` |
| `dev` | 无 bundle 版本（`swift run`） | `Pulse x.y.z-dev` |
| `mismatch` | 两者不一致 | `x.y.z≠a.b.c` + 橙色警告 |

`PulseDistributionChannel` 另标记分发通道：`preview`（ad-hoc）、`signed`（Developer ID
未公证）、`stable`（公证成功，`PulseNotarized=true`）。无 Apple Developer ID 时 GitHub
仍可将当前 semver 标为 **Latest**，但 Info.plist **不得**写 `stable`，About 保持
preview/signed；只有 notarized 才能自称 Gatekeeper-ready。
更新检查只问 GitHub Releases 有没有更新的版本；有就显示「vX 可用」和一个打开发布页的按钮。
Pulse 不下载、不校验、不替换自己。

`mismatch` 针对的是菜单栏应用的高频陷阱：装了新版，旧的还在跑。

## 事件是运行时真源

七个 Agent 的状态都来自它们自己的 hook / 插件 / 扩展。hooks 按用户选择安装：全部调用原生
`pulse-hook`（无需 Python），只装观察型事件，移除时逐字节还原（`HooksInstaller` +
`hook-installs.json`）。没有任何路径会为了观测会话去 fork 解释器；缺少 Python 不影响 app、
hook 安装或 `--selftest`。

## 门禁

| 脚本 | 守什么 |
| --- | --- |
| `version_check.py` | 版本只有一个真源，CHANGELOG 与 README 徽标跟随 |
| `catalog_check.py` | 名册恰是七个、每个 `AgentID` 一条 spec；Cursor worker 被拒；进程只经 libproc（不起 `ps` / `lsof`）；AppleScript 只在 Automation 授权后；不读 token / 用量 / 费用字段；hook 契约不含拦截类事件，且每个都有出处与测试（`docs/vendor-formats.json`） |
| `make_agent_icons.py --check` | 每个 `AgentID` 都有图标，且与生成器逐字节一致 |
| `surface_check.py` | 表面渲染值、不碰 store；fixture 与截图清单一致；QA 文件只在 `PulseQA`；「为什么」不提 hook；步骤的话从不说「正在」/ running |
| `scenario_map.py` | `docs/scenarios.md` 点名的测试套件与方法都存在 |
| `package_check.py` | 打出来的 `.app` 能找到自己的资源，且二进制里没有 QA 代码 |

前五个由 `scripts/gates.sh` 一次跑完；全部都在 `package.sh` 和 CI 里。截图由 `scripts/qa_surfaces.sh` 与
`scripts/qa_observation_truth.sh` 构建并运行 `PulseQA` 得到。

测试（`PulseBar/Tests/PulseBarTests/`）按组件分文件：`CoreTests`（目录、有界 IO、libproc 进程）、
`VendorFormatTests`（hook 契约与漂移）、`AttentionTests`
（会话簿读事件行、协议、事件日志、hook 接收器、安装器）、`SessionTests`（七个 Agent 的真值表、`TrayState`、身份）、
`NotifierTests`（`WaitLedger`、横幅规划与路由）、`TrayTests`（含行的说法 `RowWordsTests` 与灯的规则）、`SettingsTests`、
`DiagnosticsTests`（报告、Hooks 一节、托盘提示、版本与更新）、`EngineTests`（扫描静默、事件馈送、节奏）。
新测试放进它所测组件的文件，不按发版建文件；`docs/scenarios.md` 按套件名与方法名点名。加上 `swift test`
与 `--selftest`，这是全部自动防线。

**门禁只能守它真正执行的东西。** 凡是加门禁，先把它要防的那个 bug 放回去，确认它会红。

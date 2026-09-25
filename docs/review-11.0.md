# 11.0.3 基线 review 与下一版评估

> 上一份是 [`review-2.2.md`](archive/review-2.2.md)。这份是在 **11.0.3（`0190d00`）** 上重做的全仓
> review：观测管线、受管会话、Respond / hooks 安全面、工程流程四路并行，每条都给
> file:line，头部条目已在当前代码上复核。本环境无 Swift 工具链，结论来自读码与一次
> git 行为实验，**没有跑 `swift test`**。
>
> 路径均相对 `PulseBar/Sources/PulseBar/`，除非另注。

---

## 一句话

**产品的面在 15 天里长了九个大版本，结构只在 4.0 做过一次「按成员搬文件」。** 2.0→11.0
每一版都以「质变」为名加动词和表面（指挥台、受管会话、Fleet、Attention 舱、Panel、
Craft、Composition、Coherence），而 review-1.2 就挂着的 S1（声明式 adapter）与 S2
（StatusStore 拆分）至今未还。结果是一个 **33.8k 行、单 executable target、零编译器并发检查**
的单体，缺陷开始出现在「两个子系统之间」—— 这类缺陷单元测试抓不到，只有结构能预防。

下一版的质变不该再是一个新动词，而是**把 Pulse 从一个 App 变成一个内核 + 两个表面**。
理由与方案见 §4。12.0 Outcome 的内容保留，但它被外部证据（真机 Codex）阻塞，不应占住
下一个版本号 —— 这是 AGENTS.md 自己写下的教训（「Reserving a number for blocked work is
what forced two renames」）。

---

## 1. 必须先修的缺陷（11.0.4，不等重构）

按严重度排序。前三条违反 AGENTS.md 的不变量，是 bug，不是改进项。

### H-1 · Allow 可能签给了另一条请求（违反 No blind approve）

- 按钮在渲染时捕获 `inbound`（`AgentDetailWindowController.swift:177,196-197`；
  `SessionCards.swift:27,42-43`），点击却调用 `store.respondAllow(row)`。
- `writeRespondVerdict` 在**点击时**按 rowKey 重新取请求（`StatusStoreRespond.swift:166`）。
- `matchRespondInbound` 让同一行上更新的请求覆盖旧的（`:106-111`）。任一侧 session 为空时，
  它只按 agent 匹配（`:100-104`）。
- 结果：渲染与点击之间到达的新请求 B 会被签名。HMAC 绑定的是 B 的 id + digest，hook 照单
  全收。用户看到的是 A，批准的是 B。
- **修法**：`respondAllow/Deny` 带上所展示请求的 `requestID + digest`；点击时二者与当前
  inbound 不一致就拒绝，并提示「请求已变，请重看」。

### H-2 · tmux / screen 下 presence gate 把 agent 冻在在场用户面前

- `PromptVisibility.swift:47` 的 `if parent <= 1 { return false }`：父进程链走到 launchd 时
  给出**确定的** false。
- tmux / screen server（以及 iTerm2 的常驻 server）被 reparent 到 launchd，于是前台终端永远
  不是 hook 的祖先。`shouldHold` 据此判定「不可见」，最多 hold 60 秒
  （`RespondContract.swift:213-214`）。
- 不变量的原话是：无法确定时直接放行。
- **修法**：走到 launchd 仍未命中，就返回 `nil`（未知），不返回 `false`。

### H-3 · 受管会话：提交后，验证过的代码被标成「证据过期」

- 指纹 = `HEAD` + `diff-index -p HEAD` + untracked 文件（`AcceptanceEvidence.swift:105-114`）。
- Commit 之后 HEAD 变了、diff 变空，同一份树内容得到新 hash。正常流程「检查 → 提交 →
  推送」必然以「证据已过期」收尾。这让持久证据在最该有用的时刻失效。
- **修法**：以树内容为身份（临时 index + `write-tree`，或 `HEAD^{tree}` + 规范化 diff），
  不以 commit id 为身份。
- 同一处另一个问题：`diff-index HEAD` 比较的是 HEAD 与工作树，staged 与 unstaged 的区分
  丢失。已用 git 实验确认；目前无害，因为 commit 先 `add -A`。

### M-1 · 检查输出存的是头，不是尾

- `ProcessIO.Buffer.append` 只保留前 64 KiB（`ProcessIO.swift:22-28`）。
  `AcceptanceEvidence.make` 的 `suffix` 因此永远是空操作。
- 一次长 `swift test` 留下的是编译噪音，失败摘要在尾部被丢掉。
- `testEvidenceOutputIsBounded` 只测了 `make()`，没测 buffer。
- **修法**：环形保留尾部，或头 8 KiB + 尾 56 KiB。

### M-2 · 回合结束的结果可能丢失

- stdout 最后一块与进程退出各自 `Task { @MainActor }` 投递，互不保序
  （`ManagedRuntime.swift:163-176`）。
- 如果退出先到，`finished` 会 flush 半行，把回合判为 `failed("exit 0")`；晚到的那块随后被当作
  未解析行。一个成功的回合显示为失败。
- **修法**：两者经同一个串行队列排序；终止处理先 drain 管道，再发 finish。

### M-3 · 其余受管问题

- **首回合 continuation 崩溃即丢**：持久化 marker 不看 `continuationID`
  （`ManagedFleet.swift:20-25,176-187`）。首回合中 Pulse 崩溃后，「回复以续」实际开的是新
  对话。
- **检查进程收不干净**：SIGKILL 只打到 `/bin/sh`，检查的子孙进程存活，还可能继续改工作树。
  检查不可取消，退出 Pulse 也不收割。
- **`interrupted` 状态从未产生**：没有调用方会传入它。崩溃中的检查不留任何记录。
- **陈旧的通过仍显示 exit 0**：「是否过期」只在 view `@State` 里、在 appear 或行变化时算
  （`ManagedSessionViews.swift:20-23,186-233`）。用户在编辑器里改了文件，旧绿灯不会熄灭。
  这直接违反 Outcome 计划 自己的发布阻断项。
- **cancel 可能杀错进程**：2 秒后按保存的 pid 发 SIGKILL，不校验（`ManagedRuntime.swift:190-192`）。
  pid 被复用时会误杀。
- **权限请求残留**：被 SIGKILL 的 permission server 留下的请求文件永不清扫，行会一直显示
  权限等待。

### M-4 · 同步通道可以卡死本机扫描（DoS，不能伪造批准）

- `RespondSpool.boundedRead` 先用 `attributesOfItem` 查大小（查的是链接本身），再用
  `Data(contentsOf:)` 读（跟随链接）（`RespondSpool.swift:737-745`）。
- 所以 `requests.d/<host>/` 里被同步进来的指向 `/dev/zero` 的 symlink 或 FIFO，可以绕过
  256 KB 上限，或让读取永久阻塞。`rsync -a` 会原样复制 symlink，`-D` 会复制 FIFO。
- `AttentionIO.readInbox` 同病（`AttentionIO.swift:80-93`）。
- Python 侧读 verdict 与 key 都没有长度上限。
- **修法**：`open(O_NOFOLLOW|O_NONBLOCK)` + `fstat` 确认是普通文件 + 最多读上限字节。

### M-5 · 观测管线

- **数据竞争**：`HarvestDigests` 自称只被 `scanQueue` 触碰（`SessionDigest.swift:326-329`），
  但「复制诊断信息」在主线程读 `HarvestDigests.summary`（`StatusStoreSupport.swift:156`）。
  扫描中按下，会并发读写 Dictionary。
- **digest 永久停滞**：单条 JSONL 记录超过 2 MB 时 `advance` 返回 nil，offset 不再前进
  （`SessionDigest.swift:470-485`）。之后每轮扫描重读 2 MB，也永远不会 `caughtUp`，与能耗
  不变量冲突。
- **部分超时抹掉保留行**：`.failed` 且 `rowCount > 0` 的 adapter 被当作完整上报
  （`ActivityHarvest.swift:346-347`）。Codex 读了 3/10 场就超时，另外 7 行这一轮从托盘消失。
- **轮转游标错位**：游标是按 supervisor plan 过滤后列表的下标（`NativeActivityHarvest.swift:284,440`）。
  deferred 集合一变，游标就指向别的 agent，0.98 的「从停下处继续」失效。
- **Builder 不纯**：`SnapshotBuilder.swift:1010` 经 `AgentRow.lastActivitySeconds` 读墙钟
  （`Models.swift:1161-1165`）。「The builder stays pure」这条不变量实际上破了。

### M-6 · 安装器与更新

- **Codex `notify` 被覆盖**：用户自己的 `notify = …` 被静默覆盖，多行数组会被写坏成非法
  TOML（`HooksInstaller.swift:355-362`），且没有备份。Python 侧的写入不是原子的
  （`src/install_hooks.py:112,147,165,200,222`）。
- **F-4 仍开着**：SHA-256 从同一个 release body 里抓，只能防传输损坏；没有 codesign、团队 ID
  或独立签名校验，挂载前也不重新校验（`UpdateCheck.swift:365-385`；`UpdateInstaller.swift:136-168`）。
  目前被 `isGatekeeperReady` 门住，处于休眠；有 Developer ID 的那天就会生效。

### 已关闭 / 文档过时

- review-1.2 的 U-6 基本已修（稳定 hash seed，`SnapshotBuilder.swift:152-170`），AGENTS.md 仍把它列为 open。
- review-2.2 的 D-4 … D-8 已在代码里修复。
- F-2（整文件 mtime 当作到达时间，`ActivityHarvest.swift:586-588`）仍开着。

---

## 2. 结构诊断：为什么缺陷长在「之间」

| 症状 | 证据 | 后果 |
| --- | --- | --- |
| 单 target 单体 | `Package.swift`：一个 executableTarget，86 个文件、33.8k 行；无 `swiftSettings` | 无法强制依赖方向；测试只能 `@testable import` 一个可执行文件 |
| StatusStore 是分布在 12 个文件里的 god object | 60 个 `@Published`，约 45 个其他存储属性，扩展里约 225 个函数；拆分头注明「Behavior-frozen: moved verbatim」 | 每次 `snapshot = snap` 都重绘所有观察者，包括设置页；Narration 的 1223 行 UI 文案逻辑挂在 store 上直接读 `Date()` |
| 没有 adapter 协议 | `NativeActivityHarvest.swift` 4236 行：描述表 + 一个通用 `collect`，30 处 `id ==` 特判，按路径子串嗅探（`:2138`、`:2143`），122 个带厂商前缀的静态函数 | 加一个 agent 要改 10+ 处（Models 里 4-5 个 switch、ProcessProbe、别名表、图标、TerminalFocus、三个 Python gate…） |
| Models.swift 是杂物间 | 1578 行、约 24 个类型：版本/发布通道、领域类型、托盘 UI 枚举、支持面板、L10n 键；`AgentRow` 约 123 个属性 | 领域事实与呈现状态、时钟读取混在同一个值里 |
| 并发靠约定 | GCD、`Task.detached`、`@MainActor`、`@unchecked Sendable` 混用；静态可变缓存靠「只有一个队列碰」保证安全 | M-5 的竞争就是这样来的，编译器一条也拦不住 |
| 受管 runtime 接缝只做了一半 | `ManagedRuntimeSession` 把 start 与 send 合一、没有 `resolveApproval`、`onFinish(exitCode:)` 假设每回合一个进程；`loadAll` 拒绝非 Claude runtime（`ManagedSession.swift:389`）；行恒为 `.claude`（`ManagedSessionSource.swift:52`） | Outcome 计划 要的「长寿双向 Codex App Server」接不上，只能复制管线或堆条件分支 |

上面每一条单独看都可以说是「风格」，合在一起就是 H-1、M-2、M-5 的成因：**状态的所有权
不唯一，时序没有被类型表达。**

---

## 3. 工程流程

- **版本号已失去信号**：2026-08-26 与 08-27 两天里发了 3.0 → 11.0 共九个大版本，其中 3.0–11.0.0
  **全都没有 `[release]` 提交**。用户实际看到的是从 2.9.0 直接跳到 11.0.1。与此同时，真正的
  兼容性破坏（持久状态 schema v2、v3）发在**补丁版** 11.0.2、11.0.3。semver 被倒置了。
- **文档漂移**：AGENTS.md 仍写「2.0.0 is the current source version」，文档表缺 plan-2.1…6.0、
  review-2.2、evidence-12.0-codex，并把 U-6 列为 open；`architecture.md` 没有 Managed / Workbench
  层，文件名也是旧的（`TrayPanel`、`SettingsView`）。
- **EXPERIENCE.md 不再能当验收依据**：94 KB，§8 有 76 个场景（A–BX），单行长达 2154 字符，
  被测试引用的场景只有 7 个。它已经变成写在规格里的变更日志。
- **测试按发布主题命名**（HeroHonesty、ReturnTruth、LiveWire…），不按模块；大量断言渲染后的
  文案子串，对改文案与本地化都很脆。没有视图快照测试。
- **CI**：macOS runner 上没有任何缓存，也没有 `concurrency` cancel；`claude/**` 每次 push 都
  付全额。release.yml 的 gate 列表与 ci.yml 已经分叉。
- **语言**：计划、CHANGELOG 用中文，AGENTS.md 与协议文档用英文，17% 的代码注释含中文，
  没有成文规则。

---

## 4. 下一版评估

### 4.1 为什么不是 12.0 Outcome

Outcome 计划 在产品方向上是认真的：结果契约、持久证据、不排名。但它现在不该是下一版：

1. **被外部证据阻塞**：它自己的发布定义要求第二 runtime 在真机上过 P0。当前 orb 没有
   Codex binary，`evidence-12.0-codex.md` 只完成了公开协议取证。占住 12.0 等一个外部条件，
   重复的正是 1.0 等公证的错误。
2. **它的地基有 H-3、M-1、M-2、M-3**：证据身份绑错了对象，输出存头不存尾，回合终止无序，
   检查收不干净。在这上面建 Mission / Candidate，就是把这些缺陷复制 N 份。
3. **它会让受管子系统翻倍**（Codex App Server：长寿 JSON-RPC、审批关联、schema fixture）。
   受管代码现在约 4.1k 行（12%），观测核心约 12.1k 行（36%）。翻倍之后，「状态灯」实质上
   变成编排器。这应该是一次**显式的产品决定**，而不是某个版本的副作用。

### 4.2 建议：12.0 = Kernel（内核）

**唯一一件事：把 Pulse 变成一个有类型边界的内核，托盘与 Workbench 是它的两个表面。**

用户可见的质变不是一张新卡，而是三条今天做不到、之后由编译器保证的性质：

1. **所见即所批**：Respond 与受管权限的每个 verdict 都在类型上绑定到渲染时的那条请求
   （`DisplayedRequest` token）。「看 A 批 B」由类型排除，不靠某个 review 去发现。
2. **一处加 agent**：新 agent 是一个 `HarvestAdapter` conformer 加一行 registry；
   coverage / matrix / icon 三个 gate 退化为对 registry 的 Swift 测试。
3. **扫描不重绘世界**：扫描引擎是 actor，托盘、Workbench、设置各有自己的 observable；
   一轮扫描只让快照的订阅者重算。能耗不变量有了结构上的支撑。

#### 目标模块（SwiftPM targets）

```
PulseCore      纯值 + 纯函数，无 AppKit、无文件 IO
               AgentID registry · AgentFacts（从 AgentRow 拆出）· ObservationQuality
               SnapshotBuilder · ProbeSchedule · HarvestSupervisor · RowValueEngine / RowDepth
               L10n 键与表 · Clock 协议（注入，禁止 Date()）
PulseHarvest   依赖 Core；ProcessProbe · SessionDigest · HarvestAdapter 协议 + 每厂商一个文件
               扫描引擎 actor（持有游标、supervisor、last-good rows、digest store）
PulseRespond   依赖 Core；RespondContract / Spool / HookReceiver · Attention IO
               统一 SafeRead（O_NOFOLLOW + fstat + 上限）· DisplayedRequest
PulseManaged   依赖 Core（+ Respond 的 DisplayedRequest）；ManagedRuntime（会话形协议）
               AcceptanceRunner（队列、进程组 kill、持久 running→interrupted）· 树内容指纹
               状态 DTO + 真旧版 fixture 迁移
PulseApp       可执行；薄 StatusStore（协调器）+ TrayModel / WorkbenchModel / SettingsModel
               RowPresenter(lang, clock)（Narration 从 store 移出）· 视图 · --hook 入口
```

依赖方向只能向下。`PulseCore` 与 `PulseRespond` 开启 `-strict-concurrency=complete` 和
warnings-as-errors；其余 target 随迁移逐个开启。

#### 阶段与证明墙

| 阶段 | 内容 | 证明 |
| --- | --- | --- |
| **11.0.4 修复** | §1 的 H-1…M-6，全部带失败测试先行 | 每条一个回归测试；H-1 需要「渲染后到达新请求」的测试 |
| **α 时钟与纯度** | `Clock` 注入；`AgentRow` 里读时钟的计算属性改为接收 `now` | 一个 builder 测试：墙钟与 `context.nowMs` 不同时，输出只跟随后者 |
| **β Core 抽取** | 建 `PulseCore` target，编译器暴露隐藏依赖；`Models.swift` 按事实 / 呈现 / 版本拆开 | `swift test` + `--native-fixture-test` 逐步全绿；1067 个测试零语义改动 |
| **γ Adapter 协议** | `HarvestAdapter { descriptor; collect(root:budget:) -> [Fact] }`；从 Codex、Pi 开始逐厂商迁移；扫描引擎改为 actor | fixture 墙作 oracle；每迁一家都做 hero 值断言对比；`resource_budget_check` 不回退 |
| **δ Store 拆分** | ScanEngine / WaitingDelivery / SettingsModel / RowPresenter；Narration 离开 store | 性能墙：一次扫描对设置页的重算次数为 0（计数器测试） |
| **ε Managed 地基** | 会话形 runtime 协议（startOrResume / send / resolveApproval / shutdown）；AcceptanceRunner；树内容指纹；陈旧判定从 view 移进 store 并由 FSEvents 驱动 | Outcome 计划 证明墙中「Evidence state table」与「Isolation」两组测试提前到此处 |
| **ζ 流程** | 见 §5 | CI 时长与 gate 数量下降，且 release.yml 与 ci.yml 共用同一个脚本 |

**禁止**：与重构同一个提交里改变任何用户可见语义（沿用 Outcome 计划 α 的纪律）；为了拆分
放宽任何 AGENTS.md 不变量。

#### 发布定义

> 加一个 agent 只动一个文件；一次扫描不重绘设置；看到的请求就是签名的请求 ——
> 三句话都由测试或编译器证明，而不是由 review 发现。

少了第一句，是清理；少了第三句，是重排文件。二者任缺其一，都不应取 12.0。

### 4.3 Outcome 之后

Outcome（Mission / Candidate / 可比较证据）作为 **Kernel 之后的下一个大版本**，不预先编号。
开工前需要两个条件：

1. 真机 Codex P0 fixture 已保存（`evidence-12.0-codex.md` 的门）；
2. 一次明确的产品决定：Pulse 是否接受「编排器」这个身份。如果接受，考虑让 Workbench 成为
   独立进程或独立 App，与托盘共享内核但不共享进程，以守住常驻菜单栏 App 的能耗与稳定性；
   如果不接受，受管会话止步于 ε 的地基加单 runtime 的持久证据，产品重心回到「一眼知道」。

---

## 5. 流程重构（随 12.0 一起落地）

1. **版本策略成文**：major 只给持久状态、协议或被移除的能力的破坏性变更；每个落到 main 的
   版本都发布，否则不改版本号；schema 迁移不进补丁版；不预留版本号。
2. **文档**：约 55 份历史 plan 移到 `docs/archive/`，只留一个索引；AGENTS.md 的 Current state
   由 `version_check` 一并校验。EXPERIENCE.md 拆成「现行行为规格（短）」和「场景 ID → 测试 /
   QA 脚本映射表」，版本叙事移回 CHANGELOG。
3. **Gate**：coverage、matrix、icons 改为对 `AgentID` registry 的 Swift 测试；三条 grep gate 合并成
   一个 lint 脚本；保留 package_check、resource_budget、respond_hook 与 fixture 墙。release.yml
   调用 CI 的同一个脚本。
4. **CI**：缓存 `.build`；gate job 只跑在 Linux；`claude/**` 分支的 macOS job 只在 PR 上或按
   路径过滤触发；加 `concurrency: cancel-in-progress`。
5. **测试**：按模块重组；文案子串断言改为对结构化 row model 断言；给托盘行和卡片补浅色 /
   深色快照测试。
6. **语言**：代码注释与 agent 面文档用英文，用户可见文案与 CHANGELOG 用中文，写进 AGENTS.md。

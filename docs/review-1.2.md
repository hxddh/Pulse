# Pulse 深度 review（基线 1.2.0）与下个大版本评估

> **状态：2.2 已全部关闭。** 本文列出的缺陷（1 critical + 约 10 major + MINOR 批次）
> 已在 1.2.1（运载路径八项）与 2.2（其余全部）修完，每条配回归测试；修复前都在
> 当时的代码上重新核实过仍然存在，没有拿旧结论开工。结构债 S1（声明式 adapter 契约）
> 与 S2（StatusStore 拆分）仍然开着 —— 它们不是缺陷，是下一个新轴的先决条件。
>
> 原始状态说明： 本文是审计记录 + 方向评估，不是计划书。发现按子系统列出，
> 修复归属由后续计划分配；下个大版本的计划仍是 [`plan-2.0.md`](plan-2.0.md)，
> 本次 review 为它补上了 P0-0 的第一份证据（见该文件）。

范围：`PulseBar/Sources`（22.6k 行 Swift）全部 72 文件、29 个测试文件、七个门禁脚本、
发布链路、attention 协议、全部 plan/EXPERIENCE 文档。方法：按采集器 / 状态机与 UI /
Respond 与 hooks / Fleet 与基建四条线逐行审读；重点发现均已对照源码逐字抽查
（标注 ✓ 者为本次已抽查核实，未标注者引用处 file:line 俱在，修复前先复核）。

---

## 0. 一句话结论

**观测这条线已经到了收益递减点，质变在换动词。** 0.50 → 1.2 的每一个大台阶
（Signal Quality、Ground Truth、Full Transcript、Substance）都是同一个动词「看见」的
诚实化，1.1 读完整场会话之后，这条线剩下的是信号搬运，不再有台阶。计划里唯一
换动词的方向 —— Respond（从「让你去看」到「把你的判断送达」）—— 一直阻塞在
P0-0「真机契约证据」上。**本次 review 取到了这份证据的主体：契约成立，
最悲观的分支（Q2=否，只能做「一键拒绝」）可以排除**，详见 plan-2.0.md 的
证据一节。同时，本次在四个子系统里发现 1 条 critical、约 10 条 major 缺陷，
其中若干条恰好压在 Respond 的运载路径上（hooks 安装器、hook runner、判决管线的
前身），应作为大版本的发布门槛先修。

---

## 1. 采集器（NativeActivityHarvest / SessionDigest / Probe）

### CRITICAL

| # | 位置 | 发现 |
| --- | --- | --- |
| H-C1 ✓ | `NativeActivityHarvest.swift:1671-1679` | 全局字节预算耗到「低但未空」时，`budget.reserve` 失败只是静默 `return nil`，既不置 error 也不 noteTruncated；`budget.exhausted` 仍为 false，adapter 状态落到 `.noSessions`。而 `ActivityHarvest.mergePartialRows:200-213` 把 `noSessions` 当可信空结果，**允许清掉该 agent 上一轮的好行**。一次触发同时破两条 invariant：「没看到」被报成「没运行」，且 harvest 资源不足清空了扫描。修法：reserve 失败视同 timeout，让状态落 `.failed` 以保留旧行。 |

### MAJOR

| # | 位置 | 发现 |
| --- | --- | --- |
| H-M1 ✓ | `NativeActivityHarvest.swift:1907-1917` | `normalizeTimestamp` 的 `ISO8601DateFormatter` 未开 `.withFractionalSeconds`，后备格式全是空格分隔 —— `2024-12-03T14:00:01.000Z`（Claude/Pi 的实际格式，仓库自己的 fixture 即如此）解析失败返回 0。后果：`stamped` 永不生效，`activityMs` 退化为文件 mtime，同文件碎片时间戳相等，0.95 特意做的「pending 跟随最新碎片」退化回 OR 语义 —— 正是 0.95 要消灭的假 Waiting 路径。顺带：formatter 在逐行热路径上每次新建（性能）。 |
| H-M2 | `NativeActivityHarvest.swift:811-814` | 目录遍历上限 1536 项且无 mtime 排序；Claude/Codex 重度用户几个月即超限，活跃会话是否被扫到取决于枚举顺序。Pi 已为同类 bug 单独修过（:908-914 先 stat 按 mtime 排序），修法未推广到其余 adapter。 |
| H-M3 | `NativeActivityHarvest.swift:373-383` | Cascade/Windsurf 去重只在单次完整 scan 内生效；游标轮转、supervisor 熔断、scoped 扫描三种常态路径绕过它，`mergePartialRows` 保留旧 cascade 行 + 新 windsurf 行 → 同一 pending 会话两盏灯。去重应下移到 merge/builder 层对「当前+保留」合集做。 |
| H-M4 | `SessionDigest.swift:332-336` | 读到「声称的文件末尾」时末尾块即使无换行也全量折入；写入方分次 write 长记录时半行被计 1 条、下轮后半行再计 1 条 —— 注释承诺的「Never fold a half-written record」被破，且以「精确值」身份上报。现有测试只盖了「仍在增长」分支。 |
| H-M5 | `NativeActivityHarvest.swift:2932-2934` | `textFacts` 对 `.txt/.md/.log` 自由文本用正则抬 `skill=pending` —— markdown 里引用一段 `"status": "waiting"` 的 JSON 示例即可点灯（waiting-none agent 除外）。与「Waiting 绝不推断」的边界打架；`textFacts` 应只产出展示字段，永不产出 pending。 |
| H-M6 | `NativeActivityHarvest.swift:2109,2219` | Codex `records` 是「窗口内候选行数」（prefix 8 + suffix 2048），未截断标志下以精确值姿态上报；digest 追平前若干轮是错的。 |

### MINOR（选录，其余见审计记录）

`Row.isCompleted` 子串匹配把 `"incomplete"` 判成 completed（`ActivityHarvest.swift:132-142`）；
Claude/Pi 的 cwd 解码把路径中每个 `-` 还原成 `/`，错误工作区可能喂给 Focus 落地
（`NativeActivityHarvest.swift:3156-3164, 2576-2584`）；Grok 的 roots/豁免/限额三者互相矛盾，
存在从未读到的信号源（:601, :822-828, :957-958）；digest 存盘先写后 chmod 有 umask 窗口
（`SessionDigest.swift:390-402`）；attention stop 宽限用原始 tsMs 而非 effectiveMs，与
clockVerdict 政策不一致（`ActivityHarvest.swift:503-507`）；每 probe tick 两次 `ps` fork +
六条一次性线程，可合并（`ProcessProbe.swift:214-221`）；digest 追平 IO 不占 `ScanBudget`，
「每拍 IO 上限」实际可超（:1010-1016）。

### 结构债 S1：adapter 不是抽象，是 3459 行 enum + 12 处 by-id 分叉

新增一个非平凡 agent 要碰的散点：descriptors、ProcessProbe.rules、窗口分支、
stale-skip 名单、解析分派、continuation 名单、merge 特例、去重伙伴、三个门禁。
Pi 踩过的每个坑（mtime 排序、SQLite 让位 JSONL、oversize 行）都以 Pi 专属 if 落地
而非能力开关 —— 测试里 Pi 占 54 例中的 24 例即是佐证。缺的是声明式 Adapter 契约
（roots / 窗口策略 / 排序 / 解析器 / 去重伙伴 / 时间策略集中一处）。**实时化、
跨机器、双向通信任何一个新轴都会再乘一遍这 12 处分叉的复杂度，S1 是它们共同的
先决条件。**

---

## 2. 状态机与 UI（StatusStore / SnapshotBuilder / PulseApp）

| # | 位置 | 发现 |
| --- | --- | --- |
| U-1 ✓ | `SnapshotBuilder.swift:768` → `Models.swift:970-974` | builder 纯度的字面违反：tooltip 的停滞时长经 `lastActivitySeconds` 读墙钟 `Date()` 而非 `context.nowMs`。同一条规则在 `isStalled` 上修过（注释俱在），此处漏网。更大面积的未贯彻在 store 呈现层：`rowStoryLine` 等约 600 行纯决策以 store 方法形式在每次 render 里执行并反复读 `Date()`，与代码库自己写下的迁移理由矛盾。应下沉为注入时钟的 RowPresenter。 |
| U-2 ✓ | `StatusStore.swift:2251-2271` | `refresh()` 后台回调硬编码 `AppServices.store` 单例：非单例实例的扫描结果写进别人、自己 `scanInFlight` 永真、后续 refresh 全部无声吞掉。生产单例不炸，但**扫描管线因此不可测**（全部测试绕开 `refresh()` 只打 seam）——也是 Respond 的 P0-3 要挂载的位置，先修。 |
| U-3 | `PulseApp.swift:539-544` + `StatusPanelController.swift:41-57` | TrayPanel 的折叠/搜索/filter `@State` 跨开合持久（视图常驻窗口层级，无重置路径），与 EXPERIENCE §4「展开状态不持久化，每次打开都从『谁需要我』开始」直接冲突。验收依据的硬规则被违反。 |
| U-4 | `AttentionWatcher.swift:94-98,119-123` | attention.tsv 被删/原子替换后的重挂 handler 只 `arm()` 不 `armInbox()`，`attention.d/` 收件箱监听静默失效直到重启 —— 远端 raise 退化为轮询兜底。Fleet 场景下从边角升为主路径问题。 |
| U-5 | `SnapshotBuilder.swift:262-264` + `StatusStore.swift:2504-2507` | 只要有会话在跑，每次扫描（2–5s）都重写一次 `dismissed-pending.json`，集合根本没变。仅在实际变化时持久化。 |
| U-6 | `SnapshotBuilder.swift:211-215` | rowKey 去重后缀 `#n` 取决于行数与 harvest 顺序，跨扫描不稳定；snooze / soft-dismiss / 通知去重 / Look 指纹全键在 rowKey 上，键漂移即 snooze 无声丢失或 Waiting 边沿重放。Respond 的判决若经行身份寻址，此处必须先稳定。 |
| U-7 | `StatusStore.swift:2893-2908` | `clearWaiting()` 不撤销已提交 Notification Center 的 in-flight 请求（可用 `removePendingNotificationRequests` 补），AH 场景「无迟到通知」只覆盖了未投递队列。 |
| U-8 | builder → `StatusStore.swift:2855` | 远端行 lostContact 被记入「已结束的等待」历史 —— 行叙事说「失联≠完成」，历史记录却记成 resolved。 |
| U-9 | `SnapshotBuilder.swift:741-746` 等 | tooltip waitKind、`summaryLine`、attention bridge 提示串绕过 L10n（内联双语），违反「所有面向用户的串走 L10n」。 |

**性能热点**：`supportHealth` 是计算属性，内部调 `AttentionIO.latestEventTimes()`
（flock + 全文件读），`SupportCoverageView` 一次 render 调它约 10 次 —— 主线程每帧
十次文件 I/O；`safeSupportReport()` 直接在 view body 里生成（内含收件箱磁盘遍历）。
应物化为每扫描一次的快照。

**结构债 S2：StatusStore 4548 行揉了 11 种职责**（扫描编排 / 通知投递状态机 /
ledger 协调 / Look 连续性 / 行文案 / Support Health / 诊断报告 / 设置迁移 / 更新代理 /
预览注入 / DebugLog+LoginItem 顶层）。两个硬症状：40+ `@Published` 使任何变更全面重算；
扫描管线零集成测试（因 U-2）。建议拆分：ScanPipeline（接口化依赖）、
WaitingNotificationCoordinator、RowPresenter、SupportHealthSnapshot。PulseApp 3058 行
是文件组织问题，按视图拆 5-6 个文件即可；`MenuBarLabel` 是死代码（EXPERIENCE §8
代码落点表仍指向它，文档漂移）。

---

## 3. Respond 与 hooks 基础设施

**契约与模型层的结论见 plan-2.0.md 证据节。** 代码发现：

| # | 位置 | 发现 |
| --- | --- | --- |
| R-1 ✓ | `HooksInstaller.swift:36,197-210,253-257`；`install_hooks.py` 同病 | `pulseMarkers` 含通用 token `"--hook"`：每次 install 都执行的 `stripPulseHooks` 会删除任何序列化里含 `--hook` 子串的**用户自有** hook 条目（如 `mytool --hook-dir …`）；`.pulse-backup` 只保首装快照，救不回后续损失。**今天就在伤害用户，先修。** |
| R-2 | `HooksSupport.swift:212-214` + `PulseHookReceiverTests.swift:83-89` | 测试 `testSelfTestDoesNotNeedPython` 未设 `homeOverride`，在开发机跑一次测试即把真实 `hook-runner.path` 改写成 xctest 路径 —— Waiting 灯路断到真 Pulse 重启为止。恰好会毁掉取 P0-0 证据那台机器的通路。 |
| R-3 | `HooksInstaller.swift:220-223` | `ensureClaudeEvent` 见 marker 即 early-return，**已装条目永不更新** —— Respond 必须把 PermissionRequest 的 timeout 从 5 提到几十秒，现有安装不会迁移。需要「识别并重写自有条目」的版本迁移机制。 |
| R-4 | `RespondContract.swift:87-90` | 判决只绑 `requestID + digest`，不绑 agent/host —— P0-5 多主机场景下隐式依赖厂商 id 全局唯一。加绑成本为零。 |
| R-5 | `RespondContract.swift:98` + hook 进程模型 | 「单次使用」只在托盘进程内存里成立；hook 是独立短命进程，跨进程恰好一次消费（flock + 原子 rename）完全未建 —— **这是 P0-3 的实质**。`RespondDecisionStore`/`RespondHold`/`UserPresence` 目前全部零调用方（dead code by design，地基先行）。 |
| R-6 | `RespondContract.swift:54,69-73` | digest 对 `fullRequest` 字符串计算，但 `tool_input` JSON 的规范化序列化未定义 —— 键序不稳定则两端失配（fail-closed，安全但伤可靠性）。需定义 canonical 形式与 redaction 策略字节一致。 |
| R-7 | `scripts/qa_respond_contract.sh:56,141` | 引用已改名的 `plan-1.1.md`，且所谓 "shapes worth trying" 在任何文档里都不存在（本次证据已把候选形状写进 plan-2.0.md）；:15 声称 redact 但 capture 落盘的是原文，只有 shape 报告脱敏。 |

正面记录：拒改非法 JSON 并保留原文件、marker 缺失 fail-open、Swift/Python 双实现镜像、
attention 协议 v2 实现与文档互证完整（host 列、收件箱有界、20s stop 宽限、
「能写收件箱=能点灯」的信任边界已如实声明）。

---

## 4. Fleet / 更新链路 / 门禁 / 测试

| # | 位置 | 发现 |
| --- | --- | --- |
| F-1 ✓ | `AttentionIO.swift:82` | 收件箱从文件**头部**读 256KB —— TSV 尾部追加，远端文件超限后被丢的恰是**最新**事件：新 raise 永不可见、旧行持续可见。截断方向反了，应读尾部。 |
| F-2 | `ActivityHarvest.swift:433,524` | 整文件共用 mtime 作 `receivedAtMs`：活跃 host 不断追加 → 一条 2 小时前的未决 permission 走 trustArrival 后 effective≈now，**永不过期、永不 lostContact** —— plan 最怕的「重新开始说谎」形态。plan P0-5 要求的丢弃留痕（DebugLog + 计数）也未落实，全是裸 `continue`。 |
| F-3 ✓ | `UpdateInstaller.swift:179-188` | `mountDMG` 按整行 `hasPrefix("/Volumes/")` 找挂载点，而 `hdiutil attach` 输出行首是 `/dev/disk…`、挂载点在 tab 第三列 —— **paths 恒空，应用内「下载并验证」链路疑似恒失败**。`UpdateInstaller` 全类零测试，互相印证。改按 tab 切列或 `-plist`。 |
| F-4 | `UpdateCheck.swift:365-385` + `UpdateInstaller.validate` | 更新无独立验签：SHA-256 与 DMG 同源同信道（防损坏不防仓库/CI 沦陷），validate 不做 codesign/spctl；helper 重挂 Downloads 里的 DMG 时不重验 hash（TOCTOU，当前 gate 在 isGatekeeperReady 恒 false，属休眠炸弹，拿到 Developer ID 即成实弹）。长期应引入独立签名密钥（EdDSA）。 |
| F-5 | `coverage_check.py:208-223` 等 | 门禁体检：version/matrix 主体/icons/resource/package 是真门；coverage 后半的字符串存在性检查是纸老虎且含永不触发的死分支；appearance 的 FROZEN 正则单行可绕。按 AGENTS.md 自己的标准（「加门禁先把 bug 放回去确认会红」）清理或降级为提醒。 |
| F-6 | 测试整体 | 行为导向、质量高于平均（GroundTruth 断言 hero 值、LiveWire 实测行为、bitmap 视觉回归）。软肋：fixture 全部手写 vendor-shaped，与真实格式脱节的风险只是被诚实记录、未被消除（plan-1.0 已知缺口 1）；`UpdateInstaller` 零覆盖；`refresh()` 管线零集成测试（U-2 所致）。 |

安全 grep：非测试代码 `try!`/`as!` 零处、强制解包仅 3 处且有守卫、TODO/FIXME 零处;
AppleScript tty 插值未过滤换行但值域受内核约束（建议顺手拒绝控制字符）；TSV 写入
redact/去 tab 到位。

---

## 5. 下个大版本评估：质变 = Respond

### 为什么观测线不再有台阶

1.1 之后采集器已能读完整场会话；1.2 把打转搬上界面后，摘要里剩下的
（累计 token、recentTools 时间线、追平进度、文件增长速率）都是**信号搬运** ——
有价值，但每一件都是「更好的灯」，不改变用户与产品的关系。灯的极限是：
**你仍然要放下手头的事，走过去。**

### 为什么是 Respond

- **它是计划里唯一换动词的方向**，且 1.0 之后逻辑闭合：看见的边界消失后，
  「够得着」就是唯一的边界（plan-2.0.md 的原话）。远端场景里这个反差最刺眼 ——
  Pulse 能说出「devbox 上的 Claude 等授权 6 分钟了」，然后你得 ssh 过去。
- **唯一的阻塞项 P0-0 已经从「能不能」收窄为「一次 30 分钟的真机确认」。**
  本次取证（见 plan-2.0.md）确认：PermissionRequest hook 收到稳定 `tool_use_id`
  与完整 `tool_input`，stdout 可携带 allow/deny 判决，超时干净回落（fail-open 成立），
  厂商默认超时 600s —— plan 里「厂商只给 5 秒」的前提是错的，那个 5 是 Pulse
  自己写进 settings 的。「让 Agent 等你几十秒」没有厂商侧障碍。
- **产品形态可以按「完整应答」立项**，不必按最悲观的「一键拒绝」预留退路 ——
  但 `canOfferAllow` 的纪律不变：拿不到完整请求就没有「同意」按钮。
- 安全模型（双绑定 / 单次 / TTL / 不做规则引擎 / 判断权不转移）已在 1.0.1 落地
  且有测试钉死；剩余工程量集中在 R-3/R-4/R-5/R-6 与 UI 接线，量级是一个大版本，
  不是一次冒险。

评估过、本版不选的两个方向：

| 方向 | 判断 |
| --- | --- |
| **Live Wire 实时化**（事件驱动采集：FSEvents 订阅 vendor roots、digest 升格常驻 tail-follower、walk 降为兜底） | 质变第二候选，且能耗反而降。但用户感知仍是「更快的灯」；而 Respond 的 hold/送达天然逼出事件化 —— 作为 Respond 之后的版本更顺。 |
| **Fleet running 视图**（跨机器完整观测） | 需要重新引入 0.99 刚删掉的 wire 契约 + 传输 + 鉴权，投入最大；且快照/健康聚合缺 host 维度（见 U-系列），先决工程与 Respond 的 P0-5 重叠 —— 让 Respond 的远端应答先把 host 维度逼出来。 |

### 发布门槛（先于 Respond 特性合入）

Respond 把「能写入的人的最坏后果」从假警报抬到代批准，运载路径上的既有缺陷
必须先清：

1. **R-1**（安装器吞用户 hook）与 **R-2**（测试污染真机 runner path）—— 今天就在
   伤害用户，且 R-2 会毁掉取证机器的通路。
2. **R-3**（已装条目永不迁移）—— timeout 提额靠它。
3. **H-C1 / H-M1**（预算静默清行、时间戳解析）—— Waiting 的可信度是判决 UI 的地基。
4. **U-2**（refresh 单例硬引用）—— P0-3 送达管线挂载点，先让它可测。
5. **U-6**（rowKey 不稳定）—— 判决与行身份的映射不能建在会漂移的键上。
6. **F-3**（更新链路恒失败）—— 用户拿到 Respond 版本的通道本身是坏的。
7. **F-1 / F-2**（收件箱截断方向、mtime 永葆青春）—— 远端应答（P0-5）依赖的
   收件箱必须先说真话。

### 明确不做（沿袭 plan-respond，一字不让）

规则引擎 / always-allow / 自动批准；替用户判断；扩到 32 个 Agent；
配额/费用 HUD；托盘外的任何新表面。EXPERIENCE §1 非目标按 plan-respond 的措辞
**收窄**（「Pulse 仍不替你判断，它只是把你的判断送达」），不删除。

### 结构性投资（与特性并行，不占版本号）

S1（声明式 Adapter 契约）与 S2（StatusStore 拆分）不直接对用户可见，但 Respond、
实时化、Fleet 三个未来轴都在同一堵墙上 —— 本版至少完成 ScanPipeline 拆分（U-2 的
根修）与 RowAction 建模（行动作目前是四处复制的 if-else，Allow/Deny 会是第五处）。

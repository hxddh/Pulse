# Pulse 体验规格

**这份文档是 UI / UX 改动的验收依据。** 改了行为就同步改这里，否则文档漂移，
下一个接手的人会照着假规格做事。

描述的是当前实现（3.0.0），不是路线图。历史沿革看 [`CHANGELOG.md`](CHANGELOG.md)。

---

## 1. 产品一句话

Pulse 是**菜单栏状态灯**：扫一眼知道编码 Agent 要不要你；点一下看到该谁、为何等；
设置里只改行为，不看热闹。

### Job to be done

- 开会 / 写文档时：不切终端也知道「有人在等我」。
- 多 Agent 并行时：分清谁在跑、谁在等，避免空转。

### 非目标（明确不做）

- 额度 / 费用 / 重置倒计时 —— 那是另一个产品。（**边界在「配额与账单」，不在「数字」**：
  会话 token 是「它干了多少活」的观测，2.1 起正常显示；剩余额度、花了多少钱、
  几点重置，一概不做）
- 桌面宠物、像素角色、统计大盘
- 把偏好设置当第二块实时 HUD
- 为「覆盖更多名字」牺牲会话可读性
- 替用户判断 —— 没有规则引擎、没有 always-allow、没有「Pulse 认为可以」。
  Respond（场景 AR）送达的是**你的**判断，且只对逐 host 密钥 opt-in 的远端请求、
  只在完整请求可见时才出现「同意」；判断权一寸不转移。对着托盘一行截断摘要
  的「盲批」仍然明确不做

---

## 2. 三层分工（硬规则）

| 层 | 用户问题 | 唯一职责 | 禁止出现 |
| --- | --- | --- | --- |
| **Glance**（菜单栏） | 要不要抬头？ | 状态语义 + 极短线索 | 长句、token 明细、设置项 |
| **Tray**（下拉） | 谁、为何、我能做什么？ | 等待优先列表 + 可行动作 | 实时更新开关、语言、hooks 安装 |
| **Preferences** | 我想怎么用 Pulse？ | 行为与连接配置 | 大标题状态看板、重复 tray 的信息 |

**信息流向：** 探测 / hooks → SnapshotBuilder → Glance 编码状态 → Tray 展开细节 →
Prefs 只改开关与连接。

---

## 3. Glance（菜单栏）

菜单栏在有等待时显示能放进 **8 个显示宽度** 的标题：`Claude…`，或超限时的
`1 · 4m` / `1`；多个等待用数量。
**禁止常驻动画**：新等待出现时闪一次即止。永久呼吸在 30 秒和 40 分钟时长得一样，
既不携带信息，又和真正表达紧迫度的时长抢注意力。


**主信号是图标语义**，不是靠读文字。灯标将红、绿、灰、橙状态色写入图标像素并使用
非 template 图像；`NSStatusBarButton.contentTintColor` 必须保持 `nil`，让相邻标题由
菜单栏自己的 effective appearance 保持对比度。不能用 content tint 同时染图标和文字，
也不能退回只剩单色、看不出状态的 template 图标。
**辅信号是短标题**，宽度紧张时只留图标。

| 状态 | 灯 | 标题 | 触发 |
| --- | --- | --- | --- |
| Waiting | 暂停形 | `Claude…`，超限 `1 · 4m` / `1`；多个时用数量 | 有任意行在等你 |
| Running | 实心灯 | 单名或数量 | 有**健康** live 会话（有活动时钟且非仅进程），且无停滞 |
| Idle | 脉冲线 | **空** | 只有最近会话，或什么都没有 |
| Stalled / Error | 橙色脉冲线 | 数量 / `!` | live 会话停滞；仅进程 / 无活动时钟的 Running；或 probe 与 harvest 同时不可用 |

规则：

- **Glance 优先级（非 Waiting）：** 任意停滞 → 橙；否则健康 Running → 绿；否则仅进程 / 薄 Running → 橙（不得装健康绿）。
- 标题预算 **≤ 8 个显示宽度**（CJK 按宽字符算），超限降级：Waiting `1 · 4m` / `1`；Running `1`。`Claude…`（7 格）仍可。
- Agent 产品名**始终英文**（Claude、Codex…），即使界面是中文。
- Glance 不显示 tokens、相对时间、项目路径。
- Idle 必须安静 —— 不刷「空闲」这种没信息量的词。
- `LSUIElement`：无 Dock 图标；启动不闪窗。
- Tooltip 一句状态，可略长于标题；停滞主导时尽量带无活动时长。

---

## 4. Tray（下拉面板）

### 结构（固定顺序）

```
① Header（状态 + 刷新 + 更多操作）
② 分组表头 + Agent 行（默认最多 12 行，每 Agent 模型容量 500 个会话）
③ [另有 N 个…] / [另有 N 个会话未显示]
```

采集器每 Agent 最多读取 500 条，Swift 模型保留其中最多 500 条，面板默认只展开全局前 12 条。
三层预算分别服务于输入完整性、内存安全与扫视密度；超出 glance 窗口的会话必须精确计数，
不得让“看起来只显示 12 条”反向限制实际检测。
**Header 状态计数用全量 `sectionTotals`**（非搜索时），不得把窗口里可见的 9 行运行中
写成舰队只有 9 个；「另有 N」仍说明未展开的行。

面板宽度为 448pt，高度**由内容决定**（测量后封顶），不得用手写的高度加减法。
默认封顶 660pt，展开 700pt；不能在底部只露出下一组表头却不露任何一行。

面板不设独立顶部提示条、底部工具栏或上下分割线。刷新常驻 Header 右侧；
跳到等待最久、清除等待、Waiting 连接、偏好设置、诊断信息与退出收进「更多操作」。
版本属于诊断 / 关于信息，不占实时观测面板的一整条页脚。

### ① Header

最多两行：上行只答状态（需要你 / N 个等待中 / N 个运行中），下行只承载单行无法
表达的聚合信息。四态分别着色，不能因为有一个等待就把 Running / Stalled / Recent
一并染红。右侧只有刷新与「更多操作」两个紧凑入口。

> 下行曾是相对时间，但它在 `updatedAt = Date()` 之后立刻计算，恒为「刚刚」——
> 一个常量占着一整行。**不携带信息的位置要么给它真信息，要么删掉。**

### ② 分组表头

行按分组呈现，表头形如 `需要你 · 2`。计数是**全量**计数，不是窗口内的条数。

- 默认按状态分组：需要你 → 运行中 → 停滞 → 最近。停滞是仍有进程但超过用户设定
  活动阈值的会话，**不计入运行中**。
- 可切换按项目分组（设置 → 通用）；含等待的项目排在前面
- 「需要你」表头用等待色，其余用次级色

排序做了却不呈现，等于没做：五行平铺读起来就是五个平等项。

**所有分组默认展开**。表头只在用户主动折叠后变成
`▸ 最近 3 Claude · Cursor`；默认不能让计数说有三条、内容却只露一条。

按项目分组时，**不含等待的项目组同样可折叠**；含等待的项目永不折叠——
把需要你的那件事折起来，等于产品失效。

**折叠只在面板真的挤的时候才启用**（总行数 ≥ 5）。
0.27 的截图里三个会话折走了两个，屏幕上只剩一行——
折叠是拿「一行屏幕」换「一次点击 + 内容被藏起来」，
**只有屏幕真的稀缺时这笔交易才划算**。

折叠态的表头：摘要已经把每一行都点名时不再发计数
（`No project 2 Pi · Amp` 里的 2 是同一个事实说第二遍）；
摘要收敛了才发（三个 Claude 会话摘要成一个「Claude」，那时计数才是唯一说清数量的东西）。

折叠只在**它不是全部内容时**生效：如果面板里只有「最近」，那些行就是内容本身，
折起来剩一句「最近 3」等于什么都没说。同理只有 1 行时不折——省不出空间，只多一次点击。

折叠态必须带上组内的 Agent 名。只报数量不报身份，恰好是折叠制造出来的问题。

展开状态**不持久化**：每次打开托盘都是一次新的扫视，应该从「谁需要我」开始，
而不是从上次的翻找状态开始。

### ③ Agent 行

**主语是会话，不是 Agent。**

- **身份行** = 6px 状态灯（等待红 / 运行绿 / 最近灰 / 异常橙）+ Agent 产品名 + 运行时证据等级（仅缓存 / 仅进程时出现）+ 非常态芯片。
  32 个图标不是识别测试；产品名必须可直接扫读。更多操作只在悬停 / 键盘选中时显形，
  但 VoiceOver 动作始终存在
- **主行** = 会话标题（真实用户目标；Claude/Command Code 跳过 `tool_result`；
  Codex 剥 Desktop 信封；Pi 与 `/resume` 一致：最新 `session_info.name`（空则清除）否则第一条用户句；
  剥 `<environment_context>` 留后半句，未闭合 env 不当标题；不是 `Pi session` /
  `Read Foo.swift` / 工具回包；无标题时依次退到**人话工具名** → 项目名 →
  终端/应用会话短语）。禁止 `update_plan` / `Bash` / 文件名 / `Agent session` 当标题；
  禁止把 Agent 产品名再当主行（身份行已有）。
  —— 最多两行（列表拥挤时也不砍真实标题尾部）。标题不与状态、时间或菜单争同一行。
  **任务名的后半截才是识别它的那半截**，宁可多占 16pt 也不切掉
- **叙事行**（0.91 / **0.92 事实所有权**，有话才出现）= 一句回答「这个会话在干什么 / 为何出现在托盘」：
  可读 phase · 人话工具（标明最近动作，**不**冒充 Now）· 刚发生的 Changed；
  quiet live 无 phase 时回落最近动作或 model/tokens；仅进程 / 薄 cache 用**证据年龄 · 最强事实 · nextStep**；
  Waiting **不**复述芯片上的种类·时长（无消息时只补信号来源）。空则整行消失，不发明 Waiting / 进度占位
- **次行** = `{路径} · 最近活动：{相对时间}`（始于…）；**叙事行已有最近动作时次行不再重复**；
  例如 `~/code/Pulse · 最近活动：12 分钟前 · 始于 42 分钟前`
  —— 最近动作必须把 `update_plan` 等内部标识翻译成人话，并明确它是历史事件，
  不能伪装成仍在执行；主行已是该人话工具时次行也不再重复
- **次行右端** = 开始时间，例如 `始于 42 分钟前`，不得写成含义不明的 `session 42m`
- **运动信号行** = Now / Changed；**叙事行已带 Now 或 Changed 时让位**（整行可消失）
- **观测行**（有数据才出现）= `模型调用 · 入 12k · 出 3k · 641 条事件`
  —— **默认显示，不藏在悬停或 Details 里**；事实按信息量取（动态优先、值为 0/未知不出现、
  条数随内容浮动，见下），详情审视器提供完整证据（含同一叙事 + Changed）
- **等待详情**（仅 Waiting）：`↳ 消息 · 来源`（**消息优先**；种类·时长在芯片）
- **离开再回**（0.93 Look Closure / **0.96 Return Truth**）：关闭托盘打指纹（含
  `waitSinceMs`）；**重开后的扫描完成再算**具名变化（新等待 → 已结束等待 → 有变化会话，
  最多 3 条 +「+N」）；同行新等待世代优先于 ended，ended 不双计为 moved；一点滚到优先行
  （复用 Go-Look）；受影响非 Waiting 行有短暂「离开后有变」标记直至确认；不发明 Waiting
- 完整路径、完整 session id、重复的任务原文属于诊断噪音，不进入主界面

**事实按信息量取，不按固定条数**（2.1 改写，取代原「一条静态行最多 4 个事实」）。
行间距与垂直 padding 保持紧凑：有效信息优先于留白。拥挤（≥5 行）时叙事行仍保持两行可读上限。

选取规则：

- **动态事实优先**：随干活而变的（当前工具、进度、token、增长速率、错误数）
  在竞争位置时排在不变的（标题、路径）前面。
- **每个事实此刻必须携带信息**：值为 0、未知、或与相邻行重复的一律不出现
  —— 沿用本文档自己那句「不携带信息的位置要么给它真信息，要么删掉」。
- **条数随内容浮动**，但受两条约束：**不得因此增加行高**（结构仍是身份 / 主行 /
  次行 / 叙事行），拥挤时自动收敛到信息量最高的几个；**Waiting 行让位给等待详情**
  （有人在问你问题时，token 数不重要）。
- **仍然禁止**：趋势图 / 历史曲线 / 统计大盘；把同一事实换个单位或换个口径说第二遍
  （整场 token 与最近消息 token 平铺在同一行是歧义，不是信息）；无差别平铺成枚举清单。

> **这条规则改过两次，两次都是被自己的历史推翻的。**
>
> 它最初写于「两行三级文字塞了 10 个并列事实」的事故，于是定了个上限——然后
> **矫枉过正**：到 0.27 每行只剩 2 个事实，而且**两个都是静的**（会话标题与路径
> 在整个会话生命周期里都不变）。凡是随着干活而变化的东西全在一次悬停加一次
> 「详情」点击之后，**面板因此只在被追问时才可观测**。
>
> 2.1 把上限本身也去掉了：那个 4 是从事故里反弹出来的数字，不是从任何东西推导
> 出来的。真正要防的是**无差别的平铺清单**（读起来像枚举，扫视成本按条数线性
> 上升），不是事实的个数——四个**静**事实比六个里有两个在动更难回答
> 「它到底推进了没有」。约束因此从「几个」换成「哪几个、怎么排」。
>
> 核心事实不得挂在「详情」里。没有事实时整行消失，不显示占位。

#### 状态编码上限 4 种

| 编码 | 表达 |
| --- | --- |
| 身份灯 | 每行的即时状态：等待红 / 运行绿 / 最近灰 / 异常橙 |
| 左色块 | 是否需要你；**且只有它随等待时长变宽**（≥10 分钟由 3pt → 6pt） |
| 状态芯片 | 仅**非常态**：等待中（带时长）/ 停滞 / 进程 / 最近 / 子任务。**运行中不发芯片** |
| 主行字重 | 真实会话 semibold / 裸进程 regular |

**禁止**再叠加：行底色、图标透明度、整行透明度、主行字号差、主行颜色差。
冗余不是强调 —— 每多一种编码，其余每一种的信噪比都低一点。

#### 等待时长是第一信息

「等了多久」决定先管谁，所以它必须出现在芯片里，并且是 Waiting 行的排序键
（最久的在最上；时间戳未知的排最后，不得当作 0 而冒到最前）。

整行点击只在有真实句柄时执行 Focus；没有 Focus 句柄的行是观测内容，不伪装成按钮。
行内动作（忽略等待 / **稍后** / 聚焦）：
**Waiting 行常驻，其余行悬停时出现** —— 常驻动作条是「只能看到 3 个 agent」的主因。

**不提供「在终端打开」。** cwd 只能定位目录，不能定位现有会话；拿 cwd 新建一个终端窗口
不是 Focus，可能失败，还会制造重复上下文。**不提供 Finder「打开目录」。**
可聚焦时动作文案按落地精度分级诚实：

| 句柄 | 动作 | 精度 |
| --- | --- | --- |
| 进程在 Warp 下 | 聚焦 Warp（应用） | 仅 App，不暗示标签 |
| 宿主 IDE + 绝对工作区路径 | 在宿主打开工作区（`open -a Host.app <cwd>`） | 工作区；不是会话/composer |
| 宿主 IDE、无可验证 cwd | 聚焦宿主（应用） | 仅 App |
| 真实 TTY 且 Shortcuts 已 opt-in | 聚焦终端标签 | 标签（可能弹 Automation TCC） |
| 以上皆无 | 无 Focus 按钮；通知 /「跳到等待」只打开 Pulse 托盘 | — |

Terminal/iTerm 的 TTY 选择**默认关闭**；Shortcuts 里显式开启后才广告 `.tty`。
Support Health 对每个 Agent 标明 Focus 事实（工作区 / 仅 App / TTY / 需 opt-in / 仅观测）。
深链边界见 [`docs/landing-hosts.md`](docs/landing-hosts.md)。

**不提供「打开目录」。** Finder 只能把用户带到目录，既不能恢复会话，也不能回答 Agent
是否仍在推进；它增加一次应用切换，并把“工作区存在”误包装成“可操作”。cwd 留在信息层，
只用于定位与区分会话。

#### 稍后（Snooze）

一个等待原本只有两种回应：现在处理，或永久清除。最常见的那一种——
「知道了，等会儿再说」——不存在，只能靠用户自己记住，
而「靠用户自己记住」正是这个产品存在的理由。

**稍后压制的是打扰，不是事实。** 具体地说：

| 压制 | 保留 |
| --- | --- |
| 菜单栏灯不变红 | 行留在列表里，仍在「需要你」分组 |
| 菜单栏不显示它的计数与时长 | 分组计数照常算上它 |
| 不发通知 | 芯片改成「已稍后 · 剩 N」，左色块变淡但不消失 |

这和静音是同一条规则（「静音的 Agent 不发通知，但照常出现在列表里」）。
**一个会让行消失的按钮，是没人敢按的按钮。**

再按一次即可取消——不能停的倒计时比没有倒计时更糟。
稍后到期要重新发一次通知；等待自己结束了，稍后状态一并清掉。

禁止：`-` / `—` 占位、空的等待行、把 Agent 名当 hero。

#### 观测质量与降级

覆盖不是一个布尔值，至少分三档：

| 运行时证据 | 默认展示 | 禁止 |
| --- | --- | --- |
| 结构化会话 | 任务、项目、显式 Now、最近动作、最后活动、开始时间；有数据再加一个最强进度事实及模型 / 模式上下文 | 裸字段名、无标签箭头、把最近动作写成正在执行、给正常行重复标 `Session` |
| 可验证缓存 | 缓存中真实存在的标题 / 工作区 / 时间，并标注「本地缓存」 | 从配置里的任意 `name` 猜任务；把扩展目录名、文件名或 `Agent session` 当标题 |
| 仅进程 | `已检测到终端会话 · 暂无活动详情` 或 `已检测到应用 · 暂无活跃会话数据`；可 Focus 时保留动作 | `process`、`2 processes`、把常驻 worker 算成 Running |

`Now` 只能来自显式阶段事件，或尚未收到匹配结果的工具调用。最后一次工具调用本身只是
历史动作；一旦收到 tool result，它必须退出 `Now`。每行只选一个最强进度事实，避免
错误数、token、文件、上下文和记录数在同一层抢注意力。

独立的「Agent 支持健康度」窗口展示本机实际观测，而不是复述静态支持名单：每个适配器
必须区分已读到数据、正常但无近期数据、解析异常、扫描未完成；检测到的进程、证据等级、
最近成功读取、目标 / 工作区 / 活动、Waiting 来源和缺失能力都必须可见。未检测到与
检测到但仅有进程，是两个不同状态。Supervisor 故意延后（backoff / circuit）不得点亮
「扫描未完成」横幅；超时且已有部分行用专属文案，不得把其它健康 Agent 空白掉。

支持健康度默认展示完整的 32 个用户可见 Agent 名单，首屏直接看到每个适配器的
需要处理 / 信息受限 / 健康 / 暂无本机证据状态；「已观测」筛选仍可快速收窄到本机已有
有效证据。深度应用数据关闭时，受保护来源必须明确标为隐私受限，不能让用户把“未读取”
误认为“不支持”。若用户已按 Agent 开启部分数据源，顶栏不得再写成「深度扫描已关闭」；
应说明已授权数量与仍受限数量，并从该处深链到对应设置开关。

进程数是探测实现，不是用户价值；只能进诊断信息，不能占主界面状态芯片。
证据等级属于 Agent 身份行，不再另发一个状态芯片。托盘信号行不得重复同一 Context /
Model 片段。`--harvest-test` 诊断必须读取与托盘相同的 App Data 授权。

#### 面板只有一个表面

**面板的可读性不能取决于用户的壁纸。**

0.27 的两张截图是同一个面板：蓝色壁纸下整块泛蓝，深色桌面下变成一块灰板，
绿色的状态词在后者里几乎读不出来——因为内容直接坐在弹窗的 vibrancy 上。

规则：

- 面板由应用自有的无边框 `NSPanel` + 单个 `NSVisualEffectView(.menu)` 独占表面；
  `TrayPanel` 四边贴合，没有系统私有容器的额外 content inset。此前
  `MenuBarExtra(.window)` 的根视图之外仍有上、下 inset：根透明时它们直接成为两条长条，
  根画材质时又变成“圆角系统弹窗里贴了一块矩形”。这不是颜色问题，必须去掉第二个容器。
  **分组表头不固定（不 pin），因此不需要背景。**
  固定的表头必须不透明，而任何压在面板材质上的不透明层都会叠成一条更亮的带——
  0.27.1 和 0.27.2 各换了一种材质，带都还在。行数本来就有上限，固定表头没有收益；
  取消固定是**构造上**消掉那条带，而不是再去挑一个更好的色值。
- **绝不把随外观变化的颜色存进 `let`。**
  0.27.1 用 `static let surface = Color(nsColor: .windowBackgroundColor)` 换掉了材质，
  结果深色模式整个消失：深色桌面上是一块浅灰底加黑字。
  `static let` 是只初始化一次的全局量，首次绘制时的外观被冻在里面，之后再切主题都不动。
  要么在 `body` 里读，要么用渲染时逐帧解析的 token（`Material` / `.primary` / `.secondary`）。
  `scripts/appearance_check.py` 是门禁。
- **不要在圆角系统弹窗里再画一块矩形材质或颜色。** 窗口比内容高出的 inset 会变成第二个表面，
  面板会读成一个贴上去的盒子。让系统弹窗成为唯一材质所有者。
- 分割线内缩到文字边距。通宽的分割线是表格线，两条就把面板切成条带。

**头部不放灯。** 菜单栏的标记就在 40px 之上，同形同色同 `glance`；
头部只说行内说不清的事，图标同理。状态词保留 glance 颜色——那才是带信息的部分。

### 版本与诊断

版本与复制诊断信息位于 Header 的「更多操作」和 Preferences → 关于。
它回答「我跑的是哪个 build」，不参与实时状态叙事，也不再制造独立底部横条。

### 空态

不是死胡同：一句「未检测到编码 Agent」+ 一句说明 Pulse 何时会亮 +
未装 hooks 时直接给安装按钮。

### 文案

跟随 `lang=auto|en|zh`。相对时间用人话（刚刚 / 2 分钟），不用 ISO。
**所有面向用户的串都必须走 `L10n`** —— 包括 VoiceOver 标签。

---

## 5. Workbench（指挥台）

3.0 起的第四层。三层分工表不变 —— 托盘仍答「谁、为何、我能做什么」，指挥台答
**其余的一切**：看清楚一个会话，然后（3.0 正式起）对它动手。

**原则更新（3.0）：「只有计数与短名」是托盘与跨机器通道的规矩，不是产品的规矩。**
指挥台展示的是本机用户自己的仓库与会话记录：本地、只读、agent 自述文本逐处过
sanitizer、一个字节都不出机器。托盘一个像素不变。

- 入口：托盘「更多操作」→ 打开指挥台（⌘⇧W）。LSUIElement 不变，窗口走
  Settings 同一套激活舞步。
- 结构：左侧舰队侧栏（分组沿托盘四组，读 `store.allRows` 全量而非扫视窗口；
  打开时选中最需要你的行），右侧会话检视器。
- 检视器卡片：等待卡（完整消息 + 既有动作：聚焦/忽略/稍后）→ 此刻卡（live
  动作 + 行叙事）→ 计划卡（整份清单）→ 原话卡（刚说的话 + 错误原文）→
  证据卡（时间线/整场 token/速率/CPU/时长）→ **盘上改动卡**。
- **盘上改动 = 计数自己的内容**：`diff-index -p --no-color HEAD` —— 与测量同
  一套只读 plumbing 纪律（porcelain `diff` 写 index，2.7 真机抓过），同一 runner
  同一动词集合；**点击才加载**（能耗是硬约束，永不定时刷）；96KB 截断且明说
  （截断视图必须自称被截断，上方计数仍是全量真相）；干净树直说干净；远端行与
  未经磁盘确认的根不装按钮 —— 另一台机器的盘、解错的路径，都没有 diff 可看；
  失败显示「不可用」而不是发明内容。
- 检视器里的一切事实沿用行上同一套新鲜规矩（selfReportFresh / liveActionFresh）
  —— 换个窗口不换认识论。
- **回答（3.0 正式，场景 BB）**：等待卡就地回答，两条通道永不混 —— 有完整请求
  （`respond.d`，digest 复核）时嵌入与 Details 同一张 Respond 卡（完整请求原文、
  拒绝永远可用、「同意」仅当 `canOfferAllow`、HMAC 单次、fail-open）；本机
  Claude 会话的提问/续接类给**续接命令**：Pulse 构造
  `claude --resume <session> '回复'`（会话 ID 过形状门才许上命令行、回复走
  POSIX 单引号转义），复制到剪贴板并唤起终端，**永不代跑** —— 粘贴与回车就是
  不转移的那一寸判断权。权限等待无请求文件时只给聚焦（厂商提示已在眼前）；
  远端行不给续接（终端在另一台机器）；未验证厂商不给预填命令。每个出口都在
  卡上可见（复制成功 / 拒绝原因 / 判决下场）。
- **复盘（3.0 正式，场景 BC）**：已结束会话的检视器换**验收序** —— 盘上改动
  领头（它干成了什么）、清单终态、最后的话；没有「此刻」卡（陈旧不冒充此刻）；
  横幅明说这是历史且 Pulse 永不代动仓库 —— 验收在 Pulse，处置在你自己的工具里。

## 6. Preferences（设置窗）

系统感设置页，不是状态中心。允许顶部一行极简状态作上下文，但不用巨大 heading，
不复制 tray 的多行详情。

### 分区

1. **上下文**（矮，一行）—— 当前状态 + 探测节奏
2. **通用** —— 实时更新 · 登录时启动 · 语言（弹出菜单，禁止按钮循环）
3. **通知** —— 空闲通知 / 新 Waiting 通知 · 安静时段（**精确到分钟**，可跨午夜）·
   按 Agent 静音（折叠）
   - **权限被拒时**：开关置灰 + 常驻说明 + 「打开系统设置」；不循环索取。
     静默失效不可接受 —— 开关显示「开」就必须真的会响。托盘 Waiting 维护条
     与 Support safe report 同源写出 authorization / pending。
4. **等待信号** —— hooks 说明（2 行内）· 安装连接 / 移除连接 · 当前状态 ·
   Attention 桥说明（点名无 Waiting 路径的七 Agent）·「打开 Attention 文件夹」；
   托盘 / Support 可深链聚焦本节
5. **快捷键** —— 唤出组合键可选；被占用时明说「已被其他应用占用」，不归咎辅助功能权限
6. **最近的等待**（有记录才出现）—— 已结束的等待，最多 12 条，可清空
7. **关于** —— 版本 · 构建行（`sha · 日期`，可选中；无指纹时显示「开发构建」）·
   分发通道三态（`preview` / `signed` 未公证 / `stable`）· 检查更新 + 状态 ·
   复制诊断信息。无 Developer ID 时 GitHub Latest 仍跟当前 semver，但二进制为
   `preview`；更新检查走 releases 列表。校验通过后打开 DMG，
   **就地安装按钮仅 notarized stable 出现**。「已是最新」按通道解释（preview =
   unsigned feed；stable 不含 prerelease / 公证可能滞后）。
   重复安装副本最多列 5 条并写「另有 N 个」。

运行中的 Agent 列表不进入设置页。它属于 Tray 的实时内容，复制到 Preferences
只会把设置页变成第二块 HUD，并让长任务标题撑坏表单节奏。

### 视觉

- 字阶：分区小标题 muted，正文 regular，避免全页 heading
- 设置行：左标签右控件，像系统 Form
- 窗口 420–460 宽，可 hide（永不 destroy）
- 中文必须稳定 CJK 字体；禁止豆腐字当正式体验

### 禁止

- Simulate / debug 控件出现在正式设置里
- 把 hooks 说明写成营销长文
- 与 Glance / Tray 抢主状态叙事
- 注册 SwiftUI `Settings { … }` 场景作生命周期锚点（会在 reopen 时变成空白设置窗）

生命周期为 **AppKit-only**（`NSApplication` + `AppDelegate`）。Finder /
Spotlight / 更新后「打开」必须拒绝 reopen 造窗；真设置始终是
`SettingsWindowController`。

---

## 7. 跨层原则

### 可读性

1. **先状态，后细节** —— Waiting > Running > meta
2. **有数据才显示** —— 没有就不占位
3. **一行一个意思** —— 不把原因、任务、项目、tokens 揉进同一行。
   同一行内的事实按信息量取（动态优先、无值不显示、条数随内容浮动但不增行高，
   见 §4）；放不下的走展开，不往行里塞
4. **同一事实在面板里只出现一次**（0.25 起的硬规则）。优先级：
   **行内 > 分组表头 > 头部**。
   - 头部只说行内说不清的事：被折叠了多少、跨几个项目。**只有一个项目时保持沉默**
   - 分组表头只在多于一组时出现；**按项目分组时，表头说了路径，行内就不再说**
   - 单行分组不发表头 —— 那只是把那一行的路径单独占一行
   - 芯片不得复述标题；**运行中是常态，常态不发徽章**

   > 0.25 写下了这条规则，却只把它用在**面板头部**，忘了**分组表头**。
   > 于是按项目分组时，`~/Documents/Cursor` 在表头和它下面唯一那行各出现一次。
   > **规则写完的下一步就是逐处对照，否则它只在写它的那个地方成立。**

5. **家目录不是项目。** 无法定位的会话归入「工作区未知」，不发明名字。
   按项目分组时该桶必须有表头，否则未知行会在视觉上挂到前一个真实项目。
   同一个目录不得因为数据来源不同（`cwd` vs 编码过的 `project`）产生两个分组。
6. **不承诺没有的精度。** 相对时间不到一分钟就说「刚刚」，不显示秒。

   > 0.24 把一行从 10 个事实压到 4 个，却没检查这 4 个是不是同一个事实。
   > 真机截图里，一条进程行用「检测到进程」「进程」「Amp」「Amp 1」
   > 说了四遍同一件事，「运行中」在头部、表头、每行芯片说了三遍。
   > **辨识度没提升，只是把噪音换了一种形式。**
4. **扫描距离** —— Glance 0.3 秒；Tray header + 第一条 Waiting 1 秒

### 能耗（硬约束）

常驻菜单栏工具被系统标记为耗电大户等于定位破产。

| 状态 | 间隔 |
| --- | --- |
| Waiting | 2s |
| Running | 5s |
| 仅最近会话 | 15s |
| 空 | 30s |

托盘打开时最快 2s；低电量模式 ×2；**息屏 / 锁屏停表**（attention 文件变化仍唤醒）。
昂贵的 native harvest 与便宜的 `ps` probe 解耦，按节奏跳过；legacy Python 只在显式诊断时使用；
进程指纹变化 / 手动刷新 / attention 变化时强制采集。

### 通知

- 触发：全部空闲（边沿）· 新 Waiting（边沿，首扫只播种不发）
- 内容：标题 `{Agent} · {项目}`，正文 `{原因} · {消息}`。
  只说「需要你处理」而不说要什么，用户仍得切过去才知道 —— 不算闭环。
- **`{消息}` 必须说出被请求的那件事本身。** 厂商的权限事件常常不带任何散文
  （Claude 的 `PermissionRequest` 没有 `message` 字段，要批准的东西就是那次工具
  调用），此时由 `tool_name` + 工具入参组成 `Bash: npm run build` /
  `Edit: src/main.swift`，取值顺序对齐厂商自己的权限标题（`command` →
  `file_path` → `url`）。**「权限」两个字不满足这一条** —— 那正是它想消除的
  「不说要什么」。凭据照常经 `ContentSanitizer` 抹掉，字段照常有界单行。
- **后到的哑事件不得抹掉已说出的原因。** 一次授权会让厂商同时发多个事件，
  只有一个带正文，顺序不由 Pulse 决定；空消息覆盖非空消息就会把已经说清楚的
  那件事变回一个词。
- 安静时段只抑制空闲通知；Waiting 边沿仍可发（产品选择）
- 静音的 Agent 不发通知，但**照常出现在列表里**

### 数据诚实

- 进程在 ≠ 会话在干活。用「运行中 / 检测到」，不用「正在编码」。
- Waiting 只来自 hooks 或 `skill=pending`。无信号就明说，不假装。
- **工具名同理。** 只认结构化的 `tool_use` 记录和已知工具名白名单，
  绝不从「任意 `"name": "..."`」里猜——那会把 `workspaceFolder`、`filesystem`、
  模型 id 显示成「它正在跑 X」。宁可空着。
- **数量不估算。** 会话文件超过采集预算就报「未知」，不按比例外推；采集器已读到、
  但超过 Swift 500 条容量的部分必须精确计数。**读取窗口截断时记录数即为未知**——
  数 head+tail 窗口的换行符得到的是下界，不是总数，不得当作精确值展示。
- **采集器要能自证。** 每个 adapter 报告它这一趟读了什么、主行来自哪种记录、没有主行
  时是哪一层丢的。这是诊断输出，不进托盘，也不含标题、正文或路径。
- **写到磁盘上的东西要说清楚。** 账本存什么、留多久、能不能清空，用户看得到；
  注释与实现必须一致。诊断日志不落项目名。
- **主行按来源选，不按长度。** 用户句压过厂商标题，与字数无关；占位词和纯文件名
  永远不是目标。
- 每条 Waiting 标注来源 `hooks` / `pending`。
- Focus 分级诚实：TTY 标签 → 宿主工作区 → 宿主/Warp 仅 App；
  cwd 可打开进宿主，但绝不经 Finder 冒充 Focus，也不把仅激活 App 写成「跳到该会话」；
  什么都没有就不给聚焦按钮，通知路径退回打开托盘并**选中该 Waiting 行**（Go-Look Closure）。
  无 Apple Developer ID 时不标 `stable`。
- 被上限压下的会话**显式计数告知**，不静默丢弃。

**没测到的那一半不写 0（2.3 起，全局）。** 2.2 为 CPU 立的规矩不是 CPU 专属：任何
成对呈现的量，只印测到的那一半，两半都没有整条事实消失。行上的 token 对曾经把
`compactToken(0)` 返回的空串翻译回字面量 `0`，于是只上报 output 的厂商被写成
「消耗了零个输入 token」—— 一个没有任何东西测过的数字，出现在产品里被看得最多的
那一行。语域不能因为只剩一半就丢掉：「最近一次模型调用」与「整场累计」仍然是两个数。

**每个文件的权限说明它装着什么。** 凡是 Pulse 写下的、含有用户敲过 / 跑过 / 起过名字
的内容的文件，**从第一个字节起就是 0600**，不是 0644 之后再 chmod —— `write(to:.atomic)`
的临时文件带的是进程 umask，那个窗口覆盖整个写入加改名。创建模式管不到已经在盘上的
文件，所以要顺着已经拿在手里的 fd 把老文件降下来；别人拥有的文件一律不动。

**一次点击必须留下痕迹。** 动作够不着目标（窗口已关、判决写不出、请求已过期）时，
提供了这个动作的那一行要说一句人话。够不着与按钮坏掉在屏幕上长得一模一样，而
「拒绝」这种被承诺永远可用的动作，静默失败是最坏的一种。失败仍然 fail-open ——
句子里就说清楚它回落到哪儿。

---

## 8. 验收场景

| # | 场景 | 期望 |
| --- | --- | --- |
| A | 无 Agent | Glance 安静；Tray 空态带引导和安装按钮 |
| B | Claude 运行中 | Glance 绿灯 + 名字；Tray 主行是会话标题；无空的 ↳ 行 |
| C | Claude 等授权 | Glance 红灯 + 短标题（新等待闪一次即止，无常驻呼吸）；Tray 等待置顶 + 原因 + 来源标签；通知带项目与原因，且**原因是被请求的那件事**（`Bash: npm run build`），不是「权限」两个字；后到的哑事件不覆盖它 |
| D | 2 跑 + 1 等 | Glance 偏等待；Tray 等待行在最上 |
| E | 同一 Agent 520 个会话 | 采集/模型保留 500 行并报告未显示余量；面板全局 12 行后可展开 |
| F | 打开再关闭 Prefs | Tray 仍在；无 Dock 常驻感 |
| G | 切到中文 | Tray / Prefs 中文正确；Agent 名仍英文；时长单位也是中文 |
| H | 通知权限被拒 | 开关置灰 + 常驻说明 + 「打开系统设置」，不假装会响 |
| I | 息屏 | 探测停表；唤醒后立即补一次扫描 |
| J | 旧 app 与新版并存 | 关于区显示 `x.y.z≠bundle` 并提示重新打包 |
| K | Supervisor 故意延后一 Agent | 不出现 incomplete 横幅；其它 Agent 照常可见 |
| L | ad-hoc / 未公证包 | About 标 preview 或 signed；不得自称 stable；GitHub 可为 Latest；无就地安装按钮 |
| M | 多份用户安装副本 | About 最多列 5 条路径，超出显示「另有 N 个」；回收只动用户安装 |
| N | 无 Waiting 路径的 Agent 在跑 | 托盘 / Support 指向 Waiting signals · Attention 桥；不伪造 Waiting |
| O | 旗舰事实连续（Claude / Codex / Cursor） | 有会话时主行是真实 goal 或人话工具；cwd / 最新 tool / subagents 可见；无动态事实时次行省略；不发明「进度信号」占位；薄 cache 标 Limited，不升格假 session |
| P | 更新后用 Finder / Spotlight 打开 | 不弹空白 Settings 窗；真设置只经菜单进入 `SettingsWindowController`；无 SwiftUI `Settings` 场景 |
| Q | 舰队事实连续（非旗舰 session + 高流量 cache） | Amp/Pi/Grok 等有 goal/cwd/tool 时主行诚实；`bestEffortCache` 证据恒为 cache；薄索引 Limited；`depending` 等不得假 Waiting；Waiting-none 七 Agent（含 ZCode）可从 Settings 写 Attention 样本 |
| R | 富缓存 Limited（Windsurf / Cline / Roo / Warp…） | 有 goal+cwd/tool 时托盘显示真实事实，Support 标「cache facts (Limited)」；薄索引标「thin cache」；证据仍 `.cache`，不升格假 session |
| S | Waiting 连续（harvestPending + Waiting-none） | Cline `ask=followup` / Roo ask tool / Cascade waiting 旗 → 红灯；`depending` 仍否；Attention 带未知 session 不点亮已有兄弟会话（空 session 进程行可收养）；Waiting-none 只经 Settings → Waiting signals → Attention 样本，不从 harvest 抬 pending |
| T | Hook Autonomy（无 Python） | 无 Python 的 Mac：Settings 安装 Claude/Codex hooks 成功；「测试连接」通过；`pulse-hook` / `PulseBar --hook` 写入 attention.tsv；已装 `pulse_hook.py` 可迁移且可卸载 |
| U | Attention Autonomy（外接 raise） | Waiting-none / 名单外工具按 Attention Protocol v1 经 `pulse-hook` raise → 红灯 + Tray `hooks`；未知 kind 不写不亮；不扩 Claude/Codex 安装器；样本 `raise.sh` 可冒烟 |
| V | Live Continuity（绿灯可信） | stall-only → 橙；`running + stalled` 混合 → 橙（不装健康绿）；progress/tokens 前进且 harvestMs 未动 → 不假停滞；仅进程 / 无活动时钟 Running → Glance 橙；Waiting 仍优先于 stall |
| W | Go-Look Closure（打断闭环） | 点 Waiting 通知 /「去看看」→ 托盘打开且**该行**选中并滚入视口；有 Focus 句柄时仍可激活宿主，但不因 Focus 成功丢行身份；多 Waiting 摘要用精确 `rowKey`，不 smear |
| X | Fleet Coverage（ZCode） | `ZCode.app` / `~/.zcode` 可探测；证据为 best-effort cache；无原生 Waiting；Settings Attention 样本与 `raise-zcode.sh` 可亮红；不扩 Claude/Codex hooks |
| Y | Contract Honesty（契约诚实） | Support / 样本 / L10n 的 Waiting-none 名单派生自 `AgentID.waitingNoneAgents`；Waiting-none 深度仍露出 cache thin/partial；Support → Waiting signals 点名该 Agent；规格写 32 Agent；未公证不标 Gatekeeper-ready |
| Z | Tray Legibility（托盘可读） | 默认行同时可见次行（路径·最近动作含执行命令·最近活动·始于）+ 运动信号 + **观测行**（model·tokens·最强进度；**2.1 起条数不再封顶在 4，改为按信息量取**，见 §4 与场景 AS）；无事实整行消失；核心运动事实不藏 Details；不发明进度占位 |
| AA | Tray Substance（托盘实质） | Claude 会话记录带 `message.model`/`usage` 时观测行有 model+tokens；Codex `last_token_usage` 可见；Cursor `unifiedMode` 可见且非假 local；tool-hero+分组去路径时次行仍有最近动作或路径；LS/Task 等工具可作最近动作 |
| AB | Tray Fleet Substance（舰队托盘实质） | Gemini `functionCall`+`usageMetadata` / Goose `depending`→Working（非 Waiting）/ Cursor `modelDetails` / Pi `agent_usage` model+tokens 进默认行；有 model 的 cache 行观测非空且仍 Limited；quiet live 无 phase 时 Now 空、观测可有 model/tokens |
| AC | Waiting Reach（等待可达） | Waiting-none Agent 在跑 → Support/托盘/空态深链到 Waiting signals；一屏完成「确保 pulse-hook（不装 Claude/Codex）→ 打开文件夹 → 写样本 → 托盘红灯可清除」；可复制 raise 命令；Application Support 有 bridge kit；不伪造原生 Waiting、不扩 hooks 安装器 |
| AD | Row Story（行叙事） | 默认行在标题下有一句叙事：有 phase 时可读阶段·工具；quiet live 无 Now 仍有最近动作；无动作时观测行有 model/tokens（story 不重复）；tool/phase/task 变化进 Changed；仅进程/薄 cache 显示证据+下一步；不把 last tool 标成 Now、不伪造 Waiting |
| AE | Row Clarity（行清晰） | Story 拥有 phase/工具/Changed；次行只留路径·年龄；信号在 story 已带 Now/Changed 时让位；Waiting 芯片=种类·时长、详情=消息优先；Limited 质量摘要只出现一次；离开再回可见「什么动了」；Details 同叙事；不伪造 Waiting / 不升格 session |
| AF | Look Closure（回看闭环） | 离开再回 notice **具名**（最多 3 +「+N」）；优先级新等待→已结束→有变化；一点经 `pendingRevealRowKey` 选中滚到该行；受影响行短暂「离开后有变」；不发明 Waiting、不伪造会话深链 |
| AG | Waiting Proof（等待可证） | Cline/Roo/Cascade/Cursor 显式 ask/block → 红灯；soft-dismiss 后自然清除可再亮；`depending`/Waiting-none 永不从 harvest 抬；Attention raise 精确点亮并可 clear；Waiting-none 在跑时可直达 Waiting signals；不扩 hooks、不伪造 Waiting |
| AH | Extinguish Honesty（熄灭诚实） | 已答 ask / 终态不亮；Cascade/Windsurf 共享根不双红；Pi/Grok 正文不抬；soft-dismiss 重启仍压、可靠缺席后可再亮；纯 harvest dismiss 不抹掉同 Agent Attention；歧义 session 前缀不 smear；`Waiting`+Stop 有 grace；Clear waiting 无迟到通知 |
| AI | Return Truth（回看诚实） | 重开托盘后用新扫描算 Look；同行新 `waitSinceMs` 算新等待且优先于 ended；ended 不进 moved；Glance 超 8 格降为 `1 · 4m` / `1`；样本行出现后再 Go-Look；进程收养重键；Attention 压缩保留未决；Details 可行动缺口优先、quiet/cache 不重复观测/身份 |
| AJ | Pi 会话标题 | 与 Pi `/resume` 一致：最新 `session_info.name`（空则清除）否则**第一条**用户句；官方 `--<cwd>--/<timestamp>_<uuid>.jsonl`；env 标签不吞后半句，未闭合 env 不当标题；compaction `retainedTail`；sibling `.db` 不挡 JSONL；SQLite 最新句不盖 JSONL；`Auth session` 不是 chrome；官方头-only 不发明项目名主行 |
| AK | Hero Honesty（主行诚实） | Claude/Command Code `tool_result` 不当标题、长会话记录开场目标仍在；`messages[]` 跳过 tool 信封；Codex `event_msg` 用户正文进主行、Desktop 信封剥掉、`continue` 不覆盖；tool `path` 不是 cwd；Goose `name` / Kimi `lastPrompt` / Cursor `subtitle` 可见；表头计数=舰队；Details 空 phase 不发明「等待权限」；审批 ask → Permission 芯片 |
| AL | Ground Truth（采集可证） | 主行按记录种类选而非字符串长度（`sessionName` > `userPrompt` > `cacheTitle` > chrome），同种类保留先见到的；每个 adapter 输出 explain（files/bytes/truncated/facts/heroOrigin/emptyReason）进安全支持报告与 debug.log，**并进 Support Health 的「适配器诊断」折叠区**（2.2：「为什么这行是空的」不该要开终端才能问 —— 读了多少 ＋ 结果如何/哪一层丢了它，都用人话；窗口截断时同一行声明计数只是下限；什么都没读就整行消失而不是打一排 0；本版不认识的 tag 原样打出，不静默吞掉）；窗口截断时 records 报未知不报估算值；预算用尽后下次扫描从上次没走到的 adapter 开始，尾部 Agent 不再永久 `unscanned`；launchd 最小 PATH 下 `~/.local/bin` 的 CLI 仍算「已安装」；chrome 词表单源；native 墙用厂商真实布局断言主行**取值**；explain / shape 导出不含标题、正文与路径 |
| AM | Quiet Data（数据静默） | 账本注释所述 == 实际字段（≤160 字会话标题、14 天 / 256 条、已过 `ContentSanitizer`）；设置里「最近等待」下方写明保留期并可清空；chrome 词表全仓只有一份且大小写不敏感，`Cascade session` 在采集侧与行侧一致被拒；`debug.log` 的 rowKey 不含项目名但仍可跨行关联；预算挤掉的 adapter 进 supervisor 摘要；Details 事实行与 Support 事实徽章 VoiceOver 读得出标签与有无；只有一个采集器，任何路径都不为观测会话 fork 解释器 |
| AN | Live Wire（通电） | `lsof` 退 1 但已打印的进程照常采用；只有调用失败 / 超时 / 退 0 却无输出 / 退 1 而被问的进程仍活着，才武装 5 分钟 backoff；已退出的 pid 不连坐其它 Agent；子进程超时后不向仍在运行的它索要退出码，SIGTERM 不死则 SIGKILL；仅进程行从探针拿到工作区与项目名，多个陈旧会话按活进程 cwd 消歧（无 cwd 时按新旧）；厂商格式报告可从支持窗口一键复制且不含任何正文；「登录时启动」的终态经 `launchctl list` 复核并进安全支持报告；Focus 打开工作区不在主线程无限等待 |
| AO | Remote Fleet（我的舰队） | 远端 raise 经 `attention.d/<host>.tsv` 点亮独立行；`host` 空=本机，v1 六列行仍有效；两台机器的同名 Agent 是两行两个 rowKey，一台的 `done` 不清另一台；远端行**永不**报进程、**没有** Focus、叙事行说「最后听到」；TTL 后进**失联**（撤红灯、留行、给原因），一小时后才消失；发送方时钟对不上时按到达时间计龄并在行上说明，不再静默丢弃；远端等待不认领本机会话；安全支持报告有 `remoteFleet:`；Pulse 不联网、不带服务器、不上传任何东西
| AP | Full Transcript（全见） | 超过窗口的会话记录数不再报未知：摘要读完整份文件后给精确值，没读完则保持原行为；追加中的半行不计数 —— 不只看 stat 说的结尾（那是读之前量的），还问打开着的描述符文件现在到哪儿，**且末尾那截自己得像个记录**（`{` 开头却解析不出来的就是被撕开的前半截；从来不是 JSON 的行没有形状可查，照旧采信）；文件变短 / 标识变 / 头部指纹变（含同长度就地重写）一律从头重来；分片折叠结果 == 一次性折叠结果；摘要只存计数与厂商工具名，不存正文、工具入参或会话记录里的路径，有界并按期清理；安全支持报告有 `sessionDigests:`；窗口读取本版仍在，不得声称已省掉
| AQ | Substance（行的实质） | 连续调用同一工具 ≥3 次时叙事行说 `Edit · 连续 5 次`，因为「在动但没在推进」是灯表达不了、窗口也看不到的状态；Waiting 与远端行的叙事优先于它；**不改灯色**（状态编码仍是 4 种，打转不是 stalled）；Details 给整场会话证据：用过的工具按次数排序最多 4 项（长尾直接丢弃，不做「其它 N 个」）、错误总量、打转说明；摘要事实只搬运不重算，不得从窗口文本复核
| AR | Respond（回应） | 远端等待行在存在匹配的完整请求（`respond.d` 请求文件，digest 复核通过）时多出两个动作：**拒绝**（永远可用 —— 拒绝没读全的东西是安全的）与**查看并回应**（打开 Details 的完整请求区，「同意」只出现在那里且仅当 `canOfferAllow` —— 对着 200 字截断摘要没有同意按钮）；判决单次使用、90 秒过期、HMAC 逐 host 密钥签名、绑定 request id + 内容摘要 + agent + host，密钥文件不存在则这一切不出现；**2.4 起本机行也可以有这两个按钮**（见场景 AU）—— 2.0 的「本机永不 hold」是用「有人碰这台 Mac」近似「提示在你眼前」，那个近似在头号场景里是反的；hook 端任何失败静默回落厂商提示；判决送达与否 Pulse 不谎报 —— 界面只说「判决已写出，等你的同步工具送达」
| AS | Evidence（证据） | 摘要算出的事实不再停在支持报告：Details 有**会话证据**卡 —— 最近动作时间线（`Read → Edit → Bash`）、**整场会话** token（与 facts 里「最近一条消息」的 token 明确区分，不让两个数字打架）、活跃度（会话记录增长速率，未知就说未知）、会话时长、读取完整度；**定性事实在追平前也显示，但必须标注「仍在追平 · 已读 N%」** —— 披露过的部分值不是估算，藏起来才是浪费，而记录数仍然只在读完后才给（数量不估算）；**行的事实按信息量取而不按条数**（本版改写了「最多 4 个」，见 §4 —— 那个数字是从一次事故里反弹出来的，不是推导出来的）：分层排序为 故障 → 推进 → 动静 → 触及 → 常量（model/mode/skill 定位但从不推进，最后竞争）→ 总量；**会话记录增长速率排在 token 前**（它是行上唯一能区分「在干活」与「杵着」的），且仅对 live 且非停滞非 recent 的行发（完成会话上的速率是历史冒充运动）；**整场 token 不上行** —— 同一数量换个跨度平铺是歧义不是信息，它留在 Details 由标签分开说；「已读 N%」只在同一行确实有计数需要被限定时才出现（没有被限定对象的免责声明不算信息）；条数在拥挤（≥5 行）时收敛，这是**行高护栏不是配额** |
| AT | Momentum（动量） | 进程真实 CPU 占用进入观测行的**动静**层并**排在增长速率之前** —— 会话记录不动时它是唯一还能说话的事实；取值是两拍累计 CPU 时间相减，**不是 `ps %cpu`**（那是生命周期平均值，用它回答「此刻」就是撒谎）；**未知是 -1 不是 0**，界面渲染成「—」并说明还没采到（「测到了它闲着」与「还没采到」是两个答案）；pid 复用两个方向都要挡住 —— 累计值倒退挡一半，**进程比上次采样还年轻**挡另一半（新占用者烧得比前任多时计数器并不倒退）；空闲（<15%）不占位；停滞行在进程确实在跑时改说「会话记录不动，进程在跑 —— 它在算」，**不改灯色**（仍不是健康绿，只是给停滞一个解释）；Details 给计算量与常驻内存；**未经磁盘确认的工作区路径不再提供工作区落地**，降级到仅 App —— 点击时的存在性检查分不出「解对了」和「解错但碰巧存在」 |
| AU | Answer Here（就地回答） | **判断门问的是「那个提示是不是在你眼前」，不是「有没有人碰这台 Mac」** —— 2.0 用后者近似前者，而产品自己的头号场景（开会 / 写文档）里两者同时为真、只有一个作数；取值是「最前台的 App 是不是本 hook 的祖先进程」（沿 ppid 上溯，不认 App 名单、不碰 TCC、不要新权限）；**判断不出来一律不 hold**（在场时冻住 agent 是净损失，「不知道」不是证据）；前台是终端但请求来自后台标签页时仍算「在你眼前」，宁可保守；**本机 Agent 也能在 Pulse 里回答** —— 本机请求从扁平 `requests/` 读回、只挂本机行、判决写回扁平 `verdicts/`；本机判决**照样签名**（`respond-local.key`，Pulse 自动生成、从不离开这台机器）——`verdicts/` 正是双机场景里被同步进来的目录，接受未签名文件会削弱远端路径；**opt-in，默认关**，开关就是那把钥匙的存在，关掉即刻停止一切 hold；横幅上只给**拒绝**，**「同意」永不上横幅**（横幅装不下完整请求，`canOfferAllow` 的纪律不变）；超时仍然 fail-open，厂商提示照常出现 |
| AV | Confirmed（兑现） | **判决的下场是观测到的，不是 Pulse 对自己行为的复述** —— `claimVerdict` 的认领方式就是把 `verdicts/<id>.json` 原子改名成 `<id>.json.used`，所以「被取走」是一个文件事实，不需要推断；本机判决三态：已写出 / **已被取走** / 到点没人取（最后一种意味着厂商提示已经自己弹了，这是设计好的失败）；**远端永不报「已被取走」** —— `.used` 发生在另一台机器上，回不回来取决于用户的同步工具，Pulse 无从得知，远端继续说「判决已写出，等你的同步工具送达」；请求文件被清掉后回执仍留一小段时间（否则用户永远看不到那一秒）；**厂商到底认没认（① vs ③）本版不猜** —— 二进制里看到的 `decisionReason` 是内部代码路径，没有证据说明它落进会话记录，假设它在就是在犯本版要修的那个错
| AW | Effect（成效） | **第三类证据：盘上到底变了什么** —— 前两类（agent 自己写下的东西、进程还活着没有）都在回答「它在干什么」，这一类第一次回答**「它干成了什么」**；取值是三条只读命令（`rev-parse --show-toplevel` / `status --porcelain=v1` / **plumbing 的 `diff-index --shortstat HEAD`**），每条都带 optional-locks 环境与 flag；**行数不用 porcelain 的 `diff`** —— 真机测试第一跑就抓到它在 stat 缓存失配时改写 index，且 flag 与环境变量都拦不住（optional-locks 机制盖住 `status` 的隐式刷新、盖不住 `diff` 的）；`diff-index` 从不刷新、对 stat 脏条目做内容核对、输出同一种 shortstat；index 逐字节不动由测试对真仓库断言（fixture 永远看不见这类缺陷，这正是实证轴存在的理由）；**只取计数，不取内容** —— 不要 diff 正文、不要文件路径、不显示分支名；**未知是 -1 不是 0**（不是仓库 / 超时 / 命令失败 / `cwdBestEffort` 未确认，一律不知道），「测了没动」与「没测」是两个答案；**零 adapter** —— 工作副本不属于任何厂商，一份实现覆盖全部 32 个 agent 及以后新增的；省电按 harvest 节奏跳拍、同一工作副本一拍只测一次、单次太慢即进退避并如实报未知；live 且在动（CPU 忙或会话记录在长）而**测到**盘上没动 → 叙事说「在动，盘上还没有东西落地」，**不改灯色**；同一仓库根上 ≥2 个 live 本机行 → 行上点名（远端行不参与，它的路径属于另一台机器）—— 这是**只有 Pulse 能看见的事实**，每个 agent 只知道自己
| AX | Fleet（舰队） | **舰队不再只有门铃**：本机 Pulse 周期写 `fleet.d/<host>.json`（≤16 行、标题 ≤160 过 sanitizer、project 只取叶子名永不带路径、30 秒一写、0600），用户自己的同步工具搬运，对端读其余 host（≤16 host、≤256KB/文件、文件名决定 host 正文不符即拒收、未知 agent 跳过不猜）；**远端事实全部是过去时** —— 年龄以本机 mtime 计，新鲜（<10 分钟）才引用实质，过期进失联（行留、实质不引用），一小时后整行消失，发送方时钟超前 5 分钟即 clockSuspect 且活动时间不许指向未来；**Waiting 永不来自快照**（attention 是唯一来源），同一 host+agent+session 的 raise 与快照共用同一个 rowKey —— 等待来自 raise、实质来自快照；**广播默认关、读取常开**，关广播即删本机文件；本机快照只含本机行（转播远端行会在互同步时让 agent 翻倍）；远端行照旧永不报进程、没有 Focus、`workspaceRoot` 恒空（构造上进不了碰撞计数） |
| AY | Progress（进展） | **从状态到进展：agent 给自己写的计划成为一等事实** —— 会话记录里的待办结构（Claude 家族 `TodoWrite` 的 `todos`、Codex `update_plan` 的 `plan`）不再被当噪音整类过滤，而是读进专门的字段：`progressDone/Total`（喂已有的 `3/7` 事实）、`planStep`（当前项，`activeForm` 优先）、`planSteps`（整份清单，≤8 项 ≤100 字符逐项过 sanitizer，只进 Details）；**计划是状态不是事件** —— 取窗口里最后一份，后写覆盖先写；**计数取全清单、清单展示有界**（截断视图引用自己的长度就是估算冒充精确）；全部完成没有「当前」就不发明一个；`lastWord`（最新 assistant 文本首行）与 `lastErrorText`（最新 `is_error` 结果首行）同规格 —— 有错误计数没有错误原文等于让用户去猜；**这些全是自述**，与 task/tool 同一认识论层级同一规矩：过 sanitizer、行叙事引用与 phase 同门槛（30 分钟静默即撤，陈旧计划不冒充此刻）、**永不由此推断 Waiting**；主行 hero 仍是用户目标（AK 不变，plan 步骤标题依旧永不当 hero）；哪家会话记录没有该结构就如实缺席不猜；Fleet 快照只运当前步骤一句话 + 两个计数（`step`/`step_done`/`step_total`，Optional 可加可减 —— 2.7 文件照常解码、旧读者忽略新键），整份清单是内容留在本机，远端步骤与其余实质同一新鲜门 |
| AZ | Quality（质量） | **秒级**：hook 终于对干活说话 —— `PreToolUse` / `UserPromptSubmit` 写 `activity.d/<agent>-<session>.json`（每会话一个状态文件、每事件覆写、0600、目录 ≤64 个、>24h 清除、tool/target 走 toolDescriptor + 消毒截断）；**活动事件不是等待** —— 永不写 attention、永不 hold、永不由此推断 Waiting；无会话身份不写文件；文件名决定身份、正文不符拒收；watcher 第三个 source 盯 activity.d，1s 节流，唤醒只做**轻量刷新**（读一个有界目录、原地补行，绝不全量 harvest —— 能耗是硬约束），全量扫描重放同一批事件（builder 与轻路径共用 `applyActivity`，两处实现必然漂移）；**现在时只许对秒级证据说** —— live 窗口 120s，行叙事「当前 · Edit · Main.swift」（行上路径只取叶子，Details 给全路径），窗口一过回落轮询叙事；prompt 事件清空 tool（上一个工具随回合结束了）；时间戳进 `activityChangedMs`（活信号钟）不进 `harvestMs`（会话此刻在动，但事实还是采集时那么旧）；本机时钟写的未来戳按坏钟处理、夹到 now；**事件永不造行**（没有行的事件意味着 harvest 还没认识这个会话，一行只有单条事件当证据的行立不住）。**自证**：每 agent 每拍记「实测事实类」（task/tool/tokens/progress/plan/word/error/model/workspace，只记名不记值、不出机器），Support Health 显示**声明 vs 实测**；声明 structured、本拍有行、核心三类全空 → 点名「厂商格式可能已漂移」（橙色，不许耳语）—— 「agent 没干活」和「Pulse 没看清」从此不穿同一件衣服；无行是 idle 不是漂移、bestEffort 从未承诺核心类不算漂移。**平权**：2.8 的自述倒序扫描摘掉路径白名单 —— 匹配形状不匹配厂商名，谁的记录里有 `todos` 数组 / assistant 文本块 / `is_error` 结果就产出同样的事实，没有就如实缺席；Codex notify 无逐工具事件，其「正在干什么」继续走轮询，如实分级不硬造 |
| BA | Workbench（指挥台） | **形态的第四层**（§5）：托盘「更多操作」→ 打开指挥台（⌘⇧W）；左侧全量舰队侧栏（`store.allRows`，四组沿托盘，开窗选中最需要你的行），右侧会话检视器（等待卡带完整消息与既有动作 → 此刻 → 计划整份清单 → 原话+错误原文 → 证据 → 盘上改动）；**「只有计数」是托盘与跨机器的规矩不是产品的规矩** —— 指挥台内容本地、只读、自述文本逐处 sanitizer、不出机器，托盘一个像素不变；盘上改动卡 = `diff-index -p` 只读 plumbing（与测量同 runner 同动词集合，2.7 的教训直接继承）、**点击才加载**、96KB 截断且自称截断、干净直说干净、远端行与未确认根不装按钮、失败说不可用不发明内容；检视器一切事实沿用行上同一套新鲜规矩 —— 换窗口不换认识论 |
| BB | Answer（就地回答） | **第一个动词，两条通道永不混**：等待卡里，有完整请求（digest 复核）→ 嵌入与 Details 同一张 Respond 卡（完整原文、拒绝永远可用、「同意」仅当 `canOfferAllow`、HMAC 单次判决、fail-open —— 全部走已测的同一套 store 方法，指挥台不重新决定任何事）；本机 Claude 提问/续接 → 写回复、点「复制续接命令」：Pulse 构造 `claude --resume <session> '回复'` 放进剪贴板并唤起终端，**永不代跑**（粘贴与回车是不转移的那一寸判断权，也是 `--resume` 的第一次真机验证 —— 保守版先行）；会话 ID 过形状门（ASCII 字母数字与 `-_.`，≤128）才许上命令行，回复走 POSIX 单引号转义，单引号本身变 `'\''` 逃不出去；权限等待无请求文件 → 只给聚焦（厂商提示已在眼前，第二个答题框只会跟真的赛跑）；远端行 → 不给续接（终端在另一台机器）；未验证厂商 → 不给预填命令（错的命令比没有按钮更糟）；每个出口在卡上可见 —— 复制成功、形状门拒绝、判决写不出，都不许静默 |
| BC | Review（复盘） | **第二个动词：已结束会话按验收序呈现** —— 盘上改动领头（它干成了什么）、计划终态（✓/▸/· 原样，终态是重点所以不再挂 30 分钟新鲜门 —— 横幅已声明这是历史）、最后的话与错误原文、证据；**没有「此刻」卡**（没有此刻，陈旧不冒充此刻）；运行中的行反向收紧 —— 计划卡与原话卡挂上与 Details 同一道 `selfReportFresh` 门（β 的检视器漏了它，正式版补上：换窗口不换认识论）；横幅明说会话已结束且 **Pulse 永不代动仓库** —— 验收在 Pulse，处置在用户自己的工具里 |

---

## 9. 代码落点

| 规格 | 文件 |
| --- | --- |
| Glance 标题 / 灯 | `StatusPanelController.swift` → `updateStatusItem` / `pulseStatusLamp`（图标像素：`PulseBrand.statusBarIcon`） |
| Tray 结构 | `TrayPanelViews.swift` → `TrayPanel` |
| Prefs 布局 | `SettingsViews.swift` → `SettingsView` |
| 状态合并 / 编码 | `SnapshotBuilder.swift` |
| 主行来源 / 采集 explain | `NativeActivityHarvest.swift` |
| 通知策略 / 定时器 | `StatusStore.swift` |
| 探测节奏 | `ProbeSchedule.swift` + `PowerMonitor.swift` |
| 设置与迁移 | `PulseSettings.swift` |
| 文案 | `L10n.swift` |
| 版本 / 构建指纹 | `Models.swift` → `PulseVersion` |
| Harvest / hooks | `NativeActivityHarvest.swift`、`src/pulse_hook.py` |
| Attention 协议 | `AttentionProtocol.swift`、`AttentionIO.swift`、`PulseHookReceiver.swift`；契约 [`docs/attention-protocol.md`](docs/attention-protocol.md) |
| 绿灯 / 停滞 | `AgentRow.stalled` / `isHealthyRunning` / `isThinRunning`；`SnapshotBuilder` liveFleetGlance |
| 打断闭环 | `pendingRevealRowKey` · `focusAgent` · `TrayPanel.applyPendingReveal` · `PulseNotify` |
| 回看闭环 | `lookContinuityItems` · `activateLookContinuity` · `lookMovedRowKeys` · Go-Look reveal |
| 回看诚实 | `GlanceTitle` · `lookContinuityPendingClosedAt` · 指纹 `waitSinceMs` · `AttentionIO.compactLines` · `prioritizedObservationGaps` |
| 等待可证 | `skill=pending` → SnapshotBuilder Waiting · soft-dismiss · Attention raise/clear · `openWaitingReach` |

数据流详见 [`docs/architecture.md`](docs/architecture.md)。

# Changelog

All notable changes to Pulse are documented here.

## 0.29.1 — 核心事实不该藏在详情里

0.29.0 把真实任务、工具、时间和会话指标接进了界面，
但最能判断会话是否推进的事实仍藏在一次 hover 加一次「详情」点击之后；
同时「在终端打开」拿 cwd 新建窗口，却被包装成了聚焦现有 Agent。
这一版把两个交互债一起清掉。

### 默认就能判断会话是否在推进

- 移除「详情」折叠入口。token 快照、subagent 进度和真实记录数有数据时直接显示，
  没有数据就不占行，不再要求用户逐条展开。
- 会话时长留在次行右端；路径、最近工具和最后活动保持一行，
  等待中的问题仍优先于所有运行指标。
- 完整路径、完整 session id、重复任务原文和含义不稳定的 skill 文本不进入主界面；
  可观测不等于把诊断字段全部倒出来。

### 动作只承诺真正能完成的事

- 删除 `Open in Terminal / 在终端打开` 及 cwd 降级路径。
  cwd 能定位目录，不能定位原会话；新开终端既可能失败，也会制造重复上下文。
- 只有 Terminal/iTerm 的真实 TTY 或运行中的 Warp 才显示 Focus；
  其余行只保留可靠的「打开目录」。
- 整行点击与 VoiceOver 提示使用同一套动作判断，
  不再向键盘和辅助功能用户宣称不存在的 Focus 能力。

### 设置回归设置，托盘回归状态

- Settings 删除重复的实时 Agents 列表。长任务标题不再撑坏表单，
  Preferences 只负责行为与连接配置，不再充当第二块 HUD。
- hooks 安装提示改为安静的辅助入口，不再借用 Waiting 红色；
  更多操作菜单隐藏多余下拉箭头，行内层级更清楚。
- 新增 `--open-tray-preview` 视觉回归入口，直接托管真实 `TrayPanel`，
  让 `MenuBarExtra` 内容可以被截图和无障碍检查；同时补充统一的本机构建运行脚本。

## 0.29.0 — 状态必须能解释自己

这一版来自一次安装版实机审计。问题不是面板「少几个字段」，
而是已有字段在真实 Codex rollout 上**语义不可信**：
内部工具标题被当成用户任务、工具调用完全漏报、长会话丢失项目，
累计数百万 token 被包装成当前进度。精致的行因此看起来有内容，
却不能回答「它在做什么、多久没动、为什么需要我」。

### Codex 改为结构化读取

- 会话标题只取真实 `user_message`，不再全局搜索任意 `title`。
  MCP/桌面操作标题即使也写进 rollout，也不会出现在用户任务位置。
- 工具提取支持 `tool_use`、`custom_tool_call`、`function_call`、
  `tool_call` 与 MCP 调用；工具结果、嵌套参数和相邻记录不能借出一个名字。
- 稳定元数据读文件头，动态事件读文件尾，长会话不再退化成 UUID 后缀。
- Codex token 改取最近一轮 `last_token_usage`，不再显示整个 rollout 的累计量。
- 用户任务使用稀疏读取：只解析可能是真实用户消息的行，
  不为找一个标题反复解码数 MB 工具输出。

这些约束落在共享解析器，Claude、Gemini 以及其他 JSON/JSONL collector
也同步获得工具结果隔离和标题防猜测；没有可靠事件的 Agent 仍诚实显示
「进程存在」，不从配置或日志文本编造活动。

### 主行只留能做判断的事实

- `×2` 改成带单位的 `2 processes / 2 个进程`。
- Settings 与 Tray 共用去重后的身份，`Cursor · Cursor` 不再出现。
- 主行显示项目、最近工具、最后活动、会话时长与真实 subagent 进度。
  token 快照和混合事件记录数移入详情，避免把累计/容器量伪装成实时进展。
- 每行增加常驻「更多操作」菜单与右键菜单；聚焦、打开目录和详情
  不再只靠 hover 才能访问。
- VoiceOver 现在读出状态、路径、最近工具、活动时间、会话时长和等待原因，
  与视觉用户获得相同的可观测信息。

### 状态一致性与冷启动

- 系统通知被拒绝时，Idle、Waiting 与提示音三项统一禁用；
  存储层也不会继续尝试发送。
- Python harvest 使用无缓冲输出，超时时已完成的 Agent 行会立即到达 Swift，
  一个慢 collector 不再让它前面的所有 Agent 一起消失。
- 冷启动窗口从误杀正常的后台 Python/SQLite 启动调整为 3.5 秒；
  热扫描仍通常在一秒内完成。

`harvest_stats_check.py` 新增超过 tail 窗口的真实 Codex fixture，
端到端验证用户任务、头部 cwd、最近一轮 token、函数工具与无缓冲子进程参数。

## 0.28.1 — 门禁只能守它真正执行的东西

两份第三方审查读了 `v0.27.2..v0.28.0`，一共提出 11 条实质问题。
**我逐条复现，没有一条是假阳性。** 全部修在这一版。

最难堪的一条是关于我上一版最得意的那个门禁。

### 门禁在冒充验证

`harvest_stats_check.py` 的 docstring 写着「建立真实会话文件、运行真实 harvester」。
实际上它调 `session_stats()` 和 `emit_row()`，手工拼 tuple，
然后靠**数源码里 `session_stats(` 这个字符串**判断 collector 是否接线。

**字符串计数分不出「接线」和「接了但下游被砍掉」。** 而恰好有两处被砍掉：

- **Cascade** 在索引 10 建好 stats dict，两行之后 `norm.append(row[:9])` 把它连同
  多余的 agent 字段一起截掉——文件扫描的开销照付，指标恒为 `0/0`。
- **Amp** 的 pending 分支按索引重写字段，`lst[8] = amp_sid` 正好写在 thread 行
  stats dict 所在的位置。

两条都出厂了，**门禁全程绿灯**，我还据此报出「18 个 harvester 已接线」。

现在它把 `HOME` 指到临时目录，按各 collector 真实的查找路径铺会话文件，
跑真 collector，读完整 TSV。两个 bug 都放回去验证过会红。

> 第一版新门禁**仍然漏掉了 Amp**——fixture 没走到 pending 分支。
> 补了 pending log，并加断言强制它走到那里。
> **是「先把 bug 放回去确认会红」这个动作抓住的，不是我的判断。**

### 严格提取器在猜

它的第一档是「`"type":"tool_use"` 之后 200 字符内任意 `"name"`」：

```
{"type":"tool_use","input":{"name":"production"}}        → production   （嵌套参数）
{"type":"tool_use","id":"x"}\n{"role":"user","name":"alice"} → alice   （下一条记录）
```

**我那四个误报 blob 全都没有 `tool_use` 前缀，所以第一档一次都没被测到。**
我写它是为了防猜测，测的却只有兜底档。

现在真解析 JSON：`name` 必须是携带 `type == "tool_use"` 的**同一个 dict** 上的字符串。
嵌套塞不进来，邻居也借不到。

### 「正在跑」是超额承诺

白名单兜底档对 `tool_result` 和 `tool_use` 一视同仁——工具跑完了也会命中。
不改提取器，改措辞：这一列是**最近**的工具，不是**正在跑**的。
运行状态这里观察不到。

### `started_ms` 对容器文件是编造的

`harvest_extension_storage` 从共享 blob 里取 `obj[-1]`，
却把**整个容器文件**的创建时间当成那个会话的开始——
三月创建的 VS Code 存储文件，会让五分钟前开的会话显示成四个月。

`per_session` 改成**无默认值的必填参数**，逼每个调用点表态。
三个读容器或追加日志的 collector 声明 `False`，什么都不报。

### `turns` 不是轮数

它就是换行数。而一份 transcript 里混着用户消息、助手消息、
工具调用、工具结果和 token 事件——34 条记录不是 34 轮对话。
端到端改名 **`records`**，中文「条」。

### Waiting 行仍在显示量

上一版的说明写着「等待行不放」，实际只有 tokens 被挡住，
时长、记录数、子任务进度照常出现。现在整行返回空。

> 上一版的测试只构造了**带 tokens 的**等待行，而 tokens 恰好是唯一被挡的那个。
> 现在测试带齐四种量。

### 旗舰 Agent 没接上

「23 / 32」是按 harvester 数量算的。按实际使用：
**claude / codex / gemini / cursor / opencode 一个都没接。**
`claude_block` 直接 `emit()`，根本不经过读取哨兵的 `emit_row`。

前三个已接线，都移到解析式提取器。**门禁改成点名要求它们在列**，
而不是数到 15——一个阈值永远说不出「最常开的那几个不在里面」。

### 扫描预算

每文件 8 MB 的上限在 19 个调用点、2.5 秒 harvest 窗口下不构成边界。
超时后部分输出会被当作可靠结果，所以一个慢 collector 不只丢自己那行，
**还会连累它后面的所有 agent**——这违反「一家 collector 不得遮蔽其他 agent」。

每文件 8 → 2 MB，外加整轮扫描 24 MB 上限。

### 文档指针

`AGENTS.md` 还写着「0.22 已发布、0.23 进行中」，
`docs/architecture.md` 只列三个门禁并称之为「全部自动防线」。都已更新，
并写进一条规则：

> **门禁只能守它真正执行的东西。**
> 凡是加门禁，先把它要防的那个 bug 放回去，确认它会红。

### 唯一要纠正报告的地方

其中一份把扫描开销估为「数百 MB」。那是理论上界——
`session_stats` 只在 `.jsonl/.ndjson` 时才真读，`.json` 容器只 `stat()`。
**风险形状是对的，量级偏高。** 仍按风险处理并收紧了预算。

## 0.28.0 — 面板终于有东西可显示

前六个版本我一直在重排面板。这一版去数了一遍**面板到底有什么可排**，
答案是：几乎没有。

### 先说这个数

`src/activity_scan.py` 里 32 个 harvester，逐个扫过之后：

| 会变化的事实 | 改之前 | 现在 |
| --- | --- | --- |
| tokens | 5 | 5 |
| 当前工具名 | 5 | **19** |
| 会话时长 / 轮数 | 0 | **17** |
| **有任何一样** | **6 / 32** | **23 / 32** |

**26 个 Agent 什么都不产出。** 它们的行只能说会话标题和路径，
而这两个在整个会话生命周期里都不变——**跑了四十分钟的会话，
和它第一分钟长得一模一样**。

面板不是设计得不好，是它没东西可显示。

### 两个通用事实

- **`turns`** —— 会话文件的记录数（JSONL 即行数，一次流式扫描）。
  「已经发生了多少」的通用量词。
- **`started_ms`** —— 文件创建时间。面板终于能说「这个会话跑了三小时」，
  而不是只能说「一分钟前动过」。

两条诚实约束：超出字节预算报**未知**，不按比例外推；数不了的格式**不给数**。
跟 Waiting 一样，缺就是缺。

### 工具名：差一点就开始猜了

现成的 `last_tool_name` 最后一档是「任意 `"name": "..."`，
只要不在六个已知非工具的 key 里」。对它当初面向的四个 transcript 形态的 Agent 没问题。
指向另外 26 个之后，实测四个真实形状的配置 blob：

```
{"name":"workspaceFolder",...}      → workspaceFolder
{"profile":{"name":"Default"},...}  → Default
{"servers":[{"name":"filesystem"}]} → filesystem
{"model":{"name":"claude_sonnet"}}  → claude_sonnet
```

**4 / 4 全部误报**，每一个都会被显示成「这个 Agent 正在跑 X」。

这正是产品在别处坚决不做的推断。严格版只认结构化 `tool_use` 记录
和已知工具名白名单，其余返回空——宁可空着。

### 面板：量放到次行右端

```
Pulse installation guide
~/Documents/Cursor · Bash · 3m ago        2h · 34 轮 · ↑12k ↓3k
```

次行右半边本来就是空的，**不多占一行高度**。等待行不放，那里的空间归那个问题。

> `EXPERIENCE.md` 里「一条静态行最多 4 个事实，其余走悬停浮层」
> 是在行里塞了 10 个事实的时候写的，然后矫枉过正：上限是 4，而行一直坐在 2，
> 且两个都是静的。规则已修正。

### 其他面板修复

- **「No project」不再发表头**。用一整行说「下面这些行缺东西」，
  是全面板信息密度最低的一行：一个否定事实，说的是用户已经看得见的行。
- **分组表头取消固定**，因此不再需要背景。0.27.1 和 0.27.2 各换了一种材质，
  那条更亮的带都还在——因为固定的表头必须不透明，而任何压在面板材质上的
  不透明层都会叠出更亮的一层。取消固定是**构造上**消掉它。
- 根材质 `regular → thick`：更厚单调地等于透过来的桌面更少。

### 第七道门禁，而且它真的在跑代码

`scripts/harvest_stats_check.py` 在临时目录里建真的会话文件、跑真的 harvester，
断言：列到齐、预算护栏生效、旧的 12 列行仍能解析、dict 哨兵没把字段挪位、
严格版拒绝全部四个误报 blob 同时仍能读出真 `tool_use`。

还有一条反向断言：**如果宽松版哪天不再乱猜了，门禁会红**——
免得严格版变成没人知道的冗余。

**这一层是 Python，跑在 CI 和本地，不是靠看。** 这是这几个版本里
第一次有改动能被端到端验证。

### 仍未验证

轮数和时长会不会出现在**你的**机器上，取决于各 Agent 会话文件的真实形态；
门禁覆盖的是合成文件。面板长什么样也依然只有截图能回答。

## 0.27.2 — 把深色模式装回来，并让行说出它正在干什么

**0.27.1 没有深色模式。** 深色桌面上，面板是一块浅灰底加黑字。
这是 0.27.1 引入的，源头是一行：

```swift
static let surface = Color(nsColor: .windowBackgroundColor)
```

`static let` 是**只初始化一次的全局量**。面板第一次绘制时是什么外观就被冻在里面，
之后再切主题都不动。这个 app 从那一刻起就没有深色模式了——
而**六道门禁、198 个测试、四轮 CI 全绿**，因为这里没有任何东西会渲染。

那行代码是拿系统材质换来的，换的依据是我对「它会长什么样」的猜测，而我看不到结果。

### 修法：换回材质，并把它变成门禁

表面改回 `Material`。渲染器每一帧对着视图自己的外观解析它——
**这个性质是构造上成立的**，不依赖任何人的判断。

新增第六道门禁 `scripts/appearance_check.py`：
任何把随外观变化的值存进 `let` 的写法都会让 CI 变红。
它是拿真实的那行代码写出来并验证过会拒绝的，不是照着描述写的。

### 同一个错误带出的三件事，一并撤掉

- **在圆角半透明窗口里画不透明直角矩形**。窗口多出来的那截高度变成第二个表面，
  面板读成一个贴上去的盒子。材质和窗口共用同一层底，那条缝就不存在了——
  而不是用 `.fixedSize` 去追它（它从来没起过作用，删了）。
- **通宽分割线**压在平板上就是表格线，两条把面板切成条带。内缩到文字边距。
- **头部**：删掉 18pt 圆标是对的（它复述了用户刚点过的那盏灯），
  但 padding 留在原地，13pt 的一行字漂在 40pt 的空带里。
  让状态词占掉那个空间（15pt），padding 收紧。

### 行里终于有一个活的事实

**会话标题是死的。** 它在整个会话生命周期里不变，
所以一个跑了四十分钟的行和它第一分钟长得一模一样——活儿在干，面板看着是静止的。

`tool` 是活的那个。它**从第一版就在采集**，六个版本里只出现在悬停浮层和展开块里。
现在它在次行中间：

```
Pulse installation guide
~/Documents/Cursor · Bash · 1m ago
```

只对 live 行显示——已结束的会话上，最后碰过的工具是历史不是状态，
显示出来会像还在跑。已经当标题的时候也不重复。

进程行是面板最薄的一行：harvest 什么都不知道，标题退回 Agent 名，次行是空的。
它仅剩的一个事实是进程数，原来埋在展开块里，现在挂到芯片上（`process ×2`）。

### 仍未验证

外观这个 bug 是**构造上**修好的，不再有常量能冻住主题。
但面板现在好不好看，仍然只有截图能回答。
0.27.0 的键盘导航也依然没在真机上按过。

## 0.27.1 — 面板只有一个表面

0.27.0 的真机截图暴露了六个问题，全部是这一版修掉的。
**这个版本不加任何东西**，只修 0.27.0 自己带出来的毛病。

两张截图是同一个面板：一张在蓝色壁纸上，一张在深色桌面上。

### 面板原来没有自己的底

内容直接坐在弹窗的 vibrancy 上，于是**同一个面板在蓝壁纸下整块泛蓝、
在深色桌面下变成一块灰板**——可读性成了用户壁纸的函数。
绿色的状态词在前者里是绿压饱和蓝，在后者里几乎读不出来。

现在面板画在不透明的 `windowBackgroundColor` 上。
**这是拿毛玻璃换可读性**：一个强调色的词必须在任何人的机器上都能读，
这个取舍不算难做。

### 分组表头曾是整个面板最亮的一块

`.thickMaterial` 叠在那层 vibrancy 上，让表头比它分隔的行更亮，
而它承载的是屏幕上最不重要的信息。

现在用和面板同一个表面。它仍然不透明（行要从它下面滚过去），
但不再是另一个明度。**一个表面，不是一叠板子。**

> 这一项在 0.27 的计划里标着「需截图，不看不动」。现在看到了。

### 窗口比面板高出一截

上下各露出一条窗口底色，读起来就是第二个表面。
（点那片空白会关闭面板，这也确认了它是窗口而不是内容。）
改成按面板实际画出来的高度给窗口取值。

### 折叠藏起了本来放得下的内容

三个会话，折走两个，屏幕上只剩一行。

原来的规则只问「这个组能不能折」，从不问「面板到底挤不挤」。
折叠是拿**一行屏幕**换**一次点击加内容被藏起来**——
只有屏幕真的稀缺时这笔交易才划算，三行的时候不是。

两条折叠规则现在都要求总行数 ≥ 5。

### 「No project 2 Pi · Amp」

两个名字和一个 2，同一个事实说了两遍。
摘要点名了每一行时不再发计数；摘要收敛了才发——
三个 Claude 会话摘要成一个「Claude」，那时计数是唯一说清数量的东西。

### 头部的灯

菜单栏的标记就在 40px 之上，同形、同色、同 `glance`。
头部只该说行内说不清的事，图标同理。删掉；
状态词保留 glance 颜色，那才是带信息的部分。

### 仍未验证

**这一版同样没有视觉验证**，尤其是不透明表面——
它是一个关于面板该长什么样的判断，只有下一张截图能定案。

0.27.0 的键盘导航也仍未在真机上验证过。

## 0.27.0 — 一个等待终于有了第三种回应

0.26 之前，你对一个等待只有两种回应：**现在处理**，或者**永久清除**。

最常见的那一种不存在——「知道了，等会儿再说」。
于是它落回到「靠你自己记住」，而「靠你自己记住」正是这个产品存在的理由。

### 稍后（Snooze）

行内动作多了一个「稍后」，默认 10 分钟（可配 5 / 10 / 30 / 60）。

**它压制的是打扰，不是事实。**

| 压制 | 保留 |
| --- | --- |
| 菜单栏灯不变红 | 行留在列表里，仍在「需要你」分组 |
| 菜单栏不显示它的计数和时长 | 分组计数照常算上它 |
| 不发通知 | 芯片显示「已稍后 · 剩 7 分钟」，左色块变淡但不消失 |

这和静音是同一条规则（静音的 Agent 不发通知，但照常出现在列表里）。
**一个会让行消失的按钮，是没人敢按的按钮。** 再按一次即可取消。

两处容易做错、都写了测试：

- **菜单栏的时长只从「未稍后」的等待里算**。否则一个被稍后的、等了一小时的行
  会一直霸占菜单栏标题——你稍后的恰恰是它。
- **稍后到期时，先把它从「已知等待集合」里删掉再重新构建快照**。
  「新等待」这条边沿是集合差集，如果 key 全程留在集合里，
  到期后它会**悄无声息地回来**——一次不会响的提醒等于没有提醒。

### 通知横幅上的按钮

`PulseNotify` 原本一个 `UNNotificationCategory` 都没注册，
所以横幅只能整体点击，你唯一能做的事就是放下手里的活。

现在有「去看看」和「稍后」。横幅正是打扰落地的地方——
能在那里直接推迟，才算闭环。

### 停滞阈值可配

原来是写死的 20 分钟，一个对谁都不合适的值：
跑长构建的人 20 分钟不算停滞，跑短问答的人 5 分钟就该被提醒。

设置 → 通用：5 / 10 / 20 / 30 / 60 分钟，或「不判定」。默认仍是 20。

### 按项目分组也能折叠了

`TrayFold.foldable` 的第一个条件就是 `section == .recent`，
于是**给「同时开好几个仓库」的人准备的那个模式，恰好是唯一不折叠的**。

护栏和「最近」一样（唯一分组不折、单行不折），外加最关键的一条：
**含等待的项目永不折叠**——把需要你的那件事折起来，等于产品失效。

### 键盘导航

↑↓ 走可见的行（折叠起来的组会跳过，不会选中你看不见的东西），
Enter 聚焦，Esc 取消选中，Space 折叠当前行所在的组。

面板通常是快捷键唤出来的，手已经在键盘上了，用鼠标收尾才是别扭的那一步。

### 两处视觉

- **行高亮改成内缩圆角**。邮件、访达侧栏、通知中心全是内缩加圆角；
  全宽贴边的直角色块是 web 的做法，也是面板里最容易读出「不是 Mac 应用」的一处。
- **折叠与行增删加 160ms 过渡**。一个每两秒重建一次的列表，
  硬切会让「新会话出现了」和「顺序变了」长得一模一样。

### 已知未验证

**键盘导航没有在真机上验证过。** `onKeyPress` 依赖面板拿到焦点，
而 `MenuBarExtra` 的 window 样式下这件事只有在真机上才知道成不成立。
CI 能证明它编译，证明不了按下箭头会有反应。

计划里标为「需截图」的分组表头材质一项**没有做**——现在仍然没有截图，
不拿一个视觉判断去改一个视觉问题。

## 0.26.0 — 面板只留你此刻要看的东西

0.25 把每一行的内容修对了。这一版处理的是**面板整体**：
哪些行值得占位置、一行有多宽、以及一个 Agent 凭什么长得像半成品。

### 「最近」默认折叠

真机截图里四行有两行是「最近」——已经结束的会话，没有任何可做的事，
占掉半个面板，也占掉一半的阅读。

现在分组表头兼作展开控件，默认折起：

```
▸ 最近 3  Claude · Cursor
```

折叠态必须带上组内的 Agent 名。只报数量不报身份，恰好是折叠制造出来的问题。

两条护栏：**「最近」是唯一分组时不折**（那些行就是内容本身，折起来剩一句
「最近 3」等于什么都没说），**只有 1 行时不折**（省不出空间，只多一次点击）。
「需要你」和「运行中」永不折叠。

展开状态不持久化——每次打开托盘都是一次新的扫视，应该从「谁需要我」开始，
而不是从上次的翻找状态开始。

### 标题不再被切掉后半截

面板 360pt → 400pt，主行最多两行，字符上限 72 → 96。

上一版我修过 `truncate()` 的按词断字，并且说过**那不是截图里的那个截断**——
截图里的是 `lineLimit(1)`，而 72 这个上限本身就低于面板能显示的字数，
字符串在排版之前就已经被剪短了。三处一起改：单纯加宽只会挪动省略号的位置，
第二行才是保住任务名后半截的东西，而任务名的后半截才是识别它的那半截。

### 补齐 10 个 Agent 图标

三十二个 Agent 里有十个没有图标，托盘就在一排剪影中间画两个字母：
Droid 是「Dr」，Command Code 是「CC」。这是面板里最显眼的未完成感。

修法是补图，不是换一种退路。`scripts/make_agent_icons.py` 把 windsurf、devin、
kiro、junie、kilo、replit、droid、command_code、antigravity、kimi 画成几何标记，
坐标系与笔画粗细都对齐已有的 Simple Icons。

**这些是 Pulse 自己的图形，不是厂商的商标**——README 在支持列表旁边写明了这一点，
也写明了另外 22 个的来处。

### 新门禁：每个 Agent 都有图标

生成器就是源，不是一次性脚本：`--check` 重新渲染到内存里逐字节比对，
committed 的图不可能和描述它的代码分家。

它同时检查**每个 `AgentID` 都有图标**——这才是当初烂掉的地方：
新增一个 Agent 会静默退回字母标，在有人打开托盘之前没有任何东西变红。
`ci.yml`、`release.yml`、`release.sh`、`package.sh` 现在都跑它。

### 其他

- `AGENTS.md` 里过期的「107 个测试」「三个门禁」改成实际的 177 与五个

## 0.25.0 — 每一行都值得占那个位置

0.24 把一行从 10 个事实压到 4 个，**却没检查这 4 个是不是同一个事实**。
真机截图显示问题正好翻了个面：少数几个事实被重复说了三四遍，
而真正有用的信息一个都没有。

计划与验收见 [`docs/plan-0.25.md`](docs/plan-0.25.md)。

### 修复：切换语言后行内文字不跟随

面板外壳变成英文，而每一行仍是中文。`AgentRowButton` 持有的是
`let store` 而不是 `@ObservedObject`——它不订阅变更，所以切语言时外层重绘了，
每一行却收到相同的 `row` 值和相同的 store 引用，SwiftUI 判定输入未变、直接跳过。

**这个 bug 早于 0.24 就存在**，只是语言切换才让它显形。

### 次行：从「谁」换成「哪里 + 多久」

```
[icon] Pulse installation guide
       ~/code/Pulse · 12 分钟前
```

`cwd` 和 `harvestMs` **从第一版就在采集，从来没展示过**。
而它们顶替掉的那行在复述图标已经表达的 Agent 名——
项目目录恰好叫 Cursor 时，甚至会显示成 `Cursor · Cursor`。

现在每一行都能回答「在哪里、多久没动静」，而不只是「谁、什么状态」。

### 运行中不再发芯片

「运行中」原本被说三遍：头部「2 个运行中」、分组表头「运行中 2」、
每行一枚绿芯片。**运行中是常态，常态不需要徽章**——
芯片只留给需要你反应的状态：等待中（带时长）、进程、最近、子任务。

**没有芯片就是运行中。**

### 头部只说行内说不清的事

头部次行改为只讲聚合：折叠了多少行、跨几个项目。
**只有一个项目时保持沉默**——那个路径每一行下面都写着。

### 动作区：5 行菜单 + 页脚 → 一条图标栏

原来 5 个整宽菜单项加版本页脚吃掉 600pt 面板里的约 170pt，
**比它们框住的内容还占地方**。改成一条约 34pt 的图标栏，
版本徽章挂在末尾——它本来就该安静地待着。

### 其他

- **详情改为行内展开，可选中可复制**。0.24 把它们塞进悬停 tooltip，
  而 tooltip 选不中、复制不了、看到一半就消失
- 行悬停有了背景反馈；行与行之间的分隔线删除（留白已经够分隔了）
- 按项目分组改用真实路径，不再在项目未知时退化成 Agent 名
- 无会话标题的进程行，标题改用 Agent 名（原本是「检测到进程」，
  和芯片、次行、表头重复了四次）
- 回到面板时提示「你离开时有 N 个等待已结束」
- 测试 142 → **156**

### 已知未完成

- **这一版的界面同样没有经过人眼验证。** 构建环境没有 macOS。
  0.24 的教训——编译通过、测试全绿、规格同步更新，界面照样不对——
  在这一版原样成立。两个未验证的设计赌注：
  **「没有芯片就是运行中」是否可读**，以及**图标动作栏是否过于隐晦**。
- 「跳到等待最久的」仍是托盘内动作（`⌘J`），不是全局快捷键。
- DMG 仍是 ad-hoc 签名；`activity_scan.py` 的 32 处静默 except 仍无调试通道。

## 0.24.0 — 一眼看出该管谁

0.22 补功能，0.23 补可信度。这一版补**辨识度**。

Pulse 之前能告诉你「有东西在等你」，但说不出**等的是哪个、等了多久、该先管谁**——
三个 agent 同时红灯时，托盘那三行长得一模一样。

计划与验收见 [`docs/plan-0.24.md`](docs/plan-0.24.md)。

### 托盘默认能看到更多 agent

之前实际只能看到 3 个。原因是每一行都常驻一条操作按钮条（约 28pt），
而面板视口写死 300pt。三处一起改：

- 操作按钮（忽略 / 聚焦 / 打开目录）**Waiting 行常驻，其余行悬停才出现**
- 面板高度改为**测量内容**（封顶 420 / 展开 620），不再是写死的数字
- 每次最多显示的行数 5 → **8**

### 等待时长升格为主信息

`waitSinceMs` 一直在采集、格式化函数也早就写好，但唯一的出口是行内第三行的
`↳ 12分 · hooks: 消息`——和信号来源、原始消息挤在一起。
**等 30 秒和等 40 分钟在旧界面里长得一样。**

- 时长进状态芯片：`需要你 · 12分`
- Waiting 行**按等待时长排序**，最久的在最上（时间戳未知的排最后，不会冒到最前）
- 超过 10 分钟，左侧色块由 3pt 变 6pt——**全行只有这一处**用"更响"表达"更久"
- 菜单栏跟着升级：`Claude…` → `Claude · 4m`，多个等待时 `2 · 12m`
  （5 秒以内不占这个位置：那时它只会显示「刚刚」，而灯本身已经说明了）

### 分组表头

行按 `需要你 · 2` / `运行中 · 3` / `最近` 分组，计数是**全量**而非窗口内条数。
排序做了却不呈现，等于没做——五行平铺读起来就是五个平等项。

设置里可切换成**按项目分组**，含等待的项目排在前面。

### 一行不再塞 10 个事实

次行原本拼最多 5 段（`Claude · Pulse · ×3 · Warp · hooks`），下面的 meta 行再拼 5 段
（`↑1.2k ↓340 · Edit · planning · sub 2↑ · a3f9c1`）。两行三级文字里 10 个并列事实，
一个都扫不到。

现在次行封顶**两个事实**（Agent · 项目），其余全部移到悬停浮层。信息没丢，只是不再抢主线。

### 状态编码 8 种 → 3 种

一条行的状态原本同时由 8 样东西表达：左色块、行底色、图标透明度、标题字号、
字重、颜色、芯片、整行透明度——8 种编码表达大约 4 个状态。
**冗余不是强调**：每多一种，其余每一种的信噪比都低一点。

保留：左色块（是否需要你）、芯片（状态 + 时长）、标题字重（真实会话 / 裸进程）。

### 动效克制

菜单栏图标的**永久呼吸改成新等待出现时闪一次**。常驻动画在菜单栏是噪音：
每次经过零点都拽一下眼睛，一秒之后不再提供新信息，而且它在 30 秒和 40 分钟时
长得一样——反倒和真正表达紧迫度的时长抢注意力。

### 其他

- **`⌘J` 跳到等待最久的**——从「有东西在等」到那个终端页，一步
- **今天被打断 N 次**：设置 →「最近的等待」多一行摘要，取自已有的等待历史
  （一行，不是统计大盘）
- **可选提示音**，默认关
- 修掉 `headerDetail` 恒显示「刚刚」：它在 `updatedAt = Date()` 之后立刻计算，
  差值恒 < 5 秒。改为显示涉及的 Agent 名，并删掉只能产出常量的 `Context.relativeLabel`
- 测试 120 → **142**

### 已知未完成

- **这一版的视觉改动没有经过任何人眼验证。** 构建环境没有 macOS，
  无法截图或实际打开面板；只有编译和单元测试的保证。
  计划里要求的「每项配前后对比截图人工过」没有做到——这是本版最大的未知。
- 「跳到等待最久的」是**托盘内**动作（`⌘J`），不是全局快捷键。
  `GlobalHotKey` 目前只注册一个热键、回调写死为唤出面板，加第二个需要改注册与分发。
- DMG 仍是 ad-hoc 签名；`activity_scan.py` 的 32 处静默 except 仍无调试通道。

## 0.23.2 — 打包自检，并订正 0.23.1 的归因

功能没动。这一版加的是**验证手段**，同时订正 0.23.1 说明里一处讲错的根因。

### 0.23.1 的根因说错了

0.23.1 里我写的是「包内多出的 `Contents/` 让 CFBundle 打不开」。**这是错的。**

真正的原因是查找路径不匹配。SwiftPM 给 **executable target** 生成的访问器只有两个候选：

```swift
let mainPath  = Bundle.main.bundleURL.appendingPathComponent("PulseBar_PulseBar.bundle").path
let buildPath = "/Users/runner/work/.../PulseBar_PulseBar.bundle"
guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else { fatalError(...) }
```

`.app` 根目录，和编译期写死的构建目录 —— **`Contents/Resources/` 从来不在候选里**。
而 `package.sh` 恰好把资源包放在 `Contents/Resources/`。多出来的 `Contents/` 确实是脏的，
但访问器压根没走到那一层，它不是崩溃原因。

在 v0.23.0 的二进制里搜字符串可以直接确认：`could not load resource bundle: from `
命中 1 次（双候选版），`unable to find bundle named`（多候选版）命中 0 次。
v0.23.1 里前者已经归零 —— 因为所有调用点都换成了 `PulseResources`。

0.23.1 的修复本身是有效的，但它有效是因为 `PulseResources` 的候选表以
`Bundle.main.resourceURL` 打头，不是因为我当时给出的那个理由。

### 加了什么

- **`PulseBar --selftest`**：打包后用**真实的二进制、在真实的 `.app` 里**跑一遍资源解析，
  逐项报告能不能找到。入口点移到 `PulseBarMain`，在 AppKit 初始化之前返回，
  所以无头 CI 上也能跑。这是唯一一种不依赖「我们以为运行时去哪找」的检查。
- **`package_check.py` 不再把单一位置写死成唯一正确答案**：
  `Contents/Resources/` 和 `.app` 根都接受，两处都校验扁平结构与 `Info.plist`。
  之前那版断言包必须在 `Contents/Resources/` —— 而这只有在换掉 `Bundle.module`
  之后才成立，等于把我自己的假设当成了不变量。
- **门禁禁止 `Bundle.module`**：它一旦解析失败就 `fatalError()`，
  把打包失误变成没有线索的启动崩溃。用 `PulseResources`，找不到返回 nil。

### 没做的一件事

原计划还要往 `.app` 根目录再放一份资源包（或做 symlink）以兼容两种查找。
最后没做：`.app` 顶层除 `Contents/` 外放东西是非标准结构，有 codesign / Gatekeeper 风险，
而 `--selftest` 已经能直接证明解析可用，禁用 `Bundle.module` 的门禁也堵死了退化路径。
为一个已被证明不存在的问题引入一个真实的签名风险，不划算。

## 0.23.1 — 修复启动崩溃

**0.21.0 / 0.22.0 / 0.23.0 的 DMG 装上去打不开，一启动就崩。请升级到本版。**
从源码 `swift run` 一直是好的，所以三个版本都带着这个问题发了出去。

### 出了什么事

SwiftPM 生成的资源包是**扁平**结构：`Info.plist` 和资源目录都在包的根目录，
没有 `Contents/`。而 `package.sh` 在包里**又建了一层 `Contents/Resources/`**
并把资源复制了一份进去。

CFBundle 一看到 `Contents/` 就改用现代包布局：不再读根目录，转而去找
`Contents/Info.plist` —— 那个文件从来没被写过。于是 `Bundle(url:)` 返回 nil，
编译器为 `Bundle.module` 生成的访问器走到最后一行 `fatalError()`。
菜单栏画第一个图标时就会碰到它，所以是**一启动就崩**。

从发布的 v0.23.0 DMG 里解出来的实际结构：

```
Pulse.app/Contents/Resources/
├── AgentIcons/ Brand/ *.py          ← 这一份是好的
└── PulseBar_PulseBar.bundle/        ← 整个包没有 Info.plist
    ├── AgentIcons/ Brand/ *.py      ← SwiftPM 的扁平布局
    └── Contents/Resources/          ← 多出来的一层，正是它导致崩溃
        └── AgentIcons/ Brand/ *.py
```

### 修了什么

- **`package.sh`**：删掉那段多余的 `Contents/Resources/` 复制；资源包缺失时
  直接报错退出，不再静默继续打出一个坏包；确认包内有 `Info.plist`，
  SwiftPM 没写就补一个。
- **`scripts/package_check.py`（新增第四个门禁）**：对着**构建产物**检查，
  不是源码。校验资源包在位、`Info.plist` 在位、**没有多余的 `Contents/`**、
  以及每个运行时会去找的资源都真的能按扁平路径找到。
  已用发布出去的 v0.23.0 的真实结构验证过：会红。
- **CI 每次推送都打包**并跑这个门禁。此前只有发布时才打包，
  而打包这一步从来没人验证过 —— 这正是它能连发三次的原因。
- **资源找不到不再是致命错误。** `Bundle.module` 一旦解析失败就 `fatalError()`，
  把一个打包失误变成了没有任何线索的启动崩溃。改用不会 trap 的
  `PulseResources`：找不到就返回 nil，图标退回代码绘制的兜底样式。
  少一个图标不值得让整个 app 挂掉。
- 顺带修了 `ActivityHarvest` 里三条同样写着 `Contents/Resources/` 的兜底路径 ——
  它们指向的目录只是因为打包脚本错误地创建了才存在。

### 说明

修的是打包与资源查找，0.23.0 的功能一个没动。
`swift test` 从头到尾都是绿的，这个 bug 测试根本够不着 —— 门禁才是能挡住它的东西。

## 0.23.0 — 可信

0.22 修好了很多东西，但**没人能验证它修好了**：最容易出错的合并逻辑没有测试，
设置读写没有测试，公开的能耗数字是算出来的，「检查更新」对所有人永久报错。
这个版本不加功能，只把上一版的承诺变成可以核对的事实。

计划与验收见 [`docs/plan-0.23.md`](docs/plan-0.23.md)。

### 可测

- **`SnapshotBuilder`：合并逻辑从 `StatusStore` 里抽出来了。**
  「进程 + 会话文件 + attention → 托盘行」这段最容易出 bug 的代码，此前和 6 种副作用
  （取当前时间、枚举运行中的 App、读磁盘、发通知、动定时器、写日志）缠在一起，
  `applyScan` 一个函数 381 行，无法测试。现在外部世界通过 `Context` 注入，
  想让外部世界做的事（通知边沿、清除的键、日志行）作为数据返回，
  `StatusStore` 只留 I/O 与策略。`applyScan` 381 → 115 行，**34 个测试**覆盖
  排序、去重、封顶、waiting 边沿、stale harvest、Focus 分级。
- **设置变成值类型。** `PulseSettings` 是纯粹的解析 / 序列化 / 安静时段判定，
  完全不碰 Application Support，**23 个测试**，其中包含整点→分钟的迁移
  —— 老用户升级不丢配置这件事现在有测试兜着。
- 测试总数 **60+ → 120**，全部在 CI 的 macOS 上真实编译运行。

### 可核对

- **能耗数字自证。** 0.22 写的「28,800 → 2,880 次/天」是算出来的。现在
  「关于 → 复制诊断信息」多一行，报告过去一小时的真实情况：

  ```
  cadence: every 30s · 1h: 240 probes · 82 harvests (~2900/day) · avg 310ms · parked 12m
  ```

  probe 与 harvest 分开计数（只有 harvest 付 Python 的钱），只给 harvest 计时，
  失败的 harvest 照样算（它确实 fork 了），窗口不足 5 分钟不外推日均值。
  投影可直接和上面那个数字对比 —— 一份关于耗电的 bug 报告现在带得动证据。
- **「检查更新」不再对所有人报错。** 仓库已转 public，匿名请求 Releases 可用。
  fork 成私有仓库的情况在 README 里写清了替代做法。

### 可访问

- **VoiceOver 说中文。** 菜单栏那盏灯是旁白在那里唯一能读到的东西（意义全在图标上），
  却是整个界面里唯一硬编码英文的串。现在跟随语言设置，由 `SnapshotBuilder` 解析后
  挂在 snapshot 上，视图不会和旁边的行读到不同的语言。en/zh 键数 103/103。
- 顺带修了错误态文案：旁白原本读 "Error"，而可见 UI 说的是「无法刷新」——
  橙灯表示探测不可用，不是崩溃。

### 修复

- **停表计数不再吞掉「实时更新已关闭」的时长。** 屏幕休眠时关掉实时更新，
  那段暂停时间会被算进 parked，重新开启后一次性计入
  —— 关一周会显示「parked 10080m」。parked 是「本该探测但屏幕关了」，
  paused 是「你让我别探测」，两者现在分开。

### 文档

- README / `AGENTS.md` / `EXPERIENCE.md` 全部重写，新增
  [`docs/architecture.md`](docs/architecture.md)（数据从进程到菜单栏的完整路径）。
  清掉了早已换掉的 Vercel Native SDK 外壳留下的描述 —— 那些内容会误导后续迭代。
- 加上 [MIT LICENSE](LICENSE)。

### 已知未完成

- `release.yml` 仍不在默认分支，`workflow_dispatch` 因此不可用；
  三条发布触发路径实际可走两条（tag 推送、`[release]` 标记）。
- DMG 仍是 ad-hoc 签名，首次打开需右键或 `xattr -dr`。
  设仓库 secret `PULSE_SIGN_IDENTITY` 即可产出 Gatekeeper 友好的包。
- `activity_scan.py` 里 32 处静默 `except Exception` 仍未打开调试通道，
  「为什么某个 Agent 没显示」目前仍不好排查。

## 0.22.0 — Energy, honesty, and everything the audit found

Closes every open finding in [`docs/review-0.21.md`](docs/review-0.21.md).

### Energy (P0-A)
- **自适应探测节奏**：不再固定 1.5–3s。等待中 2s / 运行中 5s / 最近 15s / 空 30s；
  托盘打开时提速，低电量模式减半，**息屏或锁屏直接停表**（attention 文件变化仍会唤醒）
- **harvest 与 probe 解耦**：`ps` 便宜可以常跑，Python 采集按节奏跳过；
  进程指纹变化 / 手动刷新 / attention 变化时强制采集
- **定时器容差 20%**：让系统合并唤醒
- 空闲机器上的 Python fork 次数从约 28,800 次/天降到约 2,880 次/天

### Distribution (P0-C)
- **Developer ID 签名 + 公证**：`PULSE_SIGN_IDENTITY` / `PULSE_NOTARY_PROFILE`；
  未设置时明确警告「其他 Mac 会被 Gatekeeper 拦」。移除已废弃的 `--deep`
- **检查更新**：GitHub Releases，每天至多一次，可关；数字版本比较（`0.9.0` 不会盖过 `0.21.0`）

### Tests & CI (P0-B)
- **PulseBar 首次有测试**：60+ 用例覆盖版本 / 更新比较 / harvest 解析 /
  attention 规则 / 探测节奏 / Focus 分级 / 行展示 / 安静时段 / 通知文案 / L10n
- **GitHub Actions**：Linux 跑门禁（版本、覆盖、支持矩阵、Python 编译、资源同步），
  macOS 跑 `swift build` + `swift test`
- **支持矩阵门禁** `scripts/matrix_check.py`：README 表格与 `waitingSource` 不符即失败

### Product gaps
- **多会话可见性**：每 Agent 上限 2 → 4，托盘上限 4 → 5 行；被压下的会话显式提示「另有 N 个会话未显示」
- **通知信息量**：标题 `Agent · 项目`，正文 `原因 · 消息`（此前只有「需要你处理 · Claude」）
- **通知权限失败可见**：被拒时开关置灰并给出「打开系统设置」
- **移除 hooks**：设置页可一键卸载，只删 Pulse 条目，保留用户自己的 hook
- **最近的等待**：等待结束后进入历史（最多 12 条），回答「我是不是错过了什么」
- **快捷键可选**：⌘⇧P / ⌘⇧U / ⌘⌥P / ⌃⌥P / 关闭；被占用时明确提示，不再归咎辅助功能权限
- **安静时段支持分钟**：22:30 可表达（旧的整点设置自动迁移）
- **按 Agent 静音**：静音只停通知，列表照常显示
- **空态引导**：说明 Pulse 何时会亮，并直接给出安装 hooks 按钮

### Fixes
- **管道死锁**：子进程输出此前在其退出后才读，输出超过 64KB 管道缓冲即死锁到超时。改为独立线程边跑边读
- **超时丢弃全部结果**：改为保留已完整输出的行，并丢弃被截断的最后一行
- **`tail_bytes` 全文读入**：名为 tail 实为 `read_bytes()[-n:]`，数十 MB 的会话文件每次全读。改为 seek 到尾部
- **视图体内做 I/O**：`estimateHeight` 每行每次重绘都遍历运行中应用 + stat 磁盘。Focus 分级改为每次扫描算一次
- **attention session 匹配失效**：`rowKey.contains(session)` 因 rowKey 省略过长 id 而永不命中
- **`sessionDetail` 从未接线**：有 tool 无 task 的 live 行不再降级成「检测到进程」
- **`isSurface` 恒真**：删除空过滤
- **hooks 状态误报**：现在同时检查 `settings.local.json`
- **登录项抖动**：`launchctl` 仅在值变化时执行，且不在主线程
- `pulse_hook.py` 未使用的 import 与空操作分支

## 0.21.1 — Version identity · honesty fixes

### Version identity
- **单一真源**：`PulseVersion.semver` 为准；`scripts/version_check.py` 校验 `app.zon` / `src/version.zig` / CHANGELOG / README 不漂移（`--fix` 自动对齐）
- **修正漂移**：`app.zon` 与 `src/version.zig` 此前停在 `0.5.0`，与实际 `0.21.x` 差 16 个版本
- **构建指纹**：打包时把 git short sha + 构建日期写进 `Info.plist`，运行时可读；`swift run` 诚实显示 `-dev`
- **Tray 版本页脚**：底部一行极弱化 `Pulse x.y.z`，点击复制诊断信息
- **关于区重做**：版本 / 构建行 / 复制诊断按钮；bundle 与二进制版本不一致时高亮「版本不一致」

### Fixes
- **Goose 假 Waiting**：`pending = pending or True` 恒为真 —— 任何 tail 里出现 `"waiting"` 的 Goose 会话都会被点亮成「需要你」。改为显式标记 + 5 分钟新鲜度门槛
- **harvest 单点故障**：任一 agent 采集抛异常会让整个 `activity_scan.py` 非零退出，Pulse 丢弃全部 32 个 agent 的扫描结果。改为逐 agent 隔离，失败只写 stderr
- **Codex hook 装错表**：`notify` 曾被追加到文件末尾，落进最后一个 `[table]`（如 `[mcp_servers.x]`），Codex 永远读不到。改为定位到 root table
- **Claude settings.json 覆盖**：解析失败时曾把用户全部设置替换成只剩 hooks。改为拒绝写入并保留 `.pulse-backup`
- **调试日志无限增长**：`debug.log` 每次探测写 ~5 行且永不轮转（约 20 MB/天）。改为 2 MB 轮转保留一代
- **等待时长未本地化**：中文界面下显示 `2m` / `30s`。改为跟随语言
- **写死开发机路径**：某个开发者的 `/Users/<name>/*` 从 aider 扫描根移除，改用 `PULSE_AIDER_ROOTS`
- **watcher fd 竞态**：`DispatchSource` 的 fd 改为在 cancel handler 内关闭
- **覆盖门禁**：新增 `AgentID` 未登记到 `coverage_check.py` 时报错，不再静默缩小覆盖面

## 0.21.0 — Session-first IA

### Experience
- **Glance 交通灯**：Waiting 红 / Running 绿 / Idle 灰 / Error 橙
- **Header 只答状态**：上行 Needs you / N running；下行仅相对时间
- **会话作主语**：行 hero = 任务标题；Agent 名降到次行
- **进程降权**：无任务的 live 显示「检测到进程」，排在有标题会话之后
- **Waiting 色块**：8pt 色条 + 浅红底（替代 3pt 细轨）
- **整行聚焦**：点击行 = Focus（TTY / Warp / 打开目录）

## 0.20.0 — Clarity · hierarchy

### Experience
- **结构化 Header**：状态词（需要你 / 运行中）与明细分行，Waiting 用橙色强调
- **状态芯片**：Waiting / Running / Recent 胶囊标签，一眼辨识
- **Waiting 行强调**：左侧色轨 + 浅底，动作与内容同属一块
- **字阶分层**：名 semibold → 会话标题 → wait 橙字 → meta 等宽 tertiary
- **动态行高**：按内容估高，少裁切会话细节

## 0.19.1 — Restore session detail

### Fixes
- **会话标题回一级**：运行中 / 等待中直接显示 harvest 任务，不再一律套「刚才 ·」
- **多会话区分**：无 project 时标题用短 session；同项目时 meta 附短 session
- **设置列表**：Agent 行恢复 title + 任务摘要

## 0.19.0 — Brand · elegance

### Brand
- **App Logo**：石墨底 + 象牙灯环心跳线；`AppIcon.icns` 接入 Finder / 关于
- **菜单栏灯标**：自有 Pulse mark（idle 心跳 / running 芯点 / waiting 暂停），Waiting 轻呼吸动效

### Polish
- Tray：品牌标头、空态居中 mark、行间细分割、圆角字阶
- Settings：品牌 + 状态上下文；关于区带 mark
- Token 弱展示：Header 不再拼 ↑；Waiting 行藏 tokens；Claude 改为末次 usage 快照
- Agent waiting 角标加描边，对比更清晰

## 0.18.1 — Grok icon · tray polish

### Fixes
- **Grok 图标**：换成真实 Grok 笔触标记（不再是奇怪的假 G / 黑团）
- **启动误报 Waiting 通知**：首次扫描只播种已知等待键，不边沿通知
- **Focus 诚实**：via Warp 优先 Warp；TTY 仅在 Terminal/iTerm 可聚焦时宣称；失败回退 open cwd
- **Tray**：等待详情不再与右侧 badge 重复 kind；无额外信息时省略 ↳ 行
- **meta / 刚才**：无 task 时 tool 只出现在活动行，不与 meta 双写
- **安静时段**：起止小时相同视为关闭（不再误抑 24h）
- **设置状态文案**：空 waitKind 与 Tray 一致用「需要你」
- **SVG 加载**：`loadSVG` 补 Bundle.main 回退

## 0.18.0 — Six product traits

### Features
- **Waiting 来源标注**：wait 行带 `hooks` / `pending` 可信标签
- **Focus 诚实路由**：TTY → Warp → 在终端打开 cwd；无句柄不乱点终端；按钮文案按档位
- **Glance 并行叙事**：多 Waiting / 多 Running 时 header/tooltip 带 Agent 名
- **可选 attention 桥**：`docs/attention-bridge.md` — Droid/Kimi 可写 `attention.tsv`（不扩安装器）
- **安静时段 + 仅 Waiting 通知**：idle / waiting 通知拆分；安静时段只抑制 idle
- **行内「刚才在干什么」**：`刚才 · task|tool` 活动摘要

## 0.17.1 — Amp detect · monogram uniqueness

### Fixes
- **Amp Probe**：短名 `amp`（3 字符）此前被 pathNeedles 规则跳过；改为 basename 匹配 + 系统 AMP* deny
- **Amp Harvest**：读取现代 `~/.local/share/amp/session.json` + `history.jsonl`（不再只认旧 threads/）
- **Monogram**：全名单唯一双字母回退（无品牌图时）；去掉 Continue 的 ▶

## 0.17.0 — Capability honesty · harvest deepen

### Capabilities
- **审计对齐**：骨架 harvest 加深 — Copilot `session-state`、OpenHands sessions/file_store、Continue、Zed、Amazon Q、Roo/Kilo、Antigravity App Support、Trae/Warp
- **诚实 Waiting**：无 durable C 的 Agent（Antigravity / Trae / Warp / Devin / Junie / Replit）→ `waitingSource=none` + Tray nudge
- **门禁**：`scripts/coverage_check.py` 校验名单 harvest 接线
- **pending 词表**：扩 ask/approval/awaiting_user 等

## 0.16.0 — Droid · Command Code · Kimi · Antigravity

### Capabilities
- **新纳入**：`droid`（Factory）、`command_code`（Command Code / `cmd`）、`kimi`（Kimi Code CLI）、`antigravity`（Google）
- **Harvest**：`~/.factory/sessions`、`~/.commandcode/projects`、`~/.kimi-code/sessions`；Antigravity 尽力
- **Cline**：加深 ask/approval 字段 → `skill=pending`
- **Probe**：`cmd` 仅在 path 证据下匹配（避免短名误报）；Antigravity Waiting=`none`（诚实 nudge）

## 0.15.0 — Full coverage · hot agents

### Capabilities
- **现名单 B/C 回填**：Cline / Roo / Continue / Copilot / Amazon Q / Cascade·Windsurf / Augment / Zed / Trae / Warp / OpenHands；Grok·Pi 加深 pending
- **热门补录**：`devin` / `windsurf` / `kiro` / `junie` / `kilo` / `replit`（probe + harvest 尽力）
- **Waiting 诚实提示**：无 Waiting 接线的 live Agent → Tray 一行「暂无 Waiting 信号」（hooks nudge 优先）
- **文档矩阵**：README Agent × Probe/Harvest/Waiting

### Notes
- Waiting 仍只跟 hooks / `skill=pending`；无本地 durable 信号不强抬
- Copilot probe 收紧 CLI vs language-server

## 0.14.0 — Session attention · Codex/Amp/Aider/Goose Waiting

### Capabilities
- **会话级 attention**：`attention.tsv` 增加 `session`/`cwd`；挂对行、Dismiss、通知点击聚焦对会话
- **Harvest session id**：Claude / Codex / Cursor 等输出 session 列，rowKey 优先 session
- **Codex Waiting 加深**：hook 规范化更多 approval / user_input 事件；rollout 识别更多 approval type
- **Aider / Goose / Amp Waiting**：本地 durable 信号 → `skill=pending`（无信号不强抬）

### Fixes
- 通知 userInfo 携带 `session` + `rowKey`
- attention done/stop 可按 session 清除

## 0.13.0 — Coverage · lamp honesty

### Capabilities
- **OpenCode / Gemini / Codex Waiting**：会话内未解决的 approval / AskUser / pending tool → `skill=pending`
- **同项目多会话**：Claude / Codex / Cursor / Gemini 按 session id 去重（不再只按 project）
- **Amp 日志会话**：补 mtime，覆盖路径复活

### P0 / P1 fixes
- Clear waiting 同步 soft-dismiss Cursor/harvest pending
- 多会话不再把一个 PID 涂成所有行 Running；`×N` 仅挂最佳行
- harvest 不可靠时剥离缓存 `pending`，避免冻灯
- `activity_scan` / hooks 一致：dev 优先 `src/`
- attention 读写均 flock
- probe：收紧 `cline` / `opencode` / `pi` 匹配
- Error glance：probe+harvest 双失败且无缓存；wait kind / idle tooltip 本地化

## 0.12.0 — Needs-you 可信 · 多会话 · 包装脚枪

### Capabilities
- **Cursor blocking → Waiting**：harvest `skill=pending`（blocking actions / plan）抬成 Waiting
- **同 Agent 多会话行**：最多 2 行可按项目区分；`×N` 显示进程数
- **Hooks 缺口提示**：Claude/Codex live 但未装 hooks 时 Tray 一句 nudge
- **按行 Dismiss**：写 `done`（flock）；Cursor pending 软忽略至信号消失

### P0 / P1 fixes
- `src/*.py` 单源：打包前同步 Resources；seed 不降级 flock hook；dev 优先 `src/`
- harvest 硬失败与超时一样保留 `lastGoodHarvest`
- `clearWaiting` 与 hook 同 flock
- Attention 风暴：扫描 coalesce（只跑 latest）
- Settings：Recent / Running / Waiting 与灯一致；hooks 状态分 Claude/Codex

## 0.11.0 — Lamp honesty · wait grace · harvest cache

### P0
- **Stop grace**: Claude `Stop` no longer wipes a just-arrived Input/Permission wait (20s)
- **Harvest timeout**: keep last good harvest instead of `[]` → false Idle + idle notify
- **Copilot**: deny `language-server` / `copilot-language-server` false Running

### P1
- Glance Running only when `liveProcess` / `subRunning` / waiting; harvest-only → idle + "N recent"
- Merge `cursor_agent` → `cursor` inherits `liveProcess`
- Focus: no fallback to activate a random terminal
- `attention.tsv` writes under `fcntl.flock`
- Cursor harvest: no stamp-`now` when `lastUpdatedAt` missing
- Drop attention rows with `tsMs ≤ 0`; notify on **new** waiting agent ids
- Adaptive poll: 1.5s while waiting, 3s otherwise

### UX
- Honest header for recent-only sessions; slightly taller tray rows

### Architecture
- Same single StatusStore + probe/harvest/attention path; no new layers

## 0.10.0 — Waiting lifecycle · signal honesty · UX

### P0
- **Waiting auto-clear**: Swift AttentionReader ports Zig semantics — last event wins, `stop`/`done` clears, 30m TTL

### P1
- Harvest freshness: all emitters stamp mtime; no-mtime rows no longer fake Running
- Launch at Login opens `.app` via `/usr/bin/open -a`
- Notifications decide edges at **apply** time; stable ids (`pulse-idle`, `pulse-waiting-*`)
- Focus terminal only with tty / viaWarp / cwd; focus failure falls through to open folder
- `activity_scan.py` 2.5s timeout so Refresh cannot stick
- Cursor `skill=pending` no longer forces Waiting
- Install hooks off main thread; reconcile LoginItem on launch

### Capability
- Status lamp tells the truth after Stop; harvest-only ghosts gone; focus buttons honest

## 0.9.3 — Refresh click + Settings speed

- **Refresh 无反应**：去掉每次 `updatedAt` 变化就 `.id(...)` 重建整个 Tray（3s 定时刷新会拆掉按钮，点击被取消）
- Refresh 立即显示「刷新中…」+ spinner，结束后恢复 header
- **Settings 慢**：去掉 80–120ms 人为延迟；窗口/Hosting 复用；activationPolicy 仅在需要时切换

## 0.9.2 — Fix invisible agent rows

### Root cause
- Data path was fine (`7 running`, `and 3 more…` showed) but **agent rows had 0 height**
- `ScrollView` inside MenuBarExtra `VStack` with only `.frame(maxHeight:)` collapses to empty
- Refresh looked broken because header/tokens updated while the list stayed blank

### Fix
- Pin ScrollView to an explicit height from row count
- Keep scan off the main thread; stop dropping in-flight results via generation== check
- Write `~/Library/Application Support/Pulse/debug.log` for probe/harvest/apply

## 0.9.1 — Fix empty tray / stuck refresh

- **Empty tray**: freshness gate treated missing `mtime` as stale and dropped almost all harvest rows — restored show-when-no-mtime
- **Refresh**: `ps` + python harvest moved off the main thread so the tray stays responsive
- AttentionWatcher: avoid fd double-close / refresh storms

## 0.9.0 — Capability leap · gap close

### Capabilities
- **Claude subagents** — harvest `…/subagents/agent-*.jsonl`; tray shows `sub N↑/M` (+ header hint)
- **TTY / tab focus** — probe captures tty; Focus terminal selects Terminal.app / iTerm tab when possible
- **Near-realtime waiting** — `attention.tsv` file watcher refreshes immediately (still 3s poll as backup)
- **Hooks++** — Claude `SubagentStart` / `SubagentStop` / `PermissionRequest` + existing Notify/Stop; Codex notify
- **Actions always** — Focus terminal / Open folder when a handle exists (not only on Waiting rows)
- **Notification → agent** — tap focuses the waiting agent (TTY/cwd), not only tray reveal
- **Harvest freshness** — stale session files without a live process no longer look “running”

### Fixes
- **Settings** — rebuild hosting view each open; delayed present after tray dismiss; keep `.regular` while open
- **and N more…** — moved outside ScrollView with larger hit target; auto-collapse when ≤4

### Honest residual
- No tray-inline approve/deny/diff (no official remote HITL API)
- Warp / Ghostty exact tab still best-effort (app activate / open cwd)

## 0.8.0 — Expand more · Settings 可用 · i18n

### Fixes
- **and N more…** 可点击展开全部 Agent，再点 **Show less** 收起
- **Settings** 改为独立 `Window` + 临时 `.regular` 激活策略（LSUIElement 下原 Settings scene 打不开）

### 0.8
- 等待时长写入 `↳ Permission · 2m: …`
- Focus terminal：无可用终端时禁用
- 通知可点：点击唤出 Tray
- 语言：System / English / 中文（Tray + Settings 文案）

## 0.7.0 — Waiting闭环 + 会话行加深

### Tray
- 最多 **4** 个 Agent；超出显示 `and N more…`
- 等待行：`↳ Permission/Input · message` + **Focus terminal** / Open folder
- 会话 meta：`↑in ↓out · tool`（有 harvest 数据时）
- Header 可附带 `· ↑12k` token 汇总

### Actions
- Waiting 主点击优先聚焦终端（Warp / Terminal / iTerm / Ghostty…）
- 全局热键 **⌘⇧P** 唤出面板
- 通知改用 **UserNotifications**

### Glance
- Waiting 图标橙色强调

## 0.6.4 — Session harvest for Amp / Gemini / OpenCode

- `activity_scan.py` now harvests:
  - **Amp** — `~/.local/share/amp/threads` / `history.jsonl` / cache thread titles
  - **Gemini CLI** — `~/.gemini/tmp/*/chats/session-*` (+ `projects.json` cwd map)
  - **OpenCode** — `~/.local/share/opencode/opencode.db` session titles + tokens
- Tray can show task/project for these agents even without a live process

## 0.6.3 — More agents + CJK harvest fix

### Agents
- Added surface agents: **Cascade** (Windsurf), **Augment**, **Zed Agent**, **Trae**, **Warp Agent**
- IDE shells (Windsurf / Zed / Trae / Warp.app) stay out of the tray; only agent workers count
- Brand/monogram icons for the new IDs

### Harvest
- Fixed `activity_scan.py` JSON string decoding so Chinese/CJK session titles no longer mojibake

## 0.6.2 — Real brand marks (no ●)

- Removed status bullets (`●` / fake unicode marks) — they had no meaning
- Agent rows use **template brand icons** (Anthropic / OpenAI / Cursor / Gemini / Copilot / Amp / …)
- Tray switched to `MenuBarExtra` **window** style so icons actually render
- Waiting shown as orange “Needs you” badge + status dot on the icon

## 0.6.1 — Agent marks + hooks in Settings

- Tray rows carry **status + per-agent identity glyphs** in title text (`● ✦ Claude…`) so marks always show under MenuBarExtra `.menu` (SF Symbol alone is unreliable there)
- Settings: **Install hooks** seeds `pulse_hook.py` / `install_hooks.py` and runs the installer
- Idle glance stays icon-only

## 0.6.0 — Swift MenuBarExtra shell (scheme B)

Pulse’s menu-bar UI moves off Vercel Native SDK onto a **native SwiftUI `MenuBarExtra`** app (`PulseBar/`).

### Why
- Dynamic SF Symbol glance (idle / running / waiting / error)
- Real menu icons via `Label(..., systemImage:)`
- Proper `.accessory` activation + `LSUIElement` (no Dock)
- Settings as SwiftUI `Settings` scene

### Keep from Zig era
- `src/activity_scan.py` harvest (bundled into the app)
- Attention TSV under `~/Library/Application Support/Pulse/`
- Settings file compatibility (`settings.txt`)
- Surface-agent rules (IDE shells hidden; Cursor via session)

### Fixes
- Process pipe deadlock: drain stdout/stderr before `waitUntilExit` so large `ps` output cannot hang the main thread (empty tray / “No coding agents”)

### Build
```bash
./PulseBar/Scripts/package.sh
open zig-out/package/Pulse.app
```

Legacy Zig + Native SDK UI remains under `src/` for reference; **PulseBar is the product shell**.

## 0.5.0 — Native scan (tray hierarchy + status light)

### Tray
- Agent rows lead with status glyphs (`⏸` waiting / `●` running)
- One indented subline max
- Actions: `↻ Refresh` / Prefs / Quit

### Glance
- Dedicated status-light template (`assets/tray.png`)

### Preferences
- Less nested cards; quieter section labels

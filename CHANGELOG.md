# Changelog

All notable changes to Pulse are documented here.

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

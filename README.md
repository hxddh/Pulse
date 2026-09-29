# Pulse

macOS 菜单栏状态灯：**一眼知道编码 Agent 是空闲、在跑，还是在等你。**

**版本：`23.0.0`** · [下载 DMG](https://github.com/hxddh/Pulse/releases/tag/v23.0.0) · macOS 14+

---

## 它解决什么

开着 Claude Code 写代码，切去开会 / 写文档，回来发现它二十分钟前就停在一个授权提示上。
Pulse 把这件事变成余光可见：

| 灯 | 含义 | 你该做什么 |
| --- | --- | --- |
| 🔴 红 | **需要你** —— 阻塞在授权或提问上 | 点一下：有句柄则按精度落地（标签 / 工作区 / 仅 App），否则打开托盘 |
| 🟢 绿 | 运行中 | 不用管 |
| ⚪️ 灰 | 空闲 / 只有最近会话 | 不用管 |
| 🟠 橙 | 已停滞，或探测能力异常 | 点开查看停滞原因；探测异常时看「关于 → 复制诊断信息」 |

**16.0 起「做完了」不再是红灯**：回合结束、停在提示符上等下一句，是「轮到你」——
托盘头部安静地数「N 轮到你」，行上一个灰色标记，不发通知、不响；你一聚焦或回复它就消失。
红灯只留给阻塞。

点开托盘看到的是**一行一个会话**：灯的形状、Agent、项目、任务、时间。灯不只靠颜色 ——
实心（需要你）、环（运行中）、空心（轮到你、最近）、虚线（只看到进程），菜单栏用同一套形状，
色弱和灰度下也分得开；橙色只给停滞与出错。等待行多一行问题本身，停滞 / 出错多一行橙色原因；
其余动作在键盘、右键菜单与详情页里。
有可靠 Focus 句柄时整行可聚焦（TTY 标签 / 宿主工作区 / Warp 或宿主 App），否则点开是详情页，不制造无效动作。

**键盘优先**：打开托盘直接打字就是过滤（⌫ 只改过滤）；↑↓ 选择，↩ 前往，→ 详情，⌘D 忽略，⌘M 静音，
Esc 先返回 / 清过滤再关面板。头部一行彩色计数加「多久前更新」（过期时变橙），「⋯」里是诊断、设置、
退出；同一时间最多一条提示；面板开着时行的顺序不动。

**每个颜色都说得清来历**：鼠标停在菜单栏图标上，提示用一句话写出决定颜色的规则；
详情页有这个会话最近一小时的时间条（每种状态各几分钟）、Agent 最后说的话、
计划，以及**这条通知发生了什么**（发了、合并、被拒，或没发以及为什么）；诊断窗口的「活动」
按时间倒序列出所有会话的状态变化和通知去向。

**2.1 起说得更具体**：权限通知直接说出被请求的那件事（`Bash: npm run build`，
命令里的凭据仍被抹掉）；行上的事实按信息量排序，**会话记录增长速率**排在 token 前 ——
它是唯一能区分「在干活」与「杵着」的那个；读得不全就明说「仍在追平 · 已读 N%」。

**22.0 起只做灯**：一个状态灯应该看着编排器，而不是成为编排器。指挥台（Workbench）、
受管会话、派活、Mission、工作副本检查、盘上成效、终端代打、跨机器回应与舰队广播都已删除；
设置合成一页，静默与声音交给 macOS 的专注模式和通知设置。

**明确不做**：额度 / 费用 / 重置倒计时、桌面宠物、统计大盘、规则引擎 /
always-allow / 自动批准、对着截断摘要的盲批，以及替你派活、跑检查、打字的编排。
详见 [`EXPERIENCE.md`](EXPERIENCE.md)。

---

## 安装

从 [Releases](https://github.com/hxddh/Pulse/releases) 下载与徽标同版本的 DMG，
拖进「应用程序」。

> **没有 Apple Developer ID 时**：GitHub **Latest** 会跟到当前 semver（避免停在旧包），
> 但 DMG 仍是 ad-hoc / 未公证，About 标 `preview`，**不是** Gatekeeper-ready。首次打开
> 仍需右键「打开」或下面的 `xattr`。有 Developer ID + 公证之后才会变成 `stable` 通道。

> 目前的构建是 ad-hoc 签名，首次打开 macOS 会拦。右键点应用选「打开」，或：
> ```bash
> xattr -dr com.apple.quarantine /Applications/Pulse.app
> ```
> 也可以在「系统设置 → 隐私与安全性」里对 Pulse 点「仍要打开」。不要全局关闭
> Gatekeeper；配置 Developer ID + 公证之后这一步才不需要，见[发布](#发布)。DMG
> 内也附有中英文首次启动说明。

**24.0 起只支持七个主流 Agent**：Claude Code、Codex、Gemini CLI、Copilot CLI、OpenCode、
Cursor（编辑器与 `cursor-agent` 命令行算同一个）和 Pi。每个都走厂商自己文档里的
hook / 插件 / 扩展：设置 → Hooks 一键安装，**只装不能改变 Agent 决定的观察型事件**
（从不装 PreToolUse / beforeShellExecution 这类能拦截的 hook，也从不返回任何决定），
移除时每个文件**逐字节**还原。原生通路，无需 Python。Codex 与 Cursor 的 hook 只报
「运行中」与「轮到你」，不会报告它在等你——Pulse 如实这样写，不伪造 Waiting。

24.0 起状态只来自事件：hook 每报一件事，Pulse 的会话簿（`SessionBook`）就推进一步——
工作中、需要你、轮到你、已结束。不再扫描各 Agent 的会话目录，也不再读取受 macOS 保护的
应用数据，因此不会触发跨应用权限弹窗。进程用 libproc 每 30 秒（以及启动、唤醒时）看一次，
只为找出 Pulse 启动前就在跑、还没报过事件的会话（显示为「检测到进程」），以及知道会话的
进程何时退出。会话文件只在轮到你、需要你或打开详情时读一次（有界、离开主线程、按大小与
修改时间缓存），用来补标题、最后的消息、模型和最后的错误。读不到文件或查不到进程，都不会
让已有的会话消失。Waiting 边沿写入 Pulse 自己的会话记录（`session-log.json`），重启后
仍能去重通知。

按 → 或行菜单「详情」进入详情页，可查看任务、为什么是这个状态、时间条、最后的消息、
通知去向和诊断；诊断窗口（托盘「⋯」→「诊断…」）默认展示全部 7 个 Agent，逐项给出
hook 是否安装、最近一次事件和下一步动作。

设置存为 `settings.json`；24.0 起没有「读取应用数据」开关，旧文件里的这一项会被忽略。

新的 Waiting 会话会逐一发出系统通知（仅在你明确启用通知后），并让状态栏红灯短促脉冲
三次；红灯持续亮起表示仍有待处理确认。通知未启用或被系统关闭时，托盘会显示可点击的
提示，不会在后台反复索要权限。

---

## 它怎么知道

三个来源，**每个只承诺自己能兑现的**：

| 来源 | 手段 | 能回答 |
| --- | --- | --- |
| **事件** | 厂商自己的 hook / 插件 / 扩展 | 在干活、在等你、轮到你、结束了 |
| **进程** | libproc（每 30 秒，及启动 / 唤醒）+ 每个会话进程的退出通知 | 有没有人在跑，会话进程还在不在 |
| **会话文件** | 轮到你 / 需要你 / 打开详情时有界读一次尾部 | 标题、最后的消息、模型、最后的错误 |

**诚实规则**（写死的产品约束，见 [`AGENTS.md`](AGENTS.md)）：

- 进程在 ≠ 会话在干活。没有任务标题的 live 行只显示「检测到进程」，排在有标题的会话之后。
- Waiting 只来自厂商 hook 报告的阻塞事件，**绝不推断**。Codex 与 Cursor 的 hook 不报等待，
  它们明说「不会报告它在等你」，不假装。
- 会话只在它的进程还活着时算「运行中」；不知道进程的会话安静 30 分钟后转为「最近」，
  并在「为什么」里说明。
- Focus 不吹牛：落地精度分 TTY 标签、宿主工作区、`Warp/宿主 (app)`；Terminal/iTerm
  的 TTY 选择默认关闭（Shortcuts opt-in）。没有可验证句柄时，行保持为观测内容，
  不提供 Finder「打开目录」替代动作。深链边界见 [`docs/landing-hosts.md`](docs/landing-hosts.md)。

## 支持的 Agent

| Agent | 进程 | 会话文件 | Waiting |
| --- | --- | --- | --- |
| Claude | libproc | transcript（按需） | hooks（PermissionRequest、Notification 权限 / 提问；全部 `async`） |
| Gemini | libproc | transcript（按需） | hooks（Notification `ToolPermission`） |
| Copilot | libproc | transcript（按需） | hooks（notification `permission_prompt` / `elicitation_dialog`） |
| OpenCode | libproc | 无（用事件自带内容） | plugin（`permission.asked` / `question.asked`） |
| Pi | libproc | transcript（按需） | extension（`ui_prompt_start` / `ui_prompt_end`） |
| Codex | libproc | transcript（按需） | **none**（hooks 只报运行中与轮到你；它的 PermissionRequest 在自己的自动审查之前触发） |
| Cursor | libproc* | transcript（按需） | **none**（hooks 只报运行中与轮到你；没有不拦截的等待事件） |

\* Cursor 编辑器与 `cursor-agent` 命令行按进程认，同属 Cursor；编辑器里的会话以 hook 事件为准。
每个 Agent 装哪些 hook 事件、对应 Pulse 的哪种状态、读的是厂商哪份文档或哪个提交，记在
[`docs/vendor-formats.json`](docs/vendor-formats.json) 与
[`docs/attention-protocol.md`](docs/attention-protocol.md)。

这张表的 Waiting 一列由 `scripts/catalog_check.py` 对着 `AgentCatalog.swift` 校验，
不一致 CI 就红——它是承诺，不是宣传。

「诊断」窗口展示的是这台 Mac 的运行事实，而不是重复静态名单：问题排在最前，
每个 Agent 一行、点开看细节，区分 hook 未安装、已安装但还没收到事件、最近没有会话。
进程命中不会把完整命令行、参数或私有路径带进 UI。

24.0 起名单就是这七个；Attention Protocol（[`docs/attention-bridge.md`](docs/attention-bridge.md)）
只服务于它们自己的 hook 与脚本。

**图标**：七个 Agent 都有现成的品牌图标（[Simple Icons](https://simpleicons.org) 等，
CC0，商标归各自所有者）；没有现成图标的 Agent 由
[`scripts/make_agent_icons.py`](scripts/make_agent_icons.py) 画成几何标记——**那是 Pulse
自己的图形，不是厂商的商标**。
`--check` 是门禁：新增 Agent 若没有图标，CI 就红，不会悄悄退回字母标。

---

## 配置

偏好设置是一页，全部即时生效，从别处跳进来会滚到对应的那一节：

- **通用** —— 登录时启动、语言（跟随系统 / English / 中文）
- **快捷键** —— 唤出面板（关闭 / ⌘⇧P / ⌘⇧U / ⌘⌥P / ⌃⌥P）
- **通知** —— 授权状态、「Agent 需要我时通知」、静音的 Agent（每个带 ✕）；声音与安静时段交给
  macOS 的通知设置与专注模式，静音某个 Agent 在行菜单里（或按 M）
- **Hooks** —— 七个 Agent 各自的官方 hook / 插件 / 扩展（安装 / 移除 / 测试）；每个 Agent
  一行：已安装、未安装或这台 Mac 上没有，以及「最近事件 12 秒前」；Codex 与 Cursor
  注明「不会报告它在等你」
- **终端控制** —— 终端自动化（Terminal / iTerm 的 TTY 选择），默认关闭并写明后果
- **更新** —— 检查更新（有新版本时打开发布页，在浏览器里下载）
- 页脚：版本与构建、「诊断…」入口

「诊断」窗口把问题、自检、每个 Agent 的 hook 与最近事件、活动记录（独立标签）
和一个「复制报告」放在一起。

省电是硬约束：没有固定的探测间隔。事件文件一变就处理；此外只有一个便宜的时钟
（托盘打开或刚出现等待时 5s，否则 60s，没有会话时停表）和每 30 秒一次的进程查看，
低电量模式加倍，**息屏或锁屏直接停表**。

---

## 开发

```bash
cd PulseBar && swift run     # 开发壳，关于区显示 x.y.z-dev
cd PulseBar && swift test    # 测试数量以 SwiftPM / CI 当次输出为准
```

源码门禁只有一个入口，从仓库根目录跑（`package.sh`、`release.sh` 和 CI 都调用它）：

```bash
bash scripts/gates.sh                       # 版本、Agent 目录、图标、外观、表面、场景
python3 scripts/package_check.py            # 打出来的 .app 能找到自己的资源
```

`gates.sh` 只读源码，`package_check.py` 读**构建产物** —— 0.21 到 0.23.0 的启动崩溃全部发生在打包这一步，
源码没问题、测试全绿，照样连发三个打不开的 DMG。这类 bug 只有对着 `.app` 才看得见。

但门禁校验的是「我们以为运行时去哪找资源」，而那个假设本身就是当初错的地方。
所以还要让 app 自己回答：

```bash
zig-out/package/Pulse.app/Contents/MacOS/PulseBar --selftest
```

用真实二进制、在真实 `.app` 里跑一遍资源解析，逐项报告。在 AppKit 初始化之前返回，
无头环境也能跑。`package.sh` 打完包会自动执行。

打包：

```bash
./PulseBar/Scripts/package.sh        # 结尾自动跑 package_check + --selftest
open zig-out/package/Pulse.app
```

架构见 [`docs/architecture.md`](docs/architecture.md)。

## 发布

先在 `CHANGELOG.md` 写好 `## x.y.z` 段落 —— 没有它所有路径都会拒绝。

```bash
./scripts/release.sh 0.23.0            # 预演：改版本、跑门禁、给出 diff
./scripts/release.sh 0.23.0 --commit   # 提交（标题带 [release] 标记）
git push                               # CI 构建、打 tag、发布
```

**tag 由 CI 用自己的 `contents: write` token 创建**，发布不依赖任何人的本地推送权限。
已发布过的版本会被拒绝重复发布，重推是安全的。

发布通道三态：`preview`（ad-hoc）→ `signed`（Developer ID 未公证）→ `stable`（公证成功）。
仓库配置齐 `PULSE_CERTIFICATE_P12`（base64）、`PULSE_CERTIFICATE_PASSWORD`、
`PULSE_SIGN_IDENTITY`、`PULSE_NOTARY_KEY_P8`（base64）、
`PULSE_NOTARY_KEY_ID` 和 `PULSE_NOTARY_ISSUER_ID` 时，CI 导入临时 keychain，
公证并 staple App 与 DMG，再以 `spctl` 验收，并在 Info.plist 写入 `stable`。
**任一凭据缺失时仍发布 GitHub Latest**（跟当前 semver），产物为 ad-hoc / 未公证，
About 保持 `preview` —— **绝不能自称 stable / Gatekeeper-ready**。详见
[`CHANGELOG.md`](CHANGELOG.md) 的 0.97.0 说明。

> 应用内的「检查更新」读的就是这些 Release，走匿名请求 —— 仓库是 public，所以直接可用。
> 若 fork 成私有仓库，需用 `Info.plist` 的 `PulseUpdateFeed` 指向一个可匿名访问的 feed，
> 否则 GitHub 会返回 404。

---

## 贡献

欢迎 issue 和 PR。动手前请先读 [`AGENTS.md`](AGENTS.md) 里的**不变量**——
那几条是产品决策（不假装 Waiting、不做配额 HUD、不在托盘里批准），
不是可以顺手改掉的偏好。

改动请保证 `swift test` 与八个门禁通过；CI 会替你再跑一遍。

## 许可

[MIT](LICENSE)。

## 文档

| 文件 | 内容 |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | 接手须知：不变量、门禁、发布流程 |
| [`EXPERIENCE.md`](EXPERIENCE.md) | 体验规格 —— UI 改动的验收依据 |
| [`docs/architecture.md`](docs/architecture.md) | 数据从进程到菜单栏的完整路径 |
| [`docs/attention-bridge.md`](docs/attention-bridge.md) | 用 `pulse-hook` / 追加一行上报状态 |
| [`docs/attention-protocol.md`](docs/attention-protocol.md) | Attention Protocol v4 契约与各 Agent 事件映射 |
| [`CHANGELOG.md`](CHANGELOG.md) | 每个版本改了什么 |

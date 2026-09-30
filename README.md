# Pulse

macOS 菜单栏状态灯：**一眼知道编码 Agent 是空闲、在跑，还是在等你。**

**版本：`24.0.0`** · [下载 DMG](https://github.com/hxddh/Pulse/releases/tag/v24.0.0) · macOS 14+

---

## 它解决什么

开着 Claude Code 写代码，切去开会 / 写文档，回来发现它二十分钟前就停在一个授权提示上。
Pulse 把这件事变成余光可见：

| 灯 | 含义 | 你该做什么 |
| --- | --- | --- |
| 🔴 红 | **需要你** —— 阻塞在授权或提问上 | 点一下：能落到确切的终端就落过去，否则打开托盘里这一行的详情 |
| 🟢 绿 | 运行中 | 不用管 |
| ⚪️ 灰 | 空闲、轮到你、只有最近会话，或只看到进程 | 不用管 |
| 🟠 橙 | 已停滞 —— 报告过自己在干活的会话久无新事件 | 点开看停在哪里 |

**「做完了」不是红灯**：回合结束、停在提示符上等下一句，是「轮到你」——
托盘头部安静地数「N 轮到你」，行上一个灰色标记，不发通知、不响；你一聚焦或回复它就消失。
红灯只留给阻塞。新出现的等待让菜单栏的灯**闪一次**，之后常亮，不呼吸。

点开托盘看到的是**一行一个会话**：灯的形状、Agent、项目、任务、时间。灯不只靠颜色 ——
实心（需要你）、环（运行中）、空心（轮到你、最近）、虚线（只看到进程），菜单栏用同一套形状，
色弱和灰度下也分得开；**橙色只给停滞**。等待行多一行问题本身，停滞行多一行橙色原因；
其余动作在键盘、右键菜单与详情页里。行上不列 token、费用或上下文占用。

**键盘优先**：↑↓ 选择，↩ 前往（没有终端可落就开详情），→ / 空格 详情，← / Esc 返回，
在列表上 Esc 关面板；⌘D 忽略所选等待，⌘M 静音所选 Agent，⌘R 刷新，⌘, 设置。
头部一行彩色计数，「⋯」里是设置与退出；同一时间最多一条提示；面板开着时行的顺序不动。

**每个颜色都说得清来历**：鼠标停在菜单栏图标上，提示用一句话写出决定颜色的规则；
详情页写出这一行为什么是这个状态、从什么时候起，Agent 最后说的话与最后的错误。

权限通知直接说出被请求的那件事（`Bash: npm run build`，命令里的凭据仍被抹掉）。

**只做灯**：一个状态灯应该看着编排器，而不是成为编排器 —— 不派活、不管会话、不跑检查、
不替你在终端里打字，也不在托盘里回答授权。静默与声音交给 macOS 的专注模式和通知设置。

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

**只支持七个主流 Agent**：Claude Code、Codex、Gemini CLI、Copilot CLI、OpenCode、
Cursor（编辑器与 `cursor-agent` 命令行算同一个）和 Pi。每个都走厂商自己文档里的
hook / 插件 / 扩展：设置 → Hooks 一键安装，**只装不能改变 Agent 决定的观察型事件**
（从不装 PreToolUse / beforeShellExecution 这类能拦截的 hook，也从不返回任何决定），
移除时每个文件**逐字节**还原。原生通路，无需 Python。Codex 与 Cursor 的 hook 只报
「运行中」与「轮到你」，不会报告它在等你——Pulse 如实这样写，不伪造 Waiting。

状态只来自事件：hook 每报一件事，Pulse 的会话簿（`SessionBook`）就推进一步——
工作中、需要你、轮到你、已结束。不扫描各 Agent 的会话目录，也不读取受 macOS 保护的
应用数据，因此不会触发跨应用权限弹窗。进程用 libproc 查看：启动、唤醒、hook 报出一个
没见过的进程时各看一次，此外从 30 秒起、进程没变化就逐次加倍、最长 5 分钟看一次，
只为找出 Pulse 启动前就在跑、还没报过事件的会话（显示为「检测到进程」），以及知道会话的
进程何时退出（退出本身由系统即时通知）。会话文件只在轮到你、需要你或打开详情时读一次
（有界、离开主线程、按大小与修改时间缓存），用来补标题、最后的消息、模型和最后的错误。
读不到文件或查不到进程，都不会让已有的会话消失。

Pulse 自己不存会话记录：跨重启留下的只有 hook 写的文件与你的 `settings.json`。
通知记账只在内存里；启动时已经在等的会话不补发通知。

按 → 或行菜单「详情」进入详情页，可查看任务、为什么是这个状态、最后的消息与最后的错误，
以及折叠起来的「Pulse 如何读取这个会话」。

新的 Waiting 会话会逐一发出系统通知（仅在你明确启用通知后）；多个同时到达合成一条。
通知未启用或被系统关闭时，托盘会显示可点击的提示，不会在后台反复索要权限。

---

## 它怎么知道

三个来源，**每个只承诺自己能兑现的**：

| 来源 | 手段 | 能回答 |
| --- | --- | --- |
| **事件** | 厂商自己的 hook / 插件 / 扩展 | 在干活、在等你、轮到你、结束了 |
| **进程** | libproc（启动 / 唤醒 / 未知进程时，及 30 秒起退避到 5 分钟）+ 每个会话进程的退出通知 | 有没有人在跑，会话进程还在不在 |
| **会话文件** | 轮到你 / 需要你 / 打开详情时有界读一次尾部 | 标题、最后的消息、模型、最后的错误 |

**诚实规则**（写死的产品约束，见 [`AGENTS.md`](AGENTS.md)）：

- 进程在 ≠ 会话在干活。没有任务标题的 live 行只显示「检测到进程」，排在有标题的会话之后。
- Waiting 只来自厂商 hook 报告的阻塞事件，**绝不推断**。Codex 与 Cursor 的 hook 不报等待，
  它们明说「不会报告它在等你」，不假装。
- 会话只在它的进程还活着时算「运行中」；不知道进程的会话安静 30 分钟后转为「最近」，
  并在「为什么」里说明。
- Focus 不吹牛：tmux 窗格不需要任何权限就能确切落地；iTerm2 会话与 Terminal.app 标签按
  会话 id / tty 选中，但要用 AppleScript，默认关闭（`settings.json` 里的 `allowTerminalAutomation`，
  首次使用时 macOS 会询问自动化权限）；Ghostty、WezTerm、kitty、Warp 只把 App 带到前台，编辑器
  打开会话目录。按钮只在能确切落地时写「前往终端」，否则写「打开应用」；没落到就明说。
  深链边界见 [`docs/landing-hosts.md`](docs/landing-hosts.md)。

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

设置 → Hooks 就是诊断：这台 Mac 上的每个 Agent 一行，写出 hook 装没装（装失败就写原因）、
最近一次事件是多久前，缺的给一个安装按钮；不在这台 Mac 上的 Agent 合成一行。
进程命中不会把完整命令行、参数或私有路径带进 UI。

名单就是这七个；Attention Protocol（[`docs/attention-bridge.md`](docs/attention-bridge.md)）
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
  macOS 的通知设置与专注模式，静音某个 Agent 在行菜单里（或按 ⌘M）
- **Hooks** —— 七个 Agent 各自的官方 hook / 插件 / 扩展（安装 / 移除）；这台 Mac 上的每个
  Agent 一行：已安装、未安装或安装失败，以及「最近事件 12 秒前」；Codex 与 Cursor 注明
  「不会报告它在等你」；不在这台 Mac 上的合成一行；「复制报告」给出一份纯文本（版本、每个
  Agent 的 hook 与最近事件、通知授权、终端自动化、登录项），不含路径、提示词或会话
- **更新** —— 检查更新（有新版本时打开发布页，在浏览器里下载）
- 页脚：版本与构建

省电是硬约束：没有固定的探测间隔。事件文件一变就处理；此外只有一个便宜的时钟
（托盘打开或刚出现等待时 5s，否则 60s，没有会话时停表）和按需退避的进程查看（30 秒起，
最长 5 分钟），低电量模式加倍，**息屏或锁屏直接停表**。

---

## 开发

```bash
cd PulseBar && swift run PulseBar   # 开发壳，关于区显示 x.y.z-dev
cd PulseBar && swift test           # 测试数量以 SwiftPM / CI 当次输出为准
./scripts/qa_surfaces.sh            # 构建并运行 PulseQA，把每个表面夹具渲染成 PNG
```

截图、夹具与预览窗口都在单独的 `PulseQA` 可执行文件里，出厂的 Pulse.app 只含 `PulseBar`。

源码门禁只有一个入口，从仓库根目录跑（`package.sh`、`release.sh` 和 CI 都调用它）：

```bash
bash scripts/gates.sh                       # 版本、Agent 目录、图标、外观、表面、场景
python3 scripts/package_check.py            # 打出来的 .app 能找到自己的资源
```

`gates.sh` 只读源码，`package_check.py` 读**构建产物**（资源包、以及二进制里没有 QA 代码）——
打包这一步出的错，源码与测试都看不见，只有对着 `.app` 才看得见。

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
./scripts/release.sh X.Y.Z            # 预演：改版本、跑门禁、给出 diff
./scripts/release.sh X.Y.Z --commit   # 提交（标题带 [release] 标记）
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
About 保持 `preview` —— **绝不能自称 stable / Gatekeeper-ready**。

> 应用内的「检查更新」读的就是这些 Release，走匿名请求 —— 仓库是 public，所以直接可用。
> 若 fork 成私有仓库，需用 `Info.plist` 的 `PulseUpdateFeed` 指向一个可匿名访问的 feed，
> 否则 GitHub 会返回 404。

---

## 贡献

欢迎 issue 和 PR。动手前请先读 [`AGENTS.md`](AGENTS.md) 里的**不变量**——
那几条是产品决策（不假装 Waiting、不做配额 HUD、不在托盘里批准），
不是可以顺手改掉的偏好。

改动请保证 `swift test` 与 `bash scripts/gates.sh` 通过；CI 会替你再跑一遍。

## 许可

[MIT](LICENSE)。

## 文档

| 文件 | 内容 |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | 接手须知：不变量、门禁、发布流程 |
| [`EXPERIENCE.md`](EXPERIENCE.md) | 体验规格 —— UI 改动的验收依据 |
| [`docs/architecture.md`](docs/architecture.md) | 数据从进程到菜单栏的完整路径 |
| [`docs/attention-bridge.md`](docs/attention-bridge.md) | 用 `pulse-hook` / 追加一行上报状态 |
| [`docs/attention-protocol.md`](docs/attention-protocol.md) | Attention Protocol v5（事件日志 `events.tsv`）契约与各 Agent 事件映射 |
| [`CHANGELOG.md`](CHANGELOG.md) | 每个版本改了什么 |

# Pulse

macOS 菜单栏状态灯：**一眼知道编码 Agent 是空闲、在跑，还是在等你。**

**版本：`2.9.0`** · [下载 DMG](https://github.com/hxddh/Pulse/releases/tag/v2.9.0) · macOS 14+

---

## 它解决什么

开着 Claude Code 写代码，切去开会 / 写文档，回来发现它二十分钟前就停在一个授权提示上。
Pulse 把这件事变成余光可见：

| 灯 | 含义 | 你该做什么 |
| --- | --- | --- |
| 🔴 红 | **需要你** —— 在等授权或输入 | 点一下：有句柄则按精度落地（标签 / 工作区 / 仅 App），否则打开托盘 |
| 🟢 绿 | 运行中 | 不用管 |
| ⚪️ 灰 | 空闲 / 只有最近会话 | 不用管 |
| 🟠 橙 | 已停滞，或探测能力异常 | 点开查看停滞原因；探测异常时看「关于 → 复制诊断信息」 |

点开托盘看到的是**可解释的观测**：每行明确标出结构化会话、本地缓存或仅进程；
有可靠 Focus 句柄时整行可聚焦（TTY 标签 / 宿主工作区 / Warp 或宿主 App），否则保持为信息，不制造无效动作。

**2.1 起说得更具体**：权限通知直接说出被请求的那件事（`Bash: npm run build`，
命令里的凭据仍被抹掉）；行上的事实按信息量排序，**会话记录增长速率**排在 token 前 ——
它是唯一能区分「在干活」与「杵着」的那个；Details 给整场会话的证据（动作时间线、
整场 token、会话时长、读取完整度），读得不全就明说「仍在追平 · 已读 N%」。

**2.0 起可以回应**：远端机器（devbox）的权限请求同步到本机后，托盘行上可
「拒绝」，Details 的完整请求旁可「同意」—— 判决 HMAC 逐 host 密钥签名、单次
使用、绑定请求原文摘要，经你自己的同步工具送回；**没有密钥文件时这一切不存在**。
详见 [`docs/respond-protocol.md`](docs/respond-protocol.md)。

**明确不做**：额度 / 费用 / 重置倒计时、桌面宠物、统计大盘、规则引擎 /
always-allow / 自动批准，以及对着截断摘要的盲批。
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

装好后可直接使用，不需要安装 hooks。Pulse 默认读取本地会话与进程证据；Claude/Codex
的 hooks 只是额外增强权限/输入等待和 subagent 生命周期的 Waiting 信号，按需在设置里
启用即可（**原生通路，无需 Python**）。没有 hooks 时，能从会话数据确认的 `pending`
仍会点亮红灯；无法确认的路径
会诚实标为仅运行中，不伪造 Waiting。

0.49.0 起采集器使用 Swift 原生 bounded reader 直接生成会话和健康事实；每个 adapter 都会报告
observed、no_sessions、source_absent、permission_denied、schema_mismatch 或 failed，
不会再把“没有看到”混成“没有运行”。0.99 起没有第二个采集器：旧版 Python collector 已删除。Waiting 边沿写入 Pulse 自己的原子事件账本，重启后
仍能去重通知、恢复稍后处理和最近等待历史。首次扫描失败不会播种基线，也不会清空上一
次有效内容。

需要读取受 macOS 保护的 App Support / App Group 时，设置页可以按 Agent 单独授权；默认不
访问这些目录、不制造跨应用权限弹窗。通过行的更多操作打开“详情”可查看任务、工作区、最近动作、模型、
进度、资源、证据来源和原始 tool/skill（原始实现标识默认收起）；支持健康度窗口默认展示
全部 32 个用户可见 Agent，逐项给出证据、缺口和下一步动作。

升级到 0.49.0 不会继承旧版的全局 App Data 授权；需要时请在设置中对具体 Agent 重新选择，
这样不会因 ad-hoc 签名变化在后台反复触发 macOS 权限弹窗。

新的 Waiting 会话会逐一发出系统通知（仅在你明确启用通知后），并让状态栏红灯短促脉冲
三次；红灯持续亮起表示仍有待处理确认。通知未启用或被系统关闭时，托盘会显示可点击的
提示，不会在后台反复索要权限。

---

## 它怎么知道

三层，能力递增，**每层只承诺自己能兑现的**：

| 层 | 手段 | 能回答 |
| --- | --- | --- |
| **A · Probe** | `ps` 扫进程 | 有没有人在跑 |
| **B · Harvest** | Swift 原生读取各 Agent 会话文件 / 可验证缓存（受限目录按 Agent 授权） | 有结构化数据时回答任务、项目、会话与最近活动 |
| **C · Waiting** | hooks，或 harvest 里的 `pending` 标记 | 是不是在等你 |

**诚实规则**（写死的产品约束，见 [`AGENTS.md`](AGENTS.md)）：

- 进程在 ≠ 会话在干活。没有任务标题的 live 行只显示「检测到进程」，排在有标题的会话之后。
- Waiting 只来自 hooks 或 `skill=pending`，**绝不推断**。没有 Waiting 通路的 Agent，
  托盘明说「暂无 Waiting 信号」，不假装。
- 每条 Waiting 行标注来源是 `hooks` 还是 `pending`，你自己判断可信度。
- Focus 不吹牛：落地精度分 TTY 标签、宿主工作区、`Warp/宿主 (app)`；Terminal/iTerm
  的 TTY 选择默认关闭（Shortcuts opt-in）。没有可验证句柄时，行保持为观测内容，
  不提供 Finder「打开目录」替代动作。深链边界见 [`docs/landing-hosts.md`](docs/landing-hosts.md)。

## 支持的 Agent

| Agent | Probe | Harvest | Waiting |
| --- | --- | --- | --- |
| Claude / Codex | A | Structured session | hooks（+ Codex pending） |
| Cursor / Grok / Pi / Amp / Aider / Gemini / Copilot / OpenCode / Goose / OpenHands / Continue / Droid / Command Code / Kimi | A* | Structured session | pending |
| Amazon Q / Cline / Roo / Cascade / Windsurf / Augment / Zed / Kilo / Kiro | A | Best effort cache | pending（尽力） |
| Trae / Warp / Antigravity / Devin / Junie / Replit / ZCode | A | Best effort cache | **none**（本机无可靠信号） |

\* Cursor 进程常跳过外壳，靠 harvest 认；其余 Agent 的 Probe 仍为 A。
`Structured session` 读取真实 transcript / thread / composer / session database；
`Best effort cache` 只承诺缓存中确实存在的标题、工作区和更新时间。缓存里只有扩展名、
文件名或 `Agent session` 这类占位词时，Pulse 会直接丢弃该条，不再把“找到一个文件”
伪装成会话观测。VS Code 系扩展的 session 常被包在多层 state/container 中，Pulse 会
有界遍历这些结构，只接受同时带会话上下文、标识或绝对工作区的事实；不会把 profile、
model、theme 的 `name/title` 当成任务。两者若没有当前数据都会明确降级；CLI 进程还能
补充其真实工作目录与进程时长，但不会用进程数冒充会话信息。

Harvest 不再只是一条标题：统一行协议还能承载阶段、结果、模型/模式、进度、失败数、
涉及文件和上下文占用。各 Agent 的本地格式能提供什么、缺什么，逐项记录在
[`docs/observability-matrix.md`](docs/observability-matrix.md)。默认界面不会直接展示
`exec`、`run_terminal_command` 或内部 skill/script 名；这类实现细节只有在能可靠转换为
「正在规划 / 编辑 / 响应 / 等待权限 / 本轮完成」等用户可理解的阶段时才有可观测价值。
未知 skill 不会原样泄露 namespace 或路径；无法映射时只保留安全的叶子名称，以
`Workflow <name>` 进入默认行，避免丢失有价值的能力信号。

这张表由 `scripts/matrix_check.py` 对着代码里的 `AgentID.harvestSource` 和
`AgentID.waitingSource` 校验，
不一致 CI 就红——它是承诺，不是宣传。

独立的「Agent 支持健康度」窗口展示的是这台 Mac 的运行事实，而不是重复静态名单：
可按问题、运行中、已安装、无数据筛选，并区分未发现数据源、数据源存在但没有可用会话、
读取权限不足、供应商格式变化、采集失败和超时未完成。进程命中只展示隐私安全的规则类型，
不会把完整命令行、参数或私有路径带进 UI。

想让名单外的工具点亮 Waiting，走 [`docs/attention-bridge.md`](docs/attention-bridge.md)。

**图标**：23 个来自 [Simple Icons](https://simpleicons.org)（CC0，商标归各自所有者）；
其余 10 个没有现成品牌图标，由 [`scripts/make_agent_icons.py`](scripts/make_agent_icons.py)
画成几何标记——**那是 Pulse 自己的图形，不是厂商的商标**。
`--check` 是门禁：新增 Agent 若没有图标，CI 就红，不会悄悄退回字母标。

---

## 配置

偏好设置分区，全部即时生效：

- **通用** —— 实时更新、登录时启动、语言（跟随系统 / English / 中文）、分组方式、停滞判定阈值、稍后时长；
  受保护 App 数据可全局授权，也可只授权选中的 Agent
- **通知** —— 空闲通知、新 Waiting 通知、安静时段（精确到分钟、可跨午夜）、按 Agent 静音
- **等待信号** —— 安装 / 移除 hooks、当前状态，以及不会制造假 Waiting 的连接自检
- **快捷键** —— 唤出面板的组合键（⌘⇧P / ⌘⇧U / ⌘⌥P / ⌃⌥P / 关闭）
- **最近的等待** —— 已结束的等待记录，回答「我是不是错过了什么」
- **关于** —— 版本、构建指纹、实际运行路径、重复安装、可校验更新、复制诊断信息

省电是硬约束：探测节奏跟着状态走（等待 2s / 运行 5s / 最近 15s / 空 30s），
托盘打开时提速，低电量模式减半，**息屏或锁屏直接停表**。

---

## 开发

```bash
cd PulseBar && swift run     # 开发壳，关于区显示 x.y.z-dev
cd PulseBar && swift test    # 测试数量以 SwiftPM / CI 当次输出为准
```

八个门禁，从仓库根目录跑（`package.sh` 和 CI 都会执行）：

```bash
python3 scripts/version_check.py            # 版本一致性（--fix 自动对齐）
python3 scripts/coverage_check.py           # 每个 AgentID 都有 harvest 接线
python3 scripts/matrix_check.py             # README 支持矩阵 == 代码
python3 scripts/make_agent_icons.py --check # 每个 AgentID 都有图标，且与生成器一致
python3 scripts/appearance_check.py         # 没有把外观冻进常量（0.27.1 因此丢了深色模式）
python3 scripts/resource_budget_check.py    # native fixture 墙钟 + RSS
python3 scripts/package_check.py            # 打出来的 .app 能找到自己的资源
```

前七个读源码或跑 native fixture，最后一个读**构建产物** —— 0.21 到 0.23.0 的启动崩溃全部发生在打包这一步，
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
| [`docs/attention-bridge.md`](docs/attention-bridge.md) | 让名单外的工具上报 Waiting |
| [`docs/attention-protocol.md`](docs/attention-protocol.md) | Attention Protocol v1 契约 |
| [`CHANGELOG.md`](CHANGELOG.md) | 每个版本改了什么 |
| [`docs/plan-0.91.md`](docs/plan-0.91.md) | 0.91 计划 —— 行叙事 |
| [`docs/plan-0.90.md`](docs/plan-0.90.md) | 0.90 计划 —— 等待可达 |
| [`docs/plan-0.82.md`](docs/plan-0.82.md) | 0.82 计划 —— 舰队托盘实质 |
| [`docs/plan-0.81.md`](docs/plan-0.81.md) | 0.81 计划 —— 托盘实质 |
| [`docs/plan-0.80.md`](docs/plan-0.80.md) | 0.80 计划 —— 托盘可读 |
| [`docs/plan-0.70.md`](docs/plan-0.70.md) | 0.70 计划 —— 契约诚实 |
| [`docs/plan-0.65.md`](docs/plan-0.65.md) | 0.65 计划 —— 舰队覆盖 / ZCode |
| [`docs/plan-0.64.md`](docs/plan-0.64.md) | 0.64 计划 —— 打断闭环 |
| [`docs/plan-0.63.md`](docs/plan-0.63.md) | 0.63 计划 —— 绿灯可信 |
| [`docs/plan-0.62.md`](docs/plan-0.62.md) | 0.62 计划 —— 开放 Attention 协议 |
| [`docs/plan-0.61.md`](docs/plan-0.61.md) | 0.61 计划 —— 原生等待通路 |
| [`docs/plan-0.60.md`](docs/plan-0.60.md) | 0.60 计划 —— 等待连续 |
| [`docs/plan-0.59.md`](docs/plan-0.59.md) | 0.59 计划 —— 缓存连续 |
| [`docs/plan-0.58.md`](docs/plan-0.58.md) | 0.58 计划 —— 舰队连续 |
| [`docs/plan-0.57.md`](docs/plan-0.57.md) | 0.57 计划 —— 事实连续 |
| [`docs/plan-0.56.md`](docs/plan-0.56.md) | 0.56 计划 —— 精确落地 |
| [`docs/plan-0.55.md`](docs/plan-0.55.md) | 0.55 计划 —— 回到现场 |
| [`docs/plan-0.54.md`](docs/plan-0.54.md) | 0.54 计划 —— 通道与契约连续 |
| [`docs/plan-0.53.md`](docs/plan-0.53.md) | 0.53 计划 —— 交付连续信任 |
| [`docs/plan-0.23.md`](docs/plan-0.23.md) | 0.23 的计划与验收（P2 两项仍开着） |
| [`docs/plan-0.24.md`](docs/plan-0.24.md) | 0.24 计划 —— 辨识度与精致感 |
| [`docs/plan-0.25.md`](docs/plan-0.25.md) | 0.25 计划与实施记录 —— 每行只说一次 |
| [`docs/plan-0.27.md`](docs/plan-0.27.md) | 0.27 计划 —— 读完面板之后你能做什么 |
| [`docs/review-0.21.md`](docs/review-0.21.md) | 0.21 全量审计记录（已全部关闭） |

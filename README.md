# Pulse

macOS 菜单栏状态灯：**一眼知道编码 Agent 是空闲、在跑，还是在等你。**

**版本：`0.31.0`** · [下载 DMG](https://github.com/hxddh/Pulse/releases/latest) · macOS 14+

---

## 它解决什么

开着 Claude Code 写代码，切去开会 / 写文档，回来发现它二十分钟前就停在一个授权提示上。
Pulse 把这件事变成余光可见：

| 灯 | 含义 | 你该做什么 |
| --- | --- | --- |
| 🔴 红（呼吸） | **需要你** —— 在等授权或输入 | 点一下，直接跳到那个终端页 |
| 🟢 绿 | 运行中 | 不用管 |
| ⚪️ 灰 | 空闲 / 只有最近会话 | 不用管 |
| 🟠 橙 | 探测不可用 | 看「关于 → 复制诊断信息」 |

点开托盘看到的是**会话**，不是进程：行标题是任务名，Agent 名退到次行。
整行点击 = 聚焦到对应的终端页。

**明确不做**：额度 / 费用 / 重置倒计时、桌面宠物、统计大盘、托盘内批准或拒绝。
详见 [`EXPERIENCE.md`](EXPERIENCE.md)。

---

## 安装

从 [Releases](https://github.com/hxddh/Pulse/releases/latest) 下载 DMG，拖进「应用程序」。

> 目前的构建是 ad-hoc 签名，首次打开 macOS 会拦。右键点应用选「打开」，或：
> ```bash
> xattr -dr com.apple.quarantine /Applications/Pulse.app
> ```
> 配置了 Developer ID 之后这一步就不需要了，见[发布](#发布)。

装好后打开 **偏好设置 → 等待信号 → 安装连接**。
这一步把 hook 写进 Claude Code 与 Codex 的配置，Pulse 才能点亮「需要你」——
不装也能用，只是红灯永远不会亮。

---

## 它怎么知道

三层，能力递增，**每层只承诺自己能兑现的**：

| 层 | 手段 | 能回答 |
| --- | --- | --- |
| **A · Probe** | `ps` 扫进程 | 有没有人在跑 |
| **B · Harvest** | 读各 Agent 自己的会话文件 / sqlite / 可验证缓存 | 有结构化数据时回答任务、项目、会话与最近活动 |
| **C · Waiting** | hooks，或 harvest 里的 `pending` 标记 | 是不是在等你 |

**诚实规则**（写死的产品约束，见 [`AGENTS.md`](AGENTS.md)）：

- 进程在 ≠ 会话在干活。没有任务标题的 live 行只显示「检测到进程」，排在有标题的会话之后。
- Waiting 只来自 hooks 或 `skill=pending`，**绝不推断**。没有 Waiting 通路的 Agent，
  托盘明说「暂无 Waiting 信号」，不假装。
- 每条 Waiting 行标注来源是 `hooks` 还是 `pending`，你自己判断可信度。
- Focus 不吹牛：Warp 下可直接激活 Warp；Terminal/iTerm 的 TTY 选择需要系统自动化权限，
  Pulse 不会隐式索取，因此只提供可靠的「打开目录」。

## 支持的 Agent

| Agent | Probe | Harvest | Waiting |
| --- | --- | --- | --- |
| Claude / Codex | A | Structured session | hooks（+ Codex pending） |
| Cursor / Grok / Pi / Amp / Aider / Gemini / Copilot / OpenCode / Goose / OpenHands / Continue / Droid / Command Code / Kimi | A* | Structured session | pending |
| Amazon Q / Cline / Roo / Cascade / Windsurf / Augment / Zed / Kilo / Kiro | A | Best effort cache | pending（尽力） |
| Trae / Warp / Antigravity / Devin / Junie / Replit | A | Best effort cache | **none**（本机无可靠信号） |

\* Cursor 进程常跳过外壳，靠 harvest 认；其余 Agent 的 Probe 仍为 A。
`Structured session` 读取真实 transcript / thread / composer / session database；
`Best effort cache` 只承诺缓存中确实存在的标题、工作区和更新时间。缓存里只有扩展名、
文件名或 `Agent session` 这类占位词时，Pulse 会直接丢弃该条，不再把“找到一个文件”
伪装成会话观测。两者若没有当前数据都会明确降级，不会用进程数冒充会话信息。

这张表由 `scripts/matrix_check.py` 对着代码里的 `AgentID.harvestSource` 和
`AgentID.waitingSource` 校验，
不一致 CI 就红——它是承诺，不是宣传。

想让名单外的工具点亮 Waiting，走 [`docs/attention-bridge.md`](docs/attention-bridge.md)。

**图标**：22 个来自 [Simple Icons](https://simpleicons.org)（CC0，商标归各自所有者）；
其余 10 个没有现成品牌图标，由 [`scripts/make_agent_icons.py`](scripts/make_agent_icons.py)
画成几何标记——**那是 Pulse 自己的图形，不是厂商的商标**。
`--check` 是门禁：新增 Agent 若没有图标，CI 就红，不会悄悄退回字母标。

---

## 配置

偏好设置分区，全部即时生效：

- **通用** —— 实时更新、登录时启动、语言（跟随系统 / English / 中文）、分组方式、停滞判定阈值、稍后时长
- **通知** —— 空闲通知、新 Waiting 通知、安静时段（精确到分钟、可跨午夜）、按 Agent 静音
- **等待信号** —— 安装 / 移除 hooks，以及当前状态
- **快捷键** —— 唤出面板的组合键（⌘⇧P / ⌘⇧U / ⌘⌥P / ⌃⌥P / 关闭）
- **最近的等待** —— 已结束的等待记录，回答「我是不是错过了什么」
- **关于** —— 版本、构建指纹、检查更新、复制诊断信息

省电是硬约束：探测节奏跟着状态走（等待 2s / 运行 5s / 最近 15s / 空 30s），
托盘打开时提速，低电量模式减半，**息屏或锁屏直接停表**。

---

## 开发

```bash
cd PulseBar && swift run     # 开发壳，关于区显示 x.y.z-dev
cd PulseBar && swift test    # 217 个单元测试
```

七个门禁，从仓库根目录跑（`package.sh` 和 CI 都会执行）：

```bash
python3 scripts/version_check.py            # 版本一致性（--fix 自动对齐）
python3 scripts/coverage_check.py           # 每个 AgentID 都有 harvest 接线
python3 scripts/matrix_check.py             # README 支持矩阵 == 代码
python3 scripts/make_agent_icons.py --check # 每个 AgentID 都有图标，且与生成器一致
python3 scripts/appearance_check.py         # 没有把外观冻进常量（0.27.1 因此丢了深色模式）
python3 scripts/harvest_stats_check.py      # harvest 真的产出会变化的事实，且不猜工具名
python3 scripts/package_check.py            # 打出来的 .app 能找到自己的资源
```

前六个读源码，最后一个读**构建产物** —— 0.21 到 0.23.0 的启动崩溃全部发生在打包这一步，
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

要产出别人能直接打开的包，设仓库 secret `PULSE_SIGN_IDENTITY`
（可选 `PULSE_NOTARY_PROFILE` 触发公证）。未设置时 Release 说明会自动附上绕过提示。

> 应用内的「检查更新」读的就是这些 Release，走匿名请求 —— 仓库是 public，所以直接可用。
> 若 fork 成私有仓库，需用 `Info.plist` 的 `PulseUpdateFeed` 指向一个可匿名访问的 feed，
> 否则 GitHub 会返回 404。

---

## 贡献

欢迎 issue 和 PR。动手前请先读 [`AGENTS.md`](AGENTS.md) 里的**不变量**——
那几条是产品决策（不假装 Waiting、不做配额 HUD、不在托盘里批准），
不是可以顺手改掉的偏好。

改动请保证 `swift test` 与七个门禁通过；CI 会替你再跑一遍。

## 许可

[MIT](LICENSE)。

## 文档

| 文件 | 内容 |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | 接手须知：不变量、门禁、发布流程 |
| [`EXPERIENCE.md`](EXPERIENCE.md) | 体验规格 —— UI 改动的验收依据 |
| [`docs/architecture.md`](docs/architecture.md) | 数据从进程到菜单栏的完整路径 |
| [`docs/attention-bridge.md`](docs/attention-bridge.md) | 让名单外的工具上报 Waiting |
| [`CHANGELOG.md`](CHANGELOG.md) | 每个版本改了什么 |
| [`docs/plan-0.23.md`](docs/plan-0.23.md) | 0.23 的计划与验收（P2 两项仍开着） |
| [`docs/plan-0.24.md`](docs/plan-0.24.md) | 0.24 计划 —— 辨识度与精致感 |
| [`docs/plan-0.25.md`](docs/plan-0.25.md) | 0.25 计划与实施记录 —— 每行只说一次 |
| [`docs/plan-0.27.md`](docs/plan-0.27.md) | 0.27 计划 —— 读完面板之后你能做什么 |
| [`docs/review-0.21.md`](docs/review-0.21.md) | 0.21 全量审计记录（已全部关闭） |

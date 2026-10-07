# Pulse

macOS 菜单栏状态灯：**一眼知道编码 Agent 是空闲、在跑，还是在等你。**

**版本：`29.0.1`** · [下载 DMG](https://github.com/hxddh/Pulse/releases/tag/v29.0.1) · macOS 14+

开着 Claude Code 写代码，切去开会，回来发现它二十分钟前就停在一个授权提示上。Pulse 把这件事变成余光可见：

| 灯 | 含义 |
| --- | --- |
| 🔴 实心红 | **需要你** —— 阻塞在授权或提问上。点一下：能落到确切的终端就落过去，否则打开这一行的详情 |
| 🟢 绿环 | 运行中 |
| 🟠 橙环 | 停滞 —— 报告过自己在干活的会话久无新事件 |
| ⚪️ 灰 | 空闲、轮到你、最近，或只看到进程（虚线圈） |

回合做完是「轮到你」：托盘头部安静地计数，不变红、不发通知。每个真正的「需要你」只发一条横幅，直接说出被请求
的那件事（`Bash: npm run build`）；回答、忽略或会话结束时横幅自动撤回。点菜单栏，或在 Spotlight / Raycast 里
再打开 Pulse，托盘就打开并选中最久的那个等待，一个 ↩ 就到提示。

Pulse **只做灯**：不在托盘里回答授权，不派活、不跑检查、不替你打字，不显示 token、费用或模型。
完整行为见 [`EXPERIENCE.md`](EXPERIENCE.md)。

## 安装

从 [Releases](https://github.com/hxddh/Pulse/releases) 下载 DMG，把 Pulse 拖进「应用程序」。

> **首次打开**：目前的构建是 ad-hoc 签名、未公证的 `preview` 包，macOS 第一次会拦下它：
>
> 1. 双击打开一次；提示无法验证时点「完成」。
> 2. 打开「**系统设置 → 隐私与安全性**」，在「安全性」里点 Pulse 旁边的「**仍要打开**」并确认。
>
> 或者在「终端」里移除 Pulse 的下载隔离标记：
> ```bash
> xattr -dr com.apple.quarantine /Applications/Pulse.app
> ```
> macOS 15 起按住 Control 点「打开」不再能放行未公证的 App。不要全局关闭 Gatekeeper。每个 Release 的 DMG 旁有
> `.sha256`，可用 `shasum -a 256 -c pulse-x.y.z-macos-PulseBar.dmg.sha256` 校验。

第一次打开时，托盘顶上的设置卡会找到这台 Mac 上的 Agent：点「连接」装上它们各自的官方 hook，再允许通知即可。

## 支持的 Agent

只支持七个。每个都走厂商自己文档里的 hook / 插件 / 扩展，**只装不能改变 Agent 决定的观察型事件**
（从不装 PreToolUse 这类能拦截的 hook，也从不返回任何决定），移除时每个文件逐字节还原。

| Agent | 上一步 | 会不会报告「需要你」 |
| --- | --- | --- |
| Claude Code | `PostToolUse` | 会（PermissionRequest、权限 / 提问通知） |
| Gemini CLI | `AfterTool` | 会（`ToolPermission` 通知） |
| Copilot CLI | `postToolUse` | 会（`permission_prompt` / `elicitation_dialog`） |
| OpenCode | — | 会（插件：`permission.asked` / `question.asked`） |
| Pi | `tool_execution_end` | 会（扩展：`ui_prompt_start`） |
| Codex | `PostToolUse` | **不会** —— 它的 PermissionRequest 在自己的自动审查之前触发，装了就是假等待 |
| Cursor（编辑器与 `cursor-agent`） | — | **不会** —— 没有不拦截的等待事件 |

不会报告的两个只显示「运行中」与「轮到你」，Pulse 如实这样写，不伪造红灯。每个事件装在哪、变成什么、出处在哪，
见 [`docs/vendor-formats.md`](docs/vendor-formats.md)。

## 隐私

- **不连网络。** Pulse 不检查更新、不上报任何东西；设置里的「版本发布…」只是在浏览器里打开 Releases 页。
- **只读事件。** 状态与一行说的一切都来自 hook 写进本地事件日志
  `~/Library/Application Support/Pulse/events.tsv` 的行（0600，超过 1 MiB 自动压缩）。它装着你敲过的提示，
  所以只有你能读。Pulse 不读各 Agent 的会话文件或 transcript，不读受保护的应用数据。
- 进程用 libproc 查看，只为找出还没报过事件的会话和知道会话何时退出；完整命令行不会进入界面。
- 「复制报告」只在你点击时写进剪贴板，不含路径、提示或项目。

## 卸载

1. 设置 → Hooks →「**全部移除**」：逐字节还原每个 Agent 的配置。
2. 右键菜单栏图标 →「退出 Pulse」，把 Pulse.app 拖进废纸篓。
3. 删除 Pulse 的文件夹（事件日志、设置、hook 启动器与安装记录）：

```bash
rm -rf ~/Library/Application\ Support/Pulse
```

开过「登录时打开」的话，在「系统设置 → 通用 → 登录项」里也移除 Pulse。

## 开发

```bash
cd PulseBar && swift test
bash scripts/gates.sh            # 源码门禁
./PulseBar/Scripts/package.sh    # 打包，并检查 .app 与 --selftest
```

接手与发布流程见 [`AGENTS.md`](AGENTS.md)，改动历史见 [`CHANGELOG.md`](CHANGELOG.md)。动手前请先读 AGENTS.md
里的不变量 —— 那是产品决策，不是偏好。

## 许可

[MIT](LICENSE)。Agent 图标来自 [Simple Icons](https://simpleicons.org) 等（CC0，商标归各自所有者）；没有现成
图标的由 `scripts/make_agent_icons.py` 画成几何标记，那是 Pulse 自己的图形。

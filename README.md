# Pulse

macOS **菜单栏** 编码 Agent 运行态感知。

**版本：`0.21.0`** — Swift `MenuBarExtra` 壳（`PulseBar/`）。  
旧 Zig + Native SDK UI 仍在 `src/`，仅作参考。

> 一眼知道 Agent **空闲 / 运行中 / 等待你**。会话标题是主语；Glance 用交通灯色。

体验规格：[`EXPERIENCE.md`](EXPERIENCE.md) · 可选 attention 桥：[`docs/attention-bridge.md`](docs/attention-bridge.md)

## 运行（推荐）

```bash
./PulseBar/Scripts/package.sh
open zig-out/package/Pulse.app
```

开发调试：

```bash
cd PulseBar && swift run
python3 scripts/coverage_check.py   # harvest 接线门禁
```

## 0.18 特色

| 方向 | 行为 |
| --- | --- |
| Waiting 来源 | 行内 `hooks` / `pending` 标签 |
| Focus | TTY / Warp / open cwd 三档诚实路由 |
| Glance 并行 | 多会话 header 带 Agent 名 |
| Attention 桥 | 文档化 TSV；不扩 hook 安装器 |
| 通知 | 空闲 / Waiting 分开关；安静时段仅抑空闲 |
| 刚才在干什么 | 行内 task / tool 摘要 |

## 能力层（0.17+）

| 层 | 含义 | Waiting 来源 |
| --- | --- | --- |
| **A Probe** | 进程 Running | — |
| **B Harvest** | 任务 / 项目 / cwd / session | — |
| **C Waiting** | 需要你 | `hooks` 或 harvest `skill=pending` |

**诚实规则：** `waitingSource=none` 的 Agent 只显示 Running，Tray 可提示「暂无 Waiting 信号」——不强抬。

| Agent | Probe | Harvest | Waiting |
| --- | --- | --- | --- |
| Claude / Codex | A | B | hooks（+ Codex pending） |
| Cursor | A* | B | pending |
| Droid / Kimi / Command Code | A | B | pending |
| Gemini / OpenCode / Amp / Aider / Goose | A | B | pending |
| Grok / Pi / Cline / Roo / Kilo | A | B | pending（尽力） |
| Continue / Copilot / Amazon Q / OpenHands / Zed | A | B | pending（0.17 加深） |
| Cascade / Windsurf / Augment / Kiro | A | B | pending（尽力） |
| Antigravity / Trae / Warp / Devin / Junie / Replit | A | B* | **none**（本机 C 弱） |

\* Cursor 进程常跳过壳，靠 harvest；none 组 harvest 尽力但不承诺 Waiting。

## 版本

- Swift：`PulseBar/Sources/PulseBar/Models.swift` → `PulseVersion.semver`
- 打包产物：`zig-out/package/Pulse.app`、`pulse-*-macos-PulseBar.dmg`

## Legacy（Zig）

```bash
native test
./scripts/package-macos.sh   # 旧 Native SDK 壳，勿与 PulseBar 同时开
```

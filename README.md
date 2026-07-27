# Pulse

macOS **菜单栏** 编码 Agent 运行态感知。

**版本：`0.21.1`** — Swift `MenuBarExtra` 壳（`PulseBar/`）。  
旧 Zig + Native SDK UI 仍在 `src/`，仅作参考。

> 一眼知道 Agent **空闲 / 运行中 / 等待你**。会话标题是主语；Glance 用交通灯色。

Agent 接手：[`AGENTS.md`](AGENTS.md) · 体验规格：[`EXPERIENCE.md`](EXPERIENCE.md) · 可选 attention 桥：[`docs/attention-bridge.md`](docs/attention-bridge.md)

## 运行（推荐）

```bash
./PulseBar/Scripts/package.sh
open zig-out/package/Pulse.app
```

开发调试（从仓库根目录跑门禁，`swift run` 在 `PulseBar/` 下）：

```bash
(cd PulseBar && swift run)          # 开发壳，About 显示 x.y.z-dev
python3 scripts/version_check.py    # 版本一致性门禁（--fix 自动对齐）
python3 scripts/coverage_check.py   # harvest 接线门禁
```

两个门禁都由 `package.sh` 自动执行，打包前会先失败在这里。

## 0.21 特色

| 方向 | 行为 |
| --- | --- |
| 会话作主语 | 行 hero = 任务标题，Agent 名降到次行 |
| Glance | 交通灯：Waiting 红 / Running 绿 / Idle 灰 / Error 橙 |
| 进程降权 | 无任务的 live 显示「检测到进程」，排在有标题会话之后 |
| Waiting 来源 | 行内 `hooks` / `pending` 可信标签 |
| Focus | TTY / Warp / open cwd 三档诚实路由；整行点击即 Focus |
| 版本可辨识 | Tray 页脚 + 关于区带构建指纹，一键复制诊断 |

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

**唯一真源**：`PulseBar/Sources/PulseBar/Models.swift` → `PulseVersion.semver`。

跟随者（由 `scripts/version_check.py` 强制一致，改版本后跑一次 `--fix`）：

| 位置 | 用途 |
| --- | --- |
| `app.zon` `.version` | 旧 Zig 壳清单 |
| `src/version.zig` | 旧 Zig 壳常量（含 major/minor/patch） |
| `CHANGELOG.md` 最新标题 | 发布记录 |
| README 版本徽标 | 本文件 |

**构建指纹**：`package.sh` 把 git short sha 与构建日期写入 `Info.plist`
（`PulseGitCommit` / `PulseBuildDate`），运行时由 `PulseVersion` 读取：

- 打包运行 → `Pulse 0.21.1`，关于区第二行 `a1b2c3d · 2026-07-27`（`+` 后缀表示有未提交改动）
- `swift run` → `Pulse 0.21.1-dev`，构建行显示「开发构建」
- bundle 与二进制版本不一致 → `0.21.1≠0.21.0` 并在关于区高亮，提示重新打包

界面落点：Tray 底部页脚（点击复制诊断）、偏好设置 → 关于。

打包产物：`zig-out/package/Pulse.app`、`pulse-*-macos-PulseBar.dmg`

## Legacy（Zig）

```bash
native test
./scripts/package-macos.sh   # 旧 Native SDK 壳，勿与 PulseBar 同时开
```

# Pulse

macOS **菜单栏** 编码 Agent 运行态感知。

**版本：`0.22.0`** — Swift `MenuBarExtra` 壳（`PulseBar/`）。

> 一眼知道 Agent **空闲 / 运行中 / 等待你**。会话标题是主语；Glance 用交通灯色。

Agent 接手：[`AGENTS.md`](AGENTS.md) · 体验规格：[`EXPERIENCE.md`](EXPERIENCE.md) · 可选 attention 桥：[`docs/attention-bridge.md`](docs/attention-bridge.md)

## 运行（推荐）

```bash
./PulseBar/Scripts/package.sh
open zig-out/package/Pulse.app
```

开发调试（从仓库根目录跑门禁，`swift run` / `swift test` 在 `PulseBar/` 下）：

```bash
(cd PulseBar && swift run)           # 开发壳，About 显示 x.y.z-dev
(cd PulseBar && swift test)          # PulseBar 单元测试
python3 scripts/version_check.py     # 版本一致性（--fix 自动对齐）
python3 scripts/coverage_check.py    # harvest 接线覆盖
python3 scripts/matrix_check.py      # README 支持矩阵 vs waitingSource
```

三个门禁都由 `package.sh` 自动执行，打包前会先失败在这里；
CI（`.github/workflows/ci.yml`）在每次 push 上跑门禁 + macOS 构建与测试。

## 分发

默认 ad-hoc 签名，只能自己用 —— 其他 Mac 会被 Gatekeeper 拦。要真正分发：

```bash
export PULSE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export PULSE_NOTARY_PROFILE=pulse-notary   # 可选，触发公证 + stapler
./PulseBar/Scripts/package.sh
```

应用每天最多检查一次 GitHub Releases（设置里可关）。

## 0.21 特色

| 方向 | 行为 |
| --- | --- |
| 会话作主语 | 行 hero = 任务标题，Agent 名降到次行 |
| Glance | 交通灯：Waiting 红 / Running 绿 / Idle 灰 / Error 橙 |
| 进程降权 | 无任务的 live 显示「检测到进程」，排在有标题会话之后 |
| Waiting 来源 | 行内 `hooks` / `pending` 可信标签 |
| Focus | TTY / Warp / open cwd 三档诚实路由；整行点击即 Focus |
| 版本可辨识 | Tray 页脚 + 关于区带构建指纹，一键复制诊断 |

## 0.22 特色

| 方向 | 行为 |
| --- | --- |
| 省电 | 探测节奏跟随状态（2/5/15/30s），息屏锁屏停表，低电量减半 |
| 通知 | 标题带项目、正文带等待原因；权限被拒时明确提示 |
| 多会话 | 每 Agent 最多 4 个会话，超出部分显式告知而非静默丢弃 |
| 可控 | 快捷键可选、按 Agent 静音、安静时段精确到分钟、hooks 可卸载 |
| 更新 | 每天至多一次检查 GitHub Releases，可关 |
| 质量 | PulseBar 单元测试 + CI + 支持矩阵门禁 |

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

## 版本与发布

**唯一真源**：`PulseBar/Sources/PulseBar/Models.swift` → `PulseVersion.semver`。
`scripts/version_check.py` 强制 CHANGELOG 最新标题与 README 徽标跟随（`--fix` 自动对齐）。

**构建指纹**：`package.sh` 把 git short sha 与构建日期写入 `Info.plist`
（`PulseGitCommit` / `PulseBuildDate`），`PulseVersion` 运行时读取：

- 打包运行 → `Pulse 0.22.0`，关于区第二行 `a1b2c3d · 2026-07-27`（`+` 表示有未提交改动）
- `swift run` → `Pulse 0.22.0-dev`，构建行显示「开发构建」
- bundle 与二进制版本不一致 → `0.22.0≠0.21.1` 并高亮，提示重新打包

界面落点：Tray 底部页脚（点击复制诊断）、偏好设置 → 关于。

### 发布

先在 CHANGELOG.md 写好 `## x.y.z` 段落 —— 没有它所有路径都会拒绝。

```bash
./scripts/release.sh 0.23.0            # 预演：改版本、跑门禁、给出 diff
./scripts/release.sh 0.23.0 --commit   # 提交（附带 [release] 标记）
git push                               # CI 构建、打 tag、发布
```

三种触发方式，最终都进同一个 job：

| 触发 | 适用 |
| --- | --- |
| 提交标题含 `[release]` | 默认；任意分支可用，不需要 tag 写权限 |
| 推送 `v*.*.*` tag | 偏好显式 tag 且有相应权限时 |
| `workflow_dispatch` | 仅当 `release.yml` 已在**默认分支**上 |

**tag 由 CI 用自己的 `contents: write` token 创建** —— 这是刻意设计：发布不应
依赖某个开发者或 agent 的本地凭据。已存在 Release 的版本会被拒绝重复发布，
所以重推是安全的。

应用内的「检查更新」读的就是这些 Release。

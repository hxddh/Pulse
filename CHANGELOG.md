# Changelog

All notable changes to Pulse are documented here.

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
- **写死开发机路径**：`/Users/rustjia/*` 从 aider 扫描根移除，改用 `PULSE_AIDER_ROOTS`
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

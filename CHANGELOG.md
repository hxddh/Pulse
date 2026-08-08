# Changelog

All notable changes to Pulse are documented here.

## 0.70.0 — Contract Honesty / 契约诚实

0.60–0.65 Continuity 弧闭环后，本版换章：**规格 / Support / 样本不得再与代码漂移**。
Waiting-none 单一真源，深度不遮盖，Attention Reach 点名 Agent。详见
[`docs/plan-0.70.md`](docs/plan-0.70.md)。
**无 Apple Developer ID 时本版不切 Stable Gate、不标 `stable` / Gatekeeper-ready；不跳 1.0。**

### P0 · 契约真源

- **`AgentID.waitingNoneAgents`**：样本 / Support / 动态提示派生自 enum，不手抄七名单。
- Support 深度：Waiting-none 仍露出 cache thin/partial（ZCode 不再只显示「Waiting 不可用」）。
- Attention Reach：Support → Waiting signals 携带该 Agent 名聚焦提示。
- EXPERIENCE / observability-matrix 对齐 **32** Agent；场景 **Y**。
- safe report：`waitingNone` + `gatekeeperReady`；matrix_check 拒「31 个用户可见」漂移。

### P1 · 回归

- About preview/signed 仍明示非 Gatekeeper-ready；0.60–0.65 回归保留。

### P2 · 收口

- 假 stable 禁令 / 能量预算 / 不扩 hooks 安装器保留。

### 验证

- SupportHealthTests：深度复合文案、Waiting-none 真源、Attention Reach 点名；
  八门禁对 0.70.0。

## 0.65.0 — Fleet Coverage / ZCode

0.60–0.64 闭环灯与打断；本版换轴：**舰队诚实扩员** —— 接入 Z.ai ZCode ADE
（Probe + best-effort harvest + Waiting-none）。详见
[`docs/plan-0.65.md`](docs/plan-0.65.md)。
**无 Apple Developer ID 时本版不切 Stable Gate、不标 `stable` / Gatekeeper-ready。**

### P0 · ZCode 覆盖

- **`AgentID.zcode`**：`bestEffortCache`、`waitingSource=.none`、App Data opt-in。
- ProcessProbe + `HostAppKind.zcode`（`ZCode.app`）；harvest 根 `~/.zcode` /
  `Library/Application Support/ZCode`。
- 几何图标；Attention 样本 / `raise-zcode.sh`；Waiting-none 七 Agent。
- README 矩阵、coverage / matrix / harvest_stats、attention-bridge 对齐。

### P1 · 别名与回归

- `z-code` / `ZCode` 别名；0.60–0.64 回归保留。

### P2 · 收口

- 假 stable 禁令 / 能量预算 / 不扩 hooks 安装器保留。

### 验证

- 八门禁对 0.65.0；ProcessProbe 签名；Waiting-none 样本覆盖全集；EXPERIENCE 场景 **X**。

## 0.64.0 — Go-Look Closure / 打断闭环

0.60–0.63 让灯可信；本版换轴：**点了通知必须落到那一行** —— notify → 最佳
Focus → 托盘选中/滚到该行。详见 [`docs/plan-0.64.md`](docs/plan-0.64.md)。
**无 Apple Developer ID 时本版不切 Stable Gate、不标 `stable` / Gatekeeper-ready。**

### P0 · 打断闭环

- **`pendingRevealRowKey`**：Store → TrayPanel 一次性桥；打开后选中并滚到该行。
- **`focusAgent` / 通知**：携带 `rowKey`；Waiting 在 Focus 成功后仍 reveal+select
  （软双落点），不因宿主激活丢行身份。
- 多 Waiting 摘要优先精确 `rowKey`；热键 /「跳到最长等待」走同一路径。
- EXPERIENCE 场景 **W**；`notifFocus` →「Go look」/「去看看」。

### P1 · 诚实与回归

- Focus 分级与 composer 深链禁令保留；0.60–0.63 Attention / Live Continuity /
  native hooks 回归保留。

### P2 · 收口

- 假 stable 禁令 / 能量预算 / 不扩 hooks 安装器保留。

### 验证

- GoLookClosureTests：pending reveal、精确 rowKey、focusFirst/Oldest；
  八门禁对 0.64.0。

## 0.63.0 — Live Continuity / 绿灯可信

0.60–0.62 让红灯可达；本版换轴：**绿 / 橙不得说谎** —— 混合舰队、无活动时长、
仅进程观测，不能在菜单栏装成健康 Running。详见 [`docs/plan-0.63.md`](docs/plan-0.63.md)。
**无 Apple Developer ID 时本版不切 Stable Gate、不标 `stable` / Gatekeeper-ready。**

### P0 · Glance 与停滞钟

- **混合舰队**：任意 stalled → Glance 橙（优先于健康绿）；Waiting 仍最高。
- **停滞钟**：`max(harvestMs, activityChangedMs)` —— progress/tokens 前进即刷新，
  不因 mtime 未动假停滞。
- **薄 Running**：process-only / 无活动时钟单独在跑 → Glance 橙，不装健康绿；
  未知年龄仍不把行硬标 `isStalled`（未知 ≠ 沉默证据）。
- EXPERIENCE 场景 **V**；Glance 规则写入体验规格。

### P1 · Support 与文案

- Support：活动年龄 / `no activity yet` / live stalled 可见。
- 停滞主导时 tooltip 尽量带无活动时长。
- 关 stall 阈值、Waiting 不双标 stalled 保留；0.60–0.62 回归保留。

### P2 · 收口

- 假 stable 禁令 / 能量预算 / 不扩 hooks 安装器保留。

### 验证

- SnapshotBuilder：混合橙、信号前进不假停滞、仅进程不绿；AgentRow.stalled 单测；
  八门禁对 0.63.0。

## 0.62.0 — Attention Autonomy / 开放 Attention 协议

0.61 让 Claude/Codex Waiting 脱离 Python；本版换轴：把同一原生 `pulse-hook`
升成 **对外契约** —— Waiting-none 与名单外工具可按协议亮红灯，**不扩**
Claude/Codex hook 安装器。详见 [`docs/plan-0.62.md`](docs/plan-0.62.md)。
**无 Apple Developer ID 时本版不切 Stable Gate、不标 `stable` / Gatekeeper-ready。**

### P0 · 协议与可交付 raise

- **`AttentionProtocol` v1**：统一 header、六列、kind 白名单；未知 kind soft-fail
  （exit 0，不写）；`AttentionReader` 永不把自由文本当 Waiting。
- **契约文档** [`docs/attention-protocol.md`](docs/attention-protocol.md) + 通用
  [`raise.sh`](docs/samples/attention-bridge/raise.sh)；样本优先 `pulse-hook`。
- **可发现**：Waiting-none nudge / Support / L10n 指向协议 raise via `pulse-hook`。
- EXPERIENCE 场景 **U**；architecture / AGENTS / attention-bridge 对齐 0.62。

### P1 · 零依赖叙事与回归

- seed / 文档与「不需要 Python」一致；Live stall 仍标无活动时长。
- 0.60 Attention 身份、0.61 native install/self-test、Waiting-none 不抬 harvest
  pending 回归保留。

### P2 · 收口

- 假 stable 禁令 / 能量预算 / 不扩 hooks 安装器保留。

### 验证

- 未知 kind 拒绝写入；v1 header；外接 raise → AttentionReader Waiting；
  PulseHookReceiver / AttentionReader 单测；八门禁对 0.62.0。

## 0.61.0 — Hook Autonomy / 原生等待通路

0.60 让红灯在舰队上可达；本版换轴：**Claude/Codex 金标准 Waiting 不再依赖
optional Python** —— 原生 `pulse-hook` / `PulseBar --hook` 写入 attention.tsv，
install / self-test 与 native harvest 同级。详见 [`docs/plan-0.61.md`](docs/plan-0.61.md)。
**无 Apple Developer ID 时本版不切 Stable Gate、不标 `stable` / Gatekeeper-ready。**

### P0 · 原生 Waiting 通路

- **`PulseBar --hook`** + Application Support `pulse-hook` launcher（flock/TSV =
  AttentionIO）；`PULSE_HOME` / pathOverride 支持自检隔离。
- **Swift install/uninstall**：改 Claude settings / Codex root-table `notify`；
  拒绝损坏 JSON；迁移 `pulse_hook.py` → native。
- **self-test 无 Python**：进程内写入校验；Settings「测试连接」不依赖解释器。
- 仍 seed 旧 `pulse_hook.py`；probe 认 native 与 legacy；uninstall 清两者。
- EXPERIENCE 场景 T；AGENTS / attention-bridge / README 对齐 0.61。

### P1 · 文案与回归

- hooksHint：原生、无需 Python。
- Attention 样本 / bridge raise 优先 `pulse-hook`；停滞行仍标无活动时长。
- Attention 身份、pending、Waiting-none、Focus 回归保留。

### P2 · 收口

- 假 stable 禁令 / 能量预算 / 不扩 hooks 安装器保留。

### 验证

- PulseHookReceiver / HooksInstaller 单测；self-test；八门禁对 0.61.0。

## 0.60.0 — Waiting Continuity / 等待连续

0.59 让 Limited 缓存有料；本版回到产品本职：**红灯在舰队上可达且可信** ——
harvestPending 认显式 ask/block，Attention 不 smear 兄弟行，Waiting-none 只走
Attention 桥。详见 [`docs/plan-0.60.md`](docs/plan-0.60.md)。
**无 Apple Developer ID 时本版不切 Stable Gate、不标 `stable` / Gatekeeper-ready。**

### P0 · 等待可达

- **Attention 挂靠身份**：带明确 session 却无命中 → 新建 Waiting 行，不点亮兄弟；
  空 session 的进程行可收养该 wait；cwd 仅在无 session 时回退。
- **harvestPending 审计**：Cline `ask=followup`（无 `askResponse`）/ Roo ask tool /
  Cascade `isWaitingForResponse` / `ask_clarifying_question` → pending；
  `askResponse` 已答则否；`depending` 仍否；Waiting-none 仍不从 harvest 抬 pending。
- **一键修复**：Support/Tray → Waiting signals；六 Agent 样本写/清保留。
- EXPERIENCE 场景 S；attention-bridge / AGENTS / matrix 对齐 0.60。

### P1 · 回归

- pending 矩阵、soft-dismiss × harvest pending、通知带 `waitMessage`、
  `isSessionPath`（Pi `sessions/`、Goose `session.json`）保留。

### P2 · 收口

- Focus / Cache / Settings / 能量预算 / 假 stable 禁令保留。

### 验证

- Attention 未知 session、Cline ask 字段、Cascade waiting 旗、Waiting-none 门闩、
  pending depending；八门禁对 0.60.0。

## 0.59.0 — Cache Continuity / 缓存连续

0.58 止住了假 session；本版让高流量 `bestEffortCache` 在 Limited 下**有料**：
抽出已有的 goal/cwd/tool/mtime，Support 区分薄索引与富缓存事实。
详见 [`docs/plan-0.59.md`](docs/plan-0.59.md)。
**无 Apple Developer ID 时本版不切 Stable Gate、不标 `stable` / Gatekeeper-ready。**

### P0 · 富缓存事实

- cwd 认 `workspace` / `path`（仅绝对路径）；JSON `updatedAt`/`lastUpdatedAt` → activityMs。
- chrome title 不压嵌套用户 prompt；merge 偏好真实 goal。
- 扩展 Cline/Roo（Windsurf/Trae hosts）、Cascade/Codeium、Warp、Zed、Amazon Q 根。
- Support：薄 → `thin cache`；富 → `cache facts (Limited)`；证据仍 `.cache`。
- `waitingSource.none`（含 Warp）不从 harvest 抬 `skill=pending`。
- EXPERIENCE 场景 R；attention-bridge 样本文案对齐六 Agent。

### P1 · 质量三分与回归

- ObservationQuality：`cache_thin` vs `cache_conditional` vs privacy。
- pending：`depending` 仍否；`awaiting_user` / `ask_followup_question` 仍是。
- Pi mid-tier fixture；Attention / Support 深链保留。

### P2 · 回归

- Focus / AppKit Settings / 0.58 证据门闩 / 能量预算保留。

### 验证

- 富/薄 Windsurf·Roo、Pi、pending、Support depth、ObservationQuality；八门禁对 0.59.0。

## 0.58.0 — Fleet Continuity / 舰队连续

0.57 硬化了旗舰行；本版把同一套事实契约铺到舰队：非旗舰 session 审计、
`bestEffortCache` 永不假 session、pending 整词匹配、Waiting-none 六 Agent
Attention 样本可达。详见 [`docs/plan-0.58.md`](docs/plan-0.58.md)。
**无 Apple Developer ID 时本版不切 Stable Gate、不标 `stable` / Gatekeeper-ready。**

### P0 · 舰队事实诚实

- **非旗舰 structuredSession**：Amp 等 goal/cwd 回归；chrome 默认标题扩拒；
  EXPERIENCE 场景 Q。
- **`bestEffortCache` 证据门闩**：`makeRows` 对 cache 适配器恒输出 `.cache`，
  即使路径/SQLite 看起来 structured；Windsurf/Cline 薄索引 → Limited。
- **空壳禁令**扩到舰队；Support depth 与 matrix 一致。
- EXPERIENCE / architecture / AGENTS / README 对齐 0.58。

### P1 · Waiting 与 App Data

- Settings「写入样本 Waiting」覆盖全部六个 Waiting-none Agent
  （replit / devin / warpAgent / trae / antigravity / junie）；清除同范围。
- **pending 整词/短语匹配**：`depending` 不再因子串 `pending` 假抬 Waiting。
- 薄 cache / privacy_limited 的 `enable_app_data` nextStep 保持可点。

### P2 · 回归

- Focus / AppKit Settings / 旗舰 subagent / Codex title / Support depth 保留。

### 验证

- Amp / Windsurf·Cline cache evidence / pending depending / Attention 六样本 /
  ObservationQuality 薄 cache 单测；八门禁对 0.58.0。

## 0.57.0 — Fact Continuity / 事实连续

0.56 能诚实回去；本版保证托盘行带着**真实事实**，不留空壳 chrome，也不再靠
SwiftUI Settings 场景当生命周期锚点。详见 [`docs/plan-0.57.md`](docs/plan-0.57.md)。
**无 Apple Developer ID 时本版不切 Stable Gate、不标 `stable` / Gatekeeper-ready。**

### P0 · 事实硬化与 Settings 根治

- **Claude**：session 盖章后 re-merge；tool 后写覆盖；从
  `…/<sessionId>/subagents/agent-*.jsonl` 计数 subRunning/subTotal（mtime ≤ 120s）。
- **Codex**：无类型 head/compat 行不再把裸 `title`（plan/registry）升成 task；
  只认 task/prompt 等真提示键。
- **Cursor**：App Data 下 composer Goal/cwd/pending 回归保留；薄则 Limited。
- **托盘空壳禁令**：无动态事实 → 次行省略；无溢出 → 无 gutter；仅进程文案不重复
  （EXPERIENCE 场景 O）。
- **Settings**：去掉 SwiftUI `Settings { EmptyView() }`，AppKit-only 启动；
  reopen 拒绝造窗（场景 P）。真设置仍走 `SettingsWindowController`。

### P1 · 可读深度与文档

- Support Health 一眼区分 session / cache / Waiting-none 深度。
- `architecture.md` 写明 harvest merge：session stamp → re-merge、tool 后写覆盖。
- matrix：高流量 cache（Windsurf/Cascade/Cline/Roo/Warp…）薄则 Limited，不升格假 session。
- EXPERIENCE 场景 O / P；AGENTS / README 对齐 0.57。

### P2 · 回归

- 删除死 L10n `noProgressSignal`；Focus / 标题 / 0.56.1 回归保留。

### 验证

- Claude subagent / Codex untyped-title / Support depth 单测；八门禁对 0.57.0。

## 0.56.1 — Tray facts & phantom Settings / 托盘事实与幽灵设置窗

### Bug fixes

- **幽灵空设置窗**：更新后用 Finder/Spotlight「打开」Pulse 时，SwiftUI
  `Settings { EmptyView() }` 会被 AppKit reopen 弹出空白设置页。现拒绝 reopen，
  并在启动 / 激活时关掉无 `pulse-*` identifier 的幽灵窗。真设置仍走
  `SettingsWindowController`。
- **Claude 行缺有效信息**：原生 harvest 识别 `tool_use`/`name`；从
  `~/.claude/projects/<encoded>/` 解码 cwd；session id 盖章后重新 merge，且
  **tool 后写覆盖**，避免最早碎片抢走最新动作。
- **托盘空行占位**：次行不再回退成 Agent 名；无动态事实时不发明
  「No progress signal yet」；仅进程行的「无活动数据」改到主行文案，次行不重复。
- 无真实标题时，人话工具名可作主行（不再要求 live process）。
- ObservationQuality 只认 `usefulTask`，拒绝的占位 task 不再冒充有目标。
- 无溢出菜单时不再预留尾部空白 gutter。

### 验证

- Claude tool_use + encoded cwd 单测；托盘 context/signal/hero 回归；八门禁对 0.56.1。

## 0.56.0 — Landing Precision / 精确落地

0.55 能回去；本版把「回到哪一层」说清楚，并在可验证时落到宿主工作区。
详见 [`docs/plan-0.56.md`](docs/plan-0.56.md)。
**无 Apple Developer ID 时本版不切 Stable Gate、不标 `stable` / Gatekeeper-ready。**

### P0 · 落地精度

- `FocusTier.hostWorkspace`：绝对 cwd 时 `open -a Host.app <cwd>`；否则 `.hostApp`。
- 文案 / Support：TTY 标签 · 工作区 · Warp/宿主 (app) · 仅观测；不再把仅激活 App 写成「跳到该会话」。
- Warp 明确为 App 级；深链边界见 [`docs/landing-hosts.md`](docs/landing-hosts.md)。
- EXPERIENCE / README / architecture / matrix / AGENTS 对齐 0.56。

### P1 · ingest 与 Attention 可达

- SQLite 采集 `LIMIT` 与 retain 同为 500。
- Settings → Waiting signals：一键写入 / 清除 Replit Attention 样本（不扩 hook 安装器）。
- bestEffortCache / none Waiting 叙事与 matrix 一致。

### P2 · 回归

- hostWorkspace / 文案单测；标题边角回归保留。

### 验证

- FocusTier / SnapshotBuilder / L10n；八门禁对 0.56.0。

## 0.55.0 — Return Continuity / 回到现场

红灯已立；本版把「点一下回到正确表面」做完。详见 [`docs/plan-0.55.md`](docs/plan-0.55.md)。
**无 Apple Developer ID 时本版不切 Stable Gate、不标 `stable` / Gatekeeper-ready** ——
GitHub Latest 仍可跟 semver，Info.plist 保持 preview。

### P0 · Focus 诚实与宿主回到现场

- Support Health 每 Agent 标明 Focus 事实（Warp / 宿主 / TTY / 需 opt-in / 仅观测）。
- 通知与「跳到等待」：有句柄则 Focus，否则打开托盘 —— 不静默失败。
- `FocusTier.hostApp`：Cursor / VS Code / Windsurf / Zed / Trae / Antigravity 经
  `ps` 父链识别，点击时 `NSWorkspace` activate（扫描期不枚举、不隐式 TCC）。
- `architecture.md` 会话预算对齐 500/500/glance 12；EXPERIENCE Focus / 英雄文案同步。

### P1 · Automation opt-in 与行动作文案

- Shortcuts：显式「允许聚焦 Terminal / iTerm 标签」（默认 off）；开启后才广告 `.tty`。
- 动作文案分级：Focus Warp / Focus 宿主 / Focus 终端标签；无句柄不伪装 Focus 按钮。

### P2 · Attention 样本与标题回归

- `docs/samples/attention-bridge/`：replit / devin / warpAgent / trae / antigravity / junie。
- 标题边角（tool 同名 / 文件名）单测保留；补宿主 Focus 文案单测。

### 验证

- FocusTier / SnapshotBuilder hostApp、settings `terminalAutomation` round-trip；八门禁对 0.55.0。

## 0.54.2 — Tray titles & density / 托盘标题与信息密度

下拉弹窗主行常被工具 ID / 占位符占用，有效信息被留白和重复叙事稀释。本版修标题来源并收紧行距。

### 标题

- 主行只接受真实用户目标；拒绝 `update_plan`、文件名、`Agent session`、与 tool 同名的假标题。
- Codex 不再把 `function_call` 参数里的 title/description 写成 session task。
- harvest 通用解析优先 `task/goal/prompt`，vendor `title/summary` 靠后。
- 无真实标题时：人话工具名（Bash→执行命令）→ 项目 → 终端/应用短语；**不再用 Agent 名当主行**。

### 密度

- 真实标题在列表拥挤时仍两行；行间距 / 垂直 padding 收紧。
- 主行已是人话工具时，次行不再重复同一动作。

### 验证

- usefulTask / heroToolTitle / Codex 不提升 tool-arg 单测；八门禁对 0.54.2。

## 0.54.1 — Formal Latest without notarization / 无公证正式 Latest

没有 Apple Developer ID 时无法公证。按产品要求恢复 **GitHub Latest = 当前 semver**，
结束 0.49–0.54 把新版关进 Pre-release、Latest 钉死在 0.48 的失败模式。

### 发布策略

- `release.yml`：无论是否有签名 secrets，GitHub Release **一律非 prerelease** 且
  `make_latest`；缺凭据时 notes 强制附 Gatekeeper 说明。
- Info.plist 仍为 `preview`（ad-hoc）——**绝不**把未公证包装成 `stable` / Gatekeeper-ready。
- About / 就地安装契约不变：仅 notarized stable 出现就地安装。
- 更新文案：preview 通道写「unsigned」，不再假装「prerelease 通道」。

### 文档

- AGENTS / README / EXPERIENCE / architecture：Latest ≠ notarized；无 Developer ID 时
  Latest 跟 semver，Gatekeeper 仍需右键打开。

### 验证

- version_check → 0.54.1；发布后 `/releases/latest` == `v0.54.1` 且 `prerelease=false`。

## 0.54.0 — Channel Continuity / 通道与契约连续

0.53.0 把安装与恢复契约做完之后，本版对齐用户触达的下载链接、验收数字与更新文案；无 Apple 公证凭据时仍诚实停留在 prerelease。详见 [`docs/plan-0.54.md`](docs/plan-0.54.md)。

### P0 · 触达契约

- README 下载链跟当前 semver tag；安装节不再把 `/releases/latest` 写成「最新源码」。
- EXPERIENCE 会话预算对齐代码（500 / 500 / glance 12）；图标 32；场景与禁常驻动画一致。
- AGENTS / architecture / 贡献八门禁指针跟到 0.54。
- `version_check.py`：README「下载 DMG」URL 必须含 `v{semver}`。

### P0 · 更新通道叙事

- 「已是最新」分 preview/signed（相对 prerelease）与 stable（不含 prerelease / 公证可能滞后）；dev 保持短句。

### P1 · 节奏与回归

- `ProbeSchedule`：空闲 harvest 每 4 个 probe tick（Waiting / 托盘打开仍每 tick）。
- CI：Observation Truth 再跑一组 `en` + `dark` 截图并上传。

### P2 · 收口

- crash 恢复文案注明无法区分强制退出（SIGKILL）。
- InstallTruth / architecture 写清浅扫边界。
- Cursor App Data A/B：**明确保持手工 Darwin，不进 CI**。

### 验证

- version_check（含下载链）、ProbeSchedule empty 倍数、更新文案单测；八门禁对 0.54.0。
- **stable 公证工件仍 blocked on notarization** —— 凭据缺席时继续 prerelease，绝不假标 Latest。

## 0.53.0 — Delivery Continuity / 交付连续信任

0.52.0 把发布标签与 Gatekeeper 事实对齐之后，本版把信任推进到安装、更新与恢复连续性；无 Apple 公证凭据时仍诚实停留在 prerelease，不把未公证包装成 Latest。详见 [`docs/plan-0.53.md`](docs/plan-0.53.md)。

### P0 · 通道与更新叙事

- 文档契约：README / architecture 与 `release.yml` 对齐——缺凭据 → ad-hoc + prerelease；八门禁含 `resource_budget_check.py`；通道写全 preview / signed / stable。
- 就地安装仅 `isGatekeeperReady`（notarized stable）；preview / signed 校验 DMG 后由用户打开安装，About 说明不假装 Gatekeeper-ready。
- **stable 公证工件仍依赖仓库 Apple secrets**；凭据缺席时继续 prerelease，绝不假标 Latest。

### P0 / P1 · 安装面与恢复

- InstallTruth：Launch Services 全量注册副本 + Desktop / Downloads 浅扫；About 列出前 5 条并显示「另有 N 个」。
- LaunchRecovery：SIGTERM 写入 `forceQuit` 意图；`markCleanShutdown` 不再覆盖意图；分类与文案不再把 clean / updateReplace 误报为 crash。

### P1 · QA

- `qa_observation_truth.sh`：按文件就绪轮询代替固定 `sleep 9`；支持 `PULSE_QA_APPEARANCE` / `PULSE_QA_LANGUAGE`。

### P2 · 辅线

- `waitingSource=.none` 六 Agent：托盘 / Support 深链 Waiting signals；Attention 桥文案点名；「打开 Attention 文件夹」。
- bestEffortCache：隐私缺口一律 `enable_app_data` 深链；缓存受限行展示 wait-cache 下一步。
- `safeSupportReport`：`factCoverage` + `failureTimeline`；Support 行展示最近失败年龄。

### 验证

- intentional forceQuit / About hidden-duplicate / InstallTruth Desktop / Attention bridge / factCoverage 单测；八门禁与 version_check 对 0.53.0。

## 0.52.0 — Release Trust / 可交付信任

0.51.0 把观测文案做诚实之后，本版对齐发布标签与 Gatekeeper 事实，隔离故意延后的扫描 partial，并把通知拒绝与诊断包写进 Support。详见 [`docs/plan-0.52.md`](docs/plan-0.52.md)。

### P0 · 发布与 Gatekeeper 真相

- `package.sh` 通道：`preview`（ad-hoc）→ `signed`（Developer ID 未公证）→ `stable`（公证成功）；Info.plist 写入 `PulseDistributionChannel` + `PulseNotarized`。
- GitHub Release：ad-hoc **或** 无 notary 一律 prerelease；未公证包不得标 stable。
- About 三态文案；Gatekeeper 首次打开说明仅未公证 DMG 附带。
- `UpdateCheck`：preview / signed 读 releases 列表（含 prerelease）；stable 仍走 `/latest` 并过滤 prerelease。

### P0 · 扫描 incomplete 隔离

- Supervisor 故意延后（backoff / circuit）的 partial **不**点亮 `collectorScanIncomplete`。
- 超时且已有部分行继续用 timeout 专属文案；故意延后不再冒充扫描失败。

### P0 · 通知权限真相

- 系统拒绝通知时 Settings 常驻说明 + 打开系统设置；safe report 写入 authorization / pending 计数。

### P1 · 诊断与回归

- `safeSupportReport` 补齐 appDataGrant、probeCadence、timeoutAgents、per-agent error/duration、supervisor deferred、notarized。
- 托盘 VoiceOver 以 `rowSignalLine` 为动态摘要主源，去掉重复 activityChange+metrics。
- CI：`qa_observation_truth.sh` 截图并上传 PNG；缺文件失败。

### P2 · 门禁

- `scripts/resource_budget_check.py`：native fixture 墙钟 + RSS；接入 CI / package / AGENTS 八门禁。

### 验证

- Swift build；intentional-partial / UpdateCheck prerelease / safe-report 单测；八门禁与 version_check。

## 0.51.0 — Observation Truth / 诚实表面

0.50.0 让观测更深之后，本版让权限文案、harvest 诊断、托盘指标与 Support/检查器对齐真实授权与扫描状态。详见 [`docs/plan-0.51.md`](docs/plan-0.51.md)。

### P0 · 观测真相

- Support Health 隐私横幅区分全关 / 已按 Agent 授权仍有受限 / 无受限；scoped Cursor 授权不再被写成「深度扫描已关闭」。
- `--harvest-test` / `--harvest-dump` 读取与托盘相同的 `settings.txt` App Data 授权，并打印 `appData` / `agents`。
- 托盘信号行在无活动变化时走 `compactSignalEvidence`，消除 `Context N% · Context N%` 重复。
- 扫描不完整横幅区分「适配器超时且已有部分结果」与笼统失败；托盘给出同源短提示；超时行在 Support 暴露 `native_timeout` 原因。

### P1 · 产品表面

- 灯 tooltip / VoiceOver：Waiting 含 agent、原因与时长；Stalled 含时长。
- `openSettings(focusAppDataFor:)` 展开 App Data 作用域并高亮目标 Agent；Support / 质量下一步可深链；CLI `--open-settings-agent=`。
- Support 对 privacy / limited / unscanned 显示能力缺口 pill；检查器质量卡展示 facts、人类化 confidence、collector error 与授权深链。
- `observationGapNextStep` 显式映射 `open_agent_for_session` / `retry_scan` / `enable_app_data`；新增 `scan_timeout` 原因文案。

### P2 · 门禁与回归

- `scripts/qa_observation_truth.sh`：status-* fixture 托盘/灯截图。
- `scripts/qa_mac_cursor_appdata_ab.sh` 断言 harvest dump 反映 scoped 授权。
- `harvest_stats_check.py` 墙钟上限（默认 8s，`HARVEST_MAX_SECONDS`）。
- `status-*` tray fixture 注入真实行（承接 QA 修复）。

### 验证

- Swift build；Observation Truth / Support / settings / signal-line 单测扩展；七门禁与 version_check。

## 0.50.0 — Signal Quality / 有效观测

0.49.1 完成可靠性闭环后，本版不再扩 Agent 名单，而是让现有 31 个 Agent 的信息更深、更可信、更可操作。详见 [`docs/plan-0.50.md`](docs/plan-0.50.md)。

### P0 · 观测质量信封

- 每行携带命名 `ObservationQuality`：`facts` / `missing` / `freshness` / `confidence`。缺失字段必须说明缺什么、为什么缺、下一步做什么。
- 托盘不再出现无解释的 “Limited data / 仅进程”；改由质量信封驱动文案（进程证据、隐私受限、缓存未写出等）。
- 详情检查器展示质量摘要与缺口列表；`bestEffortCache` Agent 继续用真实 fixture 覆盖。

### P0 · 全量会话索引

- 每 Agent 可搜索保留上限提升到 500；托盘 glance 仍为 12 行，避免一次扫描拖垮菜单栏。
- 搜索表面增加 Agent / 阶段 / 结果筛选，并显示「全部 N 个会话」。
- 详情检查器从全量索引解析行，不再绑在 glance 的 12 行窗口上。
- 压力夹具覆盖 4 / 20 / 100 / 500 会话。

### P0 · Waiting 与恢复提示

- `LaunchRecovery` 区分 crash、强制退出、系统重启与正常更新替换；更新替换不再误报异常退出。
- 异常退出横幅可在健康扫描后自动消失，也可由用户关闭。
- Waiting 详情展示账本时间线：排队、通知、确认、稍后、解决与通知待发送状态。

### P0 · 单安装副本与权限

- `InstallTruth` 分类 `currentInstalled` / `buildArtifact`（zig-out 等）/ `rollback` / `orphanDuplicate`；回收只动用户安装副本。
- 按 Agent 开启 App Data 后只重扫受影响 Agent，不再全量 `saveSettings` 刷新。

### 验证

- Swift Debug/Release build、原生 31-agent fixture、协议/矩阵/图标/外观/harvest gates 通过。
- 新增 ObservationQuality 与会话索引压力测试；LaunchRecovery / InstallTruth 分类断言扩展。

## 0.49.1 — P0/P1/P2 验收收口

### 修复

- Notification Center 的异步失败现在会回写 Waiting 账本并重新排队；只有系统真正接受通知后才标记已通知，重启或服务短暂异常不会吞掉确认提醒。
- Support Health 每个 Agent 只保留一个主操作，隐私受限、重试和 hooks 路径不再重复渲染同一动作。
- supervisor 有意延后的 adapter 会被识别为 bounded partial scan：已完成的 Agent 仍可及时完成 Waiting 闭环，真正的超时、损坏和 schema 错误继续保持不可靠保护。
- Waiting 活跃事件不再被 256 条历史上限驱逐；只限制已解决历史，批量并发 Waiting 可全部恢复、确认和通知。
- 同步当前版本文档和预览版下载链接，避免 `latest` 指向旧的稳定 Release。

### 验证

- Swift Debug/Release build、原生 31-agent fixture、协议/矩阵/图标/外观/harvest/package gates 和 packaged selftest 通过。
- OperationalClosure 覆盖异步交付所依赖的 durable queue、supervisor partial、崩溃恢复、事务替换和 300 条活跃 Waiting 保留；CI 继续执行完整 XCTest。

## 0.49.0 — 完整观测闭环与可恢复发布

### P0 · 采集与 Waiting

- 每个 Agent 采集由 supervisor 独立调度：超时、重试退避、连续失败熔断和半开恢复互不影响；锁定或损坏的数据源不会拖垮其他 Agent。
- Waiting 账本持久化事件 ID、排队、通知、确认、稍后和解决状态；通知按事件去重、限流，四个以上并发等待合并为可聚焦摘要，重启后继续闭环。
- 运行时只接受命名 JSON schema 2；旧 positional TSV 只在显式兼容测试/诊断入口启用，字段变化不再静默错位。
- 31 个 Agent 的原生/合成 fixture 继续作为发布门禁，覆盖行、健康、损坏源和 partial scan。

### P1 · 可观测性与交互

- Support Health 改为七种明确状态：可用、需要处理、信息受限、未安装、无近期会话、权限不足、未扫描；每个 Agent 只给一个原因和下一步。
- 托盘搜索覆盖最多 128 条已采集会话，可按 Agent、任务、项目、工作区、会话、动作、阶段、模型和结果检索；不再被默认 12 行隐藏。
- 详情检查器把阶段提升为首要事实；原始 tool/skill 仍在诊断层保留。支持健康度默认展开诊断，权限设置逐 Agent 说明读取范围、收益和跳过后的行为。
- Waiting 记录导出为脱敏安全报告；状态颜色、行列、搜索和操作保持单一面板、长中文、深浅色、键盘和 VoiceOver 友好。

### P2 · 安装、恢复与发布

- 更新安装前执行 macOS、arm64、DMG 挂载、bundle ID、可执行文件和目录权限预检；下载校验后通过 helper 事务替换，旧 App 先进入回滚库，失败可恢复且不会先删除。
- 启动标记记录异常退出并在下次启动提示恢复；支持报告包含 supervisor、账本队列和恢复状态，不泄露路径或 payload。
- 无 Apple Developer 账户时明确产出 preview / ad-hoc / 未公证包并标记 GitHub prerelease；未来 Developer ID + notarization 自动切换 stable。

### 验证

- Swift release build、31 个 fixture、协议/矩阵/图标/外观/harvest gates、原生 selftest、事务替换与崩溃恢复测试全部纳入发布流程。

## 0.48.0 — Reliable observability

### P0 · 采集、提醒与权限稳定性

- Activity harvest now runs through the Swift-native bounded reader; the old
  Python collector is an explicit compatibility diagnostic only. A missing
  Python runtime no longer prevents launch, refresh, self-test, or packaging.
- 保留版本化 JSON 观测协议（schema 2）作为显式 legacy 诊断通道，字段按名称传输，避免新增 Agent 字段造成 positional TSV 错位；默认运行时改用 Swift 原生类型，不再依赖该 wire。
- 采集器增加运行时 helper 预检、Apple silicon 路径校验、每 Agent 隔离超时、48 MB 读取预算和 6 秒总截止时间；部分结果继续保留，单个损坏或锁定的数据源不会清空其他 Agent。
- 独立损坏 JSON 会被标为该 Agent 的可重试 partial；空的失败/超时结果保留该 Agent 上一次有效会话，避免“暂时读不到”被误报成“没有会话”。
- 超大 Codex/Claude rollout 只读取有界头尾窗口（Codex compacted context 使用独立 8 MiB 上限，仍受总预算约束），支持最新用户任务；UTF-8 截断、旧 transcript 和空占位不会再让当前会话消失或污染列表。
- 新增持久化 attention ledger：Waiting 事件、通知去重、稍后、解决和跨重启基线均原子写入，避免丢提醒或重复提醒。
- 深度 App Data 改为按 Agent 授权范围；默认不请求权限，权限说明明确到具体 Agent 和数据收益。
- 不继承旧版“一键读取全部 App Data”的授权状态；升级后必须由用户在新的逐 Agent 设置中再次明确选择，避免 ad-hoc 身份变化触发反复权限弹窗。

### P1 · 产品力与可观测性

- Support Health 默认展示完整 31 Agent 名单，状态改为可行动的“需要处理 / 信息受限 / 健康 / 暂无本机证据”，每行提供下一步操作。
- 新增 Agent Details 检查器：展示任务、工作区、阶段、模型、进度、资源、证据等级和 Waiting 原因；原始 tool/skill 仅在诊断折叠区展示。
- 每 Agent 会话采集预算提升至 256、Swift 保留 128；托盘默认可见行提升至 12，并保留精确的隐藏计数。
- 256 条是 adapter 级硬上限（SQLite、JSON、云端数组和通用解析均在追加点截断），仅包含可展示事实，避免空 Composer/metadata 记录挤掉真实会话。
- 继续以 Planning、Reading、Testing、Building、Publishing 等人类语义展示 tool/skill，不将原始实现名当作当前动作。

### P2 · 发布、诊断与体验

- 更新下载改为 OS/架构预检、内容类型/大小/SHA-256 校验和非破坏性落盘，不再删除已有安装包。
- 支持报告加入采集协议、权限范围、attention ledger 和 helper 状态；敏感路径与 payload 仍脱敏。
- 统一详情窗口、支持健康度和托盘的间距、状态颜色、VoiceOver 文案和键盘动作；默认不折叠核心内容。

### 验证门槛

- 31 个 Agent 运行态 fixture、100 会话压力、10 个并发 Waiting、权限拒绝、helper 缺失、锁库、损坏 JSON、超时、睡眠唤醒、重启恢复和 DMG 内容校验必须全部通过；Python 仅为可选 legacy/源码门禁，不是打包或运行时前置条件。
- 本版本仍需 Apple Developer ID 与 notarization 凭据后才能消除其他 Mac 的 Gatekeeper 放行步骤。

## 0.47.11 — 等待提醒与首次启动路径

### 可观测与提醒

- 同一轮扫描发现多个需要确认的会话时，每个 Waiting 会话都生成独立、可聚焦的通知，不再只提醒排序后的第一行。
- 通知权限异步返回期间不会丢失 Waiting 边沿；权限恢复后仅补发仍在等待的会话，避免过期提醒。
- 通知尚未启用或被系统关闭时，托盘在 Needs you 列表上方给出可点击的明确提示；后台扫描不会自动申请权限。
- 新 Waiting 进入时状态栏红灯短促脉冲三次，红灯持续亮起表示仍有未处理确认，不使用持续动画打扰。

### 安装与发布

- DMG 随附中英文首次启动说明，明确 ad-hoc/未公证包的 Gatekeeper 放行路径，不建议全局关闭 Gatekeeper。
- 保留 macOS 14+、Apple silicon（arm64）要求，并在诊断中记录通知授权状态与待补发数量。

### 验证

- Swift Release build、31 个 Agent collector、覆盖矩阵、图标、外观、harvest、资源 selftest 和 DMG 内容检查通过。
- 当前仍无 Apple Developer ID / notarization 凭据；跨 Mac 首次启动仍需用户明确放行。

## 0.47.10 — 托盘状态灯与布局对齐

### 界面与交互

- 统一项目分组标题和 Agent 行的图标、状态灯与名称起始列，修复项目分组下红灯错位。
- 状态灯改为视觉居中，移除等待行图标上的重复橙色徽点，避免同一状态出现多套互相冲突的灯号。
- 提升隐私受限、本地缓存等观测证据标签在浅色模式下的可读性，并覆盖中文/深色/浅色布局回归。

### 验证

- Debug / Release build、31 个 Agent collector、覆盖矩阵、图标、外观、harvest 和打包 selftest 通过。
- 新增托盘身份网格回归断言。
- 本版本仍为未签名、未公证 macOS DMG；其他 Mac 可能触发 Gatekeeper。

## 0.47.9 — 受隐私限制时补齐 Agent 可观测性

### 可观测性与交互

- 托盘默认行优先展示可验证的模型、上下文和最近动作等稳定事实；有这些信息时不再用原始事件数占位，降低信息含义歧义。
- Cursor 在未授权读取受保护 App 数据时不再从列表中消失，明确显示为“Privacy-limited / 隐私受限”，同时保留进程启动时间和检测来源。
- 过滤 Cursor 的 Electron helper 进程，避免把辅助进程误报为多个会话；主 Cursor 会话仍可被检测。

### 验证

- Cursor 隐私受限回退、helper 过滤、稳定事实优先级均新增回归测试。
- Debug / Release build、31 个 Agent collector、覆盖矩阵、图标、外观、harvest 和打包 selftest 通过。
- 本版本仍为未签名、未公证 macOS DMG；其他 Mac 可能触发 Gatekeeper。

## 0.47.8 — 托盘去除 hooks 安装提示

### 交互与可用性

- 下拉弹窗不再显示“安装 hooks”提示、入口或空状态安装按钮，避免把可选能力误读成使用前置条件。
- 无 hooks 模式继续展示本地会话、进程和 Waiting 相关事实；hooks 配置仍可在 Settings / Support Health 中按需查看。

### 验证

- Debug / Release build、托盘截图和打包 selftest 通过。
- 本版本仍为未签名、未公证 macOS DMG；其他 Mac 可能触发 Gatekeeper。

## 0.47.7 — 无 hooks 观测增强

### 可观测性与隐私

- 不安装 hooks 也能从本地会话元数据读取最近动作、模型、上下文占用、输入/输出 token、文件数和进度；仅使用明确存在的字段，不根据日志长度猜测。
- 兼容不同 Agent 对上下文占用和计数的格式（比例、百分比、字符串），并修复元数据动作写入错误 wire 字段导致 token 丢失的问题。
- Process-only 行显示可验证的检测来源，并隐藏未匹配会话流的历史事件数，避免把进程证据误读成完整活动流。

### 验证

- 31 个 Agent collector、支持矩阵、图标、外观和 harvest 协议门禁通过。
- Release build、打包 selftest、完整 harvest 测试和 31 个 adapter fixture 验证通过。
- 本版本仍为未签名、未公证 macOS DMG；其他 Mac 可能触发 Gatekeeper。

## 0.47.6 — Waiting 信号可见性修复

### 可观测性与交互

- Claude / Codex 运行但缺少 hooks 时，主托盘直接显示橙色提示，不再只藏在“…”菜单或 Support Health 中。
- hooks 已就绪但 Agent 没有 Waiting 信号时，明确显示“仅 Running”，避免把未覆盖误读成完整观测。
- Waiting 信号提示点击后只进入 Settings，不会误触发更新下载，也不会再次索要权限。

### 验证

- 31 个 Agent collector、支持矩阵、图标、外观和 harvest 协议门禁通过。
- Debug / Release build、资源 selftest、完整 harvest 测试和 ad-hoc 签名验证通过。
- 本版本仍为未签名、未公证 macOS DMG；其他 Mac 可能触发 Gatekeeper。

## 0.47.5 — 通知设置状态一致性修复

### 交互与可用性

- macOS 通知权限未授权或被拒绝时，通知与等待开关现在明确显示为关闭且不可操作，不再出现“开关显示开启但实际无法触发”的歧义。
- 权限恢复后自动恢复用户原先保存的通知偏好，不丢失设置。

### 验证

- 31 个 Agent collector、支持矩阵、32 条进程规则、图标、外观和 harvest 协议门禁通过。
- Debug / Release build、资源 selftest、完整 harvest 测试和 ad-hoc 签名验证通过。
- 本版本仍为未签名、未公证 macOS DMG；其他 Mac 可能触发 Gatekeeper。

## 0.47.4 — 采集连续性与权限提示修复

### 可观测性与稳定性

- 部分采集超时不再清空尚未完成的 Agent；已返回的 Agent 更新，未到达的 Agent 保留上一份有效观测，避免 Command Code、Cursor、Amp 等会话短暂消失。
- 忽略异常的未来时间戳，避免错误的 hook 事件把 Waiting 状态永久挂起。
- 修复状态摘要为空时产生多余分隔符的问题。

### 隐私与权限

- 通知权限改为仅在用户点击“启用通知”后请求，启动、后台扫描和发送通知不会再触发权限弹窗。
- hook 写入磁盘前对 Token、密码、私钥、认证 URL、路径和 TSV 控制字符做清洗与长度限制。
- 移除内容脱敏规则的强制正则崩溃风险。

### 验证

- 31 个 Agent collector、支持矩阵、32 条进程规则、图标、外观和 harvest 协议门禁通过。
- Release build、打包资源 selftest、完整 harvest 测试和 ad-hoc 签名验证通过。
- 本版本仍为未签名、未公证 macOS DMG；其他 Mac 可能触发 Gatekeeper。

## 0.47.3 — 观测入口与能力信号修复

### 可观测性与交互

- Process-only 行改用橙色 Limited 状态灯，避免把“检测到进程”误读为“会话数据完整”。
- Process-only 行增加支持健康度入口；不再出现悬停后打开空操作菜单的情况。
- 未知 tool / skill 不再静默丢失：默认行只展示经过清洗的安全叶子名称，避免暴露路径、namespace 或敏感文本。
- VoiceOver 的支持覆盖统计改用与视觉界面一致的有效信号分母。

## 0.47.2 — 观测语义与发布一致性修复

### 可观测性与交互

- 支持健康度默认先展示本机已有有效证据；“全部”仍可查看完整覆盖名单，未观测 Agent 不再淹没首屏。
- 受保护应用数据未开启时明确标注“隐私受限”，并提供进入设置的入口，不再把隐私策略误报成不支持。
- Waiting 文案区分“等待通路”和“信号是否就绪”，避免 `Waiting via hooks` 与缺失信号产生歧义。
- tool 只在能表达用户可理解阶段时进入默认行；未知 skill 包名留在诊断层，明确映射到工作流角色的调用才展示。

### 稳定性与发布

- 统一系统探测、hooks 安装和登录项操作的子进程管道双向排空与超时保护，避免异常 stdout/stderr 阻塞扫描或设置操作。
- 重新构建本地安装包并以当前提交写入构建指纹，避免版本号正确但实际运行旧提交。

## 0.47.1 — 启动隐私与托盘可用性修复

### 稳定性与权限

- 修复启动时扫描受保护应用数据、Spotlight 元数据和默认全局快捷键导致的 macOS 权限弹窗；默认只读取进程、hooks、工作区和安全的本地会话证据。
- 深度读取 Cursor / VS Code / Warp 等应用数据改为设置中的明确 opt-in，快捷键也改为 opt-in，旧版本配置不会在升级后静默注册。
- 安装副本诊断改用仅针对 Pulse 自身 bundle ID 的 LaunchServices 查询，保留重复 App 安全清理能力，不枚举其他应用。

### 托盘交互

- 修复 `ps` 输出管道在主线程等待导致的托盘永久卡死；下拉面板可正常打开、滚动和捕获。
- 保持单一原生面板表面，避免上下长条、蓝色焦点线和四角伪影。

### 验证与发布

- 31 个 Agent 接线、支持矩阵、图标、外观和 harvest 协议门禁通过；真实打包 selftest 和托盘截图验证通过。
- 本版本为未签名、未公证 macOS DMG；其他 Mac 可能触发 Gatekeeper。

## 0.47.0 — 托盘稳定性与视觉精修

### 可观测性与交互效率

- 默认托盘行新增红 / 绿 / 灰 / 橙状态灯，Agent 名称、分组标题和状态列保持对齐。
- 部分采集不再清空尚未返回的 Agent 健康结果，并明确显示扫描未完成提示。
- 未来时间戳不再被误判为新鲜活动；31 个覆盖 Agent 继续输出完整采集健康结果。

### 稳定性与隐私

- `lsof` 权限失败进入有界退避，避免反复触发跨应用权限请求。
- 安装副本诊断改为后台、节流执行，并修复大进程列表导致的管道死锁。
- 托盘面板改用稳定的原生菜单栏材质，消除上下长条、四角白斑和异常灰色背景。

### 验证与发布

- 31 个 Agent 接线、支持矩阵、图标、外观和 harvest 协议门禁通过。
- Release build、采集测试、资源 selftest 和实际浅色 / 深色托盘截图验证通过。
- 本版本为未签名、未公证 macOS DMG；其他 Mac 可能触发 Gatekeeper。

## 0.46.0 — 支持健康度完整呈现

### 可观测性与交互效率

- 支持健康页顶部汇总新增“尚未观测”数量，避免把未检测到误解为不支持。
- 支持健康页新增“尚未观测”筛选，可快速定位当前没有本机会话证据的 Agent。
- 中英文状态、分段筛选和摘要保持一致，31 个覆盖 Agent 的状态分类完整闭环。

### 工程维护

- 更新 Agent handoff 文档中的当前版本信息，避免后续 review 依据过期版本判断。

## 0.45.0 — 全 Agent 采集与工具语义修复

### 可观测性与稳定性

- 修复 `agy` / Antigravity 进程识别，并补齐别名映射与回归保护。
- Command Code 优先读取 transcript 的真实工作目录；不再把存储目录名当成项目。
- 将记录扫描预算隔离到每个 Agent，避免大体量 Codex 日志耗尽预算后静默丢失后续 Agent 数据。
- Warp 接入 App Group SQLite，补齐会话目标、工作目录、模型、工具、状态和任务事实。
- Grok 在 active-session 索引滞后时，从近期 session summary 安全恢复；过期记录仍不会冒充运行中。
- 移除启动和刷新路径中的跨应用进程枚举，Warp 状态改用 `ps` 证据，避免 macOS 反复弹出 Apple Events /“访问其他 App 数据”权限提示。

### Tool / Skill 语义

- 将明确的 tool / skill 调用转换为 Research、Build、Test、Edit、Publish 等可读阶段。
- 保留工具调用的历史语义，不把内部 skill 包名或工具名误报成当前正在执行的动作。
- 新增 Command Code、Warp、Grok、agy、skill 语义和 Cursor worker 的回归门禁。

### 验证与发布

- 31 个 Agent collector、支持矩阵、图标、外观和 24 列 harvest 协议门禁通过。
- Swift release build、应用资源 selftest、ad-hoc 签名和 DMG 打包通过。
- 本版本使用未签名、未公证 macOS DMG；其他 Mac 可能触发 Gatekeeper。

## 0.44.1 — Command Code 进程与会话采集修复

### 可观测性与稳定性

- 修复 Node agent 改写进程标题后无法被检测的问题；Command Code 的 `⌘ Command Code` 标题现在与可执行文件路径共同参与识别。
- Command Code 会话改为头尾有界读取，保留首条用户目标和最新运行事实，不再把 `web_fetch` 等工具结果误当作任务标题。
- 过滤 `role=user` 中的工具结果，并将真实用户请求、最近动作、模型和工作区信息接入默认展示。
- 将同类 JSONL agent 采集器统一为头尾读取与用户目标降级策略，避免长会话只剩工具名或空白占位。

### 验证与发布

- 31 个 Agent collector、支持矩阵、图标、外观和 24 列 harvest 协议门禁通过。
- Swift release build、应用资源 selftest、未签名 DMG 打包和真实托盘截图回归通过。
- 本版本使用未签名、未公证 macOS DMG；需要在其他 Mac 上运行时可能触发 Gatekeeper。

## 0.44.0 — 首屏 Agent 目标与运行事实优化

### 可观测性与交互效率

- Pi 从嵌套 `message.content` 提取最新用户目标，避免长期显示 `pi update` 等无意义命令；维护类命令改为可扫描的目标描述。
- Codex 等 Agent 的新鲜 `reading` / `working` 阶段进入默认行，首屏同时保留当前阶段、上下文占用和模型事实。
- 当 Agent 只提供通用 shell 工具时，默认行明确显示 `Last action: Terminal command`，并与模型、token、事件数量按优先级组合。
- 有结构化事件记录但缺少模型或阶段的 Agent，默认行补充事件量；没有数据的字段仍明确保持未知，不伪造事实。

### 验证与发布

- 31 个 Agent collector、支持矩阵、图标、外观和 24 列 harvest 协议门禁通过。
- Swift release build、应用资源 selftest、未签名 DMG 打包和真实托盘截图回归通过。
- 本版本使用未签名、未公证 macOS DMG；需要在其他 Mac 上运行时可能触发 Gatekeeper。

## 0.43.0 — Codex / OpenCode 运行事实与缓存误报修复

### 可观测性与稳定性

- Codex 复用已解析的 rollout 记录，并限制阶段回放窗口，避免会话增长后超过采集保护阈值而整类消失。
- Antigravity 不再把 VS Code schema、walkthrough 和索引缓存当作 Agent 会话；无真实会话时明确显示无会话。
- OpenCode 补充模型、最近工具、阶段、结果和 part 记录数，并兼容旧版 SQLite schema。
- 端到端 fixture 新增 OpenCode 运行事实断言，避免能力只存在于本地实现而没有协议保障。

### 验证

- 31 个 Agent 接线、支持矩阵、图标、外观和 24 列 harvest 协议门禁通过。
- Release build、打包资源 selftest、真实采集和托盘/支持健康页视觉回归通过。
- 本版本继续使用未签名、未公证 macOS DMG。

## 0.42.0 — 全 Agent 观测信号与采集稳定性

### 可观测性与稳定性

- Cursor 兼容秒、毫秒、微秒和 ISO 时间字段，避免时间格式变化导致并发会话全部消失。
- Pi、Gemini、Copilot、Amazon Q 等会话补充可确认的模型、token 和运行时事实；配置/索引文件不再冒充会话。
- 支持健康页新增最近动作、模型、资源信号的真实可用性，明确区分“未提供”和“未检测到”。
- 将适配器读取时间与会话最后活动时间分离，避免把旧会话误报成采集失败。

### 交互与视觉

- 修复托盘 QA 捕获在 macOS 26 上触发布局异常的问题。
- 重新验证单一圆角面板、四角、上下边界和支持健康页布局。

### 验证

- 31 个 Agent 采集门禁、24 列协议、31 个端到端 fixture、覆盖矩阵、图标和外观门禁通过。
- Release build、打包资源 selftest 和视觉截图验证通过；本版本为未签名、未公证 macOS DMG。

## 0.41.2 — 动作语义与进程观测优化

### 可观测性与稳定性

- 将 test、build、deploy、publish 等工具调用映射为可读的最近动作，避免只显示宽泛阶段。
- Process-only 支持详情显示进程运行时长与数量；停滞/动态会话不再重复低价值的开始时间。
- 仅有 transcript 事件数量的泛化会话不再被当作有效会话，减少无意义行。
- 31 个 Agent 的结构化会话、缓存降级和进程 fallback 继续保持明确的证据边界。

### 验证

- 31 个 Agent 采集门禁、24 列协议、31 个端到端 fixture、覆盖矩阵、图标和外观门禁通过。
- Release build、打包资源 selftest 通过；本版本为未签名、未公证 macOS DMG。

## 0.41.1 — 信息信号与 Agent 支持度修复

### 可观测性与稳定性

- 进程-only 会话明确展示活动数据边界与进程运行时长；停滞会展示无活动时长，不再伪装成正常运行。
- 最近会话保留最近一次可读动作；没有动态字段时明确显示暂无执行进展信号，避免空白行造成误判。
- 支持健康度不再把 transcript 事件数量当作执行进展；Cursor Agent 与 Cursor 的合并来源统一进入详情与评分。
- 支持详情优先展示目标、工作区、阶段、动作、模型、进度、错误、文件、上下文和 token 等有效事实。

### 验证

- 31 个 Agent 采集门禁、24 列协议、31 个端到端 fixture、覆盖矩阵、图标和外观门禁全部通过。
- Release build、打包资源 selftest 通过；当前包为未签名、未公证的 macOS DMG。

## 0.41.0 — 全 Agent 可观测性与托盘密度优化

### 可观测性与稳定性

- harvest-only 会话不再伪造进程数；同一 Agent 的其他会话也不再继承不属于它们的进程计数。
- Gemini JSONL 读取完整记录；Continue、Copilot、Amazon Q、Zed、OpenHands、Warp、Droid、Command Code、Kimi、Goose 等适配器统一补充可确认的阶段、模型、模式、错误、文件与进度事实。
- 裸的 Agent 名称、`Agent session`、`Command Code` 等适配器占位标题不再冒充用户任务；没有稳定本地会话协议的 Agent 继续明确标注为有限数据。
- 新增结构化 outcome 与跨 snake/camel case token 字段解析，并保持未知数据不猜测。

### 交互与精致度

- 默认行将 Now、变化、指标和模型/模式上下文收敛为一条 bounded signal line，去除重复进度并提升扫描效率。
- 默认托盘视口扩大，等待、运行、停滞和 Recent 混合场景不再把最后一行截断；仍保留滚动与“显示更多”路径。
- 裸 Agent 名称不再作为会话标题显示；浅色/深色主题继续使用单一圆角面板，无上下长条或蓝色焦点线。

### 验证

- 31 个 Agent 采集门禁、24 列协议、31 个端到端 fixture、覆盖矩阵、图标和外观门禁全部通过。
- Debug / Release Swift build 通过；本地 Command Line Tools 缺少 XCTest 模块，单元测试需在完整 Xcode runner 执行。

## 0.40.0 — 观测语义与交互可靠性修复

### 可观测性

- Codex rollout 现在读取真实模型与上下文窗口占用，托盘默认展示模型、Context 使用率和最近一轮 token，
  不再把高价值运行事实留在诊断层。
- Codex Desktop 的转义 shell 调用按 Reading、Testing、Building、Editing、Publishing 等语义阶段展示；
  `write_stdin`、`latest` 等工具名不再因子串匹配被误判。
- 31 个 Agent 的支持健康评分按实际能力计分；没有 Waiting 协议的 Agent 按 4 项适用信号评估，
  不再因不存在的能力被降级。

### 交互与精致度

- 每行更多操作菜单与整行聚焦动作解耦，避免点击“…”误触主动作，并保持键盘与 VoiceOver 路径可用。
- 保持单一圆角面板、无上下长条、默认展开和原始 tool/skill 名称不进入主界面的信息架构。

### 验证

- 31 个 collector fixture、32 个 Agent 图标、覆盖矩阵、外观门禁和打包资源自检全部通过。
- 当前 macOS Command Line Tools 环境缺少 XCTest 模块，Swift 单元测试需在完整 Xcode runner 上执行。

## 0.39.0 — 每个 Agent 都有可解释的执行信号

### 可观测性

- 托盘指标从“只取一个最强字段”改为同一行展示两个互补信号；进度、错误、文件、上下文、
  subagent、记录数和 token 不再互相覆盖。
- 支持健康页默认展示全部覆盖的 Agent，并在五项能力评分下直接列出实际观测到的任务、工作区、
  阶段、模型、模式、进度和资源信号；“progress”改成准确的“execution signal”，避免把工具调用
  误解成百分比进度。
- skill 只展示可读的叶子名称，原始命名空间不占用托盘空间；tool 仍只在能表达工作阶段时进入默认行。
- 相邻扫描的变化判断不再依赖严格递增的文件 mtime；供应商以秒级时间戳写入时，进度、模型、记录或
  subagent 变化仍会被标记。

### 稳定性与精致度

- SwiftPM 调试可执行文件不在 `.app` 包内时跳过 UserNotifications 初始化，避免打开设置/视觉 QA 直接
  因 `bundleProxyForCurrentProcess` 异常崩溃；正式 app 仍完整使用通知能力。
- 维持统一的图标基线、无顶部/底部长条和单一圆角表面；支持健康信息在默认视图中不再被折叠到诊断
  disclosure 后面。

## 0.38.0 — 观测的是变化，不是缓存里碰巧存在的字段

### 安全边界

- Agent 标题、工作区、Waiting 消息与生命周期字段在 Python 输出和 Swift 输入两端脱敏；
  菜单栏、托盘、通知、VoiceOver 与安全支持报告不会展示 credential-shaped 内容。API key、
  Bearer token、GitHub/Slack/AWS 凭据、URL 用户信息、SSH identity path 与 PEM 私钥均有
  正负例门禁，普通的 token budget、UUID 和技术文本不被误伤。
- 支持窗口新增可预览、可复制的安全报告，只包含版本、系统、适配器状态、证据等级和能力
  布尔值；不包含 prompt、完整路径、session id、命令行、tool payload 或 skill 包名。

### 有效信息与会话语义

- 默认行不再展示只重复运行状态的 `Now · Working`；`Local` 不再占一行当作 Cursor 的
  有效信息。会话创建时间只在前 24 小时帮助定向，数百小时的历史时间不再伪装成运行时长；
  进程年龄继续只用于诚实的 process-only 行。
- 同一会话在相邻扫描之间比较 outcome、错误、任务进度、文件数与模型调用；真实变化会以
  “刚刚变化”出现并保留三分钟，面板不再只是静态计数器。敏感内容同样经过可访问性边界。
- 单一未知工作区不再额外占一行分组标题；所有标题、图标、状态 chip 和右上角操作继续使用
  统一基线与固定命中区域。

### 31 个 Agent 的支持质量

- Agent 支持健康从“问题”混合桶拆为四种结果：需要处理（红）、信息受限（橙）、观测健康
  （绿）、尚未观测（灰）。缺少 Claude/Codex hooks 可直接安装，适配器权限、格式或超时
  问题可直接重试；不可由用户修复的数据缺口不再伪装成错误。
- 每个 Agent 以目标、工作区、活动、进度、Waiting 路由五个有用信号计分；原始 adapter
  行数和耗时收进诊断 disclosure，默认层先回答“能看到什么、缺什么、能否修复”。
- 31 个 source-shaped 真实 collector fixture 全部必须产出基线之外的适配器专属信息；
  任何 Agent 只剩 process detection 或 title/path 都会使 CI 失败。新增 cache 偏好与通用
  placeholder 负例，防止配置文件冒充会话。
- 通用 session 路径采集器现在保留结构化 phase/model/mode/progress、记录数和创建时间，
  Aider 也把聊天历史作为真实会话统计；Pi 与 cache adapter 的契约和实际字段重新对齐。
- 每个适配器增加独立校准的截止时间：普通缓存源 800 ms，Codex/Cursor/Aider 的有界
  transcript、SQLite 与 Spotlight 冷路径使用更宽预算；一个私有数据库锁死或目录异常
  不会吞掉后续 Agent，已完成的部分仍通过现有流式协议保留。

### 界面与验证

- 支持窗口默认按“需要处理 / 信息受限 / 观测健康 / 全部”筛选，窗口高度随有效内容收紧，
  adapter 诊断按需展开；通知权限被拒绝时，禁用开关改用灰色而不是继续像蓝色已开启。
- 新增变化保留、五信号健康分级、修复动作、敏感内容边界、31 份质量计分卡及适配器负例
  回归；浅色/深色、中英文、紧凑/拥挤、支持健康和四态状态灯继续进入视觉验收矩阵。

## 0.37.0 — 活着的进程不再复活陈旧会话

- 同一 Agent 的常驻进程不再给全部未完成历史会话续命：只要有新鲜会话，陈旧兄弟记录
  全部退出面板；只有完全没有新鲜记录时，才按工作区匹配与最近活动保留一个可解释的
  陈旧上下文。数百小时前的 Codex rollout 不会再挤掉当前任务。
- Python 采集预算提升到每 Agent 64 条，Swift 模型安全容量保持 32 条、面板全局默认
  展示 8 条；第 33–64 条会被精确计入“未显示”，采集容量、模型容量与视觉密度不再混为一谈。
- Agent 支持健康度以目标、工作区、活动、证据四项作为统一核心事实；进度是有则增强的
  观测信息，不再被误算成每个 Agent 都必须具备的支持能力。没有 Waiting 协议的 Agent
  也不会永久显示为信息缺陷。
- “适配器错误”和“信息缺口”分别计数，问题筛选显示真实总数；每个 Agent 行直接展示
  证据等级、采集结果、三项事实、4 项覆盖计数、Waiting 路由与最近读取时间，缺失项
  用明确文案说明，不再压成一行模糊灰字。
- Preferences 删除重复的实时状态卡，Agent 支持健康度进入关于区；设置页只保留配置，
  实时观测回到 Tray 与独立支持窗口。
- 四态菜单栏灯增加浅色、深色及高对比外观的像素级回归；红、绿、灰、橙在不同系统
  外观下都必须保持可见、互异且不退化为模板单色。
- 新增 40 会话、单一陈旧 fallback、当前会话压制数百小时旧会话、Waiting 能力条件化
  与四项核心事实回归测试；31 个真实 collector fixture 继续逐一验证有用信息契约。

## 0.36.2 — 展示密度不是检测上限

- Cursor 不再在采集到第二个会话后停止；本地 `composerHeaders` 与 Cursor Cloud Agent
  仓库合并、按 session id 去重，并分别保留明确的运行/完成语义、模型、仓库、上下文占用
  与文件变化。当前真实 Cursor 状态可同时产出本地和云会话。
- 每个 Agent 的模型安全容量从 4 提升到 32；面板仍在全局 8 行后折叠，展开后可查看
  第 9 条以后。默认视觉密度不再偷偷决定采集容量。
- Claude、Codex、Amp、Gemini、OpenCode、Copilot、Continue、Aider、Goose、Cline、
  Roo、Kilo、Cascade/Windsurf、Kiro、Droid、Kimi 等采集器移除散落的两条硬上限；
  Grok 与 Pi 从只读取第一条会话改为输出多会话。
- VS Code 系 Agent 的共享 JSON 缓存从“选一个得分最高的嵌套对象”改为按真实 session id
  提取多个独立会话；配置、主题和普通 checklist 项仍不能冒充会话。
- 端到端门禁新增 6 个并发 Cursor 本地会话、Cursor Cloud 运行会话、单文件 6 会话
  及 Python/Swift 容量一致性回归，防止以后再次出现 4→2 或第 5 条静默消失。

## 0.36.1 — 窗口只有一个形状

- 关闭仍按矩形合成的 WindowServer borderless-window 阴影，改为在透明窗口内用与材质
  完全相同的圆角路径绘制阴影；浅色桌面上不再出现四个矩形白色尖角。
- 视觉回归截图从只截内部材质层改为包含 AppKit 窗口根视图，外层 frame 的裁剪异常
  不会再被一张“内部正常”的截图掩盖。
- Agent 任务标题中的 Markdown 链接只展示可读标签，保留其余句子和原始观测数据；
  `[hxddh/Pulse](https://github.com/hxddh/Pulse)` 不再占用整行观测空间。
- 超长 Codex rollout 改为有界反向寻找最近的实质用户目标；即使最近一次工具输出超过
  旧的 4 MB tail，也不会重新显示数十小时前的会话开场任务。

## 0.36.0 — 支持不是“读不到”，而是能解释为什么

这一版完成 0.35 后续的 P0、P1、P2：运行版本必须可信，适配器无数据必须可诊断，
旧会话不能依附常驻进程无限存活；更新、Waiting 连接和 32 个 Agent 的本机支持情况
都有可以操作和验证的结果。

### 运行版本、安装副本与可验证更新

- 关于页同时展示编译版本、构建指纹和**实际运行路径**；扫描 `/Applications`、
  `~/Applications` 及同 bundle id 的运行进程，明确列出重复 Pulse.app 和仍在运行的旧副本。
- 重复副本只在用户确认后移入废纸篓；当前运行应用和仍在运行的其他副本不会被删除，
  打包、更新和安装流程也不再创建历史应用备份。
- 更新检查读取 Release 的 DMG、字节数和 SHA-256；应用下载后先校验大小与哈希，
  通过才打开安装包。未签名阶段仍不静默覆盖当前应用。
- 托盘仅在版本不一致、另有运行副本或确有更新时显示一条可操作维护提示；
  正常状态继续保持安静。Release workflow 自动把 DMG SHA-256 写进发布说明。

### 每个 Agent 都有可解释的运行时健康

- 31 个采集器将笼统的 `no recent data` 拆成 `source absent / no usable session /
  permission denied / data format changed / failed / unscanned`；每项同时报告数据源是否存在、
  读取耗时与有效行数，仍不暴露路径、命令行、会话内容或异常消息。
- 进程探测只保留“可执行程序命中 / 路径特征命中”两种隐私安全证据；支持窗口展示
  目标、工作区、活动、Waiting 四项核心信息完整度和最近一次读取/Waiting 信号时间。
- 支持健康窗口新增“问题 / 运行中 / 已安装 / 无数据 / 全部”筛选并按问题优先排序；
  红、绿、橙、灰小灯分别表达适配器异常、正在运行、数据源存在但信息不足、未发现来源。
- Claude/Codex Waiting 增加隔离式连接自检：真实执行随包发布的 hook 并验证输出，
  但写入临时目录，不制造假 Waiting，也不触发 Automation、Accessibility 或录屏权限。

### 会话生命周期与观测语义

- 已完成且超过近期窗口的会话不再因同 Agent CLI 常驻而永久留在 Recent；
  过期完成记录被丢弃，仍活着的 CLI 诚实降级为仅进程行。
- 同 Agent 多会话绑定 live 进程时优先未完成会话，再比较活动时间；旧完成会话不能
  抢走当前进程证据。失败和取消作为 `Outcome` 展示，不伪装成当前阶段。
- 原始 tool、MCP server、命令参数、skill/package/script 名继续留在诊断层；
  默认行只展示由显式生命周期和未完成调用映射出的 Planning、Reading、Researching、
  Editing、Testing、Building、Publishing、Responding、Waiting 和 Outcome。

### 交互与质量门

- 键盘选择继续使用自定义圆角行高亮并自动滚入可视区，保留无蓝色系统焦点框的修复；
  覆盖窗口、设置页和托盘都增加无需系统权限的应用内截图入口用于视觉回归。
- Harvest 门禁验证新的七列健康协议、数据源存在性、格式异常分类和全部 31 个
  端到端 collector fixture；Swift 测试补充更新元数据、进程证据和陈旧完成会话回归。

## 0.35.1 — 键盘可用，不等于把焦点框画进面板

- 保留托盘列表的方向键、空格与回车操作，但关闭 ScrollView 的系统 focus effect；
  圆角面板不再把蓝色焦点框裁成 Header 下方横线和左右边缘碎片。
- 状态栏图标恢复红、绿、灰、橙四态；状态色直接写入图标像素，文字仍由系统按菜单栏
  明暗自适应，不再在“彩色但可能黑底消失”和“可见但完全无状态色”之间二选一。
- 外观门禁新增焦点效果检查，防止以后恢复键盘导航时再次带回这条伪分隔线。

## 0.35.0 — 支持度必须在运行时可证明

这一版不再把“代码里有适配器”当成支持完成。Pulse 在同一轮采集里记录每个 Agent
适配器究竟读到了会话、正常完成但暂无近期数据、解析失败，还是因超时没有执行完成；
覆盖声明和本机运行事实从此是两层不同的证据。

### 适配器运行健康与覆盖界面

- 31 个采集器逐项输出 `observed / no recent data / failed / unscanned`、耗时和有效行数；
  单项异常仅展示异常类型，不暴露供应商路径、会话内容或错误消息，也不增加第二轮磁盘扫描。
- Cursor Agent 与 Cursor 的合并会话共享同一采集器健康结果，因此 32 个 Agent 身份都有
  可解释的运行状态；超时只把尚未回报的后续适配器标为未完成，不抹掉先完成的证据。
- 将支持健康度从 Preferences 的长 Disclosure 拆为独立、可搜索的 Agent 覆盖窗口；
  Preferences 恢复为偏好选择，覆盖窗口直接展示证据等级、目标、工作区、活动、
  Waiting 来源和缺失能力。

### 当前状态、结果与扫描效率

- `Now` 只用于仍活跃的会话；已结束的 `Turn complete` 改为 `Outcome`，Recent 行不再出现
  “当前 · 本轮已完成”的语义矛盾。
- Header 的 Needs you、Running、Stalled、Recent 分段着色；一个等待不再把全部状态计数
  染成红色。滚动内容增加边界提示，键盘上下选择会自动把目标行带入可视区域。
- 对通用命令只从结构化参数映射高置信角色：Testing、Building、Publishing、Reading；
  原始命令、tool 名、skill 名和参数仍不进入默认界面。

## 0.34.0 — 支持不是名单，而是本机上可验证的观测

这一版把此前评估中的 P0、P1、P2 一次收口：状态计数必须诚实，任意路径启动只能有
一个 Pulse，31 个采集器都要经过真实磁盘输入，默认行必须区分“当前阶段”和“历史动作”，
发布物必须具备可验证的 Developer ID / 公证链路。

### 四态、分组与单实例

- 将停滞从 Running 中拆出为独立 Stalled 状态；Header、分组和全量计数统一使用
  Needs you / Active / Stalled / Recent 四态，停滞会话不再抬高健康运行数。
- 按项目分组时明确展示“工作区未知”表头；无 cwd 的 Pi、Amp 等不再视觉上挂到前一个项目。
- 新增跨 bundle 路径的 BSD 进程锁；`/Applications/Pulse.app` 与开发打包副本同时启动时，
  后启动者只激活现有副本，不再制造两个状态栏图标、两套扫描与通知。

### 默认信息层级与支持健康度

- 增加严格的 `Now` 层，只接受显式生命周期事件或尚未收到结果的工具调用；
  已完成工具保留为“最近动作”，不得伪装成当前仍在执行。
- 每行只选一个最强进度事实；模型、模式与会话年龄降为次级上下文。拥挤面板保留
  Agent、目标、Now、位置/时间和进度，压缩次级信息而不是隐藏整个会话。
- 正常结构化会话不再重复显示无信息量的 `Session`；仅缓存和仅进程仍明确标注证据降级。
- 偏好设置新增 Agent 支持健康度：对 32 个 Agent 展示本机实际检测、证据级别、
  最近成功读取、目标/工作区/活动可用性、Waiting 来源与缺失能力。
- 无原生 Waiting 路径的 Trae、Warp、Antigravity、Devin、Junie、Replit 在运行行和
  支持健康度中明确说明限制，不再把“能检测进程”包装成完整可观测。

### 31 个采集器与发布质量门

- Harvest 门禁从 5 个扩到全部 31 个端到端磁盘 fixture；每个 fixture 都经过真实路径、
  真实 collector、统一 row shaping 和 24 列 TSV。扩展过程中修复 Kimi collector
  调用 `session_stats` 时缺失参数、会导致整项失效的真实问题。
- Claude、Codex、Pi 从有序事件读取 Planning / Reading / Researching / Editing /
  Testing / Responding / Waiting / Turn complete；工具结果会清除未完成工具阶段，
  防止最后一次旧工具长期霸占 `Now`。
- 新增 compact / crowded 的真实 TrayPanel 视觉 fixture，以及四态计数、停滞归类、
  单实例回收和语义阶段回归测试；恢复原生键盘焦点，并在状态变化时发送 VoiceOver 公告。
- 发布 workflow 改为强制导入 Developer ID 证书与 App Store Connect API key；
  App 和 DMG 分别公证、staple、validate，并以 `spctl` 验收。缺少任一发布凭据时拒绝
  继续发布 ad-hoc 构建。

## 0.33.1 — 看见的数量，必须就是实际的数量

- 项目和 Recent 分组默认完整展开；折叠只在用户主动操作后发生，避免标题显示多个
  Agent、默认列表却只露出一行。
- 修复 Pi 等短命令被通用防误报规则误伤的问题；Pi、Roo 和 Command Code 使用
  精确命令名白名单，并继续排除 pip、pihole、droidcam、系统 AMP 服务等误报。
- 新增覆盖全部 32 个 Agent 的进程检测契约，任何已声明支持的 Agent 都必须有一个
  可验证的真实进程签名。
- 按图标实际可见像素统一光学尺寸和中心，不再用各品牌文件不一致的透明画布对齐；
  Pi、Amazon Q、Droid、Grok 等大小和垂直位置差异得到统一。
- 统一弹窗的 16 pt 外边距、分组披露列、18 pt Agent 图标列和 28 pt 顶部操作按钮；
  标题、刷新、更多、分组文字、Agent 名称及其详情分别落在稳定的对齐网格上。

## 0.33.0 — 支持 Agent，必须能解释它在做什么

“检测到一个进程”不是可观测性；内部工具名、skill 路径和最后一条错误也不是任务。
这一版把 31 个 Agent 的支持从一张名单改成逐 Agent 能力合同，并扩展统一行协议，
让默认界面优先回答目标、阶段、进展、结果与阻塞。

### 丰富信息成为统一协议

- Harvest TSV 从 15 列扩展到 24 列，新增阶段、结果、模型、Agent 模式、失败数、
  涉及文件、上下文占用和进度；Swift 合并层与默认行视图完整承接这些事实。
- VS Code 系缓存适配只在合格的 session/thread/conversation 对象内提取丰富字段；
  profile、theme、模型偏好等配置对象仍被拒绝，缺失值保持未知。
- 增加 31 Agent 可观测能力合同与逐项文档；门禁要求每个 Agent 至少具备目标、
  工作区、活动时间和证据等级，不允许用 process-only 冒充完整支持。

### 修复真实 Agent 的错误语义

- Grok 使用 `generated_title/session_summary` 作为任务，读取 lifecycle events、
  signals 和 summary 中的阶段、结果、模型、模式、失败、文件、上下文和轮次；
  tool error/tool result 不再抢占任务标题。
- Amp 跳过“继续 / continue / go on”等延续词，向后寻找最近一个实质目标，并展示
  Agent mode；长期运行但会话文件暂未更新时，已知目标和工作区不再被提前丢弃。
- skill 只接受明确的 Skill 调用；`skills/.../scripts/preflight.py` 这类内部路径不再
  被误认成用户可理解的能力。

### 默认界面只展示能提高判断效率的事实

- 结构化阶段优先于 raw tool；默认行展示 Planning、Reading、Researching、Editing、
  Testing、Responding、Waiting for permission、Turn complete 等人类语义。
- `exec`、`run_terminal_command`、`bash` 等通用命令被降为诊断信息；具体失败数、
  文件数、进度、结果、模型和上下文占用优先显示。
- 原始 skill/package/script 名不进入默认行。只有 Agent 明确记录、且能表达用户可识别
  工作流角色的 skill 才有展示价值。

## 0.32.1 — 状态灯必须先看得见

0.32.0 把菜单栏从 SwiftUI `MenuBarExtra` 换成原生 `NSStatusItem`，却继续把
交通灯颜色强制写进 `NSStatusBarButton.contentTintColor`。这个属性会同时染模板图和标题，
而状态按钮的菜单栏外观不一定等于应用窗口外观；在深色菜单栏上因此可能解析成黑色，
主入口直接消失。

- 删除状态按钮的强制 tint，让 AppKit 在菜单栏自己的 effective appearance 中逐次解析
  template 图标与标题，恢复深浅菜单栏的原生对比度。
- Waiting / Running / Idle 不再只依赖颜色区分，分别使用暂停形、实心灯和脉冲线；
  短标题与 VoiceOver 标签继续提供文字语义。
- 新增 `--capture-status-item` QA 入口，直接捕获本进程实际的 `NSStatusBarButton`，
  无需 Screen Recording、Accessibility、Apple Events 或 UI 自动化权限。
- 外观门禁拒绝再次给原生状态项写入非空 `contentTintColor`。

## 0.32.0 — 观测必须有来源，动作必须完成任务

0.31.0 让 `MenuBarExtra` 独占材质，却没有移除它根视图之外的系统 content inset；
因此上下长条仍然存在。它也保留了「打开目录」作为无 Focus 句柄时的替代动作，
而 Finder 既不能恢复 Agent 会话，也不能提高响应效率。这一版从窗口承载、动作语义和
最低观测能力三层一起收敛。

### 上下长条从视图层级消失

- 用应用自有的原生状态项和无边框 `NSPanel` 替换 `MenuBarExtra(.window)`；
  单个 `NSVisualEffectView(.popover)` 四边贴合内容，窗口与内容不再各有一层表面或 inset。
- 快捷键与通知直接调用应用内面板控制器，不再通过辅助功能 API 点击状态栏；
  唤出面板不需要 Accessibility / Automation 权限，也不存在失败后的反复授权请求。
- 状态项仍保留动态灯色、短标题、tooltip 与 VoiceOver 标签；托盘继续使用同一个
  `TrayPanel`，不是为了截图另做一套界面。

### 删除不能完成用户任务的动作

- 删除「打开目录」及 `canOpenFolder/pathExists/openProject` 整条运行时路径。
  cwd 仍用于定位和区分会话，但不再把切到 Finder 包装成处理 Agent 的动作。
- 整行只有在确实能聚焦 Warp 时才是按钮；其他行保持为可读的观测内容。
  Waiting 的忽略与稍后仍是明确的行内动作。
- 无法聚焦的通知与全局快捷键打开 Pulse 面板，让用户看到原因和上下文，而不是静默失败
  或跳到一个不能恢复会话的目录。

### 所有覆盖 Agent 都有明确的最低信息合同

- 每一行都明确显示「结构化会话 / 本地缓存 / 仅进程」，不再让无标签的 Codex 行与
  缓存猜测看起来同样可信。
- ProcessProbe 对匹配到的 CLI 进程做一次有界 cwd 读取；没有可读会话存储时，
  仍可展示 Agent、真实工作区、进程启动时长和“暂无活动数据”，不显示内部进程数。
- VS Code 系 agent 的缓存适配从“只看根对象/最后一个数组项”升级为有界嵌套 session
  遍历，能读取 `state.sessions/conversations/tasks/composers` 里的任务、工作区和 id。
  profile、model、theme 的任意 `name/title` 被明确拒绝，避免用配置噪音填充界面。
- 会话开始时间与 token / subagent / 事件数合并为一条最多四事实的观测行；
  有数据才出现，信息更丰富但不再为一个时长单独增加第五行。

## 0.31.0 — 支持名单必须等于可解释的观测

0.30.0 仍把系统弹窗和内容材质叠在一起，上、下 inset 因而露成两条长条；
同时支持矩阵把“能搜索到一些本地文件”继续写成了结构化会话。
这版把两个问题都改成运行时契约，不再依靠界面补丁或静态宣传。

### 一个弹窗只由一个表面负责

- `MenuBarExtra(.window)` 成为唯一材质所有者，内容根视图保持透明；
  删除只覆盖内容测量范围的矩形 `.thickMaterial`，从构造上消除上下第二表面。
- 托盘宽度调整为 420pt，Agent 身份、任务、上下文、时间与观测事实改为纵向层级；
  标题不再与开始时间、状态芯片和更多菜单争抢同一行。
- 32 个 Agent 都显示文字身份，不再要求用户靠图标猜产品；更多菜单只在悬停或键盘选中时显形，
  VoiceOver 动作仍始终可用。

### 31 个采集器逐行声明证据

- harvest TSV 新增第 15 列，每一行明确标为 `session` 或 `cache`，
  Swift 合并后继续保留该等级；无 harvest 时明确降为 `process`。
- 16 个读取 transcript / thread / composer / session database 的适配器标为结构化会话；
  其余 15 个依赖 IDE 私有状态或可变缓存的适配器降为 Best effort cache，
  README 与代码门禁同步纠正。
- 缓存只有扩展名、文件名或 `Agent session` 占位词时直接丢弃；
  必须拿到真实标题或绝对工作区路径才允许进入托盘。
- 只有进程的 Agent 现在显示明确的进程启动时长，仍不冒充会话时长；
  所有 32 个 Probe 至少能回答“是否运行、运行多久、能否聚焦”。

### 验证不再制造系统打扰

- 删除通过 System Events / Apple Events 唤出托盘的回退路径，也删除通过 AppleScript
  选择 Terminal/iTerm TTY 的路径。快捷键或通知若拿不到应用自有状态项会安静失败；
  Terminal/iTerm 只保留「打开目录」，不再反复申请辅助功能 / 自动化权限。
- 覆盖门禁同时校验 31 个 evidence contract；统计门禁明确报告
  “31 个契约、4 个端到端 collector fixture”，不再用源码字符串计数冒充真实适配覆盖。

## 0.30.0 — 覆盖不再等于有个进程

这版修的不是“再多塞几个字段”，而是把观测语义重新立规矩：
一条信息必须说明它来自会话、缓存还是进程，必须让用户知道它代表现在、最近一次事件，
还是会话开始时间。没有数据时明确降级，绝不再用内部实现细节填空。

### 默认信息改成可判断的句子

- Codex 的 `update_plan / exec / view_image` 映射成「规划 / 执行命令 / 查看图片」，
  并标为“最近动作”，不再暗示工具仍在运行。
- `5m ago`、`session 1h` 分别改成“最近活动：5 分钟前”和“始于 1 小时前”；
  `↑183k ↓468` 改成带范围的“模型调用 · 入 183k · 出 468”。
- 混合 transcript 的计数改称“事件”，不再用 records/记录暗示会话轮数。
- Codex Desktop 带图片时会剥离 `Files mentioned` 与图片传输包络，主标题只保留真实请求。

### 所有 Agent 使用同一降级契约

- 有结构化会话时显示任务、项目、最近动作、活动时间与可验证指标。
- 只有进程时不再显示 `process / 2 processes`，而是明确写
  “已检测到终端会话 / 应用，暂无活动详情”，芯片标为“信息有限”。
- Cursor 的常驻 private-worker 被排除：基础设施进程不再让空闲 IDE 长期显示 Running。
- 支持矩阵新增 `Structured session / Best effort cache` 区分，
  `matrix_check.py` 同时校验 Harvest 和 Waiting 承诺；有 collector 函数不再等于有会话观测。

### 弹窗回归一个连续表面

- 删除 Header 下方与底部的两条 Divider。
- 删除独立底部工具栏和版本页脚；刷新移到 Header，设置、Waiting 连接、诊断与退出收进更多菜单。
- hooks 提示不再占据顶部整条横带。实时内容从 Header 直接进入会话列表。

## 0.29.1 — 核心事实不该藏在详情里

0.29.0 把真实任务、工具、时间和会话指标接进了界面，
但最能判断会话是否推进的事实仍藏在一次 hover 加一次「详情」点击之后；
同时「在终端打开」拿 cwd 新建窗口，却被包装成了聚焦现有 Agent。
这一版把两个交互债一起清掉。

### 默认就能判断会话是否在推进

- 移除「详情」折叠入口。token 快照、subagent 进度和真实记录数有数据时直接显示，
  没有数据就不占行，不再要求用户逐条展开。
- 会话时长留在次行右端；路径、最近工具和最后活动保持一行，
  等待中的问题仍优先于所有运行指标。
- 完整路径、完整 session id、重复任务原文和含义不稳定的 skill 文本不进入主界面；
  可观测不等于把诊断字段全部倒出来。

### 动作只承诺真正能完成的事

- 删除 `Open in Terminal / 在终端打开` 及 cwd 降级路径。
  cwd 能定位目录，不能定位原会话；新开终端既可能失败，也会制造重复上下文。
- 只有 Terminal/iTerm 的真实 TTY 或运行中的 Warp 才显示 Focus；
  其余行只保留可靠的「打开目录」。
- 整行点击与 VoiceOver 提示使用同一套动作判断，
  不再向键盘和辅助功能用户宣称不存在的 Focus 能力。

### 设置回归设置，托盘回归状态

- Settings 删除重复的实时 Agents 列表。长任务标题不再撑坏表单，
  Preferences 只负责行为与连接配置，不再充当第二块 HUD。
- hooks 安装提示改为安静的辅助入口，不再借用 Waiting 红色；
  更多操作菜单隐藏多余下拉箭头，行内层级更清楚。
- 新增 `--open-tray-preview` 视觉回归入口，直接托管真实 `TrayPanel`，
  让 `MenuBarExtra` 内容可以被截图和无障碍检查；同时补充统一的本机构建运行脚本。

## 0.29.0 — 状态必须能解释自己

这一版来自一次安装版实机审计。问题不是面板「少几个字段」，
而是已有字段在真实 Codex rollout 上**语义不可信**：
内部工具标题被当成用户任务、工具调用完全漏报、长会话丢失项目，
累计数百万 token 被包装成当前进度。精致的行因此看起来有内容，
却不能回答「它在做什么、多久没动、为什么需要我」。

### Codex 改为结构化读取

- 会话标题只取真实 `user_message`，不再全局搜索任意 `title`。
  MCP/桌面操作标题即使也写进 rollout，也不会出现在用户任务位置。
- 工具提取支持 `tool_use`、`custom_tool_call`、`function_call`、
  `tool_call` 与 MCP 调用；工具结果、嵌套参数和相邻记录不能借出一个名字。
- 稳定元数据读文件头，动态事件读文件尾，长会话不再退化成 UUID 后缀。
- Codex token 改取最近一轮 `last_token_usage`，不再显示整个 rollout 的累计量。
- 用户任务使用稀疏读取：只解析可能是真实用户消息的行，
  不为找一个标题反复解码数 MB 工具输出。

这些约束落在共享解析器，Claude、Gemini 以及其他 JSON/JSONL collector
也同步获得工具结果隔离和标题防猜测；没有可靠事件的 Agent 仍诚实显示
「进程存在」，不从配置或日志文本编造活动。

### 主行只留能做判断的事实

- `×2` 改成带单位的 `2 processes / 2 个进程`。
- Settings 与 Tray 共用去重后的身份，`Cursor · Cursor` 不再出现。
- 主行显示项目、最近工具、最后活动、会话时长与真实 subagent 进度。
  token 快照和混合事件记录数移入详情，避免把累计/容器量伪装成实时进展。
- 每行增加常驻「更多操作」菜单与右键菜单；聚焦、打开目录和详情
  不再只靠 hover 才能访问。
- VoiceOver 现在读出状态、路径、最近工具、活动时间、会话时长和等待原因，
  与视觉用户获得相同的可观测信息。

### 状态一致性与冷启动

- 系统通知被拒绝时，Idle、Waiting 与提示音三项统一禁用；
  存储层也不会继续尝试发送。
- Python harvest 使用无缓冲输出，超时时已完成的 Agent 行会立即到达 Swift，
  一个慢 collector 不再让它前面的所有 Agent 一起消失。
- 冷启动窗口从误杀正常的后台 Python/SQLite 启动调整为 3.5 秒；
  热扫描仍通常在一秒内完成。

`harvest_stats_check.py` 新增超过 tail 窗口的真实 Codex fixture，
端到端验证用户任务、头部 cwd、最近一轮 token、函数工具与无缓冲子进程参数。

## 0.28.1 — 门禁只能守它真正执行的东西

两份第三方审查读了 `v0.27.2..v0.28.0`，一共提出 11 条实质问题。
**我逐条复现，没有一条是假阳性。** 全部修在这一版。

最难堪的一条是关于我上一版最得意的那个门禁。

### 门禁在冒充验证

`harvest_stats_check.py` 的 docstring 写着「建立真实会话文件、运行真实 harvester」。
实际上它调 `session_stats()` 和 `emit_row()`，手工拼 tuple，
然后靠**数源码里 `session_stats(` 这个字符串**判断 collector 是否接线。

**字符串计数分不出「接线」和「接了但下游被砍掉」。** 而恰好有两处被砍掉：

- **Cascade** 在索引 10 建好 stats dict，两行之后 `norm.append(row[:9])` 把它连同
  多余的 agent 字段一起截掉——文件扫描的开销照付，指标恒为 `0/0`。
- **Amp** 的 pending 分支按索引重写字段，`lst[8] = amp_sid` 正好写在 thread 行
  stats dict 所在的位置。

两条都出厂了，**门禁全程绿灯**，我还据此报出「18 个 harvester 已接线」。

现在它把 `HOME` 指到临时目录，按各 collector 真实的查找路径铺会话文件，
跑真 collector，读完整 TSV。两个 bug 都放回去验证过会红。

> 第一版新门禁**仍然漏掉了 Amp**——fixture 没走到 pending 分支。
> 补了 pending log，并加断言强制它走到那里。
> **是「先把 bug 放回去确认会红」这个动作抓住的，不是我的判断。**

### 严格提取器在猜

它的第一档是「`"type":"tool_use"` 之后 200 字符内任意 `"name"`」：

```
{"type":"tool_use","input":{"name":"production"}}        → production   （嵌套参数）
{"type":"tool_use","id":"x"}\n{"role":"user","name":"alice"} → alice   （下一条记录）
```

**我那四个误报 blob 全都没有 `tool_use` 前缀，所以第一档一次都没被测到。**
我写它是为了防猜测，测的却只有兜底档。

现在真解析 JSON：`name` 必须是携带 `type == "tool_use"` 的**同一个 dict** 上的字符串。
嵌套塞不进来，邻居也借不到。

### 「正在跑」是超额承诺

白名单兜底档对 `tool_result` 和 `tool_use` 一视同仁——工具跑完了也会命中。
不改提取器，改措辞：这一列是**最近**的工具，不是**正在跑**的。
运行状态这里观察不到。

### `started_ms` 对容器文件是编造的

`harvest_extension_storage` 从共享 blob 里取 `obj[-1]`，
却把**整个容器文件**的创建时间当成那个会话的开始——
三月创建的 VS Code 存储文件，会让五分钟前开的会话显示成四个月。

`per_session` 改成**无默认值的必填参数**，逼每个调用点表态。
三个读容器或追加日志的 collector 声明 `False`，什么都不报。

### `turns` 不是轮数

它就是换行数。而一份 transcript 里混着用户消息、助手消息、
工具调用、工具结果和 token 事件——34 条记录不是 34 轮对话。
端到端改名 **`records`**，中文「条」。

### Waiting 行仍在显示量

上一版的说明写着「等待行不放」，实际只有 tokens 被挡住，
时长、记录数、子任务进度照常出现。现在整行返回空。

> 上一版的测试只构造了**带 tokens 的**等待行，而 tokens 恰好是唯一被挡的那个。
> 现在测试带齐四种量。

### 旗舰 Agent 没接上

「23 / 32」是按 harvester 数量算的。按实际使用：
**claude / codex / gemini / cursor / opencode 一个都没接。**
`claude_block` 直接 `emit()`，根本不经过读取哨兵的 `emit_row`。

前三个已接线，都移到解析式提取器。**门禁改成点名要求它们在列**，
而不是数到 15——一个阈值永远说不出「最常开的那几个不在里面」。

### 扫描预算

每文件 8 MB 的上限在 19 个调用点、2.5 秒 harvest 窗口下不构成边界。
超时后部分输出会被当作可靠结果，所以一个慢 collector 不只丢自己那行，
**还会连累它后面的所有 agent**——这违反「一家 collector 不得遮蔽其他 agent」。

每文件 8 → 2 MB，外加整轮扫描 24 MB 上限。

### 文档指针

`AGENTS.md` 还写着「0.22 已发布、0.23 进行中」，
`docs/architecture.md` 只列三个门禁并称之为「全部自动防线」。都已更新，
并写进一条规则：

> **门禁只能守它真正执行的东西。**
> 凡是加门禁，先把它要防的那个 bug 放回去，确认它会红。

### 唯一要纠正报告的地方

其中一份把扫描开销估为「数百 MB」。那是理论上界——
`session_stats` 只在 `.jsonl/.ndjson` 时才真读，`.json` 容器只 `stat()`。
**风险形状是对的，量级偏高。** 仍按风险处理并收紧了预算。

## 0.28.0 — 面板终于有东西可显示

前六个版本我一直在重排面板。这一版去数了一遍**面板到底有什么可排**，
答案是：几乎没有。

### 先说这个数

`src/activity_scan.py` 里 32 个 harvester，逐个扫过之后：

| 会变化的事实 | 改之前 | 现在 |
| --- | --- | --- |
| tokens | 5 | 5 |
| 当前工具名 | 5 | **19** |
| 会话时长 / 轮数 | 0 | **17** |
| **有任何一样** | **6 / 32** | **23 / 32** |

**26 个 Agent 什么都不产出。** 它们的行只能说会话标题和路径，
而这两个在整个会话生命周期里都不变——**跑了四十分钟的会话，
和它第一分钟长得一模一样**。

面板不是设计得不好，是它没东西可显示。

### 两个通用事实

- **`turns`** —— 会话文件的记录数（JSONL 即行数，一次流式扫描）。
  「已经发生了多少」的通用量词。
- **`started_ms`** —— 文件创建时间。面板终于能说「这个会话跑了三小时」，
  而不是只能说「一分钟前动过」。

两条诚实约束：超出字节预算报**未知**，不按比例外推；数不了的格式**不给数**。
跟 Waiting 一样，缺就是缺。

### 工具名：差一点就开始猜了

现成的 `last_tool_name` 最后一档是「任意 `"name": "..."`，
只要不在六个已知非工具的 key 里」。对它当初面向的四个 transcript 形态的 Agent 没问题。
指向另外 26 个之后，实测四个真实形状的配置 blob：

```
{"name":"workspaceFolder",...}      → workspaceFolder
{"profile":{"name":"Default"},...}  → Default
{"servers":[{"name":"filesystem"}]} → filesystem
{"model":{"name":"claude_sonnet"}}  → claude_sonnet
```

**4 / 4 全部误报**，每一个都会被显示成「这个 Agent 正在跑 X」。

这正是产品在别处坚决不做的推断。严格版只认结构化 `tool_use` 记录
和已知工具名白名单，其余返回空——宁可空着。

### 面板：量放到次行右端

```
Pulse installation guide
~/Documents/Cursor · Bash · 3m ago        2h · 34 轮 · ↑12k ↓3k
```

次行右半边本来就是空的，**不多占一行高度**。等待行不放，那里的空间归那个问题。

> `EXPERIENCE.md` 里「一条静态行最多 4 个事实，其余走悬停浮层」
> 是在行里塞了 10 个事实的时候写的，然后矫枉过正：上限是 4，而行一直坐在 2，
> 且两个都是静的。规则已修正。

### 其他面板修复

- **「No project」不再发表头**。用一整行说「下面这些行缺东西」，
  是全面板信息密度最低的一行：一个否定事实，说的是用户已经看得见的行。
- **分组表头取消固定**，因此不再需要背景。0.27.1 和 0.27.2 各换了一种材质，
  那条更亮的带都还在——因为固定的表头必须不透明，而任何压在面板材质上的
  不透明层都会叠出更亮的一层。取消固定是**构造上**消掉它。
- 根材质 `regular → thick`：更厚单调地等于透过来的桌面更少。

### 第七道门禁，而且它真的在跑代码

`scripts/harvest_stats_check.py` 在临时目录里建真的会话文件、跑真的 harvester，
断言：列到齐、预算护栏生效、旧的 12 列行仍能解析、dict 哨兵没把字段挪位、
严格版拒绝全部四个误报 blob 同时仍能读出真 `tool_use`。

还有一条反向断言：**如果宽松版哪天不再乱猜了，门禁会红**——
免得严格版变成没人知道的冗余。

**这一层是 Python，跑在 CI 和本地，不是靠看。** 这是这几个版本里
第一次有改动能被端到端验证。

### 仍未验证

轮数和时长会不会出现在**你的**机器上，取决于各 Agent 会话文件的真实形态；
门禁覆盖的是合成文件。面板长什么样也依然只有截图能回答。

## 0.27.2 — 把深色模式装回来，并让行说出它正在干什么

**0.27.1 没有深色模式。** 深色桌面上，面板是一块浅灰底加黑字。
这是 0.27.1 引入的，源头是一行：

```swift
static let surface = Color(nsColor: .windowBackgroundColor)
```

`static let` 是**只初始化一次的全局量**。面板第一次绘制时是什么外观就被冻在里面，
之后再切主题都不动。这个 app 从那一刻起就没有深色模式了——
而**六道门禁、198 个测试、四轮 CI 全绿**，因为这里没有任何东西会渲染。

那行代码是拿系统材质换来的，换的依据是我对「它会长什么样」的猜测，而我看不到结果。

### 修法：换回材质，并把它变成门禁

表面改回 `Material`。渲染器每一帧对着视图自己的外观解析它——
**这个性质是构造上成立的**，不依赖任何人的判断。

新增第六道门禁 `scripts/appearance_check.py`：
任何把随外观变化的值存进 `let` 的写法都会让 CI 变红。
它是拿真实的那行代码写出来并验证过会拒绝的，不是照着描述写的。

### 同一个错误带出的三件事，一并撤掉

- **在圆角半透明窗口里画不透明直角矩形**。窗口多出来的那截高度变成第二个表面，
  面板读成一个贴上去的盒子。材质和窗口共用同一层底，那条缝就不存在了——
  而不是用 `.fixedSize` 去追它（它从来没起过作用，删了）。
- **通宽分割线**压在平板上就是表格线，两条把面板切成条带。内缩到文字边距。
- **头部**：删掉 18pt 圆标是对的（它复述了用户刚点过的那盏灯），
  但 padding 留在原地，13pt 的一行字漂在 40pt 的空带里。
  让状态词占掉那个空间（15pt），padding 收紧。

### 行里终于有一个活的事实

**会话标题是死的。** 它在整个会话生命周期里不变，
所以一个跑了四十分钟的行和它第一分钟长得一模一样——活儿在干，面板看着是静止的。

`tool` 是活的那个。它**从第一版就在采集**，六个版本里只出现在悬停浮层和展开块里。
现在它在次行中间：

```
Pulse installation guide
~/Documents/Cursor · Bash · 1m ago
```

只对 live 行显示——已结束的会话上，最后碰过的工具是历史不是状态，
显示出来会像还在跑。已经当标题的时候也不重复。

进程行是面板最薄的一行：harvest 什么都不知道，标题退回 Agent 名，次行是空的。
它仅剩的一个事实是进程数，原来埋在展开块里，现在挂到芯片上（`process ×2`）。

### 仍未验证

外观这个 bug 是**构造上**修好的，不再有常量能冻住主题。
但面板现在好不好看，仍然只有截图能回答。
0.27.0 的键盘导航也依然没在真机上按过。

## 0.27.1 — 面板只有一个表面

0.27.0 的真机截图暴露了六个问题，全部是这一版修掉的。
**这个版本不加任何东西**，只修 0.27.0 自己带出来的毛病。

两张截图是同一个面板：一张在蓝色壁纸上，一张在深色桌面上。

### 面板原来没有自己的底

内容直接坐在弹窗的 vibrancy 上，于是**同一个面板在蓝壁纸下整块泛蓝、
在深色桌面下变成一块灰板**——可读性成了用户壁纸的函数。
绿色的状态词在前者里是绿压饱和蓝，在后者里几乎读不出来。

现在面板画在不透明的 `windowBackgroundColor` 上。
**这是拿毛玻璃换可读性**：一个强调色的词必须在任何人的机器上都能读，
这个取舍不算难做。

### 分组表头曾是整个面板最亮的一块

`.thickMaterial` 叠在那层 vibrancy 上，让表头比它分隔的行更亮，
而它承载的是屏幕上最不重要的信息。

现在用和面板同一个表面。它仍然不透明（行要从它下面滚过去），
但不再是另一个明度。**一个表面，不是一叠板子。**

> 这一项在 0.27 的计划里标着「需截图，不看不动」。现在看到了。

### 窗口比面板高出一截

上下各露出一条窗口底色，读起来就是第二个表面。
（点那片空白会关闭面板，这也确认了它是窗口而不是内容。）
改成按面板实际画出来的高度给窗口取值。

### 折叠藏起了本来放得下的内容

三个会话，折走两个，屏幕上只剩一行。

原来的规则只问「这个组能不能折」，从不问「面板到底挤不挤」。
折叠是拿**一行屏幕**换**一次点击加内容被藏起来**——
只有屏幕真的稀缺时这笔交易才划算，三行的时候不是。

两条折叠规则现在都要求总行数 ≥ 5。

### 「No project 2 Pi · Amp」

两个名字和一个 2，同一个事实说了两遍。
摘要点名了每一行时不再发计数；摘要收敛了才发——
三个 Claude 会话摘要成一个「Claude」，那时计数是唯一说清数量的东西。

### 头部的灯

菜单栏的标记就在 40px 之上，同形、同色、同 `glance`。
头部只该说行内说不清的事，图标同理。删掉；
状态词保留 glance 颜色，那才是带信息的部分。

### 仍未验证

**这一版同样没有视觉验证**，尤其是不透明表面——
它是一个关于面板该长什么样的判断，只有下一张截图能定案。

0.27.0 的键盘导航也仍未在真机上验证过。

## 0.27.0 — 一个等待终于有了第三种回应

0.26 之前，你对一个等待只有两种回应：**现在处理**，或者**永久清除**。

最常见的那一种不存在——「知道了，等会儿再说」。
于是它落回到「靠你自己记住」，而「靠你自己记住」正是这个产品存在的理由。

### 稍后（Snooze）

行内动作多了一个「稍后」，默认 10 分钟（可配 5 / 10 / 30 / 60）。

**它压制的是打扰，不是事实。**

| 压制 | 保留 |
| --- | --- |
| 菜单栏灯不变红 | 行留在列表里，仍在「需要你」分组 |
| 菜单栏不显示它的计数和时长 | 分组计数照常算上它 |
| 不发通知 | 芯片显示「已稍后 · 剩 7 分钟」，左色块变淡但不消失 |

这和静音是同一条规则（静音的 Agent 不发通知，但照常出现在列表里）。
**一个会让行消失的按钮，是没人敢按的按钮。** 再按一次即可取消。

两处容易做错、都写了测试：

- **菜单栏的时长只从「未稍后」的等待里算**。否则一个被稍后的、等了一小时的行
  会一直霸占菜单栏标题——你稍后的恰恰是它。
- **稍后到期时，先把它从「已知等待集合」里删掉再重新构建快照**。
  「新等待」这条边沿是集合差集，如果 key 全程留在集合里，
  到期后它会**悄无声息地回来**——一次不会响的提醒等于没有提醒。

### 通知横幅上的按钮

`PulseNotify` 原本一个 `UNNotificationCategory` 都没注册，
所以横幅只能整体点击，你唯一能做的事就是放下手里的活。

现在有「去看看」和「稍后」。横幅正是打扰落地的地方——
能在那里直接推迟，才算闭环。

### 停滞阈值可配

原来是写死的 20 分钟，一个对谁都不合适的值：
跑长构建的人 20 分钟不算停滞，跑短问答的人 5 分钟就该被提醒。

设置 → 通用：5 / 10 / 20 / 30 / 60 分钟，或「不判定」。默认仍是 20。

### 按项目分组也能折叠了

`TrayFold.foldable` 的第一个条件就是 `section == .recent`，
于是**给「同时开好几个仓库」的人准备的那个模式，恰好是唯一不折叠的**。

护栏和「最近」一样（唯一分组不折、单行不折），外加最关键的一条：
**含等待的项目永不折叠**——把需要你的那件事折起来，等于产品失效。

### 键盘导航

↑↓ 走可见的行（折叠起来的组会跳过，不会选中你看不见的东西），
Enter 聚焦，Esc 取消选中，Space 折叠当前行所在的组。

面板通常是快捷键唤出来的，手已经在键盘上了，用鼠标收尾才是别扭的那一步。

### 两处视觉

- **行高亮改成内缩圆角**。邮件、访达侧栏、通知中心全是内缩加圆角；
  全宽贴边的直角色块是 web 的做法，也是面板里最容易读出「不是 Mac 应用」的一处。
- **折叠与行增删加 160ms 过渡**。一个每两秒重建一次的列表，
  硬切会让「新会话出现了」和「顺序变了」长得一模一样。

### 已知未验证

**键盘导航没有在真机上验证过。** `onKeyPress` 依赖面板拿到焦点，
而 `MenuBarExtra` 的 window 样式下这件事只有在真机上才知道成不成立。
CI 能证明它编译，证明不了按下箭头会有反应。

计划里标为「需截图」的分组表头材质一项**没有做**——现在仍然没有截图，
不拿一个视觉判断去改一个视觉问题。

## 0.26.0 — 面板只留你此刻要看的东西

0.25 把每一行的内容修对了。这一版处理的是**面板整体**：
哪些行值得占位置、一行有多宽、以及一个 Agent 凭什么长得像半成品。

### 「最近」默认折叠

真机截图里四行有两行是「最近」——已经结束的会话，没有任何可做的事，
占掉半个面板，也占掉一半的阅读。

现在分组表头兼作展开控件，默认折起：

```
▸ 最近 3  Claude · Cursor
```

折叠态必须带上组内的 Agent 名。只报数量不报身份，恰好是折叠制造出来的问题。

两条护栏：**「最近」是唯一分组时不折**（那些行就是内容本身，折起来剩一句
「最近 3」等于什么都没说），**只有 1 行时不折**（省不出空间，只多一次点击）。
「需要你」和「运行中」永不折叠。

展开状态不持久化——每次打开托盘都是一次新的扫视，应该从「谁需要我」开始，
而不是从上次的翻找状态开始。

### 标题不再被切掉后半截

面板 360pt → 400pt，主行最多两行，字符上限 72 → 96。

上一版我修过 `truncate()` 的按词断字，并且说过**那不是截图里的那个截断**——
截图里的是 `lineLimit(1)`，而 72 这个上限本身就低于面板能显示的字数，
字符串在排版之前就已经被剪短了。三处一起改：单纯加宽只会挪动省略号的位置，
第二行才是保住任务名后半截的东西，而任务名的后半截才是识别它的那半截。

### 补齐 10 个 Agent 图标

三十二个 Agent 里有十个没有图标，托盘就在一排剪影中间画两个字母：
Droid 是「Dr」，Command Code 是「CC」。这是面板里最显眼的未完成感。

修法是补图，不是换一种退路。`scripts/make_agent_icons.py` 把 windsurf、devin、
kiro、junie、kilo、replit、droid、command_code、antigravity、kimi 画成几何标记，
坐标系与笔画粗细都对齐已有的 Simple Icons。

**这些是 Pulse 自己的图形，不是厂商的商标**——README 在支持列表旁边写明了这一点，
也写明了另外 22 个的来处。

### 新门禁：每个 Agent 都有图标

生成器就是源，不是一次性脚本：`--check` 重新渲染到内存里逐字节比对，
committed 的图不可能和描述它的代码分家。

它同时检查**每个 `AgentID` 都有图标**——这才是当初烂掉的地方：
新增一个 Agent 会静默退回字母标，在有人打开托盘之前没有任何东西变红。
`ci.yml`、`release.yml`、`release.sh`、`package.sh` 现在都跑它。

### 其他

- `AGENTS.md` 里过期的「107 个测试」「三个门禁」改成实际的 177 与五个

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

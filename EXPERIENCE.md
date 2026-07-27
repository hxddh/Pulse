# Pulse 体验规格 — macOS 菜单栏工具

版本目标：对齐「一眼知道 Agent 空闲 / 运行 / 等你」；**不**做配额仪表盘。  
约束延续：tray 有数据才显示；窗口用 hide / show，不用 destroy。  
版本真源是 `PulseVersion.semver`，CHANGELOG 与 README 徽标由
`scripts/version_check.py` 强制跟随。

---

## 1. 产品一句话

Pulse 是 **菜单栏状态灯**：扫一眼知道编码 Agent 要不要你；点一下看到该谁、为何等；设置里只改行为，不看热闹。

### Job to be done
- 开会 / 写文档时：不用切终端也能知道「有人在等我」。
- 多 Agent 并行时：分清谁在跑、谁在等，避免空转。

### 非目标（明确不做）
- 额度 / 费用 / 重置倒计时（那是 CodexBar 类产品）
- 桌面宠物、像素角色、统计大盘
- 用 Preferences 当第二块实时 HUD
- 为「覆盖 22 个名字」牺牲会话可读性

---

## 2. 三层分工（硬规则）

| 层 | 用户问题 | 唯一职责 | 禁止出现 |
| --- | --- | --- | --- |
| **Glance**（菜单栏） | 要不要抬头？ | 状态语义 + 极短线索 | 长句、token 明细、设置项 |
| **Tray**（下拉） | 谁、为何、我能做什么？ | 等待优先列表 + 可行动作 | Live updates、语言、hooks 安装 |
| **Preferences** | 我想怎么用 Pulse？ | 行为与连接配置 | 大标题状态看板、重复 tray 信息 |

**信息流向：** 探测 / hooks → Model → Glance 编码状态 → Tray 展开细节 → Prefs 只改开关与连接。

---

## 3. Glance（菜单栏）

### 形态
- **主信号：图标语义**（SF Symbol 或 template 单色 glyph），不是靠读长文字。
- **辅信号：短标题**（可选，宽度紧时只留图标）。
- 深浅色自适应（template rendering）；用 foreground 上交通灯色，不靠彩色 PNG 独占状态。

### 状态编码（优先级从高到低）

| 状态 | 图标语义 | 标题上限（中/英） | 说明 |
| --- | --- | --- | --- |
| Waiting | 红灯 + 呼吸 | `Claude…` / `N`；tooltip 带名 | 最高优先级；N>1 用数量 |
| Running | 绿灯 | 单名或数量 | 有 live / subagent |
| Idle | 灰灯 | （少字） | 仅 recent 或空 |
| Error | 橙灯 | `!` | probe+harvest 都不可用 |

### 规则
- Glance 用交通灯色（template + foreground）；形态仍是灯标，不是彩色 PNG 独占。
- 标题字符预算：**≤ 8 个显示宽度**（CJK 按宽字符计）；超限砍到数量形态。
- Agent **产品名始终英文**（Claude、Codex…）。
- 不在 Glance 显示 tokens、相对时间、项目路径。

### macOS 特性
- `LSUIElement`：无 Dock 图标。
- 启动：**不闪主窗**；主窗仅在「偏好设置…」时 `show`，关闭用 `hide`（永不 destroy）。
- Tooltip：一句状态（如「需要你处理 · Claude」），可略长于标题。

---

## 4. Tray（下拉菜单）

### 结构（固定顺序）

```
① Header（一行，不可点）
② Agent 块 × N（等待优先；有数据才出子行）
③ [另有 N 个…]（可选）
———
④ 刷新
⑤ 偏好设置…
———
⑥ 退出 Pulse
⑦ 版本页脚（tertiary，10pt）
```

### ⑦ 版本页脚（0.21.1+）
`Pulse x.y.z` + 右侧「复制诊断信息」。tertiary 字色、10pt，永远排在动作之后——
它回答「我跑的是哪个 build」，不参与状态叙事。bundle 与二进制版本不一致时，
追加橙色「版本不一致」。点击复制版本 / 构建 / macOS / hooks 状态 / 各行状态。

### ① Header
- **两行结构：** 上行只答状态（需要你 / N 个等待中 / N 个运行中）；下行仅相对时间。
- 状态词跟 Glance 同色（红 / 绿 / 灰）；不可点、不放开关。
- Header **不**拼 agent 名、原因、tokens。

### ② Agent 行（等待优先 → 有会话标题 → 进程检测 → 最近；最多 5 行，每 Agent 最多 4 个会话）

**主行（主语 = 会话）：**  
`{会话标题 | 检测到进程 | 项目}` + 右侧状态芯片

**次行（Agent 身份）：**  
`{Agent} · {project} · hooks|pending`

**Waiting 行：** 左侧 **色块**（非细轨）+ 浅红底，与普通行一眼可分。

**无任务 live：** 降权为「检测到进程」+ `进程` 芯片，不与有标题会话同级。

**子行（仅有数据时）：**
1. `{等待原因 · 时长 · 消息}` — 仅 Waiting
2. `↑in ↓out · tool · skill · {短 session}` — meta；**Waiting 行省略 tokens**

整行点击 = Focus（TTY / Warp / 打开目录）。

禁止：`-` / `—` 占位、空等待行、Live updates、语言切换、Agent 名当 hero。

### 动作（本阶段）
| 项 | 行为 |
| --- | --- |
| 刷新 | 立即探测 |
| 偏好设置… | `show` 主窗 |
| 退出 | `quit` |
| Focus | 有 TTY → 聚焦终端页；via Warp → 激活 Warp；仅有 cwd →「在终端打开」；无句柄不启用 |
| 打开目录 / 忽略等待 | 有 cwd / Waiting 时启用 |

### 文案
- 跟随 `lang=auto|en|zh`；tray 用系统 NSMenu（CJK 正常）。
- 相对时间用人话（刚刚 / 2 分钟），不用 ISO。

---

## 5. Preferences（设置窗）

### 定位
**系统感设置页**，不是状态中心。打开时允许有一行极简「当前：空闲 / 运行中 / 等待中」作上下文，但：
- 不用巨大 heading 当英雄区
- 不复制 tray 的多行 Agent 详情（可保留紧凑列表：名 + 状态，一行一个；无 subtitle/meta 堆叠）

### 分区（自上而下）

1. **上下文（可选，矮）** — 一行状态 + 上次更新；无 Agent 时一句引导。
2. **通用**
   - 实时更新（switch）· 登录时启动（switch）· 语言（弹出菜单，禁止按钮循环）
3. **通知**（0.22 拆为独立分区）
   - 全部空闲时通知 / 新的 Waiting 时通知（switch）
   - **权限被拒时**：两个开关置灰 + 一行说明 + 「打开系统设置」按钮。
     静默失效是不可接受的 —— 开关显示「开」就必须真的会响。
   - 安静时段（仅抑制空闲通知；Waiting 仍可发），**精确到分钟**
   - 按 Agent 静音（折叠）：静音只停通知，列表照常显示
4. **连接**
   - 说明 Waiting 依赖 hooks（2 行内）
   - 主按钮：安装连接；已安装时并列「移除连接」（只删 Pulse 条目）
   - 状态反馈：已安装 / 失败（footer 或行内，不抢主层级）
   - 一句可选 attention 桥提示（Droid/Kimi → `docs/attention-bridge.md`）
5. **快捷键** — 唤出 Pulse 的组合键可选；被占用时明确说「已被其他应用占用」，
   不再一律归咎辅助功能权限
6. **最近的等待**（有记录才出现）— 已结束的等待，最多 12 条
7. **关于** — 够写 bug 报告即可：
   - `Pulse x.y.z`（`swift run` 显示 `x.y.z-dev`；版本不一致显示 `x.y.z≠bundle`）
   - 构建行：`{git short sha} · {构建日期}`，无指纹时显示「开发构建」；可选中复制
   - 「复制诊断信息」按钮 —— 版本 / 构建 / macOS / 语言 / hooks 状态 / 前 8 行状态
   - 版本不一致时补一句橙色提示，指向 `PulseBar/Scripts/package.sh`
   - 检查更新（switch）+ 状态行；有新版时给「打开发布页」

### 视觉（在 Native canvas 约束下尽量靠 HIG）
- 字阶：分区小标题 muted；正文 regular；避免全页 heading。
- 间距：分区 20–24、行内 12；少用「大卡片套大卡片」。
- 设置行：左标签、右控件，像系统 Form。
- 中文：必须稳定 CJK 字体；失败时回退英文标签并提示，禁止豆腐字当正式体验。
- 窗口：**420–460 宽**、可 hide；标题栏简洁。0.22 起分区变多，360 已放不下设置行。

### 禁止
- Simulate / debug 控件出现在正式 Preferences
- 把 hooks 说明写成营销长文
- 与 Glance/Tray 抢「主状态叙事」

---

## 6. 跨层原则

### 可读性
1. **先状态，后细节** — Waiting > Running > meta。
2. **有数据才显示** — 已实现约束，保持。
3. **一行一个意思** — 不把原因、任务、项目、tokens 揉进同一行。
4. **扫描距离** — Glance 0.3s；Tray header + 首个 Waiting 1s；Prefs 只在改设置时打开。

### 优雅感（可验收）
- [ ] Idle 时菜单栏几乎只有图标，不刷「空闲」长词（除非用户偏好要求）
- [ ] Waiting 时不用打开菜单也能察觉（图标 + 可选通知）
- [ ] Tray 打开后，第一个可理解的信息是「要不要我处理」
- [ ] Prefs 打开后，3 秒内能改完语言或通知，无需滚动读小说
- [ ] 关 Prefs 后进程与 tray 仍在（hide，非 destroy）

### 能耗（0.22 起为硬约束）
常驻菜单栏工具被系统标记为耗电大户等于定位破产。探测节奏必须跟随状态：

| 状态 | 间隔 |
| --- | --- |
| Waiting | 2s |
| Running | 5s |
| 仅最近会话 | 15s |
| 空 | 30s |

- 托盘打开时最快 2s；低电量模式一律 ×2；**息屏 / 锁屏停表**（attention 文件变化仍唤醒）
- 昂贵的 Python harvest 与便宜的 `ps` probe 解耦，按节奏跳过；
  进程指纹变化 / 手动刷新 / attention 变化时强制采集
- 落点：`ProbeSchedule.swift`（纯策略，有测试）+ `PowerMonitor.swift`

### 通知
- 触发：空闲（全灭）· 新 Waiting（边沿触发）
- 内容：标题 `{Agent} · {项目}`，正文 `{原因} · {消息}`。
  只说「需要你处理」而不说要什么，用户仍得切过去才知道 —— 不算闭环。
- Prefs：空闲通知 / Waiting 通知分开关
- 安静时段：只抑制空闲通知；Waiting 边沿仍可发（产品选择）

### 数据诚实
- 进程在 ≠ 会话在干活：文案避免「正在编码」类过度承诺；用「运行中 / 检测到」。
- Waiting 来自 hooks，或等价诚实信号（如 Cursor blocking pending / harvest `skill=pending`）；未安装 hooks 或 Agent 无 Waiting 接线时 Tray 一句提示，不假装 Waiting。
- Wait 行标注 `hooks` / `pending`；Focus 不假装能聚焦无 TTY 的会话。
- 0.15+：名单 Agent 尽量铺满 Probe + Harvest；Waiting 有信号才亮。

---

## 7. 实现分期

### P0 — 体验纠偏（不改探测深度）
1. Glance：图标状态机 + 缩短标题；Idle 少文字. → **已做**（标题状态机；图标受 SDK 限制为静态 template）
2. Tray：收紧 Header；保持有数据才显示；去掉任何设置项渗漏. → **已做**
3. Prefs：去掉英雄大标题；语言改为菜单/分段；Agent 区压成一行摘要. → **已做**
4. 启动：零闪窗（hide/不展示，而非依赖 minimize 碰运气）. → **尽力**（50ms minimize；SDK 无 start-hidden）

### P1 — 菜单栏闭环
1. Waiting 行可行动（开项目 / 显式「已处理」清信号）. → **已做**（cwd 可开项目；清除等待）
2. 通知改为可点击. → **已做**（UNUserNotificationCenter 回调 → 聚焦对应会话）
3. Launch at Login. → **已做**（LaunchAgent）

### P2 — 会话级（产品护城河）
1. Claude + Codex 先做 session 标题 / 项目. → **已做**（标题 + 每 Agent 最多 4 会话 + cwd）
2. 多开同名可区分. → **已做**（同 Agent 多会话独立成行；超出上限显式提示「另有 N 个会话未显示」）
3. 广覆盖 probe 保留为「有人在」，会话层覆盖「在干什么」. → **已做方向**

---

## 8. 验收场景

| # | 场景 | 期望 |
| --- | --- | --- |
| A | 无 Agent | Glance 安静；Tray 一句空态 + 操作；Prefs 非空白恐慌页 |
| B | Claude 运行中 | Glance 显示 Claude 或进行中图标；Tray 有主行；无空 ↳ |
| C | Claude 等授权 | Glance 立刻可辨；Tray 等待置顶 + ↳ 原因；通知可选 |
| D | 2 跑 + 1 等 | Glance 偏等待；Tray 等待行在上 |
| E | 打开再关闭 Prefs | Tray 仍在；无 Dock 常驻感 |
| F | 切到中文 | Tray/Prefs 中文正确；Agent 名仍英文 |

---

## 9. 与代码落点（便于改）

| 规格 | 主要文件 |
| --- | --- |
| Glance 标题 / status item | `PulseBar/.../PulseApp.swift` → `MenuBarLabel` |
| Tray 结构 | `PulseBar/.../PulseApp.swift` → `TrayPanel` |
| Prefs 布局 | `PulseBar/.../PulseApp.swift` → `SettingsView` + `SettingsWindowController` |
| 文案 | `PulseBar/.../L10n.swift` |
| 状态合并 | `PulseBar/.../StatusStore.swift` |
| 版本 / 构建指纹 | `PulseBar/.../Models.swift` → `PulseVersion`；`scripts/version_check.py` |
| 诊断复制 | `PulseBar/.../StatusStore.swift` → `diagnosticsText()` |
| Harvest / hooks | `src/activity_scan.py`, `src/pulse_hook.py`（打包同步进 app） |
| 探测节奏 / 能耗 | `PulseBar/.../ProbeSchedule.swift` + `PowerMonitor.swift` |
| 更新检查 | `PulseBar/.../UpdateCheck.swift` |
| 测试 | `PulseBar/Tests/PulseBarTests/` |

本文是后续 UI/UE 改动的验收依据；实现时改行为须同步改本节，避免文档漂移。

# Pulse 代码 / 文档全量 review（基线 0.21.0 → 0.21.1）

范围：`PulseBar/`（Swift 主壳，13 个源文件）、`src/*.py`（harvest + hooks，2.4k 行）、
`src/*.zig`（legacy）、全部 Markdown、打包与门禁脚本。

**状态说明**：`已修` = 本次 0.21.1 已改并验证；`待办` = 已定位、未动（多数需要产品取舍）。

---

## 0. 一句话结论

产品定位（菜单栏状态灯，不做配额 HUD）和 IA 是清楚的，文档也罕见地写在了实现前面。
真正的风险不在功能缺口，而在三处：

1. **诚实性被实现细节破坏** —— 产品硬规则写着「不假装 Waiting」，但 Goose 采集里一行
   `pending = pending or True` 让任何 Goose 会话恒亮「需要你」。规则写了，没有测试守。
2. **单点故障吞掉全部信号** —— 任一 agent 采集抛异常 → 整个 `activity_scan.py` 非零退出
   → Pulse 丢弃全部 32 个 agent 的扫描结果，界面停在旧快照。
3. **版本身份完全不可辨识**（用户点名的问题）—— 三份版本常量，两份停在 16 个版本前，
   界面上只有设置页底部一行灰字，没有构建指纹，出问题无法定位是哪个 build。

1 / 2 / 3 本次已修。剩下的按下面清单排。

---

## 1. 版本身份（用户点名问题）

### 1.1 修前的实际状态

| 位置 | 值 | 备注 |
| --- | --- | --- |
| `Models.swift` → `PulseVersion.semver` | `0.21.0` | AGENTS.md 声明的真源 |
| `app.zon` `.version` | **`0.5.0`** | 落后 16 个 minor |
| `src/version.zig` `semver` | **`0.5.0`** | 同上，且 `major/minor/patch` 也是 0.5.0 |
| `README` 徽标 / CHANGELOG | `0.21.0` | 一致 |
| `scripts/package-macos.sh` | 读 `version.zig` | 会产出名为 `pulse-0.5.0-*.dmg` 的包 |

而 `EXPERIENCE.md` 开头写的约束是「版本双写 `app.zon` + `version.zig`」——
和 `AGENTS.md` 的「Version truth: Models.swift」**互相矛盾**，两份文档各自指向不同真源，
于是三份常量谁也没维护。

### 1.2 界面上的暴露度

修前，`PulseVersion` 在整个 UI 里只出现 **一次**：`SettingsView` 最后一个 Section，
`.secondary` 灰字一行 `Pulse 0.21.0`。这意味着：

- 菜单栏 / Tray 完全看不到版本 —— 日常使用中无从判断跑的是哪个 build。
- 没有构建指纹（commit / 日期），同一 `0.21.0` 可能是任意一次 `swift build` 的产物。
- `swift run` 的开发壳和打包的 `Pulse.app` **显示完全相同**，二者行为不同（资源查找路径不同）
  却无法区分。
- 用户装了新版但旧 `Pulse.app` 还在跑（menu bar 应用极常见），没有任何提示。
- 报 bug 时没有任何可复制的环境信息。

### 1.3 已修（0.21.1）

**真源与门禁** —— `scripts/version_check.py`（新增）把 `Models.swift` 当唯一真源，
校验 `app.zon` / `src/version.zig`（含 major/minor/patch）/ CHANGELOG 最新标题 / README 徽标，
`--fix` 自动对齐。已接进 `package.sh`，打包前先过门禁。

**构建指纹** —— `package.sh` 把 git short sha（有未提交改动加 `+`）与构建日期写进
`Info.plist` 的 `PulseGitCommit` / `PulseBuildDate`，`PulseVersion` 运行时读取。
没有指纹时诚实降级为 `dev`，不编造。

**三档 channel**（`PulseVersion.Channel`）：

| channel | 判据 | 显示 |
| --- | --- | --- |
| `release` | bundle 版本 == 编译版本 | `Pulse 0.21.1` |
| `dev` | 无 bundle 版本（`swift run`） | `Pulse 0.21.1-dev` |
| `mismatch` | bundle 版本 ≠ 编译版本 | `Pulse 0.21.1≠0.21.0` + 橙色「版本不一致」 |

`mismatch` 是这次特意加的：它正是「装了新版、旧 app 还在跑」这个 menu bar 应用高频陷阱。

**界面落点**（两处，均为 tertiary 层级，不与状态叙事抢位）：

- **Tray 页脚** —— 动作区之下一行 10pt 弱化 `Pulse x.y.z`，右侧「复制诊断信息」。
  hover 提示完整指纹。这是「不点设置也能知道跑的是哪个 build」的解法。
- **偏好设置 → 关于** —— 版本、构建行（`sha · 日期`，可选中）、复制诊断按钮；
  `mismatch` 时补一句指向 `package.sh` 的橙色提示。

**诊断文本**（`StatusStore.diagnosticsText()`）—— 一次粘贴给出：指纹、channel、macOS 版本、
语言 / 实时更新开关、hooks 状态、glance 与行数、前 8 行的 waiting/live/signal/sub 状态。

### 1.4 版本相关待办

| # | 项 | 说明 |
| --- | --- | --- |
| V1 | 无 git tag / release | 仓库只有 2 个 commit，没有 tag，CHANGELOG 写到 0.21 但无对应发布物 |
| V2 | 无更新检查 | menu bar 应用不自更新等于永远停在首装版本；建议 Sparkle 或最简「检查更新」跳转 |
| V3 | ad-hoc 签名 | `codesign --force --deep --sign -`：DMG 分发给他人会被 Gatekeeper 拦；且 `--deep` 已被 Apple 废弃 |
| V4 | legacy 打包脚本仍活着 | `scripts/package-macos.sh` 从 `version.zig` 取版本，会产出与 PulseBar 同名不同实现的 app —— 建议明确删除或标记 |

---

## 2. Bug 清单

### P0 — 影响正确性 / 数据安全

| # | 位置 | 问题 | 状态 |
| --- | --- | --- | --- |
| B1 | `activity_scan.py` `goose_activities` | `pending = pending or True` 恒为真。守卫是 `if any(x in blob ...)`，而 `blob` 里只要出现 `"waiting"` 字面量就命中 —— 任何 Goose 会话 JSON 都极易触发。结果：**假 Waiting**，直接违反 AGENTS.md「No fake Waiting」硬规则。注释「only if near end / recent file」说明作者本想加新鲜度条件，但从未写 | **已修**：改为显式带引号的标记 + `PENDING_FRESH_SEC`(5min) 门槛 |
| B2 | `activity_scan.py` `main()` | 32 个采集器全在一个函数里裸调。任一抛异常（消失的路径、锁住的 sqlite、意外 JSON）→ 脚本非零退出 → Swift 侧标记 `harvestUnreliable` → **丢弃全部扫描结果**。一个坏采集器致盲全部 agent | **已修**：`guard()` 逐 agent 隔离，失败只写 stderr，其余照常输出（已用故障注入验证） |
| B3 | `install_hooks.py` `install_claude` | `except json.JSONDecodeError: data = {}` —— 用户的 `~/.claude/settings.json` 只要解析失败（JSONC 注释、手改出错），就被**整个替换成只剩 pulse hooks** 的文件，其余全部设置静默丢失 | **已修**：拒绝写入并报错；首次写入前留 `.pulse-backup` |
| B4 | `install_hooks.py` `install_codex` | `notify = [...]` 追加在文件末尾。TOML 里裸键属于**当前 table**，若 `config.toml` 以 `[mcp_servers.x]` 结尾，`notify` 就落进那个 table，Codex 永远读不到 —— 界面显示「已安装」但 hook 从不触发。另外 `re.sub` 会替换任意 table 里第一个 `notify =`，可能改坏 `[profiles.*]` | **已修**：定位 root table（首个 `[` 之前）插入 / 替换；6 种配置形态已测 |

### P1 — 影响体验 / 资源

| # | 位置 | 问题 | 状态 |
| --- | --- | --- | --- |
| B5 | `StatusStore.DebugLog` | 每次探测写约 5 行，永不轮转。按 3s 周期约 **20 MB/天**、不清理 | **已修**：2 MB 轮转保留一代；`ISO8601DateFormatter` 也不再每行新建 |
| B6 | `Models.waitDurationLabel` | 返回硬编码 `now/30s/2m/3h`，中文界面下 Waiting 行显示英文单位 | **已修**：移入 `StatusStore`，走 L10n |
| B7 | `activity_scan.py` `aider_activities` | 扫描根写死 `/Users/rustjia/Pulse`、`/Users/rustjia/Documents`、`/Users/rustjia/Desktop` —— 开发机路径进了发布包 | **已修**：删除，改为 `PULSE_AIDER_ROOTS` 环境变量 |
| B8 | `AttentionWatcher` | `DispatchSource` 的 fd 在 `cancel()` 之后立即 `close()`。取消是异步的，GCD 仍可能持有该 fd —— 经典 fd 竞态 / 复用风险 | **已修**：fd 只在 cancel handler 内关闭 |
| B9 | `coverage_check.py` | 读了 `MODELS` 却从不使用；`probe_ids` 算出来只打印不校验。新增 `AgentID` 时门禁静默缩小 | **已修**：新增 `AgentID` 未登记到 `EXPECTED` 即失败 |

### P1 — 已定位，待办

| # | 位置 | 问题 | 建议 |
| --- | --- | --- | --- |
| B10 | `activity_scan.py:67` `tail_bytes` | 名为 tail，实为 `path.read_bytes()` 全文读入内存再切尾。Claude 的 `.jsonl` 会话文件可达数十 MB，而这个函数**每 1.5–3 秒**被调一次 | 改 `open('rb')` + `seek(-n, SEEK_END)`，只读尾部 |
| B11 | `ActivityHarvest.swift:82-98` | 子进程输出**在其退出后**才 `readDataToEndOfFile()`。stdout 超过管道缓冲（64 KB）时 python 会阻塞在 write 上永不退出 → 每次都撞 2.5s 超时 → 永远 `unreliable`。stderr 同理（B2 的诊断输出也走这条） | 边跑边读（`readabilityHandler` 或后台读线程） |
| B12 | `ActivityHarvest.swift:88-95` | 超时路径把**已经产出的部分结果整个丢弃**，退化成「一个 agent 慢 = 全部没数据」 | 超时时保留已读到的完整行 |
| B13 | `StatusStore.swift:122` | 定时器 1.5s（有 Waiting）/ 3.0s。每次都 `fork` 一个 python3 去做几十次 glob / rglob / sqlite —— 约 **28,800 次进程启动/天**，且不随「无 agent」「息屏」「电池」降频。macOS 大概率报「显著耗能」 | 见 §5 P0-A |
| B14 | `StatusStore.swift:274` | `if count >= 2 { continue }` —— 每个 agent 最多 2 个会话行，**硬编码**。开 3 个 Claude 会话时第 3 个完全不可见，界面也不提示被截断 | 与 §5 P1-D 一起做；至少让「另有 N 个」把它算进去 |
| B15 | `StatusStore.swift:617,675` | `rowKey.contains(att.session)` 永远匹配不上：`sessionKey()` 对 >24 字符的 session 做了 `prefix(12)+"…"+suffix(6)` 省略，完整 session id 不可能是它的子串。实际只有 `sessionID ==` 那条分支生效 | 直接比对 `sessionID`，删掉误导性的 `contains` |
| B16 | `PulseApp.swift:319` `estimateHeight` | 在 SwiftUI body 求值里调 `row.canFocusTerminal` → `TerminalFocus.focusTier()` → 遍历 `runningApplications` + `FileManager.fileExists`。每行、每次重绘都做一遍同步 I/O 与进程枚举 | 把 focus tier 在 `applyScan` 时算好存进 `AgentRow` |

### P2 — 小问题

| # | 位置 | 问题 |
| --- | --- | --- |
| B17 | `Models.swift:118` `isSurface` | switch 枚举了全部 case 且**一律 return true**。注释写「IDE shells stay out」但没有任何 agent 被排除 —— 死抽象，全部调用点的 `where hit.id.isSurface` 都是空过滤 |
| B18 | `Models.swift:275` `sessionDetail` | 定义完整（无 task 时对 live 行回落到 tool 名）但**从未被调用** —— tray 直接用 `usefulTask`。设计意图丢失：live 行没有 tool 兜底 |
| B19 | `HooksSupport.probeStatus` | 只查 `~/.claude/settings.json` 是否含 `pulse_hook.py`。用户把 hooks 放在 `settings.local.json` 或项目级配置时误报「未安装」，并触发 tray nudge |
| B20 | `pulse_hook.py` | `import re` 未使用；`session_from_json` 里 `if name.startswith("rollout-"): name = name` 是空操作 |
| B21 | `AttentionIO.swift` vs `AttentionWatcher` | 两处写入的 header 文本不同（`# Pulse attention log (agent\t…)` vs `# Pulse attention log`）；`readText` 忽略 `read()` 返回值（当前 80 行上限下无害） |
| B22 | `SettingsWindowController.swift:30` | 窗口 420×520，`EXPERIENCE.md` §5 写的是「固定偏窄（约 360–380）」—— 规格与实现不符 |
| B23 | `activity_scan.py` | 31 处 `except Exception: continue`。B2 的 `guard()` 兜住了顶层，但这些静默吞异常仍让「为什么这个 agent 没数据」无法排查 |

---

## 3. 不合理的内容

### 3.1 文档漂移（本次已改）

| 位置 | 问题 |
| --- | --- |
| `EXPERIENCE.md` 开头 | 「版本双写 `app.zon` + `version.zig`」与 `AGENTS.md` 的真源声明**互相矛盾** → 已改为「真源 = `PulseVersion.semver`，二者是跟随者」 |
| `README.md` | 0.21.0 的文档里挂着「## 0.18 特色」表 → 已更新为 0.21 |
| `README.md` 开发调试 | `cd PulseBar && swift run` 之后紧跟 `python3 scripts/coverage_check.py` —— 此时已在 `PulseBar/`，该路径不存在 → 已修正为子 shell + 补上版本门禁 |
| `EXPERIENCE.md` §4 / §5 | Tray 与关于区的实际结构已变，规格未同步（文末自己写了「实现时改行为须同步改本节」）→ 已补版本页脚与关于区三行 |

### 3.2 结构性矛盾（待决策）

- **legacy Zig 树的定位不清**。`src/*.zig`（约 3.5k 行）+ `src/tests.zig`（692 行测试）+
  `app.zon` + `scripts/package-macos.sh` 全部还在，README 还教人 `native test`。
  但 `AGENTS.md` 说「reference only」。结果：**唯一的自动化测试全部覆盖已死代码**，
  真正在跑的 `PulseBar/` 一行测试都没有。要么删，要么明确降级为 `legacy/` 子目录。

- **`src/*.py` 双份拷贝**。`src/` 是真源，`PulseBar/Sources/PulseBar/Resources/` 是
  `package.sh` 同步出来的副本，但两份都提交进了仓库。当前恰好同步，但没有门禁防止手改副本。
  建议：把 `Resources/*.py` 加进 `.gitignore`，或在 `version_check.py` 里加一致性断言。

- **`StatusStore` 与单例耦合**。类内部多处直接写 `AppServices.store.xxx`
  （`refresh` 的回调、`installHooks`）而非 `self` —— 它只能作为单例存在，无法实例化测试。

---

## 4. 产品层面需要补齐的内容

按「对当前定位（状态灯）的贡献 / 成本」排序。刻意不含 EXPERIENCE.md 已列的非目标
（配额、桌面宠物、统计大盘）。

### P0 — 不做会持续掉用户

| # | 缺口 | 说明 |
| --- | --- | --- |
| A | **能耗与探测策略** | 见 B13。一个「一眼看状态」的常驻小工具，被系统标记为耗电大户是致命的定位伤害。需要：无 agent 时退到 15–30s；息屏 / 锁屏 / 电池时降频；harvest 与 probe 解耦（`ps` 便宜可以快，python 采集要慢）；只在 tray 打开时提高频率 |
| B | **PulseBar 零测试 + 零 CI** | 现有测试全在已废弃的 Zig 树。`applyScan` 的合并逻辑（多会话去重、live 附着、attention 匹配、waiting 边沿通知）是产品最核心也最易回归的一段，完全裸奔。至少补：`applyScan` 纯函数化 + XCTest；`activity_scan.py` 的 pending 判定单测；GitHub Actions 跑两个门禁 |
| C | **可分发性** | ad-hoc 签名 + 无 notarization + 无更新检查 = 只能自己用。若要给第二个人用，这三件必须做 |

### P1 — 定位内的明显残缺

| # | 缺口 | 说明 |
| --- | --- | --- |
| D | **多会话真实可见性** | 每 agent 硬上限 2 会话（B14）、tray 硬上限 4 行。「多 Agent 并行时分清谁在跑、谁在等」是文档写明的 JTBD，当前在重度并行场景下直接失真，且不告知被截断 |
| E | **通知信息量** | 通知 body 直接用 `snap.tooltip`（如「需要你处理 · Claude」），不含**原因**和**项目**。用户仍得切过去才知道要批什么。应改为 `{项目} · {等待原因}`，并利用已有的 `waitMessage` |
| F | **通知权限失败无反馈** | `requestAuthorization` 结果被丢弃（`{ _, _ in }`）。用户拒绝授权后，设置里的两个通知开关依然显示「开」，但永远不响 —— 静默失效 |
| G | **hooks 卸载路径** | 只有安装没有卸载。用户删掉 Pulse 后，`~/.claude/settings.json` 和 `~/.codex/config.toml` 里的 hook 残留指向不存在的脚本 |
| H | **等待项无历史 / 无累计** | 「刚才有个 Waiting，我错过了」无法回看。attention.tsv 有 80 行数据，但界面完全不展示。一个极简「最近处理过的等待」列表成本很低 |
| I | **快捷键不可配置** | ⌘⇧P 硬编码，且与不少应用冲突；冲突时 `RegisterEventHotKey` 失败也没有任何提示（`a11yHint` 把所有失败都归因于辅助功能权限，会误导） |

### P2 — 打磨

| # | 缺口 |
| --- | --- |
| J | 安静时段只能整点，无法设 22:30 |
| K | 无「按项目 / 按 agent 静音」，某个长跑 agent 会持续打扰 |
| L | 空态引导偏弱：`No coding agents detected` 之后没有下一步（装 hooks？支持哪些 agent？） |
| M | `docs/attention-bridge.md` 的「带 session 的 done」只说「写一个包含 session 列的 done 行」，没给可复制的命令 —— 而 `pulse_hook.py` 的 argv 形态并不支持指定 session，必须走 stdin JSON |
| N | 32 个 agent 的支持矩阵无任何自动校验，README 表格靠手维护，易与 `waitingSource` 实际值脱节 |

---

## 5. 建议的下一步顺序

1. **B10 / B11 / B12 + P0-A**：一次做完探测链路 —— 真 tail、边跑边读、超时保留部分结果、
   分层降频。这是当前唯一会让人卸载的问题。
2. **P0-B**：把 `applyScan` 抽成纯函数并补 XCTest，同时上 CI 跑两个门禁。
   有了它，B1 那类「产品规则写了但没人守」的问题才不会重来。
3. **P1-E / F**：通知带上原因与项目；权限被拒时把开关置灰并说明。
4. **B14 / P1-D**：多会话上限改为可见的软上限。
5. **P0-C**：签名 / notarization / 更新检查 —— 决定 Pulse 是不是要给第二个人用。

---

*本文与 `EXPERIENCE.md` 的关系：EXPERIENCE.md 是体验验收基准（应然），本文是 0.21 时点的
实现审计（实然）。修完一项就从这里划掉；如果修的是行为，同步改 EXPERIENCE.md。*

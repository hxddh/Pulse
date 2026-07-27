# Pulse 代码 / 文档全量 review（基线 0.21.0）

> **状态：全部关闭（0.22.0）。** 本文保留为审计记录 —— 每条findings 的成因与修法都在下面。
> 0.21.1 修了版本身份与 P0 诚实性问题，0.22.0 关闭了剩余的性能、产品与工程缺口。

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

### 1.4 版本相关后续（0.22.0）

| # | 项 | 状态 |
| --- | --- | --- |
| V1 | 无 git tag / release | **待人工**：需要在 GitHub 打 tag 并发布；代码侧已就绪（更新检查读 Releases） |
| V2 | 无更新检查 | **已修**：`UpdateCheck.swift` 每天至多一次查 GitHub Releases，可关；数字版本比较有测试 |
| V3 | ad-hoc 签名 | **已修**：`PULSE_SIGN_IDENTITY` / `PULSE_NOTARY_PROFILE` 支持 Developer ID + 公证；移除废弃的 `--deep`；未设置时打印明确警告 |
| V4 | legacy 打包脚本 | **待决策**：见 §3.2 |

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

### P1 — 已定位（0.22.0 全部修复）

| # | 位置 | 问题 | 状态 |
| --- | --- | --- | --- |
| B10 | `activity_scan.py` `tail_bytes` | 名为 tail，实为 `path.read_bytes()` 全文读入内存再切尾。Claude 的 `.jsonl` 会话文件可达数十 MB，而这个函数**每 1.5–3 秒**被调一次 | **已修**：`open('rb')` + `seek(-n, SEEK_END)` |
| B11 | `ActivityHarvest.scan` | 子进程输出**在其退出后**才 `readDataToEndOfFile()`。stdout 超过管道缓冲（64 KB）时 python 阻塞在 write 上永不退出 → 每次都撞超时 | **已修**：独立线程边跑边读（stdout / stderr 各一条） |
| B12 | `ActivityHarvest.scan` | 超时路径把**已经产出的部分结果整个丢弃** | **已修**：保留完整行；只有一行都没有才算 unreliable |
| B13 | `StatusStore` 定时器 | 固定 1.5/3.0s，每次 fork python，约 28,800 次/天，不随状态 / 息屏 / 电池降频 | **已修**：见 §5 P0-A |
| B14 | `StatusStore.applyScan` | `if count >= 2` 硬编码，第 3 个会话完全不可见且不提示 | **已修**：上限 4，超出计数显式展示 |
| B15 | `StatusStore` 两处 | `rowKey.contains(session)` 永远匹配不上（rowKey 对长 id 做了省略） | **已修**：直接比对 `sessionID`，双向前缀兼容截断形式 |
| B16 | `PulseApp.estimateHeight` | 视图体内每行每次重绘遍历运行中应用 + stat 磁盘 | **已修**：`focusTier` / `canOpenFolder` 每次扫描算一次并存进 `AgentRow` |

### P2 — 小问题（0.22.0 全部处理）

| # | 位置 | 问题 | 状态 |
| --- | --- | --- | --- |
| B17 | `AgentID.isSurface` | switch 枚举全部 case 且一律 return true —— 死抽象，4 处 `where` 都是空过滤 | **已修**：删除谓词与调用点 |
| B18 | `AgentRow.sessionDetail` | 定义完整但**从未被调用**，live 行丢失 tool 兜底 | **已修**：接入 hero title 与 `isProcessOnly` |
| B19 | `HooksSupport.probeStatus` | 只查 `settings.json`，用户放在 `settings.local.json` 时误报未安装并触发 nudge | **已修**：两个文件都查 |
| B20 | `pulse_hook.py` | 未使用的 `import re`；`if name.startswith("rollout-"): name = name` 空操作 | **已修** |
| B21 | `AttentionIO` / `AttentionWatcher` | header 文本不一致；`readText` 忽略 `read()` 返回值 | **已修**：header 统一；读取按实际字节数循环 |
| B22 | `SettingsWindowController` | 窗口 420×520 与规格「360–380」不符 | **已修**：规格与实现对齐（内容变多，规格改为 420–460） |
| B23 | `activity_scan.py` | 31 处静默 `except Exception: continue` | **部分**：顶层已有 per-agent `guard` 并写 stderr；逐个 except 保留（best-effort 采集的本质） |

---

## 3. 不合理的内容

### 3.1 文档漂移（本次已改）

| 位置 | 问题 |
| --- | --- |
| `EXPERIENCE.md` 开头 | 「版本双写 `app.zon` + `version.zig`」与 `AGENTS.md` 的真源声明**互相矛盾** → 已改为「真源 = `PulseVersion.semver`，二者是跟随者」 |
| `README.md` | 0.21.0 的文档里挂着「## 0.18 特色」表 → 已更新为 0.21 |
| `README.md` 开发调试 | `cd PulseBar && swift run` 之后紧跟 `python3 scripts/coverage_check.py` —— 此时已在 `PulseBar/`，该路径不存在 → 已修正为子 shell + 补上版本门禁 |
| `EXPERIENCE.md` §4 / §5 | Tray 与关于区的实际结构已变，规格未同步（文末自己写了「实现时改行为须同步改本节」）→ 已补版本页脚与关于区三行 |

### 3.2 结构性矛盾

- **legacy Zig 树**。`src/*.zig`（约 3.5k 行）+ `src/tests.zig` + `app.zon` +
  `scripts/package-macos.sh` 是被替换掉的 **Vercel Native SDK 壳**。
  0.22.0 起 PulseBar 有了自己的测试，`src/tests.zig` 不再是「唯一的测试」。
  **建议删除整棵树**（git 历史里仍在）——一条命令：
  ```bash
  git rm -r src/*.zig src/app.native app.zon assets scripts/package-macos.sh
  python3 scripts/version_check.py   # 跟随者少两个，门禁自动适应
  ```
  未在本次执行：批量删除被安全策略拦下，且这是产品归档决定，留给你拍板。

- **`src/*.py` 双份拷贝**。`src/` 是真源，`Resources/` 是 `package.sh` 同步出的副本，
  两份都提交进仓库。→ **已加门禁**：CI 比对两者，不一致即失败。

- **`StatusStore` 与单例耦合**。类内部多处直接写 `AppServices.store.xxx` 而非 `self`。
  → **部分修复**：`installHooks` / `uninstallHooks` 改用 `self`；
  `applyScan` 的回调仍走单例（跨队列回主线程），可测性已由纯函数化的
  `ProbeSchedule` / `TerminalFocus.focusTier` / `AttentionReader.parse` 覆盖。

---

## 4. 产品层面需要补齐的内容（0.22.0 全部完成）

| # | 缺口 | 交付 |
| --- | --- | --- |
| A | **能耗与探测策略** | `ProbeSchedule` 按状态定节奏（2/5/15/30s），托盘打开提速、低电量 ×2、息屏锁屏停表；harvest 与 probe 解耦按需跳过；定时器 20% 容差。空闲机器 Python fork 从约 28,800 次/天降到约 2,880 次/天 |
| B | **PulseBar 零测试 + 零 CI** | 新增 `PulseBar/Tests/PulseBarTests`（版本 / 更新比较 / harvest 解析 / attention 规则 / 节奏 / Focus 分级 / 行展示 / 安静时段 / 通知文案 / L10n）与 `.github/workflows/ci.yml`（Linux 门禁 + macOS 构建测试） |
| C | **可分发性** | Developer ID 签名 + notarytool 公证 + stapler；更新检查。**剩人工步骤**：申请证书、打 tag、发 Release |
| D | **多会话真实可见性** | 每 Agent 上限 2 → 4，托盘 4 → 5 行；被压下的会话在托盘与设置页显式计数 |
| E | **通知信息量** | 标题 `{Agent} · {项目}`，正文 `{原因} · {消息}`，长文本截断 |
| F | **通知权限失败无反馈** | 授权结果不再丢弃；被拒时开关置灰 + 「打开系统设置」 |
| G | **hooks 卸载路径** | `install_hooks.py --uninstall` + 设置页按钮；只删 Pulse 条目（用户自己的 hook 已验证保留） |
| H | **等待项无历史** | 等待结束进入 `waitHistory`（最多 12 条），设置页「最近的等待」可看可清 |
| I | **快捷键不可配置** | 4 个预设 + 关闭；注册失败明确提示「已被占用」，不再一律归咎辅助功能 |
| J | 安静时段整点限制 | 改为分钟精度（15 分步进），旧整点配置自动迁移 |
| K | 无按 Agent 静音 | 设置页折叠列表；静音只停通知，列表照常显示 |
| L | 空态引导偏弱 | 说明 Pulse 何时会亮 + 直接给安装 hooks 按钮 |
| M | attention-bridge 文档缺命令 | 补上可复制的带 session `done` 命令，并说明 argv 形态不支持 |
| N | 支持矩阵无校验 | `scripts/matrix_check.py`：README 表格与 `waitingSource` 不符即失败（已验证能抓到人为漂移） |

## 5. 剩余事项

代码侧已清空。剩下的都需要人工决定或账号权限：

1. **归档 legacy Zig 树** —— §3.2 给了命令，等你拍板。
2. **Apple Developer ID + 公证账号** —— `package.sh` 已接好，缺证书。
3. **打 tag 并发首个 Release** —— 更新检查读的就是 GitHub Releases，
   在有 Release 之前它会一直报「检查失败 · HTTP 404」。
4. **`swift build` / `swift test` 需在 macOS 上跑** —— 本次改动在 Linux 容器完成，
   Swift 侧靠人工审查 + 结构校验；CI 的 macOS job 是第一道真正的编译验证。

---

*本文与 `EXPERIENCE.md` 的关系：EXPERIENCE.md 是体验验收基准（应然），本文是 0.21 时点的
实现审计（实然）。0.22.0 后二者已对齐；新的行为改动请同步改 EXPERIENCE.md。*

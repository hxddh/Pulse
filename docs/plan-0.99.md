# 0.99 计划 —— Quiet Data / 数据静默

## 先说这份评估的局限

**0.98 的输出还没被读过。** 0.98 的全部意义是让下一次诊断变便宜：
`--harvest-explain` 会说出每个 adapter 的 `heroOrigin` / `emptyReason` / `truncated`，
`--harvest-shape` 会说出厂商真正写了什么键。这两份东西**只能在装了 Agent 的真机上取**，
CI 的 fixture 取不到。

所以这份计划刻意**不含任何「再修某个 Agent 的解析」**。0.96.1–0.97.2 四连发的教训是：
没有真机证据时动解析，等于抽奖。P0-0 拿到证据之前，解析条目一律空着。

本版换的章不是采集，是**落盘**：0.90–0.97 让**显示**诚实，0.98 让**采集**诚实，
从没有人审过 Pulse **写到磁盘上的东西**——账本里存了什么、留多久、注释说的和实际做的
是不是一回事。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。

**诚实前提：**

- 不伪造 Waiting；不扩 hooks；不升格 cache→session。
- builder 保持纯；无额度 HUD；托盘无 approve/deny。
- 删代码不改行为：删 legacy Python 不得改变任何 native 结果。

---

## 现状盘点（0.98.0）

| 主题 | 缺陷 | 0.99 动作 |
| --- | --- | --- |
| 账本注释撒谎 | `AttentionLedger` 的类型注释写「never stores prompts, paths, tool arguments」，实际把 `row.usefulTask`（0.98 起**定义为用户真实目标**）取 160 字存进 `attention-ledger.json`，保留 14 天 / 256 条。标题本身过了 `ContentSanitizer`，所以这不是泄漏，是**声明与实现不符** | 改注释说实话；保留期与清空入口对用户可见 |
| chrome 词表第三份 | 0.98 收敛了采集侧两份，`AgentRow.usefulTask` 的 `junk` 是第三份且已分叉：大小写敏感（`junk.contains(t)` 不 lowercase，`isChromeTask` lowercase），且缺 `Cascade session`——正是 0.98 补进采集侧的那条 | 并入 `chromeTaskTitles`，加回归锁「只有一份」 |
| legacy Python 负担 | `src/activity_scan.py` 4978 行 + `Resources/` 逐字节副本 4978 行 + `harvest_stats_check.py` 1514 行 = **11,470 行**，对照 Swift 运行时 21,601 行。默认永不执行，却占一道门禁 + 一条 CI 逐字节同步检查。0.98 已证明它**挡不住 native 回归**，却让 AGENTS.md 长期误称「跑真实 collector」 | 删除采集器与其门禁；hook 脚本保留 |
| Details / Support / Settings | 三个窗口 **0 处**显式 accessibility。托盘行有 `accessibilityElement(.combine)` + label + hint，详情页没有 | 补 label/value |
| `debug.log` | 不过 `ContentSanitizer`。当前调用点不写标题，但无 session id 时 `row.rowKey` **就是项目目录名** | rowKey 落盘前脱敏项目名 |
| supervisor 盲区 | 0.98 用起点轮转解决了饥饿，但 `HarvestSupervisor` 仍对 `.unscanned` 完全 no-op，诊断里看不出「谁被预算挤掉过」 | 记 `lastUnscannedAtMs`，进 summary |

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-0 | **真机证据** | 在装了 Agent 的机器上跑 `--harvest-explain` 与 `--harvest-shape`，把逐 Agent 的 `heroOrigin` / `emptyReason` 贴回本文件。**阻塞 P0-3** |
| P0-1 | 账本诚实 | `AttentionLedger` 注释改为陈述实情（存 ≤160 字会话标题、14 天 / 256 条、已过 `ContentSanitizer`）；设置里能看到保留期并能清空；测试锁住「注释所述 == 实际字段」 |
| P0-2 | chrome 词表真单源 | `usefulTask` 的 `junk` 并入 `chromeTaskTitles`；大小写统一；回归断言全仓只有一份该词表 |
| P0-3 | 解析缺口 | **由 P0-0 决定**。若某 Agent 的 `emptyReason` 指向真实缺口，按证据修；无证据则本项为空，不许凭猜填 |
| P0-4 | 删 legacy Python | 删 `src/activity_scan.py`、`Resources/activity_scan.py`、`harvest_stats_check.py`；删 CI 的逐字节同步检查中该文件与 legacy 门禁步骤；`PULSE_LEGACY_PYTHON_HARVEST` 通路与 `legacyPythonScan` 一并移除。`pulse_hook.py` / `install_hooks.py` **保留**（仍是兼容资产）。八门禁 → 七门禁，AGENTS/architecture/README 同步 |
| P0-5 | 删代码不改行为 | ~~删除前后 rows/adapters 数一致~~ → **改判**：adapters 一致（32）；rows 由 133 变 134，而 0.98 只打印了一个总数，**无法归因到具体 Agent**。故验收改为：fixture 墙钉住**逐 Agent 行数**且每个数字都有解释；`swift test` 全绿；`--selftest` 仍认得可选资产的缺席。改判理由与代价见下方「P0-5 的改判」 |
| P0-6 | 场景 AM + 测试 | EXPERIENCE **AM**（Quiet Data）；QuietData 回归 |
| P0-7 | 交付物 | plan；CHANGELOG；semver；AGENTS/README；七门禁；草稿 PR；**等「发布」** |

### P1

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | 窗口 a11y | Details / Support / Settings 的关键控件与事实行有 label/value；VoiceOver 读得出「谁、为何、多久」 |
| P1-2 | debug.log 脱敏 | rowKey 落盘前项目名脱敏；已有调用点不回归 |
| P1-3 | supervisor 可见 | `.unscanned` 记时间戳并进 `summary` / 安全支持报告 |

### 明确不做

假 Waiting、扩 hooks（Claude/Codex 之外）、composer 深链、cache→session、假 1.0、
额度 HUD、托盘 approve/deny、上传任何遥测、把 explain 做成第二块实时 HUD、
**凭猜修解析**。

---

## 落地记录（0.99.0）

| ID | 落点 | 状态 |
| --- | --- | --- |
| P0-0 | `--harvest-explain` / `--harvest-shape` 真机输出 | **未做 —— 需要装了 Agent 的机器** |
| P0-1 | `AttentionLedger` 注释 + `retentionDays` / `maxEvents`；`StatusStore.waitHistoryRetentionLine`；设置里「最近等待」下方 | 已完成 |
| P0-2 | `AgentRow.chromeTitles` / `isChromeTitle`；采集侧 `isChromeTask` 改为委托 | 已完成 |
| P0-3 | 解析缺口 | **空 —— 阻塞于 P0-0** |
| P0-4 | 删 `src/activity_scan.py`、`Resources/activity_scan.py`、`scripts/harvest_stats_check.py`、`RuntimeResolver.swift`、`legacyPythonScan` 与 schema-2 wire；`coverage_check.py` 改读 Swift descriptor；CI 新增「No Python in the harvest path」 | 已完成 |
| P0-5 | native 墙钉住逐 Agent 行数（`expectedRows`）；`swift test` / `--selftest` 全绿 | **部分** —— 见「P0-5 的改判」 |
| P0-6 | `QuietDataTests.swift`；EXPERIENCE 场景 **AM** | 已完成 |
| P1-1 | `AgentDetailWindowController.fact`；`SupportFactPill` 读出有 / 未知 | 已完成 |
| P1-2 | `DebugLog.key(_:)` + 六个调用点 | 已完成 |
| P1-3 | `HarvestSupervisor.lastUnscannedAtMs` → `summary` | 已完成 |

Settings 依赖标准控件的默认 a11y，本版未逐项加标签；这是有意的取舍，不是遗漏。

---

## P0-5 的改判

原验收是「删除前后 `--native-fixture-test` 的 rows 数一致」。实际结果：

```
0.98.0  native fixture PASSED — rows=133 adapters=32
0.99.0  native fixture PASSED — rows=134 adapters=32
```

adapters 一致，rows 多 1。**这一条没通过，不改成通过。**

逐 Agent 分解（0.99.0）之后，134 行每一行都有出处：

| 计数 | 来源 |
| --- | --- |
| opencode 100 | 并发压力 fixture |
| cascade 2 | `.codeium/session.json` + `.windsurf/session.json`，两者都在 Cascade 声明的根内 |
| claude / codex / pi 各 2 | 通用 fixture + 0.98 加的厂商真实布局 fixture |
| windsurf 0 | Cascade 占用共享根时按设计压制 |
| 其余 26 个各 1 | 通用 fixture |

**但这不能证明 0.98 的 133 是对的。** 0.98 只打印了一个整数，没有分解，所以「多的那一行
属于谁」在事后无法回答 —— 可能是 0.99 多admit了一行，也可能是 0.98 漏了一行而 0.99 修对了。
两种可能我都没有证据，就不选一种写进文档。

> **后续更正（0.99.1）：以上两种可能都不对。** 逐 Agent 断言上线后，同一个二进制在同一次
> CI 作业里连跑两次得到 `claude=2` 与 `claude=1` —— 这堵墙本身不稳定。0.98 加的 Claude
> fixture 是刻意超限的 1.4 MB 笔录，繁忙 runner 上摄入它会耗尽 0.75 s 的单 adapter 预算，
> 第二个文件读不到。**133 与 134 是同一个抖动数字的两次采样，不是版本差异。**
> 修法是让 fixture 墙不再兼任秒表（正确性扫描用宽裕 deadline，时间交给
> `resource_budget_check.py` 与显式 timeout 扫描）。逐 Agent 断言是发现它的原因 ——
> 一个总数永远做不到这件事。

能做的是让它不再发生：fixture 墙现在钉住 `expectedRows` 逐 Agent 表，任何漂移都会指名道姓。
这正是 0.98 对采集器做过的事 —— 一个孤立的整数不可归因 —— 只是这次轮到了墙自己。

**结论：删代码本身是安全的（编译、526+ 测试、七门禁、打包、selftest 全绿），但
「不改行为」这条我只能证明到 adapters 一级，行数一级证不到。这个 PR 带着这个已知缺口。**

---

## 为什么是这个顺序

P0-0 是唯一能把 0.99 从「又一轮猜测」变成「有证据的修复」的东西，所以它排第一并阻塞
P0-3。P0-1/P0-2 收的是同一类债：**0.98 修好的规则，在更上一层还有一份没跟上的副本**
——这正是这个仓库反复出问题的形状，值得在它再咬一次之前清掉。

P0-4 删的是 11,470 行永不执行的代码。它的真实成本不是磁盘，是**它让人以为有一道
不存在的防线**：AGENTS.md 曾据此宣称门禁在跑真实 collector，四连发全绿出厂。
删掉之后，剩下的每一道门禁都守着它真正执行的东西。

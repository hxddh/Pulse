# 0.98 计划 —— Ground Truth / 采集可证

## 先说这份评估的局限

0.95 → 0.97.2 六个版本在同一天发出，其中 **0.96.1 / 0.97.0 / 0.97.1 / 0.97.2 四连发修的是同一件事**：
托盘主行不是用户目标。每一版都写了新 fixture、加了新测试、八门禁全绿，然后
「生产仍空」。0.97 计划自己写下了这句话，0.97.1 又写了一次，0.97.2 再写一次。

这不是解析逻辑不够聪明，是**采集侧没有真源**：

- 505 个 XCTest 用真实路径跑真实 `NativeActivityHarvest.scan`，但 fixture 是**照着
  猜想的格式手写的**。猜错时测试和产品一起错，颜色仍是绿的。
- `harvest_stats_check.py` —— AGENTS.md 和 architecture.md 都称它「跑真实 collector、
  验完整 TSV」—— 全文 145 处调用 `activity_scan`（**legacy Python**，architecture.md
  明说不是运行时通路）。对 native 的校验是 15 条**源码字符串存在性断言**，正是这个
  文件自己的 docstring 判过死刑的做法（「Counting a string cannot tell live wiring
  from dead wiring」）。0.28.0 的 bug 换了一层重演。
- `--native-fixture-test` 确实跑真扫描器，但它的 fixture 是 Pulse 自己发明的
  `{"sessionId":…,"title":…}` 通用 JSON；Pi 只有 `context-mode/*.db`，**没有官方
  `--<cwd>--/<ts>_<uuid>.jsonl`**；Claude 是一行 `"title"`，没有 `tool_result` 尾巴。
  断言只问「这个 Agent 有没有行」，不问「主行是不是那句话」。

所以 0.98 换章：**不再修下一条解析规则，先让采集能自证**。主行错了要能一眼看出错在
哪一层，而不是靠再发一个版本去试。

`records` 已经在撒谎（见下），比主行更早违反「数量不估算」。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。

**诚实前提：**

- 不伪造 Waiting；不扩 hooks；不升格 cache→session。
- builder 保持纯；无额度 HUD；托盘无 approve/deny。
- 新增的解释性输出只说采集器真正做过的事，不解释成因、不猜测。

---

## 现状盘点（0.97.2）

| 主题 | 缺陷 | 0.98 动作 |
| --- | --- | --- |
| 主行选择 | `preferTask` 末规则仍是 `new.count >= old.count + 8`，「长的赢」外面糊了 6 条特例（chrome / filename / 200 字 tool dump / Pi JSONL vs SQLite …）。四连发都在给这条加特例 | Fact 带 `taskOrigin` + 记录序号，按 (来源等级, 新旧) 选，**删掉字数比较** |
| 采集不可解释 | health 只有 observed / no_sessions / …。`observed` + 主行空时，用户和维护者都拿不到任何线索 | 每 Agent 输出 explain：扫了几个文件、读了多少字节、窗口是否截断、解析出几条 fact、主行来自哪种记录、为什么为空 |
| `records` 撒谎 | `ingestTranscriptFile` 用 `readWindow` 的**窗口**数换行符，>1MB 的笔录被静默少算，托盘按精确值展示「N 条」 | 窗口截断时 `records = 0`（未知），不外推 |
| 扫描饥饿 | `descriptors()` 顺序固定，全局 5.8s 用尽后**永远是同一批尾部 Agent**（droid / commandCode / antigravity / kimi / zcode）标 unscanned；supervisor 对 unscanned 显式 no-op，不会补偿 | 起点游标轮转；unscanned 进入下一轮优先队列 |
| PATH 真相 | `executableExists` 读 `ProcessInfo.environment["PATH"]`。Finder/launchd 启动的 App 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，homebrew / npm-global / `~/.local/bin` 全看不见 | 固定候选目录 + 一次性登录 shell PATH；否则「装了没会话」被说成「没装」 |
| chrome 词表分叉 | `isChromeTask` 22 条，`makeRows` 内联副本 18 条，少了 `cascade/aider/droid/kimi session` | 收敛成一份 |
| fixture 保真 | 旗舰格式的 fixture 由作者臆造；没有任何来自真机的样本 | 旗舰按厂商真实布局重写；新增「捐一份脱敏样本」路径 |

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-0 | `taskOrigin` | `Fact` 带 `.userPrompt / .sessionName / .toolTitle / .cacheTitle / .fallbackText` 与记录序号；`merge` 按 (等级, 新旧) 选主行 |
| P0-1 | 删除字数启发式 | `preferTask` 不再出现 `count` 比较；0.96.1–0.97.2 的六条特例回归**全部仍绿** |
| P0-2 | Harvest explain | 每 Agent 输出 `files/bytes/truncated/facts/heroOrigin/emptyReason`；进 `safeSupportReport()`、`debug.log` 与 `--harvest-explain`。**不进托盘 UI**——那会变成第二块实时 HUD。只有计数与固定标签，无标题 / 正文 / 路径 |
| P0-3 | 截断计数=未知 | `Fact.windowTruncated`；截断时 `records` 不进行；托盘不显示估算值 |
| P0-4 | 扫描公平 | 起点游标按轮转；连续 3 轮，尾部 Agent 至少被 attempt 一次；unscanned 提升下轮优先级 |
| P0-5 | PATH 真相 | 模拟 launchd 最小 PATH 时，`~/.local/bin/claude` 仍判 `sourcePresent`；health 为 `no_sessions` 而非 `source_absent` |
| P0-6 | chrome 词表单源 | 只有一份常量；`makeRows` 与 `isChromeTask` 共用；`cascade/aider/droid/kimi session` 两处一致 |
| P0-7 | 旗舰 fixture 保真 | `--native-fixture-test` 的 Claude / Codex / Pi 用厂商真实布局（Pi `--<cwd>--/<ts>_<uuid>.jsonl`、Claude 带 `tool_result` 长尾、Codex `event_msg`），断言**主行取值**而非「有行」 |
| P0-8 | 门禁诚实 | `harvest_stats_check.py` 的 native 段不得再用字符串存在性断言；改为对 native 结果断言，或把该段明确改名为 legacy-only 并在 AGENTS.md / architecture.md 更正描述 |
| P0-9 | 场景 AL + 测试 | EXPERIENCE **AL**（Ground Truth）；GroundTruth 回归 |
| P0-10 | 交付物 | plan；CHANGELOG；semver；AGENTS/README；八门禁；草稿 PR；**等「发布」** |

### P1

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | 样本捐赠 | `--harvest-shape` 导出**脱敏**的会话记录形状（键名 + 值类型，无值），供修解析用；默认不跑，输出短到可以先读再分享。做成 CLI 而非设置项：受众是修解析的人，且不给常驻 App 增加一个可能泄漏的按钮 |
| P1-2 | SHA-256 锚定 | `sha256(in:)` 只在 `### Download verification` 代码块内匹配，不再取正文首个 64 位十六进制 |
| P1-3 | `cmd` 探针 | Command Code 的 `cmd` 可执行名过于通用，收紧为路径特征 |

### 明确不做

假 Waiting、扩 hooks、composer 深链、cache→session、假 1.0、额度 HUD、托盘
approve/deny、上传任何遥测、把 explain 做成第二块实时 HUD。

---

## 落地记录（0.98.0）

| ID | 落点 |
| --- | --- |
| P0-0 / P0-1 | `NativeActivityHarvest.TaskOrigin`、`preferTask(_:_:)`、`effectiveOrigin` |
| P0-2 | `ActivityHarvest.CollectorExplain`、`explainResult`、`safeSupportReport()`、`--harvest-explain` |
| P0-3 | `readWindow` 返回 `truncated`；`ingestTranscriptFile` 的 `records` |
| P0-4 | `scan(startCursor:)` + `Result.nextCursor` + `StatusStore.harvestScanCursor` |
| P0-5 | `commandSearchPaths` / `executableExists(_:home:environment:)` |
| P0-6 | `chromeTaskTitles` 单一常量 |
| P0-7 | `NativeHarvestSelfTest` 的 Claude / Codex / Pi 厂商布局 fixture |
| P0-8 | `harvest_stats_check.py` 改标 legacy-only；CI 新增具名 `Native fixture wall` |
| P0-9 | `GroundTruthTests.swift`；EXPERIENCE 场景 **AL** |
| P1-1..3 | `shapeReport` / `--harvest-shape`；`sha256(in:)` 锚定；Command Code `cmd` 收紧 |

---

## 为什么是这个顺序

P0-0/1 让「主行错了」变成可争论的**类型问题**（该用哪种来源），不再是可无限加特例的
字符串问题。P0-2/3 让错了之后**一次就能定位**。P0-7/8 让门禁重新能红。

这三件事做完之前，再修一条解析规则只是第五次抽奖。

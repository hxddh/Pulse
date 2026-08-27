# Agent observability contract

> **0.50 Signal Quality** — runtime rows carry a named
> `ObservationQuality` envelope (`facts` / `missing` / `freshness` /
> `confidence`). A missing field must explain why and what to do next; see
> [`docs/plan-0.50.md`](plan-0.50.md). Process-only fallbacks are never
> presented as equivalent to session/cache rows.

Pulse does not count a detected process as “Agent support”. A useful row needs
four baseline facts whenever that Agent has written them locally:

1. **Goal** — the latest substantial user goal or stable session title.
2. **Workspace** — project and absolute working directory.
3. **Activity** — last observed activity and, when available, session age.
4. **Evidence** — structured session, verified cache, or process-only fallback.

The row then promotes lifecycle facts in this order: explicit wait/block,
current phase, progress/outcome, failures, changed files, model/context, and
volume counters. Unknown is shown as unknown; Pulse never fills a gap by
guessing from process count, CPU, a filename, or an arbitrary JSON `name`.

The UI exposes the runtime quality rather than flattening all support into one
claim:

- **A · Structured session** — stable session identity plus direct lifecycle
  records; goal, workspace and activity are expected when the Agent wrote them.
- **B · Verified cache** — a vendor-owned local cache with a verified session
  shape; only fields actually present are shown.
- **C · Process only** — executable/path evidence, process age and focus
  capability; activity detail is explicitly unavailable.

Goal, workspace, activity and evidence are the four core facts in the support
window. Progress, model, mode, counters, files and Waiting are valuable
enhancements when the Agent exposes them, not fabricated universal
requirements. An Agent whose contract has no Waiting route is therefore not
reported as incomplete merely because Waiting is unavailable; its useful-signal
score is evaluated out of four rather than five.

## Runtime adapter health

Static coverage and runtime health are different claims. The same bounded scan
that reads session data emits one privacy-safe result per collector:

Since 0.48 the normal scan is `NativeActivityHarvest.swift`: all 32 surfaces
have a Swift descriptor and typed row/health output. Cursor's composer database
is read through the macOS SQLite3 module when the user grants that Agent's
protected store. The old Python adapters remain an explicit legacy diagnostic
path only; they are not required for any row or health result.

- **Observed** — the collector emitted one or more valid rows.
- **Source absent** — no known local session source or Agent CLI exists.
- **No usable session** — a source exists, but it currently contains no row
  that satisfies the Agent's evidence contract.
- **Permission denied** — the source exists but cannot be read.
- **Data format changed** — the source exists but raised a recognized
  decode/schema/database error.
- **Failed** — another collector error occurred; Pulse shows only its type.
- **Unscanned** — a timeout or hard failure ended the scan before it reported.

Source presence is a bounded existence check, not a second diagnostics crawl.
Completed health records and rows survive a later timeout, and one failed
collector cannot blank other Agents. Cursor Agent shares Cursor's collector
because their rows are merged into one user-facing session identity.

## Coverage

“Conditional” means the Agent/version writes the fact in its local session or
cache. It is parsed and shown when present, but an older or idle installation
may not have it.

| Agent | Source | Goal + workspace + activity | Additional useful facts |
| --- | --- | --- | --- |
| Claude Code | transcript | direct | latest model call, last meaningful action, records, session age, subagents, wait |
| Codex | rollout | direct | latest model call, last meaningful action, session age, subagents, wait |
| Cursor | composer database | direct | composer mode, pending/wait |
| Grok | summary + signals + lifecycle events | direct | phase, outcome, model, agent mode, turns, failures, files, context usage, wait |
| Pi | session JSONL | direct | tokens, last meaningful action, wait |
| Amp | thread/session/history | direct | mode, session age, records, wait; continuation prompts are skipped |
| Aider | chat history | direct | last meaningful action, session age, records, wait |
| Gemini CLI | session JSON | direct | tokens, last meaningful action, session age, records, wait |
| GitHub Copilot | session store | direct | last meaningful action, session age, records, wait |
| OpenCode | session database | direct | tokens, pending/wait |
| Goose | session store | direct | last meaningful action, session age, records, wait |
| OpenHands | session store | direct | last meaningful action, session age, records, wait |
| Continue | session store | direct | last meaningful action, session age, records, wait |
| Droid | session JSONL | direct | last meaningful action, session age, records, wait |
| Command Code | session JSONL | direct | last meaningful action, session age, records, wait |
| Kimi | session JSONL | direct | last meaningful action, session age, records, wait |
| Amazon Q | verified cache | conditional | phase, model, mode, progress, outcome, pending/wait |
| Cline | verified cache | conditional | phase, model, mode, progress, outcome, pending/wait |
| Roo Code | verified cache | conditional | phase, model, mode, progress, outcome, pending/wait |
| Cascade | verified cache | conditional | phase, model, mode, progress, outcome, records, session age, pending/wait |
| Windsurf | verified cache | conditional | phase, model, mode, progress, outcome, records, session age, pending/wait |
| Augment | verified cache | conditional | phase, model, mode, progress, outcome, pending/wait |
| Zed Agent | verified cache | conditional | phase, model, mode, progress, outcome, pending/wait |
| Trae | verified cache | conditional | phase, model, mode, progress, outcome |
| Warp Agent | verified cache | conditional | phase, model, mode, progress, outcome |
| Kilo Code | verified cache | conditional | phase, model, mode, progress, outcome, pending/wait |
| Devin | verified cache | conditional | phase, model, mode, progress, outcome |
| Kiro | verified cache | conditional | phase, model, mode, progress, outcome, pending/wait |
| Junie | verified cache | conditional | phase, model, mode, progress, outcome |
| Replit Agent | verified cache | conditional | phase, model, mode, progress, outcome |
| Antigravity | verified cache | conditional | phase, model, mode, progress, outcome |
| ZCode | verified cache | conditional | phase, model, mode, progress, outcome |

Every Agent still has a process fallback: real working directory, process age,
TTY/focus capability, and an explicit “activity unavailable” statement. That
fallback is detection, not rich session observability, and is never presented
as equivalent to a session/cache row.

Collector ingestion is bounded at 500 rows per Agent (same ceiling as Swift
retain). The tray's global twelve-row fold remains presentation only. This
separation lets Pulse observe more than it shows without allowing unbounded
vendor stores to consume menu-bar memory.

`bestEffortCache` Agents may still miss goal / workspace / activity; that shows
up as Limited / ObservationQuality gaps — never as a silent “full session”
claim. Agents with `waitingSource=none` stay Running-only unless the Attention
bridge writes a real Waiting line.

High-traffic cache adapters (Windsurf / Cascade, Cline, Roo, Warp, and peers
marked `verified cache` above) stay **Limited** when the index is thin: Support
depth reads “thin cache / index”, not “session transcript”. When the same cache
emits goal + workspace/action, Support depth reads “cache facts (Limited)” —
still never `.session`. Runtime gate: `NativeActivityHarvest.makeRows` stamps
`.cache` evidence whenever `AgentID.harvestSource == .bestEffortCache`,
regardless of path needles. Agents with `waitingSource=none` never promote
harvest status words into Waiting.

Cline / Roo / Cascade harvestPending recognizes explicit ask/block fields and
ask tools (`ask=followup` without `askResponse`, `ask_followup_question`,
`isWaitingForResponse`, …) — never substring matches like `depending`. Attention
entries that name an unknown session create a dedicated Waiting row; they do
not light sibling sessions.

## Tool and skill policy

Raw tool and skill names are usually low-value implementation metadata:

- `exec`, `run_terminal_command`, `Skill`, MCP server names, and helper script
  paths do not tell a person whether the Agent is progressing.
- A tool result can be the last record even after the Agent finished, so it
  cannot be labelled “currently running”.
- A failed tool message is not the session goal and must never become the hero
  title.

Pulse therefore transforms explicit tool/lifecycle events into a small,
user-facing phase vocabulary such as **Planning**, **Reading**, **Researching**,
**Editing**, **Testing**, **Building**, **Publishing**, **Responding** and
**Waiting for permission**. `Turn complete` is an Outcome, never a current
`Now` phase. Generic command execution is hidden. Concrete failure count, file count,
progress and outcome outrank the raw tool name.

Raw skill names do not appear verbatim in the default row. A path containing
`skills/`, a package namespace, or an internal preflight script is diagnostic
data. An explicit skill invocation appears as a user-recognisable workflow
role such as Planning, Researching, Testing, Building, Editing, or Publishing
when it maps cleanly; an otherwise unknown name keeps only its safe leaf as a
bounded `Workflow <name>` label. This preserves useful capability evidence
without exposing namespaces, paths, URLs, or arbitrary implementation text.

## 工作事实矩阵（8.3 全员对账）

上表回答「四个基线事实 + 增强事实」;本节按 8.1 弹窗工作方式线的口径,
逐家逐类对账:**工具/目标、token、模型、上下文 %、skill/工作流、子 agent、
原话/计划/错误原文**,三种诚实状态:

- **✓** = 采集器有对应提取路径,且被 fixture 或形状测试钉住。
- **−** = 该厂商的本机记录(我们能读到的那份)不含此事实。缺席是诚实的,
  不发明;厂商日后开始写,形状匹配的通路自动接住(形状优先于厂商名,2.9)。
- **→** = 记录里可能有、采集器尚未提取(附原因;需真机样本才能安全落地)。

真机核对仪器:Support Health 每拍显示每家「声明 vs 实测」的事实类;
`PulseBar --harvest-test` 打印每行实测值。

### 第一梯队:structured session(16 家)

| Agent | 通路 | 工具(→目标) | token | 模型 | 上下文% | skill | 子agent | 原话/计划/错误 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Claude 家族 | 通用 JSONL 形状 | ✓(tool_use;目标走 hooks 活动事件) | ✓ message.usage | ✓ | −(transcript 不写百分比) | ✓ 8.2(`Skill` 调用的 input.skill) | ✓(subagents 目录计数) | ✓/✓/✓ |
| Command Code | 通用 JSONL(Claude 同形) | ✓ | ✓ | ✓ | − | ✓(同形自动生效) | −(无子 agent 目录约定) | ✓/✓/✓ |
| Codex | 专用解析器 | ✓ function_call | ✓ token_count(latest 优先) | ✓ 8.2(turn_context) | ✓ 8.3(window×used 两实测数之比) | −(rollout 无 skill 概念) | − | ✓/✓(update_plan)/✓ |
| Pi(JSONL) | 专用解析器 | ✓ 8.2(toolCall;>8KB 行正则打捞) | ✓ 8.2(usage {input,output}) | ✓ | −(JSONL 无上下文字段) | −(无 skill 记录) | − | ✓ 8.2/−(无 todos)/✓ 8.2(isError 方言) |
| Pi(context-mode DB) | SQLite events | ✓ tool_call 事件 | ✓ agent_usage | ✓ | −(events 无窗口字段) | − | − | −/−/✓(error 事件计数,无原文) |
| Cursor(composer) | SQLite headers + bubbles KV | →(headers 无工具;bubbles 未提取工具) | ✓(header 若带 usage 键) | ✓ | − | − | − | ✓ 9.0(cursorDiskKV 最新 assistant bubble;版式不符则缺席)/−/− |
| Grok | SQLite session_docs(+ 若有 JSONL 走形状) | −(docs 无结构化工具) | −(docs 无 usage) | −(docs 无模型字段) | − | − | − | ✓ 8.3(`<assistant` 标签后段落)/−/− |
| OpenCode | SQLite session+message+parts | ✓ parts | ✓ session 列 | ✓ session 列 | −(无窗口列) | − | − | ✓ 9.0(role 经 message 表联查;缺表则缺席)/−/− |
| Gemini | 通用(chats 整文件 JSON) | ✓ functionCall | ✓ usageMetadata | ✓ | − | − | − | ✓ 9.0(整文档遍历,最后一个 `model` 回合)/−/− |
| Amp | 通用 JSONL 形状 | ✓* | ✓* | ✓* | −* | −* | −* | ✓* |
| Aider | 文本(markdown 历史) | −(无结构化记录) | −(历史无 usage) | ✓(正则) | − | − | − | ✓ 9.0(最新 `#### ` 用户回合后的散文段)/−/− |
| Copilot / Goose / OpenHands / Continue / Droid / Kimi | 通用 JSONL/JSON 形状 | ✓* | ✓* | ✓* | −* | −* | −* | ✓* |

\* 形状通路:采到什么取决于该家本机文件实际携带什么——形状匹配则得,
不匹配则诚实缺席。某家某类长期为空 = 该家记录不写它(−);若你在原始文件里
亲眼见到该字段,那是 →:带样本提 issue,一条形状规则就能接住。

### 第二梯队:bestEffortCache(17 家)

cursorAgent(Cursor 别名)、Amazon Q、Cline、Roo、Cascade、Windsurf、Augment、
Zed Agent、Trae、Warp Agent、Kilo、Devin、Kiro、Junie、Replit、Antigravity、
ZCode——缓存级按设计只展示缓存里真实存在的字段(如 Warp 的 model/上下文%、
Cline/Roo 的显式 pending 标志),其余缺席。升格到第一梯队的唯一途径是厂商
开始写结构化会话记录,或用户给出可依据的真机样本。

### 受管会话(Pulse 自己的流)

全字段第一手:工具/原话/错误/成本·回合/±行/token——8.0 起完整入弹窗。

### 变更史

- 8.2:Pi 三缺口(大行打捞/usage 键/自述方言)、Codex model、Claude Skill、
  通用 `toolCall` 驼峰。
- 8.3:Codex 上下文%(window×used)、Grok 原话(assistant 标签);本节首发。
- 9.0:→ 栏四缺口全部关闭——Cursor bubbles(KV 表最新 assistant bubble)、
  OpenCode 原话(role 经 message 表联查,part 单独不定作者)、Gemini 原话
  (整文档遍历取最后 model 回合)、Aider 原话(markdown 段落规则)。
  每条守卫式实现:表/列/版式不符 → 空,永不猜。

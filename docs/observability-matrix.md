# Agent observability contract

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

Every Agent still has a process fallback: real working directory, process age,
TTY/focus capability, and an explicit “activity unavailable” statement. That
fallback is detection, not rich session observability, and is never presented
as equivalent to a session/cache row.

Collector ingestion is bounded at 64 rows per Agent. The Swift model keeps 32
and reports the exact number of rows held back; the tray's global eight-row
fold is presentation only. This separation lets Pulse observe more than it
shows without allowing unbounded vendor stores to consume memory.

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

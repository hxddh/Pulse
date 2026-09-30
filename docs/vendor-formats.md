# Vendor contracts — where each hook's shape comes from

Pulse's state, and everything a row says, comes from the vendors' own hook /
plugin / extension events. It reads no vendor file: no session store, no
transcript. The title is the session's first prompt (the prompt event's own
text), the last words and a turn's error are what the turn event carried,
and the steps are the per-tool events (the tool and its target). Tokens,
context, cost and plan are never read — a decision `catalog_check` holds.
When a vendor changes a hook contract nothing fails loudly: an event stops
arriving, or (worse) a new one is read as the wrong state. So each contract
names the source it was read from.

| Agent | Title (prompt event) | Step (tool event) | Last words / error |
| --- | --- | --- | --- |
| Claude | `UserPromptSubmit` `prompt` | `PostToolUse(Failure)` `tool_name` + `tool_input` | `Stop` `last_assistant_message`; `StopFailure` error |
| Codex | `UserPromptSubmit` `prompt` | `PostToolUse` `tool_name` + `tool_input` | `Stop` `last_assistant_message` |
| Gemini | `BeforeAgent` `prompt` | `AfterTool` `tool_name` + `tool_input` | `AfterAgent` `prompt_response` |
| Copilot | `userPromptSubmitted` `prompt` | `postToolUse` `toolName` + `toolArgs` (a JSON string) | unrecoverable `errorOccurred` `error.message` |
| Pi | — (`agent_start` carries none) | `tool_execution_end`, forwarded as `tool_name` + one argument | — |
| OpenCode | — | — (no tool event) | `session.error` message |
| Cursor | — | — (no tool event) | — |

## The manifest

`docs/vendor-formats.json` has one entry per catalog agent, and each entry
holds only a `hooks` block:

| `source` | Meaning | Required fields |
| --- | --- | --- |
| `repo` | Open source; the receiver follows this commit | `repo`, `commit` (40 hex), `watch` (vendor files that define the hooks), `checked`, `events`, `tests` |
| `docs` | Closed source; public documentation was read | `urls`, `checked`, `events`, `tests` |

`events` must equal the catalog's `HookContract.events`. `tests` names test
files (grouped by component) that exercise the contract; each must exist and
mention the agent.

`scripts/catalog_check.py` (in `gates.sh`) fails when an agent has no entry,
an entry carries anything besides `hooks`, a repo block lacks a full commit or watch list, the
events disagree with the catalog, a named test file does not exist or never
mentions the agent, or the manifest names an agent the catalog no longer has.
It also holds two facts about the events themselves: an agent that can raise
a block installs at least one event that answers it
(`HookContract.answerEvents`: a per-tool activity event, or the vendor's own
"replied" / "prompt closed"), and Claude, Codex, Gemini and Copilot install
their per-tool activity event (`PostToolUse`, `AfterTool`, `postToolUse`) —
the answer to a permission, and the only silence that means a stall
(`HookContract.reportsToolActivity`). Each was checked non-blocking at exit 0
with empty output against the pinned source (Codex: `engine/discovery.rs`
runs every event but `SessionEnd` async when asked; Gemini: "Global hook
mechanics"; Copilot: "postToolUse output"). Codex is `hooks.json` only:
Pulse never touches its `config.toml`. Claude also installs
`PostToolUseFailure` (after a tool call fails; its output cannot change the
outcome), which answers a block for that tool like `PostToolUse`; it does
not install `PermissionDenied`, whose `hookSpecificOutput.retry` can change
what the model does. Every event the receiver reads becomes one line of the
one event log (`docs/attention-protocol.md`), tool activity included.
**Changing a hook contract means updating its block and its test in the same
change.**

## The sentinel

`.github/workflows/vendor-drift.yml` runs `scripts/vendor_drift.py` weekly
(and on demand). For every `repo` hooks block it makes a blob-less clone and
lists commits since the pin that touched a `watch` path. Any such commit
turns the run red and names the vendor, file and commits. It only reads
public repositories and prints; it writes nothing.

A red run is a prompt to read, not proof of breakage: read the commits, fix
the receiver and its test if the contract moved, then move the pin
(`commit`, `checked`) — the same change, so the gate and the sentinel agree.

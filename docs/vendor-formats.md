# Vendor contracts — where each hook's shape comes from

Since 24.0 Pulse's state comes from the vendors' own hook / plugin /
extension events. It no longer scans session stores; it reads one transcript
lazily — at a finished turn, a wait, or when the detail opens — for the
title, the last message, the model and the last error
(`PulseHarvest/TranscriptSummary.swift`, one dialect per agent, pinned by
`TranscriptSummaryTests`). When a vendor changes a hook contract nothing
fails loudly: an event stops arriving, or (worse) a new one is read as the
wrong state. So each contract names the source it was read from.

## The manifest

`docs/vendor-formats.json` has one entry per catalog agent, and each entry
holds only a `hooks` block:

| `source` | Meaning | Required fields |
| --- | --- | --- |
| `repo` | Open source; the receiver follows this commit | `repo`, `commit` (40 hex), `watch` (vendor files that define the hooks), `checked`, `events`, `tests` |
| `docs` | Closed source; public documentation was read | `urls`, `checked`, `events`, `tests` |

`events` must equal the catalog's `HookContract.events`. `tests` names test
files (by file; 23.0 grouped them by component) that exercise the contract;
each must exist and mention the agent.

`scripts/catalog_check.py` (in `gates.sh`) fails when an agent has no entry,
an entry carries anything besides `hooks` (the 20.0 format entries went with
the harvest in 24.0), a repo block lacks a full commit or watch list, the
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
mechanics"; Copilot: "postToolUse output"). Claude also installs
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

## History

20.0 pinned every agent's on-disk session format this way and found drift in
eleven of them (Gemini, OpenCode's fake `pending` Waiting, the Cline family,
Goose, Kimi, Grok, Copilot, Continue, OpenHands, Pi, Aider). 24.0 deleted the
session-store scanning those pins guarded; see CHANGELOG and git history.

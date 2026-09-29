# Vendor formats — where each parser's shape comes from

Pulse reads other programs' private session files. When a vendor changes its
format nothing fails: Pulse quietly reads less — no title, no last word, a
missed or (worse) invented Waiting. 18.0 found Codex's paginated rollouts and
20.0 found drift in eleven agents, every time by reading the vendor's own
source rather than waiting for a bug report that never comes.

## The manifest

`docs/vendor-formats.json` has one entry per catalog agent:

| `source` | Meaning | Required fields |
| --- | --- | --- |
| `repo` | Open source; the parser and its fixtures follow this commit | `repo`, `commit` (40 hex), `watch` (vendor files that define the format), `checked`, `tests` |
| `docs` | Closed source; public documentation was read | `urls`, `checked`, `tests` |
| `unverified` | Nothing public describes the format | `why` |

`scripts/vendor_formats_check.py` (in `gates.sh`) fails when an agent has no
entry, a repo entry lacks a full commit or watch list, a named test file does
not exist or never mentions the agent, or the manifest names an agent the
catalog no longer has. **Adding or changing a dialect means updating its entry
and its vendor-shaped fixture in the same change.**

## The sentinel

`.github/workflows/vendor-drift.yml` runs `scripts/vendor_drift.py` weekly
(and on demand). For every `repo` entry it makes a blob-less clone and lists
commits since the pin that touched a `watch` path. Any such commit turns the
run red and names the vendor, file and commits. It only reads public
repositories and prints; it writes nothing.

A red run is a prompt to read, not proof of breakage: read the commits, fix
the parser and fixture if the shape moved, then move the pin (`commit`,
`checked`) — the same change, so the gate and the sentinel agree.

## What 20.0 found

| Agent | Drift | Effect before 20.0 |
| --- | --- | --- |
| Gemini | JSONL records with `type: "gemini"`, `$set` checkpoints, subagent chats, sandbox root | No last word, ever |
| OpenCode | `pending` = tool input streaming; waits are in memory | **Fake Waiting** on every tool call |
| Cline / Roo / Kilo | `ts` clock unread; idle asks (`completion_result`) counted | **Fake Waiting** on every finished task |
| Goose | Sessions moved to `sessions.db` (v1.10) | Nothing read at all |
| Kimi Code | `wire.jsonl` events; `interaction.request` | Missed Waiting and last word; credentials folder walked |
| Grok Build | Search index is plain text; runs Claude's hooks | No last word; finished sessions "running"; Grok events shown as Claude |
| Copilot CLI | `session-state/<id>/events.jsonl` | Nothing read |
| Continue | `workspaceDirectory`, `history`, `chatModelTitle` | No cwd, model or last word |
| OpenHands | Conversation directories, `execution_status` | Explicit wait never read; one row per event file |
| Pi | Cache-warm `usage` entries | Idle sessions looked busy |
| Aider | History lives in each project | Declared a Waiting path it never had |

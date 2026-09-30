# Hook install policy — how the seven agents' own hooks light Pulse

Pulse supports seven agents, and reads each one only through the hook,
plugin or extension its vendor documents. Where each is installed, which
events it gets and what each event becomes are in
[`vendor-formats.md`](vendor-formats.md); the line each event writes is
[`attention-protocol.md`](attention-protocol.md). This page is the policy.

## Rules

- **Observe-only events.** Never PreToolUse, beforeShellExecution,
  BeforeTool, `tool.execute.before`, `tool_call`, permissionRequest or any
  other hook that can gate or change a decision
  (`HookContract.gatingEvents`), and never an answer: `pulse-hook` prints
  nothing and exits 0 at once. Claude's and Codex's entries are also
  `async`, so the vendor neither waits for them nor reads their output.
- **Byte-for-byte reversible.** Before Pulse first writes a file, it records
  the file's bytes (or that it did not exist) in
  `~/Library/Application Support/Pulse/hook-installs.json`. A removal puts
  the file back exactly when it is still what Pulse wrote (a file or folder
  that did not exist is deleted again); a file edited since loses only
  Pulse-marked entries. The Pulse mark is the whole `pulse-hook` command (a
  path ending in `/pulse-hook`, or the bare word) — a user's
  `impulse-hook.sh` is not Pulse's. Invalid JSON, JSONC with comments, and a
  `hooks` value that is not "event → array" are never rewritten, and the
  reason is said; CRLF line ends and a UTF-8 BOM are kept; an empty `[]` the
  user left stays. Codex is `hooks.json` only — `config.toml` is never
  touched. A module file of the same name that Pulse did not write is never
  overwritten.
- **Only agents on this Mac.** An agent whose vendor folder (`~/.claude`,
  `~/.gemini`, …) does not exist gets no install, and the setup card offers
  only agents that are here. An agent whose install failed is not offered
  again by the card; the card says why instead.
- **No fake Waiting.** Codex and Cursor show running and your turn only, and
  Settings says they do not report waiting. The receiver refuses a blocked
  line for them, and it reads only the agent's own vendor events — the
  protocol's kind words are not an input.

## Writing

The installer writes the native `pulse-hook` launcher into every contract;
nothing else writes the event log (`events.tsv`) but it and the app's own
dismissal. `pulse-hook` appends one whole line under the log's exclusive
lock. The hook also records the agent's process id (the first ancestor
matching the catalog's process rule — never the direct parent, usually a
`sh -c` that exits with the hook, and never a parent already reaped by
launchd) and the landing handles: `tmux:%3`, `iterm:<ITERM_SESSION_ID>`,
`tty:/dev/ttys004`, `term:<TERM_PROGRAM>`. It never forks and never runs
`ps` — `sysctl` and the environment only. A pid that later runs another
program, or started after the session, ends the session.

## What the person sees

- A block (`permission` / `question`): the red lamp, a banner (when on), and
  the ask on the row's second line.
- A finished turn (`turn`): a quiet "your turn" — never red, never a banner.
  Its words are the last words; a turn that ended on an error (tool =
  `error`) shows the error.
- A tool (`tool`): a running row's quiet second line — tool · target · how
  long ago; the prompt event's text is the title. No token, usage or cost
  field is read.
- Settings → Hooks is the diagnostics: one line per agent on this Mac
  (installed / not installed / failed and why, its last event, install and
  remove buttons), the absent agents in one line, Codex and Cursor marked
  "doesn't report when it waits". "Copy report" writes it as plain text.

## Removing everything

Settings → Hooks "Remove all" takes every hook out, byte for byte. Settings
→ "Uninstall Pulse…" does that first and — only when no hook is left —
removes the login item, deletes `~/Library/Application Support/Pulse` (the
event log, settings, the launcher and the install record), quits and shows
the app in Finder for the Trash. A hook that will not come out stops it
before anything else is removed.

## Boundaries

- Nothing is approved or denied in the tray; the answer is always given in
  the vendor's own prompt.
- Tools outside the roster are not supported: `pulse-hook` refuses an
  unknown agent.

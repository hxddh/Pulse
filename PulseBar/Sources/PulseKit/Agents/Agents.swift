import Foundation

// The agent roster: six agents, one adapter file each in this folder
// (`Claude.swift`, `Codex.swift`, `Cursor.swift`, `Pi.swift`,
// `Copilot.swift`, `OpenCode.swift`). An adapter is data where it can be —
// identity, process rule, where its hook is installed and in which format,
// each event with the action it means, whether it can report a wait — and
// a `read` for the few events whose meaning is in the payload. Nothing else
// in Pulse switches on an agent: the receiver reads through the adapter,
// the installer writes one of four formats, the process scan matches the
// rules in roster order.
//
// Adding an agent is a product decision (the roster is the owner's); then
// it is one `case` here, one adapter file, its icon, its README row, its
// truth table and its `docs/vendor-formats.json` entry —
// `scripts/catalog_check.py` holds the files to each other.
//
// Order is meaningful. `Agents.all` is `AgentID.allCases` order, which is
// also process-rule precedence (the first matching rule wins).

package enum AgentID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case claude, codex, cursor, pi, copilot, opencode

    package var id: String { rawValue }

    /// Everything the roster says about this agent.
    package var spec: AgentSpec { Agents.spec(self) }

    package var displayName: String { spec.displayName }

    /// Whether this agent's installed hook reports every tool call (see
    /// `HookContract.toolActivityEvents`).
    package var reportsToolActivity: Bool { spec.hooks.reportsToolActivity }

    /// Whether a silence from this agent can be a stall: its hook reports a
    /// tool's start and its end (`HookContract.silenceCanStall`). Any other
    /// agent's rows state facts only — never orange.
    package var silenceCanStall: Bool { spec.hooks.silenceCanStall }

    /// Whether a tool's step can answer this agent's block
    /// (`AgentSpec.stepsAnswerBlocks`).
    package var stepsAnswerBlocks: Bool { spec.stepsAnswerBlocks }

    /// Whether the vendor's hook says when a session is blocked on the user.
    /// Agents with `.none` still show running and your turn from their hooks.
    package var waitingSource: WaitingSource { spec.waiting }

    /// The order the person sees the agents in (Settings, the setup card,
    /// a report).
    package static let priority: [AgentID] = [
        .claude, .codex, .cursor, .copilot, .opencode, .pi,
    ]

    /// Agents whose hook never reports a blocked session — they show running
    /// and your turn only. Single source for Settings and L10n.
    package static var waitingNoneAgents: [AgentID] {
        priority.filter { $0.waitingSource == .none }
    }
}

/// Where an agent's "needs you" comes from: only the vendor's own hook (or
/// plugin/extension event) — never inference, never a file Pulse reads.
package enum WaitingSource: Sendable {
    /// The vendor's hook raises a blocked event (permission or question).
    case hooks
    /// Nothing the vendor reports says it is blocked: running and your turn
    /// only, and the product says so.
    case none
}

// MARK: - What an event means

/// What one vendor hook event means to Pulse.
package enum HookAction: Equatable, Sendable {
    /// A session began (or resumed).
    case start
    /// The user submitted a prompt: working, and nothing is owed any more.
    case prompt
    /// The agent is working (a tool ran, a reply streamed): a `tool` line.
    case activity
    /// Work goes on, but no tool ran — a status, a retry, a recoverable
    /// error: a `status` line, never a step and never the answer to a block.
    case status
    /// The agent cannot continue until the user acts.
    case blocked(AttentionKind)
    /// The turn is over: your turn.
    case turn
    /// The turn ended on an error (an API error, an unrecoverable failure):
    /// a `failed` line — your turn, and the error's text is the session's
    /// last error.
    case failedTurn
    /// The agent has sat at its prompt a while (Claude's `idle_prompt`):
    /// your turn only if the turn's end was not seen (`AttentionKind.idle`).
    case idle
    /// The person stopped the run at the agent's own prompt (Pi's aborted
    /// `agent_settled`): the turn is over and nothing is owed — a `stopped`
    /// line, never "your turn" with the partial words.
    case stopped
    /// The vendor's own name for the session (Pi's session name): a
    /// `title` line — the row's title, no state.
    case title
    /// The block was answered in the vendor's own prompt.
    case resolved
    /// The session ended.
    case end
    /// A known event that says nothing Pulse shows.
    case ignore
    /// A known event that is heard and not turned into state, for a reason
    /// of its own (Pi's `custom` prompt is a view, not a block).
    case skip(PulseHookReceiver.Ignored)
}

/// One event read by an agent's adapter: the action and, for a block, what
/// is being asked; for a tool, whether it failed, how long it took and —
/// when the adapter knows the tool better than the generic reading — its
/// target; for a `status` that names no tool, what it says; and which
/// subagent spoke (`AgentSpec.subagentKeys`, filled by `AgentSpec.reading`
/// for every event).
package struct HookReading: Equatable, Sendable {
    package var action: HookAction
    package var ask: String
    /// The vendor's subagent id; "" for the main agent.
    package var sub: String
    /// The tool the event reports failed.
    package var failed: Bool
    /// How long the tool ran, in ms; 0 unknown.
    package var tookMs: Int64
    /// The tool's target as the adapter reads it (Claude's `Agent` task's
    /// description, a `Skill`'s name); nil leaves the generic one
    /// (`PulseHookReceiver.toolDescriptor`).
    package var target: String?
    /// What a `status` line that names no tool says ("compacted"): fixed
    /// words of the adapter's, never the payload's prose.
    package var note: String
    /// The tool's name as the adapter reads it (Cursor's
    /// `afterShellExecution` is `Shell`, an MCP call `server · tool`); nil
    /// leaves the payload's `tool_name` / `toolName`.
    package var tool: String?
    /// The reply's words on an activity line that names no tool (Cursor's
    /// `afterAgentResponse` `text`): the turn's last words so far, kept
    /// for a turn line that carries none.
    package var words: String
    /// The session's name as the adapter reads it, for a `start` or a
    /// `title` line (Copilot's `initialPrompt`, a `-p` run's prompt); nil
    /// leaves the payload's `session_name`.
    package var name: String?

    package init(
        action: HookAction, ask: String = "", sub: String = "", failed: Bool = false, tookMs: Int64 = 0,
        target: String? = nil, note: String = "", tool: String? = nil, words: String = "", name: String? = nil
    ) {
        self.action = action
        self.ask = ask
        self.sub = sub
        self.failed = failed
        self.tookMs = tookMs
        self.target = target
        self.note = note
        self.tool = tool
        self.words = words
        self.name = name
    }
}

// MARK: - Hook contracts

/// One vendor event Pulse listens to, and what it means — unless the
/// adapter's `read` finds the meaning in the payload.
package struct HookEvent: Sendable, Equatable {
    /// The event name exactly as the vendor's configuration or API spells it.
    package let name: String
    /// What the event means when the payload does not say more.
    package let action: HookAction
    /// The vendor's matcher, where it has one (Claude's notification types).
    package let matcher: String?

    package init(_ name: String, _ action: HookAction, matcher: String? = nil) {
        self.name = name
        self.action = action
        self.matcher = matcher
    }
}

/// How the `nested` format writes one entry. Claude and Codex share the
/// shape and differ only here.
package struct NestedFlavor: Sendable {
    /// Every entry runs in the background (`"async": true`): the vendor
    /// reads no decision from it (an async hook's `decision`, `retry` or
    /// `continue` has nothing left to control).
    package var async: Bool
    /// Events the vendor always runs synchronously, with the timeout it caps
    /// them at (Codex's `SessionEnd`, 3 s): no `async`, a capped timeout.
    package var synchronous: [String: Int]
    /// Events that stay `async` but whose timeout the vendor caps (Codex's
    /// `Interrupt`, 3 s): written at the cap, so the vendor has nothing to
    /// clamp or warn about.
    package var timeoutCaps: [String: Int]
    /// A word the install report adds (a step the person takes once).
    package var installNote: String?

    package init(
        async: Bool, synchronous: [String: Int] = [:], timeoutCaps: [String: Int] = [:],
        installNote: String? = nil
    ) {
        self.async = async
        self.synchronous = synchronous
        self.timeoutCaps = timeoutCaps
        self.installNote = installNote
    }
}

/// A setting in the vendor's own config that keeps every hook Pulse
/// installed from running, read-only (Claude's `disableAllHooks`, its
/// managed `allowManagedHooksOnly`): Settings says the hook is installed
/// and silenced, instead of "nothing heard yet". Pulse never writes it.
package struct HookSwitch: Sendable, Equatable {
    /// The file: home-relative, or absolute when it starts with `/`.
    package let path: String
    /// `path` is a folder whose `*.json` files are each read (a drop-in
    /// directory, `managed-settings.d`).
    package let folder: Bool
    /// The top-level key whose `true` silences Pulse's hook.
    package let key: String
    /// What Settings says when it is set.
    package let caveat: Connection.Caveat

    package init(path: String, folder: Bool = false, key: String, caveat: Connection.Caveat) {
        self.path = path
        self.folder = folder
        self.key = key
        self.caveat = caveat
    }
}

/// How Pulse's hook is written. A closed set: the installer has one writer
/// per case, and an agent picks one with its flavor.
package enum HookFormat: Sendable {
    /// A user's settings file: `{"hooks": {Event: [{"matcher"?, "hooks":
    /// [{"type": "command", "command", "timeout", "async"?}]}]}}`. Only the
    /// `hooks` member is rewritten; an emptied `hooks` goes on removal.
    case nested(NestedFlavor)
    /// A user's hook file: `{"version": 1, "hooks": {event: [{<commandKey>}]}}`.
    /// Only `hooks` is rewritten; it stays (maybe empty) on removal.
    case versioned(commandKey: String)
    /// A JSON hook file Pulse owns whole: `{"version": 1, "hooks": {event:
    /// [{"type": "command", <command>, <timeoutKey>, "matcher"?}]}}`.
    case ownedJSON(command: OwnedCommand, timeoutKey: String)
    /// A JavaScript module Pulse owns whole (a plugin, an extension),
    /// rendered from the launcher path and the event names.
    case module(render: @Sendable (_ launcher: String, _ events: [String]) -> String)

    /// Pulse owns the whole file: it writes it, and removal deletes it.
    package var ownsFile: Bool {
        switch self {
        case .nested, .versioned: return false
        case .ownedJSON, .module: return true
        }
    }
}

/// How an `ownedJSON` entry runs Pulse's launcher.
package enum OwnedCommand: Sendable, Equatable {
    /// A shell command line under this key (`"bash": "<launcher> <agent>
    /// <event>"`).
    case shell(key: String)
    /// The launcher run directly, no shell (Copilot CLI's `exec` +
    /// `args`): `"exec": "<launcher>", "args": [<agent>, <event>]` — a path
    /// with a space needs no quoting, and nothing is interpreted.
    case exec
}

/// The documented, non-blocking hook Pulse installs for one agent.
///
/// The rule: install only the vendor's documented hook, plugin or
/// extension; only events that cannot change the agent's decisions — never a
/// tool-gating event, never anything that returns a decision (Pulse's hook
/// prints nothing and exits 0; Claude and Codex entries also run `async`,
/// and an async entry's decision output is never read — so an event whose
/// only control is a decision, Claude's `PermissionDenied` `retry`, is
/// observe-only there); and every install is reversible byte for byte.
package struct HookContract: Sendable {
    package let format: HookFormat
    /// Home-relative file Pulse edits (or, for an owned format, owns whole).
    package let path: String
    /// Home-relative directory the vendor itself creates. Pulse installs only
    /// where it exists: no config is planted for an agent that is not there.
    package let home: String
    /// Events Pulse listens to, in the vendor's spelling, each with what it
    /// means.
    package let events: [HookEvent]
    /// Where the vendor reads `path` from when nothing moved it, and the
    /// environment variable that can move it (Pi's `PI_CODING_AGENT_DIR`).
    /// Pulse honours no environment — a GUI app cannot read the shell's —
    /// so when this folder is missing on a Mac where the agent is present,
    /// Settings says where Pulse installs (`Connection.configDirMissing`).
    package let relocation: Relocation?

    /// A config folder the vendor lets an environment variable move.
    package struct Relocation: Sendable, Equatable {
        /// Home-relative folder (`.pi/agent`).
        package let dir: String
        /// The variable that moves it.
        package let variable: String

        package init(dir: String, variable: String) {
            self.dir = dir
            self.variable = variable
        }
    }

    /// Vendor settings that silence every hook Pulse installed, read only
    /// to say so (`HookSwitch`); the most specific first — a managed policy
    /// before the person's own setting.
    package let offSwitches: [HookSwitch]

    package init(
        format: HookFormat, path: String, home: String, events: [HookEvent], relocation: Relocation? = nil,
        offSwitches: [HookSwitch] = []
    ) {
        self.format = format
        self.path = path
        self.home = home
        self.events = events
        self.relocation = relocation
        self.offSwitches = offSwitches
    }

    /// The installed event of this name; nil for one Pulse does not install
    /// (it is not read).
    package func event(named name: String) -> HookEvent? {
        events.first { $0.name == name }
    }

    /// Events that gate a tool call or a permission before the vendor asks
    /// the user — or whose hook takes the vendor's place (Claude's
    /// `Elicitation` can answer an MCP form, `WorktreeCreate` makes the
    /// worktree, `MessageDisplay` replaces what is shown). Pulse never
    /// installs one: its answer could change what the agent does, and a
    /// slow or missing hook could stall it. `catalog_check` and
    /// `AgentCatalogTests` hold every contract to this list.
    package static let gatingEvents: Set<String> = [
        "PreToolUse", "preToolUse", "BeforeTool", "BeforeModel", "BeforeToolSelection",
        "Elicitation", "WorktreeCreate", "MessageDisplay",
        "beforeShellExecution", "beforeMCPExecution", "beforeReadFile", "beforeSubmitPrompt",
        "permissionRequest", "userPromptTransformed",
        "tool.execute.before", "tool.execute.after", "chat.message", "chat.params",
        "tool_call", "tool_result", "permission.ask",
        "before_agent_start", "input", "turn_end", "message_end", "user_bash",
        "session_before_switch", "session_before_fork", "session_before_compact", "session_before_tree",
    ]

    /// Observe-only events that fire once per tool call, after it ran
    /// (Claude and Codex `PostToolUse`, Copilot `postToolUse`, Pi
    /// `tool_execution_end`, OpenCode's finished tool part — 1.x
    /// `message.part.updated`, 2.x `session.tool.success` / `failed` —
    /// and Cursor's `afterShellExecution` / `afterFileEdit` /
    /// `afterMCPExecution`). An agent whose contract installs one reports
    /// its work as it goes — its steps — and its tool name is what answers
    /// a block raised for that tool. Its silence is a stall only when it
    /// also reports a tool's start (`toolStartEvents`).
    package static let toolActivityEvents: Set<String> = [
        "PostToolUse", "PostToolUseFailure", "postToolUse", "postToolUseFailure",
        "tool_execution_end",
        "message.part.updated", "session.tool.success", "session.tool.failed",
        "afterShellExecution", "afterFileEdit", "afterMCPExecution",
    ]

    /// Events that say a block was answered: a tool ran after it, or the
    /// vendor's own "replied" / "prompt closed". `catalog_check` holds every
    /// agent that can raise a block to installing at least one — a red lamp
    /// must have a way to go out besides the end of the turn.
    package static let answerEvents: Set<String> = toolActivityEvents.union([
        "permission.replied", "question.replied", "question.rejected", "ui_prompt_end",
        "form.replied", "form.cancelled",
    ])

    /// Observe-only events that say a tool started and has not finished
    /// yet (Pi `tool_execution_start`, OpenCode's running tool part — 1.x
    /// `message.part.updated`, 2.x `session.tool.called`): a `status` line
    /// that names its tool, what runs now. Only an agent that reports a
    /// tool's start as well as its end can be said to have stalled: from
    /// any other, a long tool is a silence just like a stall (a 25-minute
    /// build says nothing until it ends).
    package static let toolStartEvents: Set<String> = [
        "tool_execution_start", "message.part.updated", "session.tool.called",
    ]

    /// This contract installs a per-tool activity event (`toolActivityEvents`).
    package var reportsToolActivity: Bool {
        events.contains { Self.toolActivityEvents.contains($0.name) }
    }

    /// This contract installs an event that says a tool started
    /// (`toolStartEvents`).
    package var reportsToolStart: Bool {
        events.contains { Self.toolStartEvents.contains($0.name) }
    }

    /// A silence from this agent can be a stall: it reports each tool's
    /// start and its end, so a tool that runs long is said to run
    /// (`SessionBook.Session.runningSteps`) and only a silence with nothing
    /// running is news. Every other agent's rows state facts only — never
    /// orange.
    package var silenceCanStall: Bool { reportsToolActivity && reportsToolStart }
}

/// Which processes are this agent, by executable path and argv. See
/// `AgentProcesses.match(args:)`: the hook's pid lookup and the process scan
/// (libproc, no `ps`) share it.
package struct AgentProcessRule: Sendable {
    package var basenames: [String]
    package var pathNeedles: [String]
    /// Fragments of the program itself — the executable, or an
    /// interpreter's script — that say it is not the agent (never the
    /// arguments: `pi ./pipeline.ts` is Pi).
    package var denyNeedles: [String]
    /// Fragments of the whole command line that say it is not the agent: an
    /// argument (`--worker-dir`), or a path with a space in it.
    package var argvDenyNeedles: [String]
    /// Some real CLIs intentionally use a short executable name (`pi`).
    /// Their exact basename is useful evidence after the deny list has run;
    /// length alone must not make a live agent vanish.
    package var allowBareBasename: Bool
    /// Arguments that run the agent with nobody at a prompt (Claude's
    /// `-p` / `--print`): a blocked event from such a process is a request
    /// no one can be shown — an `ignored` line, never a red lamp.
    package var promptlessFlags: [String]
    /// Arguments that give such a run a prompt after all (Claude's
    /// `--permission-prompt-tool`: an SDK host answers it), alone or as
    /// `flag=value`.
    package var promptHostFlags: [String]

    package init(
        basenames: [String],
        pathNeedles: [String],
        denyNeedles: [String] = [],
        argvDenyNeedles: [String] = [],
        allowBareBasename: Bool = false,
        promptlessFlags: [String] = [],
        promptHostFlags: [String] = []
    ) {
        self.basenames = basenames
        self.pathNeedles = pathNeedles
        self.denyNeedles = denyNeedles
        self.argvDenyNeedles = argvDenyNeedles
        self.allowBareBasename = allowBareBasename
        self.promptlessFlags = promptlessFlags
        self.promptHostFlags = promptHostFlags
    }

    /// The agent process with this argv can show nobody a prompt: it
    /// carries a promptless flag and no prompt host. Whole arguments only.
    /// Pure.
    package func cannotPrompt(argv: [String]) -> Bool {
        guard !promptlessFlags.isEmpty, argv.contains(where: { promptlessFlags.contains($0) }) else { return false }
        return !argv.contains { argument in
            promptHostFlags.contains { argument == $0 || argument.hasPrefix($0 + "=") }
        }
    }
}

/// One agent's adapter: everything Pulse knows about it.
package struct AgentSpec: Sendable {
    package let id: AgentID
    package let displayName: String
    /// Other spellings a hook or bridge may use for this agent, beyond
    /// its raw value.
    package let aliases: [String]
    /// Whether the vendor's own hook reports a blocked session.
    package let waiting: WaitingSource
    /// A tool's step can answer a block (the person said yes in the
    /// vendor's prompt and the tool ran) — `SessionBook.answers`. False for
    /// an adapter whose own module sends every ask's reply, with how many
    /// asks are still open (OpenCode's `pending`): there a tool's step
    /// answers nothing — two parallel asks of one tool are answered one
    /// reply at a time, never by the first one's step.
    package let stepsAnswerBlocks: Bool
    package let process: AgentProcessRule
    /// The vendor's documented, non-blocking hook Pulse installs.
    package let hooks: HookContract
    /// Environment variables another tool sets when it runs this agent's
    /// hooks as its own (xAI's Grok Build runs `~/.claude/settings.json`'s):
    /// such a call is not this agent speaking, and writes nothing.
    package let foreignCallers: [String]
    /// Payload keys that name the subagent an event came from (Claude's
    /// and Codex's `agent_id`, Copilot's `agentId`); absent or empty for
    /// the main agent. The line's `sub` column.
    package let subagentKeys: [String]
    /// The adapter's own module sends the agent's pid (`pid`) and spawns
    /// the hook directly: the receiver takes it only when it is the hook's
    /// own parent (`PulseHookReceiver.claimedPID`).
    package let reportsOwnPID: Bool
    /// Payload keys that name the session, most trusted first
    /// (`HookContext.sessionKeys` unless the vendor spells it otherwise:
    /// Cursor's `conversation_id` is the one every event carries, its
    /// `session_id` only some).
    package let sessionKeys: [String]
    /// The reading of an event whose meaning is in its payload; nil leaves
    /// the event's own action (`HookEvent.action`). Called only for an
    /// installed event.
    package let read: @Sendable (_ event: String, _ payload: [String: Any]) -> HookReading?

    package init(
        id: AgentID,
        displayName: String,
        aliases: [String] = [],
        waiting: WaitingSource,
        stepsAnswerBlocks: Bool = true,
        process: AgentProcessRule,
        hooks: HookContract,
        foreignCallers: [String] = [],
        subagentKeys: [String] = [],
        reportsOwnPID: Bool = false,
        sessionKeys: [String] = HookContext.sessionKeys,
        read: @escaping @Sendable (_ event: String, _ payload: [String: Any]) -> HookReading? = { _, _ in nil }
    ) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.waiting = waiting
        self.stepsAnswerBlocks = stepsAnswerBlocks
        self.process = process
        self.hooks = hooks
        self.foreignCallers = foreignCallers
        self.subagentKeys = subagentKeys
        self.reportsOwnPID = reportsOwnPID
        self.sessionKeys = sessionKeys
        self.read = read
    }

    /// What one installed event means, payload read; nil for an event Pulse
    /// does not install — it writes nothing. The subagent that spoke is
    /// read here for every event (`subagentKeys`).
    package func reading(_ event: String, payload: [String: Any]) -> HookReading? {
        guard let hook = hooks.event(named: event) else { return nil }
        var reading = self.read(event, payload) ?? HookReading(action: hook.action)
        if reading.sub.isEmpty, !subagentKeys.isEmpty {
            reading.sub = PulseHookReceiver.string(payload, keys: subagentKeys)
        }
        return reading
    }
}

/// The registry.
package enum Agents {
    /// One adapter per `AgentID`, in declaration order.
    package static let all: [AgentSpec] = [
        .claude, .codex, .cursor, .pi, .copilot, .opencode,
    ]

    private static let byID: [AgentID: AgentSpec] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    /// Every `AgentID` has exactly one spec — `AgentCatalogTests` holds the
    /// roster to that, so this lookup cannot miss in a shipped build.
    package static func spec(_ id: AgentID) -> AgentSpec {
        guard let spec = byID[id] else {
            preconditionFailure("Agents has no spec for \(id.rawValue)")
        }
        return spec
    }

    /// Raw value or any alias, as a hook or a bridge may spell it.
    package static func agent(named raw: String) -> AgentID? {
        if let id = AgentID(rawValue: raw) { return id }
        return all.first { $0.aliases.contains(raw) }?.id
    }
}

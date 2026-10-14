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
    /// `HookContract.toolActivityEvents`). Only then does silence mean a
    /// stall: an agent that speaks only at a prompt and at the end of a turn
    /// is silent through every long turn.
    package var reportsToolActivity: Bool { spec.hooks.reportsToolActivity }

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
    /// The block was answered in the vendor's own prompt.
    case resolved
    /// The session ended.
    case end
    /// A known event that says nothing Pulse shows.
    case ignore
}

/// One event read by an agent's adapter: the action and, for a block, what
/// is being asked.
package struct HookReading: Equatable, Sendable {
    package var action: HookAction
    package var ask: String

    package init(action: HookAction, ask: String = "") {
        self.action = action
        self.ask = ask
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
    /// ignores anything it could return.
    package var async: Bool
    /// Events the vendor always runs synchronously, with the timeout it caps
    /// them at (Codex's `SessionEnd`, 3 s): no `async`, a capped timeout.
    package var synchronous: [String: Int]
    /// A word the install report adds (a step the person takes once).
    package var installNote: String?

    package init(async: Bool, synchronous: [String: Int] = [:], installNote: String? = nil) {
        self.async = async
        self.synchronous = synchronous
        self.installNote = installNote
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
    /// [{"type": "command", <commandKey>, <timeoutKey>}]}}`.
    case ownedJSON(commandKey: String, timeoutKey: String)
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

/// The documented, non-blocking hook Pulse installs for one agent.
///
/// The rule: install only the vendor's documented hook, plugin or
/// extension; only events that cannot change the agent's decisions — never a
/// tool-gating event, never anything that returns a decision (Pulse's hook
/// prints nothing and exits 0; Claude and Codex entries also run `async`);
/// and every install is reversible byte for byte.
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

    package init(format: HookFormat, path: String, home: String, events: [HookEvent]) {
        self.format = format
        self.path = path
        self.home = home
        self.events = events
    }

    /// The installed event of this name; nil for one Pulse does not install
    /// (it is not read).
    package func event(named name: String) -> HookEvent? {
        events.first { $0.name == name }
    }

    /// Events that gate a tool call or a permission before the vendor asks
    /// the user. Pulse never installs one: its answer could change what the
    /// agent does, and a slow or missing hook could stall it. `catalog_check`
    /// and `AgentCatalogTests` hold every contract to this list.
    package static let gatingEvents: Set<String> = [
        "PreToolUse", "preToolUse", "BeforeTool", "BeforeModel", "BeforeToolSelection",
        "beforeShellExecution", "beforeMCPExecution", "beforeReadFile", "beforeSubmitPrompt",
        "permissionRequest", "tool.execute.before", "tool_call", "tool_result", "permission.ask",
        "before_agent_start", "input", "turn_end", "message_end", "user_bash",
    ]

    /// Observe-only events that fire once per tool call, after it ran
    /// (Claude and Codex `PostToolUse`, Copilot `postToolUse`, Pi
    /// `tool_execution_end`). An agent whose contract installs one reports
    /// its work as it goes: silence from it means something, so only such an
    /// agent can be stalled — and its tool name is what answers a block
    /// raised for that tool.
    package static let toolActivityEvents: Set<String> = [
        "PostToolUse", "PostToolUseFailure", "postToolUse", "postToolUseFailure",
        "tool_execution_end",
    ]

    /// Events that say a block was answered: a tool ran after it, or the
    /// vendor's own "replied" / "prompt closed". `catalog_check` holds every
    /// agent that can raise a block to installing at least one — a red lamp
    /// must have a way to go out besides the end of the turn.
    package static let answerEvents: Set<String> = toolActivityEvents.union([
        "permission.replied", "question.replied", "question.rejected", "ui_prompt_end",
    ])

    /// This contract installs a per-tool activity event (`toolActivityEvents`).
    package var reportsToolActivity: Bool {
        events.contains { Self.toolActivityEvents.contains($0.name) }
    }
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

    package init(
        basenames: [String],
        pathNeedles: [String],
        denyNeedles: [String] = [],
        argvDenyNeedles: [String] = [],
        allowBareBasename: Bool = false
    ) {
        self.basenames = basenames
        self.pathNeedles = pathNeedles
        self.denyNeedles = denyNeedles
        self.argvDenyNeedles = argvDenyNeedles
        self.allowBareBasename = allowBareBasename
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
    package let process: AgentProcessRule
    /// The vendor's documented, non-blocking hook Pulse installs.
    package let hooks: HookContract
    /// Environment variables another tool sets when it runs this agent's
    /// hooks as its own (xAI's Grok Build runs `~/.claude/settings.json`'s):
    /// such a call is not this agent speaking, and writes nothing.
    package let foreignCallers: [String]
    /// The reading of an event whose meaning is in its payload; nil leaves
    /// the event's own action (`HookEvent.action`). Called only for an
    /// installed event.
    package let read: @Sendable (_ event: String, _ payload: [String: Any]) -> HookReading?

    package init(
        id: AgentID,
        displayName: String,
        aliases: [String] = [],
        waiting: WaitingSource,
        process: AgentProcessRule,
        hooks: HookContract,
        foreignCallers: [String] = [],
        read: @escaping @Sendable (_ event: String, _ payload: [String: Any]) -> HookReading? = { _, _ in nil }
    ) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.waiting = waiting
        self.process = process
        self.hooks = hooks
        self.foreignCallers = foreignCallers
        self.read = read
    }

    /// What one installed event means, payload read; nil for an event Pulse
    /// does not install — it writes nothing.
    package func reading(_ event: String, payload: [String: Any]) -> HookReading? {
        guard let hook = hooks.event(named: event) else { return nil }
        return self.read(event, payload) ?? HookReading(action: hook.action)
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

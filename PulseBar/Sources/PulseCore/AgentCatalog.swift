import Foundation

// The agent roster — every fact Pulse holds about a vendor that is not parsing
// code, in one place.
//
// Adding an agent is one `case` and one `AgentSpec` in this file, plus its
// icon, README row and `docs/vendor-formats.json` entry — and
// `scripts/catalog_check.py` fails CI if a per-agent switch grows back
// anywhere else.
//
// 24.0 (Exact): Pulse supports seven agents, each through the vendor's own
// documented, non-blocking hook, plugin or extension (`hooks`). The others
// were removed with their collectors; Cursor's IDE and its `cursor-agent`
// CLI are one agent.
//
// Order is meaningful. `AgentCatalog.all` is `AgentID.allCases` order, which
// is also process-rule precedence (the first matching rule wins) and harvest
// descriptor order (the starting point of the rotation under budget).

public enum AgentID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case claude, codex, cursor, pi, gemini, copilot, opencode

    public var id: String { rawValue }

    /// Everything the roster says about this agent.
    public var spec: AgentSpec { AgentCatalog.spec(self) }

    public var displayName: String { spec.displayName }

    /// Whether the vendor's hook says when a session is blocked on the user.
    /// Agents with `.none` still show running and your turn from their hooks.
    public var waitingSource: WaitingSource { spec.waiting }

    /// What the local collector is allowed to promise before runtime data is
    /// considered. Every agent can still degrade to process detection.
    ///
    /// `structuredSession` means the adapter reads a session/thread/composer
    /// identity and its activity facts. `bestEffortCache` means the vendor
    /// exposes no stable local session contract and Pulse may only recover a
    /// workspace or title. The README matrix is checked against this value.
    public var harvestSource: HarvestSource { spec.harvest }

    /// Some adapters keep their only useful session/cache evidence inside
    /// macOS-protected Application Support stores. The default scanner
    /// deliberately skips those locations; the support window uses this bit
    /// to explain that an unavailable row may be privacy-limited, not
    /// unsupported.
    public var requiresAppDataOptIn: Bool { spec.requiresAppDataOptIn }

    public static let priority: [AgentID] = [
        .claude, .codex, .cursor, .gemini, .copilot, .opencode, .pi,
    ]

    /// Agents whose hook never reports a blocked session — they show running
    /// and your turn only. Single source for Settings, Diagnostics and L10n.
    public static var waitingNoneAgents: [AgentID] {
        priority.filter { $0.waitingSource == .none }
    }
}

/// Where an agent's "needs you" comes from. 24.0: only the vendor's own hook
/// (or plugin/extension event) — never inference, never a transcript read.
public enum WaitingSource: Sendable {
    /// The vendor's hook raises a blocked event (permission or question).
    case hooks
    /// Nothing the vendor reports says it is blocked: running and your turn
    /// only, and the product says so.
    case none
}

public enum HarvestSource: Sendable {
    case structuredSession
    case bestEffortCache
}

// MARK: - Hook contracts (24.0)

/// How Pulse's hook is written into a vendor's configuration. One case per
/// documented configuration shape.
public enum HookFormat: String, Sendable {
    /// Claude Code `~/.claude/settings.json`: `{"hooks": {Event: [{"matcher"?,
    /// "hooks": [{"type": "command", "command", "timeout", "async": true}]}]}}`.
    case claudeSettings
    /// Codex `~/.codex/hooks.json` (same nested shape, `async` honoured) plus
    /// the legacy `notify` argv in `~/.codex/config.toml`.
    case codexHooks
    /// Gemini CLI `~/.gemini/settings.json` `hooks` (nested shape, `timeout`
    /// in milliseconds, a `name`).
    case geminiSettings
    /// Copilot CLI `~/.copilot/hooks/<file>.json`: `{"version": 1, "hooks":
    /// {event: [{"type": "command", "bash", "timeoutSec"}]}}` — a file Pulse
    /// owns whole.
    case copilotHooks
    /// Cursor `~/.cursor/hooks.json`: `{"version": 1, "hooks": {event:
    /// [{"command"}]}}`.
    case cursorHooks
    /// An OpenCode plugin module Pulse owns whole (`~/.config/opencode/plugins`).
    case openCodePlugin
    /// A Pi extension module Pulse owns whole (`~/.pi/agent/extensions`).
    case piExtension

    /// Pulse owns the whole file (it did not exist before, and uninstall
    /// removes it), rather than adding entries to the user's own config.
    public var ownsFile: Bool {
        self == .copilotHooks || self == .openCodePlugin || self == .piExtension
    }
}

/// One vendor event Pulse listens to.
public struct HookEvent: Sendable, Equatable {
    /// The event name exactly as the vendor's configuration or API spells it.
    public let name: String
    /// The vendor's matcher, where it has one (Claude's notification types).
    public let matcher: String?

    public init(_ name: String, matcher: String? = nil) {
        self.name = name
        self.matcher = matcher
    }
}

/// The documented, non-blocking hook Pulse installs for one agent.
///
/// The rule (24.0): install only the vendor's documented hook, plugin or
/// extension; only events that cannot change the agent's decisions — never a
/// tool-gating event, never anything that returns a decision (Pulse's hook
/// prints nothing and exits 0; Claude and Codex entries also run `async`);
/// and every install is reversible byte for byte.
public struct HookContract: Sendable {
    public let format: HookFormat
    /// Home-relative file Pulse edits (or owns, see `HookFormat.ownsFile`).
    public let path: String
    /// Home-relative directory the vendor itself creates. Pulse installs only
    /// where it exists: no config is planted for an agent that is not there.
    public let home: String
    /// Events Pulse listens to, in the vendor's spelling.
    public let events: [HookEvent]

    public init(format: HookFormat, path: String, home: String, events: [HookEvent]) {
        self.format = format
        self.path = path
        self.home = home
        self.events = events
    }

    /// Events that gate a tool call or a permission before the vendor asks
    /// the user. Pulse never installs one: its answer could change what the
    /// agent does, and a slow or missing hook could stall it. `catalog_check`
    /// and `AgentCatalogTests` hold every contract to this list.
    public static let gatingEvents: Set<String> = [
        "PreToolUse", "preToolUse", "BeforeTool", "BeforeModel", "BeforeToolSelection",
        "beforeShellExecution", "beforeMCPExecution", "beforeReadFile", "beforeSubmitPrompt",
        "permissionRequest", "tool.execute.before", "tool_call", "permission.ask",
    ]
}

public enum TranscriptPolicy: Sendable {
    /// No transcript files, or none read as transcripts.
    case none
    /// Read transcripts; skip idle files outside the fresh window, and allow
    /// a bounded read of a large one.
    case freshWindow
    /// Read transcripts whatever their age (Pi: the idle JSONL is the title
    /// source), with the same bounded large read.
    case alwaysRead

    public var skipsStaleFiles: Bool { self == .freshWindow }
    public var allowsBoundedLargeFiles: Bool { self != .none }
}

/// A vendor store read through SQLite rather than as transcript files.
public enum DatabaseAdapter: Sendable {
    case cursor, openCode, pi

    /// Whether a database file of the right extension is this vendor's store
    /// at all. OpenCode's data directory also holds git snapshots, worktree
    /// checkouts and repos whose own `.db` files are not OpenCode's — opening
    /// one failed the adapter.
    public func admits(fileName: String) -> Bool {
        let name = fileName.lowercased()
        switch self {
        case .openCode: return name.hasPrefix("opencode") && name.hasSuffix(".db")
        default: return true
        }
    }

    /// File extensions the walk hands to this adapter instead of the
    /// transcript reader.
    public var extensions: Set<String> {
        self == .cursor ? ["vscdb", "sqlite", "db"] : ["sqlite", "db"]
    }

    /// Pi's JSONL carries the /resume title; its sibling SQLite must not run
    /// before those transcripts or the row loses its hero.
    public var runsAfterTranscripts: Bool { self == .pi }

    /// A file that will not open as SQLite fails the adapter — except for Pi,
    /// whose tree holds incidental non-SQLite `.db` files beside the JSONL
    /// that is its real source.
    public var failsOnUnreadableFile: Bool { self != .pi }
}

/// Which transcript files under an agent's roots are session evidence.
public enum TranscriptSelection: Equatable, Sendable {
    /// Every transcript-shaped file.
    case all
    /// None: the database is authoritative and the rest of the tree is noise
    /// (OpenCode's snapshots and checkouts).
    case none
    /// Only paths containing this fragment, lowercased (Pi's session tree,
    /// Gemini's chats — their roots also hold caches and checkouts).
    case pathContains(String)

    public func admits(_ lowercasedPath: String) -> Bool {
        switch self {
        case .all: return true
        case .none: return false
        case .pathContains(let fragment): return lowercasedPath.contains(fragment)
        }
    }
}

/// How the native collector walks and reads one agent's roots. The defaults
/// are the generic adapter; an agent states only where it differs.
public struct HarvestWalk: Sendable {
    public var database: DatabaseAdapter? = nil
    public var transcripts: TranscriptSelection = .all
    /// Directory names the walk normally skips but this agent keeps.
    public var keptDirectoryNames: Set<String> = []
    /// Directory names (lowercased) this agent's walk never descends into:
    /// files there are read another way, and walking them would spend the
    /// per-agent visit budget or merge them into the wrong row.
    public var skippedDirectoryNames: Set<String> = []
    /// A path fragment (lowercased) that marks a file as a structured session
    /// even where the generic session-path rule would not.
    public var structuredPathFragment: String? = nil
    /// Largest transcript file read at all; nil means the default for the
    /// agent's transcript policy.
    public var maxFileBytes: Int? = nil
    /// Bytes read per transcript window, and how many of them from the head.
    public var windowBytes = 1_000_000
    public var headBytes = 64_000
    /// The adapter's own time budget; nil means the shared default.
    public var deadlineSeconds: Double? = nil
    /// "continue" / "go on" prompts are not tasks — for agents whose
    /// transcripts record them as ordinary user turns.
    public var dropsContinuationPrompts = false
    /// Home-relative path of the generic vendor-shaped fixture the native
    /// fixture wall writes for this agent (`--native-fixture-test`). Agents
    /// with a hand-written fixture of their own leave it nil.
    public var fixturePath: String? = nil
}

/// Which `ps` argv lines are this agent. See `ProcessProbe.matchEvidence`.
public struct AgentProcessRule: Sendable {
    public var basenames: [String]
    public var pathNeedles: [String]
    public var denyNeedles: [String]
    /// Some real CLIs intentionally use a short executable name (`pi`).
    /// Their exact basename is useful evidence after the deny list has run;
    /// length alone must not make a live agent vanish.
    public var allowBareBasename: Bool = false
}

public struct AgentSpec: Sendable {
    public let id: AgentID
    public let displayName: String
    /// Fallback glyph when the PNG/SVG mark is missing — unique across the
    /// roster. The mark itself is `Resources/AgentIcons/<rawValue>.png|svg`.
    public let monogram: String
    /// Whether the vendor's own hook reports a blocked session (24.0).
    public let waiting: WaitingSource
    public let harvest: HarvestSource
    public let requiresAppDataOptIn: Bool
    public let transcripts: TranscriptPolicy
    /// Other spellings a hook or bridge may use for this agent, beyond
    /// its raw value.
    public let aliases: [String]
    public let process: AgentProcessRule
    /// Home-relative roots the native collector walks.
    public let harvestRoots: [String]
    /// Executables whose presence says the agent is installed.
    public let harvestCommands: [String]
    /// The vendor's documented, non-blocking hook Pulse installs (24.0).
    public let hooks: HookContract
    /// How the collector walks and reads those roots.
    public var walk = HarvestWalk()
}

public enum AgentCatalog {
    public static let all: [AgentSpec] = [
        AgentSpec(
            id: .claude,
            displayName: "Claude",
            monogram: "Cl",
            // PermissionRequest (at once) and Notification permission_prompt,
            // elicitation_dialog, agent_needs_input (about six seconds later).
            waiting: .hooks,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            aliases: [],
            process: AgentProcessRule(basenames: ["claude"], pathNeedles: ["/.local/bin/claude", "/bin/claude"], denyNeedles: ["Claude.app", "chrome-native-host"]),
            harvestRoots: [".claude/projects", ".claude/tasks"],
            harvestCommands: ["claude"],
            // Every entry runs `async: true`: an async hook cannot block or
            // decide anything (code.claude.com/docs/en/hooks, "Run hooks in
            // the background"). PostToolUse, not PreToolUse, marks activity.
            hooks: HookContract(format: .claudeSettings, path: ".claude/settings.json", home: ".claude", events: [
                HookEvent("SessionStart"),
                HookEvent("SessionEnd"),
                HookEvent("UserPromptSubmit"),
                HookEvent("PostToolUse"),
                HookEvent("PermissionRequest"),
                HookEvent("Notification", matcher: "permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog|elicitation_complete|elicitation_response"),
                HookEvent("Stop"),
                HookEvent("StopFailure"),
            ]),
            // `<session>/subagents/agent-*.jsonl` are sidechains: counted by
            // `claudeSubagentCounts`, never their parent's hero or last word.
            walk: HarvestWalk(skippedDirectoryNames: ["subagents"], dropsContinuationPrompts: true, fixturePath: ".claude/projects/fixture.jsonl")
        ),
        AgentSpec(
            id: .codex,
            displayName: "Codex",
            monogram: "Cx",
            // 24.0: Codex's PermissionRequest fires before its own
            // auto-review, so an approval nobody is asked for would light a
            // red lamp (openai/codex#28833). Its hooks say running and your
            // turn; they never say blocked.
            waiting: .none,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            aliases: [],
            process: AgentProcessRule(basenames: ["codex"], pathNeedles: ["/opt/homebrew/bin/codex", "/bin/codex", "Resources/codex"], denyNeedles: ["Codex Framework", "crashpad", "computer-use", "codex-code-mode-host"]),
            harvestRoots: [".codex/sessions", ".codex/rollouts"],
            harvestCommands: ["codex"],
            hooks: HookContract(format: .codexHooks, path: ".codex/hooks.json", home: ".codex", events: [
                HookEvent("SessionStart"),
                HookEvent("SessionEnd"),
                HookEvent("UserPromptSubmit"),
                HookEvent("Stop"),
            ]),
            walk: HarvestWalk(windowBytes: 8_000_000, deadlineSeconds: 1.2, fixturePath: ".codex/sessions/fixture/rollout-fixture.jsonl")
        ),
        AgentSpec(
            id: .cursor,
            displayName: "Cursor",
            monogram: "Cu",
            // No Cursor hook reports a pending approval without being a
            // gating `before*` hook — running and your turn only.
            waiting: .none,
            harvest: .structuredSession,
            requiresAppDataOptIn: true,
            transcripts: .none,
            aliases: ["cursor_agent", "cursor-agent"],
            // 24.0: the IDE and the `cursor-agent` CLI are one agent.
            // Cursor's private-worker daemon is persistent infrastructure: it
            // stays alive with no composer running, so counting it made an
            // idle IDE look like "2 processes" forever.
            process: AgentProcessRule(
                basenames: ["Cursor", "cursor", "cursor-agent", "cursor_agent"],
                pathNeedles: ["Cursor.app/Contents/MacOS/Cursor", "cursor-agent", "anysphere.cursor-agent"],
                denyNeedles: ["crashpad", "CursorUIViewService", "worker start", "--worker-dir"]
            ),
            harvestRoots: [
                "Library/Application Support/Cursor/User/globalStorage",
                "Library/Application Support/Cursor/User/workspaceStorage",
                // A few Cursor builds keep a compact session summary directly
                // under User rather than in globalStorage. It is still a
                // protected store, so this root is visited only after the
                // user's explicit app-data opt-in.
                "Library/Application Support/Cursor/User",
            ],
            harvestCommands: ["Cursor", "cursor-agent"],
            // Observe-only events: `beforeSubmitPrompt` can stop a prompt
            // (`continue: false`), so it is not installed.
            hooks: HookContract(format: .cursorHooks, path: ".cursor/hooks.json", home: ".cursor", events: [
                HookEvent("sessionStart"),
                HookEvent("sessionEnd"),
                HookEvent("afterAgentResponse"),
                HookEvent("stop"),
            ]),
            walk: HarvestWalk(database: .cursor)
        ),
        AgentSpec(
            id: .pi,
            displayName: "Pi",
            monogram: "Pi",
            // `ui_prompt_start` / `ui_prompt_end`: Pi reports when it waits on
            // a blocking user-facing prompt (a confirm, a select, an input).
            waiting: .hooks,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .alwaysRead,
            aliases: [],
            process: AgentProcessRule(basenames: ["pi"], pathNeedles: ["pi-coding-agent", "/opt/homebrew/bin/pi", "/usr/local/bin/pi", "/.local/bin/pi"], denyNeedles: ["pip", "pip3", "pihole", "pickle", "pypi", "pixel", "piano"], allowBareBasename: true),
            // Keep the two session-shaped Pi stores explicit. Walking the
            // entire ~/.pi tree also traverses its bundled npm/runtime cache
            // (11k+ files on a typical install) and consumes the budget.
            // JSONL under agent/sessions is the /resume title source.
            harvestRoots: [".pi/agent/sessions", ".pi/context-mode/sessions"],
            harvestCommands: ["pi"],
            hooks: HookContract(format: .piExtension, path: ".pi/agent/extensions/pulse.js", home: ".pi", events: [
                HookEvent("session_start"),
                HookEvent("session_shutdown"),
                HookEvent("agent_start"),
                HookEvent("tool_execution_end"),
                HookEvent("ui_prompt_start"),
                HookEvent("ui_prompt_end"),
                HookEvent("agent_settled"),
            ]),
            walk: HarvestWalk(database: .pi, transcripts: .pathContains("/.pi/agent/sessions/"), windowBytes: 496_000, headBytes: 96_000)
        ),
        AgentSpec(
            id: .gemini,
            displayName: "Gemini",
            monogram: "Ge",
            // Notification `ToolPermission` — observability only, it cannot
            // grant anything (google-gemini/gemini-cli docs/hooks/reference.md).
            waiting: .hooks,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            aliases: [],
            process: AgentProcessRule(basenames: ["gemini", "gemini-cli"], pathNeedles: ["/bin/gemini", "gemini-cli", "@google/gemini-cli"], denyNeedles: ["Gemini.app"]),
            // 20.0: under the macOS Seatbelt sandbox (`SANDBOX=sandbox-exec`)
            // Gemini CLI keeps its runtime directory in ~/.cache/.gemini.
            harvestRoots: [".gemini/tmp", ".cache/.gemini/tmp"],
            harvestCommands: ["gemini"],
            // BeforeAgent and AfterAgent block only on exit 2 or a `decision`
            // in stdout; Pulse's hook prints nothing and exits 0.
            hooks: HookContract(format: .geminiSettings, path: ".gemini/settings.json", home: ".gemini", events: [
                HookEvent("SessionStart"),
                HookEvent("SessionEnd"),
                HookEvent("BeforeAgent"),
                HookEvent("AfterAgent"),
                HookEvent("Notification"),
            ]),
            walk: HarvestWalk(transcripts: .pathContains("/chats/"), dropsContinuationPrompts: true, fixturePath: ".gemini/tmp/fixture/chats/session-fixture.jsonl")
        ),
        AgentSpec(
            id: .copilot,
            displayName: "Copilot",
            monogram: "Cp",
            // `notification` permission_prompt / elicitation_dialog —
            // fire-and-forget, never blocks the session.
            waiting: .hooks,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            aliases: [],
            process: AgentProcessRule(
                basenames: ["copilot"],
                pathNeedles: ["/bin/copilot", "github/gh-copilot", "@github/copilot", "copilot-cli"],
                denyNeedles: ["crashpad", "language-server", "copilot-language-server", "Copilot.Helper", "Copilot for Xcode"]
            ),
            // 20.0: Copilot CLI migrates XDG locations into ~/.copilot at
            // startup; sessions are session-state/<id>/events.jsonl.
            harvestRoots: [".copilot"],
            harvestCommands: ["copilot"],
            hooks: HookContract(format: .copilotHooks, path: ".copilot/hooks/pulse.json", home: ".copilot", events: [
                HookEvent("sessionStart"),
                HookEvent("sessionEnd"),
                HookEvent("userPromptSubmitted"),
                HookEvent("agentStop"),
                HookEvent("notification"),
                HookEvent("errorOccurred"),
            ]),
            walk: HarvestWalk(dropsContinuationPrompts: true, fixturePath: ".copilot/session.json")
        ),
        AgentSpec(
            id: .opencode,
            displayName: "OpenCode",
            monogram: "Oc",
            // Plugin events `permission.asked` / `question.asked`, resolved by
            // `permission.replied` / `question.replied` / `question.rejected`.
            waiting: .hooks,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["opencode", "open-code"], pathNeedles: ["/bin/opencode", "/opencode/", "opencode@", "@opencode"], denyNeedles: []),
            harvestRoots: [".local/share/opencode"],
            harvestCommands: ["opencode"],
            hooks: HookContract(format: .openCodePlugin, path: ".config/opencode/plugins/pulse.js", home: ".config/opencode", events: [
                HookEvent("session.created"),
                HookEvent("session.status"),
                HookEvent("session.idle"),
                HookEvent("session.error"),
                HookEvent("session.deleted"),
                HookEvent("permission.asked"),
                HookEvent("permission.replied"),
                HookEvent("question.asked"),
                HookEvent("question.replied"),
                HookEvent("question.rejected"),
            ]),
            // 20.0: the database is the session store; the rest of the data
            // directory is snapshots, checkouts, logs and pre-1.2 JSON that
            // OpenCode imported and left behind.
            walk: HarvestWalk(database: .openCode, transcripts: .none)
        ),
    ]

    private static let byID: [AgentID: AgentSpec] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    /// Every `AgentID` has exactly one spec — `AgentCatalogTests` holds the
    /// roster to that, so this lookup cannot miss in a shipped build.
    public static func spec(_ id: AgentID) -> AgentSpec {
        guard let spec = byID[id] else {
            preconditionFailure("AgentCatalog has no spec for \(id.rawValue)")
        }
        return spec
    }

    /// Raw value or any alias, as a hook or a bridge may spell it.
    public static func agent(named raw: String) -> AgentID? {
        if let id = AgentID(rawValue: raw) { return id }
        return all.first { $0.aliases.contains(raw) }?.id
    }
}

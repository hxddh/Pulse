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
// is also process-rule precedence (the first matching rule wins).

public enum AgentID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case claude, codex, cursor, pi, gemini, copilot, opencode

    public var id: String { rawValue }

    /// Everything the roster says about this agent.
    public var spec: AgentSpec { AgentCatalog.spec(self) }

    public var displayName: String { spec.displayName }

    /// Whether this agent's installed hook reports every tool call (see
    /// `HookContract.toolActivityEvents`). Only then does silence mean a
    /// stall: an agent that speaks only at a prompt and at the end of a turn
    /// is silent through every long turn.
    public var reportsToolActivity: Bool { spec.hooks.reportsToolActivity }

    /// Whether the vendor's hook says when a session is blocked on the user.
    /// Agents with `.none` still show running and your turn from their hooks.
    public var waitingSource: WaitingSource { spec.waiting }

    public static let priority: [AgentID] = [
        .claude, .codex, .cursor, .gemini, .copilot, .opencode, .pi,
    ]

    /// Agents whose hook never reports a blocked session — they show running
    /// and your turn only. Single source for Settings and L10n.
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
    /// Home-relative file Pulse edits (or, for Copilot, OpenCode and Pi, owns whole).
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

    /// Observe-only events that fire once per tool call, after it ran
    /// (Claude and Codex `PostToolUse`, Gemini `AfterTool`, Copilot
    /// `postToolUse`, Pi `tool_execution_end`). An agent whose contract
    /// installs one reports its work as it goes: silence from it means
    /// something, so only such an agent can be stalled — and its tool name
    /// is what answers a block raised for that tool.
    public static let toolActivityEvents: Set<String> = [
        "PostToolUse", "PostToolUseFailure", "AfterTool", "postToolUse", "postToolUseFailure",
        "tool_execution_end",
    ]

    /// Events that say a block was answered: a tool ran after it, or the
    /// vendor's own "replied" / "prompt closed". `catalog_check` holds every
    /// agent that can raise a block to installing at least one — a red lamp
    /// must have a way to go out besides the end of the turn.
    public static let answerEvents: Set<String> = toolActivityEvents.union([
        "permission.replied", "question.replied", "question.rejected", "ui_prompt_end",
    ])

    /// This contract installs a per-tool activity event (`toolActivityEvents`).
    public var reportsToolActivity: Bool {
        events.contains { Self.toolActivityEvents.contains($0.name) }
    }
}

/// Which processes are this agent, by executable path and argv. See
/// `AgentProcesses.match(args:)`: the hook's pid lookup and the process scan
/// (24.0: libproc, no `ps`) share it.
public struct AgentProcessRule: Sendable {
    public var basenames: [String]
    public var pathNeedles: [String]
    /// Fragments of the program itself — the executable, or an
    /// interpreter's script — that say it is not the agent (never the
    /// arguments: `pi ./pipeline.ts` is Pi).
    public var denyNeedles: [String]
    /// Fragments of the whole command line that say it is not the agent: an
    /// argument (`--worker-dir`), or a path with a space in it.
    public var argvDenyNeedles: [String] = []
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
    /// Other spellings a hook or bridge may use for this agent, beyond
    /// its raw value.
    public let aliases: [String]
    public let process: AgentProcessRule
    /// The vendor's documented, non-blocking hook Pulse installs (24.0).
    public let hooks: HookContract
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
            aliases: [],
            // The native install's `~/.local/bin/claude` links into
            // `~/.local/share/claude/versions/<version>`, the path the kernel
            // reports for the running binary.
            process: AgentProcessRule(basenames: ["claude"], pathNeedles: ["/.local/bin/claude", "/bin/claude", "/.local/share/claude/versions/"], denyNeedles: [], argvDenyNeedles: ["Claude.app", "chrome-native-host"]),
            // Every entry runs `async: true`: an async hook cannot block or
            // decide anything (code.claude.com/docs/en/hooks, "Run hooks in
            // the background"). PostToolUse, not PreToolUse, marks activity;
            // PostToolUseFailure is the same for a tool that failed —
            // a denied or failed call still answers the block raised for it.
            // PermissionDenied is not installed: its output can ask for a
            // retry, so it is not observe-only.
            hooks: HookContract(format: .claudeSettings, path: ".claude/settings.json", home: ".claude", events: [
                HookEvent("SessionStart"),
                HookEvent("SessionEnd"),
                HookEvent("UserPromptSubmit"),
                HookEvent("PostToolUse"),
                HookEvent("PostToolUseFailure"),
                HookEvent("PermissionRequest"),
                HookEvent("Notification", matcher: "permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog|elicitation_complete|elicitation_response"),
                HookEvent("Stop"),
                HookEvent("StopFailure"),
            ])
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
            aliases: [],
            process: AgentProcessRule(basenames: ["codex"], pathNeedles: ["/opt/homebrew/bin/codex", "/bin/codex", "Resources/codex"], denyNeedles: [], argvDenyNeedles: ["Codex Framework", "crashpad", "computer-use", "codex-code-mode-host"]),
            // PostToolUse runs `async` (codex-rs/hooks engine/discovery.rs:
            // only SessionEnd is forced synchronous), so it cannot change
            // what Codex does; it is the per-tool activity the stall rule
            // needs.
            hooks: HookContract(format: .codexHooks, path: ".codex/hooks.json", home: ".codex", events: [
                HookEvent("SessionStart"),
                HookEvent("SessionEnd"),
                HookEvent("UserPromptSubmit"),
                HookEvent("PostToolUse"),
                HookEvent("Stop"),
            ])
        ),
        AgentSpec(
            id: .cursor,
            displayName: "Cursor",
            monogram: "Cu",
            // No Cursor hook reports a pending approval without being a
            // gating `before*` hook — running and your turn only.
            waiting: .none,
            aliases: ["cursor_agent", "cursor-agent"],
            // 24.0: the IDE and the `cursor-agent` CLI are one agent.
            // Cursor's private-worker daemon is persistent infrastructure: it
            // stays alive with no composer running, so counting it made an
            // idle IDE look like "2 processes" forever.
            process: AgentProcessRule(
                basenames: ["Cursor", "cursor", "cursor-agent", "cursor_agent"],
                pathNeedles: ["Cursor.app/Contents/MacOS/Cursor", "cursor-agent", "anysphere.cursor-agent"],
                denyNeedles: [],
                argvDenyNeedles: ["crashpad", "CursorUIViewService", "worker start", "--worker-dir"]
            ),
            // Observe-only events: `beforeSubmitPrompt` can stop a prompt
            // (`continue: false`), so it is not installed.
            hooks: HookContract(format: .cursorHooks, path: ".cursor/hooks.json", home: ".cursor", events: [
                HookEvent("sessionStart"),
                HookEvent("sessionEnd"),
                HookEvent("afterAgentResponse"),
                HookEvent("stop"),
            ])
        ),
        AgentSpec(
            id: .pi,
            displayName: "Pi",
            monogram: "Pi",
            // `ui_prompt_start` / `ui_prompt_end`: Pi reports when it waits on
            // a blocking user-facing prompt (a confirm, a select, an input).
            waiting: .hooks,
            aliases: [],
            // Pi's deny list is the program's own name (`pip`, `pihole`…):
            // an argument such as `./pipeline.ts` does not make Pi not Pi.
            process: AgentProcessRule(basenames: ["pi"], pathNeedles: ["pi-coding-agent", "/opt/homebrew/bin/pi", "/usr/local/bin/pi", "/.local/bin/pi"], denyNeedles: ["pip", "pip3", "pihole", "pickle", "pypi", "pixel", "piano"], allowBareBasename: true),
            hooks: HookContract(format: .piExtension, path: ".pi/agent/extensions/pulse.js", home: ".pi", events: [
                HookEvent("session_start"),
                HookEvent("session_shutdown"),
                HookEvent("agent_start"),
                HookEvent("tool_execution_end"),
                HookEvent("ui_prompt_start"),
                HookEvent("ui_prompt_end"),
                HookEvent("agent_settled"),
            ])
        ),
        AgentSpec(
            id: .gemini,
            displayName: "Gemini",
            monogram: "Ge",
            // Notification `ToolPermission` — observability only, it cannot
            // grant anything (google-gemini/gemini-cli docs/hooks/reference.md).
            waiting: .hooks,
            aliases: [],
            process: AgentProcessRule(basenames: ["gemini", "gemini-cli"], pathNeedles: ["/bin/gemini", "gemini-cli", "@google/gemini-cli"], denyNeedles: [], argvDenyNeedles: ["Gemini.app"]),
            // BeforeAgent, AfterAgent and AfterTool act only on exit 2 or a
            // `decision` / `continue` in stdout; Pulse's hook prints nothing
            // and exits 0 (docs/hooks/reference.md, "Global hook
            // mechanics"). AfterTool is the answer to a ToolPermission: the
            // tool ran.
            hooks: HookContract(format: .geminiSettings, path: ".gemini/settings.json", home: ".gemini", events: [
                HookEvent("SessionStart"),
                HookEvent("SessionEnd"),
                HookEvent("BeforeAgent"),
                HookEvent("AfterTool"),
                HookEvent("AfterAgent"),
                HookEvent("Notification"),
            ])
        ),
        AgentSpec(
            id: .copilot,
            displayName: "Copilot",
            monogram: "Cp",
            // `notification` permission_prompt / elicitation_dialog —
            // fire-and-forget, never blocks the session.
            waiting: .hooks,
            aliases: [],
            process: AgentProcessRule(
                basenames: ["copilot"],
                pathNeedles: ["/bin/copilot", "github/gh-copilot", "@github/copilot", "copilot-cli"],
                denyNeedles: [],
                argvDenyNeedles: ["crashpad", "language-server", "copilot-language-server", "Copilot.Helper", "Copilot for Xcode"]
            ),
            // postToolUse / postToolUseFailure: empty output keeps the tool's
            // own result (hooks-reference.md, "postToolUse output"); the
            // tool ran, so a permission raised for it was answered.
            hooks: HookContract(format: .copilotHooks, path: ".copilot/hooks/pulse.json", home: ".copilot", events: [
                HookEvent("sessionStart"),
                HookEvent("sessionEnd"),
                HookEvent("userPromptSubmitted"),
                HookEvent("postToolUse"),
                HookEvent("postToolUseFailure"),
                HookEvent("agentStop"),
                HookEvent("notification"),
                HookEvent("errorOccurred"),
            ])
        ),
        AgentSpec(
            id: .opencode,
            displayName: "OpenCode",
            monogram: "Oc",
            // Plugin events `permission.asked` / `question.asked`, resolved by
            // `permission.replied` / `question.replied` / `question.rejected`.
            waiting: .hooks,
            aliases: [],
            process: AgentProcessRule(basenames: ["opencode", "open-code"], pathNeedles: ["/bin/opencode", "opencode@", "@opencode"], denyNeedles: []),
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
            ])
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

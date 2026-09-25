import Foundation

// The agent roster — every fact Pulse holds about a vendor that is not parsing
// code, in one place.
//
// Until 12.0 these facts were spread across ten places: the `AgentID` enum
// and four exhaustive switches in Models.swift, the process rule table in
// ProcessProbe, the harvest descriptor table and two transcript lists in
// NativeActivityHarvest, the alias switch in ActivityHarvest, the monogram
// switch in AgentIcon, the Respond reach switch, and hand-kept lists in three
// Python gates. Adding an agent meant finding all of them; missing one
// compiled and shipped. Now adding an agent is one `case` and one `AgentSpec`
// in this file, plus its icon and README row — and
// `scripts/agent_catalog_check.py` fails CI if a per-agent switch grows back
// anywhere else.
//
// Order is meaningful. `AgentCatalog.all` is `AgentID.allCases` order, which
// is also process-rule precedence (the first matching rule wins) and harvest
// descriptor order (the starting point of the rotation under budget).

enum AgentID: String, CaseIterable, Identifiable, Hashable {
    case claude, codex, cursor, cursorAgent = "cursor_agent"
    case grok, pi, amp, aider, gemini, copilot
    case opencode, goose, openhands, cline, roo, continue_ = "continue"
    case amazonQ = "amazon_q"
    case cascade, windsurf, augment, zedAgent = "zed_agent"
    case trae, warpAgent = "warp_agent"
    case devin, kiro, junie, kilo, replit
    case droid, commandCode = "command_code", antigravity, kimi
    case zcode

    var id: String { rawValue }

    /// Everything the roster says about this agent.
    var spec: AgentSpec { AgentCatalog.spec(self) }

    /// User-facing identity used when several vendor processes share one
    /// surface. Cursor's `cursor-agent` worker is observed separately by the
    /// collectors, but it is deliberately one Cursor row in the tray,
    /// support matrix, and attention ledger.
    var surfaceID: AgentID {
        self == .cursorAgent ? .cursor : self
    }

    var displayName: String { spec.displayName }

    /// Honest Waiting path exists (hooks and/or harvest `skill=pending`).
    /// Agents with `.none` may still show Running; tray can nudge once.
    var waitingSource: WaitingSource { spec.waiting }

    /// What the local collector is allowed to promise before runtime data is
    /// considered. Every agent can still degrade to process detection.
    ///
    /// `structuredSession` means the adapter reads a session/thread/composer
    /// identity and its activity facts. `bestEffortCache` means the vendor
    /// exposes no stable local session contract and Pulse may only recover a
    /// workspace or title. The README matrix is checked against this value so
    /// "a collector function exists" can no longer be advertised as equivalent
    /// session observability.
    var harvestSource: HarvestSource { spec.harvest }

    /// Some adapters keep their only useful session/cache evidence inside
    /// macOS-protected Application Support, App Group, or VS Code stores. The
    /// default scanner deliberately skips those locations; the support window
    /// uses this bit to explain that an unavailable row may be privacy-limited,
    /// not unsupported.
    var requiresAppDataOptIn: Bool { spec.requiresAppDataOptIn }

    /// Reach is a statement about the installed hook, not about capability.
    var respondReach: RespondReach { spec.respondReach }

    static let priority: [AgentID] = [
        .claude, .cursorAgent, .codex, .droid, .kimi, .commandCode, .devin,
        .antigravity, .cascade, .windsurf, .kiro, .junie, .kilo, .augment,
        .grok, .pi, .amp, .aider, .gemini, .copilot, .opencode, .goose,
        .openhands, .cline, .roo, .continue_, .amazonQ, .zedAgent, .trae,
        .warpAgent, .replit, .zcode, .cursor,
    ]

    /// Surface Agents with no native Waiting path — Attention Protocol only.
    /// Single source for Settings samples, Support repair, and L10n lists.
    static var waitingNoneAgents: [AgentID] {
        priority.filter { $0 != .cursorAgent && $0.waitingSource == .none }
    }
}

enum WaitingSource {
    case hooks
    case harvestPending
    case none
}

enum HarvestSource {
    case structuredSession
    case bestEffortCache
}

/// How the collector treats an agent's JSONL transcripts.
enum TranscriptPolicy {
    /// No transcript files, or none read as transcripts.
    case none
    /// Read transcripts; skip idle files outside the fresh window, and allow
    /// a bounded read of a large one.
    case freshWindow
    /// Read transcripts whatever their age (Pi: the idle JSONL is the title
    /// source), with the same bounded large read.
    case alwaysRead

    var skipsStaleFiles: Bool { self == .freshWindow }
    var allowsBoundedLargeFiles: Bool { self != .none }
}

/// A vendor store read through SQLite rather than as transcript files.
enum DatabaseAdapter {
    case cursor, openCode, warp, pi, grok

    /// File extensions the walk hands to this adapter instead of the
    /// transcript reader.
    var extensions: Set<String> {
        self == .cursor ? ["vscdb", "sqlite", "db"] : ["sqlite", "db"]
    }

    /// Pi's JSONL carries the /resume title; its sibling SQLite must not run
    /// before those transcripts or the row loses its hero.
    var runsAfterTranscripts: Bool { self == .pi }

    /// A file that will not open as SQLite fails the adapter — except for Pi,
    /// whose tree holds incidental non-SQLite `.db` files beside the JSONL
    /// that is its real source.
    var failsOnUnreadableFile: Bool { self != .pi }
}

/// Which transcript files under an agent's roots are session evidence.
enum TranscriptSelection: Equatable {
    /// Every transcript-shaped file.
    case all
    /// None: the database is authoritative and the rest of the tree is noise
    /// (Grok's terminal transcripts, locks and system prompts).
    case none
    /// Only paths containing this fragment, lowercased (Pi's session tree,
    /// Gemini's chats — their roots also hold caches and checkouts).
    case pathContains(String)

    func admits(_ lowercasedPath: String) -> Bool {
        switch self {
        case .all: return true
        case .none: return false
        case .pathContains(let fragment): return lowercasedPath.contains(fragment)
        }
    }
}

/// How the native collector walks and reads one agent's roots. The defaults
/// are the generic adapter; an agent states only where it differs.
struct HarvestWalk {
    var database: DatabaseAdapter? = nil
    var transcripts: TranscriptSelection = .all
    /// Directory names the walk normally skips but this agent keeps.
    var keptDirectoryNames: Set<String> = []
    /// A path fragment (lowercased) that marks a file as a structured session
    /// even where the generic session-path rule would not.
    var structuredPathFragment: String? = nil
    /// Largest transcript file read at all; nil means the default for the
    /// agent's transcript policy.
    var maxFileBytes: Int? = nil
    /// Bytes read per transcript window, and how many of them from the head.
    var windowBytes = 1_000_000
    var headBytes = 64_000
    /// The adapter's own time budget; nil means the shared default.
    var deadlineSeconds: Double? = nil
    /// "continue" / "go on" prompts are not tasks — for agents whose
    /// transcripts record them as ordinary user turns.
    var dropsContinuationPrompts = false
    /// Home-relative path of the generic vendor-shaped fixture the native
    /// fixture wall writes for this agent (`--native-fixture-test`). Agents
    /// with a hand-written fixture of their own leave it nil.
    var fixturePath: String? = nil
}

/// Which `ps` argv lines are this agent. See `ProcessProbe.matchEvidence`.
struct AgentProcessRule {
    var basenames: [String]
    var pathNeedles: [String]
    var denyNeedles: [String]
    /// Some real CLIs intentionally use a short executable name (`pi`,
    /// `roo`, `cmd`). Their exact basename is useful evidence after the
    /// deny list has run; length alone must not make a live agent vanish.
    var allowBareBasename: Bool = false
}

struct AgentSpec {
    let id: AgentID
    let displayName: String
    /// Fallback glyph when the PNG/SVG mark is missing — unique across the
    /// roster. The mark itself is `Resources/AgentIcons/<rawValue>.png|svg`.
    let monogram: String
    let waiting: WaitingSource
    let harvest: HarvestSource
    let requiresAppDataOptIn: Bool
    let transcripts: TranscriptPolicy
    let respondReach: RespondReach
    /// Other spellings a hook or remote host may use for this agent, beyond
    /// its raw value.
    let aliases: [String]
    let process: AgentProcessRule
    /// Home-relative roots the native collector walks. Empty means the agent
    /// has no collector of its own (Cursor Agent is folded into Cursor).
    let harvestRoots: [String]
    /// Executables whose presence says the agent is installed.
    let harvestCommands: [String]
    /// How the collector walks and reads those roots.
    var walk = HarvestWalk()
}

enum AgentCatalog {
    static let all: [AgentSpec] = [
        AgentSpec(
            id: .claude,
            displayName: "Claude",
            monogram: "Cl",
            waiting: .hooks,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            respondReach: .hookSite,
            aliases: [],
            process: AgentProcessRule(basenames: ["claude"], pathNeedles: ["/.local/bin/claude", "/bin/claude"], denyNeedles: ["Claude.app", "chrome-native-host"]),
            harvestRoots: [".claude/projects", ".claude/tasks"],
            harvestCommands: ["claude"],
            walk: HarvestWalk(dropsContinuationPrompts: true, fixturePath: ".claude/projects/fixture.jsonl")
        ),
        AgentSpec(
            id: .codex,
            displayName: "Codex",
            monogram: "Cx",
            waiting: .hooks,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["codex"], pathNeedles: ["/opt/homebrew/bin/codex", "/bin/codex", "Resources/codex"], denyNeedles: ["Codex Framework", "crashpad", "computer-use", "codex-code-mode-host"]),
            harvestRoots: [".codex/sessions", ".codex/rollouts"],
            harvestCommands: ["codex"],
            walk: HarvestWalk(windowBytes: 8_000_000, deadlineSeconds: 1.2, fixturePath: ".codex/sessions/fixture/rollout-fixture.jsonl")
        ),
        AgentSpec(
            id: .cursor,
            displayName: "Cursor",
            monogram: "Cu",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["Cursor", "cursor"], pathNeedles: ["Cursor.app/Contents/MacOS/Cursor"], denyNeedles: ["crashpad", "CursorUIViewService"]),
            harvestRoots: [
                "Library/Application Support/Cursor/User/globalStorage",
                "Library/Application Support/Cursor/User/workspaceStorage",
                // A few Cursor builds keep a compact session summary directly
                // under User rather than in globalStorage. It is still a
                // protected store, so this root is visited only after the
                // user's explicit Cursor app-data opt-in.
                "Library/Application Support/Cursor/User",
            ],
            harvestCommands: ["Cursor"],
            walk: HarvestWalk(database: .cursor)
        ),
        AgentSpec(
            id: .cursorAgent,
            displayName: "Cursor Agent",
            monogram: "CA",
            waiting: .harvestPending,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(
                basenames: ["cursor-agent", "cursor_agent"],
                pathNeedles: ["cursor-agent", "anysphere.cursor-agent", "cursor-agent-worker"],
                // Cursor's private-worker daemon is persistent infrastructure. It
                // remains alive with no composer running, so counting it as an
                // agent made an idle IDE look like "2 processes" forever.
                denyNeedles: ["crashpad", "worker start", "--worker-dir"]
            ),
            harvestRoots: [],
            harvestCommands: []
        ),
        AgentSpec(
            id: .grok,
            displayName: "Grok",
            monogram: "Gk",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .none,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["grok"], pathNeedles: ["/.grok/bin/grok", "grok-0.", "GROK_AGENT=", "/bin/grok"], denyNeedles: []),
            harvestRoots: [".grok/sessions"],
            harvestCommands: ["grok"],
            walk: HarvestWalk(database: .grok, transcripts: .none, keptDirectoryNames: ["logs"], structuredPathFragment: "/.grok/logs/", maxFileBytes: 16 * 1024 * 1024)
        ),
        AgentSpec(
            id: .pi,
            displayName: "Pi",
            monogram: "Pi",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .alwaysRead,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["pi"], pathNeedles: ["pi-coding-agent", "/opt/homebrew/bin/pi", "/usr/local/bin/pi", "/.local/bin/pi"], denyNeedles: ["pip", "pip3", "pihole", "pickle", "pypi", "pixel", "piano"], allowBareBasename: true),
            // Pi's JSONL transcripts are the richest source; context-mode's
            // per-session SQLite adds cwd/tool/resource facts when the agent
            // has no transcript hook installed.
            // Keep the two session-shaped Pi stores explicit. Walking the
            // entire ~/.pi tree also traverses its bundled npm/runtime cache
            // (11k+ files on a typical install), consumes the global budget,
            // and can hide the actual session DBs behind a native timeout.
            // JSONL under agent/sessions is the /resume title source. Walking
            // context-mode SQLite first spent the adapter deadline on empty
            // session_meta rows and never opened the transcripts.
            harvestRoots: [".pi/agent/sessions", ".pi/context-mode/sessions"],
            harvestCommands: ["pi"],
            walk: HarvestWalk(database: .pi, transcripts: .pathContains("/.pi/agent/sessions/"), windowBytes: 496_000, headBytes: 96_000)
        ),
        AgentSpec(
            id: .amp,
            displayName: "Amp",
            monogram: "Am",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(
                basenames: ["amp"],
                // Bare argv `amp` is 3 chars; non-empty pathNeedles would skip basename-only matches.
                pathNeedles: [],
                denyNeedles: ["AMPDevice", "AMPLibrary", "AMPDevices", "iTunesCloud", "AMPLibraryAgent"]
            ),
            harvestRoots: [".local/share/amp", ".amp"],
            harvestCommands: ["amp"],
            walk: HarvestWalk(dropsContinuationPrompts: true, fixturePath: ".local/share/amp/history.jsonl")
        ),
        AgentSpec(
            id: .aider,
            displayName: "Aider",
            monogram: "Ai",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["aider"], pathNeedles: ["/bin/aider", "-m aider"], denyNeedles: []),
            harvestRoots: [".aider"],
            harvestCommands: ["aider"],
            walk: HarvestWalk(dropsContinuationPrompts: true, fixturePath: ".aider/session.json")
        ),
        AgentSpec(
            id: .gemini,
            displayName: "Gemini",
            monogram: "Ge",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["gemini", "gemini-cli"], pathNeedles: ["/bin/gemini", "gemini-cli", "@google/gemini-cli"], denyNeedles: ["Gemini.app"]),
            harvestRoots: [".gemini/tmp"],
            harvestCommands: ["gemini"],
            walk: HarvestWalk(transcripts: .pathContains("/chats/"), dropsContinuationPrompts: true, fixturePath: ".gemini/tmp/fixture/chats/session-fixture.jsonl")
        ),
        AgentSpec(
            id: .copilot,
            displayName: "Copilot",
            monogram: "Cp",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(
                basenames: ["copilot"],
                pathNeedles: ["/bin/copilot", "github/gh-copilot", "@github/copilot", "copilot-cli"],
                denyNeedles: ["crashpad", "language-server", "copilot-language-server", "Copilot.Helper", "Copilot for Xcode"]
            ),
            harvestRoots: [".copilot", ".config/copilot"],
            harvestCommands: ["copilot"],
            walk: HarvestWalk(dropsContinuationPrompts: true, fixturePath: ".copilot/session.json")
        ),
        AgentSpec(
            id: .opencode,
            displayName: "OpenCode",
            monogram: "Oc",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .none,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["opencode", "open-code"], pathNeedles: ["/bin/opencode", "/opencode/", "opencode@", "@opencode"], denyNeedles: []),
            harvestRoots: [".local/share/opencode"],
            harvestCommands: ["opencode"],
            walk: HarvestWalk(database: .openCode)
        ),
        AgentSpec(
            id: .goose,
            displayName: "Goose",
            monogram: "Go",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["goose"], pathNeedles: ["/bin/goose", "block/goose", "goose-cli"], denyNeedles: []),
            harvestRoots: [".config/goose", ".local/share/goose", "Library/Application Support/Goose"],
            harvestCommands: ["goose"],
            walk: HarvestWalk(dropsContinuationPrompts: true, fixturePath: ".config/goose/session.json")
        ),
        AgentSpec(
            id: .openhands,
            displayName: "OpenHands",
            monogram: "OH",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["openhands", "opendevin"], pathNeedles: ["openhands", "OpenHands", "OpenDevin"], denyNeedles: []),
            harvestRoots: [".openhands", ".openhands-state"],
            harvestCommands: ["openhands"],
            walk: HarvestWalk(dropsContinuationPrompts: true, fixturePath: ".openhands/session.json")
        ),
        AgentSpec(
            id: .cline,
            displayName: "Cline",
            monogram: "Ci",
            waiting: .harvestPending,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["cline"], pathNeedles: ["saoudrizwan.claude-dev", "/cline/", "cline@", "claude-dev"], denyNeedles: ["crashpad", "decline", "incline"]),
            harvestRoots: [
                "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev",
                "Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev",
                "Library/Application Support/Windsurf/User/globalStorage/saoudrizwan.claude-dev",
                "Library/Application Support/Trae/User/globalStorage/saoudrizwan.claude-dev",
            ],
            harvestCommands: [],
            walk: HarvestWalk(fixturePath: "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/session.json")
        ),
        AgentSpec(
            id: .roo,
            displayName: "Roo",
            monogram: "Ro",
            waiting: .harvestPending,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["roo", "roo-code"], pathNeedles: ["roo-cline", "roo-code", "RooCode"], denyNeedles: ["crashpad"], allowBareBasename: true),
            harvestRoots: [
                "Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline",
                "Library/Application Support/Cursor/User/globalStorage/rooveterinaryinc.roo-cline",
                "Library/Application Support/Windsurf/User/globalStorage/rooveterinaryinc.roo-cline",
                "Library/Application Support/Trae/User/globalStorage/rooveterinaryinc.roo-cline",
            ],
            harvestCommands: [],
            walk: HarvestWalk(fixturePath: "Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/session.json")
        ),
        AgentSpec(
            id: .continue_,
            displayName: "Continue",
            monogram: "Cn",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(basenames: ["continue", "continue-cli"], pathNeedles: ["continue.dev", "Continue.continue", "continue-cli"], denyNeedles: ["crashpad"]),
            harvestRoots: [".continue"],
            harvestCommands: [],
            walk: HarvestWalk(dropsContinuationPrompts: true, fixturePath: ".continue/session.json")
        ),
        AgentSpec(
            id: .amazonQ,
            displayName: "Amazon Q",
            monogram: "Q",
            waiting: .harvestPending,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: ["amazon-q", "q"],
            process: AgentProcessRule(basenames: ["amazon-q", "q-chat", "qchat"], pathNeedles: ["amazon-q", "Amazon Q", "/opt/homebrew/bin/q"], denyNeedles: ["qemu", "QuickTime"]),
            harvestRoots: [
                ".aws/amazonq", ".aws/amazon-q", ".aws/q",
                ".local/share/amazon-q",
                "Library/Application Support/Amazon Q",
                "Library/Application Support/amazon-q",
                "Library/Application Support/AmazonQ",
            ],
            harvestCommands: [],
            walk: HarvestWalk(fixturePath: ".aws/amazonq/session.json")
        ),
        AgentSpec(
            id: .cascade,
            displayName: "Cascade",
            monogram: "Cs",
            waiting: .harvestPending,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: ["windsurf-cascade"],
            process: AgentProcessRule(
                basenames: ["cascade", "windsurf-cascade"],
                pathNeedles: ["cascade-agent", "windsurf-cascade", "codeium.cascade", "Codeium.Cascade"],
                denyNeedles: ["crashpad", "Windsurf.app/Contents/MacOS/Windsurf", "Windsurf Helper"]
            ),
            harvestRoots: [
                ".codeium", ".windsurf",
                "Library/Application Support/Windsurf",
                "Library/Application Support/Codeium",
            ],
            harvestCommands: [],
            walk: HarvestWalk(fixturePath: ".codeium/session.json")
        ),
        AgentSpec(
            id: .windsurf,
            displayName: "Windsurf",
            monogram: "Ws",
            waiting: .harvestPending,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(
                basenames: ["Windsurf", "windsurf"],
                pathNeedles: ["Windsurf.app/Contents/MacOS/Windsurf", "Exafunction/windsurf", "codeium.windsurf"],
                denyNeedles: ["crashpad", "Windsurf Helper", "WindsurfUI", "cascade-agent", "windsurf-cascade"]
            ),
            harvestRoots: [".windsurf", "Library/Application Support/Windsurf"],
            harvestCommands: [],
            walk: HarvestWalk(fixturePath: ".windsurf/session.json")
        ),
        AgentSpec(
            id: .augment,
            displayName: "Augment",
            monogram: "Au",
            waiting: .harvestPending,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: false,
            transcripts: .none,
            respondReach: .none,
            aliases: ["auggie"],
            process: AgentProcessRule(
                basenames: ["augment", "auggie"],
                pathNeedles: ["augmentcode", "augment-code", "/bin/augment", "Augment"],
                denyNeedles: ["crashpad"]
            ),
            harvestRoots: [".augment", ".auggie"],
            harvestCommands: [],
            walk: HarvestWalk(fixturePath: ".augment/session.json")
        ),
        AgentSpec(
            id: .zedAgent,
            displayName: "Zed Agent",
            monogram: "Zd",
            waiting: .harvestPending,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: ["zed-agent"],
            process: AgentProcessRule(
                basenames: ["zed-agent", "zed_agent"],
                pathNeedles: ["zed-agent", "zed_agent", "Zed Agent", "zed-agentic"],
                denyNeedles: ["crashpad", "Zed.app/Contents/MacOS/Zed", "Zed.app/Contents/MacOS/zed"]
            ),
            harvestRoots: [
                ".zed", ".config/zed",
                "Library/Application Support/Zed",
            ],
            harvestCommands: [],
            walk: HarvestWalk(fixturePath: ".zed/session.json")
        ),
        AgentSpec(
            id: .trae,
            displayName: "Trae",
            monogram: "Tr",
            waiting: .none,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: [],
            process: AgentProcessRule(
                basenames: ["trae-agent", "TraeAgent"],
                pathNeedles: ["trae-agent", "bytedance.trae", "Trae Agent", "trae/agent"],
                denyNeedles: ["crashpad", "Trae Helper", "Trae.app/Contents/MacOS/Trae"]
            ),
            harvestRoots: [".trae", "Library/Application Support/Trae"],
            harvestCommands: [],
            walk: HarvestWalk(fixturePath: "Library/Application Support/Trae/session.json")
        ),
        AgentSpec(
            id: .warpAgent,
            displayName: "Warp Agent",
            monogram: "Wa",
            waiting: .none,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: ["warp-agent"],
            process: AgentProcessRule(
                basenames: ["warp-agent", "warp_agent", "warp-ai"],
                pathNeedles: ["warp-agent", "warp_agent", "WarpAgent", "warp ai agent"],
                denyNeedles: ["crashpad", "Warp.app/Contents/MacOS/stable", "Warp.app/Contents/MacOS/Warp"]
            ),
            harvestRoots: [
                ".warp",
                "Library/Application Support/dev.warp.Warp-Stable",
                "Library/Application Support/dev.warp.Warp",
                "Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable",
                "Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp",
            ],
            harvestCommands: [],
            walk: HarvestWalk(database: .warp)
        ),
        AgentSpec(
            id: .devin,
            displayName: "Devin",
            monogram: "Dv",
            waiting: .none,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: false,
            transcripts: .none,
            respondReach: .none,
            aliases: ["devin-cli"],
            process: AgentProcessRule(
                basenames: ["devin", "devin-cli"],
                pathNeedles: ["/bin/devin", "cognition.devin", "devin-cli", "@cognition/devin"],
                denyNeedles: ["crashpad"]
            ),
            harvestRoots: [".devin", ".cognition"],
            harvestCommands: ["devin"],
            walk: HarvestWalk(fixturePath: ".devin/session.json")
        ),
        AgentSpec(
            id: .kiro,
            displayName: "Kiro",
            monogram: "Kr",
            waiting: .harvestPending,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: ["kiro-cli", "kiro-agent"],
            process: AgentProcessRule(
                basenames: ["kiro", "kiro-cli", "kiro-agent"],
                pathNeedles: ["/bin/kiro", "kiro-cli", "kiro-agent", "amazon.kiro", "Kiro.app"],
                denyNeedles: ["crashpad", "Kiro Helper"]
            ),
            harvestRoots: [".kiro", "Library/Application Support/Kiro"],
            harvestCommands: ["kiro"],
            walk: HarvestWalk(fixturePath: ".kiro/session.json")
        ),
        AgentSpec(
            id: .junie,
            displayName: "Junie",
            monogram: "Ju",
            waiting: .none,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: ["junie-cli"],
            process: AgentProcessRule(
                basenames: ["junie", "junie-cli"],
                pathNeedles: ["/bin/junie", "junie-cli", "jetbrains.junie", "Junie"],
                denyNeedles: ["crashpad"]
            ),
            harvestRoots: [".junie", "Library/Application Support/JetBrains/Junie"],
            harvestCommands: ["junie"],
            walk: HarvestWalk(fixturePath: ".junie/session.json")
        ),
        AgentSpec(
            id: .kilo,
            displayName: "Kilo",
            monogram: "Ko",
            waiting: .harvestPending,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: ["kilo-code", "kilocode"],
            process: AgentProcessRule(
                basenames: ["kilo", "kilo-code"],
                pathNeedles: ["kilocode", "kilo-code", "kilo.code", "Kilo Code"],
                denyNeedles: ["crashpad", "kilobyte"]
            ),
            harvestRoots: [
                "Library/Application Support/Code/User/globalStorage/kilocode.kilo-code",
                "Library/Application Support/Cursor/User/globalStorage/kilocode.kilo-code",
            ],
            harvestCommands: [],
            walk: HarvestWalk(fixturePath: "Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/session.json")
        ),
        AgentSpec(
            id: .replit,
            displayName: "Replit",
            monogram: "Rp",
            waiting: .none,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: ["replit-agent"],
            process: AgentProcessRule(
                basenames: ["replit", "replit-agent"],
                pathNeedles: ["replit-agent", "replit.com/agent", "@replit/agent", "Replit Agent"],
                denyNeedles: ["crashpad"]
            ),
            harvestRoots: [".replit", ".config/replit"],
            harvestCommands: [],
            walk: HarvestWalk(fixturePath: ".replit/session.json")
        ),
        AgentSpec(
            id: .droid,
            displayName: "Droid",
            monogram: "Dr",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            respondReach: .none,
            aliases: ["factory", "factory-droid"],
            process: AgentProcessRule(
                basenames: ["droid"],
                pathNeedles: ["/bin/droid", "factory.ai", "/.factory/", "@factory", "Factory-AI", "factory/droid"],
                denyNeedles: ["crashpad", "android", "droidcam"]
            ),
            harvestRoots: [".factory"],
            harvestCommands: ["droid"],
            walk: HarvestWalk(dropsContinuationPrompts: true, fixturePath: ".factory/session.jsonl")
        ),
        AgentSpec(
            id: .commandCode,
            displayName: "Command Code",
            monogram: "CC",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            respondReach: .none,
            aliases: ["command-code", "commandcode", "cmd"],
            process: AgentProcessRule(
                basenames: ["cmd", "command-code"],
                pathNeedles: [
                    "command-code",
                    "commandcode",
                    "Command Code",
                    "⌘ Command Code",
                    "/.commandcode/",
                    "@command-code",
                    "node_modules/command-code",
                    "/opt/homebrew/bin/cmd",
                    "/usr/local/bin/cmd",
            ],
                denyNeedles: ["crashpad", "cmd.exe", "cmdline-tools"],
                allowBareBasename: true
            ),
            // `cmd` alone is far too generic a binary name to treat as
            // evidence that Command Code is installed — especially now that
            // the search covers ~/.local/bin and the other user bin roots.
            harvestRoots: [".commandcode"],
            harvestCommands: ["command-code"],
            walk: HarvestWalk(dropsContinuationPrompts: true, fixturePath: ".commandcode/session.jsonl")
        ),
        AgentSpec(
            id: .antigravity,
            displayName: "Antigravity",
            monogram: "Ag",
            waiting: .none,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: ["antigravity-ide", "antigravity_ide", "agy"],
            process: AgentProcessRule(
                basenames: ["Antigravity", "antigravity", "Antigravity IDE", "agy"],
                pathNeedles: [
                    "Antigravity.app/Contents/MacOS/Antigravity",
                    "Antigravity IDE.app",
                    "/bin/antigravity",
                    "/.local/bin/agy",
                    "/bin/agy",
                    "google.antigravity",
            ],
                denyNeedles: ["crashpad", "Antigravity Helper", "AntigravityUI"],
                allowBareBasename: true
            ),
            harvestRoots: [
                "Library/Application Support/Antigravity/User/globalStorage",
                "Library/Application Support/Antigravity/User/workspaceStorage",
                "Library/Application Support/Antigravity IDE/User/globalStorage",
                "Library/Application Support/Antigravity IDE/User/workspaceStorage",
            ],
            harvestCommands: ["agy", "antigravity"],
            walk: HarvestWalk(fixturePath: "Library/Application Support/Antigravity/User/globalStorage/session.json")
        ),
        AgentSpec(
            id: .kimi,
            displayName: "Kimi",
            monogram: "Km",
            waiting: .harvestPending,
            harvest: .structuredSession,
            requiresAppDataOptIn: false,
            transcripts: .freshWindow,
            respondReach: .none,
            aliases: ["kimi-code", "kimi_code"],
            process: AgentProcessRule(
                basenames: ["kimi"],
                pathNeedles: ["kimi-code", "/.kimi-code/", "@moonshot-ai/kimi-code", "moonshotai/kimi", "/bin/kimi"],
                denyNeedles: ["crashpad", "Kimis", "kimisc"]
            ),
            harvestRoots: [".kimi-code"],
            harvestCommands: ["kimi"],
            walk: HarvestWalk(dropsContinuationPrompts: true, fixturePath: ".kimi-code/session.jsonl")
        ),
        AgentSpec(
            id: .zcode,
            displayName: "ZCode",
            monogram: "Zc",
            waiting: .none,
            harvest: .bestEffortCache,
            requiresAppDataOptIn: true,
            transcripts: .none,
            respondReach: .none,
            aliases: ["z-code", "ZCode", "zcode-agent"],
            process: AgentProcessRule(
                basenames: ["ZCode", "zcode"],
                pathNeedles: [
                    "ZCode.app/Contents/MacOS/ZCode",
                    "ZCode.app/",
                    "/.zcode/",
                    "zcode.cjs",
                    "Resources/glm/zcode",
            ],
                denyNeedles: [
                    "crashpad",
                    "ZCode Helper",
                    "ZCode Account Switcher",
            ]
            ),
            harvestRoots: [
                ".zcode",
                "Library/Application Support/ZCode",
            ],
            harvestCommands: ["zcode", "ZCode"],
            walk: HarvestWalk(fixturePath: ".zcode/sessions/session.json")
        ),
    ]

    private static let byID: [AgentID: AgentSpec] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    /// Every `AgentID` has exactly one spec — `AgentCatalogTests` holds the
    /// roster to that, so this lookup cannot miss in a shipped build.
    static func spec(_ id: AgentID) -> AgentSpec {
        guard let spec = byID[id] else {
            preconditionFailure("AgentCatalog has no spec for \(id.rawValue)")
        }
        return spec
    }

    /// Raw value or any alias, as a hook or a remote host may spell it.
    static func agent(named raw: String) -> AgentID? {
        if let id = AgentID(rawValue: raw) { return id }
        return all.first { $0.aliases.contains(raw) }?.id
    }
}

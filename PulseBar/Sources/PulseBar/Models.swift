import Foundation

enum PulseVersion {
    static let semver = "0.21.0"
    static let about = "Pulse \(semver)"
}

enum AgentID: String, CaseIterable, Identifiable, Hashable {
    case claude, codex, cursor, cursorAgent = "cursor_agent"
    case grok, pi, amp, aider, gemini, copilot
    case opencode, goose, openhands, cline, roo, continue_ = "continue"
    case amazonQ = "amazon_q"
    case cascade, windsurf, augment, zedAgent = "zed_agent"
    case trae, warpAgent = "warp_agent"
    case devin, kiro, junie, kilo, replit
    case droid, commandCode = "command_code", antigravity, kimi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .cursorAgent: return "Cursor Agent"
        case .grok: return "Grok"
        case .pi: return "Pi"
        case .amp: return "Amp"
        case .aider: return "Aider"
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        case .opencode: return "OpenCode"
        case .goose: return "Goose"
        case .openhands: return "OpenHands"
        case .cline: return "Cline"
        case .roo: return "Roo"
        case .continue_: return "Continue"
        case .amazonQ: return "Amazon Q"
        case .cascade: return "Cascade"
        case .windsurf: return "Windsurf"
        case .augment: return "Augment"
        case .zedAgent: return "Zed Agent"
        case .trae: return "Trae"
        case .warpAgent: return "Warp Agent"
        case .devin: return "Devin"
        case .kiro: return "Kiro"
        case .junie: return "Junie"
        case .kilo: return "Kilo"
        case .replit: return "Replit"
        case .droid: return "Droid"
        case .commandCode: return "Command Code"
        case .antigravity: return "Antigravity"
        case .kimi: return "Kimi"
        }
    }

    /// Coding agents shown in Glance/Tray (IDE shells stay out).
    var isSurface: Bool {
        switch self {
        case .claude, .codex, .cursor, .cursorAgent, .grok, .pi, .amp,
             .aider, .gemini, .copilot, .opencode, .goose, .openhands,
             .cline, .roo, .continue_, .amazonQ,
             .cascade, .windsurf, .augment, .zedAgent, .trae, .warpAgent,
             .devin, .kiro, .junie, .kilo, .replit,
             .droid, .commandCode, .antigravity, .kimi:
            return true
        }
    }

    /// Honest Waiting path exists (hooks and/or harvest `skill=pending`).
    /// Agents with `.none` may still show Running; tray can nudge once.
    var waitingSource: WaitingSource {
        switch self {
        case .claude, .codex:
            return .hooks
        case .cursor, .cursorAgent, .gemini, .opencode, .amp, .aider, .goose,
             .cline, .roo, .continue_, .copilot, .amazonQ, .cascade, .windsurf,
             .augment, .zedAgent, .openhands, .grok, .pi, .kilo, .kiro,
             .droid, .commandCode, .kimi:
            return .harvestPending
        // Opaque / cloud-first / IDE-shell: probe (+best-effort harvest) only.
        case .replit, .antigravity, .trae, .warpAgent, .devin, .junie:
            return .none
        }
    }

    static let priority: [AgentID] = [
        .claude, .cursorAgent, .codex, .droid, .kimi, .commandCode, .devin,
        .antigravity, .cascade, .windsurf, .kiro, .junie, .kilo, .augment,
        .grok, .pi, .amp, .aider, .gemini, .copilot, .opencode, .goose,
        .openhands, .cline, .roo, .continue_, .amazonQ, .zedAgent, .trae,
        .warpAgent, .replit, .cursor,
    ]
}

enum WaitingSource {
    case hooks
    case harvestPending
    case none
}

/// How this row's Waiting was raised (shown as a short credibility tag).
enum WaitSignalKind: String, Equatable {
    case hooks
    case pending
}

/// Honesty tier for Focus — never claim TTY when we only have cwd.
enum FocusTier: Equatable {
    case tty
    case warp
    case openCwd
}

enum GlanceKind: Equatable {
    case idle
    case running
    case waiting
    case error

    var symbolName: String {
        switch self {
        case .idle: return "circle"
        case .running: return "circle.fill"
        case .waiting: return "pause.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .waiting: return "Needs attention"
        case .error: return "Error"
        }
    }
}

struct AgentRow: Identifiable, Hashable {
    /// Unique tray row (multi-session: agent|session or agent|project).
    var rowKey: String
    /// Agent product identity.
    var agent: AgentID
    /// Optional session / composer / rollout id for attention matching.
    var sessionID: String = ""
    var project: String = ""
    var task: String = ""
    var cwd: String = ""
    var waiting: Bool = false
    var waitKind: String = ""
    var waitMessage: String = ""
    /// hooks vs harvest pending — for tray credibility tag.
    var waitSignal: WaitSignalKind? = nil
    var viaWarp: Bool = false
    var processCount: Int = 0
    var tokensIn: Int = 0
    var tokensOut: Int = 0
    var tool: String = ""
    var skill: String = ""
    var waitSinceMs: Int64 = 0
    var pid: Int = 0
    var tty: String = ""
    var harvestMs: Int64 = 0
    var subRunning: Int = 0
    var subTotal: Int = 0
    /// True when a live process was matched (not harvest-only).
    var liveProcess: Bool = false

    var id: String { rowKey }

    var titleLine: String {
        var parts: [String] = [agent.displayName]
        let short = Self.shortProject(project)
        if !short.isEmpty {
            parts.append(short)
        } else if let hint = shortSessionHint {
            // No project — show short session so multi-row agents stay distinguishable.
            parts.append(hint)
        }
        if processCount > 1 { parts.append("×\(processCount)") }
        if viaWarp { parts.append("via Warp") }
        return parts.joined(separator: " · ")
    }

    /// Short session id for tray disambiguation (never the full uuid).
    var shortSessionHint: String? {
        let sid = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty else { return nil }
        if sid.count <= 10 { return sid }
        return String(sid.suffix(8))
    }

    /// Waiting reason line: "↳ Permission · 2m · hooks: please approve"
    var waitLine: String? {
        guard waiting else { return nil }
        var head: [String] = []
        if !waitKind.isEmpty { head.append(waitKind) }
        let dur = Self.waitDurationLabel(sinceMs: waitSinceMs)
        if !dur.isEmpty { head.append(dur) }
        if let sig = waitSignal { head.append(sig.rawValue) }
        let headText = head.joined(separator: " · ")
        if !waitMessage.isEmpty {
            if headText.isEmpty { return "↳ \(waitMessage)" }
            return "↳ \(headText): \(waitMessage)"
        }
        if headText.isEmpty { return "↳ Needs you" }
        return "↳ \(headText)"
    }

    var taskLine: String? {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Drop placeholder harvest titles that aren't real session detail.
    var usefulTask: String? {
        guard let t = taskLine else { return nil }
        let junk: Set<String> = [
            "-", "—", "Running", "Active", "none",
            "Agent session", "Chat", "Amp session", "Amp thread",
        ]
        if junk.contains(t) { return nil }
        if t.hasPrefix("/"), !t.contains(" ") { return nil }
        return t
    }

    /// First-class session detail for tray (task title). Tool-only falls back for live rows.
    var sessionDetail: String? {
        if let t = usefulTask { return t }
        if waiting { return nil }
        let toolTrim = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if !toolTrim.isEmpty, liveProcess || subRunning > 0 { return toolTrim }
        return nil
    }

    /// Recent (not live) rows may soft-prefix with L10n activityPrefix in the view.
    var isRecentOnly: Bool {
        !waiting && !liveProcess && subRunning == 0
    }

    /// Live / subagent with no real session title — secondary in list IA.
    var isProcessOnly: Bool {
        !waiting && (liveProcess || subRunning > 0) && usefulTask == nil
    }

    /// Has a first-class session title (sorts above process-only peers).
    var hasSessionTitle: Bool { usefulTask != nil }

    /// "What it was doing" — kept for callers; prefer `sessionDetail` in tray.
    var activitySnippet: String? {
        sessionDetail
    }

    var focusTier: FocusTier? {
        TerminalFocus.focusTier(row: self)
    }

    /// Compact meta: "↑12k ↓3k · Bash · sub 2↑/5"
    /// Waiting rows omit tokens (status first). Tool alone goes to sessionDetail when no task.
    var metaLine: String? {
        var bits: [String] = []
        if !waiting {
            let tin = Self.compactToken(tokensIn)
            let tout = Self.compactToken(tokensOut)
            if !tin.isEmpty || !tout.isEmpty {
                var tok = ""
                if !tin.isEmpty { tok += "↑\(tin)" }
                if !tout.isEmpty {
                    if !tok.isEmpty { tok += " " }
                    tok += "↓\(tout)"
                }
                bits.append(tok)
            }
        }
        if !tool.isEmpty, usefulTask != nil { bits.append(tool) }
        if !skill.isEmpty, skill != "pending" { bits.append(skill) }
        if let sub = subagentLine { bits.append(sub) }
        // When project already in title, still hint session if both exist (multi-session same project).
        if let hint = shortSessionHint, !Self.shortProject(project).isEmpty {
            bits.append(hint)
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    /// e.g. `sub 2↑/5` when Claude has parallel subagents.
    var subagentLine: String? {
        guard subTotal > 0 else { return nil }
        if subRunning > 0 {
            return "sub \(subRunning)↑/\(subTotal)"
        }
        return "sub \(subTotal)"
    }

    var canOpenFolder: Bool {
        let path = cwd.isEmpty ? project : cwd
        guard !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var canFocusTerminal: Bool {
        TerminalFocus.canFocus(row: self)
    }

    static func shortProject(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if s.contains("/") {
            s = (s as NSString).lastPathComponent
        }
        if s.range(of: #"^[0-9a-fA-F-]{16,}$"#, options: .regularExpression) != nil { return "" }
        if s.count > 24 { return String(s.prefix(23)) + "…" }
        return s
    }

    static func compactToken(_ n: Int) -> String {
        guard n > 0 else { return "" }
        if n < 1000 { return "\(n)" }
        if n < 10_000 { return String(format: "%.1fk", Double(n) / 1000.0) }
        if n < 1_000_000 { return "\(n / 1000)k" }
        // Soft magnitude — avoid accounting-style millions in a status lamp.
        return String(format: "%.1fM", Double(n) / 1_000_000.0)
    }

    static func waitDurationLabel(sinceMs: Int64) -> String {
        guard sinceMs > 0 else { return "" }
        let ago = Date().timeIntervalSince1970 - Double(sinceMs) / 1000.0
        if ago < 5 { return "now" }
        if ago < 60 { return "\(Int(ago))s" }
        if ago < 3600 { return "\(Int(ago / 60))m" }
        return "\(Int(ago / 3600))h"
    }
}

struct PulseSnapshot: Equatable {
    var glance: GlanceKind = .idle
    var title: String = ""
    var tooltip: String = "Pulse"
    /// Short status word for tray header (Needs you / Running / …).
    var headerTitle: String = ""
    /// Supporting line under headerTitle (names · relative time).
    var headerDetail: String = ""
    var header: String = "No coding agents"
    var rows: [AgentRow] = []
    var hiddenCount: Int = 0
    var totalCount: Int = 0
    var probeError: String?
    var updatedAt: Date = .distantPast
}

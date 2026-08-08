import Foundation

/// Single source of truth for the product version.
///
/// `semver` is the truth; `scripts/version_check.py` keeps the CHANGELOG and
/// the README badge from drifting away from it. Build metadata (commit, date)
/// is injected into `Info.plist` by `PulseBar/Scripts/package.sh`, so a `swift
/// run` build honestly reports itself as `dev` instead of faking a release id.
enum PulseVersion {
    static let semver = "0.70.0"

    enum Channel {
        /// Packaged Pulse.app whose bundle version matches this binary.
        case release
        /// `swift run` / unpackaged — no build metadata.
        case dev
        /// Packaged, but Info.plist disagrees with the compiled semver.
        case mismatch(bundle: String)
    }

    private static func plist(_ key: String) -> String? {
        guard let raw = Bundle.main.infoDictionary?[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `CFBundleShortVersionString` of the running bundle, when packaged.
    static var bundleVersion: String? { plist("CFBundleShortVersionString") }

    /// Short git sha stamped at package time (`dev` when unpackaged).
    static var commit: String { plist("PulseGitCommit") ?? "dev" }

    /// ISO date stamped at package time (empty when unpackaged).
    static var buildDate: String { plist("PulseBuildDate") ?? "" }

    /// `preview` (ad-hoc) / `signed` (Developer ID, not notarized) / `stable`
    /// (notarized) / `dev` (unpackaged). Never treat signed-as-stable.
    static var distributionChannel: String {
        plist("PulseDistributionChannel") ?? (bundleVersion == nil ? "dev" : "preview")
    }

    /// Stapler success stamp from `package.sh`. Absent or false → not Gatekeeper-ready.
    static var isNotarized: Bool {
        (plist("PulseNotarized") ?? "false").lowercased() == "true"
    }

    /// True only for notarized stable builds that other Macs can open without
    /// the Control-click recovery path.
    static var isGatekeeperReady: Bool {
        distributionChannel == "stable" && isNotarized
    }

    /// Preview and signed-but-unnotarized builds should follow prerelease feeds.
    static var prefersPrereleaseUpdates: Bool {
        switch distributionChannel {
        case "stable": return false
        case "dev": return false
        default: return true
        }
    }

    static var channel: Channel {
        guard let bundle = bundleVersion else { return .dev }
        return bundle == semver ? .release : .mismatch(bundle: bundle)
    }

    /// Compact badge for tray footer / logs: `x.y.z`, `x.y.z-dev`, `x.y.z≠<bundle>`.
    static var short: String {
        switch channel {
        case .release: return semver
        case .dev: return "\(semver)-dev"
        case .mismatch(let bundle): return "\(semver)≠\(bundle)"
        }
    }

    /// `Pulse x.y.z` — About heading.
    static var about: String { "Pulse \(short)" }

    /// Second About line: `<sha> · <date>`. Empty when there is nothing honest to show.
    static var buildLine: String {
        var bits: [String] = []
        if commit != "dev" { bits.append(commit) }
        if !buildDate.isEmpty { bits.append(buildDate) }
        return bits.joined(separator: " · ")
    }

    /// One line that fully identifies this build — logs and bug reports.
    static var fingerprint: String {
        let build = buildLine
        return build.isEmpty ? "Pulse \(short)" : "Pulse \(short) (\(build))"
    }
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
    case zcode

    var id: String { rawValue }

    /// User-facing identity used when several vendor processes share one
    /// surface. Cursor's `cursor-agent` worker is observed separately by the
    /// collectors, but it is deliberately one Cursor row in the tray,
    /// support matrix, and attention ledger.
    var surfaceID: AgentID {
        self == .cursorAgent ? .cursor : self
    }

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
        case .zcode: return "ZCode"
        }
    }

    // `isSurface` used to gate Glance/Tray, but every case returned true — the
    // whole AgentID list is the surface list. The vacuous filter is gone; if a
    // non-surface id ever lands here, reintroduce the predicate deliberately.

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
        case .replit, .antigravity, .trae, .warpAgent, .devin, .junie, .zcode:
            return .none
        }
    }

    /// What the local collector is allowed to promise before runtime data is
    /// considered. Every agent can still degrade to process detection.
    ///
    /// `structuredSession` means the adapter reads a session/thread/composer
    /// identity and its activity facts. `bestEffortCache` means the vendor
    /// exposes no stable local session contract and Pulse may only recover a
    /// workspace or title. The README matrix is checked against this switch so
    /// "a collector function exists" can no longer be advertised as equivalent
    /// session observability.
    var harvestSource: HarvestSource {
        switch self {
        case .claude, .codex, .cursor, .grok, .pi, .amp, .aider, .gemini,
             .copilot, .opencode, .goose, .openhands, .continue_, .droid,
             .commandCode, .kimi:
            return .structuredSession
        case .cursorAgent, .amazonQ, .cline, .roo, .cascade, .windsurf,
             .augment, .zedAgent, .trae, .warpAgent, .kilo, .devin, .kiro,
             .junie, .replit, .antigravity, .zcode:
            return .bestEffortCache
        }
    }

    /// Some adapters keep their only useful session/cache evidence inside
    /// macOS-protected Application Support, App Group, or VS Code stores. The
    /// default scanner deliberately skips those locations; the support window
    /// uses this bit to explain that an unavailable row may be privacy-limited,
    /// not unsupported.
    var requiresAppDataOptIn: Bool {
        switch self {
        case .cursor, .cursorAgent, .amazonQ, .cline, .roo, .cascade, .windsurf,
             .zedAgent, .trae, .warpAgent, .kilo, .kiro, .junie, .replit,
             .antigravity, .zcode:
            return true
        default:
            return false
        }
    }

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

/// Evidence carried by this specific row, not a blanket promise for an agent.
///
/// An agent may have a structured collector and still degrade to a process
/// row when its local session store is unavailable. The view uses this value
/// to choose an information architecture instead of making every row look
/// equally certain.
enum ObservationSource: String, Equatable, Hashable {
    case session
    case cache
    case process
}

/// Named fact keys for the 0.50 Signal Quality envelope.
///
/// Every observed row must either present these facts or explain why they are
/// missing. Unknown is shown as unknown; Pulse never invents a goal, phase, or
/// wait reason from process noise.
enum ObservationFactKey: String, CaseIterable, Equatable, Hashable {
    case task
    case workspace
    case action
    case phase
    case model
    case progress
    case error
    case waitingReason
    case evidence
    case freshness
}

enum ObservationConfidence: String, Equatable, Hashable {
    case high
    case medium
    case low
}

enum FreshnessSource: String, Equatable, Hashable {
    case sourceMtime = "source_mtime"
    case harvest
    case processStart = "process_start"
    case unknown
}

/// One missing fact with a stable reason/next-step code for localization.
struct ObservationGap: Equatable, Hashable {
    var key: ObservationFactKey
    /// Stable code — never a free-form path or payload.
    var reason: String
    var nextStep: String
}

/// Per-row signal quality. Drives Limited-data copy and Support Health depth.
struct ObservationQuality: Equatable, Hashable {
    var facts: Set<ObservationFactKey> = []
    var missing: [ObservationGap] = []
    var freshnessMs: Int64 = 0
    var freshnessSource: FreshnessSource = .unknown
    var confidence: ObservationConfidence = .low

    var isLimited: Bool {
        confidence != .high
            || !facts.contains(.evidence)
            || (!facts.contains(.task) && !facts.contains(.workspace) && !facts.contains(.action))
    }

    /// Derive quality from the final merged row fields. Call after harvest,
    /// process attach, and Waiting merge so the envelope matches what the tray
    /// shows.
    static func derive(
        task: String,
        workspace: String,
        action: String,
        phase: String,
        model: String,
        progressDone: Int,
        progressTotal: Int,
        errors: Int,
        waiting: Bool,
        waitMessage: String,
        evidence: ObservationSource,
        harvestMs: Int64,
        processStartedMs: Int64,
        privacyLimited: Bool,
        agentHarvestSource: HarvestSource,
        waitingSource: WaitingSource
    ) -> ObservationQuality {
        var facts: Set<ObservationFactKey> = [.evidence]
        var missing: [ObservationGap] = []

        func present(_ key: ObservationFactKey, when ok: Bool, reason: String, next: String) {
            if ok {
                facts.insert(key)
            } else {
                missing.append(ObservationGap(key: key, reason: reason, nextStep: next))
            }
        }

        let hasTask = !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasWorkspace = !workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAction = !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPhase = !phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasModel = !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasProgress = progressTotal > 0
        let hasError = errors > 0
        let hasWaitReason = waiting && !waitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let baseReason: String
        let baseNext: String
        switch evidence {
        case .process:
            baseReason = privacyLimited ? "privacy_limited" : "process_only"
            baseNext = privacyLimited ? "enable_app_data" : "open_agent_for_session"
        case .cache:
            if privacyLimited {
                baseReason = "privacy_limited"
                baseNext = "enable_app_data"
            } else {
                // Rich Limited ≈ goal + workspace/action present; thin is title-only.
                let previewCore = [hasTask, hasWorkspace, hasAction].filter { $0 }.count
                baseReason = previewCore >= 2 ? "cache_conditional" : "cache_thin"
                baseNext = "wait_for_vendor_cache"
            }
        case .session:
            baseReason = "not_emitted"
            baseNext = "open_agent_for_session"
        }

        present(.task, when: hasTask, reason: baseReason, next: baseNext)
        present(.workspace, when: hasWorkspace, reason: baseReason, next: baseNext)
        present(.action, when: hasAction, reason: baseReason, next: baseNext)
        present(.phase, when: hasPhase, reason: baseReason, next: baseNext)
        present(.model, when: hasModel, reason: baseReason, next: baseNext)
        present(.progress, when: hasProgress, reason: "not_emitted", next: "open_agent_for_session")
        if hasError {
            facts.insert(.error)
        } else {
            // Errors are enhancements when zero — do not demand a failure.
        }
        if waiting {
            if hasWaitReason {
                facts.insert(.waitingReason)
            } else {
                missing.append(ObservationGap(
                    key: .waitingReason,
                    reason: "waiting_no_detail",
                    nextStep: "open_agent_for_session"
                ))
            }
        } else if waitingSource == .none {
            missing.append(ObservationGap(
                key: .waitingReason,
                reason: "waiting_unsupported",
                nextStep: "use_attention_bridge"
            ))
        }

        let freshnessMs: Int64
        let freshnessSource: FreshnessSource
        if harvestMs > 0 {
            freshnessMs = harvestMs
            freshnessSource = evidence == .process ? .harvest : .sourceMtime
            facts.insert(.freshness)
        } else if processStartedMs > 0 {
            freshnessMs = processStartedMs
            freshnessSource = .processStart
            facts.insert(.freshness)
        } else {
            freshnessMs = 0
            freshnessSource = .unknown
            missing.append(ObservationGap(
                key: .freshness,
                reason: baseReason,
                nextStep: baseNext
            ))
        }

        let coreCount = [.task, .workspace, .action, .evidence]
            .filter { facts.contains($0) }.count
        let confidence: ObservationConfidence
        switch evidence {
        case .session:
            confidence = coreCount >= 4 ? .high : (coreCount >= 2 ? .medium : .low)
        case .cache:
            confidence = coreCount >= 3 ? .medium : .low
            if agentHarvestSource == .bestEffortCache, coreCount < 3 {
                // Keep confidence honest for thin cache adapters.
            }
        case .process:
            confidence = .low
        }

        return ObservationQuality(
            facts: facts,
            missing: missing,
            freshnessMs: freshnessMs,
            freshnessSource: freshnessSource,
            confidence: confidence
        )
    }
}

/// Privacy-safe reason a process rule matched.
///
/// The support window needs to explain why Pulse believes an Agent is live,
/// but the full command line can contain paths, prompts, tokens, and secrets.
/// Keep only the rule class.
enum ProcessEvidence: String, Equatable, Hashable {
    case executable
    case pathSignature = "path_signature"
}

/// How this row's Waiting was raised (shown as a short credibility tag).
enum WaitSignalKind: String, Equatable {
    case hooks
    case pending
}

/// Honesty tier for Focus — never claim session/tab precision when we only activate an app.
enum FocusTier: Equatable, Hashable {
    /// Terminal/iTerm tab select (Automation opt-in only).
    case tty
    /// Warp app activate — never tab-precise.
    case warp
    /// Host IDE with an absolute workspace path we can open via `open -a`.
    case hostWorkspace(HostAppKind)
    /// Host IDE app activate only.
    case hostApp(HostAppKind)
}

enum GlanceKind: Equatable {
    case idle
    case running
    case stalled
    case waiting
    case error

    /// VoiceOver reads this instead of the icon. It used to be hardcoded
    /// English, so a Chinese user heard "Needs attention" in an otherwise
    /// localized interface.
    var accessibilityKey: L10n.Key {
        switch self {
        case .idle: return .a11yIdle
        case .running: return .a11yRunning
        case .stalled: return .a11yStalled
        case .waiting: return .a11yWaiting
        case .error: return .a11yError
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
    /// Host IDE detected by walking the process parent chain (`ps` only).
    var hostApp: HostAppKind? = nil
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
    /// How this row can be focused — resolved once per scan, never in a view body.
    var focusTier: FocusTier? = nil
    /// Sessions of this agent that exist but did not fit the per-agent cap.
    var hiddenSessions: Int = 0
    /// Records in the session file. 0 = unknown, never estimated.
    ///
    /// Not conversational turns — the transcript counts tool calls, tool
    /// results and token events too. Shipped as "turns" in 0.28.0, which
    /// promised a precision the number does not have.
    var records: Int = 0
    var phase: String = ""
    var outcome: String = ""
    var model: String = ""
    var mode: String = ""
    var errors: Int = 0
    var files: Int = 0
    var contextPercent: Int = 0
    var progressDone: Int = 0
    var progressTotal: Int = 0
    /// A bounded, cross-scan change signal. Static counters answer "how much";
    /// this answers the more useful operational question: "what just moved?"
    var activityChange: AgentActivityChange? = nil
    var activityChangedMs: Int64 = 0
    /// When the session began, in ms. 0 = unknown.
    var startedMs: Int64 = 0
    /// What this concrete row is backed by.
    var observationSource: ObservationSource = .process
    /// When the matched OS process began, in ms. Never presented as session age.
    var processStartedMs: Int64 = 0
    /// Why the process probe matched, without retaining argv.
    var processEvidence: ProcessEvidence? = nil
    /// Named Signal Quality envelope — facts present, gaps with reasons, freshness.
    var quality: ObservationQuality = ObservationQuality()

    /// Recompute `quality` from the merged row. Safe to call after every scan merge.
    mutating func refreshObservationQuality(privacyLimited: Bool = false) {
        let workspace = cwd.isEmpty ? project : cwd
        quality = ObservationQuality.derive(
            task: usefulTask ?? "",
            workspace: workspace,
            action: tool.isEmpty ? skill : tool,
            phase: phase,
            model: model,
            progressDone: progressDone,
            progressTotal: progressTotal,
            errors: errors,
            waiting: waiting,
            waitMessage: waitMessage.isEmpty ? waitKind : waitMessage,
            evidence: observationSource,
            harvestMs: harvestMs,
            processStartedMs: processStartedMs,
            privacyLimited: privacyLimited,
            agentHarvestSource: agent.harvestSource,
            waitingSource: agent.waitingSource
        )
    }

    /// How long this session has been going, in seconds; 0 when unknown.
    ///
    /// Distinct from `lastActivitySeconds`, which is when it last moved. The
    /// panel could say "1m ago" for a session that started three hours back and
    /// had no way to say the three hours.
    func sessionAgeSeconds(nowMs: Int64) -> Double {
        guard startedMs > 0, nowMs > startedMs else { return 0 }
        return Double(nowMs - startedMs) / 1000.0
    }
    /// Seconds left on a "remind me later", resolved at scan time. 0 = not snoozed.
    ///
    /// Snoozing suppresses the *interruption* — lamp, menu-bar text, banner —
    /// and nothing else. The row stays in the list, in Needs-you, with the
    /// remaining time on its chip. This mirrors the rule muting already
    /// follows: a muted agent stops notifying and still appears. A button that
    /// makes a row disappear is a button nobody dares press.
    var snoozeRemainingSeconds: Double = 0

    var isSnoozed: Bool { waiting && snoozeRemainingSeconds > 0 }

    var id: String { rowKey }

    var titleLine: String {
        var parts: [String] = [agent.displayName]
        let short = Self.shortProject(project)
        if !short.isEmpty,
           short.compare(agent.displayName, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
            parts.append(short)
        } else if let hint = shortSessionHint {
            // No project — show short session so multi-row agents stay distinguishable.
            parts.append(hint)
        }
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

    // Waiting reason lines are built in `StatusStore.localizedWaitDetail` so
    // durations and kinds follow the resolved language.

    var taskLine: String? {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Drop placeholder harvest titles that aren't real session detail.
    var usefulTask: String? {
        guard let raw = taskLine else { return nil }
        let t = Self.displayTaskTitle(raw)
        let junk: Set<String> = [
            "-", "—", "Running", "Active", "none",
            "Agent session", "Chat", "Amp session", "Amp thread",
            // Placeholders that shipped as row titles in 0.25.
            "New Session", "New session", "Untitled", "New Chat", "New chat",
            "Pi session", "Cursor session", "Grok session",
            // Fleet chrome — vendor default titles are identity, not goals.
            "OpenCode session", "Gemini session", "Goose session",
            "Copilot session", "Continue session", "Warp session",
            "Windsurf session", "Cline session", "Roo session",
            "Aider session", "Droid session", "Kimi session",
        ]
        if junk.contains(t) { return nil }
        let low = t.lowercased()
        let agent = agent.displayName.lowercased()
        if low == agent { return nil }
        let genericSuffixes = [" session", " thread", " chat", " task", " agent"]
        if genericSuffixes.contains(where: { low == agent + $0 }) { return nil }
        if t.hasPrefix("/"), !t.contains(" ") { return nil }
        // Harvest sometimes promotes the live tool id (update_plan, Bash) or a
        // lone filename into `task`. Those are actions/paths, not goals.
        let toolTrim = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if !toolTrim.isEmpty, t.caseInsensitiveCompare(toolTrim) == .orderedSame {
            return nil
        }
        if Self.looksLikeInternalToolIdentifier(t) { return nil }
        if Self.looksLikeFilenameOnlyTitle(t) { return nil }
        return t
    }

    /// Session titles are plain UI labels, not a Markdown renderer.
    ///
    /// Codex can preserve the user's `[label](URL)` prompt syntax as its task
    /// title. Showing the transport syntax spends scarce tray width on an
    /// address that is neither actionable nor easier to scan. Keep the label
    /// and the surrounding sentence; keep the raw task untouched for matching
    /// and diagnostics.
    static func displayTaskTitle(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(
            of: #"!?\[([^\]\n]{1,240})\]\((?:https?|file)://[^)\n]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = cleaned
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "·", with: "")
        switch compact {
        case "piupdate", "updatepi", "upgradepi":
            return "Update Pi and extensions"
        case "pilist", "listpi":
            return "List Pi agents"
        case "update", "upgrade":
            return "Update agent packages"
        case "resume":
            return "Resume agent session"
        default:
            return cleaned
        }
    }

    /// `update_plan`, namespaced MCP leaves, etc. — never a user goal.
    static func looksLikeInternalToolIdentifier(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return false }
        let low = t.lowercased()
        if low.contains(":") { return true } // mcp:server:tool
        let known: Set<String> = [
            "bash", "shell", "exec", "read", "write", "grep", "glob",
            "update_plan", "todowrite", "todo_write", "run_terminal_cmd",
            "run_terminal_command", "batch_execute",
        ]
        if known.contains(low) { return true }
        if low.hasPrefix("mcp_") || low.hasPrefix("mcp.") { return true }
        if low.hasSuffix("_plan") || low.hasSuffix("_todo") { return true }
        if low.hasPrefix("run_") && low.contains("terminal") { return true }
        // snake_case tool leaves: verb_noun with a known verb head.
        if low.contains("_") {
            let head = low.split(separator: "_").first.map(String.init) ?? ""
            return [
                "update", "run", "edit", "write", "read", "search", "browser",
                "patch", "grep", "glob", "exec", "bash", "shell",
            ].contains(head)
        }
        return false
    }

    /// Pi (and others) sometimes stamp `Read Foo.swift` or bare `Foo.swift`.
    static func looksLikeFilenameOnlyTitle(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(
            of: #"^(Read|Reading)\s+\S+\.\w{1,12}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        guard !t.contains(" "), t.contains(".") else { return false }
        let ext = (t as NSString).pathExtension.lowercased()
        let code = [
            "swift", "ts", "tsx", "js", "jsx", "py", "md", "json", "go", "rs",
            "rb", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "cs", "sh",
        ]
        return code.contains(ext)
    }

    /// First-class session detail for tray (real task title only).
    ///
    /// Live tool identifiers are not titles — the tray humanizes them as a
    /// separate hero fallback via `StatusStore.heroToolTitle`.
    var sessionDetail: String? { usefulTask }

    /// Live/subagent or recent row has a tool string that can stand in after
    /// humanization when there is no real session title.
    var hasLiveToolFallback: Bool {
        guard !waiting else { return false }
        return !tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Recent (not live) rows may soft-prefix with L10n activityPrefix in the view.
    var isCompletedPhase: Bool {
        let value = phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "turn_complete" || value == "completed" || value == "complete"
    }

    /// Explicit lifecycle evidence from a session store can establish Running
    /// even when the work is remote and has no matching local process.
    var isExplicitlyRunningPhase: Bool {
        let value = phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "running"
            || value == "in_progress"
            || value == "working"
            || value == "executing"
    }

    var isRecentOnly: Bool {
        !waiting
            && !isExplicitlyRunningPhase
            && (!liveProcess || isCompletedPhase)
            && subRunning == 0
    }

    /// Live / subagent with nothing to say about the session — secondary in list IA.
    /// A known live tool still counts as something to say (humanized in the tray).
    var isProcessOnly: Bool {
        !waiting && (liveProcess || subRunning > 0) && usefulTask == nil && !hasLiveToolFallback
    }

    /// Has a first-class session title (sorts above process-only peers).
    var hasSessionTitle: Bool { usefulTask != nil }


    /// `↑12k ↓3k` — how much this session has actually moved.
    ///
    /// The only quantity the app has, and until 0.28 it lived behind a hover
    /// and then behind an expand. A panel whose rows carry a name, a path and
    /// a relative time has nothing on it that changes as work happens; this
    /// does. Waiting rows omit it, because there the question is the point.
    var tokenLine: String? {
        guard !waiting else { return nil }
        let tin = Self.compactToken(tokensIn)
        let tout = Self.compactToken(tokensOut)
        guard !tin.isEmpty || !tout.isEmpty else { return nil }
        var tok = ""
        if !tin.isEmpty { tok += "↑\(tin)" }
        if !tout.isEmpty {
            if !tok.isEmpty { tok += " " }
            tok += "↓\(tout)"
        }
        return tok
    }

    /// Compact meta: "↑12k ↓3k · Bash · sub 2↑/5"
    /// Waiting rows omit tokens (status first). Tool alone goes to sessionDetail when no task.
    var metaLine: String? {
        var bits: [String] = []
        if let tok = tokenLine { bits.append(tok) }
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

    var canFocusTerminal: Bool { focusTier != nil }

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

    /// Seconds a Waiting row has been outstanding (0 when unknown).
    /// Formatting lives in `StatusStore.waitDurationLabel` so units localize.
    var waitAgeSeconds: Double {
        guard waitSinceMs > 0 else { return 0 }
        return max(0, Date().timeIntervalSince1970 - Double(waitSinceMs) / 1000.0)
    }

    /// Where this session lives, written the way a person would write it.
    ///
    /// `cwd` has been collected since the beginning and never shown. The tray
    /// could say who and what, but never *where* — so two Claude sessions in
    /// different repos were indistinguishable.
    var displayPath: String {
        let raw = cwd.isEmpty ? project : cwd
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // The home directory is not a project.
        //
        // 0.25 rendered it as "~" and grouped sessions under it, then a session
        // that had no cwd fell back to its harvest-encoded project name and the
        // *same* directory appeared a second time as "users-<name>". One
        // location, two groups, and a header claiming three projects where
        // there were two.
        if Self.isHomeLike(trimmed, home: home) { return "" }

        guard trimmed.hasPrefix("/") else { return Self.shortProject(trimmed) }
        var path = trimmed
        if !home.isEmpty, path.hasPrefix(home + "/") {
            path = "~" + path.dropFirst(home.count)
        }
        // Keep the tail: the last two components carry the identity, the
        // middle of a deep path does not.
        let parts = path.split(separator: "/").map(String.init)
        if parts.count > 3 {
            return (path.hasPrefix("~") ? "~/…/" : "/…/") + parts.suffix(2).joined(separator: "/")
        }
        return path
    }

    /// Every spelling of "the home directory" this data can produce.
    ///
    /// Harvest hands back either a real path or a decoded form of Claude's
    /// encoded project directory (`-Users-name` → `users-name`), so the same
    /// place arrives under several names and has to be collapsed before it can
    /// be grouped or counted.
    static func isHomeLike(_ raw: String, home: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "~" || s == "~/" { return true }
        guard !home.isEmpty else { return false }
        if s == home || s == home + "/" { return true }
        let user = (home as NSString).lastPathComponent.lowercased()
        guard !user.isEmpty else { return false }
        let low = s.lowercased()
        // `-Users-name` decoded to `users-name`, and the bare account name.
        return low == user || low == "users-\(user)" || low == "-users-\(user)"
    }

    /// Seconds since this session last did anything (0 when unknown).
    ///
    /// Prefer the fresher of harvest mtime and a live signal move
    /// (`activityChangedMs`) — progress/tokens can advance without a newer
    /// filesystem stamp.
    var lastActivitySeconds: Double {
        let lastMs = max(harvestMs, activityChangedMs)
        guard lastMs > 0 else { return 0 }
        return max(0, Date().timeIntervalSince1970 - Double(lastMs) / 1000.0)
    }

    /// Running with a live session is the ordinary case, and the ordinary case
    /// does not need a badge. Only states worth reacting to get one.
    var needsStatusChip: Bool {
        if waiting || isProcessOnly || isRecentOnly || isStalled { return true }
        return false
    }

    /// Live, but nothing has moved for a long time.
    ///
    /// As real a signal as Waiting and never surfaced: an agent that has been
    /// "running" for twenty minutes without touching anything is usually stuck
    /// on something, and the tray showed it exactly like a healthy session.
    /// Default only. The real threshold comes from settings and rides in on
    /// `SnapshotBuilder.Context` — twenty minutes is right for nobody in
    /// particular: a long compile is not stalled at twenty, and a short
    /// question-and-answer session is stuck well before it.
    static let stalledSeconds: Double = 20 * 60

    /// Resolved once per scan against the scan's own clock, not `Date()`.
    ///
    /// As a computed property this reached for the real clock while the builder
    /// around it ran on an injected `nowMs` — so with a fixed test clock every
    /// row read as stalled by years. `focusTier` was moved to scan time in
    /// 0.23 for the same reason.
    var isStalled: Bool = false

    /// Whether this row would be stalled at the given instant.
    ///
    /// `threshold <= 0` means the user turned staleness off, which must read as
    /// "never stalled" rather than "always stalled".
    ///
    /// `activityChangedMs` counts as a live signal (progress / tokens / …) even
    /// when `harvestMs` did not move — same rule as the change banner. A zero
    /// clock is still *not* evidence of silence (unknown ≠ stalled row), but
    /// Glance must not treat thin/process-only Running as healthy green.
    static func stalled(
        harvestMs: Int64,
        nowMs: Int64,
        waiting: Bool,
        live: Bool,
        threshold: Double = stalledSeconds,
        activityChangedMs: Int64 = 0
    ) -> Bool {
        guard threshold > 0, !waiting, live else { return false }
        let lastMs = max(harvestMs, activityChangedMs)
        guard lastMs > 0 else { return false }
        return Double(nowMs - lastMs) / 1000.0 >= threshold
    }

    /// Session-backed Running that may light a healthy green glance.
    /// Process-only / no-mtime rows stay live in the tray but are not "healthy".
    var isHealthyRunning: Bool {
        section == .running && !isProcessOnly && harvestMs > 0
    }

    /// Live Running without a trusted activity clock or session title.
    var isThinRunning: Bool {
        section == .running && (isProcessOnly || harvestMs == 0)
    }

    /// A wait old enough to deserve more than the ordinary Waiting treatment.
    /// This is the *only* place "longer" becomes "louder" — every other visual
    /// encoding stays constant, so the escalation actually reads as one.
    static let urgentWaitSeconds: Double = 600

    var isUrgentWait: Bool { waiting && waitAgeSeconds >= Self.urgentWaitSeconds }

    /// Which tray section this row belongs to.
    var section: TraySection {
        if waiting { return .needsYou }
        if isCompletedPhase, subRunning == 0 { return .recent }
        if isStalled { return .stalled }
        if liveProcess || isExplicitlyRunningPhase || subRunning > 0 { return .running }
        return .recent
    }
}

enum AgentActivityChange: Hashable {
    case errors(Int)
    case files(Int)
    case progress(done: Int, total: Int)
    case modelCall
    case completed
    case failed
    case cancelled
}

/// Tray rows are grouped under a heading rather than relying on sort order
/// alone — five rows in one undifferentiated stack read as five equals.
enum TraySection: Int, CaseIterable, Hashable {
    case needsYou = 0
    case running = 1
    case stalled = 2
    case recent = 3

    var titleKey: L10n.Key {
        switch self {
        case .needsYou: return .sectionNeedsYou
        case .running: return .sectionRunning
        case .stalled: return .sectionStalled
        case .recent: return .sectionRecent
        }
    }
}

/// Runtime truth for one supported Agent.
///
/// The support matrix says what an adapter is designed to read. This model
/// says what Pulse actually observed on this Mac in the latest good scan.
/// Keeping the two distinct prevents a declared collector from being presented
/// as rich support when the vendor store is missing, unreadable, or changed.
struct AgentSupportHealth: Identifiable, Equatable {
    var agent: AgentID
    var collectorState: ActivityHarvest.CollectorState
    var collectorDurationMs: Int
    var collectorRows: Int
    var sourcePresent: Bool
    var collectorErrorKind: String
    var processDetected: Bool
    var processEvidence: ProcessEvidence?
    /// Earliest matched process start for this Agent, when the probe provided
    /// it. This is process evidence, not session age.
    var processStartedMs: Int64 = 0
    /// Number of matching processes represented by the support row.
    var processCount: Int = 0
    var evidence: ObservationSource?
    var lastSuccessfulReadMs: Int64
    var lastWaitingSignalMs: Int64
    var hasGoal: Bool
    var hasWorkspace: Bool
    var hasActivity: Bool
    var hasProgress: Bool
    var waitingSignalReady: Bool
    /// True when the latest result may be incomplete because the user keeps
    /// protected app-data reads disabled. This is explanatory UI state, not a
    /// claim that the Agent is installed.
    var privacyLimited: Bool = false
    /// Optional operational facts shown separately from the four core facts.
    /// These are inventory signals, not quality gates: an Agent may not expose
    /// a model or resource counter in its local store, but that absence must be
    /// visible instead of silently making every adapter look equivalent.
    var hasActionSignal: Bool = false
    var hasModelSignal: Bool = false
    var hasResourceSignal: Bool = false
    /// Best Focus handle among this Agent's rows this scan — nil means observation only.
    var focusTier: FocusTier? = nil
    /// A real TTY exists but Shortcuts Automation is off — honest, not clickable.
    var focusTTYNeedsOptIn: Bool = false
    /// Seconds since the freshest session activity clock (0 = unknown).
    /// Distinct from `lastSuccessfulReadMs` (Pulse read the adapter).
    var activityAgeSeconds: Double = 0
    /// True when any live row for this Agent is currently marked stalled.
    var hasStalledLive: Bool = false

    var id: AgentID { agent }

    var isObserved: Bool { processDetected || evidence != nil }

    var missingCapabilities: [SupportCapability] {
        guard isObserved else { return [.notDetected] }
        var missing: [SupportCapability] = []
        if evidence == .process || !hasActivity { missing.append(.activityFeed) }
        if !hasGoal { missing.append(.goal) }
        if !hasWorkspace { missing.append(.workspace) }
        if agent.waitingSource != .none, !waitingSignalReady {
            missing.append(.waitingSignal)
        }
        return missing
    }

    var observedFactCount: Int {
        [
            hasGoal,
            hasWorkspace,
            hasActivity,
            evidence != nil || processDetected,
        ].filter { $0 }.count
    }

    /// User-value scorecard: goal, workspace, activity, progress, and a usable
    /// Waiting route when that Agent actually exposes one. Process detection is
    /// evidence, not useful content; an Agent with no Waiting contract must not
    /// lose a point for a capability it cannot provide.
    var usefulFactCount: Int {
        var facts = [
            hasGoal,
            hasWorkspace,
            hasActivity,
            hasProgress,
        ]
        if agent.waitingSource != .none {
            facts.append(waitingSignalReady)
        }
        return facts.filter { $0 }.count
    }

    /// Number of useful signals that are meaningful for this Agent's local
    /// contract. This keeps the support UI honest for cloud/opaque agents that
    /// do not expose a Waiting event at all.
    var usefulFactTotal: Int {
        agent.waitingSource == .none ? 4 : 5
    }

    var disposition: SupportDisposition {
        // A scan that ended before this adapter reported is an observation
        // gap, not an adapter failure. The support window shows the global
        // partial-scan banner and preserves the previous per-agent result.
        if collectorState == .unscanned {
            return isObserved ? .limited : .unscanned
        }
        if collectorState.isIssue {
            // A bounded timeout that already returned rows is actionable for
            // diagnostics, but the partial rows are still usable. Keep them
            // visible as limited rather than hiding them behind an error state.
            if collectorState == .failed, collectorRows > 0 { return .limited }
            if collectorState == .permissionDenied { return .permissionDenied }
            return .needsAction
        }
        if privacyLimited && !isObserved { return .permissionDenied }
        if isObserved,
           agent.waitingSource == .hooks,
           !waitingSignalReady {
            return .needsAction
        }
        guard isObserved else {
            if collectorState == .sourceAbsent { return .notInstalled }
            return .noRecentSession
        }
        if collectorState == .noSessions || collectorState == .noRecentData {
            return .noRecentSession
        }
        if evidence == .process
            || !hasGoal
            || !hasWorkspace
            || !hasActivity
            || !hasProgress
            || (agent.waitingSource != .none && !waitingSignalReady) {
            return .limited
        }
        return .available
    }

    var repair: SupportRepair {
        if disposition == .needsAction,
           agent.waitingSource == .hooks,
           !waitingSignalReady {
            return .installHooks
        }
        if disposition == .permissionDenied { return .openSettings }
        if collectorState.isIssue { return .retry }
        // Live opaque agents cannot invent Waiting — point at the Attention bridge.
        if agent.waitingSource == .none, processDetected {
            return .openAttentionBridge
        }
        return .none
    }
}

enum SupportDisposition: Int, Equatable {
    case available = 0
    case needsAction = 1
    case limited = 2
    case notInstalled = 3
    case noRecentSession = 4
    case permissionDenied = 5
    case unscanned = 6
}

enum SupportRepair: Equatable {
    case none
    case installHooks
    case retry
    case openSettings
    case runAgent
    case openAttentionBridge
}

enum SupportCapability: String, Equatable {
    case notDetected
    case activityFeed
    case goal
    case workspace
    case waitingSignal
}

struct PulseSnapshot: Equatable {
    var glance: GlanceKind = .idle
    var title: String = ""
    var tooltip: String = "Pulse"
    /// Glance state spoken by VoiceOver, in the resolved language.
    var accessibilityLabel: String = ""
    /// Short status word for tray header (Needs you / Running / …).
    var headerTitle: String = ""
    /// Supporting line under headerTitle (names · relative time).
    var headerDetail: String = ""
    var header: String = "No coding agents"
    var rows: [AgentRow] = []
    /// Section totals over the *whole* list, so a heading can say "3 running"
    /// even when the window is showing two of them.
    var sectionTotals: [TraySection: Int] = [:]
    /// Distinct projects across the whole list — an aggregate no single row
    /// can state, which is the only kind of thing the header should say.
    var projectCount: Int = 0
    /// Longest outstanding wait, in seconds — the number that decides who to
    /// deal with first, so it reaches the menu bar rather than staying buried
    /// in a row's third line.
    var longestWaitSeconds: Double = 0
    var hiddenCount: Int = 0
    /// Sessions suppressed by the per-agent cap (never silently dropped).
    var cappedSessions: Int = 0
    var totalCount: Int = 0
    var probeError: String?
    var updatedAt: Date = .distantPast
}

/// Which tray groups fold, and what a folded group still says.
///
/// Screenshots of 0.25.0 showed four rows, two of them Recent — finished
/// sessions, nothing to act on, taking half the panel and half the reading.
/// Folding them is the largest space win available without dropping a fact.
enum TrayFold {
    /// Groups are visible on every fresh panel open. Folding is an explicit,
    /// reversible user action; the aggregate count must never promise rows
    /// that the default view silently hides.
    static func isCollapsed(_ groupID: String, manuallyFolded: Set<String>) -> Bool {
        manuallyFolded.contains(groupID)
    }

    /// Below this many rows the panel is not crowded, so nothing folds.
    ///
    /// A 0.27 screenshot showed three sessions with two of them folded away —
    /// one visible row in a panel that had room for all three. Folding traded a
    /// line of screen for a click and hidden content, which is only a good
    /// trade when the screen is the scarce thing. It was not.
    static let crowdedFrom = 5

    /// A project group folds when nothing in it is waiting.
    ///
    /// `foldable` only ever answered for the Recent *section*, so grouping by
    /// project — the mode built for people running several repos at once — was
    /// the one mode where nothing folded and the panel was a flat list of every
    /// project. Same two guards as Recent, plus the one that matters here: a
    /// project holding a wait is never folded away.
    static func foldableProject(
        hasWaiting: Bool,
        groupCount: Int,
        rowCount: Int,
        totalRows: Int
    ) -> Bool {
        !hasWaiting && groupCount > 1 && rowCount >= 2 && totalRows >= crowdedFrom
    }

    /// Recent is foldable, but only when it is not the whole list.
    ///
    /// If Recent is all there is, those rows *are* the content and folding
    /// them leaves a panel that says nothing. The rule is "hide the part you
    /// are not here for", which requires there to be another part.
    static func foldable(
        section: TraySection,
        groupCount: Int,
        rowCount: Int,
        totalRows: Int
    ) -> Bool {
        section == .recent && groupCount > 1 && rowCount >= 2 && totalRows >= crowdedFrom
    }

    /// True when the summary names every row, making the count a repeat.
    ///
    /// Three Claude sessions summarise to "Claude" — one name for three rows,
    /// so the count is still the only thing saying how many. Two rows named
    /// "Pi · Amp" are a different case: the names *are* the count.
    static func summaryNamesEveryRow(_ rows: [AgentRow], limit: Int = 3) -> Bool {
        let distinct = Set(rows.map(\.agent)).count
        return distinct == rows.count && rows.count <= limit
    }

    /// Agents in the folded group, in first-seen order, deduplicated.
    ///
    /// A folded heading otherwise reads "Recent 3" — a count with no identity,
    /// which is exactly the question folding creates.
    static func summary(_ rows: [AgentRow], limit: Int = 3) -> String {
        var seen = Set<AgentID>()
        var names: [String] = []
        for row in rows where !seen.contains(row.agent) {
            seen.insert(row.agent)
            names.append(row.agent.displayName)
        }
        guard !names.isEmpty else { return "" }
        if names.count <= limit { return names.joined(separator: " · ") }
        return names.prefix(limit).joined(separator: " · ") + " +\(names.count - limit)"
    }
}

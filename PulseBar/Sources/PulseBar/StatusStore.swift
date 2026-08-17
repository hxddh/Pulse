import Foundation
import AppKit
import CryptoKit

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var snapshot = PulseSnapshot()
    @Published var autoProbe = true
    @Published var notifyOnIdle = true
    @Published var notifyOnWaiting = true
    /// Quiet hours suppress idle notify only; Waiting edges still fire when notifyOnWaiting.
    @Published var quietHoursEnabled = false
    /// Minutes since midnight — whole hours were too coarse for a 22:30 bedtime.
    @Published var quietStartMinute: Int = 22 * 60
    @Published var quietEndMinute: Int = 8 * 60
    @Published var launchAtLogin = false
    /// Whether launchd was actually left in the state `launchAtLogin` claims.
    /// `nil` until the toggle has been applied at least once this run.
    @Published private(set) var loginItemApplied: Bool?
    @Published var language: AppLanguage = .auto
    @Published var hooksStatus: HooksSupport.Status = .unknown
    /// Native `pulse-hook` launcher present — Attention bridge path, not Claude/Codex install.
    @Published private(set) var pulseHookLauncherReady = false
    @Published private(set) var didCopyAttentionRaise = false
    @Published var showAllAgents = false
    @Published private(set) var isRefreshing = false
    /// Transient "Copied" confirmation on the diagnostics button.
    @Published private(set) var didCopyDiagnostics = false
    /// The shape report walks the session stores, so the button says so.
    @Published private(set) var isCopyingShapeReport = false
    @Published private(set) var didCopyShapeReport = false
    /// Agents the user muted — no notifications, still shown in the tray.
    @Published var mutedAgents: Set<AgentID> = []
    @Published var hotkey: HotkeyChoice = .commandShiftP
    @Published var hotkeyEnabled = false
    /// Opt-in: Terminal/iTerm tab Focus via Apple Events (may prompt Automation).
    @Published var allowTerminalAutomation = false
    @Published var trayGrouping: TrayGrouping = .status
    @Published var playSoundOnWaiting = false
    /// Minutes of silence before a live row reads as stalled; 0 turns it off.
    @Published var stallMinutes = 20
    /// How long "Later" silences a wait.
    @Published var snoozeMinutes = 10
    /// False when the system refused the shortcut (another app owns it).
    @Published private(set) var hotkeyRegistered = true
    @Published var updateCheckEnabled = true
    /// Opt-in only: reading vendor Application Support/App Group data can
    /// trigger macOS's cross-app privacy prompt. The default scan remains
    /// useful through hooks, dot-directory sessions, and process evidence.
    @Published var allowAppData = false
    /// Protected app-data access is scoped to the agents the user actually
    /// wants richer details for. The all-agents switch remains available, but
    /// a single TCC decision must never silently widen the scan to every app.
    @Published var appDataAgents: Set<AgentID> = []
    @Published var updateStatus: UpdateCheck.Status = .idle
    @Published var updateDownloadStatus: UpdateCheck.DownloadStatus = .idle
    @Published private(set) var recoveredAfterCrash = false
    @Published private(set) var recoveryExitKind: LaunchRecovery.ExitKind = .clean
    /// Keep the unclean-exit banner through the first healthy scan so the user
    /// can actually see it; clear on the next healthy scan or explicit dismiss.
    private var recoveryNoticeSurvivedFirstHealthyScan = false
    private var launchRecovery: LaunchRecovery?
    /// SIGTERM → force-quit marker. Force Quit via SIGKILL still looks like a crash.
    private var terminationSignalSource: DispatchSourceSignal?
    @Published private(set) var installReport = InstallTruth.Report.empty
    @Published private(set) var hookSelfTestResult: HooksSupport.SelfTestResult = .idle
    /// Notification authorization — a denied prompt used to fail silently.
    @Published private(set) var notifyAuthorized: Bool?
    /// True when the latest harvest stopped before every adapter reported.
    /// Existing per-agent health is retained in that case; the banner exposes
    /// the scan gap without turning every unvisited adapter into an error.
    @Published private(set) var collectorScanIncomplete = false
    /// Waits that have already been resolved, newest first (P1-H).
    @Published private(set) var waitHistory: [ResolvedWait] = []
    /// Waits that ended while the tray was closed — "what did I miss?".
    @Published private(set) var missedWhileAway = 0
    /// Sessions that moved / new waits while the tray was closed (Look Continuity).
    @Published private(set) var lookMovedWhileAway = 0
    @Published private(set) var lookNewWaitsWhileAway = 0
    /// Localized Look Closure notice — named agents/sessions, not only counts (0.93).
    @Published private(set) var lookContinuityNotice = ""
    /// Ordered Look Closure events (new wait → ended wait → moved).
    @Published private(set) var lookContinuityItems: [LookDeltaItem] = []
    /// Respond (scene AR): inbound full permission requests matched to rows,
    /// and the rows whose verdict this session already wrote. State only —
    /// matching and actions live in StatusStore+Respond.swift, which is also
    /// the only writer (internal set because extensions live in another file).
    @Published var respondInboundByRowKey: [String: RespondSpool.InboundRequest] = [:]
    @Published var respondVerdictSentRowKeys: Set<String> = []
    /// Row keys marked “moved while away” until the notice is acknowledged.
    @Published private(set) var lookMovedRowKeys: Set<String> = []
    /// When the tray was last dismissed, for the missed-wait count.
    private var trayClosedAt: Date?
    /// Fingerprint of visible rows at last tray close — Look Continuity (0.92).
    private var trayCloseFingerprint: TrayLookFingerprint?

    /// One named Look Closure event (0.93).
    struct LookDeltaItem: Equatable, Identifiable {
        enum Kind: Equatable {
            case newWait
            case endedWait
            case moved
        }

        var id: String { "\(kindTag)|\(rowKey)|\(label)" }
        var kind: Kind
        var rowKey: String
        var label: String
        /// True when the live tray still has this rowKey (can Go-Look reveal).
        var revealable: Bool

        private var kindTag: String {
            switch kind {
            case .newWait: return "new"
            case .endedWait: return "ended"
            case .moved: return "moved"
            }
        }
    }

    /// Compact tray-close snapshot for "what moved since you left".
    struct TrayLookFingerprint: Equatable {
        struct RowSnap: Equatable {
            var rowKey: String
            var agentRaw: String
            var label: String
            var waiting: Bool
            var waitKind: String
            var phase: String
            var tool: String
            var task: String
            var harvestMs: Int64
            var activityChangedMs: Int64
            var changeTag: String
            var tokensIn: Int
            var tokensOut: Int
            var progressDone: Int
            /// Wait generation — same row can end one wait and start another.
            var waitSinceMs: Int64 = 0
        }

        var closedAt: Date
        var rows: [RowSnap]
    }
    /// Install-copy discovery is diagnostic-only. Keep it off the main thread
    /// and avoid re-running a process/filesystem scan on every tray open.
    private var installTruthRefreshInFlight = false
    private var installTruthRefreshedAt: Date?
    private var installTruthGeneration = 0

    /// A Waiting row that is no longer waiting — "did I miss something?".
    struct ResolvedWait: Identifiable, Equatable {
        var id: String { "\(rowKey)|\(Int(resolvedAt.timeIntervalSince1970))" }
        var rowKey: String
        var agent: AgentID
        var title: String
        var kind: String
        var project: String
        var resolvedAt: Date
        var waitedSeconds: Double
    }

    /// Resolved waits kept for the Settings history list.
    static let maxWaitHistory = 12

    private var timer: Timer?
    private var cachedAll: [AgentRow] = []
    private var lastGoodHarvest: [ActivityHarvest.Row] = []
    /// Result of the latest attempted adapter scan, including adapters that
    /// ran successfully but had no recent local session. This is deliberately
    /// separate from row evidence: zero rows is a useful result, not silence.
    private var collectorHealthByAgent: [AgentID: ActivityHarvest.CollectorHealth] = [:]
    /// Latest successful collector read by Agent, retained even after its
    /// session row ages out so Settings can distinguish "not running" from
    /// "collector has never produced evidence".
    private var lastSuccessfulReadByAgent: [AgentID: Int64] = [:]
    /// Per-Agent retry/backoff/circuit policy. A bad store must not consume the
    /// next scan budget for every other adapter.
    private var harvestSupervisor = HarvestSupervisor()
    /// Where the next native harvest should start.
    ///
    /// The collector walks its adapters in a fixed order, so before 0.98 a
    /// global budget cutoff always fell in the same place and the same tail
    /// adapters were reported `unscanned` on every refresh. The scan returns
    /// the first adapter it could not reach; the next one begins there.
    fileprivate var harvestScanCursor = 0
    /// Deterministic event ages for visual fixtures only.
    private var previewWaitingEventTimes: [AgentID: Int64]?
    /// Prevent a preview panel opening from immediately replacing its fixture
    /// with a live scan before the screenshot is taken.
    private var previewFixtureActive = false
    private let powerMonitor = PowerMonitor()
    /// Tray panel is on screen — worth probing faster while the user reads it.
    private var trayOpen = false
    /// Close instant to apply Look Continuity *after* the opening scan (0.96).
    private var lookContinuityPendingClosedAt: Date?
    /// Sample Waiting reveal waits until the row exists in `cachedAll`.
    private var pendingSampleRevealSession = ""
    private var activity: ProbeSchedule.Activity = .empty
    private var currentInterval: TimeInterval?
    /// Live-process fingerprint; a change forces a harvest even off-cadence.
    private var lastProcessSignature = ""
    private var ticksSinceHarvest = Int.max
    /// Last value actually pushed to launchd — avoids re-running launchctl
    /// (two synchronous subprocesses) on every settings write.
    private var appliedLaunchAtLogin: Bool?
    /// Rolling scan counters, so the energy claim can be checked, not believed.
    private var probeStats = ProbeStats()
    /// When the timer parked, for the parked-duration counter.
    private var parkedSince: Date?
    private var knownWaitingKeys: Set<String> = []
    /// First apply seeds waiting keys without firing edge notifications.
    private var waitingNotifySeeded = false
    /// Waiting edges observed while macOS notification authorization is still
    /// resolving. Keep one row per session so a delayed permission callback
    /// cannot make an approval disappear without either a banner or a tray
    /// prompt.
    private var pendingWaitingNotifications: [String: AgentRow] = [:]
    /// One interruption per short window keeps a burst of parallel approvals
    /// useful without turning Notification Center into a stream of duplicates.
    private static let waitingNotificationMinimumIntervalMs: Int64 = 3_000
    private var waitingDeliveryTask: Task<Void, Never>?
    /// Notification Center accepts requests asynchronously. Keep the event
    /// in-flight until its callback arrives so a fast follow-up scan cannot
    /// post a duplicate or mark a failed request as delivered.
    private var waitingDeliveryInFlight: Set<String> = []
    /// Keep the optional sound as one cue per delivery window, not one cue per
    /// session when a batch is accepted as separate Notification Center
    /// requests.
    private var waitingDeliverySounded = false
    /// Cross-launch Waiting/delivery state. This is deliberately separate from
    /// the agent-owned attention.tsv bridge so a restart cannot lose the only
    /// human-confirmation edge or emit it twice.
    private var attentionLedger = AttentionLedger.load()
    /// Soft-dismissed Cursor harvest pending until skill clears.
    private var dismissedPendingKeys: Set<String> = []
    /// Row key → when its "remind me later" runs out.
    private var snoozedUntil: [String: Date] = [:]
    private let attentionWatcher = AttentionWatcher()
    private let scanQueue = DispatchQueue(label: "com.pulse.scan", qos: .userInitiated)
    private var scanTicket: UInt64 = 0
    private var lastAppliedTicket: UInt64 = 0
    private var scanInFlight = false
    private var pendingRefreshReason: String?
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var lang: ResolvedLanguage { language.resolved }

    var protectedAppDataAgents: [AgentID] {
        // `cursorAgent` is merged into Cursor in the tray and shares the same
        // local store. Showing both aliases as separate switches makes a
        // single permission look like two independent promises. Keep the
        // policy aliases internal while exposing one switch per user-facing
        // data source.
        AgentID.allCases.filter { $0.requiresAppDataOptIn && $0 != .cursorAgent }
    }

    /// The Python collector groups a few vendor identities behind one local
    /// store. Selecting either public identity must unlock that store, but the
    /// policy never widens to unrelated agents.
    private var harvestAppDataAgents: Set<AgentID> {
        var result = appDataAgents
        if result.contains(.cursor) || result.contains(.cursorAgent) {
            result.insert(.cursor)
            result.insert(.cursorAgent)
        }
        if result.contains(.cascade) || result.contains(.windsurf) {
            result.insert(.cascade)
            result.insert(.windsurf)
        }
        return result
    }

    func isAppDataAllowed(for agent: AgentID) -> Bool {
        allowAppData || harvestAppDataAgents.contains(agent)
    }

    func appDataScopeDescription(for agent: AgentID) -> String {
        switch agent {
        case .cursor, .cursorAgent: return "Cursor / VS Code workspace and composer stores"
        case .warpAgent: return "Warp Agent local conversations and task database"
        case .cascade, .windsurf: return "Windsurf / Cascade local session cache"
        case .cline, .roo, .kilo: return "VS Code extension session store"
        default: return "\(agent.displayName) local Application Support session store"
        }
    }

    private var appDataScanDescription: String {
        if allowAppData { return "all" }
        let scoped = appDataAgents.map(\.rawValue).sorted()
        return scoped.isEmpty ? "disabled" : "scoped:\(scoped.joined(separator: ","))"
    }

    func setAppDataAccess(for agent: AgentID, enabled: Bool) {
        if enabled {
            appDataAgents.insert(agent)
        } else {
            appDataAgents.remove(agent)
        }
        // Persist without a full roster refresh — only the affected Agent needs
        // a new harvest pass. Blanket saveSettings→refresh was waking every
        // adapter after a single privacy toggle.
        persistSettingsOnly()
        refresh(reason: "appData:\(agent.rawValue)", agentFilter: [agent])
    }

    func setAllAppDataAccess(_ enabled: Bool) {
        allowAppData = enabled
        if enabled {
            appDataAgents.formUnion(protectedAppDataAgents)
        } else {
            appDataAgents.removeAll()
        }
        persistSettingsOnly()
        refresh(reason: "appData:all", agentFilter: Set(protectedAppDataAgents))
    }

    func tr(_ key: L10n.Key) -> String { L10n.t(key, lang) }

    /// User-facing last action for the detail inspector. The raw identifier is
    /// still available under Diagnostics; the primary fact uses the same
    /// phase vocabulary as the tray so `exec`, `apply_patch`, and vendor
    /// aliases do not appear as unexplained implementation jargon.
    func detailLastAction(_ row: AgentRow) -> String {
        guard !row.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return tr(.noActivityYet)
        }
        return readableAction(row.tool)
    }

    /// First-class workflow phase for the inspector. If an adapter emitted a
    /// vendor-specific phase we still show a safe, human-readable value rather
    /// than leaving the most important operational fact blank.
    func detailPhase(_ row: AgentRow) -> String {
        if let phase = readablePhase(row.phase, waiting: row.waiting) { return phase }
        let raw = row.phase.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw.replacingOccurrences(of: "_", with: " ").capitalized }
        if row.waiting {
            let kind = row.waitKind.trimmingCharacters(in: .whitespacesAndNewlines)
            if !kind.isEmpty { return localizedWaitKind(kind) }
            return tr(.needsYou)
        }
        if row.isStalled { return tr(.stalled) }
        if row.liveProcess { return tr(.phaseWorking) }
        if !row.outcome.isEmpty { return row.outcome }
        return "—"
    }

    /// Claude/Codex live but hooks not wired — tray nudge only.
    var needsHooksNudge: Bool {
        guard hooksStatus == .missing || hooksStatus == .unknown else { return false }
        return cachedAll.contains {
            $0.liveProcess && ($0.agent == .claude || $0.agent == .codex)
        }
    }

    /// Live agent with no Waiting path (not hooks-dependent) — one-line honesty, not a HUD.
    var needsWaitingSignalNudge: Bool {
        if needsHooksNudge { return false }
        return firstLiveWaitingNoneAgent != nil
    }

    /// First live Waiting-none agent still without an active wait — Reach funnel focus target.
    var firstLiveWaitingNoneAgent: AgentID? {
        cachedAll.first {
            $0.liveProcess && $0.agent.waitingSource == .none && !$0.waiting
        }?.agent
    }

    /// Packaged bundle version disagrees with the compiled semver — usually a
    /// stale `Pulse.app` next to a fresh build. Worth saying out loud.
    var isVersionMismatch: Bool {
        // XCTest and deterministic tray fixtures run from a host bundle whose
        // version is unrelated to Pulse. Do not let that harness detail hide
        // the fixture's observable Waiting signal or affect its screenshots;
        // real packaged launches still keep stale-bundle diagnosis first.
        if previewFixtureActive { return false }
        if case .mismatch = PulseVersion.channel { return true }
        return false
    }

    /// Everything a bug report needs, in one paste.
    func diagnosticsText() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines: [String] = [
            PulseVersion.fingerprint,
            "channel: \(isVersionMismatch ? "mismatch" : PulseVersion.distributionChannel)",
            "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "lang: \(language.rawValue) · autoProbe: \(autoProbe)",
            "appDataScan: \(appDataScanDescription)",
            "harvest: native (no external runtime)",
            "hooks: \(hooksStatus.label(lang: lang))",
            "glance: \(snapshot.glance) · rows: \(snapshot.rows.count)/\(snapshot.totalCount)",
            "cadence: \(probeIntervalDescription) · \(probeStats.summary(now: Date()))",
        ]
        let collector = supportHealth
        let collectorCounts = Dictionary(grouping: collector, by: \.collectorState).mapValues(\.count)
        lines.append("collectorScan: \(collectorScanIncomplete ? "partial" : "complete")")
        lines.append(
            "collectors: observed=\(collectorCounts[.observed] ?? 0) "
                + "sourceAbsent=\(collectorCounts[.sourceAbsent] ?? 0) "
                + "noSessions=\((collectorCounts[.noSessions] ?? 0) + (collectorCounts[.noRecentData] ?? 0)) "
                + "permission=\(collectorCounts[.permissionDenied] ?? 0) "
                + "schema=\(collectorCounts[.schemaMismatch] ?? 0) "
                + "failed=\(collectorCounts[.failed] ?? 0) "
                + "unscanned=\(collectorCounts[.unscanned] ?? 0)"
            )
        let notificationAuthorization = notifyAuthorized.map { String($0) } ?? "unknown"
        lines.append(
            "notifications: authorization=\(notificationAuthorization) "
                + "notifyWaiting=\(notifyOnWaiting) pending=\(pendingWaitingNotifications.count) "
                + "queued=\(attentionLedger.queuedKeys.count)"
        )
        lines.append("harvestSupervisor: \(harvestSupervisor.summary(nowMs: Int64(Date().timeIntervalSince1970 * 1000)))")
        lines.append(
            "attentionLedger: active=\(attentionLedger.activeKeys.count) "
                + "events=\(attentionLedger.events.count) baseline=\(attentionLedger.baselineEstablished)"
        )
        let failedCollectors = collector.filter { $0.collectorState.isIssue }
        if !failedCollectors.isEmpty {
            lines.append(
                "collectorErrors: " + failedCollectors.map {
                    "\($0.agent.rawValue)=\($0.collectorErrorKind.isEmpty ? "unknown" : $0.collectorErrorKind)"
                }.joined(separator: ",")
            )
        }
        if let err = snapshot.probeError { lines.append("probeError: \(err)") }
        lines.append("runningBundle: \(installReport.runningURL.path)")
        lines.append("installCopies: \(installReport.copies.count)")
        for row in cachedAll.prefix(8) {
            lines.append(
                "  \(row.agent.rawValue) waiting=\(row.waiting) live=\(row.liveProcess) "
                    + "signal=\(row.waitSignal?.rawValue ?? "-") sub=\(row.subRunning)/\(row.subTotal)"
            )
        }
        return lines.joined(separator: "\n")
    }

    func copyDiagnostics() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(diagnosticsText(), forType: .string)
        didCopyDiagnostics = true
        DebugLog.write("diagnostics copied")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            self?.didCopyDiagnostics = false
        }
    }

    /// A previewable, deliberately path-free support report. It contains
    /// adapter health and capability booleans, never prompts, session IDs,
    /// workspace paths, tool payloads, or command lines.
    func safeSupportReport() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let authLabel: String = {
            switch notifyAuthorized {
            case .some(true): return "authorized"
            case .some(false): return "denied"
            case .none: return "unknown"
            }
        }()
        let grantLabel: String = {
            switch appDataGrantMode {
            case .all: return "all"
            case .scoped(let n): return "scoped:\(n)"
            case .none: return "none"
            }
        }()
        let timeoutAgents = collectorHealthByAgent.values
            .filter { $0.errorKind == "native_timeout" }
            .map(\.id.rawValue)
            .sorted()
            .joined(separator: ",")
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let healthItems = supportHealth
        let factPresent = healthItems.reduce(0) { $0 + $1.usefulFactCount }
        let factPossible = healthItems.reduce(0) { $0 + $1.usefulFactTotal }
        let limitedAgents = healthItems.filter { $0.disposition == .limited }.count
        let failures = harvestSupervisor.failureTimeline(nowMs: nowMs)
        var lines = [
            "Pulse safe support report",
            PulseVersion.fingerprint,
            "channel: \(PulseVersion.distributionChannel)",
            "notarized: \(PulseVersion.isNotarized)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Agents: \(healthItems.count)",
            "waitingNone: \(Self.attentionSampleAgents.map(\.rawValue).joined(separator: ","))",
            "gatekeeperReady: \(PulseVersion.isGatekeeperReady)",
            "appDataScan: \(appDataScanDescription)",
            "appDataGrant: \(grantLabel)",
            "notifications: authorization=\(authLabel) notifyWaiting=\(notifyOnWaiting) pending=\(pendingWaitingNotifications.count)",
            "probeCadence: \(probeIntervalDescription)",
            "launchAtLogin: \(launchAtLogin) applied=\(loginItemApplied.map(String.init) ?? "untouched")",
            "harvest: native (no external runtime)",
            "remoteFleet: \(remoteFleetSummary)",
            "sessionDigests: \(HarvestDigests.summary)",
            "collectorScan: \(collectorScanIncomplete ? "partial" : "complete")",
            "timeoutAgents: \(timeoutAgents.isEmpty ? "-" : timeoutAgents)",
            "factCoverage: present=\(factPresent) possible=\(factPossible) limitedAgents=\(limitedAgents)",
            "attentionLedger: active=\(attentionLedger.activeKeys.count) events=\(attentionLedger.events.count) baseline=\(attentionLedger.baselineEstablished)",
            "harvestSupervisor: \(harvestSupervisor.summary(nowMs: nowMs))",
        ]
        if failures.isEmpty {
            lines.append("failureTimeline: -")
        } else {
            lines.append("failureTimeline:")
            for entry in failures {
                let ageSec = max(0, (nowMs - entry.atMs) / 1000)
                lines.append(
                    "  \(entry.agent.rawValue)=\(entry.error) ageSec=\(ageSec)"
                )
            }
        }
        for item in healthItems {
            let waiting = item.agent.waitingSource == .none
                ? "n/a"
                : String(item.waitingSignalReady)
            let health = collectorHealthByAgent[item.agent]
            let err = health?.errorKind.isEmpty == false ? health!.errorKind : "-"
            let dur = health?.durationMs ?? 0
            let harvest = item.agent.harvestSource == .bestEffortCache ? "cache" : "session"
            lines.append(
                "\(item.agent.rawValue): \(item.collectorState.rawValue) "
                    + "disposition=\(item.disposition) evidence=\(item.evidence?.rawValue ?? "none") "
                    + "harvest=\(harvest) "
                    + "goal=\(item.hasGoal) workspace=\(item.hasWorkspace) "
                    + "activity=\(item.hasActivity) progress=\(item.hasProgress) "
                    + "waiting=\(waiting) "
                    + "score=\(item.usefulFactCount)/\(item.usefulFactTotal) "
                    + "privacyLimited=\(item.privacyLimited) "
                    + "error=\(err) durationMs=\(dur) "
                    // How the adapter reached that result. Without this line an
                    // `observed` adapter with a blank hero looked identical to a
                    // healthy one, and finding out which layer lost the title
                    // cost a release.
                    + "explain=[\(health?.explain.summary ?? "-")]"
            )
        }
        return ContentSanitizer.redact(lines.joined(separator: "\n"))
    }

    /// Remote sources, named. A fleet you cannot see is the problem 1.0 set
    /// out to fix; a fleet Pulse silently failed to read would be the same
    /// problem wearing a different coat.
    var remoteFleetSummary: String {
        let rows = cachedAll.filter(\.isRemote)
        let hosts = Set(rows.map(\.host)).sorted().joined(separator: ",")
        let lost = rows.filter(\.lostContact).count
        let files = AttentionIO.readInbox().count
        return "inbox=\(files) hosts=\(hosts.isEmpty ? "-" : hosts) rows=\(rows.count) lost=\(lost)"
    }

    func copySafeSupportReport() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(safeSupportReport(), forType: .string)
        didCopyDiagnostics = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            self?.didCopyDiagnostics = false
        }
    }

    /// The vendor-shape report, on the clipboard, from a button.
    ///
    /// `--harvest-shape` has been the one diagnostic that only a terminal could
    /// produce, and it is exactly the evidence a parsing fix needs: which keys
    /// an agent actually writes, rather than which keys someone inferred. Two
    /// releases of parsing work have stayed deliberately empty waiting for it.
    /// It walks the session stores, so it runs off the main thread and only
    /// when asked.
    @MainActor
    func copyHarvestShapeReport() {
        guard !isCopyingShapeReport else { return }
        isCopyingShapeReport = true
        let allowAll = allowAppData
        let agents = harvestAppDataAgents
        DispatchQueue.global(qos: .userInitiated).async {
            let safe = ContentSanitizer.redact(
                NativeActivityHarvest.shapeReport(
                    allowAppData: allowAll,
                    appDataAgents: agents
                )
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(safe, forType: .string)
                self.isCopyingShapeReport = false
                self.didCopyShapeReport = true
                DebugLog.write("harvest shape report copied bytes=\(safe.utf8.count)")
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                self.didCopyShapeReport = false
            }
        }
    }

    @MainActor
    func exportSafeSupportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pulse-support-\(Int(Date().timeIntervalSince1970)).txt"
        panel.canCreateDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let data = ContentSanitizer.redact(self.safeSupportReport()).data(using: .utf8) ?? Data()
                try data.write(to: url, options: .atomic)
                DebugLog.write("safe support report exported")
            } catch {
                DebugLog.write("safe support report export failed \(error.localizedDescription)")
            }
        }
    }

    var supportHealth: [AgentSupportHealth] {
        let waitingEvents = previewWaitingEventTimes ?? AttentionIO.latestEventTimes()
        // Cursor Agent is a transport identity, not a second product. Its
        // process/session rows are normalized into Cursor by SnapshotBuilder;
        // listing it again here made the coverage screen claim two adapters
        // and split the same health result into duplicate entries.
        let displayAgents = AgentID.priority.filter { $0 != .cursorAgent }
        return displayAgents.map { agent in
            let rows = cachedAll.filter {
                $0.agent == agent || (agent == .cursor && $0.agent == .cursorAgent)
            }
            let health = collectorHealthByAgent[agent]
                ?? (agent == .cursor ? collectorHealthByAgent[.cursorAgent] : nil)
            let strongest: ObservationSource? = {
                if rows.contains(where: { $0.observationSource == .session }) { return .session }
                if rows.contains(where: { $0.observationSource == .cache }) { return .cache }
                if rows.contains(where: { $0.observationSource == .process }) { return .process }
                return nil
            }()
            return AgentSupportHealth(
                agent: agent,
                collectorState: health?.state ?? .unscanned,
                collectorDurationMs: health?.durationMs ?? 0,
                collectorRows: health?.rowCount ?? 0,
                sourcePresent: health?.sourcePresent ?? false,
                collectorErrorKind: health?.errorKind ?? "",
                processDetected: rows.contains(where: \.liveProcess),
                processEvidence: rows.compactMap(\.processEvidence).first,
                processStartedMs: rows
                    .filter(\.liveProcess)
                    .map(\.processStartedMs)
                    .filter { $0 > 0 }
                    .min() ?? 0,
                processCount: rows.map(\.processCount).max() ?? 0,
                evidence: strongest,
                // This clock is when Pulse successfully read the adapter, not
                // when the vendor session last changed. Reusing row.harvestMs
                // here made a healthy idle collector look months stale.
                lastSuccessfulReadMs: lastSuccessfulReadByAgent[agent] ?? 0,
                lastWaitingSignalMs: waitingEvents[agent] ?? 0,
                hasGoal: rows.contains { $0.usefulTask != nil },
                hasWorkspace: rows.contains { !$0.displayPath.isEmpty },
                // Process age is evidence that an executable exists, not an
                // Agent activity feed. Keep the activity fact reserved for a
                // session/cache timestamp so process-only rows cannot claim
                // 4/4 core facts while simultaneously admitting the feed is
                // unavailable.
                hasActivity: rows.contains {
                    $0.harvestMs > 0 && $0.observationSource != .process
                },
                hasProgress: rows.contains {
                    !$0.phase.isEmpty || !$0.tool.isEmpty || !$0.outcome.isEmpty
                        || $0.progressDone > 0 || $0.progressTotal > 0
                        || $0.tokensIn > 0 || $0.tokensOut > 0
                        || $0.subTotal > 0 || $0.errors > 0 || $0.files > 0
                        || $0.contextPercent > 0 || !$0.model.isEmpty || !$0.mode.isEmpty
                },
                waitingSignalReady: waitingSignalReady(for: agent),
                privacyLimited: agent.requiresAppDataOptIn && !isAppDataAllowed(for: agent),
                hasActionSignal: rows.contains { !$0.tool.isEmpty },
                hasModelSignal: rows.contains { !$0.model.isEmpty },
                hasResourceSignal: rows.contains {
                    $0.tokensIn > 0 || $0.tokensOut > 0 || $0.records > 0
                        || $0.errors > 0 || $0.files > 0 || $0.contextPercent > 0
                },
                focusTier: bestSupportFocus(in: rows),
                focusTTYNeedsOptIn: supportTTYNeedsOptIn(in: rows),
                activityAgeSeconds: {
                    let clocks = rows.compactMap { row -> Int64? in
                        let ms = max(row.harvestMs, row.activityChangedMs)
                        return ms > 0 ? ms : nil
                    }
                    guard let newest = clocks.max() else { return 0 }
                    return max(0, Date().timeIntervalSince1970 - Double(newest) / 1000.0)
                }(),
                hasStalledLive: rows.contains { $0.liveProcess && $0.isStalled }
            )
        }
    }

    /// Prefer Warp → host workspace → host app → TTY — honesty order.
    private func bestSupportFocus(in rows: [AgentRow]) -> FocusTier? {
        let tiers = rows.compactMap(\.focusTier)
        if tiers.contains(where: { if case .warp = $0 { return true }; return false }) {
            return .warp
        }
        if let host = tiers.compactMap({ tier -> HostAppKind? in
            if case .hostWorkspace(let kind) = tier { return kind }
            return nil
        }).first {
            return .hostWorkspace(host)
        }
        if let host = tiers.compactMap({ tier -> HostAppKind? in
            if case .hostApp(let kind) = tier { return kind }
            return nil
        }).first {
            return .hostApp(host)
        }
        if tiers.contains(where: { if case .tty = $0 { return true }; return false }) {
            return .tty
        }
        return nil
    }

    /// Real TTY on a row that still has no advertised focus (Automation off).
    private func supportTTYNeedsOptIn(in rows: [AgentRow]) -> Bool {
        guard !allowTerminalAutomation else { return false }
        return rows.contains { row in
            guard row.focusTier == nil, !row.viaWarp, row.hostApp == nil else { return false }
            var t = row.tty.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("/dev/") { t = String(t.dropFirst(5)) }
            return !t.isEmpty && t != "?" && t != "??" && t != "-"
        }
    }

    /// Full session inventory for the tray search surface. The normal glance
    /// uses `snapshot.rows`; a query must search the bounded 500-row index so a
    /// session hidden behind the twelve-row viewport is still discoverable.
    var allRowsForDisplay: [AgentRow] { cachedAll }

    /// Resolve a row for the detail inspector from the full index, not glance.
    func rowForDetail(rowKey: String) -> AgentRow? {
        cachedAll.first(where: { $0.rowKey == rowKey })
            ?? snapshot.rows.first(where: { $0.rowKey == rowKey })
    }

    /// Localized Limited-data / gap explanation — never a bare "Process only".
    func observationQualitySummary(_ row: AgentRow) -> String {
        if !row.quality.isLimited, row.observationSource == .session {
            return tr(.sessionEvidence)
        }
        guard let gap = row.quality.missing.first else {
            switch row.observationSource {
            case .session: return tr(.sessionEvidence)
            case .cache: return tr(.cacheEvidence)
            case .process:
                return "\(tr(.limitedData)) · \(tr(.qualityNextOpenAgent))"
            case .remote:
                return tr(.remoteEvidence)
            }
        }
        return "\(observationGapReason(gap)) · \(observationGapNextStep(gap))"
    }

    func observationGapReason(_ gap: ObservationGap) -> String {
        switch gap.reason {
        case "privacy_limited": return tr(.supportCollectorPrivacyLimitedDetail)
        case "process_only": return tr(.qualityReasonProcessOnly)
        case "cache_conditional": return tr(.qualityReasonCache)
        case "cache_thin": return tr(.qualityReasonCacheThin)
        case "waiting_no_detail": return tr(.qualityReasonWaitingNoDetail)
        case "waiting_unsupported": return tr(.supportWaitingNoneDetail)
        case "scan_timeout": return tr(.qualityReasonScanTimeout)
        case "remote_event_only": return tr(.remoteEvidence)
        default: return tr(.qualityReasonNotEmitted)
        }
    }

    func observationGapNextStep(_ gap: ObservationGap) -> String {
        switch gap.nextStep {
        case "enable_app_data": return tr(.supportEnableData)
        case "wait_for_vendor_cache": return tr(.qualityNextWaitCache)
        case "use_attention_bridge": return tr(.qualityNextAttentionBridge)
        case "retry_scan": return tr(.qualityNextRetryScan)
        case "open_agent_for_session": return tr(.qualityNextOpenAgent)
        case "wait_for_remote_host": return tr(.remoteNoFocus)
        default: return tr(.qualityNextOpenAgent)
        }
    }

    /// Details lists actionable gaps first so truncation cannot hide the fix.
    func prioritizedObservationGaps(_ gaps: [ObservationGap]) -> [ObservationGap] {
        let actionable: Set<String> = ["use_attention_bridge", "enable_app_data"]
        return gaps.enumerated().sorted { left, right in
            let leftAct = actionable.contains(left.element.nextStep)
            let rightAct = actionable.contains(right.element.nextStep)
            if leftAct != rightAct { return leftAct && !rightAct }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// How deep App Data is currently granted — drives Support Health copy so
    /// a scoped Cursor grant is not described as "scan is off".
    enum AppDataGrantMode: Equatable {
        case all
        case scoped(Int)
        case none
    }

    var appDataGrantMode: AppDataGrantMode {
        if allowAppData { return .all }
        let count = appDataAgents.filter { $0 != .cursorAgent }.count
        return count == 0 ? .none : .scoped(count)
    }

    var privacyLimitedAgents: [AgentSupportHealth] {
        supportHealth.filter(\.privacyLimited)
    }

    var privacyLimitedCount: Int { privacyLimitedAgents.count }

    /// Banner when some protected agents remain privacy-limited.
    var privacyBannerText: String? {
        guard privacyLimitedCount > 0 else { return nil }
        switch appDataGrantMode {
        case .all:
            return nil
        case .none:
            return tr(.supportCollectorPrivacyLimitedDetail)
        case .scoped(let granted):
            return String(
                format: tr(.supportCollectorPrivacyLimitedScoped),
                granted,
                privacyLimitedCount
            )
        }
    }

    var firstPrivacyLimitedAgent: AgentID? {
        privacyLimitedAgents.first?.agent
    }

    /// Incomplete-scan banner: timeout-with-rows is not the same claim as a
    /// blank failure.
    var scanIncompleteBannerText: String? {
        guard collectorScanIncomplete else { return nil }
        let timedOutWithRows = collectorHealthByAgent.values.contains {
            $0.errorKind == "native_timeout" && $0.rowCount > 0
        }
        if timedOutWithRows {
            return tr(.supportScanIncompleteTimeout)
        }
        return tr(.supportScanIncomplete)
    }

    /// Short tray notice sharing the Support incomplete vocabulary.
    var trayScanIncompleteNotice: String? {
        scanIncompleteBannerText
    }

    func confidenceLabel(_ confidence: ObservationConfidence) -> String {
        switch confidence {
        case .high: return tr(.qualityConfidenceHigh)
        case .medium: return tr(.qualityConfidenceMedium)
        case .low: return tr(.qualityConfidenceLow)
        }
    }

    func factKeyLabel(_ key: ObservationFactKey) -> String {
        switch key {
        case .task: return tr(.supportGoal)
        case .workspace: return tr(.supportWorkspace)
        case .action: return tr(.supportAction)
        case .phase: return tr(.detailPhase)
        case .model: return tr(.supportModel)
        case .progress: return tr(.supportProgress)
        case .error: return tr(.detailErrors)
        case .waitingReason: return tr(.supportMissingWaiting)
        case .evidence: return tr(.supportEvidence)
        case .freshness: return tr(.supportLastRead)
        }
    }

    func attentionEvent(for rowKey: String) -> AttentionLedger.Event? {
        attentionLedger.events.last(where: { $0.rowKey == rowKey && $0.isActive })
            ?? attentionLedger.events.last(where: { $0.rowKey == rowKey })
    }

    private func waitingSignalReady(for agent: AgentID) -> Bool {
        switch agent.waitingSource {
        case .hooks:
            if hooksStatus.isInstalled(for: agent) { return true }
            // Codex also has a harvest-pending Waiting path (README matrix).
            if agent == .codex {
                let state = collectorHealthByAgent[agent]?.state ?? .unscanned
                return state == .observed || state == .noRecentData
            }
            return false
        case .harvestPending:
            let state = collectorHealthByAgent[agent]?.state
                ?? (agent == .cursor ? collectorHealthByAgent[.cursorAgent]?.state : nil)
                ?? .unscanned
            // A source that exists but yielded no usable session cannot yet
            // prove a pending signal. Counting `.noSessions` as ready made a
            // process-only Amp row read “1/5 useful signals” despite having no
            // activity feed or actionable Waiting route.
            return state == .observed || state == .noRecentData
        case .none:
            return false
        }
    }

    func supportEvidenceLabel(_ health: AgentSupportHealth) -> String {
        // A bounded timeout that already returned rows is a partial read, not
        // an empty adapter failure. Keep the error detail in the inspector,
        // but classify the row as limited so useful evidence remains primary.
        if health.collectorState == .failed, health.collectorRows > 0 {
            return tr(.supportLimited)
        }
        if health.collectorState == .failed { return tr(.supportCollectorFailed) }
        if health.collectorState == .unscanned { return tr(.supportCollectorUnscanned) }
        if health.collectorState == .permissionDenied { return tr(.supportCollectorPermission) }
        if health.collectorState == .schemaMismatch { return tr(.supportCollectorSchema) }
        if health.privacyLimited, !health.isObserved {
            return tr(.supportCollectorPrivacyLimited)
        }
        if health.collectorState == .sourceAbsent, !health.isObserved {
            return tr(.supportCollectorSourceAbsent)
        }
        if [.noRecentData, .noSessions].contains(health.collectorState), !health.isObserved {
            return tr(.supportCollectorNoSessions)
        }
        guard health.isObserved else { return tr(.supportNotDetected) }
        switch health.evidence {
        case .session: return tr(.supportStructured)
        case .cache: return tr(.supportCache)
        case .process: return tr(.supportProcess)
        case .remote: return tr(.remoteEvidence)
        case .none: return tr(.supportDetected)
        }
    }

    func supportHealthDetail(_ health: AgentSupportHealth) -> String {
        [
            supportAdapterDetail(health),
            supportCoverageDetail(health),
            supportTimelineDetail(health),
            supportMissingDetail(health),
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    func supportAdapterDetail(_ health: AgentSupportHealth) -> String {
        var facts: [String] = []
        if health.agent == .cursor {
            facts.append(tr(.supportSharedCursor))
        }
        switch health.collectorState {
        case .observed:
            facts.append(String(
                format: tr(.supportCollectorObserved),
                health.collectorRows,
                health.collectorDurationMs
            ))
        case .noRecentData, .noSessions:
            facts.append(String(
                format: tr(.supportCollectorNoSessionsDetail),
                health.collectorDurationMs
            ))
            if health.privacyLimited {
                facts.append(tr(.supportCollectorPrivacyLimitedDetail))
            }
        case .sourceAbsent:
            facts.append(
                health.privacyLimited
                    ? tr(.supportCollectorPrivacyLimitedDetail)
                    : tr(.supportCollectorSourceAbsentDetail)
            )
        case .permissionDenied:
            facts.append(tr(.supportCollectorPermissionDetail))
        case .schemaMismatch:
            facts.append(tr(.supportCollectorSchemaDetail))
        case .failed:
            let kind = health.collectorErrorKind.isEmpty ? tr(.supportCollectorFailed) : health.collectorErrorKind
            facts.append(String(format: tr(.supportCollectorFailedDetail), kind))
        case .unscanned:
            facts.append(tr(.supportCollectorUnscannedDetail))
        }
        return facts.joined(separator: " · ")
    }

    func supportCoverageDetail(_ health: AgentSupportHealth) -> String {
        guard health.isObserved else { return "" }
        var facts: [String] = []
        if health.isObserved {
            if health.hasGoal { facts.append(tr(.supportGoal)) }
            if health.hasWorkspace { facts.append(tr(.supportWorkspace)) }
            if health.hasActivity { facts.append(tr(.supportActivity)) }
            if health.hasProgress { facts.append(tr(.supportProgress)) }
            facts.append(String(
                format: tr(.supportFactCoverage),
                health.observedFactCount,
                health.usefulFactTotal
            ))
        }
        return facts.joined(separator: " · ")
    }

    /// The score pills answer “how much can Pulse observe?”; this answers the
    /// next question, “what did it actually observe?” Keeping one compact,
    /// representative session per adapter makes the 31-agent matrix useful
    /// without turning it into a transcript or exposing raw session IDs.
    func supportObservedDetail(_ health: AgentSupportHealth) -> String {
        // Cursor Agent is normalized into Cursor for the user-facing support
        // row. Keep the evidence lookup normalized too; otherwise a Cursor
        // Agent-only session can score correctly above and still render as
        // "no usable session signals" below it.
        let candidates = cachedAll.filter {
            $0.agent == health.agent || (health.agent == .cursor && $0.agent == .cursorAgent)
        }
        guard let row = candidates.max(by: { lhs, rhs in
            let left = (
                lhs.waiting ? 4 : 0,
                lhs.liveProcess ? 2 : 0,
                lhs.harvestMs
            )
            let right = (
                rhs.waiting ? 4 : 0,
                rhs.liveProcess ? 2 : 0,
                rhs.harvestMs
            )
            return left < right
        }) else { return "" }

        var facts: [String] = []
        func nonEmpty(_ raw: String) -> String? {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if let task = row.usefulTask { facts.append(task) }
        if !row.displayPath.isEmpty { facts.append(row.displayPath) }
        if let phase = readablePhase(row.phase, waiting: row.waiting) { facts.append(phase) }
        if let tool = nonEmpty(row.tool) {
            let action = readableAction(tool)
            // Support diagnostics have more room than the tray's default row.
            // Keep generic and previously unknown tools visible as a safe,
            // human-readable last action instead of dropping the only
            // capability signal an adapter emitted. Avoid saying "Testing"
            // twice when the structured phase already supplied that fact.
            if !action.isEmpty,
               !facts.contains(where: { $0.caseInsensitiveCompare(action) == .orderedSame }) {
                facts.append(String(format: tr(.lastAction), action))
            }
        }
        if let model = nonEmpty(row.model) {
            facts.append(String(format: tr(.modelFact), readableModel(model)))
        }
        if let mode = nonEmpty(readableMode(row.mode)) { facts.append(mode) }
        if row.progressTotal > 0 {
            facts.append(String(format: tr(.progressFact), row.progressDone, row.progressTotal))
        } else if row.progressDone > 0 {
            facts.append(String(format: tr(.turnsFact), row.progressDone))
        }
        if row.errors > 0 {
            facts.append(row.errors == 1 ? tr(.errorFactOne) : String(format: tr(.errorsFact), row.errors))
        }
        if row.files > 0 { facts.append(String(format: tr(.filesFact), row.files)) }
        if row.contextPercent > 0 { facts.append(String(format: tr(.contextFact), row.contextPercent)) }
        let input = AgentRow.compactToken(row.tokensIn)
        let output = AgentRow.compactToken(row.tokensOut)
        if !input.isEmpty || !output.isEmpty {
            facts.append(String(format: tr(.reportedTokens), input.isEmpty ? "0" : input, output.isEmpty ? "0" : output))
        }
        // Record count is a collector diagnostic, not execution progress. It
        // belongs in Adapter diagnostics; letting it occupy the observed-fact
        // line made a session with only a transcript look more informative than
        // one with a real action, outcome, or token signal.
        guard !facts.isEmpty else { return "" }
        let clipped = facts.prefix(4).joined(separator: " · ")
        return String(format: tr(.supportObservedSignals), clipped)
    }

    func supportTimelineDetail(_ health: AgentSupportHealth) -> String {
        var facts: [String] = []
        if health.processDetected {
            let evidence = health.processEvidence == .pathSignature
                ? tr(.supportDetectedPath)
                : tr(.supportDetectedExecutable)
            facts.append(evidence)
            if health.processStartedMs > 0 {
                let seconds = max(
                    0,
                    Date().timeIntervalSince1970 - Double(health.processStartedMs) / 1000.0
                )
                facts.append(String(
                    format: tr(.processAge),
                    DurationFormat.label(seconds: seconds, lang: lang)
                ))
            }
            if health.processCount > 1 {
                facts.append(String(format: tr(.processCount), health.processCount))
            }
        }
        facts.append(supportWaitingLabel(health.agent))
        if health.hasStalledLive {
            if health.activityAgeSeconds > 0 {
                facts.append(String(
                    format: tr(.stalledFor),
                    DurationFormat.label(seconds: health.activityAgeSeconds, lang: lang)
                ))
            } else {
                facts.append(tr(.stalled))
            }
        } else if health.hasActivity, health.activityAgeSeconds > 0 {
            facts.append(String(
                format: tr(.agoFormat),
                DurationFormat.label(seconds: health.activityAgeSeconds, lang: lang)
            ))
        } else if health.processDetected, !health.hasActivity {
            facts.append(tr(.noActivityYet))
        }
        if health.lastWaitingSignalMs > 0 {
            let seconds = max(
                0,
                Date().timeIntervalSince1970 - Double(health.lastWaitingSignalMs) / 1000.0
            )
            facts.append(String(
                format: tr(.supportLastSignal),
                DurationFormat.label(seconds: seconds, lang: lang)
            ))
        }
        if health.lastSuccessfulReadMs > 0 {
            let seconds = max(
                0,
                Date().timeIntervalSince1970 - Double(health.lastSuccessfulReadMs) / 1000.0
            )
            facts.append(String(
                format: tr(.supportLastRead),
                DurationFormat.label(seconds: seconds, lang: lang)
            ))
        }
        return facts.joined(separator: " · ")
    }

    func supportMissingDetail(_ health: AgentSupportHealth) -> String? {
        let missing = health.missingCapabilities.map { capability -> String in
            switch capability {
            case .notDetected: return tr(.supportNotDetected)
            case .activityFeed: return tr(.supportMissingFeed)
            case .goal: return tr(.supportMissingGoal)
            case .workspace: return tr(.supportMissingWorkspace)
            case .waitingSignal: return tr(.supportMissingWaiting)
            }
        }
        if health.isObserved, !missing.isEmpty {
            return String(format: tr(.supportMissing), missing.joined(separator: ", "))
        }
        return nil
    }

    private func supportWaitingLabel(_ agent: AgentID) -> String {
        switch agent.waitingSource {
        case .hooks: return tr(.supportWaitingHooks)
        case .harvestPending: return tr(.supportWaitingHarvest)
        case .none: return tr(.supportWaitingNoneDetail)
        }
    }

    /// Compact collector failure age for Support diagnostics (empty when clean).
    func supportFailureTimelineDetail(_ health: AgentSupportHealth) -> String? {
        let state = harvestSupervisor.state(for: health.agent)
        guard state.lastFailureAtMs > 0, !state.lastError.isEmpty else { return nil }
        let seconds = max(0, Date().timeIntervalSince1970 - Double(state.lastFailureAtMs) / 1000.0)
        return String(
            format: tr(.supportFailureTimelineEntry),
            state.lastError,
            DurationFormat.label(seconds: seconds, lang: lang)
        )
    }

    func start() {
        DebugLog.write("start begin \(PulseVersion.fingerprint)")
        let recovery = LaunchRecovery.begin(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        launchRecovery = recovery.state
        recoveryExitKind = recovery.kind
        // Update replacement is an intentional exit — never show the unclean banner.
        recoveredAfterCrash = recovery.wasUnclean
        if recoveredAfterCrash {
            DebugLog.write("launch recovery unclean kind=\(recovery.kind.rawValue)")
        }
        // Restore only Pulse-owned attention state. Agent-owned hooks remain
        // the source of truth for the current row; the ledger supplies the
        // cross-launch baseline, snooze timers and delivery dedupe.
        attentionLedger = AttentionLedger.load()
        snoozedUntil = attentionLedger.snoozedUntil
        knownWaitingKeys = attentionLedger.activeKeys
        waitingNotifySeeded = attentionLedger.baselineEstablished
        dismissedPendingKeys = Self.loadDismissedPendingKeys()
        restoreAttentionHistory()
        HooksSupport.seedAssets()
        hooksStatus = HooksSupport.probeStatus()
        refreshPulseHookLauncherStatus()
        loadSettings()
        applyHotkey()
        PulseNotify.registerCategories(lang: lang)
        PulseNotify.configure { [weak self] granted in
            Task { @MainActor in
                self?.notifyAuthorized = granted
                self?.deliverPendingWaitingNotificationsIfPossible()
                DebugLog.write("notify authorization granted=\(String(describing: granted))")
            }
        }
        refresh(reason: "start")
        rescheduleTimer()
        attentionWatcher.start { [weak self] in
            Task { @MainActor in
                self?.refresh(reason: "attention")
            }
        }
        powerMonitor.start { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.rescheduleTimer()
                // Coming back from sleep/lock: catch up immediately.
                if !self.powerMonitor.state.parked { self.refresh(reason: "wake") }
            }
        }
        UpdateCheck.shared.startIfEnabled(store: self)
        installTerminationSignalMarker()
        DebugLog.write("start armed auto=\(autoProbe)")
    }

    /// Deterministic visual contract for compact/crowded tray QA.
    ///
    /// This is command-line only (`--tray-fixture=<fixture>`) and never
    /// reachable from product UI. It hosts the real TrayPanel and catches
    /// count, state, grouping, alignment and density regressions without
    /// depending on whichever Agents happen to be running on a test machine.
    func installPreviewFixture(_ name: String) {
        previewFixtureActive = true
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        func row(
            _ key: String,
            _ agent: AgentID,
            task: String,
            cwd: String = "/Users/me/code/Pulse",
            source: ObservationSource = .session,
            live: Bool = true,
            ageMinutes: Int = 1
        ) -> AgentRow {
            var value = AgentRow(rowKey: key, agent: agent)
            value.sessionID = key
            value.task = task
            value.cwd = cwd
            value.project = AgentRow.shortProject(cwd)
            value.observationSource = source
            value.liveProcess = live
            value.processCount = live ? 1 : 0
            value.harvestMs = now - Int64(ageMinutes * 60 * 1000)
            value.startedMs = now - 54 * 60 * 1000
            value.records = 126
            return value
        }

        if name.hasPrefix("status-") {
            // Compact status fixtures used to only stamp glance/header and left
            // `rows` empty, so `--capture-tray-panel` still showed whatever live
            // harvest (or nothing) was present. Inject one concrete row so
            // visual QA exercises the real tray layout for that lamp state.
            var fixtureRow = row(
                "status-fixture",
                .cursor,
                task: name == "status-waiting"
                    ? "Approve the packaging step"
                    : "Ship Signal Quality",
                cwd: "/Users/me/code/Pulse"
            )
            fixtureRow.phase = name == "status-waiting" ? "waiting" : "testing"
            fixtureRow.model = "fixture-model"
            fixtureRow.tool = name == "status-waiting" ? "" : "swift_test"
            switch name {
            case "status-waiting":
                fixtureRow.waiting = true
                fixtureRow.waitKind = "Permission"
                fixtureRow.waitMessage = "Bash: ./scripts/release.sh 2.0.0 --commit"
                fixtureRow.waitSignal = .hooks
                fixtureRow.waitSinceMs = now - 8 * 60 * 1000
            case "status-stalled":
                fixtureRow.isStalled = true
                fixtureRow.harvestMs = now - 25 * 60 * 1000
            case "status-running":
                fixtureRow.progressDone = 12
                fixtureRow.progressTotal = 31
            default:
                fixtureRow.liveProcess = false
                fixtureRow.processCount = 0
            }
            fixtureRow.refreshObservationQuality(privacyLimited: false)
            cachedAll = [fixtureRow]

            var snap = PulseSnapshot()
            switch name {
            case "status-running":
                snap.glance = .running
                snap.title = "1"
                snap.sectionTotals[.running] = 1
            case "status-stalled":
                snap.glance = .stalled
                snap.title = "1"
                snap.sectionTotals[.stalled] = 1
            case "status-waiting":
                snap.glance = .waiting
                snap.title = "1"
                snap.sectionTotals[.needsYou] = 1
            default:
                snap.glance = .idle
            }
            snap.headerTitle = name
            snap.header = name
            snap.tooltip = name
            snap.accessibilityLabel = tr(snap.glance.accessibilityKey)
            snap.rows = [fixtureRow]
            snap.totalCount = 1
            snap.updatedAt = Date()
            snapshot = snap
            return
        }

        if name == "coverage" {
            var codex = row(
                "coverage-codex",
                .codex,
                task: "Ship runtime observability",
                cwd: "/Users/me/code/Pulse"
            )
            codex.phase = "testing"
            codex.progressDone = 26
            codex.progressTotal = 31
            codex.processEvidence = .pathSignature

            var amp = row(
                "coverage-amp",
                .amp,
                task: "",
                cwd: "",
                source: .process
            )
            amp.harvestMs = 0
            amp.records = 0
            amp.processStartedMs = now - 60 * 60 * 1000
            amp.processCount = 2
            amp.processEvidence = .executable

            var cursor = row(
                "coverage-cursor",
                .cursor,
                task: "Refine adapter coverage",
                cwd: "/Users/me/code/Client",
                source: .cache,
                live: false
            )
            cursor.phase = "completed"
            cachedAll = [codex, amp, cursor]
            hooksStatus = .installedBoth
            previewWaitingEventTimes = [
                .claude: now - 48_000,
                .codex: now - 12_000,
            ]
            var health = Dictionary(
                uniqueKeysWithValues: AgentID.allCases.map { agent in
                    (
                        agent,
                        ActivityHarvest.CollectorHealth(
                            id: agent,
                            state: .sourceAbsent,
                            durationMs: 1,
                            rowCount: 0,
                            sourcePresent: false,
                            errorKind: ""
                        )
                    )
                }
            )
            health[.codex] = .init(
                    id: .codex,
                    state: .observed,
                    durationMs: 31,
                    rowCount: 1,
                    sourcePresent: true,
                    errorKind: ""
                )
            health[.amp] = .init(
                    id: .amp,
                    state: .noSessions,
                    durationMs: 4,
                    rowCount: 0,
                    sourcePresent: true,
                    errorKind: ""
                )
            health[.cursor] = .init(
                    id: .cursor,
                    state: .schemaMismatch,
                    durationMs: 18,
                    rowCount: 0,
                    sourcePresent: true,
                    errorKind: "JSONDecodeError"
                )
            health[.claude] = .init(
                    id: .claude,
                    state: .permissionDenied,
                    durationMs: 3,
                    rowCount: 0,
                    sourcePresent: true,
                    errorKind: "PermissionError"
                )
            recordCollectorHealth(Array(health.values))
            lastSuccessfulReadByAgent[.codex] = codex.harvestMs
            lastSuccessfulReadByAgent[.cursor] = cursor.harvestMs
            snapshot = PulseSnapshot(
                glance: .running,
                title: "2",
                tooltip: "coverage",
                accessibilityLabel: tr(.a11yRunning),
                headerTitle: "2 running",
                headerDetail: "",
                header: "2 running",
                rows: cachedAll,
                sectionTotals: [.running: 2, .recent: 1],
                projectCount: 2,
                totalCount: cachedAll.count,
                updatedAt: Date()
            )
            return
        }

        var waiting = row("claude-preview", .claude, task: "Approve the release build")
        waiting.waiting = true
        waiting.waitKind = "Permission"
        waiting.waitMessage = "Bash: ./scripts/release.sh 2.0.0 --commit"
        waiting.waitSignal = .hooks
        waiting.waitSinceMs = now - 8 * 60 * 1000

        var active = row(
            "codex-preview",
            .codex,
            task: "[hxddh/Pulse](https://github.com/hxddh/Pulse) Fix panel corners"
        )
        active.phase = "testing"
        active.progressDone = 18
        active.progressTotal = 31
        active.activityChange = .progress(done: 18, total: 31)
        active.activityChangedMs = now - 15_000
        active.tool = "swift_test"
        active.model = "gpt-5"
        active.contextPercent = 42
        active.tokensIn = 12_400
        active.tokensOut = 860

        var stalled = row(
            "pi-preview",
            .pi,
            task: "Check the process detector",
            cwd: "",
            ageMinutes: 32
        )
        stalled.isStalled = true

        var recent = row(
            "cursor-preview",
            .cursor,
            task: "Refine crowded tray alignment",
            cwd: "/Users/me/code/Design",
            live: false,
            ageMinutes: 4
        )
        recent.phase = "turn_complete"

        var rows = [waiting, active, stalled, recent]
        if name != "compact" {
            var cache = row(
                "kiro-preview",
                .kiro,
                task: "Audit settings copy",
                cwd: "/Users/me/code/Docs",
                source: .cache,
                live: false,
                ageMinutes: 6
            )
            cache.phase = "completed"
            var process = row(
                "replit-preview",
                .replit,
                task: "",
                cwd: "",
                source: .process,
                ageMinutes: 0
            )
            process.harvestMs = 0
            process.records = 0
            process.processStartedMs = now - 70 * 60 * 1000
            process.processEvidence = .executable
            var sub = row(
                "claude-sub-preview",
                .claude,
                task: "Run collector fixtures",
                cwd: "/Users/me/code/Pulse"
            )
            sub.subRunning = 2
            sub.subTotal = 3
            sub.model = "claude-sonnet-4"
            sub.contextPercent = 68
            rows += [cache, process, sub]
        }
        trayGrouping = name == "project" ? .project : .status
        rows.sort { $0.section.rawValue < $1.section.rawValue }
        cachedAll = rows

        var snap = PulseSnapshot()
        snap.glance = .waiting
        snap.title = "Claude · 8m"
        snap.tooltip = "Needs you · Claude"
        snap.accessibilityLabel = tr(.a11yWaiting)
        snap.rows = rows
        snap.totalCount = rows.count
        snap.sectionTotals = Dictionary(
            uniqueKeysWithValues: TraySection.allCases.map { section in
                (section, rows.filter { $0.section == section }.count)
            }
        )
        let bits = TraySection.allCases.compactMap { section -> String? in
            let count = snap.sectionTotals[section] ?? 0
            guard count > 0 else { return nil }
            return "\(count) \(tr(section.titleKey).lowercased())"
        }
        snap.headerTitle = bits.joined(separator: " · ")
        snap.header = snap.headerTitle
        snap.projectCount = Set(rows.map(\.displayPath).filter { !$0.isEmpty }).count
        snap.updatedAt = Date()
        snapshot = snap
    }

    /// launchctl unload+load are two blocking subprocesses; never run them on
    /// the main thread, and never run them when nothing changed.
    private func applyLaunchAtLoginIfChanged() {
        guard appliedLaunchAtLogin != launchAtLogin else { return }
        appliedLaunchAtLogin = launchAtLogin
        let enabled = launchAtLogin
        DispatchQueue.global(qos: .utility).async {
            let applied = LoginItem.setEnabled(enabled)
            Task { @MainActor [weak self] in self?.loginItemApplied = applied }
        }
    }

    /// Tray panel appeared — probe faster while the user is looking at it.
    func trayDidAppear() {
        trayOpen = true
        // 0.96: keep the close fingerprint until the opening scan finishes.
        // Diffing `cachedAll` here used the last background tick, so sleep/lock
        // changes landed in the list but not in the while-away notice.
        if trayClosedAt != nil {
            lookContinuityPendingClosedAt = trayClosedAt
        }
        rescheduleTimer()
        if previewFixtureActive {
            applyPendingLookContinuity()
        } else {
            refresh(reason: "trayOpen")
        }
    }

    func trayDidDisappear() {
        trayOpen = false
        trayClosedAt = Date()
        trayCloseFingerprint = captureLookFingerprint(at: trayClosedAt ?? Date())
        lookContinuityPendingClosedAt = nil
        rescheduleTimer()
    }

    /// Apply Look Closure against the rows from the opening scan (0.96).
    private func applyPendingLookContinuity() {
        guard let closed = lookContinuityPendingClosedAt else { return }
        lookContinuityPendingClosedAt = nil
        missedWhileAway = waitHistory.filter { $0.resolvedAt > closed }.count
        if let prior = trayCloseFingerprint {
            applyLookContinuity(prior: prior, closedAt: closed)
            return
        }
        lookMovedWhileAway = 0
        lookNewWaitsWhileAway = 0
        let ended = waitHistory.filter { $0.resolvedAt > closed }
        lookContinuityItems = ended.map { wait in
            let label = wait.title.isEmpty
                ? wait.agent.displayName
                : "\(wait.agent.displayName) · \(wait.title)"
            let revealable = cachedAll.contains(where: { $0.rowKey == wait.rowKey })
            return LookDeltaItem(
                kind: .endedWait,
                rowKey: wait.rowKey,
                label: label,
                revealable: revealable
            )
        }
        lookMovedRowKeys = []
        rebuildLookContinuityNotice()
    }

    /// Test seam: seed resolved-wait history for Look Closure assertions.
    func seedWaitHistory(_ items: [ResolvedWait]) {
        waitHistory = items
    }

    /// Acknowledge the "while you were away" line (clears named notice + row marks).
    func clearMissedWhileAway() {
        missedWhileAway = 0
        lookMovedWhileAway = 0
        lookNewWaitsWhileAway = 0
        lookContinuityNotice = ""
        lookContinuityItems = []
        lookMovedRowKeys = []
    }

    /// Look Closure (0.93): reveal the highest-priority named row, then ack.
    func activateLookContinuity() {
        let key = lookContinuityPrimaryRevealKey
        clearMissedWhileAway()
        if let key, !key.isEmpty {
            requestTrayReveal(rowKey: key)
        }
    }

    /// First revealable Look Closure row — new wait → ended (if still present) → moved.
    var lookContinuityPrimaryRevealKey: String? {
        lookContinuityItems.first(where: \.revealable)?.rowKey
    }

    /// Short row mark while the Look Closure notice is still up.
    func lookMarkedWhileAway(_ row: AgentRow) -> Bool {
        lookMovedRowKeys.contains(row.rowKey) && !row.waiting
    }

    /// Snapshot of live tray rows for Look Continuity / Closure.
    func captureLookFingerprint(at date: Date = Date()) -> TrayLookFingerprint {
        let snaps = cachedAll.map { row -> TrayLookFingerprint.RowSnap in
            TrayLookFingerprint.RowSnap(
                rowKey: row.rowKey,
                agentRaw: row.agent.rawValue,
                label: lookRowLabel(row),
                waiting: row.waiting,
                waitKind: row.waitKind,
                phase: row.phase,
                tool: row.tool,
                task: row.task,
                harvestMs: row.harvestMs,
                activityChangedMs: row.activityChangedMs,
                changeTag: lookChangeTag(row.activityChange),
                tokensIn: row.tokensIn,
                tokensOut: row.tokensOut,
                progressDone: row.progressDone,
                waitSinceMs: row.waitSinceMs
            )
        }
        return TrayLookFingerprint(closedAt: date, rows: snaps)
    }

    private func lookRowLabel(_ row: AgentRow) -> String {
        if let task = row.usefulTask, !task.isEmpty {
            let short = task.count > 28 ? String(task.prefix(27)) + "…" : task
            return "\(row.agent.displayName) · \(short)"
        }
        return row.agent.displayName
    }

    private func lookChangeTag(_ change: AgentActivityChange?) -> String {
        guard let change else { return "" }
        switch change {
        case .errors(let n): return "errors:\(n)"
        case .files(let n): return "files:\(n)"
        case .progress(let d, let t): return "progress:\(d)/\(t)"
        case .modelCall: return "model"
        case .toolChanged: return "tool"
        case .phaseChanged: return "phase"
        case .taskChanged: return "task"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    /// Compare close fingerprint to current rows — named Look Closure events (0.93).
    func applyLookContinuity(prior: TrayLookFingerprint, closedAt: Date) {
        let now = captureLookFingerprint(at: Date())
        let keyDelta = Self.lookContinuityKeyDelta(prior: prior, current: now)
        let liveByKey = Dictionary(uniqueKeysWithValues: cachedAll.map { ($0.rowKey, $0) })
        var items: [LookDeltaItem] = []

        // Priority: new waits → ended waits → moved sessions.
        for key in keyDelta.newWaitKeys {
            let label: String
            let revealable: Bool
            if let row = liveByKey[key] {
                label = lookRowLabel(row)
                revealable = true
            } else if let snap = now.rows.first(where: { $0.rowKey == key }) {
                label = snap.label.isEmpty ? snap.agentRaw : snap.label
                revealable = false
            } else {
                label = key
                revealable = false
            }
            items.append(LookDeltaItem(kind: .newWait, rowKey: key, label: label, revealable: revealable))
        }

        let ended = waitHistory.filter { $0.resolvedAt > closedAt }
        let endedKeys = Set(ended.map(\.rowKey))
        let newWaitSet = Set(keyDelta.newWaitKeys)
        lookNewWaitsWhileAway = keyDelta.newWaitKeys.count
        lookMovedWhileAway = keyDelta.movedKeys.filter {
            !endedKeys.contains($0) && !newWaitSet.contains($0)
        }.count
        missedWhileAway = ended.count

        for wait in ended {
            // Same row lighting a new wait outranks the ended history item.
            if newWaitSet.contains(wait.rowKey) { continue }
            let label = wait.title.isEmpty
                ? wait.agent.displayName
                : "\(wait.agent.displayName) · \(wait.title)"
            let revealable = liveByKey[wait.rowKey] != nil
            items.append(LookDeltaItem(
                kind: .endedWait,
                rowKey: wait.rowKey,
                label: label,
                revealable: revealable
            ))
        }

        for key in keyDelta.movedKeys {
            if endedKeys.contains(key) || newWaitSet.contains(key) { continue }
            let label: String
            let revealable: Bool
            if let row = liveByKey[key] {
                label = lookRowLabel(row)
                revealable = true
            } else if let snap = now.rows.first(where: { $0.rowKey == key }) {
                label = snap.label.isEmpty ? snap.agentRaw : snap.label
                revealable = false
            } else {
                continue
            }
            items.append(LookDeltaItem(kind: .moved, rowKey: key, label: label, revealable: revealable))
        }

        lookContinuityItems = items
        lookMovedRowKeys = Set(
            items.compactMap { item -> String? in
                guard item.revealable else { return nil }
                switch item.kind {
                case .newWait, .moved: return item.rowKey
                case .endedWait: return nil
                }
            }
        )
        rebuildLookContinuityNotice()
    }

    /// Key-level Look Continuity diff — only fingerprint fields; never invents Waiting.
    static func lookContinuityKeyDelta(
        prior: TrayLookFingerprint,
        current: TrayLookFingerprint
    ) -> (movedKeys: [String], newWaitKeys: [String]) {
        let priorByKey = Dictionary(uniqueKeysWithValues: prior.rows.map { ($0.rowKey, $0) })
        var movedKeys: [String] = []
        var newWaitKeys: [String] = []
        for snap in current.rows {
            guard let old = priorByKey[snap.rowKey] else {
                if snap.waiting {
                    newWaitKeys.append(snap.rowKey)
                } else if snap.harvestMs > 0 || snap.activityChangedMs > 0 {
                    movedKeys.append(snap.rowKey)
                }
                continue
            }
            if snap.waiting, !old.waiting {
                newWaitKeys.append(snap.rowKey)
                continue
            }
            // 0.96: a new wait generation on the same row (waitSinceMs moved)
            // is a new wait, not a silent continuation.
            if snap.waiting, old.waiting,
               snap.waitSinceMs > 0, old.waitSinceMs > 0,
               snap.waitSinceMs != old.waitSinceMs {
                newWaitKeys.append(snap.rowKey)
                continue
            }
            let changed = snap.phase != old.phase
                || snap.tool != old.tool
                || snap.task != old.task
                || snap.changeTag != old.changeTag
                || snap.harvestMs != old.harvestMs
                || snap.activityChangedMs != old.activityChangedMs
                || snap.tokensIn != old.tokensIn
                || snap.tokensOut != old.tokensOut
                || snap.progressDone != old.progressDone
                || snap.waitKind != old.waitKind
            if changed { movedKeys.append(snap.rowKey) }
        }
        return (movedKeys, newWaitKeys)
    }

    /// Compatibility wrapper used by older tests — counts only.
    static func lookContinuityDelta(
        prior: TrayLookFingerprint,
        current: TrayLookFingerprint
    ) -> (moved: Int, newWaits: Int) {
        let keys = lookContinuityKeyDelta(prior: prior, current: current)
        return (keys.movedKeys.count, keys.newWaitKeys.count)
    }

    private func rebuildLookContinuityNotice() {
        // Prefer named Look Closure copy (0.93); fall back to counts if empty.
        if !lookContinuityItems.isEmpty {
            lookContinuityNotice = formatLookContinuityNotice(lookContinuityItems)
            return
        }
        var parts: [String] = []
        if missedWhileAway > 0 {
            parts.append(String(format: tr(.whileAway), missedWhileAway))
        }
        if lookNewWaitsWhileAway > 0 {
            parts.append(String(format: tr(.whileAwayNewWaits), lookNewWaitsWhileAway))
        }
        if lookMovedWhileAway > 0 {
            parts.append(String(format: tr(.whileAwayMoved), lookMovedWhileAway))
        }
        lookContinuityNotice = parts.joined(separator: " · ")
    }

    /// Named notice: up to 3 events + "+N". Priority already encoded in items order.
    func formatLookContinuityNotice(_ items: [LookDeltaItem], limit: Int = 3) -> String {
        guard !items.isEmpty else { return "" }
        let head = items.prefix(limit).map { item -> String in
            switch item.kind {
            case .newWait:
                return String(format: tr(.whileAwayNamedNew), item.label)
            case .endedWait:
                return String(format: tr(.whileAwayNamedEnded), item.label)
            case .moved:
                return String(format: tr(.whileAwayNamedMoved), item.label)
            }
        }
        var text = head.joined(separator: " · ")
        let overflow = items.count - limit
        if overflow > 0 {
            text += " · " + String(format: tr(.whileAwayMore), overflow)
        }
        return text
    }

    /// Current cadence, for Settings/diagnostics ("probing every 5s").
    var probeIntervalDescription: String {
        guard autoProbe else { return tr(.probePaused) }
        guard let interval = currentInterval else { return tr(.probeParked) }
        return String(format: tr(.probeEvery), Int(interval.rounded()))
    }

    /// Close an open parked span. Switching live updates off is *not* parking —
    /// settling here too keeps a week with probing disabled out of the parked
    /// counter, which would otherwise swallow it whole on the next unpark.
    private func settleParked() {
        guard let since = parkedSince else { return }
        probeStats.addParked(Date().timeIntervalSince(since))
        parkedSince = nil
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard autoProbe else {
            settleParked()
            currentInterval = nil
            return
        }
        let interval = ProbeSchedule.interval(
            activity: activity,
            power: powerMonitor.state,
            trayOpen: trayOpen
        )
        currentInterval = interval
        guard let interval else {
            if parkedSince == nil { parkedSince = Date() }
            DebugLog.write("probe parked (display asleep / locked)")
            return
        }
        settleParked()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Bind before the Task: the timer block is @Sendable, and referencing
            // the captured `weak self` var from inside a Task is not allowed.
            guard let store = self else { return }
            Task { @MainActor in
                guard store.autoProbe else { return }
                store.refresh(reason: "timer")
            }
        }
        // Let the system coalesce wakeups — meaningful battery win for a
        // background poller that does not need millisecond precision.
        t.tolerance = interval * 0.2
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func installHooks() {
        hooksStatus = .unknown
        // `Task` inherits this class's main-actor isolation, so the assignment
        // lands on main while the optional hook installer stays off it.
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                HooksSupport.install()
            }.value
            self?.hooksStatus = status
        }
    }

    func runHookSelfTest() {
        hookSelfTestResult = .running
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                HooksSupport.selfTest()
            }.value
            self?.hookSelfTestResult = result
        }
    }

    func uninstallHooks() {
        hooksStatus = .unknown
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                HooksSupport.uninstall()
            }.value
            self?.hooksStatus = status
        }
    }

    var hooksInstalled: Bool {
        switch hooksStatus {
        case .installedBoth, .installedClaude, .installedCodex: return true
        case .unknown, .missing, .failed: return false
        }
    }

    /// Notification permission lives in System Settings, not in Pulse.
    func openSystemNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Notification permission is requested only from an explicit Settings
    /// action. Launching Pulse or scanning an Agent must remain interruption-
    /// free, especially for unsigned builds whose identity can change.
    func requestNotificationAuthorization() {
        PulseNotify.requestAuthorizationAfterUserAction()
    }

    func checkForUpdatesNow() {
        UpdateCheck.shared.check(store: self, force: true)
    }

    func downloadAndVerifyUpdate() {
        UpdateCheck.shared.downloadAndOpen(store: self)
    }

    func installVerifiedUpdate() {
        UpdateCheck.shared.installVerifiedUpdate(store: self)
    }

    var updateStatusText: String {
        switch updateStatus {
        case .idle: return tr(.updateIdle)
        case .checking: return tr(.updateChecking)
        case .current:
            if PulseVersion.prefersPrereleaseUpdates {
                return tr(.updateCurrentPrerelease)
            }
            if PulseVersion.distributionChannel == "stable" {
                return tr(.updateCurrentStable)
            }
            return tr(.updateCurrent)
        case .available(let release): return String(format: tr(.updateAvailable), release.version)
        case .failed(let message): return "\(tr(.updateFailed)) · \(message)"
        }
    }

    var updateAvailableURL: URL? {
        if case .available(let release) = updateStatus, !release.pageURL.isEmpty {
            return URL(string: release.pageURL)
        }
        return nil
    }

    var updateCanVerifyDownload: Bool {
        if case .available(let release) = updateStatus {
            return release.canVerifyDownload
        }
        return false
    }

    /// In-place install is only honest on notarized stable builds.
    var updateCanInstallInPlace: Bool {
        PulseVersion.isGatekeeperReady
    }

    var updateDownloadStatusText: String? {
        switch updateDownloadStatus {
        case .idle: return nil
        case .downloading: return tr(.updateDownloading)
        case .verifying: return tr(.updateVerifying)
        case .ready:
            return updateCanInstallInPlace
                ? tr(.updateVerified)
                : tr(.updateVerifiedOpenOnly)
        case .installing: return tr(.updateInstalling)
        case .failed(let message): return "\(tr(.updateVerifyFailed)) · \(message)"
        }
    }

    var maintenanceNoticeText: String? {
        if recoveredAfterCrash { return recoveryNoticeText }
        if isVersionMismatch { return tr(.versionStale) }
        if installReport.hasOtherRunningCopy { return tr(.duplicateAppRunning) }
        // A Waiting row is already visible in the tray, but without a system
        // notification the user has no interruption when the panel is closed.
        // Make the missing permission explicit and give the notice a direct
        // action; never request permission implicitly from a background scan.
        if waitingNotificationNeedsSetup {
            return notifyAuthorized == false
                ? tr(.waitingNotifyDenied)
                : tr(.waitingNotifyNotConfigured)
        }
        // The tray is an observation surface, not a hook installer. Missing
        // Claude/Codex hooks remain visible in Support Health and Settings
        // (native install — no Python). Do not displace session facts.
        if needsWaitingSignalNudge { return tr(.waitingSignalNudge) }
        if case .available = updateStatus { return updateStatusText }
        return nil
    }

    private var recoveryNoticeText: String {
        switch recoveryExitKind {
        case .forceQuit: return tr(.recoveredAfterForceQuit)
        case .systemRestart: return tr(.recoveredAfterSystemRestart)
        case .crash, .unknown: return tr(.recoveredAfterCrash)
        case .clean, .updateReplace:
            // wasUnclean excludes these; never surface a crash lie here.
            return ""
        }
    }

    func dismissRecoveryNotice() {
        recoveredAfterCrash = false
        recoveryExitKind = .clean
        recoveryNoticeSurvivedFirstHealthyScan = false
    }

    func performMaintenanceNoticeAction() {
        if recoveredAfterCrash {
            dismissRecoveryNotice()
            openSettings()
            return
        }
        if waitingNotificationNeedsSetup {
            if notifyAuthorized == false {
                openSystemNotificationSettings()
            } else {
                openSettings()
            }
            return
        }
        // The tray notice is reserved for actionable non-hook maintenance or
        // an already-configured Waiting route. Hook setup stays in Settings.
        if needsWaitingSignalNudge {
            openSettings(
                focusWaitingSignals: true,
                focusWaitingAgent: firstLiveWaitingNoneAgent
            )
            return
        }
        if case .available = updateStatus, updateCanVerifyDownload {
            downloadAndVerifyUpdate()
        } else {
            openSettings()
        }
    }

    /// A live Waiting row with the user's Waiting-notification preference on,
    /// but no usable macOS authorization. This is intentionally level-based:
    /// the in-tray prompt remains until the user fixes the route or turns the
    /// preference off, so an approval cannot be missed between scans.
    var waitingNotificationNeedsSetup: Bool {
        notifyOnWaiting && notifyAuthorized != true && cachedAll.contains(where: \.waiting)
    }

    func refreshInstallTruth(force: Bool = false) {
        let now = Date()
        if !force,
           installTruthRefreshInFlight
                || (installTruthRefreshedAt.map { now.timeIntervalSince($0) < 30 } ?? false) {
            return
        }
        installTruthRefreshInFlight = true
        installTruthGeneration += 1
        let generation = installTruthGeneration
        Task { @MainActor [weak self] in
            let report = await Task.detached(priority: .utility) {
                InstallTruth.inspect()
            }.value
            guard let self, self.installTruthGeneration == generation else { return }
            self.installReport = report
            self.installTruthRefreshedAt = Date()
            self.installTruthRefreshInFlight = false
        }
    }

    func recycleDuplicateApps() {
        let candidates = installReport.removableDuplicates
        InstallTruth.recycle(candidates) { [weak self] _ in
            self?.refreshInstallTruth(force: true)
        }
    }

    var hookSelfTestText: String {
        switch hookSelfTestResult {
        case .idle: return tr(.hookTestIdle)
        case .running: return tr(.hookTestRunning)
        case .passed(let date):
            return "\(tr(.hookTestPassed)) · \(relative(date))"
        case .failed(let message):
            return "\(tr(.hookTestFailed)) · \(message)"
        }
    }

    /// `Permission · waited 4 分 · Pulse` for the resolved-wait list.
    func historyDetail(_ entry: ResolvedWait) -> String {
        var bits: [String] = []
        if !entry.kind.isEmpty { bits.append(localizedWaitKind(entry.kind)) }
        if entry.waitedSeconds >= 1 {
            bits.append(String(format: tr(.waitedFor), durationLabel(seconds: entry.waitedSeconds)))
        }
        if !entry.project.isEmpty { bits.append(entry.project) }
        bits.append(relative(entry.resolvedAt))
        return bits.joined(separator: " · ")
    }

    func toggleShowAllAgents() {
        showAllAgents.toggle()
        applyRowWindow()
    }

    func refresh() {
        refresh(reason: "manual")
    }

    func refresh(reason: String, agentFilter: Set<AgentID>? = nil) {
        if scanInFlight {
            pendingRefreshReason = reason
            DebugLog.write("refresh coalesce pending=\(reason)")
            return
        }
        scanInFlight = true
        scanTicket &+= 1
        let ticket = scanTicket
        let showSpinner = reason == "manual" || reason == "start"
        if showSpinner {
            isRefreshing = true
        }
        DebugLog.write("refresh enqueue #\(ticket) reason=\(reason)")

        // Native harvest walks bounded vendor roots; probe is one `ps` call.
        // Only pay for the richer scan when something plausibly changed.
        let forceHarvest = reason != "timer"
        let priorSignature = lastProcessSignature
        let ticks = ticksSinceHarvest
        let everyN = ProbeSchedule.harvestEveryNTicks(activity: activity, trayOpen: trayOpen)
        let allowAllAppData = allowAppData
        let appDataAgentPolicy = harvestAppDataAgents
        let supervisorNowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let supervisorPlan = harvestSupervisor.plan(nowMs: supervisorNowMs)
        if !supervisorPlan.deferred.isEmpty {
            DebugLog.write("harvest supervisor deferred=\(supervisorPlan.deferred.map(\.rawValue).sorted().joined(separator: ",")) \(harvestSupervisor.summary(nowMs: supervisorNowMs))")
        }
        // Permission toggles force the affected Agent(s) even if the supervisor
        // would otherwise defer them. Full scans keep the supervisor plan.
        let harvestFilter: Set<AgentID>? = {
            if let agentFilter { return Set(agentFilter.map(\.surfaceID)) }
            return supervisorPlan.attempted
        }()
        let scopedHarvest = agentFilter != nil
        let startCursor = harvestScanCursor

        scanQueue.async { [weak self] in
            let t0 = Date()
            let procs = ProcessProbe.scan(
                allowAppData: allowAllAppData,
                appDataAgents: appDataAgentPolicy
            )
            let signature = ProcessProbe.signature(procs)

            let why: String
            if forceHarvest {
                why = "forced"
            } else if signature != priorSignature {
                why = "procChanged"
            } else if ticks >= everyN {
                why = "cadence"
            } else {
                why = "skipped"
            }

            let outcome: HarvestOutcome
            var harvestMs: Int?
            var nextCursor = startCursor
            if why == "skipped" {
                outcome = .skipped
            } else {
                let h0 = Date()
                let result = ActivityHarvest.scan(
                    allowAppData: allowAllAppData,
                    appDataAgents: appDataAgentPolicy,
                    agentFilter: harvestFilter,
                    startCursor: startCursor
                )
                harvestMs = Int(Date().timeIntervalSince(h0) * 1000)
                // A scoped rescan covers a hand-picked subset; its cursor is
                // meaningless to the full rotation.
                nextCursor = scopedHarvest ? startCursor : result.nextCursor
                let intentionalPartial = Self.isIntentionalSupervisorPartial(
                    health: result.health,
                    plan: supervisorPlan
                )
                // Scoped permission rescans report only the affected adapters.
                // Force a partial merge so other Agents keep their last good rows.
                let complete = scopedHarvest ? false : result.complete
                outcome = result.unreliable
                    ? .failed(result.health, complete, intentionalPartial || scopedHarvest)
                    : .fresh(result.rows, result.health, complete, intentionalPartial || scopedHarvest)
            }

            let attention = AttentionReader.load()
            // Respond (scene AR): read the inbound full-request spool off the
            // main thread, alongside the other file sources. Cleanup here too
            // — both are bounded (≤16 hosts × 32 files).
            let scanNowMs = Int64(Date().timeIntervalSince1970 * 1000)
            RespondSpool.cleanup(nowMs: scanNowMs)
            let respondInbound = RespondSpool.readInboundRequests(nowMs: scanNowMs)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DebugLog.write(
                "scan done #\(ticket) \(ms)ms harvest=\(why) scoped=\(scopedHarvest) procs=\(procs.count) " +
                "att=\(attention.count) procIds=\(procs.map(\.id.rawValue).joined(separator: ","))"
            )
            let completedHarvestMs = harvestMs
            let completedCursor = nextCursor
            // Land results on the store that started the flight, not the
            // AppServices singleton: a hardwired singleton sent every other
            // instance's results to the wrong store and left its
            // `scanInFlight` stuck forever — which is also why the scan
            // pipeline could never be exercised from a test.
            DispatchQueue.main.async { [completedHarvestMs, completedCursor] in
                guard let self else { return }
                self.harvestScanCursor = completedCursor
                switch outcome {
                case .fresh(_, let health, _, _), .failed(let health, _, _):
                    self.harvestSupervisor.record(
                        health,
                        nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                    )
                case .skipped:
                    break
                }
                self.applyScan(
                    procs: procs,
                    harvest: outcome,
                    processSignature: signature,
                    attention: attention,
                    ticket: ticket,
                    harvestMs: completedHarvestMs,
                    clearRefreshing: showSpinner,
                    reason: reason
                )
                self.refreshRespondInbound(respondInbound)
            }
        }
    }

    fileprivate func finishScanFlight() {
        scanInFlight = false
        if let pending = pendingRefreshReason {
            pendingRefreshReason = nil
            refresh(reason: pending)
        }
    }

    /// What the background scan managed to get from the native collector.
    enum HarvestOutcome {
        /// Ran and produced rows (possibly partial after a timeout).
        case fresh([ActivityHarvest.Row], [ActivityHarvest.CollectorHealth], Bool, Bool)
        /// Deliberately not run this tick — cached rows are still current.
        case skipped
        /// Ran and failed; cached rows may be stale.
        case failed([ActivityHarvest.CollectorHealth], Bool, Bool)
    }

    /// A supervisor plan can intentionally omit adapters that are backing off
    /// or inside a circuit. That is a bounded, known partial scan: the rows
    /// from those adapters remain in `mergePartialRows`, while the adapters
    /// that did run are a trustworthy snapshot for Waiting reconciliation.
    /// Distinguish this from a global deadline or a failed adapter, otherwise
    /// one broken source would delay notifications and resolution for all the
    /// healthy agents on every subsequent tick.
    nonisolated static func isIntentionalSupervisorPartial(
        health: [ActivityHarvest.CollectorHealth],
        plan: HarvestSupervisor.Plan
    ) -> Bool {
        guard !plan.deferred.isEmpty else { return false }
        let attempted = Set(plan.attempted.map(\.surfaceID))
        guard !attempted.isEmpty else { return false }
        let reported = Set(health.map { $0.id.surfaceID })
        guard attempted.isSubset(of: reported) else { return false }
        return health
            .filter { attempted.contains($0.id.surfaceID) }
            .allSatisfy { item in
                switch item.state {
                case .failed, .schemaMismatch, .unscanned:
                    return false
                case .observed, .noRecentData, .sourceAbsent, .noSessions, .permissionDenied:
                    return true
                }
            }
    }

    func recordCollectorHealth(
        _ health: [ActivityHarvest.CollectorHealth],
        complete: Bool = true,
        intentionalPartial: Bool = false
    ) {
        // A partial stream must not erase the last known result for adapters
        // that have not been reached yet. Only a complete health report resets
        // the map to the explicit unscanned baseline before applying results.
        var next = complete && !health.isEmpty
            ? Dictionary(
                uniqueKeysWithValues: AgentID.allCases.map {
                    ($0, ActivityHarvest.CollectorHealth.unscanned($0))
                }
            )
            : (collectorHealthByAgent.isEmpty
                ? Dictionary(
                    uniqueKeysWithValues: AgentID.allCases.map {
                        ($0, ActivityHarvest.CollectorHealth.unscanned($0))
                    }
                )
                : collectorHealthByAgent)
        for item in health {
            var normalized = item
            normalized.id = item.id.surfaceID
            next[normalized.id] = normalized
        }
        // Cursor Agent sessions are merged into Cursor rows by SnapshotBuilder
        // to avoid duplicate IDE/CLI entries. They share Cursor's local-store
        // collector, so the runtime health must share that result too.
        if let cursor = next[.cursor] {
            next[.cursorAgent] = ActivityHarvest.CollectorHealth(
                id: .cursorAgent,
                state: cursor.state,
                durationMs: cursor.durationMs,
                rowCount: cursor.rowCount,
                sourcePresent: cursor.sourcePresent,
                errorKind: cursor.errorKind,
                explain: cursor.explain
            )
        }
        collectorHealthByAgent = next
        // Supervisor-deferred adapters are a policy partial, not a failed scan.
        // Lighting the incomplete banner for intentional deferral made healthy
        // ticks look broken every time one agent was in backoff.
        collectorScanIncomplete = !complete && !intentionalPartial
    }

    fileprivate func applyScan(
        procs: [ProcessProbe.Hit],
        harvest: HarvestOutcome,
        processSignature: String,
        attention: [AttentionReader.Entry],
        ticket: UInt64,
        harvestMs: Int? = nil,
        clearRefreshing: Bool = false,
        reason: String = ""
    ) {
        defer { finishScanFlight() }

        if ticket < lastAppliedTicket {
            DebugLog.write("apply skip stale #\(ticket) lastApplied=\(lastAppliedTicket)")
            if clearRefreshing { isRefreshing = false }
            return
        }
        lastAppliedTicket = ticket
        lastProcessSignature = processSignature

        // Resolve which harvest rows this scan should use, and remember them.
        let acts: [ActivityHarvest.Row]
        switch harvest {
        case .fresh(let rows, let health, let complete, let intentionalPartial):
            // A timed-out child can still emit a valid prefix of the stream.
            // Replace only adapters that reported; keep the previous rows for
            // adapters the child never reached so one slow collector cannot
            // make unrelated live sessions disappear from the tray.
            acts = complete
                ? rows
                : ActivityHarvest.mergePartialRows(
                    current: rows,
                    health: health,
                    previous: lastGoodHarvest
                )
            lastGoodHarvest = acts
            recordCollectorHealth(
                health,
                complete: complete,
                intentionalPartial: intentionalPartial
            )
            // `row.harvestMs` is the vendor session's last activity time, not
            // when Pulse successfully read that adapter. Using it as "last
            // read" made a healthy but idle collector look months stale, and
            // made a newly-read old session look like a failed adapter. Keep
            // the two clocks separate: this timestamp records the completed
            // collector read, while row.harvestMs remains session activity.
            let collectorReadAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            for item in health where !item.state.isIssue {
                let agent = item.id.surfaceID
                lastSuccessfulReadByAgent[agent] = max(
                    lastSuccessfulReadByAgent[agent] ?? 0,
                    collectorReadAtMs
                )
            }
            ticksSinceHarvest = 0
        case .skipped:
            // Cached rows are at most a couple of ticks old — keep them whole,
            // pending included, or Waiting would flicker off between harvests.
            acts = lastGoodHarvest
            ticksSinceHarvest = ticksSinceHarvest == Int.max ? 1 : ticksSinceHarvest + 1
        case .failed(let health, let complete, let intentionalPartial):
            recordCollectorHealth(
                health,
                complete: complete,
                intentionalPartial: intentionalPartial
            )
            // 0.95: keep last-good pending intact. Stripping pending on failure
            // manufactured a false clear then a re-raise on the next skip.
            acts = lastGoodHarvest
            ticksSinceHarvest = 0
            DebugLog.write("harvest unreliable → reuse \(acts.count) cached rows (pending kept)")
        }
        let harvestUnreliable: Bool = {
            switch harvest {
            case .failed(_, _, let intentionalPartial):
                return !intentionalPartial
            case .fresh(_, _, let complete, let intentionalPartial):
                // A timed-out stream may contain useful rows, but it is not a
                // complete baseline. Treat it as unreliable for attention
                // edge reconciliation so an adapter that was never reached
                // cannot silently resolve a real Waiting event.
                return !complete && !intentionalPartial
            case .skipped:
                return false
            }
        }()

        let now = Date()
        probeStats.record(
            ProbeStats.Sample(at: now, harvested: harvestMs != nil, harvestMs: harvestMs)
        )

        // A snooze that has run out must announce itself again, so forget the
        // row was ever waiting: the builder's "newly waiting" edge is a set
        // difference against these keys, and a wait that stayed in the set for
        // the whole snooze would come back silently.
        var waitingKeysForEdges = knownWaitingKeys
        for (key, deadline) in snoozedUntil where deadline <= now {
            snoozedUntil.removeValue(forKey: key)
            attentionLedger.unsnooze(rowKey: key)
            waitingKeysForEdges.remove(key)
            DebugLog.write("snooze expired \(DebugLog.key(key))")
        }

        let result = SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: procs,
                harvest: acts,
                harvestUnreliable: harvestUnreliable,
                attention: attention
            ),
            previous: SnapshotBuilder.Previous(rows: cachedAll, waitingKeys: waitingKeysForEdges),
            context: SnapshotBuilder.Context(
                nowMs: Int64(now.timeIntervalSince1970 * 1000),
                terminal: TerminalFocus.Environment.current(
                    allowTTYAutomation: allowTerminalAutomation
                ),
                lang: lang,
                dismissedPendingKeys: dismissedPendingKeys,
                showAllAgents: showAllAgents,
                snoozedUntilMs: snoozedUntil.mapValues { Int64($0.timeIntervalSince1970 * 1000) },
                stalledSeconds: Double(stallMinutes) * 60,
                privacyLimitedAgents: Set(
                    AgentID.allCases.filter {
                        $0.requiresAppDataOptIn && !isAppDataAllowed(for: $0)
                    }
                )
            )
        )

        for note in result.debugNotes { DebugLog.write(note) }
        for (oldKey, newKey) in result.remappedRowKeys {
            migrateRowIdentity(from: oldKey, to: newKey)
        }
        dismissedPendingKeys.subtract(result.clearedPendingKeys)
        if !result.clearedPendingKeys.isEmpty {
            persistDismissedPendingKeys()
        }
        cachedAll = result.rows
        showAllAgents = result.showAllAgents
        knownWaitingKeys = result.waitingKeys
        // A wait that resolved on its own takes its snooze with it, or the next
        // wait on the same row would start life already silenced.
        snoozedUntil = snoozedUntil.filter { result.waitingKeys.contains($0.key) }

        // Reconcile before delivery so a restart can distinguish an already
        // known wait from a newly crossed edge. An unreliable first scan is
        // not a trustworthy baseline: seeding it would suppress the first
        // real notification after the collector recovers. The ledger is
        // written atomically; a crash during this scan leaves the previous
        // complete state intact.
        let attentionBaselineValid = !harvestUnreliable
            || result.rows.contains(where: \.waiting)
            || !attention.isEmpty
        if attentionBaselineValid {
            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            attentionLedger.reconcile(
                activeRows: result.rows.filter(\.waiting),
                nowMs: nowMs
            )
            // A queued edge can outlive both the scan and the process. Rebuild
            // the in-memory delivery queue from the durable ledger before any
            // notification decision so a relaunch never loses it.
            for row in result.rows where row.waiting && attentionLedger.queuedKeys.contains(row.rowKey) {
                pendingWaitingNotifications[row.rowKey] = row
            }
            attentionLedger.markBaseline()
            attentionLedger.save()
        } else {
            DebugLog.write("attention ledger baseline deferred: harvest unreliable and no wait evidence")
        }

        var snap = result.snapshot
        snap.updatedAt = now

        // A healthy scan after launch means recovery succeeded. Keep the banner
        // through the first healthy scan so opening the tray once still shows
        // it; clear on the subsequent healthy scan (or explicit dismiss).
        if recoveredAfterCrash, !harvestUnreliable {
            if recoveryNoticeSurvivedFirstHealthyScan {
                dismissRecoveryNotice()
            } else {
                recoveryNoticeSurvivedFirstHealthyScan = true
            }
        }

        // Notification policy lives here; the builder only reports the edges.
        let quiet = isInQuietHours()
        if notifyAuthorized == true, notifyOnIdle, !quiet, result.wentIdle {
            PulseNotify.postIdle(title: "Pulse", body: tr(.idleNotify))
        }
        // Waiting edges stay available even during quiet hours (when enabled).
        // Skip the first scan so launch doesn't flood for already-waiting rows.
        if notifyOnWaiting, waitingNotifySeeded {
            let waitingEdges = result.newlyWaiting.filter { !mutedAgents.contains($0.agent) }
            let queuedRows = pendingWaitingNotifications.values.filter { row in
                row.waiting && !mutedAgents.contains(row.agent)
            }
            let deliveryRows = Self.waitingDeliveryRows(edges: waitingEdges, queued: queuedRows)
            if notifyAuthorized == true {
                postWaitingNotifications(deliveryRows)
            } else if notifyAuthorized != true {
                // Permission resolution is asynchronous, and a previously
                // denied permission may be enabled later in System Settings.
                // Preserve every edge until the callback arrives instead of
                // dropping the only interruption for a just-started session.
                for waiting in waitingEdges {
                    pendingWaitingNotifications[waiting.rowKey] = waiting
                    attentionLedger.markQueued(
                        rowKey: waiting.rowKey,
                        nowMs: Int64(now.timeIntervalSince1970 * 1000)
                    )
                }
                attentionLedger.save()
            }
        }
        if !waitingNotifySeeded, attentionBaselineValid {
            waitingNotifySeeded = true
        }

        recordResolvedWaits(result.resolvedWaits, at: now)

        snapshot = snap
        if clearRefreshing { isRefreshing = false }
        if reason == "trayOpen" {
            applyPendingLookContinuity()
        }
        if reason == "trayOpen" || reason == "attentionSample" {
            applyPendingSampleReveal()
        }

        let previousActivity = activity
        activity = result.activity
        // Only re-arm when the cadence tier actually moved — a timer rebuilt on
        // every tick never fires at its own interval.
        if previousActivity != activity || timer == nil {
            rescheduleTimer()
        }

        DebugLog.write(
            "apply #\(ticket) rows=\(snap.rows.count)/\(snap.totalCount) glance=\(snap.glance) " +
            "activity=\(activity) wait=\(result.waitingKeys.count) " +
            "every=\(currentInterval.map { String(Int($0)) } ?? "parked")"
        )
    }

    /// Deliver one actionable notification per Waiting session. A previous
    /// implementation used `first(where:)`, so a scan that found Codex and
    /// Cursor approvals notified only whichever row happened to sort first.
    private func postWaitingNotifications(_ rows: [AgentRow]) {
        guard notifyAuthorized == true, notifyOnWaiting else { return }
        let candidates = Array(
            Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, AgentRow)? in
                guard row.waiting,
                      !mutedAgents.contains(row.agent),
                      !attentionLedger.isAcknowledged(rowKey: row.rowKey),
                      !waitingDeliveryInFlight.contains(row.rowKey)
                else { return nil }
                return (row.rowKey, row)
            }).values
        )
        guard !candidates.isEmpty else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard attentionLedger.canDeliver(
            nowMs: nowMs,
            minimumIntervalMs: Self.waitingNotificationMinimumIntervalMs
        ) else {
            for waiting in candidates {
                pendingWaitingNotifications[waiting.rowKey] = waiting
                attentionLedger.markQueued(rowKey: waiting.rowKey, nowMs: nowMs)
            }
            attentionLedger.save()
            scheduleWaitingDelivery(afterMs: max(
                Self.waitingNotificationMinimumIntervalMs - (nowMs - attentionLedger.lastNotificationAtMs),
                250
            ))
            return
        }

        let wasIdleBeforeDelivery = waitingDeliveryInFlight.isEmpty
        let deliveryKeys = candidates.map(\.rowKey)
        if wasIdleBeforeDelivery { waitingDeliverySounded = false }
        for waiting in candidates {
            pendingWaitingNotifications[waiting.rowKey] = waiting
            waitingDeliveryInFlight.insert(waiting.rowKey)
            attentionLedger.markQueued(rowKey: waiting.rowKey, nowMs: nowMs)
        }
        // Persist before asking Notification Center to accept the request. A
        // crash between those two operations leaves a durable queued edge,
        // which the next launch can rehydrate and deliver exactly once.
        attentionLedger.save()

        let batchCompletion: (Bool) -> Void = { [weak self] success in
            guard let self else { return }
            self.finishWaitingDelivery(
                keys: deliveryKeys,
                rows: candidates,
                success: success
            )
        }

        if candidates.count > 3 {
            let eventIDs = candidates.compactMap { attentionLedger.eventID(for: $0.rowKey) }
            let title = String(format: tr(.waitingSummaryTitle), candidates.count)
            let body = candidates.prefix(3).map(notificationBody).joined(separator: " · ")
                + (candidates.count > 3 ? " …" : "")
            let first = candidates[0]
            PulseNotify.postWaitingSummary(
                title: title,
                body: body,
                agent: first.agent.rawValue,
                session: first.sessionID,
                rowKeys: candidates.map(\.rowKey),
                eventIDs: eventIDs,
                completion: batchCompletion
            )
        } else {
            for waiting in candidates {
                PulseNotify.postWaiting(
                    title: notificationTitle(waiting),
                    body: notificationBody(waiting),
                    agent: waiting.agent.rawValue,
                    session: waiting.sessionID,
                    rowKey: waiting.rowKey,
                    eventID: attentionLedger.eventID(for: waiting.rowKey) ?? "",
                    completion: { success in
                        // Each individual request owns one event; commit that
                        // event independently so one rejected request never
                        // hides the other accepted Waiting notifications.
                        self.finishWaitingDelivery(
                            keys: [waiting.rowKey],
                            rows: [waiting],
                            success: success
                        )
                    }
                )
            }
        }
    }

    /// Commit or requeue the durable event only after Notification Center has
    /// reported whether the request was accepted. This closes the rare but
    /// important gap where an app reinstall, identity transition, or system
    /// service error rejects an otherwise valid request.
    /// One delivery row per Waiting session, fresh edge preferred.
    ///
    /// A row can legitimately be in both lists: an edge queued while
    /// notification authorization was still unresolved, then re-emitted as a
    /// new wait once the agent cleared and asked again — 0.96 made a new
    /// `waitSinceMs` on the same key a new edge. The previous inline
    /// `Dictionary(uniqueKeysWithValues:)` **traps** on a duplicate key, so
    /// that sequence crashed the menu bar outright. `AttentionLedger` had
    /// already learned this lesson in `snoozedUntil`; the same landmine sat
    /// here in the notification path.
    nonisolated static func waitingDeliveryRows(
        edges: [AgentRow],
        queued: [AgentRow]
    ) -> [AgentRow] {
        Array(
            Dictionary(
                (edges + queued).map { ($0.rowKey, $0) },
                uniquingKeysWith: { fresh, _ in fresh }
            ).values
        )
    }

    private func finishWaitingDelivery(
        keys: [String],
        rows: [AgentRow],
        success: Bool
    ) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for key in keys {
            waitingDeliveryInFlight.remove(key)
        }
        if success {
            for row in rows {
                attentionLedger.markNotified(rowKey: row.rowKey, nowMs: nowMs)
                pendingWaitingNotifications.removeValue(forKey: row.rowKey)
            }
            attentionLedger.save()
            // Opt-in, and deliberately quiet: Tink, not an alert tone. A
            // successful batch produces one cue even when several sessions
            // crossed into Waiting together.
            if playSoundOnWaiting, !waitingDeliverySounded {
                NSSound(named: NSSound.Name("Tink"))?.play()
                waitingDeliverySounded = true
            }
        } else {
            for row in rows where row.waiting {
                pendingWaitingNotifications[row.rowKey] = row
                attentionLedger.markQueued(rowKey: row.rowKey, nowMs: nowMs)
            }
            attentionLedger.save()
            DebugLog.write("waiting notification requeued keys=\(keys.joined(separator: ","))")
            scheduleWaitingDelivery(afterMs: Self.waitingNotificationMinimumIntervalMs)
        }
    }

    private func scheduleWaitingDelivery(afterMs: Int64) {
        waitingDeliveryTask?.cancel()
        waitingDeliveryTask = Task { @MainActor [weak self] in
            let nanos = UInt64(max(250, afterMs)) * 1_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.waitingDeliveryTask = nil
            self.deliverPendingWaitingNotificationsIfPossible()
        }
    }

    /// Authorization may become known after the scan that observed a new
    /// Waiting edge. Flush only rows that are still waiting; a resolved prompt
    /// should not reappear as a stale notification when the user returns from
    /// System Settings.
    private func deliverPendingWaitingNotificationsIfPossible() {
        guard notifyAuthorized == true, notifyOnWaiting, !pendingWaitingNotifications.isEmpty else {
            if !notifyOnWaiting { pendingWaitingNotifications.removeAll() }
            return
        }
        let current = Dictionary(uniqueKeysWithValues: cachedAll.map { ($0.rowKey, $0) })
        let rows = pendingWaitingNotifications.values.compactMap { pending -> AgentRow? in
            guard let row = current[pending.rowKey], row.waiting else { return nil }
            return row
        }
        postWaitingNotifications(rows)
    }

    private func applyRowWindow() {
        var snap = snapshot
        SnapshotBuilder.window(
            rows: cachedAll,
            showAll: showAllAgents,
            maxVisible: SnapshotBuilder.maxVisibleRows,
            into: &snap
        )
        snapshot = snap
    }

    /// `Claude · Pulse` — who and where, so the banner is actionable at a glance.
    func notificationTitle(_ row: AgentRow) -> String {
        let project = AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project)
        return project.isEmpty
            ? row.agent.displayName
            : "\(row.agent.displayName) · \(project)"
    }

    /// `Permission · Approve shell command` — the reason, not just "Needs you".
    /// The old body was the glance tooltip, which never said what was wanted.
    func notificationBody(_ row: AgentRow) -> String {
        var bits: [String] = [
            row.waitKind.isEmpty ? tr(.needsYou) : localizedWaitKind(row.waitKind)
        ]
        let msg = row.waitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !msg.isEmpty {
            bits.append(msg.count > 120 ? String(msg.prefix(119)) + "…" : msg)
        } else if let task = row.usefulTask {
            bits.append(task.count > 120 ? String(task.prefix(119)) + "…" : task)
        }
        return bits.joined(separator: " · ")
    }

    /// Rehydrate the small resolved-wait trail from the durable ledger. The
    /// current rows still come exclusively from the live scan; only completed
    /// attention edges are restored here so a relaunch can answer “what did I
    /// miss?” without retaining prompts or raw agent payloads.
    private func restoreAttentionHistory() {
        waitHistory = attentionLedger.recentResolved.prefix(Self.maxWaitHistory).compactMap { event in
            guard let agent = AgentID(rawValue: event.agent), event.resolvedAtMs > 0 else { return nil }
            let resolved = Date(timeIntervalSince1970: Double(event.resolvedAtMs) / 1000)
            let observed = Date(timeIntervalSince1970: Double(event.observedAtMs) / 1000)
            return ResolvedWait(
                rowKey: event.rowKey,
                agent: agent,
                title: event.title,
                kind: event.kind,
                project: event.project,
                resolvedAt: resolved,
                waitedSeconds: max(0, resolved.timeIntervalSince(observed))
            )
        }
    }

    /// Keep a short trail of waits that already cleared, so "I think something
    /// pinged me while I was away" has an answer. The builder decides *which*
    /// waits resolved; this only records them.
    private func recordResolvedWaits(_ resolved: [AgentRow], at now: Date) {
        guard !resolved.isEmpty else { return }
        for row in resolved {
            waitHistory.insert(
                ResolvedWait(
                    rowKey: row.rowKey,
                    agent: row.agent,
                    title: row.usefulTask ?? AgentRow.shortProject(row.project),
                    kind: row.waitKind,
                    project: AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project),
                    resolvedAt: now,
                    waitedSeconds: row.waitAgeSeconds
                ),
                at: 0
            )
        }
        if waitHistory.count > Self.maxWaitHistory {
            waitHistory = Array(waitHistory.prefix(Self.maxWaitHistory))
        }
    }

    /// What the recent-wait list costs in stored data, in the panel that shows
    /// it. The numbers come from the ledger itself so the sentence cannot drift
    /// away from the retention it describes.
    var waitHistoryRetentionLine: String {
        String(
            format: tr(.historyRetention),
            AttentionLedger.retentionDays,
            AttentionLedger.maxEvents
        )
    }

    func clearWaitHistory() {
        waitHistory = []
        attentionLedger.clearResolved()
        attentionLedger.save()
    }

    func clearWaiting() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // 0.95: extinguish delivery synchronously so a queued banner cannot
        // fire after the user already cleared Waiting.
        pendingWaitingNotifications.removeAll()
        for row in cachedAll where row.waiting {
            attentionLedger.acknowledge(rowKey: row.rowKey, nowMs: nowMs)
            if row.waitSignal == .pending || row.skill == "pending" {
                dismissedPendingKeys.insert(row.rowKey)
            }
        }
        attentionLedger.save()
        persistDismissedPendingKeys()
        AttentionIO.clearAll()
        refresh(reason: "clearWaiting")
    }

    /// Live Waiting-none session — needs Attention Reach, not a fake Waiting chip.
    func isWaitingNoneNeedsReach(_ row: AgentRow) -> Bool {
        !row.waiting
            && row.liveProcess
            && row.agent.waitingSource == .none
    }

    /// Open Waiting signals focused on this Waiting-none agent (0.94 Proof).
    func openWaitingReach(for row: AgentRow) {
        openSettings(
            focusWaitingSignals: true,
            focusWaitingAgent: row.agent.waitingSource == .none ? row.agent : firstLiveWaitingNoneAgent
        )
    }

    func localizedWaitKind(_ kind: String) -> String {
        switch kind {
        case "Permission": return tr(.kindPermission)
        case "Input": return tr(.kindInput)
        case "Waiting": return tr(.kindWaiting)
        case "": return tr(.needsYou)
        default: return kind
        }
    }

    /// The row that has been blocked longest, if any.
    ///
    /// Rows arrive sorted oldest-wait-first, so this is the top of the list —
    /// but the lookup does not rely on that, because a caller reaching for
    /// "the most urgent thing" should not silently depend on sort order.
    var oldestWait: AgentRow? {
        cachedAll
            .filter { $0.waiting && $0.waitSinceMs > 0 }
            .min { $0.waitSinceMs < $1.waitSinceMs }
            ?? cachedAll.first(where: \.waiting)
    }

    /// Focus the longest-outstanding wait. One step from "something needs me"
    /// to the waiting row (and best Focus handle when one exists).
    func focusOldestWait() {
        guard let row = oldestWait else { return }
        DebugLog.write("jump to oldest wait \(DebugLog.key(row.rowKey))")
        focusAgent(idRaw: row.agent.rawValue, session: row.sessionID, rowKey: row.rowKey)
    }

    /// "Today: 4 interruptions, 6m average wait" — built from the wait history
    /// already kept for the Settings list. A single line, not a dashboard:
    /// `EXPERIENCE.md` rules out a stats panel and this does not become one.
    var interruptionsTodayLine: String? {
        let calendar = Calendar.current
        let today = waitHistory.filter { calendar.isDateInToday($0.resolvedAt) }
        guard !today.isEmpty else { return nil }
        let mean = today.reduce(0.0) { $0 + $1.waitedSeconds } / Double(today.count)
        return String(
            format: tr(.interruptionsToday),
            today.count,
            durationLabel(seconds: mean)
        )
    }

    /// "12m ago" for a row's last activity, or "no activity yet".
    func lastActivityLabel(_ row: AgentRow) -> String {
        guard row.harvestMs > 0 || row.activityChangedMs > 0 else { return "" }
        let secs = row.lastActivitySeconds
        // "54s ago" reads as precision the number does not have — the panel
        // rescans every few seconds and nobody acts on the difference between
        // 40 and 54 seconds. Below a minute it is simply recent.
        if secs < 60 { return tr(.durNow) }
        return String(format: tr(.agoFormat), durationLabel(seconds: secs))
    }

    /// Second line of a row: where it is and how long since it moved.
    ///
    /// 0.92 Row Clarity — story owns “what is this session doing?” (phase /
    /// tool gist / Changed). Context yields last-action when story already
    /// carries it, so the secondary line stays where · age.
    ///
    /// Only for live rows: on a finished session the last tool it touched is
    /// history, not status, and would read as though it were still going.
    func rowContextLine(_ row: AgentRow, omitPath: Bool = false) -> String {
        if row.isProcessOnly {
            var bits: [String] = []
            let path = row.displayPath
            if !path.isEmpty, !omitPath { bits.append(path) }
            // Process-only is still useful liveness evidence. Explain how the
            // row was found. Hero already states the activity-feed gap — do not
            // repeat "activity unavailable" on the secondary line.
            if let evidence = row.processEvidence {
                bits.append(
                    evidence == .pathSignature
                        ? tr(.supportDetectedPath)
                        : tr(.supportDetectedExecutable)
                )
            }
            return bits.joined(separator: " · ")
        }
        var bits: [String] = []
        let path = row.displayPath
        if !path.isEmpty, !omitPath { bits.append(path) }
        // A completed/recent session still benefits from the last meaningful
        // action — unless the story line already owns that fact (0.92).
        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        // EXPERIENCE skips last-action when the hero is already that tool —
        // unless a project heading omitted the path, which would leave an
        // age-only secondary (0.81 Tray Substance).
        let heroIsToolOnly = row.usefulTask == nil && row.hasLiveToolFallback
        let storyOwnsAction = storyOwnsLastAction(row)
        if !tool.isEmpty, usefulAction(tool), !heroIsToolOnly || omitPath, !storyOwnsAction {
            bits.append(String(format: tr(.lastAction), readableAction(tool)))
        }
        let ago = lastActivityLabel(row)
        if !ago.isEmpty { bits.append(String(format: tr(.lastActive), ago)) }
        let age = row.sessionAgeSeconds(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        // EXPERIENCE 次行右端: "始于…" when known. Cap at 24h so ancient store
        // timestamps do not pretend to be runtime state (0.80 Tray Legibility).
        if age >= 60, age <= 24 * 60 * 60 {
            bits.append(String(
                format: tr(.sessionAge),
                DurationFormat.label(seconds: age, lang: lang)
            ))
        }
        if row.liveProcess, row.agent.waitingSource == .none {
            bits.append(tr(.supportWaitingNone))
        }
        // Heading ate the path and there is no tool action → restore path so
        // the secondary line is not age chrome alone.
        if omitPath, !path.isEmpty, tool.isEmpty || storyOwnsAction {
            if !bits.contains(path) { bits.insert(path, at: 0) }
        }
        // Empty secondary is honest. Agent name already sits on the identity
        // line — repeating it here is EXPERIENCE-forbidden empty chrome.
        return bits.joined(separator: " · ")
    }

    /// Explicit lifecycle state only. A historical last tool is deliberately
    /// excluded: it belongs in `rowContextLine` as "Last action", never under
    /// a "Now" label.
    func rowNowLine(_ row: AgentRow) -> String {
        guard !row.waiting else { return "" }
        if let failure = readableFailure(row.outcome) {
            return String(format: tr(.outcomeActivity), failure)
        }
        if row.isRecentOnly {
            if row.isCompletedPhase {
                return String(format: tr(.outcomeActivity), tr(.phaseTurnComplete))
            }
            // A collector can expose a concrete phase without a matching
            // local process. Show it only while the row is genuinely fresh;
            // otherwise an old "reading" event would look like work happening
            // now after the session has gone quiet.
            guard row.lastActivitySeconds <= 30 * 60,
                  let phase = readablePhase(row.phase, waiting: row.waiting) else { return "" }
            return String(format: tr(.nowActivity), phase)
        }
        guard let phase = readablePhase(row.phase, waiting: row.waiting) else { return "" }
        return String(format: tr(.nowActivity), phase)
    }

    func rowActivityChange(_ row: AgentRow) -> String {
        guard !row.waiting, let change = row.activityChange else { return "" }
        let detail: String
        switch change {
        case .errors(let count):
            detail = String(format: tr(.newErrors), count)
        case .files(let count):
            detail = String(format: tr(.newFiles), count)
        case .progress(let done, let total):
            detail = String(format: tr(.progressAdvanced), done, total)
        case .modelCall:
            detail = tr(.modelCallChanged)
        case .toolChanged:
            detail = tr(.toolChanged)
        case .phaseChanged:
            detail = tr(.phaseChanged)
        case .taskChanged:
            detail = tr(.taskChanged)
        case .completed:
            detail = tr(.phaseTurnComplete)
        case .failed:
            detail = tr(.outcomeFailed)
        case .cancelled:
            detail = tr(.outcomeCancelled)
        }
        return String(format: tr(.activityChanged), detail)
    }

    /// EXPERIENCE 行叙事（0.91 / 0.92）— one scannable sentence answering
    /// “what is this session doing / why is it on the tray”.
    /// Composes existing fields only; never invents Waiting or fake Now.
    /// 0.92: story owns phase / tool gist / Changed; Waiting yields kind·duration
    /// to the chip; Limited opaque story carries age · strongest · nextStep once.
    func rowStoryLine(_ row: AgentRow) -> String {
        // A remote row's story is the only honest thing there is to say about
        // it: when we last heard, and whether we have stopped hearing. It
        // takes precedence over every local template, none of which it can
        // support with evidence.
        if row.isRemote, let line = remoteStatusLine(row) { return line }
        // 1.2: an agent calling the same tool back to back is busy without
        // being any closer to done. The lamp cannot say that — it is running
        // and its clock is moving — and a window could never see it, because
        // the repetition is spread through the part of the transcript that was
        // never read. It outranks the ordinary story: "what it is doing" is
        // less useful than "it has been doing this five times".
        if row.isLooping, !row.waiting {
            return String(format: tr(.loopingTool), row.loopTool, row.loopCount)
        }
        if row.waiting {
            // Chip owns kind · duration; wait detail owns the message (0.92).
            // Story only surfaces the signal source when there is no message.
            let msg = row.waitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty { return "" }
            if let signal = row.waitSignal {
                return signal == .hooks ? tr(.signalHooks) : tr(.signalPending)
            }
            return ""
        }

        if row.isProcessOnly || (row.quality.isLimited && row.usefulTask == nil && row.tool.isEmpty) {
            return opaqueObservationStory(row)
        }

        var bits: [String] = []
        // Prefer explicit lifecycle — never promote last tool under a Now label.
        if let phase = readablePhase(row.phase, waiting: row.waiting), !row.isRecentOnly || row.lastActivitySeconds <= 30 * 60 {
            bits.append(phase)
        } else if row.isStalled {
            bits.append(tr(.stalled))
        }

        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let heroIsToolOnly = row.usefulTask == nil && row.hasLiveToolFallback
        if bits.isEmpty, !tool.isEmpty, usefulAction(tool), !heroIsToolOnly {
            // Quiet live: last action is history, not Now (0.91 / 0.82 honesty).
            bits.append(String(format: tr(.lastAction), readableAction(tool)))
        } else if !bits.isEmpty, !tool.isEmpty, usefulAction(tool), !heroIsToolOnly {
            // Phase known — append humanized tool as companion, not as Now.
            let action = readableAction(tool)
            if !action.isEmpty, !bits.contains(action) {
                bits.append(action)
            }
        }

        if let change = row.activityChange {
            let compact = rowSignalChange(row)
            if !compact.isEmpty, !bits.contains(compact) {
                bits.append(compact)
            } else if change == .toolChanged || change == .phaseChanged || change == .taskChanged {
                let full = rowActivityChange(row)
                if !full.isEmpty { bits.append(full) }
            }
        }

        if bits.isEmpty {
            if row.agent.waitingSource == .none, row.liveProcess {
                return tr(.supportWaitingNoneDetail)
            }
            // 0.96: observation line owns model/tokens — do not duplicate.
            return ""
        }

        return bits.prefix(3).joined(separator: " · ")
    }

    /// Cache / process Limited story — evidence age · strongest fact · nextStep.
    /// Still Limited; never invents Now or Waiting; never upgrades to session.
    private func opaqueObservationStory(_ row: AgentRow) -> String {
        var bits: [String] = []
        if row.isProcessOnly, row.processStartedMs > 0 {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let age = max(0, Double(nowMs - row.processStartedMs) / 1000.0)
            bits.append(String(
                format: tr(.processAge),
                DurationFormat.label(seconds: age, lang: lang)
            ))
        } else {
            let ago = lastActivityLabel(row)
            if !ago.isEmpty {
                bits.append(String(format: tr(.lastActive), ago))
            } else if row.quality.freshnessMs > 0 {
                let ageSec = max(
                    0,
                    Double(Int64(Date().timeIntervalSince1970 * 1000) - row.quality.freshnessMs) / 1000.0
                )
                if ageSec >= 0 {
                    bits.append(String(
                        format: tr(.lastActive),
                        ageSec < 60 ? tr(.durNow) : durationLabel(seconds: ageSec)
                    ))
                }
            }
        }

        let model = readableModel(row.model)
        if !model.isEmpty {
            bits.append(String(format: tr(.modelFact), model))
        } else {
            let input = AgentRow.compactToken(row.tokensIn)
            let output = AgentRow.compactToken(row.tokensOut)
            if !input.isEmpty || !output.isEmpty {
                bits.append(String(
                    format: tr(.compactTokens),
                    input.isEmpty ? "0" : input,
                    output.isEmpty ? "0" : output
                ))
            } else if let evidence = row.processEvidence {
                bits.append(
                    evidence == .pathSignature
                        ? tr(.supportDetectedPath)
                        : tr(.supportDetectedExecutable)
                )
            } else if row.isProcessOnly {
                bits.append(tr(.limitedData))
            }
        }

        if let gap = row.quality.missing.first {
            let next = observationGapNextStep(gap)
            if !bits.contains(next) { bits.append(next) }
        } else if row.isProcessOnly {
            let next = tr(.qualityNextOpenAgent)
            if !bits.contains(next) { bits.append(next) }
        }

        let joined = bits.prefix(3).joined(separator: " · ")
        return joined.isEmpty ? observationQualitySummary(row) : joined
    }

    /// True when `rowStoryLine` will carry last-action / tool gist for this row.
    func storyOwnsLastAction(_ row: AgentRow) -> Bool {
        guard !row.waiting else { return false }
        if row.isProcessOnly || (row.quality.isLimited && row.usefulTask == nil && row.tool.isEmpty) {
            return false
        }
        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let heroIsToolOnly = row.usefulTask == nil && row.hasLiveToolFallback
        guard !tool.isEmpty, usefulAction(tool), !heroIsToolOnly else { return false }
        return true
    }

    /// True when story already narrates lifecycle phase (signal yields Now).
    func storyOwnsNow(_ row: AgentRow) -> Bool {
        guard !row.waiting else { return false }
        if row.isProcessOnly || (row.quality.isLimited && row.usefulTask == nil && row.tool.isEmpty) {
            return false
        }
        if row.isStalled { return true }
        if let _ = readablePhase(row.phase, waiting: row.waiting), !row.isRecentOnly || row.lastActivitySeconds <= 30 * 60 {
            return true
        }
        return false
    }

    /// True when story already carries the Changed compact (signal yields).
    func storyOwnsChange(_ row: AgentRow) -> Bool {
        guard !row.waiting, row.activityChange != nil else { return false }
        if row.isProcessOnly || (row.quality.isLimited && row.usefulTask == nil && row.tool.isEmpty) {
            return false
        }
        return true
    }

    /// Limited quality summary rides on story — identity tag stays short (0.92).
    func rowSourceLabel(_ row: AgentRow) -> String? {
        switch row.observationSource {
        case .session: return nil
        case .cache:
            return tr(.cacheEvidence)
        case .process:
            return tr(.limitedData)
        case .remote:
            // Name the machine. "Remote host" alone tells the user the one
            // thing they already guessed and withholds the one they need.
            return row.host.isEmpty ? tr(.remoteEvidence) : "\(tr(.remoteEvidence)) · \(row.host)"
        }
    }

    /// The line a remote row gets instead of "last activity".
    ///
    /// A local row's clock comes from the process table and the session file.
    /// A remote row has neither: all Pulse can honestly report is when it last
    /// heard anything, and — once that goes quiet — that it has stopped.
    func remoteStatusLine(_ row: AgentRow, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String? {
        guard row.isRemote else { return nil }
        var parts: [String] = []
        if row.lastHeardMs > 0 {
            let age = durationLabel(seconds: Double(max(0, nowMs - row.lastHeardMs)) / 1000.0)
            parts.append(String(format: tr(.remoteLastHeard), age))
        }
        if row.lostContact { parts.append(tr(.remoteLostContact)) }
        if row.clockSuspect { parts.append(tr(.remoteClockSuspect)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The single strongest progress fact for this row.
    ///
    /// `EXPERIENCE.md` used to send tokens, sub-agent progress and skill to a
    /// hover overlay, on a rule written when a row was cramming ten facts into
    /// two lines. That rule over-corrected: rows ended up carrying two facts,
    /// both of them static — a session title fixed for the session's life, and
    /// a path. Everything that moves while work happens was one hover and one
    /// action-menu click away, so the panel was only observable on demand.
    ///
    /// These ride on the right of the context line, in the space that line was
    /// already wasting, so density costs no height.
    func rowMetrics(_ row: AgentRow) -> String {
        // Nothing at all on a waiting row.
        //
        // 0.28.0's notes said "waiting rows do not carry these", and only
        // tokens were actually suppressed — age, records and sub-agent
        // progress all still appeared beside the one thing that needs an
        // answer. The rule is the right one; it just was not implemented.
        guard !row.waiting else { return "" }
        if row.isProcessOnly, row.processStartedMs > 0 {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let age = max(0, Double(nowMs - row.processStartedMs) / 1000.0)
            var process = String(
                format: tr(.processAge),
                DurationFormat.label(seconds: age, lang: lang)
            )
            if row.processCount > 1 {
                process += " · " + String(format: tr(.processCount), row.processCount)
            }
            return process
        }
        // A single-priority metric made the row look empty for most adapters:
        // progress hid tokens, files hid context, and a model call hid the
        // only failure. Keep one line, but carry the two strongest independent
        // signals so every supported agent has a useful default glance.
        var facts: [String] = []
        let change = row.activityChange
        if row.errors > 0, !isErrorChange(change) {
            facts.append(row.errors == 1
                ? tr(.errorFactOne)
                : String(format: tr(.errorsFact), row.errors))
        }
        if let outcome = readableFailure(row.outcome), !isFailureChange(change) { facts.append(outcome) }
        if row.progressTotal > 0, !isProgressChange(change) {
            facts.append(String(format: tr(.progressFact), row.progressDone, row.progressTotal))
        } else if row.progressDone > 0, !isProgressChange(change) {
            facts.append(String(format: tr(.turnsFact), row.progressDone))
        }
        if row.subTotal > 0 {
            facts.append(row.subRunning > 0
                ? String(format: tr(.subagentsActive), row.subRunning, row.subTotal)
                : String(format: tr(.subagentsObserved), row.subTotal))
        }
        if row.files > 0, !isFilesChange(change) { facts.append(String(format: tr(.filesFact), row.files)) }
        if row.contextPercent > 0 { facts.append(String(format: tr(.contextFact), row.contextPercent)) }
        let input = AgentRow.compactToken(row.tokensIn)
        let output = AgentRow.compactToken(row.tokensOut)
        if !input.isEmpty || !output.isEmpty {
            let scope: L10n.Key = [.claude, .codex].contains(row.agent)
                ? .latestCallTokens
                : .reportedTokens
            facts.append(String(
                format: tr(scope),
                input.isEmpty ? "0" : input,
                output.isEmpty ? "0" : output
            ))
        }
        if row.records > 0 { facts.append("\(row.records)\(tr(.recordsSuffix))") }
        return facts.prefix(2).joined(separator: " · ")
    }

    /// One bounded **motion** line: Now / Changed / stalled age / multi-process.
    /// Model, tokens, and durable progress live on `rowObservationLine` so the
    /// default tray can show both without a single truncated scan line (0.80).
    /// 0.92: yields Now / Changed when `rowStoryLine` already carries them.
    func rowSignalLine(_ row: AgentRow) -> String {
        guard !row.waiting else { return "" }
        let lifecycle = storyOwnsNow(row)
            ? ""
            : rowNowLine(row).trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = storyOwnsChange(row)
            ? ""
            : rowSignalChange(row).trimmingCharacters(in: .whitespacesAndNewlines)
        var bits: [String] = []
        if !lifecycle.isEmpty { bits.append(lifecycle) }
        if !changed.isEmpty {
            bits.append(changed)
            // Urgent companion only — durable model/tokens belong on observation.
            if row.errors > 0, !isErrorChange(row.activityChange) {
                bits.append(row.errors == 1
                    ? tr(.errorFactOne)
                    : String(format: tr(.errorsFact), row.errors))
            }
        }
        if row.isStalled {
            let metric = rowSignalMetric(row).trimmingCharacters(in: .whitespacesAndNewlines)
            if !metric.isEmpty, !bits.contains(metric) { bits.append(metric) }
        }
        // Process-only age · nextStep live on opaque story (0.92) — signal yields.
        if row.liveProcess, !row.isProcessOnly, row.processCount > 1 {
            bits.append(String(format: tr(.processCount), row.processCount))
        }
        // EXPERIENCE: motion line disappears when empty — never invent chrome.
        return bits.prefix(3).joined(separator: " · ")
    }

    /// Compact counterpart to the full change sentence used by accessibility
    /// and diagnostics. The default row has a single-line width budget, so a
    /// terse phase/count label keeps the numeric evidence at the end visible.
    private func rowSignalChange(_ row: AgentRow) -> String {
        guard !row.waiting, let change = row.activityChange else { return "" }
        switch change {
        case .errors(let count):
            return String(format: tr(.signalErrors), count)
        case .files(let count):
            return String(format: tr(.signalFiles), count)
        case .progress(let done, let total):
            return String(format: tr(.signalProgress), done, total)
        case .modelCall:
            return tr(.signalModel)
        case .toolChanged:
            return tr(.signalTool)
        case .phaseChanged:
            return tr(.signalPhase)
        case .taskChanged:
            return tr(.signalTask)
        case .completed:
            return tr(.signalCompleted)
        case .failed:
            return tr(.signalFailed)
        case .cancelled:
            return tr(.signalCancelled)
        }
    }

    /// A compact, priority-ordered metric for the one-line live signal. The
    /// full `rowMetrics` string remains available to accessibility and the
    /// expanded detail surface; this version keeps the default tray glance
    /// from truncating its only numeric evidence after a long change label.
    private func rowSignalMetric(_ row: AgentRow) -> String {
        guard !row.waiting else { return "" }
        if row.isProcessOnly, row.processStartedMs > 0 {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let age = max(0, Double(nowMs - row.processStartedMs) / 1000.0)
            var process = String(
                format: tr(.processAge),
                DurationFormat.label(seconds: age, lang: lang)
            )
            if row.processCount > 1 {
                process += " · " + String(format: tr(.processCount), row.processCount)
            }
            return process
        }
        if row.isStalled {
            let seconds = row.lastActivitySeconds
            if seconds > 0 {
                return String(format: tr(.stalledFor), durationLabel(seconds: seconds))
            }
            return tr(.noActivityYet)
        }
        let change = row.activityChange
        if row.errors > 0, !isErrorChange(change) {
            return row.errors == 1
                ? tr(.errorFactOne)
                : String(format: tr(.errorsFact), row.errors)
        }
        if let outcome = readableFailure(row.outcome), !isFailureChange(change) {
            return outcome
        }
        if row.progressTotal > 0, !isProgressChange(change) {
            return String(format: tr(.progressFact), row.progressDone, row.progressTotal)
        }
        if row.progressDone > 0, !isProgressChange(change) {
            return String(format: tr(.turnsFact), row.progressDone)
        }
        if row.subTotal > 0 {
            return row.subRunning > 0
                ? String(format: tr(.subagentsActive), row.subRunning, row.subTotal)
                : String(format: tr(.subagentsObserved), row.subTotal)
        }
        if row.files > 0, !isFilesChange(change) {
            return String(format: tr(.filesFact), row.files)
        }
        if row.contextPercent > 0 {
            return String(format: tr(.contextFact), row.contextPercent)
        }
        let input = AgentRow.compactToken(row.tokensIn)
        let output = AgentRow.compactToken(row.tokensOut)
        if !input.isEmpty || !output.isEmpty {
            return String(format: tr(.compactTokens), input.isEmpty ? "0" : input, output.isEmpty ? "0" : output)
        }
        return ""
    }

    private func isErrorChange(_ change: AgentActivityChange?) -> Bool {
        if case .errors = change { return true }
        return false
    }

    private func isFilesChange(_ change: AgentActivityChange?) -> Bool {
        if case .files = change { return true }
        return false
    }

    private func isProgressChange(_ change: AgentActivityChange?) -> Bool {
        if case .progress = change { return true }
        return false
    }

    private func isFailureChange(_ change: AgentActivityChange?) -> Bool {
        if case .failed = change { return true }
        return false
    }

    /// EXPERIENCE 观测行 — default tray surface, max 4 facts.
    /// Example: model · in/out tokens · strongest progress · records.
    /// Never invents chrome when empty; never Details-only (0.80).
    func rowObservationLine(_ row: AgentRow) -> String {
        guard !row.waiting, !row.isProcessOnly else { return "" }
        var facts: [String] = []
        let model = readableModel(row.model)
        if !model.isEmpty { facts.append(String(format: tr(.modelFact), model)) }
        let mode = readableMode(row.mode)
        if !mode.isEmpty { facts.append(mode) }
        let input = AgentRow.compactToken(row.tokensIn)
        let output = AgentRow.compactToken(row.tokensOut)
        if !input.isEmpty || !output.isEmpty {
            facts.append(String(
                format: tr(.compactTokens),
                input.isEmpty ? "0" : input,
                output.isEmpty ? "0" : output
            ))
        }
        let change = row.activityChange
        // Errors already ride the motion line as an urgent companion when a
        // change is present — do not spend an observation slot on the same fact.
        if row.errors > 0, !isErrorChange(change), change == nil {
            facts.append(row.errors == 1
                ? tr(.errorFactOne)
                : String(format: tr(.errorsFact), row.errors))
        } else if row.subTotal > 0 {
            facts.append(row.subRunning > 0
                ? String(format: tr(.subagentsActive), row.subRunning, row.subTotal)
                : String(format: tr(.subagentsObserved), row.subTotal))
        } else if row.progressTotal > 0, !isProgressChange(change) {
            facts.append(String(format: tr(.progressFact), row.progressDone, row.progressTotal))
        } else if row.progressDone > 0, !isProgressChange(change) {
            facts.append(String(format: tr(.turnsFact), row.progressDone))
        } else if row.files > 0, !isFilesChange(change) {
            facts.append(String(format: tr(.filesFact), row.files))
        } else if row.contextPercent > 0 {
            facts.append(String(format: tr(.contextFact), row.contextPercent))
        }
        let skill = readableSkill(row.skill)
        if facts.count < 4, !skill.isEmpty { facts.append(skill) }
        // Records are last-resort filler when no stronger progress-class fact
        // earned a slot (0.80 — never crowd model/tokens/context).
        let hasProgressClass = row.errors > 0 || row.subTotal > 0
            || row.progressTotal > 0 || row.progressDone > 0
            || row.files > 0 || row.contextPercent > 0
        if facts.count < 4, !hasProgressClass, row.records > 0 {
            facts.append(String(row.records) + tr(.recordsSuffix))
        }
        return facts.prefix(4).joined(separator: " · ")
    }

    /// The most recent tool a live row recorded — not necessarily one still
    /// executing.
    ///
    /// The wire column is `last_tool`, and the harvest reads it from whatever
    /// the transcript wrote most recently, which includes a `tool_result`.
    /// Calling it "running" would claim a process state nothing here observes,
    /// and the row already has a badge for actual state.
    ///
    /// `sessionDetail` promotes `tool` to the hero when there is no task, so
    /// showing it again here would be the same word twice on two lines.
    /// Humanized live-tool hero when harvest has no real session title.
    /// Returns nil for empty tools; always humanizes (Bash → Running command).
    func heroToolTitle(_ row: AgentRow) -> String? {
        guard row.usefulTask == nil, row.hasLiveToolFallback else { return nil }
        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { return nil }
        return readableAction(tool)
    }

    func liveTool(_ row: AgentRow) -> String? {
        guard row.liveProcess || row.subRunning > 0, !row.waiting else { return nil }
        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty, row.usefulTask != nil else { return nil }
        return tool
    }

    /// Any tool that humanizes to a non-empty label earns the context-line
    /// last-action slot. A keyword whitelist previously dropped LS/Task/Agent
    /// and left running Claude rows without a middle fact (0.81).
    private func usefulAction(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !readableAction(trimmed).isEmpty
    }

    private func readablePhase(_ raw: String, waiting: Bool = false) -> String? {
        let low = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if low.isEmpty { return nil }
        if low.contains("permission") {
            return waiting ? tr(.phaseWaitingPermission) : tr(.phaseWorking)
        }
        if low.contains("turn_complete") || low == "completed" || low == "complete" {
            return tr(.phaseTurnComplete)
        }
        if low.contains("stream") || low.contains("respond") || low.contains("generat") {
            return tr(.phaseResponding)
        }
        if low.contains("test") || low.contains("verify") || low.contains("check") {
            return tr(.phaseTesting)
        }
        if low.contains("build") { return tr(.phaseBuilding) }
        if low.contains("publish") || low.contains("release") || low.contains("push") {
            return tr(.phasePublishing)
        }
        if low.contains("plan") { return tr(.phasePlanning) }
        if low.contains("search") || low.contains("research") { return tr(.actionResearch) }
        if low.contains("read") { return tr(.actionReading) }
        if low.contains("edit") || low.contains("write") { return tr(.actionEditing) }
        if low == "working" || low == "running" || low.contains("execut")
            || low == "in_progress" || low == "inprogress"
            || low == "active" || low == "busy" || low == "thinking"
            || low == "depending" {
            return tr(.phaseWorking)
        }
        // Unknown vendor phases remain hidden rather than leaking raw
        // implementation labels into the default row.
        return nil
    }

    private func readableMode(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.caseInsensitiveCompare("local") == .orderedSame { return "" }
        value = value
            .replacingOccurrences(of: "grok-", with: "", options: [.caseInsensitive, .anchored])
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return value.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func readableModel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: " ")
    }

    private func readableSkill(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.lowercased() != "pending" else { return "" }
        // Package names and registry namespaces are implementation detail. A
        // skill earns default-row space only when its explicit invocation maps
        // to a user-recognisable workflow role; everything else stays in
        // diagnostics so `product-design:audit` never becomes a mysterious
        // "Skill audit" badge.
        let low = value.lowercased()
        if low.contains("plan") || low.contains("todo") {
            return tr(.actionPlanning)
        }
        if low.contains("research") || low.contains("browser") || low.contains("web") {
            return tr(.actionResearch)
        }
        if low.contains("test") || low.contains("verify") || low.contains("check") {
            return tr(.phaseTesting)
        }
        if low.contains("build") || low.contains("compile") || low.contains("package") {
            return tr(.phaseBuilding)
        }
        if low.contains("edit") || low.contains("patch") || low.contains("write") {
            return tr(.actionEditing)
        }
        if low.contains("publish") || low.contains("release") || low.contains("deploy") {
            return tr(.phasePublishing)
        }
        if low.contains("image") || low.contains("screenshot") {
            return tr(.actionImage)
        }
        // An unknown skill can still be the only capability evidence for a
        // vendor adapter. Keep the namespace/path and implementation noise
        // out of the row, but expose a safe leaf such as "Workflow Audit" or
        // "Workflow Agents SDK" rather than silently losing the signal.
        let ignored = Set(["skill", "skills", "default", "unknown", "none", "server", "tool"])
        let label = safeIdentifier(value)
        guard !label.isEmpty, !ignored.contains(label.lowercased()) else { return "" }
        return String(format: tr(.skillFact), label)
    }

    private func readableFailure(_ raw: String) -> String? {
        let low = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if low.contains("fail") || low.contains("error") { return tr(.outcomeFailed) }
        if low.contains("cancel") || low.contains("abort") { return tr(.outcomeCancelled) }
        return nil
    }

    /// Translate implementation-level tool identifiers into an action a
    /// person can scan. This is intentionally phrased as the *last* action:
    /// harvest observes an event, not whether that action is still executing.
    private func readableAction(_ raw: String) -> String {
        let tool = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = tool.lowercased()
        if low.contains("plan") || low.contains("todo") { return tr(.actionPlanning) }
        if low.contains("patch") || low.contains("edit") || low.contains("write") {
            return tr(.actionEditing)
        }
        if low.contains("image") || low.contains("screenshot") {
            return tr(.actionImage)
        }
        if low.contains("search") || low.contains("web") || low.contains("browser") {
            return tr(.actionResearch)
        }
        if low.contains("read") || low.contains("glob") || low.contains("grep") {
            return tr(.actionReading)
        }
        if low.contains("test") || low.contains("verify") || low.contains("check") {
            return tr(.phaseTesting)
        }
        if low.contains("build") || low.contains("compile") || low.contains("package") {
            return tr(.phaseBuilding)
        }
        if low.contains("publish") || low.contains("release") || low.contains("deploy") {
            return tr(.phasePublishing)
        }
        if low == "exec" || low.contains("command") || low == "bash" || low == "shell"
            || low.contains("batch_execute") {
            return tr(.actionCommand)
        }
        if low == "js" || low.contains("automation") || low.contains("computer") {
            return tr(.actionAutomation)
        }
        return safeIdentifier(tool)
    }

    /// Turn an unrecognised vendor identifier into a bounded, safe label.
    /// Namespaces and paths are implementation detail; the leaf still carries
    /// useful capability information, while filtering prevents raw URLs,
    /// private paths, or arbitrary punctuation from entering the default UI.
    private func safeIdentifier(_ raw: String, maxLength: Int = 32) -> String {
        let leaf = raw
            .split(whereSeparator: { $0 == ":" || $0 == "/" || $0 == "\\" || $0 == "." })
            .last
            .map(String.init) ?? raw
        let normalized = leaf
            .replacingOccurrences(of: "__", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let filtered = String(normalized.map { character in
            character.isLetter || character.isNumber || character.isWhitespace ? character : " "
        })
        let words = filtered.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return "" }
        let title = words.map { word -> String in
            guard let first = word.first else { return "" }
            return String(first).uppercased() + word.dropFirst()
        }.joined(separator: " ")
        guard !title.isEmpty else { return "" }
        return String(title.prefix(maxLength))
    }

    /// Human wait age in the resolved language (`2 分` / `2m`).
    func waitDurationLabel(_ row: AgentRow) -> String {
        guard row.waitSinceMs > 0 else { return "" }
        return durationLabel(seconds: row.waitAgeSeconds)
    }

    func durationLabel(seconds ago: Double) -> String {
        DurationFormat.label(seconds: ago, lang: lang)
    }

    /// Rebuild wait detail under the badge: message-first (0.92).
    /// Kind · duration live on the chip; story may carry signal when no message.
    /// Returns nil when there is nothing beyond the badge label.
    func localizedWaitDetail(_ row: AgentRow) -> String? {
        guard row.waiting else { return nil }
        let msg = row.waitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !msg.isEmpty {
            if let sig = row.waitSignal {
                let src = sig == .hooks ? tr(.signalHooks) : tr(.signalPending)
                return "↳ \(msg) · \(src)"
            }
            return "↳ \(msg)"
        }
        // No message — signal may already sit on the story line; do not repeat.
        return nil
    }

    /// Full wait line (kind + detail) — used by glance / a11y.
    func localizedWaitLine(_ row: AgentRow) -> String {
        guard row.waiting else { return "" }
        let kind = row.waitKind.isEmpty ? tr(.needsYou) : localizedWaitKind(row.waitKind)
        if let detail = localizedWaitDetail(row) {
            // detail already has ↳ — splice kind after arrow when present
            let rest = String(detail.dropFirst(2)) // drop "↳ "
            return "↳ \(kind) · \(rest)"
        }
        return "↳ \(kind)"
    }

    func focusActionTitle(_ row: AgentRow) -> String {
        switch row.focusTier {
        case .tty: return tr(.focusTTY)
        case .warp: return tr(.focusWarp)
        case .hostWorkspace(let kind):
            return String(format: tr(.focusHostWorkspace), kind.displayName)
        case .hostApp(let kind):
            return String(format: tr(.focusHostApp), kind.displayName)
        case .none:
            // No handle — never advertise "Focus terminal" for cwd-only rows.
            return tr(.focusOpenTray)
        }
    }

    func primaryActionTitle(_ row: AgentRow) -> String {
        if row.canFocusTerminal { return focusActionTitle(row) }
        return tr(.moreActions)
    }

    /// Support Health Focus fact — observation-only when nothing is clickable.
    func supportFocusDetail(_ health: AgentSupportHealth) -> String {
        if let tier = health.focusTier {
            switch tier {
            case .warp: return tr(.supportFocusWarp)
            case .hostWorkspace(let kind):
                return String(format: tr(.supportFocusHostWorkspace), kind.displayName)
            case .hostApp(let kind):
                return String(format: tr(.supportFocusHost), kind.displayName)
            case .tty: return tr(.supportFocusTTY)
            }
        }
        if health.focusTTYNeedsOptIn {
            return tr(.supportFocusTTYNeedsOptIn)
        }
        return tr(.supportFocusNone)
    }

    /// Thin vs deep observation — never let a cache/none Agent look session-deep.
    /// Rich cache (goal + workspace/activity) stays Limited but says so honestly.
    /// Waiting-none still exposes harvest depth so ZCode/Trae cannot hide behind
    /// “Waiting unavailable” alone (0.70 Contract Honesty).
    func supportDepthDetail(_ health: AgentSupportHealth) -> String {
        let harvest: String
        switch health.agent.harvestSource {
        case .bestEffortCache:
            let rich = health.hasGoal && (health.hasWorkspace || health.hasActivity)
            harvest = rich ? tr(.supportDepthCachePartial) : tr(.supportDepthCacheThin)
        case .structuredSession:
            harvest = tr(.supportDepthSession)
        }
        if health.agent.waitingSource == .none {
            return "\(tr(.supportDepthWaitingNone)) · \(harvest)"
        }
        return harvest
    }

    /// "Remind me later" — the answer that did not exist.
    ///
    /// A wait had exactly two available responses: deal with it now, or clear
    /// it forever. The most common real one was neither, and fell back on the
    /// user's memory — the thing this app was built to replace.
    func snooze(_ row: AgentRow) {
        let deadline = Date().addingTimeInterval(Double(snoozeMinutes) * 60)
        snoozedUntil[row.rowKey] = deadline
        attentionLedger.snooze(
            rowKey: row.rowKey,
            untilMs: Int64(deadline.timeIntervalSince1970 * 1000)
        )
        attentionLedger.save()
        DebugLog.write("snooze \(DebugLog.key(row.rowKey)) for \(snoozeMinutes)m")
        refresh(reason: "snooze")
    }

    /// Undo a snooze from the row that shows it — a countdown you cannot stop
    /// is a worse deal than no countdown.
    func unsnooze(_ row: AgentRow) {
        guard snoozedUntil.removeValue(forKey: row.rowKey) != nil else { return }
        attentionLedger.unsnooze(rowKey: row.rowKey)
        attentionLedger.save()
        DebugLog.write("unsnooze \(DebugLog.key(row.rowKey))")
        refresh(reason: "unsnooze")
    }

    /// Snooze by row key — the notification banner has a key, not a row.
    func snooze(rowKey: String) {
        guard !rowKey.isEmpty else { return }
        let deadline = Date().addingTimeInterval(Double(snoozeMinutes) * 60)
        snoozedUntil[rowKey] = deadline
        attentionLedger.snooze(
            rowKey: rowKey,
            untilMs: Int64(deadline.timeIntervalSince1970 * 1000)
        )
        attentionLedger.save()
        DebugLog.write("snooze(notif) \(DebugLog.key(rowKey)) for \(snoozeMinutes)m")
        refresh(reason: "snoozeNotification")
    }

    func snoozeLabel(_ row: AgentRow) -> String {
        String(format: tr(.snoozedFor), DurationFormat.label(seconds: row.snoozeRemainingSeconds, lang: lang))
    }

    func dismissWaiting(_ row: AgentRow) {
        let isHarvestPending = row.waitSignal == .pending || row.skill == "pending"
        // 0.95: pure harvest soft-dismiss must not write agent-wide Attention
        // done (empty session clears every wait for that agent).
        if row.waitSignal == .hooks {
            AttentionIO.appendDone(agent: row.agent, session: row.sessionID)
        } else if !isHarvestPending, !row.sessionID.isEmpty {
            AttentionIO.appendDone(agent: row.agent, session: row.sessionID)
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        attentionLedger.acknowledge(rowKey: row.rowKey, nowMs: nowMs)
        attentionLedger.save()
        pendingWaitingNotifications.removeValue(forKey: row.rowKey)
        if isHarvestPending {
            dismissedPendingKeys.insert(row.rowKey)
            persistDismissedPendingKeys()
        }
        refresh(reason: "dismissWaiting")
    }

    func primaryAction(_ row: AgentRow) {
        if row.canFocusTerminal {
            _ = TerminalFocus.focus(row: row)
        }
    }

    func focusTerminal(_ row: AgentRow) {
        _ = TerminalFocus.focus(row: row)
    }

    func focusFirstWaiting() {
        if let row = cachedAll.first(where: \.waiting) ?? snapshot.rows.first(where: \.waiting) {
            focusAgent(idRaw: row.agent.rawValue, session: row.sessionID, rowKey: row.rowKey)
            return
        }
        requestTrayReveal()
    }

    /// Resolve a notify / hotkey / jump target, attempt best Focus, and always
    /// keep tray row identity for Waiting (Go-Look Closure). Focus success must
    /// not abandon the row that raised the interruption.
    func focusAgent(idRaw: String, session: String = "", rowKey: String = "") {
        let row = resolveFocusRow(idRaw: idRaw, session: session, rowKey: rowKey)
        if let row {
            let didFocus = row.canFocusTerminal && TerminalFocus.focus(row: row)
            if row.waiting || !didFocus {
                requestTrayReveal(rowKey: row.rowKey)
            }
            return
        }
        if !rowKey.isEmpty {
            // Stale notify identity: still open the tray so the user is not stranded.
            requestTrayReveal(rowKey: rowKey)
            return
        }
        focusFirstWaiting()
    }

    /// Prefer exact `rowKey`, then session, then first waiting/live row for agent.
    private func resolveFocusRow(idRaw: String, session: String, rowKey: String) -> AgentRow? {
        if !rowKey.isEmpty, let row = cachedAll.first(where: { $0.rowKey == rowKey }) {
            return row
        }
        if !session.isEmpty, let row = cachedAll.first(where: {
            !$0.sessionID.isEmpty && ($0.sessionID == session || session.hasPrefix($0.sessionID))
        }) {
            return row
        }
        guard let id = ActivityHarvest.mapAgent(idRaw) else { return nil }
        return cachedAll.first(where: { $0.agent == id && $0.waiting })
            ?? cachedAll.first(where: { $0.agent == id })
    }

    /// When set, Settings expands the App Data scopes group and highlights
    /// this agent — used by Support Health and quality next-step deep links.
    @Published var settingsFocusAppDataAgent: AgentID? = nil
    @Published var settingsExpandAppDataScopes = false
    /// When true, Settings scrolls/highlights the Waiting signals section
    /// (Attention bridge path for agents without a native Waiting contract).
    @Published var settingsFocusWaitingSignals = false
    /// Waiting-none Agent named when Support deep-links into Attention Reach.
    @Published var settingsFocusWaitingAgent: AgentID? = nil
    /// One-shot tray identity for Go-Look Closure: notify / hotkey / jump
    /// seeds a `rowKey`, TrayPanel selects+scrolls it, then clears.
    @Published private(set) var pendingRevealRowKey: String? = nil

    /// Open the tray, optionally selecting a concrete row after it appears.
    func requestTrayReveal(rowKey: String = "") {
        if !rowKey.isEmpty {
            pendingRevealRowKey = rowKey
        }
        TrayReveal.show()
    }

    func clearPendingRevealRowKey() {
        pendingRevealRowKey = nil
    }

    func openSettings(
        focusAppDataFor agent: AgentID? = nil,
        focusWaitingSignals: Bool = false,
        focusWaitingAgent: AgentID? = nil
    ) {
        settingsFocusAppDataAgent = agent
        if agent != nil {
            settingsExpandAppDataScopes = true
        }
        settingsFocusWaitingSignals = focusWaitingSignals
        settingsFocusWaitingAgent = focusWaitingAgent
        SettingsWindowController.shared.show(
            store: self,
            focusAppDataFor: agent,
            focusWaitingSignals: focusWaitingSignals
        )
    }

    /// Open the Pulse Application Support folder so the Attention bridge path
    /// is one click away — never expands the hook installer past Claude/Codex.
    func revealAttentionBridgeFolder() {
        ensurePulseHookLauncher()
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// Reveal the seeded bridge kit (`raise.sh` / `clear.sh`) under Application Support.
    func revealAttentionBridgeKit() {
        ensurePulseHookLauncher()
        let url = HooksSupport.attentionBridgeKitDir()
        NSWorkspace.shared.open(url)
    }

    /// Write or refresh native `pulse-hook` only — does **not** merge Claude/Codex hooks.
    func ensurePulseHookLauncher() {
        do {
            try HooksInstaller.ensureLauncher()
            HooksInstaller.refreshRunnerPath()
            HooksSupport.seedAttentionBridgeKit()
            refreshPulseHookLauncherStatus()
            DebugLog.write("pulse-hook launcher ensured ready=\(pulseHookLauncherReady)")
        } catch {
            refreshPulseHookLauncherStatus()
            DebugLog.write("pulse-hook launcher ensure failed \(error.localizedDescription)")
        }
    }

    func refreshPulseHookLauncherStatus() {
        pulseHookLauncherReady = FileManager.default.isExecutableFile(
            atPath: HooksInstaller.launcherURL.path
        )
    }

    /// Agents with `waitingSource=.none` — derived from `AgentID.waitingNoneAgents`.
    /// Does not expand the Claude/Codex hook installer.
    nonisolated static var attentionSampleAgents: [AgentID] { AgentID.waitingNoneAgents }

    /// Localized sample hint listing every Waiting-none display name from the
    /// enum — never a hand-maintained seven-name string.
    func attentionBridgeWriteSampleHintText() -> String {
        let names = Self.attentionSampleAgents.map(\.displayName)
        let joined = lang == .zh ? names.joined(separator: "、") : names.joined(separator: ", ")
        let n = names.count
        if lang == .zh {
            return "为全部\(n)个无 Waiting 路径的 Agent（\(joined)）追加 Attention 桥样本。不会把 hook 安装器扩到 Claude/Codex 以外。"
        }
        return "Appends Attention bridge lines for all \(n) Waiting-none Agents (\(joined)). Does not expand the Claude/Codex hook installer."
    }

    func attentionBridgeHintText() -> String {
        let names = Self.attentionSampleAgents.map(\.displayName)
        let joined = lang == .zh ? names.joined(separator: "、") : names.joined(separator: ", ")
        if lang == .zh {
            return "无原生 Waiting 路径的 Agent（\(joined)）请用 pulse-hook / Attention Protocol v1 上报（docs/attention-protocol.md）。hooks 安装器仍只覆盖 Claude / Codex。"
        }
        return "Opaque agents (\(joined)) have no native Waiting path — raise via pulse-hook / Attention Protocol v1 (docs/attention-protocol.md). Hook installer stays Claude/Codex only."
    }

    func attentionBridgeFocusHintText() -> String {
        if let agent = settingsFocusWaitingAgent {
            if lang == .zh {
                return "\(agent.displayName) 无原生 Waiting 路径 — 在此用 pulse-hook / Attention Protocol 上报"
            }
            return "\(agent.displayName) has no native Waiting path — raise here via pulse-hook / Attention Protocol"
        }
        return tr(.attentionBridgeFocusHint)
    }

    func waitingReachStepsText() -> String {
        if let agent = settingsFocusWaitingAgent {
            if lang == .zh {
                return "① 确保 pulse-hook（不装 Claude/Codex）· ② 打开 Attention 文件夹 · ③ 为 \(agent.displayName) 写入样本 Waiting · ④ 托盘应亮红并可清除。不会伪造原生 Waiting。"
            }
            return "1) Ensure pulse-hook (not Claude/Codex install) · 2) Reveal Attention folder · 3) Write sample Waiting for \(agent.displayName) · 4) Tray should go red and stay clearable. Never invents native Waiting."
        }
        if lang == .zh {
            return "① 确保 pulse-hook（不装 Claude/Codex）· ② 打开 Attention 文件夹 · ③ 写入样本 Waiting · ④ 托盘应亮红并可清除。不会伪造原生 Waiting。"
        }
        return "1) Ensure pulse-hook (not Claude/Codex install) · 2) Reveal Attention folder · 3) Write sample Waiting · 4) Tray should go red and stay clearable. Never invents native Waiting."
    }

    func attentionRaiseCommand(for agent: AgentID) -> String {
        let hook = HooksInstaller.launcherURL.path
        let quoted = hook.contains(" ") ? "\"\(hook)\"" : hook
        return "\(quoted) \(agent.rawValue)"
    }

    func copyAttentionRaiseCommand(for agent: AgentID? = nil) {
        let target = agent ?? settingsFocusWaitingAgent ?? firstLiveWaitingNoneAgent ?? .zcode
        ensurePulseHookLauncher()
        let command = attentionRaiseCommand(for: target)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
        didCopyAttentionRaise = true
        DebugLog.write("attention raise command copied agent=\(target.rawValue)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            self?.didCopyAttentionRaise = false
        }
    }

    /// Settings one-click sample Waiting via Attention bridge.
    /// When `agent` is set, only that Waiting-none Agent is raised (Reach funnel).
    func writeAttentionBridgeSample(for agent: AgentID? = nil) {
        ensurePulseHookLauncher()
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path
        let agents: [AgentID]
        if let agent {
            guard agent.waitingSource == .none else { return }
            agents = [agent]
        } else {
            agents = Self.attentionSampleAgents
        }
        for id in agents {
            AttentionIO.appendPermission(
                agent: id,
                message: "Approve tool (sample)",
                session: "pulse-sample",
                cwd: cwd
            )
        }
        DebugLog.write(
            "attention sample written agents=\(agents.map(\.rawValue).joined(separator: ",")) session=pulse-sample"
        )
        pendingSampleRevealSession = "pulse-sample"
        refresh(reason: "attentionSample")
    }

    private func applyPendingSampleReveal() {
        guard !pendingSampleRevealSession.isEmpty else { return }
        if let row = cachedAll.first(where: {
            $0.sessionID == pendingSampleRevealSession && $0.waiting
        }) {
            requestTrayReveal(rowKey: row.rowKey)
            pendingSampleRevealSession = ""
        }
    }

    /// Test seam: sample Go-Look waits until the named session row exists.
    func testingRevealSampleIfPresent(session: String) {
        pendingSampleRevealSession = session
        applyPendingSampleReveal()
    }

    var testingHasPendingSampleReveal: Bool { !pendingSampleRevealSession.isEmpty }

    func clearAttentionBridgeSample() {
        for agent in Self.attentionSampleAgents {
            AttentionIO.appendDone(agent: agent, session: "pulse-sample")
        }
        DebugLog.write(
            "attention sample cleared agents=\(Self.attentionSampleAgents.map(\.rawValue).joined(separator: ",")) session=pulse-sample"
        )
        refresh(reason: "attentionSampleClear")
    }

    func openSupportHealth() {
        SupportCoverageWindowController.shared.show(store: self)
    }

    func openAgentDetail(_ row: AgentRow) {
        AgentDetailWindowController.shared.show(store: self, row: row)
    }

    func quit() {
        markCleanShutdown()
        attentionWatcher.stop()
        GlobalHotKey.uninstall()
        NSApp.terminate(nil)
    }

    func markCleanShutdown() {
        guard var recovery = launchRecovery else { return }
        recovery.markCleanShutdown()
        launchRecovery = recovery
    }

    func markIntendedUpdateReplace() {
        guard var recovery = launchRecovery else { return }
        recovery.markIntendedExit(.updateReplace)
        launchRecovery = recovery
    }

    func markIntendedForceQuit() {
        guard var recovery = launchRecovery else { return }
        recovery.markIntendedExit(.forceQuit)
        launchRecovery = recovery
    }

    /// Soft termination (SIGTERM / Activity Monitor "Quit") writes a force-quit
    /// intent so the next launch can distinguish it from a crash. True Force
    /// Quit (SIGKILL) cannot be intercepted and remains classified as crash.
    private func installTerminationSignalMarker() {
        guard terminationSignalSource == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.markIntendedForceQuit()
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSignalSource = source
    }

    private func relative(_ date: Date) -> String {
        if date == .distantPast { return tr(.notYet) }
        let ago = Date().timeIntervalSince(date)
        if ago < 5 { return tr(.justNow) }
        relativeFormatter.locale = lang == .zh ? Locale(identifier: "zh-Hans") : Locale(identifier: "en_US")
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func settingsURL() -> URL {
        PulseSettings.settingsFileURL()
    }

    /// Snapshot of the settings the store currently holds.
    var currentSettings: PulseSettings {
        PulseSettings(
            autoProbe: autoProbe,
            notifyOnIdle: notifyOnIdle,
            notifyOnWaiting: notifyOnWaiting,
            quietHoursEnabled: quietHoursEnabled,
            quietStartMinute: quietStartMinute,
            quietEndMinute: quietEndMinute,
            launchAtLogin: launchAtLogin,
            language: language,
            updateCheckEnabled: updateCheckEnabled,
            allowAppData: allowAppData,
            appDataAgents: appDataAgents,
            hotkey: hotkey,
            hotkeyEnabled: hotkeyEnabled,
            allowTerminalAutomation: allowTerminalAutomation,
            mutedAgents: mutedAgents,
            trayGrouping: trayGrouping,
            playSoundOnWaiting: playSoundOnWaiting,
            stallMinutes: stallMinutes,
            snoozeMinutes: snoozeMinutes
        )
    }

    func apply(_ s: PulseSettings) {
        autoProbe = s.autoProbe
        notifyOnIdle = s.notifyOnIdle
        notifyOnWaiting = s.notifyOnWaiting
        quietHoursEnabled = s.quietHoursEnabled
        quietStartMinute = s.quietStartMinute
        quietEndMinute = s.quietEndMinute
        launchAtLogin = s.launchAtLogin
        language = s.language
        updateCheckEnabled = s.updateCheckEnabled
        allowAppData = s.allowAppData
        appDataAgents = s.appDataAgents
        hotkey = s.hotkey
        hotkeyEnabled = s.hotkeyEnabled
        allowTerminalAutomation = s.allowTerminalAutomation
        mutedAgents = s.mutedAgents
        trayGrouping = s.trayGrouping
        playSoundOnWaiting = s.playSoundOnWaiting
        stallMinutes = s.stallMinutes
        snoozeMinutes = s.snoozeMinutes
    }

    func loadSettings() {
        guard let text = try? String(contentsOf: settingsURL(), encoding: .utf8) else {
            appliedLaunchAtLogin = launchAtLogin
            return
        }
        let parsed = PulseSettings.parse(text)
        apply(parsed)
        DebugLog.write("settings \(parsed.debugDescription)")
        // Launchd already reflects the persisted value at load; don't re-run it.
        appliedLaunchAtLogin = launchAtLogin
    }

    func saveSettings() {
        persistSettingsOnly()
        // Banner button titles are baked into the registered category, so they
        // go stale on a language switch unless re-registered here.
        PulseNotify.registerCategories(lang: lang)
        applyLaunchAtLoginIfChanged()
        applyHotkey()
        UpdateCheck.shared.startIfEnabled(store: self)
        rescheduleTimer()
        refresh(reason: "saveSettings")
    }

    /// Write settings without scheduling a full roster harvest. Used by
    /// per-Agent App Data toggles that refresh only the affected adapters.
    func persistSettingsOnly() {
        let dir = settingsURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        quietStartMinute = PulseSettings.clampMinute(quietStartMinute)
        quietEndMinute = PulseSettings.clampMinute(quietEndMinute)
        try? currentSettings.serialized().write(to: settingsURL(), atomically: true, encoding: .utf8)
    }

    /// Soft-dismiss tombstones for harvest pending — survive relaunch until
    /// the builder observes a natural clear or complete absence (0.95).
    private static func dismissedPendingURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/dismissed-pending.json")
    }

    private static func loadDismissedPendingKeys() -> Set<String> {
        let url = dismissedPendingURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded.filter { !$0.isEmpty })
    }

    private func persistDismissedPendingKeys() {
        let url = Self.dismissedPendingURL()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys = Array(dismissedPendingKeys).sorted()
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Follow a process-only → session identity change so snooze/dismiss survive.
    private func migrateRowIdentity(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, !newKey.isEmpty else { return }
        if dismissedPendingKeys.remove(oldKey) != nil {
            dismissedPendingKeys.insert(newKey)
            persistDismissedPendingKeys()
        }
        if let until = snoozedUntil.removeValue(forKey: oldKey) {
            snoozedUntil[newKey] = until
        }
        if let queued = pendingWaitingNotifications.removeValue(forKey: oldKey) {
            var moved = queued
            moved.rowKey = newKey
            pendingWaitingNotifications[newKey] = moved
        }
        if knownWaitingKeys.remove(oldKey) != nil {
            knownWaitingKeys.insert(newKey)
        }
        if lookMovedRowKeys.remove(oldKey) != nil {
            lookMovedRowKeys.insert(newKey)
        }
        if waitingDeliveryInFlight.remove(oldKey) != nil {
            waitingDeliveryInFlight.insert(newKey)
        }
        attentionLedger.remapRowKey(from: oldKey, to: newKey)
        attentionLedger.save()
        DebugLog.write("row identity \(DebugLog.key(oldKey)) → \(DebugLog.key(newKey))")
    }

    /// Re-register the global shortcut and report honestly when the system
    /// refuses (another app already owns the combination).
    func applyHotkey() {
        let choice = hotkeyEnabled ? hotkey : .off
        hotkeyRegistered = GlobalHotKey.install(choice: choice)
        if choice != .off, !hotkeyRegistered {
            DebugLog.write("hotkey \(hotkey.rawValue) registration FAILED — likely taken")
        }
    }

    func toggleMute(_ agent: AgentID) {
        if mutedAgents.contains(agent) {
            mutedAgents.remove(agent)
        } else {
            mutedAgents.insert(agent)
        }
        saveSettings()
    }

    func isInQuietHours(now: Date = Date()) -> Bool {
        currentSettings.isInQuietHours(now: now)
    }
}

enum DebugLog {
    static let path: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/debug.log")
    }()
    private static var previousPath: URL {
        path.deletingLastPathComponent().appendingPathComponent("debug.log.1")
    }
    /// Pulse writes ~5 lines every probe tick; without a cap the log grows
    /// unbounded (tens of MB per day). Roll at 2 MB, keep one generation.
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static let lock = NSLock()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static var bytesWritten: UInt64 = 0
    private static var sizeKnown = false

    /// A row key without the project name.
    ///
    /// `ActivityHarvest.sessionKey` falls back to the workspace leaf when an
    /// agent has no session id, so `claude|Pulse` — a directory name off the
    /// user's disk — was landing in a log file that support reports quote. The
    /// agent stays readable and the tail becomes a stable digest, so lines
    /// about the same row still correlate across a whole log.
    static func key(_ rowKey: String) -> String {
        guard let split = rowKey.firstIndex(of: "|") else { return rowKey }
        let agent = rowKey[..<split]
        let tail = rowKey[rowKey.index(after: split)...]
        guard !tail.isEmpty else { return rowKey }
        let digest = SHA256.hash(data: Data(tail.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(agent)|\(digest)"
    }

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if !sizeKnown {
            let attrs = try? fm.attributesOfItem(atPath: path.path)
            bytesWritten = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            sizeKnown = true
        }

        let line = "\(stamp.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if bytesWritten + UInt64(data.count) > maxBytes, fm.fileExists(atPath: path.path) {
            try? fm.removeItem(at: previousPath)
            try? fm.moveItem(at: path, to: previousPath)
            bytesWritten = 0
        }

        if fm.fileExists(atPath: path.path),
           let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: path, options: .atomic)
        }
        bytesWritten += UInt64(data.count)
    }
}

enum LoginItem {
    static let label = "com.pulse.app"

    /// Whether launchd currently knows the agent. `launchctl list <label>`
    /// exits non-zero when it does not.
    static func isRegistered() -> Bool {
        shell("/bin/launchctl", ["list", label]) == 0
    }

    /// Returns whether launchd ended up in the state the user asked for.
    ///
    /// Both `launchctl` calls used to be discarded with `_ =`, so the toggle
    /// reported success whether or not anything was registered — the same
    /// "claimed done, never verified" shape this project keeps having to undo.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let label = Self.label
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        if enabled {
            var appPath = Bundle.main.bundleURL.path
            if !appPath.hasSuffix(".app") {
                appPath = Bundle.main.executableURL?.path
                    ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PulseBar").path
                let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                  <key>Label</key><string>\(label)</string>
                  <key>ProgramArguments</key><array><string>\(appPath)</string></array>
                  <key>RunAtLoad</key><true/>
                </dict></plist>
                """
                try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? xml.write(to: plist, atomically: true, encoding: .utf8)
            } else {
                let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                  <key>Label</key><string>\(label)</string>
                  <key>ProgramArguments</key><array>
                    <string>/usr/bin/open</string>
                    <string>-a</string>
                    <string>\(appPath)</string>
                  </array>
                  <key>RunAtLoad</key><true/>
                </dict></plist>
                """
                try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? xml.write(to: plist, atomically: true, encoding: .utf8)
            }
            _ = shell("/bin/launchctl", ["unload", "-w", plist.path])
            _ = shell("/bin/launchctl", ["load", "-w", plist.path])
        } else {
            _ = shell("/bin/launchctl", ["unload", "-w", plist.path])
            try? FileManager.default.removeItem(at: plist)
        }
        let applied = isRegistered() == enabled
        DebugLog.write("loginItem enabled=\(enabled) applied=\(applied)")
        return applied
    }

    private static func shell(_ path: String, _ args: [String]) -> Int32 {
        guard let result = ProcessIO.run(
            executable: path,
            arguments: args,
            timeout: 4.0
        ), !result.timedOut else {
            return -1
        }
        return result.status
    }
}

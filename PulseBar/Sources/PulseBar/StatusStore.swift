import Foundation
import AppKit

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
    @Published var language: AppLanguage = .auto
    @Published var hooksStatus: HooksSupport.Status = .unknown
    @Published var showAllAgents = false
    @Published private(set) var isRefreshing = false
    /// Transient "Copied" confirmation on the diagnostics button.
    @Published private(set) var didCopyDiagnostics = false
    /// Agents the user muted — no notifications, still shown in the tray.
    @Published var mutedAgents: Set<AgentID> = []
    @Published var hotkey: HotkeyChoice = .commandShiftP
    @Published var hotkeyEnabled = false
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
    private var launchRecovery: LaunchRecovery?
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
    /// When the tray was last dismissed, for the missed-wait count.
    private var trayClosedAt: Date?
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
    /// Deterministic event ages for visual fixtures only.
    private var previewWaitingEventTimes: [AgentID: Int64]?
    /// Prevent a preview panel opening from immediately replacing its fixture
    /// with a live scan before the screenshot is taken.
    private var previewFixtureActive = false
    private let powerMonitor = PowerMonitor()
    /// Tray panel is on screen — worth probing faster while the user reads it.
    private var trayOpen = false
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
        saveSettings()
    }

    func setAllAppDataAccess(_ enabled: Bool) {
        allowAppData = enabled
        if enabled {
            appDataAgents.formUnion(protectedAppDataAgents)
        } else {
            appDataAgents.removeAll()
        }
        saveSettings()
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
        if let phase = readablePhase(row.phase) { return phase }
        let raw = row.phase.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw.replacingOccurrences(of: "_", with: " ").capitalized }
        if row.waiting { return tr(.phaseWaitingPermission) }
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
        return cachedAll.contains {
            $0.liveProcess && $0.agent.waitingSource == .none && !$0.waiting
        }
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
            "harvestProtocol: native-json-\(ActivityHarvest.wireSchemaVersion) (legacy-tsv explicit only)",
            "helperStatus: harvest=native legacyPython=\(ActivityHarvest.pythonURL() == nil ? "optional-unavailable" : "optional-ready")",
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
        var lines = [
            "Pulse safe support report",
            PulseVersion.fingerprint,
            "channel: \(PulseVersion.distributionChannel)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Agents: \(supportHealth.count)",
            "appDataScan: \(appDataScanDescription)",
            "harvestProtocol: native-json-\(ActivityHarvest.wireSchemaVersion) (legacy-tsv explicit only)",
            "helperStatus: harvest=native legacyPython=\(ActivityHarvest.pythonURL() == nil ? "optional-unavailable" : "optional-ready")",
            "collectorScan: \(collectorScanIncomplete ? "partial" : "complete")",
            "attentionLedger: active=\(attentionLedger.activeKeys.count) events=\(attentionLedger.events.count) baseline=\(attentionLedger.baselineEstablished)",
            "harvestSupervisor: \(harvestSupervisor.summary(nowMs: Int64(Date().timeIntervalSince1970 * 1000)))",
        ]
        for item in supportHealth {
            let waiting = item.agent.waitingSource == .none
                ? "n/a"
                : String(item.waitingSignalReady)
            lines.append(
                "\(item.agent.rawValue): \(item.collectorState.rawValue) "
                    + "disposition=\(item.disposition) evidence=\(item.evidence?.rawValue ?? "none") "
                    + "goal=\(item.hasGoal) workspace=\(item.hasWorkspace) "
                    + "activity=\(item.hasActivity) progress=\(item.hasProgress) "
                    + "waiting=\(waiting) "
                    + "score=\(item.usefulFactCount)/\(item.usefulFactTotal) "
                    + "privacyLimited=\(item.privacyLimited)"
            )
        }
        return ContentSanitizer.redact(lines.joined(separator: "\n"))
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
                }
            )
        }
    }

    /// Full session inventory for the tray search surface. The normal glance
    /// uses `snapshot.rows`; a query must search the bounded 128-row model so a
    /// session hidden behind the twelve-row viewport is still discoverable.
    var allRowsForDisplay: [AgentRow] { cachedAll }

    private func waitingSignalReady(for agent: AgentID) -> Bool {
        switch agent.waitingSource {
        case .hooks:
            return hooksStatus.isInstalled(for: agent)
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
        if let phase = readablePhase(row.phase) { facts.append(phase) }
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
        case .none: return tr(.supportWaitingNone)
        }
    }

    func start() {
        DebugLog.write("start begin \(PulseVersion.fingerprint)")
        let recovery = LaunchRecovery.begin(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        launchRecovery = recovery.state
        recoveredAfterCrash = recovery.wasUnclean
        if recoveredAfterCrash { DebugLog.write("launch recovery detected unclean previous exit") }
        // Restore only Pulse-owned attention state. Agent-owned hooks remain
        // the source of truth for the current row; the ledger supplies the
        // cross-launch baseline, snooze timers and delivery dedupe.
        attentionLedger = AttentionLedger.load()
        snoozedUntil = attentionLedger.snoozedUntil
        knownWaitingKeys = attentionLedger.activeKeys
        waitingNotifySeeded = attentionLedger.baselineEstablished
        restoreAttentionHistory()
        HooksSupport.seedAssets()
        hooksStatus = HooksSupport.probeStatus()
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

        if name.hasPrefix("status-") {
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
            snap.updatedAt = Date()
            snapshot = snap
            return
        }

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
        waiting.waitMessage = "Run the signed packaging step"
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
            LoginItem.setEnabled(enabled)
        }
    }

    /// Tray panel appeared — probe faster while the user is looking at it.
    func trayDidAppear() {
        trayOpen = true
        // Coming back to the tray, the first question is what was missed. The
        // panel only ever showed the present moment.
        if let closed = trayClosedAt {
            missedWhileAway = waitHistory.filter { $0.resolvedAt > closed }.count
        }
        rescheduleTimer()
        if !previewFixtureActive {
            refresh(reason: "trayOpen")
        }
    }

    func trayDidDisappear() {
        trayOpen = false
        trayClosedAt = Date()
        rescheduleTimer()
    }

    /// Acknowledge the "while you were away" line.
    func clearMissedWhileAway() {
        missedWhileAway = 0
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
        case .current: return tr(.updateCurrent)
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

    var updateDownloadStatusText: String? {
        switch updateDownloadStatus {
        case .idle: return nil
        case .downloading: return tr(.updateDownloading)
        case .verifying: return tr(.updateVerifying)
        case .ready: return tr(.updateVerified)
        case .installing: return tr(.updateInstalling)
        case .failed(let message): return "\(tr(.updateVerifyFailed)) · \(message)"
        }
    }

    var maintenanceNoticeText: String? {
        if recoveredAfterCrash { return tr(.recoveredAfterCrash) }
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
        // Claude/Codex hooks remain visible in Support Health and Settings,
        // but must not displace the session facts or imply that hooks are a
        // prerequisite for local harvest.
        if needsWaitingSignalNudge { return tr(.waitingSignalNudge) }
        if case .available = updateStatus { return updateStatusText }
        return nil
    }

    func performMaintenanceNoticeAction() {
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
            openSettings()
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

    func refresh(reason: String) {
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

        scanQueue.async {
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
            if why == "skipped" {
                outcome = .skipped
            } else {
                let h0 = Date()
                let result = ActivityHarvest.scan(
                    allowAppData: allowAllAppData,
                    appDataAgents: appDataAgentPolicy,
                    agentFilter: supervisorPlan.attempted
                )
                harvestMs = Int(Date().timeIntervalSince(h0) * 1000)
                outcome = result.unreliable
                    ? .failed(result.health, result.complete)
                    : .fresh(result.rows, result.health, result.complete)
            }

            let attention = AttentionReader.load()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DebugLog.write(
                "scan done #\(ticket) \(ms)ms harvest=\(why) procs=\(procs.count) " +
                "att=\(attention.count) procIds=\(procs.map(\.id.rawValue).joined(separator: ","))"
            )
            // Capture the optional as a value before crossing queues. Swift 6
            // diagnoses a mutable local captured by the main-queue closure,
            // even though the scan queue has finished assigning it here.
            let completedHarvestMs = harvestMs
            DispatchQueue.main.async { [completedHarvestMs] in
                switch outcome {
                case .fresh(_, let health, _), .failed(let health, _):
                    AppServices.store.harvestSupervisor.record(
                        health,
                        nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                    )
                case .skipped:
                    break
                }
                AppServices.store.applyScan(
                    procs: procs,
                    harvest: outcome,
                    processSignature: signature,
                    attention: attention,
                    ticket: ticket,
                    harvestMs: completedHarvestMs,
                    clearRefreshing: showSpinner
                )
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
        case fresh([ActivityHarvest.Row], [ActivityHarvest.CollectorHealth], Bool)
        /// Deliberately not run this tick — cached rows are still current.
        case skipped
        /// Ran and failed; cached rows may be stale.
        case failed([ActivityHarvest.CollectorHealth], Bool)
    }

    private func recordCollectorHealth(
        _ health: [ActivityHarvest.CollectorHealth],
        complete: Bool = true
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
                errorKind: cursor.errorKind
            )
        }
        collectorHealthByAgent = next
        collectorScanIncomplete = !complete
    }

    fileprivate func applyScan(
        procs: [ProcessProbe.Hit],
        harvest: HarvestOutcome,
        processSignature: String,
        attention: [AttentionReader.Entry],
        ticket: UInt64,
        harvestMs: Int? = nil,
        clearRefreshing: Bool = false
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
        case .fresh(let rows, let health, let complete):
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
            recordCollectorHealth(health, complete: complete)
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
        case .failed(let health, let complete):
            recordCollectorHealth(health, complete: complete)
            // Keep last good shape, but never freeze Needs-you on stale pending.
            acts = lastGoodHarvest.map { row in
                guard row.skill == "pending" else { return row }
                var cleared = row
                cleared.skill = ""
                return cleared
            }
            ticksSinceHarvest = 0
            DebugLog.write("harvest unreliable → reuse \(acts.count) cached rows (pending stripped)")
        }
        let harvestUnreliable: Bool = {
            switch harvest {
            case .failed:
                return true
            case .fresh(_, _, let complete):
                // A timed-out stream may contain useful rows, but it is not a
                // complete baseline. Treat it as unreliable for attention
                // edge reconciliation so an adapter that was never reached
                // cannot silently resolve a real Waiting event.
                return !complete
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
            DebugLog.write("snooze expired \(key)")
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
                terminal: TerminalFocus.Environment.current(),
                lang: lang,
                dismissedPendingKeys: dismissedPendingKeys,
                showAllAgents: showAllAgents,
                snoozedUntilMs: snoozedUntil.mapValues { Int64($0.timeIntervalSince1970 * 1000) },
                stalledSeconds: Double(stallMinutes) * 60
            )
        )

        for note in result.debugNotes { DebugLog.write(note) }
        dismissedPendingKeys.subtract(result.clearedPendingKeys)
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
            let deliveryRows = Array(
                Dictionary(uniqueKeysWithValues: (waitingEdges + queuedRows).map { ($0.rowKey, $0) })
                    .values
            )
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
                      !attentionLedger.isAcknowledged(rowKey: row.rowKey)
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
                eventIDs: eventIDs
            )
        } else {
            for waiting in candidates {
                PulseNotify.postWaiting(
                    title: notificationTitle(waiting),
                    body: notificationBody(waiting),
                    agent: waiting.agent.rawValue,
                    session: waiting.sessionID,
                    rowKey: waiting.rowKey,
                    eventID: attentionLedger.eventID(for: waiting.rowKey) ?? ""
                )
            }
        }
        for waiting in candidates {
            attentionLedger.markNotified(rowKey: waiting.rowKey, nowMs: nowMs)
            pendingWaitingNotifications.removeValue(forKey: waiting.rowKey)
        }
        attentionLedger.save()
        let posted = true
        // Opt-in, and deliberately quiet: Tink, not an alert tone. Muting an
        // agent silences this too, same as the banner. Play once per scan even
        // when several sessions crossed into Waiting together.
        if posted, playSoundOnWaiting {
            NSSound(named: NSSound.Name("Tink"))?.play()
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

    func clearWaitHistory() {
        waitHistory = []
        attentionLedger.clearResolved()
        attentionLedger.save()
    }

    func clearWaiting() {
        AttentionIO.clearAll()
        for row in cachedAll where row.waiting {
            dismissedPendingKeys.insert(row.rowKey)
        }
        refresh(reason: "clearWaiting")
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
    /// to the terminal tab it is blocked in.
    func focusOldestWait() {
        guard let row = oldestWait else { return }
        DebugLog.write("jump to oldest wait \(row.rowKey)")
        primaryAction(row)
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
        guard row.harvestMs > 0 else { return "" }
        let secs = row.lastActivitySeconds
        // "54s ago" reads as precision the number does not have — the panel
        // rescans every few seconds and nobody acts on the difference between
        // 40 and 54 seconds. Below a minute it is simply recent.
        if secs < 60 { return tr(.durNow) }
        return String(format: tr(.agoFormat), durationLabel(seconds: secs))
    }

    /// Second line of a row: where it is, what it is doing, and how long since
    /// it moved.
    ///
    /// The middle fact is the one the panel was missing. A row's title is the
    /// *session* name — it is fixed for the whole life of the session, so a
    /// running row said the same two things at minute one and minute forty and
    /// the panel read as static. `tool` is the live fact, it has been harvested
    /// since the first version, and it only ever appeared behind a hover or an
    /// expand. It is what turns "Claude is open" into "Claude is running Bash".
    ///
    /// Only for live rows: on a finished session the last tool it touched is
    /// history, not status, and would read as though it were still going.
    func rowContextLine(_ row: AgentRow, omitPath: Bool = false) -> String {
        if row.isProcessOnly {
            var bits: [String] = []
            let path = row.displayPath
            if !path.isEmpty, !omitPath { bits.append(path) }
            // Process-only is still useful liveness evidence. Explain how the
            // row was found instead of collapsing every limited observation
            // into the opaque "activity unavailable" label. The command line
            // itself is deliberately never retained or displayed.
            if let evidence = row.processEvidence {
                bits.append(
                    evidence == .pathSignature
                        ? tr(.supportDetectedPath)
                        : tr(.supportDetectedExecutable)
                )
            }
            bits.append(tr(.activityUnavailable))
            return bits.joined(separator: " · ")
        }
        var bits: [String] = []
        let path = row.displayPath
        if !path.isEmpty, !omitPath { bits.append(path) }
        // A completed/recent session still benefits from the last meaningful
        // action. It is explicitly labelled as history, never presented as
        // something currently running. This is often the only useful signal
        // for adapters that do not expose a lifecycle phase.
        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if row.usefulTask != nil, !tool.isEmpty, usefulAction(tool) {
            bits.append(String(format: tr(.lastAction), readableAction(tool)))
        }
        let ago = lastActivityLabel(row)
        if !ago.isEmpty { bits.append(String(format: tr(.lastActive), ago)) }
        let age = row.sessionAgeSeconds(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        // Session creation is useful while orienting in a new session, but an
        // ancient store timestamp is history—not runtime state. It previously
        // produced labels such as "Started 1276h ago" beside a fresh activity.
        if age >= 60, age <= 24 * 60 * 60,
           row.waiting || age >= 2 * 60 * 60 || !rowHasDynamicEvidence(row) {
            bits.append(String(
                format: tr(.sessionAge),
                DurationFormat.label(seconds: age, lang: lang)
            ))
        }
        if row.liveProcess, row.agent.waitingSource == .none {
            bits.append(tr(.supportWaitingNone))
        }
        // With none of them, fall back to naming the agent rather than an
        // empty line.
        if bits.isEmpty { return row.isProcessOnly ? "" : row.agent.displayName }
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
                  let phase = readablePhase(row.phase) else { return "" }
            return String(format: tr(.nowActivity), phase)
        }
        guard let phase = readablePhase(row.phase) else { return "" }
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
        case .completed:
            detail = tr(.phaseTurnComplete)
        case .failed:
            detail = tr(.outcomeFailed)
        case .cancelled:
            detail = tr(.outcomeCancelled)
        }
        return String(format: tr(.activityChanged), detail)
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

    /// One bounded execution signal line for the default row. The panel's
    /// previous stack rendered lifecycle, change, metrics, and model context
    /// as four separate blocks, so a multi-fact session pushed later rows below
    /// the viewport. Keep the same evidence, but give it one scan target and
    /// suppress facts already represented by the transient change label.
    func rowSignalLine(_ row: AgentRow) -> String {
        guard !row.waiting else { return "" }
        let lifecycle = rowNowLine(row).trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = rowSignalChange(row).trimmingCharacters(in: .whitespacesAndNewlines)
        let metrics = rowSignalMetric(row).trimmingCharacters(in: .whitespacesAndNewlines)
        let stableFacts = rowStableFacts(row)
        var bits: [String] = []
        if !lifecycle.isEmpty { bits.append(lifecycle) }
        if !changed.isEmpty {
            bits.append(changed)
            // A change is already the strongest dynamic fact. Use the remaining
            // line for the durable context that makes the change actionable:
            // model/context first, then tokens/files/errors as available. The
            // old branch spent this slot on tokens and silently dropped the
            // model and context, leaving the row's meaning ambiguous.
            let evidence = compactSignalEvidence(metrics: metrics, stableFacts: stableFacts)
            if !evidence.isEmpty { bits.append(evidence) }
        } else {
            if !metrics.isEmpty { bits.append(metrics) }
            if !stableFacts.isEmpty {
                let stable = stableFacts.prefix(2).joined(separator: " · ")
                if !stable.isEmpty { bits.append(stable) }
            }
        }
        // Generic shell wrappers are still useful as a historical activity
        // fact when they are the only action a vendor exposes. Keep the claim
        // explicit ("last", never "running") and place it ahead of low-value
        // observation metadata so it is not clipped from the scan line.
        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if lifecycle.isEmpty, changed.isEmpty,
           !tool.isEmpty, row.usefulTask != nil, !usefulAction(tool) {
            bits.insert(String(format: tr(.lastAction), readableAction(tool)), at: min(1, bits.count))
        }
        if row.liveProcess, !row.isProcessOnly, row.processCount > 1 {
            bits.append(String(format: tr(.processCount), row.processCount))
        }
        // A structured/cache row can still be real while exposing no phase,
        // action, model, progress, token, or outcome. Do not leave the third
        // line blank: that looks like a Pulse rendering bug and hides the
        // adapter's actual information boundary. Process-only and stalled rows
        // have more precise fallbacks above.
        if bits.isEmpty, row.observationSource != .process {
            bits.append(tr(.noProgressSignal))
        }
        return bits.prefix(3).joined(separator: " · ")
    }

    /// Stable execution context that makes a numeric signal meaningful. Model
    /// and context are deliberately first: they answer which runtime is doing
    /// the work and how close it is to its input budget. Mode/skill follows as
    /// workflow context. Record count is only a last-resort observation
    /// boundary; it must never displace a real progress, outcome, or token
    /// signal.
    private func rowStableFacts(_ row: AgentRow) -> [String] {
        guard !row.waiting, !row.isProcessOnly else { return [] }
        var facts: [String] = []
        let model = readableModel(row.model)
        if !model.isEmpty { facts.append(String(format: tr(.modelFact), model)) }
        if row.contextPercent > 0 {
            facts.append(String(format: tr(.contextFact), row.contextPercent))
        }
        let mode = readableMode(row.mode)
        if !mode.isEmpty { facts.append(mode) }
        let skill = readableSkill(row.skill)
        if !skill.isEmpty { facts.append(skill) }
        if facts.isEmpty, row.records > 0 {
            facts.append(String(row.records) + tr(.recordsSuffix))
        }
        return facts
    }

    /// Fit the most useful dynamic and stable facts into the one remaining
    /// signal slot when a row has a lifecycle + change label. Stable facts are
    /// placed first so model/context remain visible even when SwiftUI clips a
    /// long line at the trailing edge.
    private func compactSignalEvidence(metrics: String, stableFacts: [String]) -> String {
        var facts: [String] = []
        for fact in stableFacts.prefix(2) where !fact.isEmpty {
            if !facts.contains(fact) { facts.append(fact) }
        }
        if !metrics.isEmpty, !facts.contains(metrics) { facts.append(metrics) }
        return facts.joined(separator: " · ")
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

    /// Stable, useful session evidence that should not require opening a
    /// disclosure. This is deliberately bounded to four facts and excludes
    /// diagnostic-only values such as the full cwd and session identifier.
    func rowObservationLine(_ row: AgentRow) -> String {
        // Process-only rows can retain stale session fields after a merge, but
        // those fields are not trustworthy without a matched session feed.
        // Suppressing the whole line by presentation category used to hide the
        // only useful facts on real session rows. That policy was too loose:
        // a stale merge could carry transcript counts onto a process-only row,
        // making "Process only" look like a real session feed. A process row
        // now keeps only its explicit process evidence/age line.
        guard !row.waiting, !row.isProcessOnly else { return "" }
        // Keep this public detail line in lockstep with the default signal
        // priority. It is also used by accessibility, so exposing the same
        // model/context facts here avoids a different meaning behind the row.
        return rowStableFacts(row).prefix(3).joined(separator: " · ")
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
    func liveTool(_ row: AgentRow) -> String? {
        guard row.liveProcess || row.subRunning > 0, !row.waiting else { return nil }
        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty, row.usefulTask != nil else { return nil }
        return tool
    }

    /// Raw tool identifiers are diagnostic evidence. Only actions that convey
    /// a user-recognisable workflow phase earn scarce default-row space.
    private func usefulAction(_ raw: String) -> Bool {
        let low = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if low.isEmpty || low == "exec" || low == "bash" || low == "shell" { return false }
        if low.contains("command") || low.contains("terminal") { return false }
        return [
            "plan", "todo", "patch", "edit", "write", "image", "screenshot",
            "search", "web", "browser", "read", "glob", "grep", "automation", "computer",
            "test", "verify", "check", "build", "compile", "package", "publish", "release", "deploy",
        ].contains { low.contains($0) }
    }

    /// Dynamic evidence makes a session's start time secondary. Keep the
    /// duration for long-running sessions and waits, but do not repeat
    /// `Started 54m ago` beside a live action, progress, or token signal.
    private func rowHasDynamicEvidence(_ row: AgentRow) -> Bool {
        usefulAction(row.tool) || !row.phase.isEmpty || !row.outcome.isEmpty
            || row.progressDone > 0 || row.progressTotal > 0
            || row.tokensIn > 0 || row.tokensOut > 0
            || row.subTotal > 0 || row.errors > 0 || row.files > 0
            || row.contextPercent > 0 || !row.model.isEmpty || !row.mode.isEmpty
            || !row.skill.isEmpty || row.activityChange != nil
            || row.isStalled || row.section == .stalled
    }

    private func readablePhase(_ raw: String) -> String? {
        let low = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if low.isEmpty { return nil }
        if low.contains("permission") { return tr(.phaseWaitingPermission) }
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
        if low == "working" || low == "running" || low.contains("execut") {
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

    /// Rebuild wait detail under the badge: duration · signal · message (kind lives in the badge).
    /// Returns nil when there is nothing beyond the badge label.
    func localizedWaitDetail(_ row: AgentRow) -> String? {
        guard row.waiting else { return nil }
        var head: [String] = []
        let dur = waitDurationLabel(row)
        if !dur.isEmpty { head.append(dur) }
        if let sig = row.waitSignal {
            head.append(sig == .hooks ? tr(.signalHooks) : tr(.signalPending))
        }
        let headText = head.joined(separator: " · ")
        let msg = row.waitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !msg.isEmpty {
            if headText.isEmpty { return "↳ \(msg)" }
            return "↳ \(headText): \(msg)"
        }
        if headText.isEmpty { return nil }
        return "↳ \(headText)"
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
        case .none: return tr(.focusTerminal)
        }
    }

    func primaryActionTitle(_ row: AgentRow) -> String {
        if row.canFocusTerminal { return focusActionTitle(row) }
        return tr(.moreActions)
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
        DebugLog.write("snooze \(row.rowKey) for \(snoozeMinutes)m")
        refresh(reason: "snooze")
    }

    /// Undo a snooze from the row that shows it — a countdown you cannot stop
    /// is a worse deal than no countdown.
    func unsnooze(_ row: AgentRow) {
        guard snoozedUntil.removeValue(forKey: row.rowKey) != nil else { return }
        attentionLedger.unsnooze(rowKey: row.rowKey)
        attentionLedger.save()
        DebugLog.write("unsnooze \(row.rowKey)")
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
        DebugLog.write("snooze(notif) \(rowKey) for \(snoozeMinutes)m")
        refresh(reason: "snoozeNotification")
    }

    func snoozeLabel(_ row: AgentRow) -> String {
        String(format: tr(.snoozedFor), DurationFormat.label(seconds: row.snoozeRemainingSeconds, lang: lang))
    }

    func dismissWaiting(_ row: AgentRow) {
        AttentionIO.appendDone(agent: row.agent, session: row.sessionID)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        attentionLedger.acknowledge(rowKey: row.rowKey, nowMs: nowMs)
        attentionLedger.save()
        pendingWaitingNotifications.removeValue(forKey: row.rowKey)
        if row.skill == "pending" {
            dismissedPendingKeys.insert(row.rowKey)
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
            if row.canFocusTerminal, TerminalFocus.focus(row: row) { return }
        }
        TrayReveal.show()
    }

    func focusAgent(idRaw: String, session: String = "", rowKey: String = "") {
        if !rowKey.isEmpty, let row = cachedAll.first(where: { $0.rowKey == rowKey }) {
            if row.canFocusTerminal, TerminalFocus.focus(row: row) { return }
            TrayReveal.show()
            return
        }
        if !session.isEmpty, let row = cachedAll.first(where: {
            !$0.sessionID.isEmpty && ($0.sessionID == session || session.hasPrefix($0.sessionID))
        }) {
            if row.canFocusTerminal, TerminalFocus.focus(row: row) { return }
            TrayReveal.show()
            return
        }
        guard let id = ActivityHarvest.mapAgent(idRaw) else {
            focusFirstWaiting()
            return
        }
        if let row = cachedAll.first(where: { $0.agent == id && $0.waiting })
            ?? cachedAll.first(where: { $0.agent == id }) {
            if row.canFocusTerminal, TerminalFocus.focus(row: row) { return }
            TrayReveal.show()
            return
        }
        TrayReveal.show()
    }

    func openSettings() {
        SettingsWindowController.shared.show(store: self)
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
        launchRecovery?.markCleanShutdown()
    }

    private func relative(_ date: Date) -> String {
        if date == .distantPast { return tr(.notYet) }
        let ago = Date().timeIntervalSince(date)
        if ago < 5 { return tr(.justNow) }
        relativeFormatter.locale = lang == .zh ? Locale(identifier: "zh-Hans") : Locale(identifier: "en_US")
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func settingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/settings.txt")
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
        let dir = settingsURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        quietStartMinute = PulseSettings.clampMinute(quietStartMinute)
        quietEndMinute = PulseSettings.clampMinute(quietEndMinute)
        try? currentSettings.serialized().write(to: settingsURL(), atomically: true, encoding: .utf8)
        // Banner button titles are baked into the registered category, so they
        // go stale on a language switch unless re-registered here.
        PulseNotify.registerCategories(lang: lang)
        applyLaunchAtLoginIfChanged()
        applyHotkey()
        UpdateCheck.shared.startIfEnabled(store: self)
        rescheduleTimer()
        refresh(reason: "saveSettings")
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
    static func setEnabled(_ enabled: Bool) {
        let label = "com.pulse.app"
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

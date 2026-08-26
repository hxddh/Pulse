import Foundation
import AppKit
import CryptoKit

@MainActor
final class StatusStore: ObservableObject {
    @Published var snapshot = PulseSnapshot()
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
    @Published var loginItemApplied: Bool?
    @Published var language: AppLanguage = .auto
    @Published var hooksStatus: HooksSupport.Status = .unknown
    /// Native `pulse-hook` launcher present — Attention bridge path, not Claude/Codex install.
    @Published var pulseHookLauncherReady = false
    @Published var didCopyAttentionRaise = false
    @Published var showAllAgents = false
    @Published var isRefreshing = false
    /// Transient "Copied" confirmation on the diagnostics button.
    @Published var didCopyDiagnostics = false
    /// The shape report walks the session stores, so the button says so.
    @Published var isCopyingShapeReport = false
    @Published var didCopyShapeReport = false
    /// Agents the user muted — no notifications, still shown in the tray.
    @Published var mutedAgents: Set<AgentID> = []
    @Published var hotkey: HotkeyChoice = .commandShiftP
    @Published var hotkeyEnabled = false
    /// Opt-in: Terminal/iTerm tab Focus via Apple Events (may prompt Automation).
    @Published var allowTerminalAutomation = false
    @Published var allowWorkbenchActuation = false
    /// Answer this Mac's own agents from Pulse, when the prompt is not in
    /// front of you. **The key file is the source of truth**, not this flag —
    /// a persisted setting could drift from the file the hook actually reads,
    /// and the hook is the half that decides whether an agent waits.
    @Published var respondLocalEnabled = false
    /// Measure what has landed in each agent's working copy. On by default —
    /// an evidence axis nobody switches on is worth nothing — and bounded,
    /// read-only and content-free by construction. Off means not one git
    /// command runs.
    @Published var measureWorkspaceEffect = true
    /// Write this Mac's own fleet snapshot for other machines to read. Off by
    /// default — content leaving the machine is the user's call, every time.
    /// Reading other hosts' snapshots is always on: it is passive, local and
    /// bounded, and the directory simply does not exist until a sync tool
    /// puts something there.
    @Published var broadcastFleet = false
    /// Last time the local snapshot was written, so the file is refreshed on
    /// the snapshot's own cadence rather than every 2-second tick.
    var lastFleetWriteMs: Int64 = 0
    @Published var trayGrouping: TrayGrouping = .status
    @Published var playSoundOnWaiting = false
    /// Minutes of silence before a live row reads as stalled; 0 turns it off.
    @Published var stallMinutes = 20
    /// How long "Later" silences a wait.
    @Published var snoozeMinutes = 10
    /// False when the system refused the shortcut (another app owns it).
    @Published var hotkeyRegistered = true
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
    @Published var recoveredAfterCrash = false
    @Published var recoveryExitKind: LaunchRecovery.ExitKind = .clean
    /// Keep the unclean-exit banner through the first healthy scan so the user
    /// can actually see it; clear on the next healthy scan or explicit dismiss.
    var recoveryNoticeSurvivedFirstHealthyScan = false
    var launchRecovery: LaunchRecovery?
    /// SIGTERM → force-quit marker. Force Quit via SIGKILL still looks like a crash.
    var terminationSignalSource: DispatchSourceSignal?
    @Published var installReport = InstallTruth.Report.empty
    @Published var hookSelfTestResult: HooksSupport.SelfTestResult = .idle
    /// Notification authorization — a denied prompt used to fail silently.
    @Published var notifyAuthorized: Bool?
    /// True when the latest harvest stopped before every adapter reported.
    /// Existing per-agent health is retained in that case; the banner exposes
    /// the scan gap without turning every unvisited adapter into an error.
    @Published var collectorScanIncomplete = false
    /// Waits that have already been resolved, newest first (P1-H).
    @Published var waitHistory: [ResolvedWait] = []
    /// Waits that ended while the tray was closed — "what did I miss?".
    @Published var missedWhileAway = 0
    /// Sessions that moved / new waits while the tray was closed (Look Continuity).
    @Published var lookMovedWhileAway = 0
    @Published var lookNewWaitsWhileAway = 0
    /// Localized Look Closure notice — named agents/sessions, not only counts (0.93).
    @Published var lookContinuityNotice = ""
    /// Ordered Look Closure events (new wait → ended wait → moved).
    @Published var lookContinuityItems: [LookDeltaItem] = []
    /// Respond (scene AR): inbound full permission requests matched to rows,
    /// and the rows whose verdict this session already wrote. State only —
    /// matching and actions live in StatusStore+Respond.swift, which is also
    /// the only writer (internal set because extensions live in another file).
    @Published var respondInboundByRowKey: [String: RespondSpool.InboundRequest] = [:]
    @Published var respondVerdictSentRowKeys: Set<String> = []
    /// Verdicts this Mac wrote, and what has become of each. The fate is read
    /// off disk every scan — `claimVerdict` renames a verdict to `.used`
    /// before reading it, so the agent taking it is a file fact rather than
    /// something Pulse infers.
    @Published var respondDecided: [String: DecidedVerdict] = [:]
    /// What happened the last time the user pressed a button on this row.
    ///
    /// A click that reached nothing used to be indistinguishable from a dead
    /// button. `TerminalFocus.focus` returns whether it actually got
    /// anywhere and every caller threw that away; a verdict that could not be
    /// written went to `debug.log` and nowhere else. Both are honest failures
    /// with a real cause, and both deserve one short sentence on the row that
    /// offered the action — especially Deny, which the product documents as
    /// always available precisely because refusing is the safe move.
    @Published var rowActionNotices: [String: String] = [:]
    /// Row keys marked “moved while away” until the notice is acknowledged.
    @Published var lookMovedRowKeys: Set<String> = []
    /// When the tray was last dismissed, for the missed-wait count.
    var trayClosedAt: Date?
    /// Fingerprint of visible rows at last tray close — Look Continuity (0.92).
    var trayCloseFingerprint: TrayLookFingerprint?

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
    var installTruthRefreshInFlight = false
    var installTruthRefreshedAt: Date?
    var installTruthGeneration = 0

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

    var timer: Timer?
    /// 5.0-α — the engine boundary. Sources produce rows; the coordinator
    /// merges; `cachedAll` is the merged cache the display layer reads.
    /// The observed pipeline registers first and stays ground truth for any
    /// rowKey it also produces; the managed runtime (5.0-β) registers after.
    let observedSessions = ObservedSessionSource()
    /// 5.0-β — registered on first dispatch (after observed, so the
    /// coordinator's ground-truth rule holds by construction).
    let managedSessions = ManagedSessionSource()
    private(set) lazy var sessionSources = SessionSourceCoordinator(sources: [observedSessions])
    var cachedAll: [AgentRow] = []
    var lastGoodHarvest: [ActivityHarvest.Row] = []
    /// Result of the latest attempted adapter scan, including adapters that
    /// ran successfully but had no recent local session. This is deliberately
    /// separate from row evidence: zero rows is a useful result, not silence.
    var collectorHealthByAgent: [AgentID: ActivityHarvest.CollectorHealth] = [:]
    /// Latest successful collector read by Agent, retained even after its
    /// session row ages out so Settings can distinguish "not running" from
    /// "collector has never produced evidence".
    var lastSuccessfulReadByAgent: [AgentID: Int64] = [:]
    /// Per-Agent retry/backoff/circuit policy. A bad store must not consume the
    /// next scan budget for every other adapter.
    var harvestSupervisor = HarvestSupervisor()
    /// Per-repository-root measurements, their cadence, and the slow-repo
    /// circuit. Lives here because measuring forks git; the builder only ever
    /// sees the resulting table.
    var workspaceEffects = WorkspaceEffectStore()
    var workspaceEffectsByDirectory: [String: WorkspaceEffect.Measurement] = [:]
    /// Where the next native harvest should start.
    ///
    /// The collector walks its adapters in a fixed order, so before 0.98 a
    /// global budget cutoff always fell in the same place and the same tail
    /// adapters were reported `unscanned` on every refresh. The scan returns
    /// the first adapter it could not reach; the next one begins there.
    // Internal since the 4.0-γ split: the engine extension is the only
    // reader and writer (StatusStoreEngine.swift).
    var harvestScanCursor = 0
    /// Deterministic event ages for visual fixtures only.
    var previewWaitingEventTimes: [AgentID: Int64]?
    /// Prevent a preview panel opening from immediately replacing its fixture
    /// with a live scan before the screenshot is taken.
    var previewFixtureActive = false
    let powerMonitor = PowerMonitor()
    /// Tray panel is on screen — worth probing faster while the user reads it.
    var trayOpen = false
    /// Close instant to apply Look Continuity *after* the opening scan (0.96).
    var lookContinuityPendingClosedAt: Date?
    /// Sample Waiting reveal waits until the row exists in `cachedAll`.
    var pendingSampleRevealSession = ""
    var activity: ProbeSchedule.Activity = .empty
    var currentInterval: TimeInterval?
    /// Live-process fingerprint; a change forces a harvest even off-cadence.
    var lastProcessSignature = ""
    var ticksSinceHarvest = Int.max
    /// Last value actually pushed to launchd — avoids re-running launchctl
    /// (two synchronous subprocesses) on every settings write.
    var appliedLaunchAtLogin: Bool?
    /// Rolling scan counters, so the energy claim can be checked, not believed.
    var probeStats = ProbeStats()
    /// When the timer parked, for the parked-duration counter.
    private var parkedSince: Date?
    var knownWaitingKeys: Set<String> = []
    /// First apply seeds waiting keys without firing edge notifications.
    var waitingNotifySeeded = false
    /// Waiting edges observed while macOS notification authorization is still
    /// resolving. Keep one row per session so a delayed permission callback
    /// cannot make an approval disappear without either a banner or a tray
    /// prompt.
    var pendingWaitingNotifications: [String: AgentRow] = [:]
    /// One interruption per short window keeps a burst of parallel approvals
    /// useful without turning Notification Center into a stream of duplicates.
    static let waitingNotificationMinimumIntervalMs: Int64 = 3_000
    var waitingDeliveryTask: Task<Void, Never>?
    /// Notification Center accepts requests asynchronously. Keep the event
    /// in-flight until its callback arrives so a fast follow-up scan cannot
    /// post a duplicate or mark a failed request as delivered.
    var waitingDeliveryInFlight: Set<String> = []
    /// Keep the optional sound as one cue per delivery window, not one cue per
    /// session when a batch is accepted as separate Notification Center
    /// requests.
    var waitingDeliverySounded = false
    /// Cross-launch Waiting/delivery state. This is deliberately separate from
    /// the agent-owned attention.tsv bridge so a restart cannot lose the only
    /// human-confirmation edge or emit it twice.
    var attentionLedger = AttentionLedger.load()
    /// Soft-dismissed Cursor harvest pending until skill clears.
    var dismissedPendingKeys: Set<String> = []
    /// Row key → when its "remind me later" runs out.
    var snoozedUntil: [String: Date] = [:]
    let attentionWatcher = AttentionWatcher()
    let scanQueue = DispatchQueue(label: "com.pulse.scan", qos: .userInitiated)
    var scanTicket: UInt64 = 0
    var lastAppliedTicket: UInt64 = 0
    /// Tests exercising store behaviour must not start a real background scan.
    ///
    /// A scan is not read-only: it folds session digests and flushes them, so
    /// an unguarded `refresh()` inside a unit test writes the developer's own
    /// `session-digests.json` — the same class of accident 1.1 fixed when a
    /// fixture scan leaked into the real digest store. Same shape as
    /// `AttentionIO.pathOverride` and `HooksInstaller.homeOverride`.
    static var suppressBackgroundScansForTesting = false

    var scanInFlight = false
    /// A refresh that arrived while one was already in flight.
    ///
    /// Only the reason used to survive the wait, so a scoped rescan replayed
    /// as a full scan — and a full scan is precisely what a scoped rescan is
    /// not. The scope exists to force an agent the supervisor would otherwise
    /// defer, so toggling that agent's data source during an in-flight scan
    /// could leave it unread until its backoff expired: "I enabled it and
    /// nothing happened."
    struct PendingRefresh {
        var reason: String
        /// nil means a full scan, which absorbs any scoped request merged in.
        var agentFilter: Set<AgentID>?

        mutating func absorb(reason: String, agentFilter: Set<AgentID>?) {
            self.reason = reason
            guard let agentFilter, let existing = self.agentFilter else {
                self.agentFilter = nil
                return
            }
            self.agentFilter = existing.union(agentFilter)
        }
    }

    var pendingRefresh: PendingRefresh?
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
    var harvestAppDataAgents: Set<AgentID> {
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

    var appDataScanDescription: String {
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


    /// the main thread, and never run them when nothing changed.
    /// A new glance is about to start — discard the last one's navigation.
    ///
    /// EXPERIENCE §4: "展开状态不持久化：每次打开托盘都是一次新的扫视，应该从
    /// 「谁需要我」开始". The panel is built once and only ordered in and out, so
    /// SwiftUI keeps every `@State` it ever had: a search typed at 11:00 was
    /// still filtering the list at 15:00, and a group folded to see past it
    /// stayed folded over the next wait. Bumping this token gives `TrayPanel` a
    /// new identity, which is the one mechanism that resets *all* of its state
    /// — including any added later — rather than the subset someone remembered
    /// to list in a reset function.
    ///
    /// Called before the panel is ordered in, so the reset lands in the same
    /// layout pass rather than a frame after the user is already reading.
    @Published var traySessionToken: Int = 0

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

    func rescheduleTimer() {
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

    func toggleShowAllAgents() {
        showAllAgents.toggle()
        applyRowWindow()
    }


    /// Withdraw banners that were already handed to Notification Center.
    ///
    /// Injected so the clear path can be tested without a bundled app: an
    /// unbundled test process has no `UNUserNotificationCenter` at all.
    var withdrawWaitingBanners: () -> Void = { PulseNotify.withdrawWaitingNotifications() }

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


    func relative(_ date: Date) -> String {
        if date == .distantPast { return tr(.notYet) }
        let ago = Date().timeIntervalSince(date)
        if ago < 5 { return tr(.justNow) }
        relativeFormatter.locale = lang == .zh ? Locale(identifier: "zh-Hans") : Locale(identifier: "en_US")
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

}

/// Which sentence a token pair belongs to.
///
/// The scope is not decoration: "latest model call" and "the agent's own
/// running total" are different numbers, and a pair printed without saying
/// which one it is has been a bug report waiting to happen since 2.1. Each
/// scope carries three phrasings, because a pair with one unmeasured half is
/// a different sentence — not the same sentence with a zero in it.

import Foundation
import AppKit
import CryptoKit
import Observation

/// The app's one source of truth, observed field by field (19.0).
///
/// Before 19.0 this was an `ObservableObject`: any `@Published` assignment
/// woke every view that held the store, whether or not it drew that field.
/// Under Observation a view is invalidated only by the properties its body
/// actually read. Two rules keep that honest:
///
/// - Engine bookkeeping (timers, tickets, caches no view draws) is
///   `@ObservationIgnored`, so writing it wakes nothing.
/// - The scan path still writes a tracked property only when its value
///   changed — Observation announces every assignment, equal or not.
///   `ScanQuietTests` tracks every property here and holds it to that.
@MainActor
@Observable
final class StatusStore {
    var snapshot = PulseSnapshot() {
        didSet {
            let agents = Set(snapshot.rows.map(\.agent))
            if agents != snapshotAgents { snapshotAgents = agents }
        }
    }
    /// The agents in the current snapshot. Settings offers a mute switch per
    /// agent Pulse has seen; reading this rather than `snapshot` keeps a
    /// scan that only moved a row's activity from redrawing the form.
    private(set) var snapshotAgents: Set<AgentID> = []
    var notifyOnIdle = true
    var notifyOnWaiting = true
    var launchAtLogin = false
    /// Whether launchd was actually left in the state `launchAtLogin` claims.
    /// `nil` until the toggle has been applied at least once this run.
    var loginItemApplied: Bool?
    var language: AppLanguage = .auto
    var hooksStatus: HooksSupport.Status = .unknown
    var showAllAgents = false
    var isRefreshing = false
    /// Transient "Copied" confirmation on the diagnostics button.
    var didCopyDiagnostics = false
    /// 19.0: the self-check's last result, and its button states.
    var doctorReport: DoctorModel.Report?
    var isRunningDoctor = false
    var didCopyDoctorReport = false
    /// The shape report walks the session stores, so the button says so.
    var isCopyingShapeReport = false
    var didCopyShapeReport = false
    /// Agents the user muted — no notifications, still shown in the tray.
    var mutedAgents: Set<AgentID> = []
    /// `.off` until the person picks one (see `PulseSettings.hotkey`).
    var hotkey: HotkeyChoice = .off
    /// Opt-in: Terminal/iTerm tab Focus via Apple Events (may prompt Automation).
    var allowTerminalAutomation = false
    /// Persisted: the user uninstalled the hooks, so the tray stops offering
    /// them. Cleared by the next install.
    var hooksNudgeOff = false
    /// When the last scan was applied — advances on every scan, published or
    /// not, unlike `snapshot.updatedAt` which moves only when the snapshot
    /// changes. Read by the self-check; never drives a view.
    @ObservationIgnored var lastScanAt: Date?
    /// False when the system refused the shortcut (another app owns it).
    var hotkeyRegistered = true
    var updateCheckEnabled = true
    /// Opt-in only: reading vendor Application Support/App Group data can
    /// trigger macOS's cross-app privacy prompt. The default scan remains
    /// useful through hooks, dot-directory sessions, and process evidence.
    var allowAppData = false
    /// Protected app-data access is scoped to the agents the user actually
    /// wants richer details for. The all-agents switch remains available, but
    /// a single TCC decision must never silently widen the scan to every app.
    var appDataAgents: Set<AgentID> = []
    var updateStatus: UpdateCheck.Status = .idle
    var hookSelfTestResult: HooksSupport.SelfTestResult = .idle
    /// Notification authorization — a denied prompt used to fail silently.
    var notifyAuthorized: Bool?
    /// 21.0: Notification Center refused the last "needs you" banner.
    var waitingBannerFailed = false
    /// True when the latest harvest stopped before every adapter reported.
    /// Existing per-agent health is retained in that case; the banner exposes
    /// the scan gap without turning every unvisited adapter into an error.
    var collectorScanIncomplete = false
    /// What happened the last time the user pressed a button on this row.
    ///
    /// A click that reached nothing used to be indistinguishable from a dead
    /// button. `TerminalFocus.focus` returns whether it actually got
    /// anywhere and every caller threw that away. An honest failure with a
    /// real cause deserves one short sentence on the row that offered the
    /// action.
    var rowActionNotices: [String: String] = [:]
    @ObservationIgnored var timer: Timer?
    /// Every row the last scan produced; the display layer reads it.
    var cachedAll: [AgentRow] = []
    @ObservationIgnored var lastGoodHarvest: [ActivityHarvest.Row] = []
    /// Result of the latest attempted adapter scan, including adapters that
    /// ran successfully but had no recent local session. This is deliberately
    /// separate from row evidence: zero rows is a useful result, not silence.
    @ObservationIgnored var collectorHealthByAgent: [AgentID: ActivityHarvest.CollectorHealth] = [:]
    /// Latest successful collector read by Agent, retained even after its
    /// session row ages out so Settings can distinguish "not running" from
    /// "collector has never produced evidence".
    @ObservationIgnored var lastSuccessfulReadByAgent: [AgentID: Int64] = [:]
    /// Per-Agent retry/backoff/circuit policy. A bad store must not consume the
    /// next scan budget for every other adapter.
    @ObservationIgnored var harvestSupervisor = HarvestSupervisor()
    /// Where the next native harvest should start.
    ///
    /// The collector walks its adapters in a fixed order, so before 0.98 a
    /// global budget cutoff always fell in the same place and the same tail
    /// adapters were reported `unscanned` on every refresh. The scan returns
    /// the first adapter it could not reach; the next one begins there.
    // Internal since the 4.0-γ split: the engine extension is the only
    // reader and writer (StatusStoreEngine.swift).
    /// True while a finished scan is being landed on the main actor. Views
    /// that should not redraw per scan read it through `StoreObservation`.
    @ObservationIgnored var isApplyingScan = false
    @ObservationIgnored var harvestScanCursor = 0
    /// Deterministic event ages for visual fixtures only.
    var previewWaitingEventTimes: [AgentID: Int64]?
    /// Prevent a preview panel opening from immediately replacing its fixture
    /// with a live scan before the screenshot is taken.
    var previewFixtureActive = false
    let powerMonitor = PowerMonitor()
    /// Tray panel is on screen — worth probing faster while the user reads it.
    @ObservationIgnored var trayOpen = false
    @ObservationIgnored var activity: ProbeSchedule.Activity = .empty
    @ObservationIgnored var currentInterval: TimeInterval?
    /// Live-process fingerprint; a change forces a harvest even off-cadence.
    @ObservationIgnored var lastProcessSignature = ""
    @ObservationIgnored var ticksSinceHarvest = Int.max
    /// Last value actually pushed to launchd — avoids re-running launchctl
    /// (two synchronous subprocesses) on every settings write.
    @ObservationIgnored var appliedLaunchAtLogin: Bool?
    /// Rolling scan counters, so the energy claim can be checked, not believed.
    @ObservationIgnored var probeStats = ProbeStats()
    /// When the timer parked, for the parked-duration counter.
    @ObservationIgnored private var parkedSince: Date?
    /// First apply seeds waiting keys without firing edge notifications.
    @ObservationIgnored var waitingNotifySeeded = false
    /// One interruption per short window keeps a burst of parallel approvals
    /// useful without turning Notification Center into a stream of duplicates.
    static let waitingNotificationMinimumIntervalMs: Int64 = 3_000
    @ObservationIgnored var waitingDeliveryTask: Task<Void, Never>?
    /// Notification Center accepts requests asynchronously. Keep the event
    /// in-flight until its callback arrives so a fast follow-up scan cannot
    /// post a duplicate or mark a failed request as delivered.
    @ObservationIgnored var waitingDeliveryInFlight: Set<String> = []
    /// 23.0: the one record of what each session did — state spans, and
    /// every wait with its banner's fate, the owed banners (`queuedKeys`),
    /// dismissals (`suppressedKeys`) and the edge baseline (`waitingKeys`).
    /// Deliberately separate from the agent-owned attention.tsv bridge so a
    /// restart cannot lose the only human-confirmation edge or emit it
    /// twice. Changed only through `updateLog`; read by views through
    /// `logRevision`, which moves only when the log did.
    @ObservationIgnored var sessionLog = SessionLog()
    var logRevision = 0
    let sessionLogStore = SessionLogStore()
    /// The next scan is the first since the log was loaded.
    @ObservationIgnored var logAwaitsFirstScan = true
    /// 22.0: the tray has an open detail view or a typed filter, so Escape
    /// belongs to it before it closes the panel. Not observed: only the
    /// panel's key monitor reads it.
    @ObservationIgnored var trayEscapeConsumed = false
    @ObservationIgnored var lastApplyLogSignature = ""
    let attentionWatcher = AttentionWatcher()
    let scanQueue = DispatchQueue(label: "com.pulse.scan", qos: .userInitiated)
    @ObservationIgnored var scanTicket: UInt64 = 0
    @ObservationIgnored var lastAppliedTicket: UInt64 = 0
    /// Tests exercising store behaviour must not start a real background scan.
    ///
    /// A scan is not read-only: it writes attention files and, once
    /// `start()` has loaded it, the session log — so an unguarded `refresh()`
    /// inside a unit test would touch the developer's own files. Same shape as `AttentionIO.pathOverride`
    /// and `HooksInstaller.homeOverride`.
    static var suppressBackgroundScansForTesting = false

    @ObservationIgnored var scanInFlight = false
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

    @ObservationIgnored var pendingRefresh: PendingRefresh?
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
    var traySessionToken: Int = 0

    /// Current cadence, for Settings/diagnostics ("probing every 5s").
    var probeIntervalDescription: String {
        guard let interval = currentInterval else { return tr(.probeParked) }
        return String(format: tr(.probeEvery), Int(interval.rounded()))
    }

    /// Close an open parked span.
    private func settleParked() {
        guard let since = parkedSince else { return }
        probeStats.addParked(Date().timeIntervalSince(since))
        parkedSince = nil
    }

    func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
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
                store.refresh(reason: "timer")
                // One date comparison unless a day has passed since the last
                // answer — how a Mac that never sleeps still re-checks.
                UpdateCheck.shared.startIfEnabled(store: store)
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
    @ObservationIgnored var withdrawWaitingBanners: () -> Void = { PulseNotify.withdrawWaitingNotifications() }

    /// When set, Settings expands the App Data scopes group and highlights
    /// this agent — used by Support Health and quality next-step deep links.
    var settingsFocusAppDataAgent: AgentID? = nil
    var settingsExpandAppDataScopes = false
    /// When true, Settings scrolls/highlights the Waiting signals section
    /// (Attention bridge path for agents without a native Waiting contract).
    var settingsFocusWaitingSignals = false
    /// 22.0: moves on every deep link, so a second link to the same place
    /// still scrolls there.
    var settingsFocusToken = 0
    /// One-shot tray identity for Go-Look Closure: notify / hotkey / jump
    /// seeds a `rowKey`, TrayPanel selects+scrolls it, then clears.
    private(set) var pendingRevealRowKey: String? = nil

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

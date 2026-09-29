import Foundation
import AppKit
import Observation

/// The model every view reads (23.0): UI-facing state and the intents a view
/// may send. Nothing else.
///
/// Three classes share what used to be one ~100-property store:
///
/// - `ScanEngine` (not observed) owns the cadence, the background scan and
///   every piece of bookkeeping a scan keeps between passes. It hands each
///   finished scan to `land(_:snapshot:nowMs:)`.
/// - `WaitNotifier` (not observed) owns the "needs you" banner: planning,
///   posting, rate limiting, outcomes and clicks.
/// - `StatusStore` (this, `@Observable`) holds the snapshot and rows, the
///   settings, the session log's revision and a handful of UI flags. A view
///   is invalidated only by the properties its body read, and Observation
///   announces every assignment, equal or not — so every write on the scan
///   path is guarded: a property is assigned only when its value changed.
///   `ScanQuietTests` tracks every observed property here and holds it to
///   that.
@MainActor
@Observable
final class StatusStore {
    // MARK: Observed — what views draw

    var snapshot = PulseSnapshot()
    /// Every row the last scan produced (the tray's visible window is
    /// `snapshot.rows`); search, Health and focus read this.
    var cachedAll: [AgentRow] = []
    /// The person's settings, persisted as `settings.json`. Change them
    /// through `set(_:_:)` / `setReadProtectedAppData(_:)` so the change is
    /// saved and applied.
    var settings = PulseSettings()
    /// Moves only when the session log did; views that draw the log read it.
    var logRevision = 0
    var isRefreshing = false
    /// The tray shows every row rather than its visible window.
    var showAllAgents = false
    var hooksStatus: HooksSupport.Status = .unknown
    var hookSelfTestResult: HooksSupport.SelfTestResult = .idle
    /// False when the system refused the shortcut (another app owns it).
    var hotkeyRegistered = true
    /// Whether launchd was actually left in the state `launchAtLogin` claims.
    /// `nil` until the toggle has been applied at least once this run.
    var loginItemApplied: Bool?
    /// Notification authorization — a denied prompt used to fail silently.
    var notifyAuthorized: Bool?
    /// 21.0: Notification Center refused the last "needs you" banner.
    var waitingBannerFailed = false
    /// True when the latest harvest stopped before every adapter reported.
    var collectorScanIncomplete = false
    var updateStatus: UpdateCheck.Status = .idle
    /// What happened the last time the user pressed a button on this row —
    /// a click that reached nothing says so, briefly.
    var rowActionNotices: [String: String] = [:]
    /// One-shot tray identity for Go-Look Closure: notify / hotkey / jump
    /// seeds a `rowKey`, TrayPanel selects+scrolls it, then clears.
    private(set) var pendingRevealRowKey: String?
    /// A new glance is about to start — discard the last one's navigation.
    ///
    /// EXPERIENCE §4: "展开状态不持久化". The panel is built once and only
    /// ordered in and out, so SwiftUI keeps every `@State` it ever had.
    /// Bumping this token gives `TrayPanel` a new identity, which resets all
    /// of its state at once.
    private(set) var traySessionToken = 0
    /// Where Settings should scroll when it opens from a deep link.
    private(set) var settingsFocus = SettingsFocus()
    /// The Health window's buttons and the self-check's last result.
    var diagnostics = DiagnosticsState()

    // MARK: Not observed

    /// 23.0: the one record of what each session did. Changed only through
    /// `updateLog`; read by views through `logRevision`.
    @ObservationIgnored var sessionLog = SessionLog()
    /// The next scan is the first since the log was loaded.
    @ObservationIgnored var logAwaitsFirstScan = true
    /// 22.0: the tray has an open detail view or a typed filter, so Escape
    /// belongs to it before it closes the panel. Only the panel's key
    /// monitor reads it.
    @ObservationIgnored var trayEscapeConsumed = false
    /// Prevent a preview panel opening from immediately replacing its fixture
    /// with a live scan before the screenshot is taken. Set by the CLI-only
    /// fixture before anything renders.
    @ObservationIgnored var previewFixtureActive = false
    /// Deterministic event ages for visual fixtures only.
    @ObservationIgnored var previewWaitingEventTimes: [AgentID: Int64]?
    /// Last value actually pushed to launchd — avoids re-running launchctl
    /// (two synchronous subprocesses) on every settings write.
    @ObservationIgnored private var appliedLaunchAtLogin: Bool?
    /// Settings are saved and applied (launchd, the shortcut, a rescan) only
    /// once `start()` has read them, so a store a test or a fixture builds
    /// never touches the developer's own file or login items.
    @ObservationIgnored private var started = false

    let engine: ScanEngine
    let notifier: WaitNotifier
    let sessionLogStore = SessionLogStore()
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    init() {
        engine = ScanEngine()
        notifier = WaitNotifier()
        engine.model = self
        notifier.model = self
    }

    // MARK: - Language

    var language: AppLanguage {
        get { settings.language }
        set { settings.language = newValue }
    }

    var lang: ResolvedLanguage { settings.language.resolved }

    func tr(_ key: L10n.Key) -> String { L10n.t(key, lang) }

    func relative(_ date: Date) -> String {
        if date == .distantPast { return tr(.notYet) }
        let ago = Date().timeIntervalSince(date)
        if ago < 5 { return tr(.justNow) }
        relativeFormatter.locale = lang == .zh ? Locale(identifier: "zh-Hans") : Locale(identifier: "en_US")
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Lifecycle

    func start() {
        DebugLog.write("start begin \(PulseVersion.fingerprint)")
        // Restore only Pulse-owned attention state. Agent-owned hooks remain
        // the source of truth for the current row; the session log supplies
        // the cross-launch baseline, delivery dedupe and dismissals.
        loadSessionLog()
        notifier.seeded = sessionLog.baselineEstablished
        HooksSupport.seedAssets()
        landHooksStatus(HooksSupport.probeStatus())
        loadSettings()
        applyHotkey()
        notifier.start()
        engine.start()
        UpdateCheck.shared.startIfEnabled(store: self)
        DebugLog.write("start armed")
    }

    func quit() {
        engine.stop()
        GlobalHotKey.uninstall()
        NSApp.terminate(nil)
    }

    func refresh() {
        refresh(reason: "manual")
    }

    func refresh(reason: String, agentFilter: Set<AgentID>? = nil) {
        engine.refresh(reason: reason, agentFilter: agentFilter)
    }

    // MARK: - What the engine and the notifier hand over

    /// One finished scan. Each observed property is assigned only when its
    /// value changed; a scan that finds the same world announces nothing.
    func land(_ result: SnapshotBuilder.Result, snapshot next: PulseSnapshot, nowMs: Int64) {
        for (oldKey, newKey) in result.remappedRowKeys {
            notifier.followRemap(from: oldKey, to: newKey)
        }
        let previousRows = cachedAll
        setCachedAll(result.rows)
        if showAllAgents != result.showAllAgents { showAllAgents = result.showAllAgents }
        // Reconcile before delivery so a restart can distinguish an already
        // known wait from a newly crossed edge. Spans, waits, released soft
        // dismissals and the baseline move in one change; a scan that finds
        // the same world changes nothing and writes nothing.
        recordScan(previous: previousRows, result: result, nowMs: nowMs)
        notifier.scanLanded(result, nowMs: nowMs)
        // 12.4 Surface: a scan that found the same world leaves `snapshot`
        // alone — except when a relative-time label on screen is due to move.
        if PulseSnapshot.needsPublish(next: next, current: snapshot) {
            snapshot = next
        }
    }

    /// The watcher's light path: patch matching rows in place.
    func landActivityEvents(_ events: [ActivitySpool.Event], nowMs: Int64) {
        var byKey: [String: ActivitySpool.Event] = [:]
        for event in events {
            guard let agent = AgentID(rawValue: event.agent)?.surfaceID else { continue }
            byKey[agent.rawValue + "|" + event.session] = event
        }
        guard !byKey.isEmpty else { return }
        func patch(_ rows: inout [AgentRow]) -> Bool {
            var changed = false
            for index in rows.indices where !rows[index].sessionID.isEmpty {
                let key = rows[index].agent.rawValue + "|" + rows[index].sessionID
                guard let event = byKey[key] else { continue }
                var row = rows[index]
                row.applyActivity(event, nowMs: nowMs)
                if row != rows[index] {
                    rows[index] = row
                    changed = true
                }
            }
            return changed
        }
        var rows = cachedAll
        if patch(&rows) {
            setCachedAll(rows)
        }
        var next = snapshot
        if patch(&next.rows) {
            snapshot = next
        }
    }

    /// The merged rows every surface reads. Re-merged on every scan, so the
    /// write is guarded: an identical merge must not wake the tray.
    func setCachedAll(_ rows: [AgentRow]) {
        if rows != cachedAll { cachedAll = rows }
    }

    func setRefreshing(_ value: Bool) {
        if isRefreshing != value { isRefreshing = value }
    }

    func landCollectorScanIncomplete(_ value: Bool) {
        if collectorScanIncomplete != value { collectorScanIncomplete = value }
    }

    func landNotifyAuthorized(_ value: Bool?) {
        if notifyAuthorized != value { notifyAuthorized = value }
    }

    func landWaitingBannerFailed(_ value: Bool) {
        if waitingBannerFailed != value { waitingBannerFailed = value }
    }

    func landHooksStatus(_ value: HooksSupport.Status) {
        if hooksStatus != value { hooksStatus = value }
    }

    func landUpdateStatus(_ value: UpdateCheck.Status) {
        if updateStatus != value { updateStatus = value }
    }

    // MARK: - Settings

    /// Read `settings.json` (a pre-23.0 `settings.txt` is deleted, unread).
    /// With no file, whatever the store holds stays — the defaults, or a
    /// `--language=` the command line set.
    func loadSettings() {
        if let loaded = PulseSettings.loadIfPresent() {
            if loaded != settings { settings = loaded }
            DebugLog.write("settings \(loaded.debugDescription)")
        }
        started = true
        // Launchd already reflects the persisted value at load; don't re-run it.
        appliedLaunchAtLogin = settings.launchAtLogin
    }

    /// Change one setting, save it, and apply what it affects.
    func set<Value: Equatable>(_ keyPath: WritableKeyPath<PulseSettings, Value>, _ value: Value) {
        guard settings[keyPath: keyPath] != value else { return }
        settings[keyPath: keyPath] = value
        guard started else { return }
        settings.save()
        // Banner button titles are baked into the registered category, so they
        // go stale on a language switch unless re-registered here.
        notifier.languageChanged(lang)
        applyLaunchAtLoginIfChanged()
        applyHotkey()
        UpdateCheck.shared.startIfEnabled(store: self)
        engine.rescheduleTimer()
        refresh(reason: "saveSettings")
    }

    /// The one app-data switch. Only the protected agents need a new
    /// harvest pass, so the rescan is scoped to them.
    func setReadProtectedAppData(_ enabled: Bool) {
        guard settings.readProtectedAppData != enabled else { return }
        settings.readProtectedAppData = enabled
        persistSettings()
        let protected = Set(AgentID.allCases.filter(\.requiresAppDataOptIn))
        refresh(reason: "appData", agentFilter: protected)
    }

    func toggleMute(_ agent: AgentID) {
        var muted = settings.mutedAgents
        if muted.contains(agent) {
            muted.remove(agent)
        } else {
            muted.insert(agent)
        }
        set(\.mutedAgents, muted)
    }

    private func persistSettings() {
        guard started else { return }
        settings.save()
    }

    private func applyLaunchAtLoginIfChanged() {
        guard appliedLaunchAtLogin != settings.launchAtLogin else { return }
        appliedLaunchAtLogin = settings.launchAtLogin
        let enabled = settings.launchAtLogin
        DispatchQueue.global(qos: .utility).async {
            let applied = LoginItem.setEnabled(enabled)
            Task { @MainActor [weak self] in
                if self?.loginItemApplied != applied { self?.loginItemApplied = applied }
            }
        }
    }

    /// Re-register the global shortcut and report honestly when the system
    /// refuses (another app already owns the combination).
    func applyHotkey() {
        let choice = settings.hotkey
        let registered = GlobalHotKey.install(choice: choice)
        if hotkeyRegistered != registered { hotkeyRegistered = registered }
        if choice != .off, !registered {
            DebugLog.write("hotkey \(choice.rawValue) registration FAILED — likely taken")
        }
    }

    /// Open Settings, optionally scrolled to a section: the app-data switch,
    /// or the hook connections (how an agent gets a Waiting signal).
    func openSettings(focus target: SettingsFocus.Target? = nil) {
        var next = settingsFocus
        next.target = target
        if target != nil { next.token &+= 1 }
        if next != settingsFocus { settingsFocus = next }
        SettingsWindowController.shared.show(store: self)
    }

    // MARK: - Tray lifecycle

    func trayWillAppear() {
        traySessionToken &+= 1
        // Store-owned, and just as much "last time's rummaging" as the folds.
        if showAllAgents {
            showAllAgents = false
            applyRowWindow()
        }
    }

    /// Tray panel appeared — probe faster while the user is looking at it.
    func trayDidAppear() {
        engine.setTrayOpen(true)
        if !previewFixtureActive {
            refresh(reason: "trayOpen")
        }
    }

    func trayDidDisappear() {
        engine.setTrayOpen(false)
    }

    func toggleShowAllAgents() {
        showAllAgents.toggle()
        applyRowWindow()
    }

    func applyRowWindow() {
        var snap = snapshot
        SnapshotBuilder.window(
            rows: cachedAll,
            showAll: showAllAgents,
            maxVisible: SnapshotBuilder.maxVisibleRows,
            into: &snap
        )
        if snap != snapshot { snapshot = snap }
    }

    /// Open the tray, optionally selecting a concrete row after it appears.
    func requestTrayReveal(rowKey: String = "") {
        if !rowKey.isEmpty {
            pendingRevealRowKey = rowKey
        }
        TrayReveal.show()
    }

    func clearPendingRevealRowKey() {
        if pendingRevealRowKey != nil { pendingRevealRowKey = nil }
    }

    // MARK: - Row intents

    func rowActionNotice(_ row: AgentRow) -> String? {
        rowActionNotices[row.rowKey]
    }

    /// Say what happened, briefly. Long enough to read, short enough that it
    /// never settles in and becomes row furniture.
    func noteRowAction(_ rowKey: String, _ message: String) {
        rowActionNotices[rowKey] = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            guard let self, self.rowActionNotices[rowKey] == message else { return }
            self.rowActionNotices.removeValue(forKey: rowKey)
        }
    }

    func primaryAction(_ row: AgentRow) {
        guard row.canFocusTerminal else { return }
        focusTerminal(row)
    }

    /// The focus handle was derived by the scan that produced this row, and a
    /// window can close between then and the click. When nothing was reached,
    /// say so and rescan: the next row either carries a handle that works or
    /// stops offering one.
    func focusTerminal(_ row: AgentRow) {
        if row.yourTurn { markTurnSeen(row) }
        guard !TerminalFocus.focus(row: row) else { return }
        noteRowAction(row.rowKey, tr(.focusFailed))
        refresh(reason: "focus-failed")
    }

    /// Looking at a finished session is what "your turn" was asking for. A
    /// session-scoped `done` in the attention file is the record — it
    /// survives a restart, and it is the same line a new prompt would write.
    func markTurnSeen(_ row: AgentRow) {
        guard row.yourTurn, !row.doneSession.isEmpty else { return }
        AttentionIO.appendDone(agent: row.agent, session: row.doneSession)
        refresh(reason: "turn-seen")
    }

    /// A harvest `pending` — or a vendor-reported wait (18.0) — is dismissed
    /// softly: its source keeps reporting it until the session moves, so the
    /// log keeps it suppressed until then.
    nonisolated static func dismissIsSoft(_ row: AgentRow) -> Bool {
        row.waitSignal == .pending || row.waitSignal == .vendor || row.skill == "pending"
    }

    func dismissWaiting(_ row: AgentRow) {
        let isHarvestPending = Self.dismissIsSoft(row)
        // 0.95: pure harvest soft-dismiss must not write agent-wide Attention
        // done (empty session clears every wait for that agent).
        if row.waitSignal == .hooks {
            AttentionIO.appendDone(agent: row.agent, session: row.doneSession)
        } else if !isHarvestPending, !row.doneSession.isEmpty {
            AttentionIO.appendDone(agent: row.agent, session: row.doneSession)
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        updateLog(immediately: true) { log in
            _ = log.dismiss(row, soft: isHarvestPending, nowMs: nowMs)
        }
        refresh(reason: "dismissWaiting")
    }

    func clearWaiting() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // 0.95: a dismissed wait is no longer owed a banner
        // (`SessionLog.queuedKeys`). 2.2: `center.add` is asynchronous — a
        // request accepted a moment before the click still lands after the
        // user cleared Waiting, so take back what was already submitted too
        // (scene AH, U-7).
        notifier.withdrawAll()
        let waiting = cachedAll.filter(\.waiting)
        updateLog(immediately: true) { log in
            for row in waiting {
                log.dismiss(row, soft: Self.dismissIsSoft(row), nowMs: nowMs)
            }
        }
        AttentionIO.clearAll()
        refresh(reason: "clearWaiting")
    }

    /// Live Waiting-none session — needs Attention Reach, not a fake Waiting chip.
    func isWaitingNoneNeedsReach(_ row: AgentRow) -> Bool {
        !row.waiting
            && row.liveProcess
            && row.agent.waitingSource == .none
    }

    /// Open Waiting signals (how an agent without a Waiting path gets one).
    func openWaitingReach(for row: AgentRow) {
        openSettings(focus: .waitingSignals)
    }

    // MARK: - Focus

    /// The row that has been blocked longest, if any.
    var oldestWait: AgentRow? {
        Self.oldestWaitRow(in: cachedAll)
    }

    nonisolated static func oldestWaitRow(in rows: [AgentRow]) -> AgentRow? {
        let waiting = rows.filter(\.waiting)
        return waiting
            .filter { $0.waitSinceMs > 0 }
            .min { $0.waitSinceMs < $1.waitSinceMs }
            ?? waiting.first
    }

    nonisolated static func firstWaitingRow(in rows: [AgentRow]) -> AgentRow? {
        rows.first(where: \.waiting)
    }

    /// Focus the longest-outstanding wait.
    func focusOldestWait() {
        guard let row = oldestWait else { return }
        DebugLog.write("jump to oldest wait \(DebugLog.key(row.rowKey))")
        focusAgent(idRaw: row.agent.rawValue, session: row.sessionID, rowKey: row.rowKey)
    }

    /// 16.0: the finished session that has waited longest for a look.
    var oldestTurn: AgentRow? {
        cachedAll.filter(\.yourTurn).min { $0.turnSinceMs < $1.turnSinceMs }
    }

    /// Blocked first, then "your turn".
    func focusNextTurn() {
        guard let row = oldestTurn else { return }
        DebugLog.write("jump to turn \(DebugLog.key(row.rowKey))")
        focusAgent(idRaw: row.agent.rawValue, session: row.sessionID, rowKey: row.rowKey)
    }

    func focusFirstWaiting() {
        if let row = Self.firstWaitingRow(in: cachedAll) ?? Self.firstWaitingRow(in: snapshot.rows) {
            focusAgent(idRaw: row.agent.rawValue, session: row.sessionID, rowKey: row.rowKey)
            return
        }
        requestTrayReveal()
    }

    /// Resolve a notify / hotkey / jump target, attempt best Focus, and always
    /// keep tray row identity for Waiting (Go-Look Closure). Focus success must
    /// not abandon the row that raised the interruption.
    func focusAgent(idRaw: String, session: String = "", rowKey: String = "") {
        let row = Self.focusTarget(in: cachedAll, idRaw: idRaw, session: session, rowKey: rowKey)
        if let row {
            let didFocus = row.canFocusTerminal && TerminalFocus.focus(row: row)
            if row.yourTurn { markTurnSeen(row) }
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

    /// Prefer exact `rowKey`, then session, then first waiting/live row for
    /// agent. The session match stays inside the named agent and takes a
    /// prefix only when exactly one row fits — the same rule the builder
    /// applies to attention ids, so a truncated id cannot send a banner click
    /// to the wrong row.
    nonisolated static func focusTarget(
        in rows: [AgentRow], idRaw: String, session: String, rowKey: String
    ) -> AgentRow? {
        if !rowKey.isEmpty, let row = rows.first(where: { $0.rowKey == rowKey }) {
            return row
        }
        let agent = ActivityHarvest.mapAgent(idRaw)?.surfaceID
        if !session.isEmpty {
            let sameAgent = rows.filter { !$0.sessionID.isEmpty && (agent == nil || $0.agent == agent) }
            if let exact = sameAgent.first(where: { $0.sessionID == session }) { return exact }
            let prefixed = sameAgent.filter {
                session.hasPrefix($0.sessionID) || $0.sessionID.hasPrefix(session)
            }
            if prefixed.count == 1 { return prefixed[0] }
        }
        guard let id = agent else { return nil }
        let own = rows.filter { $0.agent == id }
        return firstWaitingRow(in: own) ?? own.first
    }

    // MARK: - Hooks

    func installHooks() {
        landHooksStatus(.unknown)
        setHooksNudgeOff(false)
        // `Task` inherits this class's main-actor isolation, so the assignment
        // lands on main while the optional hook installer stays off it.
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                HooksSupport.install()
            }.value
            self?.landHooksStatus(status)
        }
    }

    func uninstallHooks() {
        landHooksStatus(.unknown)
        // An uninstall is a decision: stop suggesting hooks until the user
        // installs them again.
        setHooksNudgeOff(true)
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                HooksSupport.uninstall()
            }.value
            self?.landHooksStatus(status)
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

    /// Persist the "don't suggest hooks" choice without a full rescan.
    private func setHooksNudgeOff(_ value: Bool) {
        guard settings.hooksNudgeOff != value else { return }
        settings.hooksNudgeOff = value
        persistSettings()
    }

    var hooksInstalled: Bool {
        switch hooksStatus {
        case .installedBoth, .installedClaude, .installedCodex: return true
        case .unknown, .missing, .failed: return false
        }
    }

    // MARK: - Notifications and updates

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

    func openSupportHealth() {
        SupportCoverageWindowController.shared.show(store: self)
    }
}

/// Where Settings scrolls when a deep link opens it. The token moves on
/// every deep link, so a second link to the same place still scrolls there.
struct SettingsFocus: Equatable {
    enum Target: Equatable {
        case appData
        case waitingSignals
    }

    var target: Target?
    var token = 0
}

/// The Health window's transient button states and the self-check's result.
struct DiagnosticsState: Equatable {
    var doctorReport: DoctorModel.Report?
    var isRunningDoctor = false
    var didCopyDoctorReport = false
    /// The shape report walks the session stores, so the button says so.
    var isCopyingShapeReport = false
    var didCopyShapeReport = false
    /// Transient "Copied" confirmation on the diagnostics button.
    var didCopyDiagnostics = false
}

// MARK: - 12.4 Surface: publish only what changed

extension PulseSnapshot {
    /// Equal in everything a surface draws — `updatedAt` aside.
    func sameContent(as other: PulseSnapshot) -> Bool {
        var mine = self
        mine.updatedAt = other.updatedAt
        return mine == other
    }

    /// Below a minute, durations are drawn in seconds (`DurationFormat`).
    static let secondsLabelWindowMs: Int64 = 60_000
    /// Minute labels need a redraw at most this often when nothing else moved.
    static let minuteLabelRefresh: TimeInterval = 60

    /// Whether `next` must replace `current` for the surfaces to stay true.
    ///
    /// Content changed → yes. Otherwise only the clock can make a drawn fact
    /// stale: a row whose wait or activity is younger than a minute shows a
    /// seconds count that moves every scan, and minute labels move once a
    /// minute. Nothing else about an unchanged world is worth a redraw.
    static func needsPublish(next: PulseSnapshot, current: PulseSnapshot) -> Bool {
        if current.updatedAt == .distantPast { return true }
        if !next.sameContent(as: current) { return true }
        let nowMs = Int64(next.updatedAt.timeIntervalSince1970 * 1000)
        let secondsOnScreen = next.rows.contains { row in
            let newest = max(row.waitSinceMs, row.activityChangedMs, row.harvestMs)
            return newest > 0 && nowMs - newest < secondsLabelWindowMs
        }
        if secondsOnScreen { return true }
        return next.updatedAt.timeIntervalSince(current.updatedAt) >= minuteLabelRefresh
    }
}

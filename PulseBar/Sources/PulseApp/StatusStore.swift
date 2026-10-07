import Foundation
import AppKit
import Observation

/// The model every view reads: UI-facing state and the intents a view may
/// send. Nothing else.
///
/// Three classes share the app's state:
///
/// - `ScanEngine` (not observed) owns the session book, the watchers, the
///   process scan and the tick. It hands each projection to
///   `land(_:nowMs:baseline:)`.
/// - `WaitNotifier` (not observed) owns the "needs you" banner: planning,
///   posting, rate limiting (its in-memory `WaitLedger`) and clicks.
/// - `StatusStore` (this, `@Observable`) holds the snapshot and rows, the
///   settings and a handful of UI flags. A view
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
    /// Every row the last scan produced (the same list as
    /// `snapshot.rows`); the open tray and focus read this.
    var cachedAll: [AgentRow] = []
    /// The person's settings, persisted as `settings.json`. Change them
    /// through `set(_:_:)` so the change is saved and applied.
    var settings = PulseSettings()
    var hooksStatus: HooksSupport.Status = .unknown
    /// Agents whose vendor folder is on this Mac (`HooksInstaller.vendorPresent`)
    /// — read at launch and when the tray opens; never on the scan path.
    var presentAgents: Set<AgentID> = []
    /// The agents the setup card just connected: the card shows what is
    /// left to do until "Got it". nil otherwise; not saved.
    var setupConnected: Set<AgentID>?
    /// Pulse's login item as macOS reports it (`SMAppService`); nil until
    /// read. The Settings toggle shows this, not what was asked.
    var loginItem: LoginItemState?
    /// Notification authorization — a denied prompt used to fail silently.
    var notifyAuthorized: Bool?
    /// Notification Center refused the last "needs you" banner.
    var waitingBannerFailed = false
    /// What happened the last time the user pressed a button on this row —
    /// a click that reached nothing says so, briefly (and, once, what would
    /// make it land exactly).
    var rowActionNotices: [String: RowNotice] = [:]
    /// A new glance is about to start — discard the last one's navigation.
    ///
    /// EXPERIENCE §4: "展开状态不持久化". The panel is built once and only
    /// ordered in and out, so SwiftUI keeps every `@State` it ever had.
    /// Bumping this token gives `TrayPanel` a new identity, which resets all
    /// of its state at once.
    private(set) var traySessionToken = 0
    /// Where Settings should scroll when it opens from a deep link.
    private(set) var settingsFocus = SettingsFocus()

    // MARK: Not observed

    /// One-shot tray identity for Go-Look Closure: a banner or a jump seeds
    /// a `rowKey` (and whether to open its detail); the panel takes it when
    /// it opens — or at once, when it is already open. Not observed: the
    /// panel reads it at those two moments, no view draws it.
    @ObservationIgnored private(set) var pendingRevealRowKey: String?
    @ObservationIgnored private(set) var pendingRevealDetail = false
    /// Prevent a preview panel opening from immediately replacing its fixture
    /// with a live scan before the screenshot is taken. Set by the QA
    /// fixture (`PulseQA`) before anything renders.
    @ObservationIgnored var previewFixtureActive = false
    /// Last value handed to `SMAppService` — a settings write that did not
    /// change it does not register again.
    @ObservationIgnored private var appliedLaunchAtLogin: Bool?
    /// Opens the tray. Tests replace it to see a reopen arrive; the app's
    /// is the status item's panel.
    @ObservationIgnored var showTray: @MainActor () -> Void = { TrayReveal.show() }
    /// Settings are saved and applied (the login item) only once `start()`
    /// has read them, so a store a test or a fixture builds never touches
    /// the developer's own file or login items.
    @ObservationIgnored private var started = false

    let engine: ScanEngine
    let notifier: WaitNotifier
    /// The interface's language: the system's (`ResolvedLanguage.system`),
    /// read once. A test passes one.
    let lang: ResolvedLanguage

    init(lang: ResolvedLanguage = .system) {
        self.lang = lang
        engine = ScanEngine()
        notifier = WaitNotifier()
        engine.model = self
        notifier.model = self
    }

    func tr(_ key: L10n.Key) -> String { L10n.t(key, lang) }

    // MARK: - Lifecycle

    func start() {
        DebugLog.write("start begin \(PulseVersion.fingerprint)")
        HooksSupport.seedAssets()
        landHooksStatus(HooksSupport.probeStatus())
        refreshPresentAgents()
        loadSettings()
        refreshLoginItem()
        notifier.start()
        engine.start()
        DebugLog.write("start armed")
    }

    func quit() {
        engine.stop()
        NSApp?.terminate(nil)
    }

    func refresh(reason: String) {
        engine.refresh(reason: reason)
    }

    /// Pulse was opened again while it runs — from Finder, Spotlight, the
    /// Dock's recent items or a second copy (`SingleInstanceGuard`): the
    /// person wants to see it, so the tray opens as a menu-bar click opens
    /// it, on the oldest wait. Never a window of its own.
    func reopen() {
        DebugLog.write("reopen")
        requestTrayReveal()
    }

    // MARK: - What the engine and the notifier hand over

    /// One projection. Each observed property is assigned only when its
    /// value changed; a projection that finds the same world announces
    /// nothing. `baseline`: the event log has not been read yet (or
    /// this is the projection of its first read) — a wait already there is
    /// not a new one.
    func land(_ state: TrayState, nowMs: Int64, baseline: Bool = false) {
        setCachedAll(state.rows)
        notifier.scanLanded(state, nowMs: nowMs, baseline: baseline)
        // A scan that found the same world leaves `snapshot` alone — except
        // when a relative-time label on screen is due to move.
        if PulseSnapshot.needsPublish(next: state.snapshot, current: snapshot) {
            snapshot = state.snapshot
        }
    }

    /// The merged rows every surface reads. Re-merged on every scan, so the
    /// write is guarded: an identical merge must not wake the tray.
    func setCachedAll(_ rows: [AgentRow]) {
        if rows != cachedAll { cachedAll = rows }
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

    /// Which agents are on this Mac: seven directory checks.
    func refreshPresentAgents() {
        let present = Set(AgentID.priority.filter(HooksInstaller.vendorPresent))
        if presentAgents != present { presentAgents = present }
    }

    // MARK: - Settings

    /// Read `settings.json`. With no file, the defaults stay.
    func loadSettings() {
        if let loaded = PulseSettings.loadIfPresent() {
            if loaded != settings { settings = loaded }
            DebugLog.write("settings \(loaded.debugDescription)")
        }
        started = true
        // macOS already holds the login item; `refreshLoginItem` reads it.
        appliedLaunchAtLogin = settings.launchAtLogin
    }

    /// Change one setting, save it, and apply what it affects.
    func set<Value: Equatable>(_ keyPath: WritableKeyPath<PulseSettings, Value>, _ value: Value) {
        update { $0[keyPath: keyPath] = value }
    }

    /// Change any number of settings at once: one assignment, one save, and
    /// what the change needs applied once (`applyEffects`).
    func update(_ change: (inout PulseSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let before = settings
        settings = next
        guard started else { return }
        settings.save()
        applyEffects(from: before, to: next)
    }

    /// What a change from `before` to `after` needs outside the file: the
    /// login item, when it changed. Everything else is read where it is
    /// used.
    private func applyEffects(from before: PulseSettings, to after: PulseSettings) {
        if before.launchAtLogin != after.launchAtLogin { applyLaunchAtLoginIfChanged() }
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
            let state = LoginItem.setEnabled(enabled)
            Task { @MainActor [weak self] in
                self?.landLoginItem(state)
            }
        }
    }

    /// The login toggle. It shows what
    /// macOS says, so it can read off while the setting is on (macOS did not
    /// take it, or the person removed Pulse in System Settings): the same
    /// answer asks macOS again rather than doing nothing.
    func setLaunchAtLogin(_ on: Bool) {
        if started, settings.launchAtLogin == on, let state = loginItem, state.isOn != on {
            appliedLaunchAtLogin = nil
            applyLaunchAtLoginIfChanged()
            return
        }
        set(\.launchAtLogin, on)
    }

    func landLoginItem(_ state: LoginItemState) {
        if loginItem != state { loginItem = state }
    }

    /// Read the login item — at launch, Settings opening, the app coming
    /// forward: the person may have changed it in System Settings. macOS is
    /// the truth; the setting follows it.
    func refreshLoginItem() {
        guard started, !previewFixtureActive else { return }
        DispatchQueue.global(qos: .utility).async {
            let state = LoginItem.state
            Task { @MainActor [weak self] in
                self?.syncLoginItem(state)
            }
        }
    }

    /// What macOS says becomes the setting, quietly: saved, nothing applied.
    private func syncLoginItem(_ state: LoginItemState) {
        landLoginItem(state)
        let on = state.isOn
        appliedLaunchAtLogin = on
        guard settings.launchAtLogin != on else { return }
        settings.launchAtLogin = on
        persistSettings()
    }

    /// Open Settings, optionally scrolled to a section — the hook connections
    /// (how an agent gets a Waiting signal) or notifications.
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
        if !previewFixtureActive { refreshPresentAgents() }
    }

    /// Tray panel appeared — tick faster while the user is looking at it.
    func trayDidAppear() {
        engine.setTrayOpen(true)
        if !previewFixtureActive {
            refresh(reason: "trayOpen")
        }
    }

    func trayDidDisappear() {
        engine.setTrayOpen(false)
    }

    /// Open the tray, optionally selecting a concrete row — and opening its
    /// detail — once it is on screen.
    func requestTrayReveal(rowKey: String = "", detail: Bool = false) {
        pendingRevealRowKey = rowKey.isEmpty ? nil : rowKey
        pendingRevealDetail = detail && !rowKey.isEmpty
        showTray()
    }

    func clearPendingRevealRowKey() {
        pendingRevealRowKey = nil
        pendingRevealDetail = false
    }

    /// The pending reveal, once: the panel takes it and it is gone.
    func takePendingReveal() -> (rowKey: String, detail: Bool)? {
        guard let key = pendingRevealRowKey, !key.isEmpty else { return nil }
        let detail = pendingRevealDetail
        clearPendingRevealRowKey()
        return (key, detail)
    }

    // MARK: - Row intents

    func rowActionNotice(_ row: AgentRow) -> RowNotice? {
        rowActionNotices[row.rowKey]
    }

    /// Say what happened, briefly. Long enough to read, short enough that it
    /// never settles in and becomes row furniture.
    func noteRowAction(_ rowKey: String, _ message: String) {
        noteRowAction(rowKey, RowNotice(text: message))
    }

    func noteRowAction(_ rowKey: String, _ notice: RowNotice) {
        rowActionNotices[rowKey] = notice
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            guard let self, self.rowActionNotices[rowKey] == notice else { return }
            self.rowActionNotices.removeValue(forKey: rowKey)
        }
    }

    /// The landing plan was made by the projection that produced this row,
    /// and a window can close between then and the click. Say how it landed,
    /// never rounded up: exact says nothing, the app alone says so, and
    /// nothing reached says so and re-reads — the next row either carries a
    /// handle that works or stops offering one.
    func focusTerminal(_ row: AgentRow) {
        if row.isYourTurn { markTurnSeen(row) }
        reportLanding(TerminalFocus.land(row.landingPlan), row: row)
    }

    func reportLanding(_ outcome: LandingOutcome, row: AgentRow) {
        switch outcome {
        case .exact:
            return
        case .appOnly:
            noteAppOnly(row)
        case .failed:
            noteRowAction(row.rowKey, tr(.focusFailed))
            refresh(reason: "focus-failed")
        }
    }

    /// The Go reached the app, not the exact terminal: the notice says so,
    /// and where macOS's Automation permission is when a script was tried.
    private func noteAppOnly(_ row: AgentRow) {
        noteRowAction(row.rowKey, RowNotice.appOnly(row: row, lang: lang))
    }

    /// Looking at a finished session is what "your turn" was asking for. A
    /// session-scoped `done` in the event log is the record — it
    /// survives a restart, and it is the same line a new prompt would write.
    func markTurnSeen(_ row: AgentRow) {
        guard row.isYourTurn, !row.attentionSession.isEmpty else { return }
        writeDone(agent: row.agent, session: row.attentionSession, cwd: row.cwd)
    }

    /// The person dismissed a wait: a `done` in the event log under
    /// exactly the session its entry carried — an empty one, with the
    /// row's folder, clears only that agent's session-less entry in that
    /// folder, never its other sessions — and no banner for it.
    func dismissWaiting(_ row: AgentRow) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        notifier.dismissed(row.rowKey)
        if let done = Self.doneLine(for: row) {
            writeDone(agent: done.agent, session: done.session, cwd: done.cwd, nowMs: nowMs)
        }
    }

    /// File writes for `done` lines, one at a time, off the main thread:
    /// the event log is locked, and a click must not wait on it.
    private static let doneWrites = DispatchQueue(label: "com.pulse.attention-done", qos: .userInitiated)

    /// A `done` line: applied to the book at once (the row moves under the
    /// click), appended to the event log off the main thread. The watch
    /// reads the line back; the book has already applied it, so it changes
    /// nothing.
    private func writeDone(agent: AgentID, session: String, cwd: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        let record = Self.dismissalRecord(agent: agent, session: session, cwd: cwd, nowMs: nowMs)
        // A preview fixture's rows are not the book's; leave them on screen.
        if !previewFixtureActive { engine.apply(records: [record], nowMs: nowMs) }
        let line = record.line
        Self.doneWrites.async {
            EventLog.append(line, nowMs: nowMs)
        }
    }

    /// The app's own `done` line, marked `:dismiss`
    /// (`AttentionRecord.dismissTool`): only it makes the vendor's echo of
    /// the same ask stay cleared (`SessionBook`); a vendor's "resolved" does
    /// not. Pure.
    nonisolated static func dismissalRecord(agent: AgentID, session: String, cwd: String, nowMs: Int64) -> AttentionRecord {
        AttentionRecord(
            agent: agent.rawValue,
            kind: AttentionKind.done.rawValue,
            ms: nowMs,
            session: AttentionProtocol.flatten(session),
            cwd: AttentionProtocol.flatten(cwd),
            tool: AttentionRecord.dismissTool
        )
    }

    /// The `done` a dismissal writes, with the entry's own session spelling
    /// (possibly empty) and its folder — what tells one session-less wait
    /// from another of the same agent. Pure.
    nonisolated static func doneLine(for row: AgentRow) -> (agent: AgentID, session: String, cwd: String)? {
        guard row.isBlocked else { return nil }
        return (row.agent, row.attentionSession, row.cwd)
    }

    // MARK: - Focus

    nonisolated static func firstWaitingRow(in rows: [AgentRow]) -> AgentRow? {
        rows.first(where: \.isBlocked)
    }

    /// Open the tray on the first wait (the projection lists the oldest first).
    func focusFirstWaiting() {
        if let row = Self.firstWaitingRow(in: cachedAll) ?? Self.firstWaitingRow(in: snapshot.rows) {
            requestTrayReveal(rowKey: row.rowKey)
            return
        }
        requestTrayReveal()
    }

    /// A banner click (or its Go button): the terminal, and nothing
    /// else, when it can be focused — the tray does not pop up over it. With
    /// no handle (or one that failed) the tray opens on the row's detail; a
    /// row that is gone opens the tray. `BannerRoute` decides.
    func focusAgent(idRaw: String, session: String = "", rowKey: String = "") {
        let row = Self.focusTarget(in: cachedAll, idRaw: idRaw, session: session, rowKey: rowKey)
        var focused = false
        if let row, row.canFocusTerminal {
            let outcome = TerminalFocus.land(row.landingPlan)
            focused = outcome != .failed
            if outcome == .appOnly { noteAppOnly(row) }
        }
        if let row, row.isYourTurn { markTurnSeen(row) }
        switch BannerRoute.decide(target: row?.rowKey, focused: focused) {
        case .terminal:
            return
        case .detail(let key):
            requestTrayReveal(rowKey: key, detail: true)
        case .tray:
            focusFirstWaiting()
        }
    }

    /// Prefer exact `rowKey`, then session, then first waiting/live row for
    /// agent. The session match stays inside the named agent and takes a
    /// prefix only when exactly one row fits — the same rule the builder
    /// used to apply to attention ids, so a truncated id cannot send a banner
    /// click to the wrong row.
    nonisolated static func focusTarget(
        in rows: [AgentRow], idRaw: String, session: String, rowKey: String
    ) -> AgentRow? {
        if !rowKey.isEmpty, let row = rows.first(where: { $0.rowKey == rowKey }) {
            return row
        }
        let agent = AgentCatalog.agent(named: idRaw)
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

    /// Installs and removals run one at a time (`HooksSupport.installQueue`)
    /// and the buttons are disabled while one runs (`.working`).
    func installHooks(then done: @escaping @MainActor @Sendable (HooksSupport.Status) -> Void = { _ in }) {
        runHooks(.install, then: done)
    }

    /// One install or removal of every agent's hook. An install clears
    /// "don't suggest hooks"; removing them sets it (a decision).
    func runHooks(
        _ job: HooksSupport.Job,
        then done: @escaping @MainActor @Sendable (HooksSupport.Status) -> Void = { _ in }
    ) {
        guard !hooksStatus.isWorking else { return }
        let previous = hooksStatus.failures
        landHooksStatus(.working)
        setHooksNudgeOff(job == .uninstall)
        // `Task` inherits this class's main-actor isolation, so the assignment
        // lands on main while the hook installer stays off it.
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                HooksSupport.run(job, previous: previous)
            }.value
            self?.landHooksStatus(status)
            done(status)
        }
    }

    /// The setup card's one click: install the hooks of every agent on this
    /// Mac, then ask macOS to allow banners (asked only if it never was),
    /// then show what is left — Codex's trust step, and that sessions
    /// already running appear after their next step.
    func connectFromSetup() {
        let before = hooksStatus.installedAgents
        installHooks { [weak self] status in
            guard let self else { return }
            self.requestNotificationAuthorization()
            let connected = status.installedAgents.subtracting(before)
            if !connected.isEmpty, self.setupConnected != connected { self.setupConnected = connected }
        }
    }

    /// Removing every hook is a decision: stop suggesting hooks until the
    /// user installs them again.
    func uninstallHooks() {
        runHooks(.uninstall)
    }

    /// Persist the "don't suggest hooks" choice without a full rescan.
    private func setHooksNudgeOff(_ value: Bool) {
        guard settings.hooksNudgeOff != value else { return }
        settings.hooksNudgeOff = value
        persistSettings()
    }

    var hooksInstalled: Bool {
        !hooksStatus.installedAgents.isEmpty
    }

    // MARK: - Notifications

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
}

/// Where Settings scrolls when a deep link opens it. The token moves on
/// every deep link, so a second link to the same place still scrolls there.
struct SettingsFocus: Equatable {
    enum Target: Equatable {
        /// The hooks: how an agent gets a "needs you" signal.
        case waitingSignals
        case notifications
    }

    var target: Target?
    var token = 0
}

// MARK: - Publish only what changed

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
    /// stale: a wait younger than a minute shows a seconds count that moves
    /// every scan, and minute labels move once a minute. Nothing else about
    /// an unchanged world is worth a redraw.
    static func needsPublish(next: PulseSnapshot, current: PulseSnapshot) -> Bool {
        if current.updatedAt == .distantPast { return true }
        if !next.sameContent(as: current) { return true }
        // Only a wait's age is drawn in seconds (the row's time while it is
        // blocked); the menu-bar title's "2 · 4m" is content, so its minute
        // label moving already made `next` differ above.
        let nowMs = Int64(next.updatedAt.timeIntervalSince1970 * 1000)
        let secondsOnScreen = next.rows.contains { row in
            guard let since = row.wait?.sinceMs, since > 0 else { return false }
            return nowMs - since < secondsLabelWindowMs
        }
        if secondsOnScreen { return true }
        return next.updatedAt.timeIntervalSince(current.updatedAt) >= minuteLabelRefresh
    }
}

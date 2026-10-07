import Foundation
import AppKit
import Observation

/// The model every view reads: UI-facing state and the intents a view may
/// send. Nothing else — the decisions are the pure models'.
///
/// Three classes share the app's state:
///
/// - `ScanEngine` (not observed) owns the session book, the watchers, the
///   process scan and the tick. It hands each projection to
///   `land(_:nowMs:baseline:)`.
/// - `WaitNotifier` (not observed) owns the "needs you" banner: planning,
///   posting, rate limiting (its in-memory `WaitLedger`) and clicks.
/// - `StatusStore` (this, `@Observable`) holds the snapshot and rows, the
///   settings and a handful of UI flags. A view is invalidated only by the
///   properties its body read, and Observation announces every assignment,
///   equal or not — so every write on the scan path is guarded
///   (`land(_:_:)`): a property is assigned only when its value changed.
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
    /// Where Settings should scroll when it opens from a deep link.
    private(set) var settingsFocus = SettingsFocus()

    // MARK: Not observed

    /// One-shot tray identity for Go-Look Closure: a banner or a jump seeds
    /// a row (and whether to open its detail); the tray takes it when it
    /// opens — or at once, when it is already open. No view draws it.
    @ObservationIgnored private(set) var pendingReveal: (rowKey: String, detail: Bool)?
    /// A QA fixture's rows are on screen (`PulseQA`): no live scan, login
    /// item or version check replaces them before the capture.
    @ObservationIgnored var previewFixtureActive = false
    /// Last value handed to `SMAppService` — a settings write that did not
    /// change it does not register again.
    @ObservationIgnored private var appliedLaunchAtLogin: Bool?
    /// Opens the tray. Tests replace it to see a reopen arrive; the app's
    /// is the status item's popover.
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

    /// Assign an observed property only when the value changed: an equal
    /// assignment would still wake every view that reads it.
    func land<Value: Equatable>(_ path: ReferenceWritableKeyPath<StatusStore, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    // MARK: - Lifecycle

    func start() {
        DebugLog.write("start begin \(PulseVersion.fingerprint)")
        HooksSupport.seedAssets()
        land(\.hooksStatus, HooksSupport.probeStatus())
        refreshPresentAgents()
        if let loaded = PulseSettings.loadIfPresent() {
            land(\.settings, loaded)
            DebugLog.write("settings \(loaded.debugDescription)")
        }
        started = true
        // macOS already holds the login item; `refreshLoginItem` reads it.
        appliedLaunchAtLogin = settings.launchAtLogin
        refreshLoginItem()
        notifier.start()
        engine.start()
        DebugLog.write("start armed")
    }

    func quit() {
        engine.stop()
        NSApp?.terminate(nil)
    }

    /// One projection. Each observed property is assigned only when its
    /// value changed; a projection that finds the same world announces
    /// nothing. `baseline`: the event log has not been read yet (or
    /// this is the projection of its first read) — a wait already there is
    /// not a new one.
    func land(_ state: TrayState, nowMs: Int64, baseline: Bool = false) {
        land(\.cachedAll, state.rows)
        notifier.scanLanded(state, nowMs: nowMs, baseline: baseline)
        // A scan that found the same world leaves `snapshot` alone — except
        // when a relative-time label on screen is due to move.
        if PulseSnapshot.needsPublish(next: state.snapshot, current: snapshot) {
            snapshot = state.snapshot
        }
    }

    /// Which agents are on this Mac: seven directory checks.
    func refreshPresentAgents() {
        land(\.presentAgents, Set(AgentID.priority.filter(HooksInstaller.vendorPresent)))
    }

    // MARK: - Settings

    /// Change one setting, save it, and apply what it affects outside the
    /// file — the login item. Everything else is read where it is used.
    func set<Value: Equatable>(_ keyPath: WritableKeyPath<PulseSettings, Value>, _ value: Value) {
        guard settings[keyPath: keyPath] != value else { return }
        settings[keyPath: keyPath] = value
        guard started else { return }
        settings.save()
        applyLaunchAtLogin()
    }

    private func applyLaunchAtLogin() {
        guard appliedLaunchAtLogin != settings.launchAtLogin else { return }
        appliedLaunchAtLogin = settings.launchAtLogin
        let enabled = settings.launchAtLogin
        DispatchQueue.global(qos: .utility).async {
            let state = LoginItem.setEnabled(enabled)
            Task { @MainActor [weak self] in
                self?.land(\.loginItem, state)
            }
        }
    }

    /// The login toggle. It shows what macOS says, so it can read off while
    /// the setting is on (macOS did not take it, or the person removed Pulse
    /// in System Settings): the same answer asks macOS again rather than
    /// doing nothing.
    func setLaunchAtLogin(_ on: Bool) {
        if started, settings.launchAtLogin == on, let state = loginItem, state.isOn != on {
            appliedLaunchAtLogin = nil
            applyLaunchAtLogin()
            return
        }
        set(\.launchAtLogin, on)
    }

    /// Read the login item — at launch, Settings opening, the app coming
    /// forward: the person may have changed it in System Settings. macOS is
    /// the truth; the setting follows it, quietly: saved, nothing applied.
    func refreshLoginItem() {
        guard started, !previewFixtureActive else { return }
        DispatchQueue.global(qos: .utility).async {
            let state = LoginItem.state
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.land(\.loginItem, state)
                self.appliedLaunchAtLogin = state.isOn
                guard self.settings.launchAtLogin != state.isOn else { return }
                self.settings.launchAtLogin = state.isOn
                self.settings.save()
            }
        }
    }

    /// Open Settings, optionally scrolled to a section — the hook connections
    /// (how an agent gets a Waiting signal) or notifications.
    func openSettings(focus target: SettingsFocus.Target? = nil) {
        var next = settingsFocus
        next.target = target
        if target != nil { next.token &+= 1 }
        land(\.settingsFocus, next)
        SettingsWindowController.shared.show(store: self)
    }

    // MARK: - The tray

    func trayWillAppear() {
        if !previewFixtureActive { refreshPresentAgents() }
    }

    /// The tray came on screen — tick faster while the person reads it.
    func trayDidAppear() {
        engine.setTrayOpen(true)
        if !previewFixtureActive { engine.refresh(reason: "trayOpen") }
    }

    func trayDidDisappear() {
        engine.setTrayOpen(false)
    }

    /// Open the tray — Pulse opened again (Finder, Spotlight, a second
    /// copy), a banner, a jump — optionally selecting a row, and opening
    /// its detail, once it is on screen. Never a window of its own.
    func requestTrayReveal(rowKey: String = "", detail: Bool = false) {
        pendingReveal = rowKey.isEmpty ? nil : (rowKey: rowKey, detail: detail)
        showTray()
    }

    /// The pending reveal, once: the tray takes it and it is gone.
    func takePendingReveal() -> (rowKey: String, detail: Bool)? {
        defer { pendingReveal = nil }
        return pendingReveal
    }

    /// The tray row's face, as a value — the store contributes the clock and
    /// the row's notice.
    func trayRowModel(_ row: AgentRow) -> TrayRowModel {
        TrayRowModel.make(TrayRowModel.Input(
            row: row, lang: lang, nowMs: ScanEngine.nowMs(), notice: rowActionNotices[row.rowKey]
        ))
    }

    /// One session in full — the detail page's value.
    func detailModel(_ row: AgentRow) -> DetailModel {
        DetailModel.make(row: row, lang: lang, nowMs: ScanEngine.nowMs(), notice: rowActionNotices[row.rowKey])
    }

    /// The tray header — the why, in counts.
    var trayHeaderModel: TrayHeaderModel {
        TrayHeaderModel.make(counts: snapshot.counts, lang: lang)
    }

    /// What the tray's one notice is chosen from.
    var trayNoticeInput: TrayNoticeModel.Input {
        TrayNoticeModel.Input(
            lang: lang,
            notifyAuthorized: notifyAuthorized,
            bannerFailed: waitingBannerFailed && cachedAll.contains(where: \.isBlocked),
            unconnected: TrayNoticeModel.unconnected(
                present: presentAgents, hooks: hooksStatus, nudgeOff: settings.hooksNudgeOff
            ),
            installFailure: TrayNoticeModel.installFailure(
                hooks: hooksStatus, nudgeOff: settings.hooksNudgeOff, lang: lang
            ),
            justConnected: setupConnected.map { connected in AgentID.priority.filter(connected.contains) }
        )
    }

    /// At most one notice, with one action (`TrayNoticeModel.pick`).
    var trayNotice: TrayNoticeModel? { TrayNoticeModel.pick(trayNoticeInput) }

    func performTrayNotice(_ action: TrayNoticeModel.Action) {
        switch action {
        case .connect: connectFromSetup()
        case .dismissSetup: land(\.setupConnected, nil)
        case .openHooksSettings: openSettings(focus: .waitingSignals)
        case .openNotificationSettings: PulseNotify.openSystemSettings()
        case .enableNotifications: PulseNotify.requestAuthorizationAfterUserAction()
        }
    }

    // MARK: - Row intents

    /// Say what happened, briefly. Long enough to read, short enough that it
    /// never settles in and becomes row furniture.
    func noteRowAction(_ rowKey: String, _ notice: RowNotice) {
        rowActionNotices[rowKey] = notice
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            guard let self, self.rowActionNotices[rowKey] == notice else { return }
            self.rowActionNotices.removeValue(forKey: rowKey)
        }
    }

    /// Go to the row's terminal. The landing plan was made by the projection
    /// that produced this row, and a window can close between then and the
    /// click. Say how it landed, never rounded up: exact says nothing, the
    /// app alone says so (and where macOS's Automation permission is when a
    /// script was tried), and nothing reached says so and re-reads — the
    /// next row either carries a handle that works or stops offering one.
    /// Returns whether it reached anything.
    @discardableResult
    func focusTerminal(_ row: AgentRow) -> Bool {
        markTurnSeen(row)
        switch TerminalFocus.land(row.landingPlan) {
        case .exact:
            return true
        case .appOnly:
            noteRowAction(row.rowKey, RowNotice.appOnly(row: row, lang: lang))
            return true
        case .failed:
            noteRowAction(row.rowKey, RowNotice(text: tr(.focusFailed)))
            engine.refresh(reason: "focus-failed")
            return false
        }
    }

    /// A banner click (or its Go button): the terminal, and nothing
    /// else, when it can be focused — the tray does not pop up over it. With
    /// no handle (or one that failed) the tray opens on the row's detail; a
    /// row that is gone opens the tray on the oldest wait. `BannerRoute`
    /// decides.
    func focusAgent(idRaw: String, session: String = "", rowKey: String = "") {
        let row = BannerRoute.target(in: cachedAll, idRaw: idRaw, session: session, rowKey: rowKey)
        var focused = false
        if let row {
            if row.canFocusTerminal {
                focused = focusTerminal(row)
            } else {
                markTurnSeen(row)
            }
        }
        switch BannerRoute.decide(target: row?.rowKey, focused: focused) {
        case .terminal:
            return
        case .detail(let key):
            requestTrayReveal(rowKey: key, detail: true)
        case .tray:
            requestTrayReveal(rowKey: cachedAll.first(where: \.isBlocked)?.rowKey ?? "")
        }
    }

    /// Looking at a finished session is what "your turn" was asking for. A
    /// session-scoped `done` in the event log is the record — it survives a
    /// restart, and it is the same line a new prompt would write.
    private func markTurnSeen(_ row: AgentRow) {
        guard row.isYourTurn, !row.attentionSession.isEmpty else { return }
        writeDone(row)
    }

    /// The person dismissed a wait: a `done` in the event log under exactly
    /// the session its entry carried (`AttentionRecord.dismissal`) — and no
    /// banner for it.
    func dismissWaiting(_ row: AgentRow) {
        guard row.isBlocked else { return }
        notifier.dismissed(row.rowKey)
        writeDone(row)
    }

    /// File writes for `done` lines, one at a time, off the main thread:
    /// the event log is locked, and a click must not wait on it.
    private static let doneWrites = DispatchQueue(label: "com.pulse.attention-done", qos: .userInitiated)

    /// A `done` line: applied to the book at once (the row moves under the
    /// click), appended to the event log off the main thread. The watch
    /// reads the line back; the book has already applied it, so it changes
    /// nothing.
    private func writeDone(_ row: AgentRow) {
        let nowMs = ScanEngine.nowMs()
        let record = AttentionRecord.dismissal(
            agent: row.agent.rawValue, session: row.attentionSession, cwd: row.cwd, ms: nowMs
        )
        // A preview fixture's rows are not the book's; leave them on screen.
        if !previewFixtureActive { engine.apply(records: [record], nowMs: nowMs) }
        let line = record.line
        Self.doneWrites.async {
            EventLog.append(line, nowMs: nowMs)
        }
    }

    // MARK: - Hooks

    /// One install or removal of every agent's hook, one at a time
    /// (`HooksSupport.installQueue`; the buttons wait while one runs). An
    /// install clears "don't suggest hooks"; removing them sets it — a
    /// decision.
    func runHooks(
        _ job: HooksSupport.Job,
        then done: @escaping @MainActor @Sendable (HooksSupport.Status) -> Void = { _ in }
    ) {
        guard !hooksStatus.isWorking else { return }
        let previous = hooksStatus.failures
        land(\.hooksStatus, .working)
        if settings.hooksNudgeOff != (job == .uninstall) {
            settings.hooksNudgeOff = job == .uninstall
            if started { settings.save() }
        }
        // `Task` inherits this class's main-actor isolation, so the assignment
        // lands on main while the hook installer stays off it.
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                HooksSupport.run(job, previous: previous)
            }.value
            self?.land(\.hooksStatus, status)
            done(status)
        }
    }

    /// The setup card's one click: install the hooks of every agent on this
    /// Mac, then ask macOS to allow banners (asked only if it never was),
    /// then show what is left — Codex's trust step, and that sessions
    /// already running appear after their next step.
    func connectFromSetup() {
        let before = hooksStatus.installedAgents
        runHooks(.install) { [weak self] status in
            PulseNotify.requestAuthorizationAfterUserAction()
            let connected = status.installedAgents.subtracting(before)
            if !connected.isEmpty { self?.land(\.setupConnected, connected) }
        }
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

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
    /// Every row the last scan produced (the tray's visible window is
    /// `snapshot.rows`); the open tray and focus read this.
    var cachedAll: [AgentRow] = []
    /// The person's settings, persisted as `settings.json`. Change them
    /// through `set(_:_:)` so the change is saved and applied.
    var settings = PulseSettings()
    /// The tray shows every row rather than its visible window.
    var showAllAgents = false
    var hooksStatus: HooksSupport.Status = .unknown
    /// Agents whose vendor folder is on this Mac (`HooksInstaller.vendorPresent`)
    /// — read at launch and when the tray opens; never on the scan path.
    var presentAgents: Set<AgentID> = []
    /// The agents the setup card just connected: the card shows what is
    /// left to do until "Got it". nil otherwise; not saved.
    var setupConnected: Set<AgentID>?
    /// False when the system refused the shortcut (another app owns it).
    var hotkeyRegistered = true
    /// Pulse's login item as macOS reports it (`SMAppService`); nil until
    /// read. The Settings toggle shows this, not what was asked.
    var loginItem: LoginItemState?
    /// Notification authorization — a denied prompt used to fail silently.
    var notifyAuthorized: Bool?
    /// Notification Center refused the last "needs you" banner.
    var waitingBannerFailed = false
    var updateStatus: UpdateCheck.Status = .idle
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
    /// Settings are saved and applied (launchd, the shortcut, a rescan) only
    /// once `start()` has read them, so a store a test or a fixture builds
    /// never touches the developer's own file or login items.
    @ObservationIgnored private var started = false

    let engine: ScanEngine
    let notifier: WaitNotifier
    init() {
        engine = ScanEngine()
        notifier = WaitNotifier()
        engine.model = self
        notifier.model = self
    }

    // MARK: - Language

    /// `PulseQA`'s `--language=`: wins over `settings.json` for that run and
    /// is never saved. Set before launch; not observed — it does not change
    /// while the app runs. The shipping app never sets it.
    @ObservationIgnored var languageOverride: AppLanguage?

    var lang: ResolvedLanguage { (languageOverride ?? settings.language).resolved }

    func tr(_ key: L10n.Key) -> String { L10n.t(key, lang) }

    // MARK: - Lifecycle

    func start() {
        DebugLog.write("start begin \(PulseVersion.fingerprint)")
        // The agents' own hooks are the only state that outlives a launch;
        // files Pulse once kept of its own are deleted, never read.
        Self.removeRetiredFiles()
        HooksSupport.seedAssets()
        landHooksStatus(HooksSupport.probeStatus())
        refreshPresentAgents()
        loadSettings()
        adoptLoginItem()
        applyHotkey()
        notifier.start()
        engine.start()
        UpdateCheck.shared.startIfEnabled(store: self)
        DebugLog.write("start armed")
    }

    func quit() {
        engine.stop()
        GlobalHotKey.uninstall()
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

    /// Files earlier versions kept beside `events.tsv` (`PULSE_HOME`
    /// moves it) and in the default support folder. Deleted at launch,
    /// never migrated — the v4 attention file and the activity spool
    /// included: the event log starts empty.
    nonisolated static let retiredFileNames = [
        "attention.tsv", "activity.d",
        "session-log.json",
        "attention-ledger.json", "attention-history.json", "session-timeline.json", "dismissed-pending.json",
    ]

    nonisolated static func removeRetiredFiles() {
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse", isDirectory: true)
        var dirs = [EventLog.directory]
        if dirs[0].standardizedFileURL != defaultDir.standardizedFileURL { dirs.append(defaultDir) }
        removeRetiredFiles(in: dirs)
    }

    nonisolated static func removeRetiredFiles(in dirs: [URL]) {
        for dir in dirs {
            for name in retiredFileNames {
                let file = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    // MARK: - What the engine and the notifier hand over

    /// One projection. Each observed property is assigned only when its
    /// value changed; a projection that finds the same world announces
    /// nothing. `baseline`: the event log has not been read yet (or
    /// this is the projection of its first read) — a wait already there is
    /// not a new one.
    func land(_ state: TrayState, nowMs: Int64, baseline: Bool = false) {
        setCachedAll(state.rows)
        if showAllAgents != state.showAllAgents { showAllAgents = state.showAllAgents }
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

    func landUpdateStatus(_ value: UpdateCheck.Status) {
        if updateStatus != value { updateStatus = value }
    }

    // MARK: - Settings

    /// Read `settings.json` (an old `settings.txt` is deleted, unread).
    /// With no file, the defaults stay. `PulseQA`'s language is
    /// `languageOverride`, not a setting, so a file cannot undo it.
    func loadSettings() {
        if let loaded = PulseSettings.loadIfPresent() {
            if loaded != settings { settings = loaded }
            DebugLog.write("settings \(loaded.debugDescription)")
        }
        started = true
        // macOS already holds the login item; `adoptLoginItem` reads it.
        appliedLaunchAtLogin = settings.launchAtLogin
    }

    /// Change one setting, save it, and apply what it affects.
    func set<Value: Equatable>(_ keyPath: WritableKeyPath<PulseSettings, Value>, _ value: Value) {
        update { $0[keyPath: keyPath] = value }
    }

    /// Change any number of settings at once: one assignment, one save, and
    /// each effect applied once — only the ones a changed setting needs
    /// (`effects(from:to:)`).
    func update(_ change: (inout PulseSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let before = settings
        settings = next
        guard started else { return }
        settings.save()
        for effect in Self.effects(from: before, to: next).sorted() { apply(effect) }
    }

    /// The effects a change from `before` to `after` needs — nothing for a
    /// mute or a notification switch, which are read where they are used.
    /// Pure.
    nonisolated static func effects(from before: PulseSettings, to after: PulseSettings) -> Set<SettingEffect> {
        var out: Set<SettingEffect> = []
        if before.language != after.language { out.formUnion([.bannerCategory, .mainMenu, .reproject]) }
        if before.launchAtLogin != after.launchAtLogin { out.insert(.loginItem) }
        if before.hotkey != after.hotkey { out.insert(.hotkey) }
        if before.updateCheckEnabled != after.updateCheckEnabled { out.insert(.updateCheck) }
        if before.allowTerminalAutomation != after.allowTerminalAutomation { out.insert(.reproject) }
        return out
    }

    private func apply(_ effect: SettingEffect) {
        switch effect {
        case .bannerCategory: notifier.languageChanged(lang)
        case .mainMenu: MainMenu.install(lang: lang)
        case .loginItem: applyLaunchAtLoginIfChanged()
        case .hotkey: applyHotkey()
        case .updateCheck: UpdateCheck.shared.startIfEnabled(store: self)
        case .reproject: engine.project()
        }
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
            let state = LoginItem.setEnabled(enabled)
            Task { @MainActor [weak self] in
                self?.landLoginItem(state)
            }
        }
    }

    /// The login toggle or the setup card's checkbox. The toggle shows what
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

    /// At launch: read the login item from macOS, and adopt the LaunchAgent
    /// plist earlier versions wrote (`com.pulse.app.plist`, Pulse's own
    /// file) — register Pulse with macOS first, and retire the plist only
    /// once macOS has taken it, so the person's choice is never lost
    /// (`LoginAdoption`). Then macOS is the truth: the setting follows what
    /// it says — unless the register failed, when the plist and the setting
    /// stay and Settings says macOS did not take it.
    func adoptLoginItem() {
        DispatchQueue.global(qos: .utility).async {
            let hadLegacyAgent = LoginItem.hasLegacyAgent()
            let state = hadLegacyAgent ? LoginItem.setEnabled(true) : LoginItem.state
            let adoption = LoginAdoption.decide(hadLegacyAgent: hadLegacyAgent, state: state)
            if adoption == .retireLegacyAndSync { LoginItem.retireLegacyAgent() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch adoption {
                case .sync, .retireLegacyAndSync:
                    self.syncLoginItem(state)
                case .keepLegacy:
                    // What macOS said, shown; the setting (and the plist
                    // that still opens Pulse at login) left alone.
                    self.landLoginItem(state)
                }
            }
        }
    }

    /// Re-read the login item — Settings opening, the app coming forward:
    /// the person may have changed it in System Settings.
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

    /// Open Settings, optionally scrolled to a section — the hook connections
    /// (how an agent gets a Waiting signal), notifications, updates.
    func openSettings(focus target: SettingsFocus.Target? = nil) {
        var next = settingsFocus
        next.target = target
        if target != nil { next.token &+= 1 }
        if next != settingsFocus { settingsFocus = next }
        // The menu bar shows the main menu while Settings is open: in the
        // language chosen now.
        MainMenu.install(lang: lang)
        SettingsWindowController.shared.show(store: self)
    }

    // MARK: - Tray lifecycle

    func trayWillAppear() {
        traySessionToken &+= 1
        if !previewFixtureActive { refreshPresentAgents() }
        // Store-owned, and just as much "last time's rummaging" as the folds.
        if showAllAgents {
            showAllAgents = false
            applyRowWindow()
        }
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

    func toggleShowAllAgents() {
        showAllAgents.toggle()
        applyRowWindow()
    }

    func applyRowWindow() {
        var snap = snapshot
        TrayState.window(
            rows: cachedAll,
            showAll: showAllAgents,
            maxVisible: TrayState.maxVisibleRows,
            into: &snap
        )
        if snap != snapshot { snapshot = snap }
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
        let seconds: UInt64 = 8
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
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

    /// The Go reached the app, not the exact terminal. When Terminal
    /// automation (a Settings toggle) would have reached the exact tab, the
    /// notice says where to turn it on.
    private func noteAppOnly(_ row: AgentRow) {
        noteRowAction(row.rowKey, RowNotice.appOnly(
            row: row, automationAllowed: settings.allowTerminalAutomation, lang: lang
        ))
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
        runHooks(.install(nil), then: done)
    }

    /// One install or removal — every agent, or the one a Settings line
    /// names. An install clears "don't suggest hooks"; removing every
    /// agent's hook sets it (a decision); removing one agent's hook is
    /// about that agent only.
    func runHooks(
        _ job: HooksSupport.Job,
        then done: @escaping @MainActor @Sendable (HooksSupport.Status) -> Void = { _ in }
    ) {
        guard !hooksStatus.isWorking else { return }
        let previous = hooksStatus.failures
        landHooksStatus(.working)
        switch job {
        case .install: setHooksNudgeOff(false)
        case .uninstall(.none): setHooksNudgeOff(true)
        case .uninstall: break
        }
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
        runHooks(.uninstall(nil))
    }

    // MARK: - Uninstall

    /// "Uninstall Pulse…": say what goes (`UninstallPlan`), and on the
    /// person's yes remove every hook through the installer. Only when none
    /// is left: the login item, then Pulse's folder, then quit and show the
    /// app in Finder for the Trash. A hook that would not come out stops it
    /// there — nothing else is removed, and Settings → Hooks says why.
    func uninstallPulse() {
        guard !hooksStatus.isWorking else { return }
        let plan = UninstallPlan.make(
            installed: hooksStatus.installedAgents,
            loginItem: loginItem,
            asked: settings.launchAtLogin,
            folder: HooksSupport.supportDir(),
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        NSApp?.activate(ignoringOtherApps: true)
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = tr(.uninstallTitle)
        confirm.informativeText = plan.message(lang)
        let uninstall = confirm.addButton(withTitle: tr(.uninstallConfirm))
        uninstall.hasDestructiveAction = true
        confirm.addButton(withTitle: tr(.uninstallCancel))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        DebugLog.write("uninstall: confirmed")
        runHooks(.uninstall(nil)) { [weak self] status in
            guard let self else { return }
            guard UninstallPlan.hooksRemoved(status) else {
                DebugLog.write("uninstall: stopped — a hook is still in place")
                let stopped = NSAlert()
                stopped.messageText = self.tr(.uninstallStopped)
                stopped.runModal()
                self.openSettings(focus: .waitingSignals)
                return
            }
            self.finishUninstall(plan)
        }
    }

    /// Every hook is out: the rest, then quit. Nothing may write to Pulse's
    /// folder after it is deleted — the engine and the shortcut stop first,
    /// and the last log line is written before it goes.
    private func finishUninstall(_ plan: UninstallPlan) {
        engine.stop()
        GlobalHotKey.uninstall()
        // Always: the plan's read of the login item may be stale (changed in
        // System Settings since), and unregistering one that is off does
        // nothing.
        LoginItem.setEnabled(false)
        let folder = HooksSupport.supportDir()
        DebugLog.write("uninstall: deleting the support folder and quitting")
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            DebugLog.write("uninstall: folder not deleted: \(error.localizedDescription)")
        }
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" {
            NSWorkspace.shared.activateFileViewerSelecting([app])
        }
        NSApp?.terminate(nil)
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
}

/// What applying a setting means outside the settings file
/// (`StatusStore.effects(from:to:)`).
enum SettingEffect: Int, Comparable, Sendable {
    /// Re-register the banner's button titles: they are baked into the
    /// registered category and go stale on a language switch.
    case bannerCategory
    /// Re-install the main menu: its titles are the language's, and it is
    /// in the menu bar while Settings — where the language is picked — is
    /// open.
    case mainMenu
    /// Register (or unregister) Pulse's login item with macOS.
    case loginItem
    /// Re-register the global shortcut.
    case hotkey
    /// Start (or stop) the daily update check.
    case updateCheck
    /// Re-project the book: the words (language) or how a click lands
    /// (Terminal automation) changed.
    case reproject

    static func < (a: SettingEffect, b: SettingEffect) -> Bool { a.rawValue < b.rawValue }
}

/// Where Settings scrolls when a deep link opens it. The token moves on
/// every deep link, so a second link to the same place still scrolls there.
struct SettingsFocus: Equatable {
    enum Target: Equatable {
        /// The hooks: how an agent gets a "needs you" signal.
        case waitingSignals
        case notifications
        case updates
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

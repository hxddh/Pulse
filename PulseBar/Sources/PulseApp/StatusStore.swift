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

    /// The glance: the lamp, the menu-bar title, the counts.
    var snapshot = PulseSnapshot()
    /// Every row the last projection produced, in its order — state only;
    /// what a session said lately is read from the book when a row is drawn
    /// (`facts(for:)`).
    var rows: [AgentRow] = []
    /// The person's settings, persisted as `settings.json`. Change them
    /// through `set(_:_:)` so the change is saved and applied.
    var settings = PulseSettings()
    var hooksStatus: HooksSupport.Status = .unknown
    /// How each agent's config carries Pulse's hook (`HooksSupport.inspect`)
    /// — read at launch, when Settings opens and after an install; never on
    /// the scan path.
    var hookInstalls: [AgentID: Connection.Install] = [:]
    /// What else each agent's config says — a vendor setting that silences
    /// hooks, when the file Pulse edits last changed (`HooksSupport.config`)
    /// — read with `hookInstalls`.
    var hookConfigs: [AgentID: Connection.Config] = [:]
    /// Agents whose vendor folder is on this Mac (`HooksInstaller.vendorPresent`)
    /// — read at launch and when the tray opens; never on the scan path.
    var presentAgents: Set<AgentID> = []
    /// Agents on this Mac (a vendor folder, or a live process) whose movable
    /// config folder Pulse installs into is missing
    /// (`Connection.configDirMissing`) — read with `presentAgents`.
    var configDirMissing: Set<AgentID> = []
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
    var rowActionNotices: [SessionKey: RowNotice] = [:]
    /// Where Settings should scroll when it opens from a deep link.
    private(set) var settingsFocus = SettingsFocus()
    /// The global shortcut as macOS answered: registered, refused (another
    /// app holds the chord), or nil — off, or not started.
    var shortcutRegistered: Bool?
    /// The optional direct-jump shortcut (⌃⌥⌘↩) as macOS answered.
    var directJumpRegistered: Bool?
    /// Settings' "Test connection", its last answer; nil not run.
    var hookPing: HookPing.Result?
    /// Sessions whose end of turn the person asked to hear about, on the
    /// detail page — one banner each, in memory only.
    var turnWatches: Set<SessionKey> = []
    /// What macOS says about Apple Events to each terminal (bundle id →
    /// state) — read when Settings opens, never on the scan path.
    var automation: [String: AutomationState] = [:]

    // MARK: Not observed

    /// One-shot tray identity for Go-Look Closure: a banner or a jump seeds
    /// a row (and whether to open its detail); the tray takes it when it
    /// opens — or at once, when it is already open. No view draws it.
    @ObservationIgnored private(set) var pendingReveal: (key: SessionKey, detail: Bool)?
    /// A QA fixture's rows are on screen (`PulseQA`): no live scan, login
    /// item or version check replaces them before the capture.
    @ObservationIgnored var previewFixtureActive = false
    /// A QA fixture's session facts, in place of the book's.
    @ObservationIgnored var fixtureFacts: [SessionKey: SessionFacts] = [:]
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
        probeHooks()
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
        GlobalShortcut.shared.onPress = { [weak self] in self?.shortcutPressed() }
        GlobalShortcut.shared.onDirectJump = { [weak self] in self?.jumpToOldestWait() }
        applyShortcut()
        applyDirectJumpShortcut()
        engine.start()
        DebugLog.write("start armed")
    }

    func quit() {
        engine.stop()
        NSApp?.terminate(nil)
    }

    /// One projection. Each observed property is assigned only when its
    /// value changed; a projection that finds the same world announces
    /// nothing — it carries state only, so plain equality says so.
    /// `baseline`: the event log has not been read yet (or this is the
    /// projection of its first read) — a wait already there is not a new
    /// one.
    func land(_ state: TrayState, nowMs: Int64, baseline: Bool = false) {
        let previousRows = rows
        land(\.rows, state.rows)
        notifier.scanLanded(state, nowMs: nowMs, baseline: baseline)
        let watched = TurnWatch.finished(watching: turnWatches, rows: state.rows)
        let autoDone = baseline
            ? []
            : TurnWatch.autoDone(
                previous: previousRows,
                current: state.rows,
                facts: { self.facts(for: $0) },
                settings: settings
            )
        var notifiedDone = Set<SessionKey>()
        for row in watched.done + autoDone where notifiedDone.insert(row.key).inserted {
            notifier.postTurnDone(row, facts: facts(for: row.key))
        }
        land(\.turnWatches, turnWatches.subtracting(watched.gone).subtracting(watched.done.map(\.key)))
        land(\.snapshot, state.snapshot)
    }

    // MARK: - The shortcut, muting, the connection test, turn watches

    /// Register the chord when the setting is on; drop it when off.
    func applyShortcut() {
        guard started else { return }
        let on = settings.globalShortcut
        let registered = GlobalShortcut.shared.set(enabled: on, choice: settings.shortcut)
        land(\.shortcutRegistered, on ? registered : nil)
    }

    /// Register the direct-jump chord (⌃⌥⌘↩) when the setting is on.
    func applyDirectJumpShortcut() {
        guard started else { return }
        let on = settings.directJumpShortcut
        let registered = GlobalShortcut.shared.setDirectJump(enabled: on)
        land(\.directJumpRegistered, on ? registered : nil)
    }

    func setGlobalShortcut(_ on: Bool) {
        set(\.globalShortcut, on)
        applyShortcut()
    }

    func setDirectJumpShortcut(_ on: Bool) {
        set(\.directJumpShortcut, on)
        applyDirectJumpShortcut()
    }

    /// The chord: the tray on the oldest wait, or closed when it is open.
    func shortcutPressed() {
        if let tray = StatusItemController.shared, tray.isTrayShown {
            tray.close()
        } else {
            requestTrayReveal(key: rows.first(where: \.isBlocked)?.key)
        }
    }

    @ObservationIgnored private var lastDirectJumpKey: SessionKey?
    @ObservationIgnored private var lastDirectJumpMs: Int64 = 0

    /// Direct jump (⌃⌥⌘↩): jump straight to the oldest blocked terminal
    /// without popping up the tray; pressing again (or when already viewing
    /// that terminal) cycles cleanly to the next blocked terminal.
    func jumpToOldestWait() {
        let nowMs = Self.ms(Date())
        guard let target = DirectJump.pick(
            rows: rows,
            frontmost: { row in
                row.pid > 1 && PromptVisibility.promptIsFrontmost(selfPID: row.pid) == true
            },
            lastJumped: lastDirectJumpKey,
            lastJumpedAtMs: lastDirectJumpMs,
            nowMs: nowMs
        ) else {
            requestTrayReveal()
            return
        }
        lastDirectJumpKey = target.key
        lastDirectJumpMs = nowMs
        focusAgent(idRaw: target.agent.rawValue, session: target.session, rowKey: target.key.description)
    }

    func setShortcut(_ choice: ShortcutChoice) {
        set(\.shortcut, choice)
        applyShortcut()
    }

    func setMenuBarStyle(_ style: MenuBarStyle) {
        set(\.menuBarStyle, style)
        engine.project()
    }

    /// Temporarily snooze all notification banners for `minutes` (lamp stays red).
    func setQuiet(minutes: Int, nowMs: Int64 = ScanEngine.nowMs()) {
        let until = nowMs + Int64(max(1, minutes)) * 60 * 1000
        set(\.quietUntilMs, until)
        engine.project(nowMs: nowMs)
    }

    /// Resume notification banners immediately and deliver any still-open waits queued during quiet mode.
    func resumeQuiet() {
        guard settings.quietUntilMs != 0 else { return }
        set(\.quietUntilMs, 0)
        engine.project()
        notifier.deliverPendingIfPossible()
    }

    /// Remaining quiet duration label at `date`, or nil when not snoozed.
    func quietRemaining(at date: Date = Date()) -> String? {
        settings.quietRemaining(at: Self.ms(date), lang: lang)
    }

    func setNotifyDone(_ agent: AgentID, _ enabled: Bool) {
        set(\.notifyDoneAgents, settings.notifyingDone(agent, enabled).notifyDoneAgents)
    }

    func setLongTurnSeconds(_ seconds: Int) {
        set(\.notifyLongTurnSeconds, max(0, seconds))
    }

    func setNotificationSound(_ sound: NotificationSound) {
        set(\.notificationSound, sound)
    }

    /// Every finished turn in the tray, looked at: the same `pulse.seen` a
    /// click on each would write.
    func markAllSeen() {
        for row in rows where row.isYourTurn { markTurnSeen(row) }
    }

    /// Hide one recent or process-only row from the tray until it has newer activity.
    func hideRow(_ row: AgentRow) {
        guard !previewFixtureActive, row.isRecent || row.isProcessOnly else { return }
        engine.hideRow(row.key)
    }

    /// Clear all recent rows currently shown in the tray.
    func clearRecent() {
        guard !previewFixtureActive else { return }
        let keys = rows.filter(\.isRecent).map(\.key)
        engine.clearRecent(keys)
    }

    /// Ask macOS, without prompting, what it allows for each terminal.
    func refreshAutomation() {
        Task { @MainActor [weak self] in
            let states = await Task.detached(priority: .utility) { AutomationCheck.all() }.value
            self?.land(\.automation, states)
        }
    }

    func setMuted(_ agent: AgentID, _ muted: Bool) {
        set(\.mutedAgents, settings.muting(agent, muted).mutedAgents)
    }

    /// Run the installed launcher with `--ping` off the main thread and
    /// read whether a Pulse answered after the click (`HookPing`).
    func testHookConnection() {
        guard hookPing != .running else { return }
        let launcher = HooksInstaller.launcherURL.path
        guard FileManager.default.isExecutableFile(atPath: launcher) else {
            land(\.hookPing, .noLauncher)
            return
        }
        land(\.hookPing, .running)
        let since = Self.ms(Date()) - 1_000
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ConnectionTest.run(launcher: launcher, since: since)
            }.value
            self?.land(\.hookPing, result)
            DebugLog.write("hook ping \(result)")
        }
    }

    /// The detail page's "Tell me when this turn is done", on and off.
    func toggleTurnWatch(_ row: AgentRow) {
        if turnWatches.contains(row.key) {
            land(\.turnWatches, turnWatches.subtracting([row.key]))
        } else if TurnWatch.canWatch(row) {
            land(\.turnWatches, turnWatches.union([row.key]))
        }
    }

    /// What a session said lately — its steps, last words, error and
    /// clocks — read from the book when a row or the detail page is drawn.
    /// Not observed: the views redraw it on their clock (`TimelineView`).
    func facts(for key: SessionKey) -> SessionFacts {
        previewFixtureActive ? fixtureFacts[key] ?? .empty : engine.book.facts(for: key)
    }

    /// What the agents' configs carry now: the status line and each
    /// agent's install.
    func probeHooks() {
        if !hooksStatus.isWorking { land(\.hooksStatus, .ready()) }
        land(\.hookInstalls, HooksSupport.inspectAll())
        land(\.hookConfigs, HooksSupport.configAll())
    }

    /// Every agent's connection: its install (the last failure wins), the
    /// vendor event heard last and the last one not used, and why a whole
    /// install may say nothing — the engine's and the last probe's, so a
    /// redraw reads no file.
    var connections: [Connection] {
        let failures = hooksStatus.failures
        return AgentID.priority.map { agent in
            Connection.make(
                agent: agent,
                probed: hookInstalls[agent],
                failure: failures[agent],
                heard: engine.latestHeard[agent],
                ignored: engine.latestIgnored[agent],
                configDirMissing: configDirMissing.contains(agent),
                config: hookConfigs[agent] ?? Connection.Config(),
                logWhole: engine.logWhole
            )
        }
    }

    /// Which agents are on this Mac: six directory checks — and, for an
    /// agent whose config folder can be moved, whether the default one
    /// Pulse installs into is there.
    func refreshPresentAgents() {
        let present = Set(AgentID.priority.filter(HooksInstaller.vendorPresent))
        land(\.presentAgents, present)
        let running = Set(engine.processes.map(\.agent))
        land(\.configDirMissing, Set(AgentID.priority.filter { agent in
            Connection.configDirMissing(
                agent: agent,
                present: present.contains(agent) || running.contains(agent),
                exists: HooksInstaller.homeFolderExists
            )
        }))
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
        FloatingBeaconController.shared?.setTrayOpen(true)
        engine.setTrayOpen(true)
        if !previewFixtureActive { engine.refresh(reason: "trayOpen") }
    }

    func trayDidDisappear() {
        FloatingBeaconController.shared?.setTrayOpen(false)
        engine.setTrayOpen(false)
    }

    /// Open the tray — Pulse opened again (Finder, Spotlight, a second
    /// copy), a banner, a jump — optionally selecting a row, and opening
    /// its detail, once it is on screen. Never a window of its own.
    func requestTrayReveal(key: SessionKey? = nil, detail: Bool = false) {
        pendingReveal = key.map { (key: $0, detail: detail) }
        showTray()
    }

    /// The pending reveal, once: the tray takes it and it is gone.
    func takePendingReveal() -> (key: SessionKey, detail: Bool)? {
        defer { pendingReveal = nil }
        return pendingReveal
    }

    /// The tray row's face, as a value, at `date` — the store contributes
    /// the session's facts and the row's notice.
    func trayRowModel(
        _ row: AgentRow,
        at date: Date = Date(),
        hideProject: Bool = false,
        showBranch: Bool = false
    ) -> TrayRowModel {
        TrayRowModel.make(TrayRowModel.Input(
            row: row, facts: facts(for: row.key), lang: lang,
            nowMs: Self.ms(date), notice: rowActionNotices[row.key],
            connected: connected(row.agent),
            hideProject: hideProject,
            showBranch: showBranch,
            watching: turnWatches.contains(row.key)
        ))
    }

    /// One session in full — the detail page's value, at `date`;
    /// `disclosed`: the steps behind its timeline's runs are shown.
    func detailModel(_ row: AgentRow, at date: Date = Date(), disclosed: Bool = false) -> DetailModel {
        DetailModel.make(
            row: row, facts: facts(for: row.key), lang: lang,
            nowMs: Self.ms(date), notice: rowActionNotices[row.key],
            connected: connected(row.agent), disclosed: disclosed,
            watching: turnWatches.contains(row.key)
        )
    }

    /// "Copy this turn's summary" (`TurnSummary`): only on the person's
    /// click, only to their own clipboard. Unlike Settings' content-free
    /// "Copy report", it carries the turn's prompt and paths — the person
    /// asked for exactly that. Nothing of it is logged.
    func copyTurnSummary(_ row: AgentRow) {
        let text = TurnSummary.text(row: row, facts: facts(for: row.key), lang: lang, nowMs: Self.ms(Date()))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        DebugLog.write("turn summary copied")
    }

    /// Copy the blocked row's ask (shell command / question) to the clipboard.
    func copyAsk(_ row: AgentRow) {
        guard let ask = TrayRowModel.ask(row) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ask, forType: .string)
        DebugLog.write("ask copied")
    }

    /// Pulse's hook is in the agent's config (the last probe; a status not
    /// read yet counts as connected, so nothing is claimed missing).
    private func connected(_ agent: AgentID) -> Bool {
        if let install = hookInstalls[agent] { return install.carriesHook }
        return hooksStatus == .unknown || hooksStatus.isWorking
    }

    /// The agents whose config carries Pulse's hook, as last read.
    var hookedAgents: Set<AgentID> {
        Set(hookInstalls.filter { $0.value.carriesHook }.keys)
    }

    private static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    /// The tray header — the why, in counts.
    var trayHeaderModel: TrayHeaderModel {
        TrayHeaderModel.make(counts: snapshot.counts, lang: lang)
    }

    /// What the tray's one notice is chosen from.
    var trayNoticeInput: TrayNoticeModel.Input {
        let connections = self.connections
        return TrayNoticeModel.Input(
            lang: lang,
            notifyAuthorized: notifyAuthorized,
            bannerFailed: waitingBannerFailed && rows.contains(where: \.isBlocked),
            unconnected: TrayNoticeModel.unconnected(
                present: presentAgents, connections: connections, hooks: hooksStatus, nudgeOff: settings.hooksNudgeOff
            ),
            installFailure: TrayNoticeModel.installFailure(
                connections: connections, nudgeOff: settings.hooksNudgeOff, lang: lang
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
    func noteRowAction(_ key: SessionKey, _ notice: RowNotice) {
        rowActionNotices[key] = notice
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            guard let self, self.rowActionNotices[key] == notice else { return }
            self.rowActionNotices.removeValue(forKey: key)
        }
    }

    /// Go to the row's terminal. The landing plan was made by the projection
    /// that produced this row, and a window can close between then and the
    /// click. Say how it landed, never rounded up: exact says nothing, the
    /// app alone says so (and where macOS's Automation permission is when a
    /// script was tried), and nothing reached says so and re-reads — the
    /// next row either carries a handle that works or stops offering one.
    ///
    /// The landing runs off the main thread: each step may wait on a child
    /// process (osascript, tmux, a terminal's CLI) and the first AppleScript
    /// waits while macOS shows its Automation question. The menu bar and the
    /// tray never freeze behind it.
    func focusTerminal(_ row: AgentRow) {
        Task { @MainActor [weak self] in
            _ = await self?.land(row)
        }
    }

    /// Runs the row's plan off the main actor; reports on it.
    @discardableResult
    func land(_ row: AgentRow) async -> Bool {
        markTurnSeen(row)
        let plan = row.landingPlan
        let outcome = await Task.detached(priority: .userInitiated) { TerminalFocus.land(plan) }.value
        switch outcome {
        case .exact:
            return true
        case .appOnly:
            noteRowAction(row.key, RowNotice.appOnly(row: row, lang: lang))
            return true
        case .failed:
            noteRowAction(row.key, RowNotice(text: tr(.focusFailed)))
            engine.refresh(reason: "focus-failed")
            return false
        }
    }

    /// A banner click (or its Go button): the terminal, and nothing
    /// else, when it can be focused — the tray does not pop up over it. With
    /// no handle (or one that failed) the tray opens on the row's detail; a
    /// row that is gone opens the tray on the oldest wait. `BannerRoute`
    /// decides. A row with no handle is routed at once; one with a handle
    /// is routed when its landing answers.
    func focusAgent(idRaw: String, session: String = "", rowKey: String = "") {
        let row = BannerRoute.target(in: rows, idRaw: idRaw, session: session, rowKey: rowKey)
        guard let row, row.canFocusTerminal else {
            if let row { markTurnSeen(row) }
            route(target: row?.key, focused: false)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let focused = await self.land(row)
            self.route(target: row.key, focused: focused)
        }
    }

    private func route(target: SessionKey?, focused: Bool) {
        switch BannerRoute.decide(target: target, focused: focused) {
        case .terminal:
            return
        case .detail(let key):
            requestTrayReveal(key: key, detail: true)
        case .tray:
            requestTrayReveal(key: rows.first(where: \.isBlocked)?.key)
        }
    }

    /// Looking at a finished session is what "your turn" was asking for. A
    /// session-scoped `dismiss` (`pulse.seen`) in the event log is the
    /// record — it survives a restart.
    private func markTurnSeen(_ row: AgentRow) {
        guard row.isYourTurn, !row.session.isEmpty else { return }
        notifier.withdrawTurnDone(row.key)
        writeDismissal(row, event: AttentionRecord.seenEvent)
    }

    /// The person dismissed a wait: a `dismiss` in the event log under
    /// exactly the session its entry carried (`AttentionRecord.dismissal`)
    /// — and no banner for it.
    func dismissWaiting(_ row: AgentRow) {
        guard row.isBlocked else { return }
        notifier.dismissed(row.key)
        writeDismissal(row, event: AttentionRecord.dismissEvent)
    }

    /// The app's own lines, one at a time, off the main thread: the event
    /// log is locked, and a click must not wait on it.
    private static let dismissWrites = DispatchQueue(label: PulseVersion.bundleID + ".attention-dismiss", qos: .userInitiated)

    /// A `dismiss` line: applied to the book at once (the row moves under
    /// the click), appended to the event log off the main thread. The watch
    /// reads it back under its `seq`; the book has already applied it, and a
    /// second clear changes nothing.
    private func writeDismissal(_ row: AgentRow, event: String) {
        let nowMs = ScanEngine.nowMs()
        let record = AttentionRecord.dismissal(
            agent: row.agent, session: row.session, cwd: row.cwd, ms: nowMs, event: event
        )
        // A preview fixture's rows are not the book's; leave them on screen.
        if !previewFixtureActive { engine.apply(records: [record], nowMs: nowMs) }
        Self.dismissWrites.async {
            EventLog.append(record, nowMs: nowMs)
        }
    }

    // MARK: - Hooks

    /// One install or removal of every agent's hook, one at a time
    /// (`HooksSupport.installQueue`; the buttons wait while one runs). An
    /// install clears "don't suggest hooks"; removing them sets it — a
    /// decision.
    func runHooks(
        _ job: HooksSupport.Job,
        agents: [AgentID]? = nil,
        then done: @escaping @MainActor @Sendable (HooksSupport.Status) -> Void = { _ in }
    ) {
        guard !hooksStatus.isWorking else { return }
        let previous = hooksStatus.failures
        land(\.hooksStatus, .working)
        // Only bulk removal disables the setup nudge; any install re-enables it.
        if agents == nil || job == .install {
            let nudgeOff = agents == nil && job == .uninstall
            if settings.hooksNudgeOff != nudgeOff {
                settings.hooksNudgeOff = nudgeOff
                if started { settings.save() }
            }
        }
        // `Task` inherits this class's main-actor isolation, so the assignment
        // lands on main while the hook installer stays off it.
        Task { [weak self] in
            let (status, installs) = await Task.detached(priority: .userInitiated) {
                let status: HooksSupport.Status
                switch job {
                case .install: status = HooksSupport.install(agents: agents, previous: previous)
                case .uninstall: status = HooksSupport.uninstall(agents: agents, previous: previous)
                }
                return (status, HooksSupport.inspectAll())
            }.value
            self?.land(\.hooksStatus, status)
            self?.land(\.hookInstalls, installs)
            done(status)
        }
    }

    /// The setup card's one click: install the hooks of every agent on this
    /// Mac, then ask macOS to allow banners (asked only if it never was),
    /// then show what is left — Codex's trust step, and that sessions
    /// already running appear after their next step.
    func connectFromSetup() {
        let before = hookedAgents
        runHooks(.install) { [weak self] _ in
            PulseNotify.requestAuthorizationAfterUserAction()
            guard let self else { return }
            let connected = self.hookedAgents.subtracting(before)
            if !connected.isEmpty { self.land(\.setupConnected, connected) }
        }
    }
}

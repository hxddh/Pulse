import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 23.0 · the tray as values: the keyboard reducer, the frozen order, the
/// header and its freshness, the one notice, the row's second line, where a
/// banner click goes, and the Settings page's sections.
@Suite("Tray interaction")
struct TrayInteractionTests {
    let now: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private func session(_ key: String, _ agent: AgentID = .claude) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = key
        row.task = "Fix the login test"
        row.project = "app"
        row.liveProcess = true
        row.state = .running
        row.harvestMs = now - minute
        row.source = .session
        return row
    }

    private func blocked(_ key: String, ask: String = "Bash: npm test") -> AgentRow {
        var row = session(key)
        row.state = .blocked(RowWait(kind: "Permission", ask: ask, sinceMs: now - 4 * minute, signal: .hooks))
        return row
    }

    private let rows = [
        TrayKeys.Row(key: "a", blocked: true, canFocus: true),
        TrayKeys.Row(key: "b", blocked: false, canFocus: false),
        TrayKeys.Row(key: "c", blocked: false, canFocus: true),
    ]

    private func press(_ state: TrayKeys.State, _ keys: [TrayKeys.Key], rows: [TrayKeys.Row]? = nil) -> TrayKeys.Outcome {
        let on = rows ?? self.rows
        var outcome = TrayKeys.Outcome(state: state, effect: nil, handled: true)
        for key in keys {
            outcome = TrayKeys.reduce(outcome.state, key, rows: on)
        }
        return outcome
    }

    // MARK: - Keys: selection and go

    @Test func arrowsMoveTheSelectionAndStopAtTheEnds() {
        let down = press(TrayKeys.State(), [.down])
        #expect(down.state.selected == "a", "↓ with nothing selected takes the first row")
        let twice = press(down.state, [.down, .down, .down])
        #expect(twice.state.selected == "c", "the last row holds")
        let up = press(twice.state, [.up])
        #expect(up.state.selected == "b")
        let fromNothingUp = press(TrayKeys.State(), [.up])
        #expect(fromNothingUp.state.selected == "c", "↑ with nothing selected takes the last row")
    }

    @Test func returnGoesToTheTerminalWhenItCan() {
        let state = TrayKeys.State(query: "", selected: "a", detail: nil)
        let outcome = press(state, [.enter])
        #expect(outcome.effect == .focus("a"))
        #expect(outcome.state.detail == nil)
    }

    @Test func returnOpensTheDetailWhenThereIsNoHandle() {
        let state = TrayKeys.State(query: "", selected: "b", detail: nil)
        let outcome = press(state, [.enter])
        #expect(outcome.effect == nil)
        #expect(outcome.state.detail == "b")
    }

    @Test func rightAndSpaceOpenTheDetail() {
        let state = TrayKeys.State(query: "", selected: "c", detail: nil)
        let right = press(state, [.right])
        #expect(right.state.detail == "c")
        let space = press(state, [.space])
        #expect(space.state.detail == "c")
    }

    // MARK: - Keys: the detail page

    @Test func leftAndEscapeLeaveTheDetailAndKeepTheSelection() {
        let open = TrayKeys.State(query: "", selected: nil, detail: "b")
        let left = press(open, [.left])
        #expect(left.state.detail == nil)
        #expect(left.state.selected == "b")
        let escape = press(open, [.escape])
        #expect(escape.state.detail == nil)
        #expect(escape.effect == nil, "Esc in the detail goes back; it does not close the panel")
        #expect(escape.handled)
    }

    @Test func theDetailPageTakesDAndMAndReturn() {
        let open = TrayKeys.State(query: "", selected: "a", detail: "a")
        let dismiss = press(open, [.character("d")])
        #expect(dismiss.effect == .dismiss("a"))
        let mute = press(open, [.character("M")])
        #expect(mute.effect == .toggleMute("a"))
        let go = press(open, [.enter])
        #expect(go.effect == .focus("a"))
        let typing = press(open, [.character("x")])
        #expect(typing.state.query == "", "the detail page has no filter")
        #expect(typing.handled)
    }

    @Test func dismissOnADetailThatIsNotAWaitDoesNothing() {
        let open = TrayKeys.State(query: "", selected: "b", detail: "b")
        let outcome = press(open, [.character("d")])
        #expect(outcome.effect == nil)
    }

    // MARK: - Keys: type to filter

    @Test func typingFiltersAndBackspaceOnlyEditsTheFilter() {
        let typed = press(TrayKeys.State(), [.character("l"), .character("o"), .character("g")])
        #expect(typed.state.query == "log")
        let edited = press(typed.state, [.backspace])
        #expect(edited.state.query == "lo")
        #expect(edited.effect == nil, "⌫ never acts on a row")
        let emptied = press(edited.state, [.backspace, .backspace, .backspace])
        #expect(emptied.state.query == "")
        #expect(emptied.effect == nil)
    }

    @Test func backspaceOnASelectedWaitDoesNotDismissIt() {
        let state = TrayKeys.State(query: "", selected: "a", detail: nil)
        let outcome = press(state, [.backspace])
        #expect(outcome.effect == nil)
        #expect(outcome.state == state)
    }

    @Test func spaceTypesWhileFiltering() {
        let state = TrayKeys.State(query: "fix", selected: "a", detail: nil)
        let outcome = press(state, [.space, .character("l")])
        #expect(outcome.state.query == "fix l")
        #expect(outcome.state.detail == nil)
    }

    @Test func escapeClearsTheFilterThenClosesThePanel() {
        let filtering = TrayKeys.State(query: "zzz", selected: nil, detail: nil)
        let first = press(filtering, [.escape])
        #expect(first.state.query == "")
        #expect(first.effect == nil)
        let second = press(first.state, [.escape])
        #expect(second.effect == .closePanel)
    }

    /// The bug: with no matches the list was replaced and its key handlers
    /// went with it. The reducer does not care what is on screen.
    @Test func escapeWorksWithNoResults() {
        let filtering = TrayKeys.State(query: "nothing matches", selected: nil, detail: nil)
        let outcome = press(filtering, [.escape], rows: [])
        #expect(outcome.handled)
        #expect(outcome.state.query == "")
        let down = press(filtering, [.down], rows: [])
        #expect(down.state.selected == nil)
    }

    @Test func dAndMAreCommandsOnlyWhileTheFilterIsEmpty() {
        let onWait = TrayKeys.State(query: "", selected: "a", detail: nil)
        let dismiss = press(onWait, [.character("D")])
        #expect(dismiss.effect == .dismiss("a"))
        let mute = press(onWait, [.character("m")])
        #expect(mute.effect == .toggleMute("a"))

        let onRunning = TrayKeys.State(query: "", selected: "b", detail: nil)
        let letter = press(onRunning, [.character("d")])
        #expect(letter.effect == nil, "D is not a dismiss on a row that is not waiting")
        #expect(letter.state.query == "d")

        let filtering = TrayKeys.State(query: "co", selected: "a", detail: nil)
        let typed = press(filtering, [.character("d")])
        #expect(typed.state.query == "cod")
        #expect(typed.effect == nil)
    }

    @Test func commandKeysWorkEverywhere() {
        let detail = TrayKeys.State(query: "", selected: nil, detail: "a")
        let refresh = press(detail, [.refresh])
        #expect(refresh.effect == .refresh)
        let settings = press(TrayKeys.State(query: "abc"), [.settings])
        #expect(settings.effect == .openSettings)
        #expect(settings.state.query == "abc")
    }

    @Test func aFilterSelectsItsFirstMatch() {
        let typed = TrayKeys.State(query: "c", selected: nil, detail: nil)
        let filtered = [TrayKeys.Row(key: "c")]
        let normalized = TrayKeys.normalize(typed, rows: filtered)
        #expect(normalized.selected == "c")
        let gone = TrayKeys.State(query: "", selected: "zz", detail: nil)
        let moved = TrayKeys.normalize(gone, rows: rows)
        #expect(moved.selected == "a", "a selection whose row left moves to the first row")
        let none = TrayKeys.normalize(TrayKeys.State(), rows: rows)
        #expect(none.selected == nil, "no filter, no selection: nothing is invented")
    }

    @Test func eventsBecomeKeys() {
        let esc = TrayKeys.key(keyCode: 53, characters: "\u{1b}", command: false, control: false, option: false)
        #expect(esc == .escape)
        let backspace = TrayKeys.key(keyCode: 51, characters: "\u{7f}", command: false, control: false, option: false)
        #expect(backspace == .backspace)
        let refresh = TrayKeys.key(keyCode: 15, characters: "r", command: true, control: false, option: false)
        #expect(refresh == .refresh)
        let copy = TrayKeys.key(keyCode: 8, characters: "c", command: true, control: false, option: false)
        #expect(copy == nil, "⌘C stays the system's")
        let letter = TrayKeys.key(keyCode: 0, characters: "a", command: false, control: false, option: false)
        #expect(letter == .character("a"))
        let function = TrayKeys.key(keyCode: 122, characters: "\u{F704}", command: false, control: false, option: false)
        #expect(function == nil, "a function key is not text")
        let controlled = TrayKeys.key(keyCode: 0, characters: "a", command: false, control: true, option: false)
        #expect(controlled == nil)
    }

    @Test func theFilterSearchesEveryRetainedRow() {
        var codex = session("codex|1", .codex)
        codex.task = "Ship the offline queue"
        let claude = session("claude|1")
        let matches = TrayKeys.filter([claude, codex], query: "offline")
        let keys = matches.map { $0.rowKey }
        #expect(keys == ["codex|1"])
        let all = TrayKeys.filter([claude, codex], query: "  ")
        #expect(all.count == 2)
    }

    // MARK: - The frozen order

    @Test func theOrderHoldsWhileTheTrayIsOpen() {
        let a = session("a"), b = session("b"), c = session("c")
        let frozen = ["a", "b", "c"]
        // The builder now wants c first (it became blocked): the open tray
        // keeps the order it opened with.
        let arranged = TrayOrder.arrange([c, a, b], frozen: frozen)
        let keys = arranged.map { $0.rowKey }
        #expect(keys == ["a", "b", "c"])
    }

    @Test func newcomersAppendAndLeaversDisappear() {
        let a = session("a"), c = session("c"), d = session("d"), e = session("e")
        let arranged = TrayOrder.arrange([e, c, d, a], frozen: ["a", "b", "c"])
        let keys = arranged.map { $0.rowKey }
        #expect(keys == ["a", "c", "e", "d"], "b left; e and d came, in the order they came")
        let extended = TrayOrder.extend(["a", "b", "c"], with: [e, c, d, a])
        #expect(extended == ["a", "b", "c", "e", "d"])
        let again = TrayOrder.arrange([d, e, a, c], frozen: extended)
        let stable = again.map { $0.rowKey }
        #expect(stable == ["a", "c", "e", "d"], "a newcomer keeps the place it was given")
    }

    // MARK: - The header

    private func header(rows: [AgentRow], scanAgoMs: Int64?, interval: Double? = 2, asleep: Bool = false, lang: ResolvedLanguage = .en) -> TrayHeaderModel {
        TrayHeaderModel.make(TrayHeaderModel.Input(
            rows: rows,
            lang: lang,
            nowMs: now,
            lastScanMs: scanAgoMs.map { now - $0 },
            intervalSeconds: interval,
            asleep: asleep
        ))
    }

    @Test func theHeaderCountsWhatMattersInTone() {
        var stalled = session("s")
        stalled.isStalled = true
        var turn = session("t")
        turn.state = .yourTurn(sinceMs: now - minute)
        let model = header(rows: [blocked("w1"), blocked("w2"), session("r"), stalled, turn], scanAgoMs: 8_000)
        let labels = model.counts.map { "\($0.count) \($0.label)" }
        #expect(labels == ["2 need you", "1 running", "1 stalled", "1 your turn"])
        let tones = model.counts.map { $0.tone }
        #expect(tones == [.waiting, .running, .attention, .idle])
        #expect(model.freshness == String(format: L10n.t(.headerUpdatedAgo, .en), "8s"))
        #expect(!model.stale)
    }

    @Test func oneWaitIsSingular() {
        let model = header(rows: [blocked("w")], scanAgoMs: 1_000)
        let labels = model.counts.map { $0.label }
        #expect(labels == [L10n.t(.waiting1, .en)])
        #expect(model.freshness == L10n.t(.headerUpdatedNow, .en))
    }

    @Test func aLateScanSaysSoInsteadOfItsFreshness() {
        let model = header(rows: [session("r")], scanAgoMs: 4 * minute, interval: 5)
        #expect(model.stale)
        #expect(model.freshness == String(format: L10n.t(.headerNotUpdated, .en), "4m"))
    }

    @Test func staleMeansTwiceTheIntervalAndNeverSooner() {
        let justLate = header(rows: [], scanAgoMs: 31_000, interval: 2)
        #expect(justLate.stale, "past the thirty-second floor")
        let notYet = header(rows: [], scanAgoMs: 25_000, interval: 2)
        #expect(!notYet.stale, "the floor keeps an open tray from flashing orange")
        let slow = header(rows: [], scanAgoMs: 50_000, interval: 30)
        #expect(!slow.stale, "a 30 s cadence is late only after a minute")
        let asleep = header(rows: [], scanAgoMs: 1_000, asleep: true)
        #expect(asleep.stale, "asleep or locked: nothing is being read")
    }

    @Test func anEmptyHeaderSaysWhatIsTrue() {
        let none = header(rows: [], scanAgoMs: nil)
        #expect(none.counts.isEmpty)
        #expect(none.title == L10n.t(.noAgents, .en))
        #expect(none.freshness == L10n.t(.headerUpdating, .en))
        var process = AgentRow(rowKey: RowIdentity.process(agent: .amp, pid: 1), agent: .amp)
        process.state = .processOnly
        let grey = header(rows: [process], scanAgoMs: 1_000, lang: .zh)
        #expect(grey.title == "1 " + L10n.t(.processOnlyN, .zh))
    }

    // MARK: - The one notice

    private func notice(
        notify: Bool = true, authorized: Bool? = true, banner: Bool = false,
        hooks: Bool = false, scan: Bool = false
    ) -> TrayNoticeModel? {
        TrayNoticeModel.pick(TrayNoticeModel.Input(
            lang: .en, notifyOnWaiting: notify, notifyAuthorized: authorized,
            bannerFailed: banner, hooksMissing: hooks, scanIncomplete: scan
        ))
    }

    @Test func atMostOneNoticeInItsOrder() {
        let all = notice(authorized: false, banner: true, hooks: true, scan: true)
        #expect(all?.kind == .notificationsDenied)
        #expect(all?.action == .openNotificationSettings)
        let notAsked = notice(authorized: nil, hooks: true)
        #expect(notAsked?.kind == .notificationsOff)
        #expect(notAsked?.action == .enableNotifications)
        let hooks = notice(hooks: true, scan: true)
        #expect(hooks?.kind == .hooksMissing)
        #expect(hooks?.action == .installHooks)
        let scan = notice(scan: true)
        #expect(scan?.action == .openDiagnostics)
        #expect(notice() == nil)
        let optedOut = notice(notify: false, authorized: false)
        #expect(optedOut == nil, "notifications turned off in Pulse are not a problem")
    }

    // MARK: - The row's second line

    @Test func onlyABlockedOrOrangeRowHasASecondLine() {
        let face = { (row: AgentRow) in TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now)) }
        let waiting = face(blocked("w", ask: "Allow npm test?"))
        #expect(waiting.secondLine == TrayRowModel.SecondLine(kind: .ask, text: "Allow npm test?"))
        let running = face(session("r"))
        #expect(running.secondLine == nil)
        var stalledRow = session("s")
        stalledRow.isStalled = true
        let stalled = face(stalledRow)
        #expect(stalled.secondLine?.kind == .warning)
        var failingRow = session("f")
        failingRow.state = .recent
        failingRow.errors = 1
        let failing = face(failingRow)
        #expect(failing.secondLine?.kind == .warning)
        #expect(failing.lamp == LampFace(shape: .hollow, tone: .attention))
        var turnRow = session("t")
        turnRow.state = .yourTurn(sinceMs: now)
        let turn = face(turnRow)
        #expect(turn.secondLine == nil)
        #expect(turn.turnLabel == L10n.t(.yourTurn, .en))
    }

    @Test func aWaitingRowShowsOnlyTheWaitAge() {
        let model = TrayRowModel.make(TrayRowModel.Input(row: blocked("w"), lang: .en, nowMs: now))
        #expect(model.age == "4m")
        let running = TrayRowModel.make(TrayRowModel.Input(row: session("r"), lang: .en, nowMs: now))
        #expect(running.age == String(format: L10n.t(.agoFormat, .en), "1m"))
    }

    // MARK: - Banner clicks

    @Test func aBannerClickGoesToTheTerminalAndNowhereElse() {
        #expect(BannerRoute.decide(target: "claude|a", focused: true) == .terminal)
        #expect(BannerRoute.decide(target: "claude|a", focused: false) == .detail("claude|a"))
        #expect(BannerRoute.decide(target: nil, focused: false) == .tray)
    }

    @MainActor
    @Test func aBannerForARowWithNoHandleOpensItsDetail() throws {
        let store = StatusStore()
        store.installPreviewFixture("status-waiting")
        let firstBlocked = store.allRowsForDisplay.first { $0.isBlocked }
        let row = try #require(firstBlocked)
        store.clearPendingRevealRowKey()
        store.focusAgent(idRaw: row.agent.rawValue, session: row.sessionID, rowKey: row.rowKey)
        let reveal = store.takePendingReveal()
        #expect(reveal?.rowKey == row.rowKey)
        #expect(reveal?.detail == true)
        let again = store.takePendingReveal()
        #expect(again == nil, "a reveal is taken once")
    }

    @MainActor
    @Test func aRevealForARowThatIsGoneIsDropped() {
        let store = StatusStore()
        store.installPreviewFixture("status-waiting")
        let ui = TrayUI(store: store)
        ui.open(selectMostUrgent: false)
        store.requestTrayReveal(rowKey: "gone|nowhere", detail: true)
        ui.applyPendingReveal()
        #expect(ui.keys.detail == nil)
        #expect(store.pendingRevealRowKey == nil)
    }

    @MainActor
    @Test func aRevealWhileADetailIsOpenIsApplied() throws {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        let ui = TrayUI(store: store)
        ui.open(selectMostUrgent: false)
        let rows = store.allRowsForDisplay
        try #require(rows.count >= 2)
        ui.showDetail(rows[0].rowKey)
        store.requestTrayReveal(rowKey: rows[1].rowKey, detail: true)
        ui.applyPendingReveal()
        #expect(ui.keys.detail == rows[1].rowKey)
        #expect(ui.keys.selected == rows[1].rowKey)
    }

    @MainActor
    @Test func theHotkeyOpensOnTheMostUrgentRow() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        let ui = TrayUI(store: store)
        ui.open(selectMostUrgent: true)
        let first = ui.displayRows.first?.rowKey
        #expect(ui.keys.selected == first)
        #expect(first != nil)
    }

    // MARK: - Settings

    @Test func settingsIsOnePageOfSevenSections() {
        #expect(SettingsModel.sections == [.general, .shortcut, .notifications, .hooks, .terminal, .dataAccess, .updates])
        let titles = SettingsModel.sections.map { SettingsModel.title($0, lang: .zh) }
        #expect(Set(titles).count == titles.count, "every section has its own name")
    }

    @Test func deepLinksLandOnTheirSection() {
        #expect(SettingsModel.section(for: .appData) == .dataAccess)
        #expect(SettingsModel.section(for: .waitingSignals) == .hooks)
        #expect(SettingsModel.section(for: .notifications) == .notifications)
        #expect(SettingsModel.section(for: .updates) == .updates)
    }

    @Test func mutedAgentsReadInOrder() {
        let muted = SettingsModel.sortedMuted([.gemini, .aider, .claude])
        let names = muted.map { $0.displayName }
        let ordered = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #expect(names == ordered)
        #expect(SettingsModel.notifications(nil) == .notAsked)
        #expect(SettingsModel.notifications(false) == .denied)
    }

    @MainActor
    @Test func theSettingsPageReadsSettingsNotScans() {
        let store = StatusStore()
        store.settings.mutedAgents = [.codex]
        store.notifyAuthorized = false
        let model = store.settingsModel
        #expect(model.mutedAgents == [.codex])
        #expect(model.notifications == .denied)
        #expect(!model.notifyOnWaiting, "the switch shows what takes effect")
        store.performSettings(.unmute(.codex))
        #expect(store.settings.mutedAgents.isEmpty)
    }

    // MARK: - Diagnostics

    @Test func diagnosticsPutsProblemsFirstAndSortsAgentsByNeed() {
        let model = SurfaceFixtures.diagnostics(lang: .en)
        let first = model.problems.first?.id
        #expect(first == "scan", "standing problems come before the self-check's findings")
        let order = model.agents.map { $0.agent }
        #expect(order.first == .codex, "what needs action sorts first")
        #expect(order.last == .aider, "not installed sorts last")
    }
}

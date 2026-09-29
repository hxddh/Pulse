import Foundation
import AppKit
import Testing
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Tray: the row face, header, keys, order, lamp, detail page and copy.

// 23.0 removed the observation, work and compute lines (and the CPU and
// memory facts they rendered) with `RowNarrator`; what a row says is pinned
// in `ExplainTests`. The focus-honesty rule below stays.

/// A workspace the disk could not confirm must not be offered as a landing.
final class BestEffortWorkspaceTests: XCTestCase {
    @MainActor
    func testAnUnverifiedWorkspaceDropsToAppPrecision() {
        let env = TerminalFocus.Environment(
            warpRunning: true,
            ttyHostRunning: true,
            allowTTYAutomation: true
        )
        let verified = TerminalFocus.focusTier(
            tty: "", viaWarp: false, hostApp: .cursor,
            workspace: "/Users/me/my-project", workspaceVerified: true, env: env
        )
        let guessed = TerminalFocus.focusTier(
            tty: "", viaWarp: false, hostApp: .cursor,
            workspace: "/Users/me/my/project", workspaceVerified: false, env: env
        )
        if case .hostWorkspace = verified {} else {
            XCTFail("a confirmed path still lands on the workspace: \(String(describing: verified))")
        }
        if case .hostApp = guessed {} else {
            XCTFail("an unconfirmed decode must not open a folder: \(String(describing: guessed))")
        }
    }
}

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
        row.eventMs = now - minute
        row.source = .hooks
        return row
    }

    private func blocked(_ key: String, ask: String = "Bash: npm test") -> AgentRow {
        var row = session(key)
        row.state = .blocked(RowWait(kind: "Permission", ask: ask, sinceMs: now - 4 * minute))
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

    @Test func theDetailPageTakesCommandDAndCommandMAndReturn() {
        let open = TrayKeys.State(query: "", selected: "a", detail: "a")
        let dismiss = press(open, [.dismiss])
        #expect(dismiss.effect == .dismiss("a"))
        let mute = press(open, [.mute])
        #expect(mute.effect == .toggleMute("a"))
        let go = press(open, [.enter])
        #expect(go.effect == .focus("a"))
        let letter = press(open, [.character("d")])
        #expect(letter.effect == nil, "a bare D is a letter, never a dismiss")
        let typing = press(open, [.character("x")])
        #expect(typing.state.query == "", "the detail page has no filter")
        #expect(typing.handled)
    }

    @Test func dismissOnADetailThatIsNotAWaitDoesNothing() {
        let open = TrayKeys.State(query: "", selected: "b", detail: "b")
        let outcome = press(open, [.dismiss])
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

    /// 23.0 bug: the tray opens with a row selected, so typing "deploy" or
    /// "main" to filter dismissed the selected wait or muted its agent on
    /// the first letter. Letters always filter; the commands carry ⌘.
    @Test func lettersAlwaysFilterEvenWithAWaitSelected() {
        let onWait = TrayKeys.State(query: "", selected: "a", detail: nil)
        let typedD = press(onWait, [.character("d")])
        #expect(typedD.effect == nil, "D on a selected wait is a letter")
        #expect(typedD.state.query == "d")
        let typedM = press(onWait, [.character("M")])
        #expect(typedM.effect == nil, "M on a selected row is a letter")
        #expect(typedM.state.query == "M")
        let word = press(onWait, [.character("d"), .character("e"), .character("p")])
        #expect(word.effect == nil)
        #expect(word.state.query == "dep")
    }

    @Test func commandDAndCommandMActOnTheSelectedRow() {
        let onWait = TrayKeys.State(query: "", selected: "a", detail: nil)
        let dismiss = press(onWait, [.dismiss])
        #expect(dismiss.effect == .dismiss("a"))
        let mute = press(onWait, [.mute])
        #expect(mute.effect == .toggleMute("a"))

        let onRunning = TrayKeys.State(query: "", selected: "b", detail: nil)
        let notAWait = press(onRunning, [.dismiss])
        #expect(notAWait.effect == nil, "⌘D is not a dismiss on a row that is not waiting")
        #expect(notAWait.state.query == "")

        let filtering = TrayKeys.State(query: "co", selected: "a", detail: nil)
        let whileFiltering = press(filtering, [.dismiss])
        #expect(whileFiltering.effect == .dismiss("a"), "⌘D works while filtering too")
        #expect(whileFiltering.state.query == "co")

        let nothingSelected = press(TrayKeys.State(), [.mute])
        #expect(nothingSelected.effect == nil)
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
        let dismiss = TrayKeys.key(keyCode: 2, characters: "d", command: true, control: false, option: false)
        #expect(dismiss == .dismiss)
        let dismissByDelete = TrayKeys.key(keyCode: 51, characters: "\u{7f}", command: true, control: false, option: false)
        #expect(dismissByDelete == .dismiss)
        let mute = TrayKeys.key(keyCode: 46, characters: "m", command: true, control: false, option: false)
        #expect(mute == .mute)
        let bareD = TrayKeys.key(keyCode: 2, characters: "d", command: false, control: false, option: false)
        #expect(bareD == .character("d"))
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

    /// 23.0 bug: while the tray was open the list was the builder's top-12
    /// window re-arranged, so a new wait sorting to the top pushed the
    /// twelfth row — possibly the one under the pointer — out of the list.
    @Test func aNewWaitWhileOpenIsAppendedAndPushesNothingOut() {
        let shown = (0..<12).map { session("r\($0)") }
        let frozen = shown.map { $0.rowKey }
        let wait = blocked("new-wait")
        // The builder now puts the wait first and folds the old twelfth row.
        let window = [wait] + shown.prefix(11)
        let all = [wait] + shown
        let listed = TrayOrder.openWindow(
            all: all, window: window, pinned: Set(frozen), frozen: frozen, cap: TrayOrder.openCap
        )
        let keys = listed.map { $0.rowKey }
        #expect(keys == frozen + ["new-wait"], "every row shown stays, in place; the wait is appended")
    }

    @Test func theOpenListDropsRowsThatLeftAndCapsOnlyNewcomers() {
        let a = session("a"), b = session("b"), c = session("c"), d = session("d")
        let listed = TrayOrder.openWindow(
            all: [c, a, d], window: [d, c, a], pinned: ["a", "b", "c"], frozen: ["a", "b", "c"], cap: 3
        )
        let keys = listed.map { $0.rowKey }
        #expect(keys == ["a", "c", "d"], "b left the scan; d is new")
        let capped = TrayOrder.openWindow(
            all: [a, b, c, d], window: [d, a], pinned: ["a", "b", "c"], frozen: ["a", "b", "c"], cap: 3
        )
        let cappedKeys = capped.map { $0.rowKey }
        #expect(cappedKeys == ["a", "b", "c"], "the cap holds newcomers back, never a row already shown")
        let fresh = TrayOrder.openWindow(all: [a, b], window: [b], pinned: [], frozen: [], cap: 12)
        let freshKeys = fresh.map { $0.rowKey }
        #expect(freshKeys == ["b"], "nothing pinned: the builder's window")
    }

    // MARK: - The header

    private func header(
        rows: [AgentRow], scanAgoMs: Int64?, interval: Double? = 2, lastScanInterval: Double? = nil,
        asleep: Bool = false, lang: ResolvedLanguage = .en
    ) -> TrayHeaderModel {
        TrayHeaderModel.make(TrayHeaderModel.Input(
            rows: rows,
            lang: lang,
            nowMs: now,
            lastScanMs: scanAgoMs.map { now - $0 },
            intervalSeconds: interval,
            lastScanIntervalSeconds: lastScanInterval,
            asleep: asleep
        ))
    }

    /// 23.0 bug: opening the tray shortens the interval at once, and the
    /// header judged the scan on screen — scheduled a minute apart — by the
    /// new two seconds: orange "not updated" on every open.
    @Test func openingTheTrayDoesNotFlashTheHeaderOrange() {
        let opened = header(rows: [session("r")], scanAgoMs: 50_000, interval: 2, lastScanInterval: 60)
        #expect(!opened.stale, "the last scan was due by the minute that scheduled it")
        let late = header(rows: [session("r")], scanAgoMs: 125_000, interval: 2, lastScanInterval: 60)
        #expect(late.stale, "past twice that interval it is late")
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
        var process = AgentRow(rowKey: RowIdentity.process(agent: .codex, pid: 1), agent: .codex)
        process.state = .processOnly
        let grey = header(rows: [process], scanAgoMs: 1_000, lang: .zh)
        #expect(grey.title == "1 " + L10n.t(.processOnlyN, .zh))
    }

    // MARK: - The one notice

    private func notice(
        notify: Bool = true, authorized: Bool? = true, banner: Bool = false,
        hooks: Bool = false
    ) -> TrayNoticeModel? {
        TrayNoticeModel.pick(TrayNoticeModel.Input(
            lang: .en, notifyOnWaiting: notify, notifyAuthorized: authorized,
            bannerFailed: banner, hooksMissing: hooks
        ))
    }

    @Test func atMostOneNoticeInItsOrder() {
        let all = notice(authorized: false, banner: true, hooks: true)
        #expect(all?.kind == .notificationsDenied)
        #expect(all?.action == .openNotificationSettings)
        let notAsked = notice(authorized: nil, hooks: true)
        #expect(notAsked?.kind == .notificationsOff)
        #expect(notAsked?.action == .enableNotifications)
        let hooks = notice(hooks: true)
        #expect(hooks?.kind == .hooksMissing)
        #expect(hooks?.action == .installHooks)
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
        failingRow.lastErrorText = "npm ERR!"
        let failing = face(failingRow)
        #expect(failing.secondLine == nil, "24.0: an error is a detail-page fact, not an orange row")
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
}

/// The tray opens on "who needs me", never on the last visit's rummaging.
/// EXPERIENCE §4: "展开状态不持久化". The panel is built once and only ordered in
/// and out, so nothing resets `@State` on its own (U-3).
final class TrayGlanceResetTests: XCTestCase {
    @MainActor
    func testEachOpenGivesTheTrayANewIdentity() {
        let store = StatusStore()
        let atLaunch = store.traySessionToken
        store.trayWillAppear()
        let firstOpen = store.traySessionToken
        store.trayWillAppear()
        let secondOpen = store.traySessionToken
        XCTAssertNotEqual(atLaunch, firstOpen)
        XCTAssertNotEqual(firstOpen, secondOpen, "every open discards the previous view state")
    }

    /// `showAllAgents` lives on the store rather than in `@State`, so the view
    /// identity alone cannot reset it.
    @MainActor
    func testOpeningTheTrayCollapsesTheExpandedList() {
        let store = StatusStore()
        store.toggleShowAllAgents()
        XCTAssertTrue(store.showAllAgents)
        store.trayWillAppear()
        XCTAssertFalse(store.showAllAgents)
    }

    /// The host view is what carries the identity into SwiftUI; keep it wired.
    @MainActor
    func testTheTrayHostIsBuiltFromTheSameStore() {
        let store = StatusStore()
        _ = TrayPanelHost(store: store, ui: TrayUI(store: store))
    }
}

final class StatusPanelChromeTests: XCTestCase {
    @MainActor
    func testRoundedMaterialOwnsItsShadowInsideATransparentWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 444, height: 204),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        let root = NSView(frame: panel.contentView?.bounds ?? .zero)
        let shadow = NSView(frame: root.bounds.insetBy(
            dx: StatusPanelChrome.shadowInset,
            dy: StatusPanelChrome.shadowInset
        ))
        let effect = NSVisualEffectView(frame: shadow.frame)
        root.addSubview(shadow)
        root.addSubview(effect)
        panel.contentView = root

        StatusPanelChrome.apply(
            to: panel,
            rootView: root,
            shadowView: shadow,
            effectView: effect
        )

        XCTAssertFalse(panel.hasShadow, "WindowServer shadow is rectangular for this panel")
        XCTAssertEqual(effect.layer?.cornerRadius, StatusPanelChrome.cornerRadius)
        XCTAssertTrue(effect.layer?.masksToBounds == true)
        XCTAssertEqual(shadow.layer?.cornerRadius, StatusPanelChrome.cornerRadius)
        XCTAssertNotNil(shadow.layer?.shadowPath)
        XCTAssertGreaterThan(shadow.layer?.shadowOpacity ?? 0, 0)
        let background = root.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        XCTAssertEqual(background?.alphaComponent, 0)

        root.layoutSubtreeIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            return XCTFail("window root did not produce a visual regression bitmap")
        }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let corners = [
            (0, 0),
            (bitmap.pixelsWide - 1, 0),
            (0, bitmap.pixelsHigh - 1),
            (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1),
        ]
        for (x, y) in corners {
            XCTAssertLessThan(
                bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1,
                0.01,
                "the AppKit window root leaked an opaque square corner"
            )
        }
    }
}

final class StatusLampTests: XCTestCase {
    func testStatusBarLampsKeepTheirStateColors() {
        let states: [GlanceKind] = [.waiting, .running, .idle, .stalled]
        for state in states {
            XCTAssertFalse(
                PulseBrand.statusBarIcon(for: state).isTemplate,
                "\(state) must not be recolored by the menu bar"
            )
        }

        let waiting = PulseBrand.statusColor(for: GlanceKind.waiting).usingColorSpace(.deviceRGB)!
        let running = PulseBrand.statusColor(for: GlanceKind.running).usingColorSpace(.deviceRGB)!
        let stalled = PulseBrand.statusColor(for: GlanceKind.stalled).usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(waiting.redComponent, waiting.greenComponent)
        XCTAssertGreaterThan(running.greenComponent, running.redComponent)
        XCTAssertGreaterThan(stalled.redComponent, stalled.blueComponent)
        XCTAssertGreaterThan(stalled.greenComponent, stalled.blueComponent)
    }
}

/// VoiceOver must speak the interface language, not English.
final class AccessibilityLocalizationTests: XCTestCase {
    func testGlanceStatesHaveDistinctLocalizedLabels() {
        for glance in [GlanceKind.idle, .running, .stalled, .waiting] {
            let en = L10n.t(glance.accessibilityKey, .en)
            let zh = L10n.t(glance.accessibilityKey, .zh)
            XCTAssertFalse(en.isEmpty)
            XCTAssertFalse(zh.isEmpty)
            XCTAssertNotEqual(en, zh, "\(glance) was not translated")
        }
    }

    func testSnapshotCarriesTheResolvedLabelSoTheViewNeedsNoLanguage() {
        let ctx = SnapshotBuilder.Context(nowMs: 1_700_000_000_000, lang: .zh)
        let result = SnapshotBuilder.build(rows: [], previous: .init(), context: ctx)
        XCTAssertEqual(result.snapshot.accessibilityLabel, L10n.t(.a11yIdle, .zh))
    }

    func testStatusBarIconsKeepTheirTrafficLightColourAcrossAppearances() throws {
        let original = NSAppearance.current
        defer { NSAppearance.current = original }

        let appearances: [NSAppearance.Name] = [
            .aqua,
            .darkAqua,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
        ]
        for appearanceName in appearances {
            NSAppearance.current = try XCTUnwrap(NSAppearance(named: appearanceName))
            var rgba: Set<String> = []
            for glance in [GlanceKind.idle, .running, .stalled, .waiting] {
                let icon = PulseBrand.statusBarIcon(for: glance)
                XCTAssertFalse(
                    icon.isTemplate,
                    "\(glance) would be flattened to monochrome in \(appearanceName.rawValue)"
                )
                XCTAssertEqual(icon.size, NSSize(width: 16, height: 16))
                let bitmap = try XCTUnwrap(
                    icon.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
                )
                var visiblePixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide
                    where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.08 {
                        visiblePixels += 1
                    }
                }
                XCTAssertGreaterThan(
                    visiblePixels,
                    8,
                    "\(glance) disappeared in \(appearanceName.rawValue)"
                )

                let color = PulseBrand.statusColor(for: glance)
                    .usingColorSpace(.deviceRGB) ?? PulseBrand.statusColor(for: glance)
                rgba.insert(
                    String(
                        format: "%.3f,%.3f,%.3f,%.3f",
                        color.redComponent,
                        color.greenComponent,
                        color.blueComponent,
                        color.alphaComponent
                    )
                )
            }
            XCTAssertEqual(
                rgba.count,
                4,
                "red, green, grey and orange merged in \(appearanceName.rawValue)"
            )
        }
    }
}

/// 15.0 · Witness — the product's rules asserted on the surface values
/// `SurfaceCapture` photographs, not on the store behind them. 23.0: the
/// tray row, header, notice and filter, the detail page, Settings,
/// Diagnostics and the self-check.
final class SurfaceModelTests: XCTestCase {

    // MARK: - The fixture list the capture script reads

    func testTheCaptureScriptsNamesAreTheFixtures() {
        XCTAssertEqual(SurfaceFixtures.all(lang: .en).map(\.name), SurfaceFixtures.names)
        XCTAssertEqual(Set(SurfaceFixtures.names).count, SurfaceFixtures.names.count)
    }

    // MARK: - Both languages

    private func firstMenuTitle(_ lang: ResolvedLanguage) -> String? {
        guard case .row(let model, _) = SurfaceFixtures.all(lang: lang).first?.value else { return nil }
        return model.menu.first?.title
    }

    func testEveryFixtureSpeaksBothLanguages() {
        XCTAssertEqual(SurfaceFixtures.all(lang: .zh).map(\.name), SurfaceFixtures.names)
        XCTAssertNotNil(firstMenuTitle(.en))
        XCTAssertNotEqual(firstMenuTitle(.zh), firstMenuTitle(.en))
    }
}

/// Focus honesty: never claim a TTY we cannot select.
final class FocusTierTests: XCTestCase {
    private let fullEnv = TerminalFocus.Environment(
        warpRunning: true, ttyHostRunning: true, allowTTYAutomation: true
    )

    func testWarpWins_WhenProcessRunsUnderWarp() {
        let tier = TerminalFocus.focusTier(tty: "ttys003", viaWarp: true, env: fullEnv)
        XCTAssertEqual(tier, .warp, "TTY tab select does not work inside Warp")
    }

    func testHostAppIsAdvertisedWithoutAutomation() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: false, allowTTYAutomation: false
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(
                tty: "", viaWarp: false, hostApp: .cursor, env: env
            ),
            .hostApp(.cursor)
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(
                tty: "ttys003", viaWarp: false, hostApp: .vsCode, env: env
            ),
            .hostApp(.vsCode)
        )
    }

    func testAbsoluteWorkspacePromotesHostWorkspaceTier() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: false, allowTTYAutomation: false
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(
                tty: "",
                viaWarp: false,
                hostApp: .cursor,
                workspace: "/Users/me/code/Pulse",
                env: env
            ),
            .hostWorkspace(.cursor)
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(
                tty: "",
                viaWarp: false,
                hostApp: .zed,
                workspace: "/",
                env: env
            ),
            .hostApp(.zed),
            "root is not a usable workspace advertisement"
        )
        XCTAssertFalse(TerminalFocus.isAbsoluteWorkspacePath(""))
        XCTAssertFalse(TerminalFocus.isAbsoluteWorkspacePath("relative/path"))
        XCTAssertTrue(TerminalFocus.isAbsoluteWorkspacePath("/Users/me/proj"))
    }

    func testWarpBeatsHostApp() {
        let env = TerminalFocus.Environment(
            warpRunning: true, ttyHostRunning: false, allowTTYAutomation: false
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(
                tty: "", viaWarp: true, hostApp: .cursor, workspace: "/Users/me/p", env: env
            ),
            .warp
        )
    }

    func testTTYIsNotAdvertisedUntilAutomationOptIn() {
        let off = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: true, allowTTYAutomation: false
        )
        XCTAssertNil(
            TerminalFocus.focusTier(tty: "ttys003", viaWarp: false, env: off),
            "default off — never advertise TTY before Shortcuts opt-in"
        )
        let on = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: true, allowTTYAutomation: true
        )
        XCTAssertEqual(
            TerminalFocus.focusTier(tty: "ttys003", viaWarp: false, env: on),
            .tty
        )
    }

    func testCwdDoesNotPretendToBeAFocusHandle() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: false, allowTTYAutomation: false
        )
        XCTAssertNil(TerminalFocus.focusTier(tty: "ttys003", viaWarp: false, env: env))
    }

    func testNoHandleMeansNoFocusButtonAtAll() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: false, allowTTYAutomation: false
        )
        XCTAssertNil(TerminalFocus.focusTier(tty: "", viaWarp: false, env: env))
    }

    func testPlaceholderTTYValuesAreNotRealHandles() {
        let env = TerminalFocus.Environment(
            warpRunning: false, ttyHostRunning: true, allowTTYAutomation: true
        )
        for placeholder in ["", "?", "??", "-"] {
            XCTAssertNil(
                TerminalFocus.focusTier(tty: placeholder, viaWarp: false, env: env),
                "\(placeholder) should not count as a TTY"
            )
        }
    }

    func testFocusHostAppActionCopyIsProductNameNotGenericTerminal() {
        let enApp = L10n.t(.focusHostApp, .en)
        XCTAssertEqual(String(format: enApp, HostAppKind.cursor.displayName), "Go to Cursor (app)")
        let enWs = L10n.t(.focusHostWorkspace, .en)
        XCTAssertEqual(String(format: enWs, HostAppKind.zed.displayName), "Go to the workspace in Zed")
        XCTAssertEqual(L10n.t(.focusWarp, .en), "Go to Warp (app)")
        let zh = L10n.t(.focusHostApp, .zh)
        XCTAssertEqual(String(format: zh, "Cursor"), "前往 Cursor（应用）")
    }
}

/// Every localized key must resolve in both languages.
final class L10nTests: XCTestCase {
    func testNoKeyIsBlankInEitherLanguage() {
        for key in L10n.Key.allCases {
            XCTAssertFalse(L10n.t(key, .en).isEmpty, "empty en string for \(key)")
            XCTAssertFalse(L10n.t(key, .zh).isEmpty, "empty zh string for \(key)")
        }
    }

    func testFormatSpecifiersMatchAcrossLanguages() {
        // A %d that exists in one language but not the other crashes String(format:).
        for key in L10n.Key.allCases {
            let en = L10n.t(key, .en)
            let zh = L10n.t(key, .zh)
            XCTAssertEqual(
                en.components(separatedBy: "%d").count,
                zh.components(separatedBy: "%d").count,
                "%d count differs for \(key)"
            )
            XCTAssertEqual(
                en.components(separatedBy: "%@").count,
                zh.components(separatedBy: "%@").count,
                "%@ count differs for \(key)"
            )
        }
    }

    func testDurationUnitsAreLocalized() {
        XCTAssertNotEqual(L10n.t(.durMin, .en), L10n.t(.durMin, .zh), "zh tray showed English units")
    }
}

/// Every user-facing string goes through the table (U-9).
final class LocalizedCopyTests: XCTestCase {
    /// One table for the tooltip, the chip and the banner.
    func testWaitKindTranslationIsSharedWithTheBuilder() {
        XCTAssertEqual(L10n.waitKind("Permission", .zh), L10n.t(.kindPermission, .zh))
        XCTAssertEqual(L10n.waitKind("", .zh), L10n.t(.needsYou, .zh))
        XCTAssertEqual(
            L10n.waitKind("Somethingelse", .zh), "Somethingelse",
            "an unknown vendor kind is passed through, not invented"
        )
    }
}

/// Duration wording moved off `StatusStore` so `SnapshotBuilder` — which is
/// pure and has no store — could put the elapsed wait in the menu bar.
final class DurationFormatTests: XCTestCase {
    func testUnitsCrossOverAtTheRightPlaces() {
        XCTAssertEqual(DurationFormat.label(seconds: 2, lang: .en), "now")
        XCTAssertEqual(DurationFormat.label(seconds: 42, lang: .en), "42s")
        XCTAssertEqual(DurationFormat.label(seconds: 600, lang: .en), "10m")
        XCTAssertEqual(DurationFormat.label(seconds: 7200, lang: .en), "2h")
    }

    func testChineseDiffersFromEnglish() {
        XCTAssertNotEqual(
            DurationFormat.label(seconds: 600, lang: .zh),
            DurationFormat.label(seconds: 600, lang: .en)
        )
    }
}

/// 0.96 Return Truth — Glance width and Attention compact. (23.0: the rekey
/// and story-honesty tests went with the remap and `RowNarrator`.)
final class GlanceTitleTests: XCTestCase {

    @MainActor
    func testGlanceTitleBudgetFitsEightCells() {
        XCTAssertEqual(GlanceTitle.cells("Claude…"), 7)
        XCTAssertEqual(GlanceTitle.cells("Claude · 4m"), 11)
        XCTAssertEqual(GlanceTitle.cells("1 · 4m"), 6)
        XCTAssertEqual(GlanceTitle.cells("中"), 2)
        XCTAssertEqual(GlanceTitle.fit("Claude · 4m", "1 · 4m", "1"), "1 · 4m")
        XCTAssertEqual(GlanceTitle.fit("Claude…", "1"), "Claude…")
        XCTAssertEqual(GlanceTitle.fit("Antigravity", "1"), "1")
        XCTAssertLessThanOrEqual(GlanceTitle.cells("Claude…"), GlanceTitle.maxCells)
    }

    @MainActor
    func testIdleGlanceStaysEmpty() {
        let r = SnapshotBuilder.build(
            rows: [],
            previous: .init(),
            context: SnapshotBuilder.Context(nowMs: 1_700_000_000_000, lang: .en)
        )
        XCTAssertEqual(r.snapshot.glance, .idle)
        XCTAssertEqual(r.snapshot.title, "")
    }
}

/// The agent's own words are quoted as *now* only while they are fresh —
/// one rule for every surface.
final class DetailPlanTests: XCTestCase {
    private let now: Int64 = 1_800_000_000_000

    func testSelfReportFreshnessIsOneRuleForEverySurface() {
        // Codex review on #74: Details showed "Current step" past the 30
        // minutes where the story line had already withdrawn it. Every
        // surface reads this one rule.
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.eventMs = now - 5 * 60 * 1000
        XCTAssertTrue(row.selfReportFresh(at: now))
        row.eventMs = now - 31 * 60 * 1000
        XCTAssertFalse(row.selfReportFresh(at: now), "the headline and the detail page share this gate")
    }

    func testTheLastMessageNeverImpliesWaiting() {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.lastWord = "Waiting for your review."
        row.state = .running
        row.eventMs = now
        let detail = DetailModel.make(row: row, lang: .en, nowMs: now)
        XCTAssertEqual(detail.lastMessage, "Waiting for your review.")
        XCTAssertFalse(row.isBlocked, "words never write Waiting")
        XCTAssertFalse(detail.canDismiss)
    }
}

/// Clarity fixes — each test pins one defect found by reading the code: the
/// value the user would have seen, before and after.
@MainActor
@Suite("Terminal tab script", .serialized)/// Clarity fixes — each test pins one defect found by reading the code: the
/// value the user would have seen, before and after.
@MainActor
@Suite("Terminal tab script", .serialized)
struct TerminalTabScriptTests {
    // MARK: - 9 · the tab search activates only on a match

    @Test(arguments: [TerminalFocus.terminalTabScript(tty: "ttys003"), TerminalFocus.iTermTabScript(tty: "ttys003")])
    func aTabSearchActivatesOnlyOnAMatch(script: String) throws {
        let match = try #require(script.range(of: "if ttyName contains"))
        let activate = try #require(script.range(of: "activate"))
        #expect(activate.lowerBound > match.upperBound, "activating before the search brought an unrelated window forward")
    }
}

/// 2.3 — the defects a fresh audit at the 2.2 baseline turned up.
///
/// Each of these is a place where the code said something it had not
/// measured, dropped work it had been asked to do, or let a click reach
/// nothing without saying so.
final class RowActionNoticeTests: XCTestCase {

    @MainActor
    private func store(_ lang: AppLanguage = .en) -> StatusStore {
        let store = StatusStore()
        store.settings.language = lang
        return store
    }

    private func liveRow() -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Fix the auth module"
        row.liveProcess = true
        row.state = .running
        row.eventMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.source = .hooks
        return row
    }

    // MARK: D-6 / D-7 · a click that reached nothing says so

    @MainActor
    func testAnActionNoticeIsAttachedToItsOwnRow() {
        let s = store()
        let row = liveRow()
        XCTAssertNil(s.rowActionNotice(row))
        s.noteRowAction(row.rowKey, s.tr(.focusFailed))
        XCTAssertEqual(s.rowActionNotice(row), s.tr(.focusFailed))

        var other = liveRow()
        other.rowKey = "codex|s2"
        XCTAssertNil(s.rowActionNotice(other), "a notice belongs to the row that was clicked")
    }

    @MainActor
    func testEveryFailureSentenceIsRealCopyInBothLanguages() {
        // These only ever appear when something went wrong, which is exactly
        // when an untranslated or empty string would be found by a user
        // rather than by us.
        for key in [L10n.Key.focusFailed] {
            XCTAssertFalse(L10n.t(key, .en).isEmpty, "\(key)")
            XCTAssertFalse(L10n.t(key, .zh).isEmpty, "\(key)")
            XCTAssertNotEqual(L10n.t(key, .en), L10n.t(key, .zh), "\(key)")
        }
    }
}

import Foundation
import AppKit
import Testing
import XCTest
@testable import PulseApp
@testable import PulseQA
@testable import PulseKit

// Tray: the row face, header, keys, order, lamp, detail page and copy.

// What a row says is pinned in `RowWordsTests` (below); the focus-honesty
// rule is here.

/// A folder that cannot be a workspace is never opened as one: the editor
/// drops to app precision.
final class BestEffortWorkspaceTests: XCTestCase {
    func testOnlyAnAbsoluteWorkspaceIsOpened() {
        let handle = LandingHandle(term: "vscode")
        let opened = LandingPlan.make(handle: handle, cwd: "/Users/me/my-project")
        XCTAssertEqual(opened.steps.first, LandingStep.openFolder(bundleIDs: HostAppKind.vsCode.bundleIDs, path: "/Users/me/my-project"))
        for cwd in ["", "relative/path", "/", "/tmp", "/private/tmp"] {
            let plan = LandingPlan.make(handle: handle, cwd: cwd)
            XCTAssertEqual(plan.steps, [.activateApp(bundleIDs: HostAppKind.vsCode.bundleIDs)], "\(cwd) is not a workspace")
        }
    }
}

/// The tray as values: the keyboard reducer, the frozen order, the header,
/// the one notice, the row's second line and where a banner click goes.
@Suite("Tray interaction")
struct TrayInteractionTests {
    let now: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private func session(_ key: SessionKey) -> AgentRow {
        var row = AgentRow(key: key, status: .running(stalled: false))
        row.session = key.description
        row.task = "Fix the login test"
        row.cwd = "/Users/me/app"
        row.liveProcess = true
        return row
    }

    /// What a running session said a minute ago.
    private var facts: SessionFacts { SessionFacts(lastEventMs: now - minute) }

    private func blocked(_ key: SessionKey, ask: String = "Bash: npm test") -> AgentRow {
        var row = session(key)
        row.status = .needsYou(Block(kind: .permission, ask: ask, sinceMs: now - 4 * minute))
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
        let state = TrayKeys.State(selected: "a", detail: nil)
        let outcome = press(state, [.enter])
        #expect(outcome.effect == .focus("a"))
        #expect(outcome.state.detail == nil)
    }

    @Test func returnOpensTheDetailWhenThereIsNoHandle() {
        let state = TrayKeys.State(selected: "b", detail: nil)
        let outcome = press(state, [.enter])
        #expect(outcome.effect == nil)
        #expect(outcome.state.detail == "b")
    }

    @Test func rightAndSpaceOpenTheDetail() {
        let state = TrayKeys.State(selected: "c", detail: nil)
        let right = press(state, [.right])
        #expect(right.state.detail == "c")
        let space = press(state, [.space])
        #expect(space.state.detail == "c")
    }

    // MARK: - Keys: the detail page

    @Test func leftAndEscapeLeaveTheDetailAndKeepTheSelection() {
        let open = TrayKeys.State(selected: nil, detail: "b")
        let left = press(open, [.left])
        #expect(left.state.detail == nil)
        #expect(left.state.selected == "b")
        let escape = press(open, [.escape])
        #expect(escape.state.detail == nil)
        #expect(escape.effect == nil, "Esc in the detail goes back; it does not close the panel")
        #expect(escape.handled)
    }

    @Test func theDetailPageTakesCommandDAndReturn() {
        let open = TrayKeys.State(selected: "a", detail: "a")
        let dismiss = press(open, [.dismiss])
        #expect(dismiss.effect == .dismiss("a"))
        let go = press(open, [.enter])
        #expect(go.effect == .focus("a"))
    }

    @Test func dismissOnADetailThatIsNotAWaitDoesNothing() {
        let open = TrayKeys.State(selected: "b", detail: "b")
        let outcome = press(open, [.dismiss])
        #expect(outcome.effect == nil)
    }

    // MARK: - Keys: the list

    @Test func escapeOnTheListClosesTheTray() {
        let outcome = press(TrayKeys.State(selected: "a", detail: nil), [.escape])
        #expect(outcome.effect == .closeTray)
        let empty = press(TrayKeys.State(), [.escape], rows: [])
        #expect(empty.effect == .closeTray, "Esc works on an empty list too")
        let down = press(TrayKeys.State(), [.down], rows: [])
        #expect(down.state.selected == nil)
    }

    @Test func commandDActsOnTheSelectedRow() {
        let onWait = TrayKeys.State(selected: "a", detail: nil)
        let dismiss = press(onWait, [.dismiss])
        #expect(dismiss.effect == .dismiss("a"))

        let onRunning = TrayKeys.State(selected: "b", detail: nil)
        let notAWait = press(onRunning, [.dismiss])
        #expect(notAWait.effect == nil, "⌘D is not an ignore on a row that is not waiting")

        let nothingSelected = press(TrayKeys.State(), [.dismiss])
        #expect(nothingSelected.effect == nil)
    }

    @Test func commandKeysWorkEverywhere() {
        let detail = TrayKeys.State(selected: nil, detail: "a")
        let refresh = press(detail, [.refresh])
        #expect(refresh.effect == .refresh)
        let settings = press(TrayKeys.State(), [.settings])
        #expect(settings.effect == .openSettings)
        let quit = press(detail, [.quit])
        #expect(quit.effect == .quit)
    }

    /// ⌘W is the tray's: it closes the panel as Esc does on the list —
    /// left to the system it would reach `performClose:` on the borderless
    /// panel and beep.
    @Test func commandWClosesTheTray() {
        let event = TrayKeys.key(keyCode: 13, characters: "w", command: true)
        #expect(event == .close)
        let bareW = TrayKeys.key(keyCode: 13, characters: "w", command: false)
        #expect(bareW == nil, "a bare W is not the tray's")
        let list = press(TrayKeys.State(selected: "a", detail: nil), [.close])
        let escape = press(TrayKeys.State(selected: "a", detail: nil), [.escape])
        #expect(list.effect == .closeTray)
        #expect(list == escape, "on the list ⌘W is Esc")
        let empty = press(TrayKeys.State(), [.close], rows: [])
        #expect(empty.effect == .closeTray)
        let detail = press(TrayKeys.State(selected: "b", detail: "b"), [.close])
        #expect(detail.effect == .closeTray, "⌘W closes the tray from the detail page too")
        #expect(detail.handled)
    }

    @Test func aSelectionWhoseRowLeftMovesToTheFirstRow() {
        let gone = TrayKeys.State(selected: "zz", detail: nil)
        let moved = TrayKeys.normalize(gone, rows: rows)
        #expect(moved.selected == "a", "a selection whose row left moves to the first row")
        let none = TrayKeys.normalize(TrayKeys.State(), rows: rows)
        #expect(none.selected == nil, "no selection: nothing is invented")
    }

    /// A bare letter is not the tray's: the tray opens with a row selected,
    /// and a bare D must never ignore a wait.
    @Test func eventsBecomeKeys() {
        let esc = TrayKeys.key(keyCode: 53, characters: "\u{1b}", command: false)
        #expect(esc == .escape)
        let refresh = TrayKeys.key(keyCode: 15, characters: "r", command: true)
        #expect(refresh == .refresh)
        let copy = TrayKeys.key(keyCode: 8, characters: "c", command: true)
        #expect(copy == nil, "⌘C stays the system's")
        let dismiss = TrayKeys.key(keyCode: 2, characters: "d", command: true)
        #expect(dismiss == .dismiss)
        let dismissByDelete = TrayKeys.key(keyCode: 51, characters: "\u{7f}", command: true)
        #expect(dismissByDelete == .dismiss)
        let commandM = TrayKeys.key(keyCode: 46, characters: "m", command: true)
        #expect(commandM == nil, "⌘M is not the tray's")
        let bareD = TrayKeys.key(keyCode: 2, characters: "d", command: false)
        #expect(bareD == nil, "a bare D is never a dismiss")
        let backspace = TrayKeys.key(keyCode: 51, characters: "\u{7f}", command: false)
        #expect(backspace == nil)
        let space = TrayKeys.key(keyCode: 49, characters: " ", command: false)
        #expect(space == .space)
    }

    // MARK: - The frozen order

    @Test func theOrderHoldsWhileTheTrayIsOpen() {
        let a = session("a"), b = session("b"), c = session("c")
        let frozen: [SessionKey] = ["a", "b", "c"]
        // The builder now wants c first (it became blocked): the open tray
        // keeps the order it opened with.
        let arranged = TrayOrder.arrange([c, a, b], frozen: frozen)
        let keys = arranged.map { $0.key }
        #expect(keys == ["a", "b", "c"])
    }

    @Test func newcomersAppendAndLeaversDisappear() {
        let a = session("a"), c = session("c"), d = session("d"), e = session("e")
        let arranged = TrayOrder.arrange([e, c, d, a], frozen: ["a", "b", "c"])
        let keys = arranged.map { $0.key }
        #expect(keys == ["a", "c", "e", "d"], "b left; e and d came, in the order they came")
        let extended = TrayOrder.extend(["a", "b", "c"], with: [e, c, d, a])
        #expect(extended == ["a", "b", "c", "e", "d"])
        let again = TrayOrder.arrange([d, e, a, c], frozen: extended)
        let stable = again.map { $0.key }
        #expect(stable == ["a", "c", "e", "d"], "a newcomer keeps the place it was given")
    }

    /// A new wait sorting to the top while the tray is open is appended:
    /// it never pushes a row — possibly the one under the pointer — out of
    /// its place.
    @Test func aNewWaitWhileOpenIsAppendedAndPushesNothingOut() {
        let shown = (0..<12).map { session(SessionKey(.claude, "r\($0)")) }
        let frozen = shown.map { $0.key }
        let wait = blocked("new-wait")
        // The projection now puts the wait first.
        let all = [wait] + shown
        let listed = TrayOrder.openList(all: all, pinned: Set(frozen), frozen: frozen)
        let keys = listed.map { $0.key }
        #expect(keys == frozen + ["new-wait"], "every row shown stays, in place; the wait is appended")
    }

    @Test func theOpenListDropsRowsThatLeftAndAppendsNewcomers() {
        let a = session("a"), b = session("b"), c = session("c"), d = session("d"), e = session("e")
        let listed = TrayOrder.openList(all: [c, a, d], pinned: ["a", "b", "c"], frozen: ["a", "b", "c"])
        let keys = listed.map { $0.key }
        #expect(keys == ["a", "c", "d"], "b left the scan; d is new")
        let many = TrayOrder.openList(all: [e, d, a, b, c], pinned: ["a", "b", "c"], frozen: ["a", "b", "c", "e", "d"])
        let manyKeys = many.map { $0.key }
        #expect(manyKeys == ["a", "b", "c", "e", "d"], "no cap: every newcomer is listed, after the rows already shown")
        let fresh = TrayOrder.openList(all: [a, b], pinned: [], frozen: [])
        let freshKeys = fresh.map { $0.key }
        #expect(freshKeys == ["a", "b"], "nothing pinned: the projection's order")
    }

    // MARK: - The header

    @Test func theHeaderCountsWhatMattersInTone() {
        var stalled = session("s")
        stalled.status = .running(stalled: true)
        var turn = session("t")
        turn.status = .yourTurn(sinceMs: now - minute)
        let model = TrayHeaderModel.make(counts: TrayState.Counts(rows: [blocked("w1"), blocked("w2"), session("r"), stalled, turn]), lang: .en)
        let labels = model.counts.map { "\($0.count) \($0.label)" }
        #expect(labels == ["2 need you", "1 running", "1 stalled", "1 your turn"])
        let tones = model.counts.map { $0.tone }
        #expect(tones == [Lamp.waiting, .running, .stalled, .idle])
    }

    @Test func oneWaitIsSingular() {
        let model = TrayHeaderModel.make(counts: TrayState.Counts(rows: [blocked("w")]), lang: .en)
        let labels = model.counts.map { $0.label }
        #expect(labels == [L10n.t(.waiting1, .en)])
    }

    @Test func anEmptyHeaderSaysWhatIsTrue() {
        let none = TrayHeaderModel.make(counts: TrayState.Counts(rows: []), lang: .en)
        #expect(none.counts.isEmpty)
        #expect(none.title == L10n.t(.noAgents, .en))
        var process = AgentRow(key: .process(.codex, pid: 1))
        process.status = .processOnly
        let grey = TrayHeaderModel.make(counts: TrayState.Counts(rows: [process]), lang: .zh)
        #expect(grey.title == "1 " + L10n.t(.processOnlyN, .zh))
    }

    // MARK: - The one notice

    private func notice(
        authorized: Bool? = true, banner: Bool = false,
        unconnected: [AgentID] = [], failure: String = "", connected: [AgentID]? = nil
    ) -> TrayNoticeModel? {
        TrayNoticeModel.pick(TrayNoticeModel.Input(
            lang: .en, notifyAuthorized: authorized,
            bannerFailed: banner, unconnected: unconnected, installFailure: failure, justConnected: connected
        ))
    }

    @Test func atMostOneNoticeInItsOrder() {
        let all = notice(authorized: false, banner: true, unconnected: [.claude])
        #expect(all?.kind == .setup, "connecting comes before notifications")
        #expect(all?.action == .connect)
        let followUp = notice(authorized: false, unconnected: [.opencode], connected: [.claude])
        #expect(followUp?.kind == .setupDone)
        #expect(followUp?.action == .dismissSetup)
        let denied = notice(authorized: false, banner: true)
        #expect(denied?.kind == .notificationsDenied)
        #expect(denied?.action == .openNotificationSettings)
        let notAsked = notice(authorized: nil)
        #expect(notAsked?.kind == .notificationsOff)
        #expect(notAsked?.action == .enableNotifications)
        let failed = notice(authorized: false, failure: "OpenCode: broken")
        #expect(failed?.kind == .setupFailed, "a failed install comes before notifications")
        #expect(failed?.action == .openHooksSettings)
        #expect(failed?.text == "OpenCode: broken")
        let unconnectedFirst = notice(unconnected: [.claude], failure: "OpenCode: broken")
        #expect(unconnectedFirst?.kind == .setup, "agents that can still connect are offered first")
        let banner = notice(banner: true)
        #expect(banner?.kind == .bannerFailed)
        #expect(notice() == nil)
    }

    @Test func theSetupCardNamesTheAgentsAndItsRemainingSteps() {
        let card = notice(unconnected: [.claude, .codex])
        #expect(card?.text == String(format: L10n.t(.setupFound, .en), "Claude, Codex"))
        #expect(card?.steps.isEmpty == true)
        let codex = notice(connected: [.claude, .codex])
        #expect(codex?.steps == [L10n.t(.setupStepCodex, .en), L10n.t(.setupStepRestart, .en)])
        let claudeOnly = notice(connected: [.claude])
        #expect(claudeOnly?.steps == [L10n.t(.setupStepRestart, .en)], "the Codex step only when Codex was connected")
    }

    // MARK: - The row's second line

    @Test func onlyABlockedOrOrangeRowHasASecondLine() {
        let said = facts
        let face = { (row: AgentRow) in TrayRowModel.make(TrayRowModel.Input(row: row, facts: said, lang: .en, nowMs: now)) }
        let waiting = face(blocked("w", ask: "Allow npm test?"))
        #expect(waiting.secondLine == TrayRowModel.SecondLine(kind: .ask, text: "Allow npm test?"))
        let running = face(session("r"))
        #expect(running.secondLine == nil)
        var stalledRow = session("s")
        stalledRow.status = .running(stalled: true)
        let stalled = face(stalledRow)
        #expect(stalled.secondLine?.kind == .warning)
        var failingRow = session("f")
        failingRow.status = .recent(.atPrompt)
        let failing = TrayRowModel.make(TrayRowModel.Input(row: failingRow, facts: SessionFacts(lastError: "npm ERR!"), lang: .en, nowMs: now))
        #expect(failing.secondLine == nil, "an error is a detail-page fact, not an orange row")
        var turnRow = session("t")
        turnRow.status = .yourTurn(sinceMs: now)
        let turn = face(turnRow)
        #expect(turn.secondLine == nil)
        #expect(turn.turnLabel == L10n.t(.yourTurn, .en))
    }

    @Test func aWaitingRowShowsOnlyTheWaitAge() {
        let model = TrayRowModel.make(TrayRowModel.Input(row: blocked("w"), facts: facts, lang: .en, nowMs: now))
        #expect(model.age == "4m")
        let running = TrayRowModel.make(TrayRowModel.Input(row: session("r"), facts: facts, lang: .en, nowMs: now))
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
        let firstBlocked = store.rows.first { $0.isBlocked }
        let row = try #require(firstBlocked)
        _ = store.takePendingReveal()
        store.focusAgent(idRaw: row.agent.rawValue, session: row.session, rowKey: row.key.description)
        let reveal = store.takePendingReveal()
        #expect(reveal?.key == row.key)
        #expect(reveal?.detail == true)
        let again = store.takePendingReveal()
        #expect(again == nil, "a reveal is taken once")
    }

    @MainActor
    @Test func aRevealForARowThatIsGoneIsDropped() {
        let store = StatusStore()
        store.installPreviewFixture("status-waiting")
        let ui = TrayUI(store: store)
        ui.open()
        store.requestTrayReveal(key: "gone|nowhere", detail: true)
        ui.applyPendingReveal()
        #expect(ui.keys.detail == nil)
        #expect(store.pendingReveal?.key == nil)
    }

    @MainActor
    @Test func aRevealWhileADetailIsOpenIsApplied() throws {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        let ui = TrayUI(store: store)
        ui.open()
        let rows = store.rows
        try #require(rows.count >= 2)
        ui.showDetail(rows[0].key)
        store.requestTrayReveal(key: rows[1].key, detail: true)
        ui.applyPendingReveal()
        #expect(ui.keys.detail == rows[1].key)
        #expect(ui.keys.selected == rows[1].key)
    }

    /// One gesture — a menu-bar click and a reopen (Spotlight, Raycast)
    /// open the same way, on the oldest wait.
    @MainActor
    @Test func everyOpenSelectsTheOldestWait() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        let ui = TrayUI(store: store)
        ui.open()
        let oldest = ui.displayRows.filter(\.isBlocked).min { ($0.wait?.sinceMs ?? 0) < ($1.wait?.sinceMs ?? 0) }
        #expect(oldest != nil)
        #expect(ui.keys.selected == oldest?.key)
    }

    /// A fresh glance selects the first row, so the projection's order is
    /// what makes it the oldest wait: waits first, the oldest first, an
    /// unknown clock last, then the rest.
    @Test func theProjectionListsTheOldestWaitFirst() {
        func blocked(_ key: SessionKey, since: Int64) -> AgentRow {
            AgentRow(key: key, status: .needsYou(Block(kind: .permission, sinceMs: since)))
        }
        let running = AgentRow(key: "codex|run", status: .running(stalled: false))
        let rows = [running, blocked("new", since: 9_000), blocked("unknown", since: 0), blocked("old", since: 1_000)]
        let order = TrayState.assemble(rows: rows, context: .init(nowMs: 10_000)).rows.map(\.key)
        #expect(order == ["old", "new", "unknown", "codex|run"])
        let onlyUnknown = TrayState.assemble(rows: [running, blocked("unknown", since: 0)], context: .init(nowMs: 10_000)).rows.first?.key
        #expect(onlyUnknown == "unknown")
    }

    // MARK: - Clicks and the pointer

    /// A click on the row's body goes; the "›" column opens the detail; an
    /// ⌥-click anywhere opens the detail.
    @Test func aClickGoesTheChevronAndAnOptionClickOpenTheDetail() {
        let body = TrayRowModel.clickAction(zone: .body, option: false)
        #expect(body == .primary)
        let chevron = TrayRowModel.clickAction(zone: .chevron, option: false)
        #expect(chevron == .details)
        let optionBody = TrayRowModel.clickAction(zone: .body, option: true)
        #expect(optionBody == .details, "⌥-click on the body is Details, not Go")
        let optionChevron = TrayRowModel.clickAction(zone: .chevron, option: true)
        #expect(optionChevron == .details)
    }

    /// Go on a row with no landing plan opens its detail — the click always
    /// reaches something real.
    @MainActor
    @Test func goWithoutAHandleOpensTheDetail() {
        let store = StatusStore()
        let row = session("no-handle")
        store.rows = [row]
        let ui = TrayUI(store: store)
        #expect(!row.canFocusTerminal)
        ui.send(TrayRowModel.Action.primary, row: row)
        #expect(ui.keys.detail == "no-handle")
    }

    /// The pointer entering a row selects it — one highlight; the keyboard
    /// moves the same selection, and only a keyboard move scrolls.
    @MainActor
    @Test func thePointerSelectsTheRowItEnters() throws {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        let ui = TrayUI(store: store)
        ui.open(pointer: CGPoint(x: 10, y: 10))
        let rows = ui.displayRows
        try #require(rows.count >= 2)
        let first = ui.keys.selected
        ui.hover(rows[1].key, at: CGPoint(x: 10, y: 10))
        #expect(ui.keys.selected == first, "the list appeared under a still pointer: nothing moves")
        ui.hover(rows[1].key, at: CGPoint(x: 12, y: 40))
        #expect(ui.keys.selected == rows[1].key)
        #expect(ui.pointerSelection == rows[1].key, "the list does not scroll to a pointer's selection")
        _ = ui.handle(.up)
        #expect(ui.keys.selected == rows[0].key, "the keyboard moves the same selection")
        #expect(ui.pointerSelection == nil)
        ui.hover(rows[1].key, at: CGPoint(x: 12, y: 40))
        #expect(ui.keys.selected == rows[0].key, "rows scrolled under a still pointer do not take the selection")
        ui.showDetail(rows[0].key)
        ui.hover(rows[1].key, at: CGPoint(x: 30, y: 60))
        #expect(ui.keys.selected == rows[0].key, "no row is under the pointer on the detail page")
    }

    /// The keys the row's click model leans on: ↩ goes, → and Space open
    /// the detail, ← and Esc come back from it.
    @Test func theKeysMatchTheClicks() {
        let go = press(TrayKeys.State(selected: "a", detail: nil), [.enter])
        #expect(go.effect == .focus("a"))
        for key in [TrayKeys.Key.right, .space] {
            let details = press(TrayKeys.State(selected: "a", detail: nil), [key])
            #expect(details.state.detail == "a")
        }
        for key in [TrayKeys.Key.left, .escape] {
            let back = press(TrayKeys.State(selected: "a", detail: "a"), [key])
            #expect(back.state.detail == nil)
            #expect(back.state.selected == "a")
        }
    }
}

/// The tray opens on "who needs me", never on the last visit's rummaging.
/// EXPERIENCE §4: "展开状态不持久化". The popover's view is built once, so
/// nothing resets `@State` on its own: every open gives the tray a new
/// identity.
final class TrayGlanceResetTests: XCTestCase {
    @MainActor
    func testEachOpenGivesTheTrayANewIdentity() {
        let store = StatusStore()
        let ui = TrayUI(store: store)
        let atLaunch = ui.generation
        ui.open()
        let firstOpen = ui.generation
        ui.open()
        let secondOpen = ui.generation
        XCTAssertNotEqual(atLaunch, firstOpen)
        XCTAssertNotEqual(firstOpen, secondOpen, "every open discards the previous view state")
        _ = TrayView(store: store, ui: ui)
    }
}

final class StatusLampTests: XCTestCase {
    /// Red, green and orange keep their colour; a grey lamp — idle or
    /// process only — is a template the menu bar colours like its
    /// neighbours.
    func testStatusBarLampsKeepTheirStateColors() {
        for lamp in Lamp.allCases {
            XCTAssertEqual(lamp.statusBarImage.isTemplate, lamp.isGrey, "\(lamp): only grey follows the menu bar")
        }
        XCTAssertTrue(Lamp.processOnly.isGrey)

        let waiting = Lamp.waiting.nsColor.usingColorSpace(.deviceRGB)!
        let running = Lamp.running.nsColor.usingColorSpace(.deviceRGB)!
        let stalled = Lamp.stalled.nsColor.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(waiting.redComponent, waiting.greenComponent)
        XCTAssertGreaterThan(running.greenComponent, running.redComponent)
        XCTAssertGreaterThan(stalled.redComponent, stalled.blueComponent)
        XCTAssertGreaterThan(stalled.greenComponent, stalled.blueComponent)
    }
}

/// VoiceOver must speak the interface language, not English.
final class AccessibilityLocalizationTests: XCTestCase {
    func testGlanceStatesHaveDistinctLocalizedLabels() {
        for lamp in Lamp.allCases {
            let en = L10n.t(lamp.accessibilityKey, .en)
            let zh = L10n.t(lamp.accessibilityKey, .zh)
            XCTAssertFalse(en.isEmpty)
            XCTAssertFalse(zh.isEmpty)
            XCTAssertNotEqual(en, zh, "\(lamp) was not translated")
        }
    }

    func testSnapshotCarriesTheResolvedLabelSoTheViewNeedsNoLanguage() {
        let ctx = TrayState.Context(nowMs: 1_700_000_000_000, lang: .zh)
        let result = TrayState.assemble(rows: [], context: ctx)
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
            for glance in [Lamp.idle, .running, .stalled, .waiting] {
                let icon = glance.statusBarImage
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

                let color = glance.nsColor.usingColorSpace(.deviceRGB) ?? glance.nsColor
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

/// Landing: the handle decides, the plan says how precisely, and the
/// label never promises more than the plan.
@Suite("Landing plan")
struct LandingPlanTests {
    @Test func aTmuxPaneLandsExactlyWithoutAutomation() {
        let handle = LandingHandle("tmux:%3;tmuxsock:/private/tmp/tmux-501/default;iterm:w0t1p0:ABCD;tty:/dev/ttys004;term:tmux;app:com.googlecode.iterm2")
        #expect(handle.tmuxPane == "%3")
        #expect(handle.tmuxSocket == "/private/tmp/tmux-501/default")
        #expect(handle.tty == "ttys004")
        let plan = LandingPlan.make(handle: handle, cwd: "/Users/me/app")
        #expect(plan.steps == [
            .tmuxPane(pane: "%3", socket: "/private/tmp/tmux-501/default", hostBundleIDs: ["com.googlecode.iterm2"]),
            .activateApp(bundleIDs: ["com.googlecode.iterm2"]),
        ], "inside tmux the pane is the handle; the tty and iTerm id are the server's")
        #expect(plan.precision == .exact)
        #expect(LandingPlan.tmuxArguments(pane: "%3", socket: "/s") == [
            "-S", "/s",
            "switch-client", "-t", "%3", ";",
            "select-window", "-t", "%3", ";",
            "select-pane", "-t", "%3", ";",
            "display-message", "-p", "-t", "%3", "#{session_id}",
        ])
        #expect(LandingPlan.tmuxArguments(pane: "%3", socket: "").first == "switch-client")
    }

    @Test func anITermSessionIsSelectedByItsUniqueID() {
        let handle = LandingHandle("iterm:w0t1p0:9F1C-UUID;tty:/dev/ttys007;term:iTerm.app")
        #expect(handle.itermUniqueID == "9F1C-UUID")
        let plan = LandingPlan.make(handle: handle, cwd: "/Users/me/app")
        #expect(plan.steps == [
            .iTermSession(uniqueID: "9F1C-UUID"),
            .ttyTab(tty: "ttys007"),
            .activateApp(bundleIDs: [LandingPlan.iTermBundleID]),
        ])
        #expect(plan.precision == .exact)
    }

    @Test func aTerminalTabIsFoundByItsTTY() {
        let plan = LandingPlan.make(handle: LandingHandle("tty:/dev/ttys001;term:Apple_Terminal"), cwd: "")
        #expect(plan.steps == [.ttyTab(tty: "ttys001"), .activateApp(bundleIDs: [LandingPlan.terminalBundleID])])
        #expect(plan.precision == .exact)
    }

    @Test func ghosttyIsTheAppOnly() {
        let plan = LandingPlan.make(handle: LandingHandle("tty:/dev/ttys002;term:ghostty"), cwd: "/Users/me/app")
        #expect(plan.steps == [.activateApp(bundleIDs: ["com.mitchellh.ghostty"])], "the tab search asks only Terminal and iTerm")
        #expect(plan.precision == .app)
    }

    @Test func anEditorTerminalOpensTheFolderInThatEditor() {
        let vscode = LandingPlan.make(handle: LandingHandle("tty:/dev/ttys005;term:vscode"), cwd: "/Users/me/app", pid: 812)
        #expect(vscode.steps == [
            .openFolder(bundleIDs: HostAppKind.vsCode.bundleIDs, path: "/Users/me/app"),
            .activateApp(bundleIDs: HostAppKind.vsCode.bundleIDs),
            .activateOwner(pid: 812),
        ])
        #expect(vscode.precision == .app)
        let cursor = LandingPlan.make(
            handle: LandingHandle("term:vscode;app:com.todesktop.230313mzl4w4u92"), cwd: "/Users/me/app"
        )
        #expect(cursor.steps.first == LandingStep.openFolder(bundleIDs: HostAppKind.cursor.bundleIDs, path: "/Users/me/app"), "Cursor also says vscode")
    }

    @Test func anEmptyHandleFallsBackToTheProcessOwnerOrNothing() {
        #expect(LandingPlan.make(handle: LandingHandle(""), cwd: "/Users/me/app").isEmpty)
        #expect(LandingPlan.make(handle: LandingHandle(), cwd: "").precision == nil)
        let process = LandingPlan.make(handle: LandingHandle(), cwd: "/Users/me/app", pid: 4312)
        #expect(process.steps == [.activateOwner(pid: 4312)])
        #expect(process.precision == .app)
        let ide = LandingPlan.make(handle: LandingHandle(), cwd: "/Users/me/app", pid: 4312, hostApp: .zed)
        #expect(ide.steps.first == LandingStep.openFolder(bundleIDs: HostAppKind.zed.bundleIDs, path: "/Users/me/app"))
    }

    /// No setting gates the scripted steps: an iTerm session and a bare
    /// tty are always tried, and macOS's own Automation prompt is the
    /// consent. A placeholder tty is no handle.
    @Test func theScriptedStepsAreAlwaysPlanned() {
        let iterm = LandingPlan.make(handle: LandingHandle("iterm:w0t1p0:ABCD;tty:/dev/ttys007;term:iTerm.app"), cwd: "")
        #expect(iterm.steps.first == .iTermSession(uniqueID: "ABCD"))
        #expect(iterm.precision == .exact)
        let terminal = LandingPlan.make(handle: LandingHandle("tty:/dev/ttys001"), cwd: "")
        #expect(terminal.steps == [.ttyTab(tty: "ttys001")], "a bare tty is searched in Terminal and iTerm")
        for placeholder in ["tty:?", "tty:??", "tty:-"] {
            #expect(LandingPlan.make(handle: LandingHandle(placeholder), cwd: "").isEmpty, "\(placeholder)")
        }
    }

    @Test func theLabelFollowsThePrecision() {
        var row = AgentRow(key: "claude|s1")
        #expect(!row.canFocusTerminal)
        row.landingPlan = LandingPlan.make(handle: LandingHandle("term:ghostty"), cwd: "")
        #expect(TrayRowModel.focusTitle(row, lang: .en) == "Open app")
        #expect(TrayRowModel.focusTitle(row, lang: .zh) == "打开应用")
        row.landingPlan = LandingPlan.make(handle: LandingHandle("tmux:%1"), cwd: "")
        #expect(TrayRowModel.focusTitle(row, lang: .en) == "Go to terminal")
        #expect(TrayRowModel.focusTitle(row, lang: .zh) == "前往终端")
        #expect(row.landingPlan.precision == .exact)
        var app = row
        app.landingPlan = LandingPlan(steps: [.activateOwner(pid: 9)])
        #expect(TrayRowModel.focusTitle(app, lang: .en) == "Open app")
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

    /// One term per concept and one punctuation — 设置 (not 偏好设置),
    /// 「」 quotes, an unspaced "——"; no developer path or "unsigned" in
    /// what a person reads.
    func testTheCopyIsConsistent() {
        for key in L10n.Key.allCases {
            let zh = L10n.t(key, .zh)
            let en = L10n.t(key, .en)
            XCTAssertFalse(zh.contains("偏好设置"), "\(key): \(zh)")
            XCTAssertFalse(zh.contains("“") || zh.contains("”"), "\(key): \(zh)")
            XCTAssertFalse(zh.contains(" ——") || zh.contains("—— "), "\(key): \(zh)")
            XCTAssertFalse(en.contains("package.sh") || zh.contains("package.sh"), "\(key)")
            XCTAssertFalse(en.localizedCaseInsensitiveContains("unsigned"), "\(key): \(en)")
        }
        XCTAssertEqual(L10n.t(.ignoreWait, .en), "Ignore")
        XCTAssertEqual(L10n.t(.ignoreWait, .zh), "忽略")
        XCTAssertEqual(L10n.t(.settings, .zh), "设置…")
    }

    /// US spelling in English ("Gray"), and no space between a Chinese
    /// word and a placeholder that may itself be Chinese ("上一步：刚刚").
    func testSpellingAndChineseSpacing() {
        for key in L10n.Key.allCases {
            XCTAssertFalse(L10n.t(key, .en).contains("Grey"), "\(key)")
            XCTAssertFalse(L10n.t(key, .zh).contains("上一步 %@"), "\(key)")
        }
        XCTAssertTrue(L10n.t(.lampRuleIdle, .en).hasPrefix("Gray:"))
    }
}

/// Every user-facing string goes through the table.
final class LocalizedCopyTests: XCTestCase {
    /// One table for the tooltip, the chip and the banner.
    func testWaitKindTranslationIsSharedWithTheBuilder() {
        XCTAssertEqual(L10n.waitKind(.permission, .zh), L10n.t(.kindPermission, .zh))
        XCTAssertEqual(L10n.waitKind(.question, .zh), L10n.t(.kindInput, .zh))
        XCTAssertEqual(L10n.waitKind(.waiting, .zh), L10n.t(.kindWaiting, .zh))
    }
}

/// Durations are `DateComponentsFormatter`'s, in the interface's language:
/// one unit, rounded down, abbreviated where drawn and in full where
/// spoken; "now" below a minute — one key, so nothing redraws every tick.
/// ICU's spacing varies, so the checks read through its no-break spaces.
final class DurationTests: XCTestCase {
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testBelowAMinuteIsNowInEitherLanguage() {
        XCTAssertEqual(L10n.duration(2, .en), L10n.t(.now, .en))
        XCTAssertEqual(L10n.duration(59, .zh), "刚刚")
        XCTAssertEqual(L10n.duration(42, .en, spoken: true), "now")
        XCTAssertEqual(L10n.ago(1_000, nowMs: 30_000, .en), "now", "never \"now ago\"")
    }

    func testOneUnitRoundedDown() {
        XCTAssertEqual(plain(L10n.duration(600, .en)), "10m")
        XCTAssertEqual(plain(L10n.duration(659, .en)), "10m")
        XCTAssertEqual(plain(L10n.duration(7200 + 59 * 60, .en)), "2h")
        XCTAssertTrue(L10n.duration(600, .zh).contains("10"))
        XCTAssertTrue(L10n.duration(600, .zh).contains("分"), "zh tray showed English units")
        XCTAssertTrue(L10n.duration(7200, .zh).contains("小时"))
    }

    /// VoiceOver hears whole words: "4 minutes", "1 hour", never "4m".
    func testSpokenDurationsUseFullUnits() {
        XCTAssertEqual(plain(L10n.duration(60, .en, spoken: true)), "1 minute")
        XCTAssertEqual(plain(L10n.duration(240, .en, spoken: true)), "4 minutes")
        XCTAssertEqual(plain(L10n.duration(3600, .en, spoken: true)), "1 hour")
        XCTAssertEqual(plain(L10n.duration(7200, .en, spoken: true)), "2 hours")
        XCTAssertTrue(L10n.duration(240, .zh, spoken: true).contains("分钟"))
    }

    func testAgoWrapsTheDuration() {
        let now: Int64 = 1_700_000_000_000
        XCTAssertEqual(plain(L10n.ago(now - 12 * 60_000, nowMs: now, .en)), "12m ago")
        XCTAssertEqual(L10n.ago(now - 12 * 60_000, nowMs: now, .zh), String(format: L10n.t(.agoFormat, .zh), L10n.duration(12 * 60, .zh)))
    }

    /// A count picks its form — never "session(s)".
    func testNoCopyUsesAPluralHack() {
        for key in L10n.Key.allCases {
            XCTAssertFalse(L10n.t(key, .en).contains("(s)"), "\(key): a plural hack")
        }
    }
}

/// Return Truth — Glance width and Attention compact.
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
        let r = TrayState.assemble(
            rows: [],
            context: TrayState.Context(nowMs: 1_700_000_000_000, lang: .en)
        )
        XCTAssertEqual(r.snapshot.lamp, .idle)
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
        XCTAssertTrue(SessionFacts(lastEventMs: now - 5 * 60 * 1000).selfReportFresh(at: now))
        XCTAssertFalse(SessionFacts(lastEventMs: now - 31 * 60 * 1000).selfReportFresh(at: now), "the headline and the detail page share this gate")
    }

    func testTheLastMessageNeverImpliesWaiting() {
        let row = AgentRow(key: "claude|s1", status: .running(stalled: false))
        let said = SessionFacts(lastWords: "Waiting for your review.", lastEventMs: now)
        let detail = DetailModel.make(row: row, facts: said, lang: .en, nowMs: now)
        XCTAssertEqual(detail.lastMessage, "Waiting for your review.")
        XCTAssertFalse(row.isBlocked, "words never write Waiting")
        XCTAssertFalse(detail.canDismiss)
    }
}

/// Clarity fixes — each test pins one defect found by reading the code: the
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

    @Test func theITermSessionSearchActivatesOnlyOnItsUniqueID() throws {
        let script = TerminalFocus.iTermSessionScript(uniqueID: "9F1C-\"x")
        let match = try #require(script.range(of: "if (unique id of s as text) is \"9F1C-\\\"x\""))
        let activate = try #require(script.range(of: "activate"))
        #expect(activate.lowerBound > match.upperBound)
    }
}

/// The defects a fresh audit turned up.
///
/// Each of these is a place where the code said something it had not
/// measured, dropped work it had been asked to do, or let a click reach
/// nothing without saying so.
final class RowActionNoticeTests: XCTestCase {

    @MainActor
    private func store(_ lang: ResolvedLanguage = .en) -> StatusStore {
        StatusStore(lang: lang)
    }

    private func liveRow() -> AgentRow {
        var row = AgentRow(key: "claude|s1", status: .running(stalled: false))
        row.task = "Fix the auth module"
        row.liveProcess = true
        return row
    }

    // MARK: D-6 / D-7 · a click that reached nothing says so

    @MainActor
    func testAnActionNoticeIsAttachedToItsOwnRow() {
        let s = store()
        let row = liveRow()
        XCTAssertNil(s.rowActionNotices[row.key])
        s.noteRowAction(row.key, RowNotice(text: s.tr(.focusFailed)))
        XCTAssertEqual(s.rowActionNotices[row.key]?.text, s.tr(.focusFailed))

        var other = liveRow()
        other.key = "codex|s2"
        XCTAssertNil(s.rowActionNotices[other.key], "a notice belongs to the row that was clicked")
    }

    @MainActor
    func testEveryFailureSentenceIsRealCopyInBothLanguages() {
        // These only ever appear when something went wrong, which is exactly
        // when an untranslated or empty string would be found by a user
        // rather than by us.
        for key in [L10n.Key.focusFailed, .focusAppOnly, .focusAppOnlyAutomation] {
            XCTAssertFalse(L10n.t(key, .en).isEmpty, "\(key)")
            XCTAssertFalse(L10n.t(key, .zh).isEmpty, "\(key)")
            XCTAssertNotEqual(L10n.t(key, .en), L10n.t(key, .zh), "\(key)")
        }
    }
}

// MARK: - Row words

/// What a row says — the headline and the why — the lamp's one-sentence
/// rule, and the row face and detail page built on them. A row carries its
/// status; what its session said lately (`SessionFacts`) is read beside it.
@Suite("Row words")
struct RowWordsTests {
    let now: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private func session(_ agent: AgentID = .claude, task: String = "Refactor the settings panes") -> AgentRow {
        var row = AgentRow(key: SessionKey(agent, "s1"), status: .running(stalled: false))
        row.session = "s1"
        row.task = task
        row.cwd = "/Users/me/pulse"
        row.liveProcess = true
        return row
    }

    /// What the session said a minute ago.
    private var said: SessionFacts { SessionFacts(lastEventMs: now - minute) }

    private func blocked(kind: AttentionKind = .permission, inFront: Bool = false) -> AgentRow {
        var row = session()
        row.status = .needsYou(Block(kind: kind, ask: "Bash: npm test", sinceMs: now - 4 * minute, inFront: inFront))
        return row
    }

    private func stalled() -> AgentRow {
        var row = session()
        row.status = .running(stalled: true)
        return row
    }

    private func why(_ row: AgentRow, _ lang: ResolvedLanguage = .en, facts: SessionFacts? = nil) -> String {
        TrayRowModel.why(row, facts: facts ?? said, lang: lang, nowMs: now)
    }

    private func face(_ row: AgentRow, _ facts: SessionFacts? = nil, lang: ResolvedLanguage = .en) -> TrayRowModel {
        TrayRowModel.make(TrayRowModel.Input(row: row, facts: facts ?? said, lang: lang, nowMs: now))
    }

    private func headline(_ row: AgentRow, facts: SessionFacts? = nil) -> String {
        TrayRowModel.headline(row, facts: facts ?? said, lang: .en, nowMs: now)
    }

    // MARK: - Why: which evidence, and since when

    @Test func aHookWaitNamesItsEvidenceAndItsAge() {
        let text = why(blocked())
        #expect(!text.contains("Claude"), "the row's icon already says who")
        #expect(text.contains(L10n.t(.explainKindPermission, .en)))
        #expect(text.contains(L10n.ago(now - 4 * minute, nowMs: now, .en)))
        #expect(!text.hasSuffix(L10n.t(.explainAskedFront, .en)))
    }

    @Test func aWaitRaisedInFrontSaysWhyThereWasNoBanner() {
        let text = why(blocked(inFront: true))
        #expect(text.hasSuffix(L10n.t(.explainAskedFront, .en)))
    }

    /// The why is plain words — what was asked, and when.
    @Test func aWaitIsSaidInPlainWords() {
        #expect(why(blocked()) == "Asked permission · 4m ago")
        #expect(why(blocked(), .zh) == "请求权限 · " + L10n.ago(now - 4 * minute, nowMs: now, .zh))
        let process = AgentRow(key: .process(.cursor, pid: 7), status: .processOnly)
        #expect(why(process) == "Started before Pulse — details after its next step")
        #expect(why(process, .zh) == "在 Pulse 之前启动——下一步之后显示详情")
        for lang in [ResolvedLanguage.en, .zh] {
            for key in L10n.Key.allCases where "\(key)".hasPrefix("explain") {
                let text = L10n.t(key, lang).lowercased()
                #expect(!text.contains("hook"), "\(key): \(text)")
            }
        }
    }

    @Test func aQuestionSaysInput() {
        let text = why(blocked(kind: .question))
        #expect(text.hasPrefix(L10n.t(.explainKindInput, .en)))
    }

    @Test func yourTurnSaysHowToClearItWithoutNowAgo() {
        var row = session(.codex)
        row.status = .yourTurn(sinceMs: now - 2_000)
        let text = why(row, .zh)
        #expect(text.hasPrefix(L10n.t(.explainTurn, .zh)))
        #expect(!text.contains("刚刚前"), "never 'just now ago'")
    }

    // MARK: - Why: provenance — the vendor event that said so

    /// Each why cites the vendor event that put the row in its state, and
    /// when: "Asked permission (PermissionRequest) · 4m ago", "Turn ended
    /// (Stop) · 2m ago" — in both languages.
    @Test func theWhyCitesTheCausingEvent() {
        var facts = said
        facts.stateEvent = "PermissionRequest"
        #expect(why(blocked(), facts: facts) == "Asked permission (PermissionRequest) · 4m ago")
        #expect(why(blocked(), .zh, facts: facts) == "请求权限（PermissionRequest） · " + L10n.ago(now - 4 * minute, nowMs: now, .zh))
        var turn = session(.codex)
        turn.status = .yourTurn(sinceMs: now - 2 * minute)
        facts.stateEvent = "Stop"
        #expect(why(turn, facts: facts) == "Turn ended (Stop) · 2m ago")
        #expect(why(turn, .zh, facts: facts) == "回合结束（Stop） · " + L10n.ago(now - 2 * minute, nowMs: now, .zh))
        var running = said
        running.lastEvent = "PostToolUse"
        #expect(why(session(), facts: running) == "Working (PostToolUse) · 1m ago")
        var ended = session()
        ended.liveProcess = false
        ended.status = .recent(.ended(atMs: now - 5 * minute))
        facts.stateEvent = "SessionEnd"
        #expect(why(ended, facts: facts) == "Session ended (SessionEnd) · 5m ago")
        facts.stateEvent = ""
        #expect(why(ended, facts: facts) == "Session ended · 5m ago", "a process exit names no event")
    }

    /// An event column that is not a name — a hand-edited log, a path — is
    /// not repeated in the why.
    @Test func aWhyNeverQuotesWhatIsNotAnEventName() {
        var facts = said
        facts.stateEvent = "/Users/me/secret"
        #expect(why(blocked(), facts: facts) == "Asked permission · 4m ago")
        facts.stateEvent = "hook event with spaces"
        #expect(!why(blocked(), facts: facts).contains("hook"))
    }

    /// The book carries the event into the why: a raise and its echo keep
    /// the first event; a held turn lands with its own.
    @Test func theBookCarriesTheEventIntoTheWhy() {
        var book = SessionBook()
        let key = SessionKey(.claude, "s1")
        book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: now - 4 * minute, message: "Bash: npm test", session: "s1", tool: "Bash", event: "PermissionRequest"), nowMs: now)
        book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: now - 4 * minute + 6_000, message: "Claude needs your permission to use Bash", session: "s1", event: "Notification"), nowMs: now)
        #expect(book.facts(for: key).stateEvent == "PermissionRequest", "the echo keeps the first raise's event")
        book.apply(AttentionRecord(agent: .claude, kind: .turn, ms: now - 4 * minute + 9_000, session: "s1", event: "Stop"), nowMs: now)
        #expect(book.facts(for: key).stateEvent == "PermissionRequest", "held inside the grace")
        book.settleHeldTurns(nowMs: now)
        let facts = book.facts(for: key)
        #expect(facts.stateEvent == "Stop", "the held turn lands with its own event")
        #expect(facts.lastEvent == "Stop")
    }

    @Test func aProcessOnlyRowSaysItIsOnlyAProcess() {
        var row = AgentRow(key: .process(.cursor, pid: 7), status: .processOnly)
        row.liveProcess = true
        #expect(why(row, facts: SessionFacts()) == L10n.t(.explainProcessOnly, .en))
    }

    /// The stall rule is not a setting, so the sentence names the
    /// silence and nothing the person could not have set.
    @Test func aStalledRowNamesTheSilence() {
        let quiet = L10n.duration(23 * 60, .en)
        let expected = String(format: L10n.t(.explainStalled, .en), quiet)
        #expect(why(stalled(), facts: SessionFacts(lastEventMs: now - 23 * minute)) == expected)
    }

    /// A stalled row's why names its last step: "Nothing new for 23m — last
    /// step: Bash · swift test".
    @Test func aStalledRowNamesItsLastStep() {
        let row = stalled()
        let facts = SessionFacts(
            steps: [SessionBook.Step(tool: "Bash", target: "swift test", ms: now - 23 * minute)],
            lastEventMs: now - 23 * minute
        )
        #expect(why(row, facts: facts) == "Nothing new for 23m — last step: Bash · swift test")
        #expect(why(row, .zh, facts: facts) == String(format: L10n.t(.stepStalled, .zh), L10n.duration(23 * 60, .zh), "Bash · swift test"))
        #expect(face(row, facts).secondLine == TrayRowModel.SecondLine(kind: .warning, text: why(row, facts: facts)))
    }

    /// A running row's quiet second line is its last step, worded as a
    /// past step; its time slot is this turn's duration.
    @Test func aRunningRowShowsItsLastStepAndItsTurn() {
        let row = session()
        var facts = SessionFacts(
            steps: [SessionBook.Step(tool: "Bash", target: "swift test", ms: now - 12 * minute)],
            turnStartMs: now - 14 * minute,
            lastEventMs: now - minute
        )
        let en = face(row, facts)
        #expect(en.secondLine == TrayRowModel.SecondLine(kind: .step, text: "Bash · swift test · 12m ago"))
        #expect(en.age == "14m")
        #expect(en.accessibilityLabel.contains("Bash · swift test"))
        let zh = face(row, facts, lang: .zh)
        #expect(zh.secondLine?.text == "Bash · swift test · " + L10n.ago(now - 12 * minute, nowMs: now, .zh))
        #expect(zh.age == L10n.duration(14 * 60, .zh))
        // Under a minute the turn and the step both say "now".
        facts.turnStartMs = now - 20_000
        facts.steps = [SessionBook.Step(tool: "Read", target: "", ms: now - 10_000)]
        let young = face(row, facts)
        #expect(young.age == "now")
        #expect(young.secondLine?.text == "Read · now")
    }

    /// No step, no second line: a Cursor or OpenCode row stays one line,
    /// and a row whose turn start is unknown shows when it last moved.
    @Test func aRowWithoutStepsStaysOneLine() {
        let model = face(session(.cursor))
        #expect(model.secondLine == nil)
        #expect(model.age == String(format: L10n.t(.agoFormat, .en), "1m"))
    }

    /// Step words say what was reported, never that it is still going.
    @Test func noStepWordingSaysRunning() {
        let row = stalled()
        let step = SessionBook.Step(tool: "Edit", target: "a.swift", ms: now - 30 * minute)
        let facts = SessionFacts(steps: [step], turnStartMs: now - 40 * minute, lastEventMs: now - 30 * minute)
        for lang in [ResolvedLanguage.en, .zh] {
            var texts = [why(row, lang, facts: facts), TrayRowModel.stepLine(step, nowMs: now, lang: lang)]
            texts += [L10n.t(.stepStalled, lang), L10n.t(.timelineHeading, lang), L10n.t(.stepThisTurn, lang)]
            let timeline = SurfaceFixtures.detailTimeline(lang: lang).timeline
            texts += timeline.flatMap { [$0.time, $0.effect] }
            for text in texts {
                #expect(!text.lowercased().contains("running"), "\(text)")
                #expect(!text.contains("正在"), "\(text)")
            }
        }
    }

    /// The detail page's timeline: what was heard, newest first — the
    /// event, what it did (steps among it) — rebuilt by the replay, and this
    /// turn's duration as a fact.
    @Test func theDetailShowsTheTimelineAndThisTurn() {
        let detail = SurfaceFixtures.detailTimeline(lang: .en)
        let lines = detail.timeline.map { "\($0.event) \($0.effect)" }
        #expect(lines == [
            "PostToolUse Bash · swift test",
            "PostToolUse Edit · Sources/Upload/Backoff.swift",
            "PreCompact Ignored — not an installed event",
            "PostToolUse Answered",
            "Notification Same ask again",
            "PermissionRequest Raised · Permission",
            "PostToolUse Edit · Sources/Upload/Queue.swift",
            "PostToolUse Read · Sources/Upload/Queue.swift",
            "UserPromptSubmit Prompt",
        ])
        #expect(detail.timeline.first?.time == "2m ago")
        let alerts = detail.timeline.filter { $0.tone == .alert }.count
        #expect(alerts == 1, "only the raise is red")
        let turn = detail.facts.first { $0.label == L10n.t(.stepThisTurn, .en) }
        #expect(turn?.value == "14m")
        let zh = SurfaceFixtures.detailTimeline(lang: .zh)
        let zhEffects = zh.timeline.map { $0.effect }
        let raised = "变红 · " + L10n.waitKind(.permission, .zh)
        #expect(zhEffects.contains(raised))
        let zhEvents = zh.timeline.map { $0.event }
        let enEvents = detail.timeline.map { $0.event }
        #expect(zhEvents == enEvents, "event names are the vendor's, in any language")
    }

    @Test func aStalledRowWithNoClockSaysSoRatherThanGuess() {
        #expect(why(stalled(), facts: SessionFacts()) == L10n.t(.explainStalledUnknown, .en))
    }

    @Test func aRunningRowSaysItIsWorking() {
        let text = why(session())
        #expect(text.hasPrefix("Working"), "\(text)")
        #expect(why(session(), facts: SessionFacts()) == L10n.t(.explainRunningNoClock, .en))
    }

    /// Orange is only a stall — a turn's error is a fact in the detail page,
    /// not a lamp.
    @Test func anErrorIsNotAnOrangeLamp() {
        let model = face(session(), SessionFacts(lastError: "npm ERR! missing script: test", lastEventMs: now - minute))
        #expect(model.lamp == .running)
    }

    /// A recent row says which rule made it recent.
    @Test func aRecentRowSaysWhichRuleMadeItRecent() {
        var row = session()
        row.liveProcess = false
        row.status = .recent(.ended(atMs: now - 5 * minute))
        #expect(why(row).hasPrefix("Session ended"))
        row.status = .recent(.atPrompt)
        #expect(why(row).hasPrefix("At its prompt"))
        row.status = .recent(.quiet)
        #expect(why(row).contains("no process to watch"))
        row.status = .recent(.silent)
        #expect(why(row).hasPrefix("Nothing heard for"))
    }

    @Test func theSameRowAndInstantAlwaysSayTheSameThing() {
        let input = TrayRowModel.Input(row: blocked(), facts: said, lang: .en, nowMs: now)
        let first = TrayRowModel.make(input)
        let second = TrayRowModel.make(input)
        #expect(first == second)
    }

    @Test func thePinnedClockIsTheOneTheSentenceMeasuresFrom() {
        let row = blocked()
        let early = TrayRowModel.why(row, facts: said, lang: .en, nowMs: now)
        let later = TrayRowModel.why(row, facts: said, lang: .en, nowMs: now + 60 * minute)
        #expect(early != later)
    }

    @Test func languageIsAnInput() {
        let row = blocked()
        #expect(why(row, .en) != why(row, .zh))
    }

    // MARK: - Headline: the tray hero

    @Test func theTaskLeadsEvenWhenWordsAreFresh() {
        let facts = SessionFacts(lastWords: "All tests pass.", lastEventMs: now - minute)
        #expect(headline(session(), facts: facts) == "Refactor the settings panes")
    }

    @Test func freshWordsLeadOnlyWithoutATask() {
        let row = session(task: "")
        #expect(headline(row, facts: SessionFacts(lastWords: "All tests pass.", lastEventMs: now - minute)) == "All tests pass.")
        #expect(headline(row, facts: SessionFacts(lastWords: "All tests pass.", lastEventMs: now - 45 * minute)) == "pulse", "stale words fall back to the project")
    }

    @Test func aSessionWithNothingToSayNamesItsHandle() {
        var row = session(task: "")
        row.cwd = ""
        #expect(headline(row) == L10n.t(.appSession, .en))
        row.landingPlan = LandingPlan(steps: [.ttyTab(tty: "ttys003")])
        #expect(headline(row) == L10n.t(.terminalSession, .en))
    }

    @Test func aWaitLeadsWithWhatThePersonMustRecognise() {
        var row = blocked()
        let words = SessionFacts(lastWords: "Fresh words never displace the question.", lastEventMs: now - minute)
        #expect(headline(row, facts: words) == "Refactor the settings panes")
        row.task = ""
        #expect(headline(row, facts: words) == "pulse")
        row.cwd = ""
        #expect(headline(row, facts: words) == L10n.t(.needsYou, .en))
    }

    @Test func aProcessOnlyRowSaysWhatLittleIsTrue() {
        var row = AgentRow(key: .process(.codex, pid: 9), status: .processOnly)
        row.task = "never shown"
        #expect(headline(row) == L10n.t(.appDetectedNoDetails, .en))
        row.landingPlan = LandingPlan(steps: [.ttyTab(tty: "ttys003")])
        #expect(headline(row) == L10n.t(.terminalDetectedNoDetails, .en))
    }

    @Test func aBlockedRowCarriesItsAsk() {
        let row = blocked()
        #expect(TrayRowModel.ask(row) == "Bash: npm test")
        #expect(TrayRowModel.stateText(row, lang: .en) == L10n.t(.needsYou, .en), "one word per concept")
    }

    // MARK: - The lamp explanation

    @Test func aRedLampSaysOneLine() {
        var other = session(.codex)
        other.key = "codex|b"
        let rule = TrayState.lampRule(counts: TrayState.Counts(rows: [blocked(), other]))
        #expect(rule == .blocked)
        let sentence = TrayState.lampSentence(rule, lang: .en)
        #expect(sentence == L10n.t(.lampRuleBlocked, .en))
        #expect(!sentence.contains("\n"))
    }

    @Test func aProcessOnlySessionIsAGreyRuleNotAnOrangeOne() {
        var process = AgentRow(key: .process(.cursor, pid: 3), status: .processOnly)
        process.liveProcess = true
        let rule = TrayState.lampRule(counts: TrayState.Counts(rows: [process]))
        #expect(rule == .processOnly)
        #expect(TrayState.lampSentence(rule, lang: .zh) == L10n.t(.lampRuleProcessOnly, .zh))
    }

    @Test func aStalledLampNamesNoThreshold() {
        let rule = TrayState.lampRule(counts: TrayState.Counts(rows: [stalled()]))
        #expect(rule == .stalled)
        let sentence = TrayState.lampSentence(rule, lang: .en)
        #expect(!sentence.contains("20"))
    }

    @Test func aGreyLampWithATurnSaysWhoseTurn() {
        var turn = session(.codex)
        turn.status = .yourTurn(sinceMs: now - minute)
        let process = AgentRow(key: .process(.codex, pid: 4), status: .processOnly)
        let rule = TrayState.lampRule(counts: TrayState.Counts(rows: [process, turn]))
        #expect(rule == .yourTurn, "a finished turn outranks a bare process")
    }

    // MARK: - The lamp's shape and tone, per state

    @Test func everyStateHasItsShapeAndTone() {
        typealias Status = AgentRow.Status
        #expect(Lamp(Status.needsYou(Block(kind: .permission))) == .waiting)
        #expect(Lamp(Status.running(stalled: false)) == .running)
        #expect(Lamp(Status.running(stalled: true)) == .stalled)
        #expect(Lamp(Status.yourTurn(sinceMs: now)) == .idle)
        #expect(Lamp(Status.recent(.atPrompt)) == .idle)
        #expect(Lamp(Status.processOnly) == .processOnly, "a process is never orange")
    }

    /// The menu bar draws the lamp of the rule that set it: the same five
    /// lamps as the rows.
    @Test func theMenuBarLampUsesTheSameShapes() {
        #expect(Lamp(TrayState.LampRule.blocked) == .waiting)
        #expect(Lamp(TrayState.LampRule.running) == .running)
        #expect(Lamp(TrayState.LampRule.stalled) == .stalled)
        #expect(Lamp(TrayState.LampRule.yourTurn) == .idle)
        #expect(Lamp(TrayState.LampRule.recent) == .idle)
        #expect(Lamp(TrayState.LampRule.idle) == .idle)
        #expect(Lamp(TrayState.LampRule.processOnly) == .processOnly)
    }

    // MARK: - The row face

    @Test func aPermissionRowShowsItsAskOnce() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowPermission(), lang: .en)
        #expect(model.lamp == .waiting)
        #expect(model.secondLine == TrayRowModel.SecondLine(kind: .ask, text: "Bash: npm run build"))
        let menu = model.menu.map { $0.action }
        #expect(menu == [.focus, .details, .dismiss], "every verb is in the menu once")
        let ignore = model.menu.first { $0.action == .dismiss }?.title
        #expect(ignore == "Ignore", "one word for setting a wait aside: the tray, the detail and the banner")
        // The only time on a waiting row is how long it has waited.
        let waited = TrayRowModel.rowTime(SurfaceFixtures.rowPermission().row, nowMs: SurfaceFixtures.nowMs, lang: .en)
        #expect(model.age == waited)
    }

    /// The context menu teaches the keys: each item carries the tray key
    /// that does the same — the tray has no key legend of its own.
    @Test func theContextMenuShowsEachItemsKey() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowPermission(), lang: .en)
        let keys: [TrayKeys.Key?] = model.menu.map { $0.key }
        let expected: [TrayKeys.Key?] = [.enter, .right, .dismiss]
        #expect(keys == expected)
    }

    @Test func yourTurnIsQuietAndSaysSo() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowTurn(), lang: .zh)
        #expect(model.lamp == .idle)
        #expect(model.turnLabel == "轮到你")
        #expect(model.secondLine == nil)
        #expect(model.accessibilityLabel.contains("轮到你"))
    }

    @Test func aProcessOnlyRowIsQuietGrey() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowProcessOnly(), lang: .en)
        #expect(model.lamp == .processOnly)
        #expect(model.secondLine == nil, "grey is not a warning")
        let actions = model.menu.map { $0.action }
        #expect(actions == [.details], "details only; nothing to ignore, nowhere to go")
        #expect(!model.canFocus)
    }

    @Test func theProjectIsNotRepeatedWhenItIsTheHeadline() {
        var sample = SurfaceFixtures.rowPermission()
        sample.row.task = ""
        let model = SurfaceFixtures.rowModel(sample, lang: .en)
        #expect(model.headline == "app")
        #expect(model.project == "")
    }

    @Test func aWaitWithoutWordsNamesItsKind() {
        var sample = SurfaceFixtures.rowPermission()
        sample.row.status = .needsYou(Block(kind: .permission, sinceMs: SurfaceFixtures.nowMs - 2 * 60_000))
        let model = SurfaceFixtures.rowModel(sample, lang: .en)
        #expect(model.secondLine == TrayRowModel.SecondLine(kind: .ask, text: L10n.waitKind(.permission, .en)))
    }

    @Test func everyFixtureSpeaksBothLanguages() {
        for lang in [ResolvedLanguage.en, .zh] {
            for fixture in SurfaceFixtures.all(lang: lang) {
                if case .row(let model, _) = fixture.value {
                    #expect(!model.headline.isEmpty, "\(fixture.name)")
                    #expect(!model.why.isEmpty, "\(fixture.name)")
                    #expect(model.lang == lang)
                }
            }
        }
    }

    // MARK: - The detail page

    @Test func theDetailPageSaysTheSameWhyAsTheRow() {
        let sample = SurfaceFixtures.rowPermission()
        let face = SurfaceFixtures.rowModel(sample, lang: .en)
        let detail = SurfaceFixtures.detail(sample, lang: .en)
        #expect(detail.why == face.why)
        #expect(detail.lamp == face.lamp)
        #expect(detail.ask == "Bash: npm run build")
        #expect(detail.canDismiss)
        let labels = detail.facts.map { $0.label }
        #expect(!labels.contains("Source"), "how Pulse reads a session is in the report, not the page")
        #expect(!labels.contains("Model"), "the model is never shown")
    }

    @Test func theTurnDetailQuotesTheLastMessage() {
        let fixture = SurfaceFixtures.detailTurn(lang: .en)
        #expect(fixture.lastMessage != nil)
        #expect(!fixture.canDismiss)
    }

    @Test func staleWordsAreNotQuotedAsNow() {
        let detail = DetailModel.make(row: session(), facts: SessionFacts(lastWords: "old", lastEventMs: now - 45 * minute), lang: .en, nowMs: now)
        #expect(detail.lastMessage == nil)
    }

    /// The page says each thing once: the headline is its title (no second
    /// headline block), "This turn" is its one clock (no state-and-age, no
    /// start time), and a stalled row's why — already the row's second
    /// line — is not repeated.
    @Test func theDetailSaysEachThingOnce() {
        let steps = SurfaceFixtures.detailTimeline(lang: .en)
        let labels = steps.facts.map { $0.label }
        #expect(labels == [L10n.t(.stepThisTurn, .en), L10n.t(.detailFolder, .en)], "one clock, then the folder")
        let running = SurfaceFixtures.rowTimeline()
        let headline = TrayRowModel.headline(running.row, facts: running.facts, lang: .en, nowMs: SurfaceFixtures.nowMs)
        #expect(steps.headline == headline)
        #expect(steps.why != nil, "a running row's why is not its second line (the step)")

        let stalledFace = SurfaceFixtures.rowModel(SurfaceFixtures.rowStalledStep(), lang: .en)
        let stalled = SurfaceFixtures.detailStalled(lang: .en)
        #expect(stalledFace.secondLine?.kind == .warning)
        #expect(stalledFace.secondLine?.text == stalledFace.why)
        #expect(stalled.why == nil, "the stall's why is the row's second line — said once")

        let blocked = SurfaceFixtures.detailPermission(lang: .en)
        #expect(blocked.why != nil, "a wait's why is not its ask")
        #expect(blocked.ask == "Bash: npm run build")
    }

    /// The detail page carries the row's landing notice — the same words.
    @Test func theDetailCarriesTheLandingNotice() {
        let detail = SurfaceFixtures.detailAppOnly(lang: .en)
        #expect(detail.notice?.text == L10n.t(.focusAppOnlyAutomation, .en))
        let row = SurfaceFixtures.rowModel(SurfaceFixtures.rowTerminalTab(), lang: .en, appOnly: true)
        #expect(row.notice == detail.notice)
    }

    /// No placeholder rows: a fact Pulse does not have is not listed, and
    /// raw values are words.
    @Test func theDetailListsOnlyWhatItKnows() {
        var row = session()
        row.cwd = ""
        let detail = DetailModel.make(row: row, facts: said, lang: .en, nowMs: now)
        #expect(detail.facts.isEmpty, "\(detail.facts)")
    }
}

/// The defects a fresh audit turned up.
///
/// Each of these is a place where the code said something it had not
/// measured, dropped work it had been asked to do, or let a click reach
/// nothing without saying so.
final class RowErrorTests: XCTestCase {
    private let now: Int64 = 1_800_000_000_000

    private func liveRow() -> AgentRow {
        var row = AgentRow(key: "claude|s1", status: .running(stalled: false))
        row.task = "Fix the auth module"
        row.liveProcess = true
        return row
    }

    // MARK: D-2 · a fault is not crowded out

    /// A turn's last error is shown on the detail page, where
    /// it can be read in full — not guessed into a count.
    func testALastErrorIsTheDetailPagesError() {
        let failed = SessionFacts(lastError: "npm ERR! missing script: test", lastEventMs: now)
        XCTAssertEqual(DetailModel.make(row: liveRow(), facts: failed, lang: .en, nowMs: now).error, "npm ERR! missing script: test")
        XCTAssertNil(DetailModel.make(row: liveRow(), facts: SessionFacts(lastEventMs: now), lang: .en, nowMs: now).error)
    }

    func testNoErrorsIsNoFault() {
        let why = TrayRowModel.why(liveRow(), facts: SessionFacts(lastEventMs: now), lang: .en, nowMs: now)
        XCTAssertFalse(why.contains("error"), why)
    }
}

/// VoiceOver speaks up only for a new wait — who and what it asks — and
/// says nothing when the count falls or holds.
@Suite("Wait announcement")
struct WaitAnnouncementTests {
    let now: Int64 = 1_800_000_000_000

    private func waiting(_ key: SessionKey, ask: String, since: Int64) -> AgentRow {
        AgentRow(key: key, status: .needsYou(Block(kind: .permission, ask: ask, sinceMs: since)))
    }

    @Test func onlyARisingBlockedCountIsAnnounced() {
        let old = waiting("claude|a", ask: "Bash: npm test", since: now - 600_000)
        let new = waiting("copilot|b", ask: "Edit: src/main.swift", since: now - 5_000)
        let rose = WaitAnnouncement.text(previousBlocked: 1, rows: [old, new], lang: .en)
        #expect(rose == "Copilot needs you: Edit: src/main.swift", "the newest wait, in its own words")
        let held = WaitAnnouncement.text(previousBlocked: 2, rows: [old, new], lang: .en)
        #expect(held == nil)
        let fell = WaitAnnouncement.text(previousBlocked: 2, rows: [old], lang: .en)
        #expect(fell == nil, "an answered wait is not announced")
        let running = AgentRow(key: "codex|c", status: .running(stalled: false))
        let other = WaitAnnouncement.text(previousBlocked: 0, rows: [running], lang: .en)
        #expect(other == nil, "a running session is not announced")
        let first = WaitAnnouncement.text(previousBlocked: nil, rows: [old], lang: .en)
        #expect(first == nil, "the first scan is the baseline")
    }

    @Test func aWaitWithoutWordsSaysWhoAndInChinese() {
        let quiet = AgentRow(key: "pi|a", status: .needsYou(Block(kind: .waiting, sinceMs: now)))
        let text = WaitAnnouncement.text(previousBlocked: 0, rows: [quiet], lang: .en)
        #expect(text == "Pi needs you")
        let zh = WaitAnnouncement.text(previousBlocked: 0, rows: [waiting("claude|a", ask: "Bash: ls", since: now)], lang: .zh)
        #expect(zh == "Claude 需要你：Bash: ls")
    }

    /// A row's VoiceOver label says its time in whole words.
    @Test func aRowsSpokenTimeIsInFullUnits() {
        var row = waiting("claude|a", ask: "Bash: npm test", since: now - 4 * 60_000)
        row.task = "Fix the flaky test"
        let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        #expect(face.age == "4m", "the drawn time stays compact")
        #expect(face.accessibilityLabel.contains(L10n.duration(4 * 60, .en, spoken: true)), "\(face.accessibilityLabel)")
        #expect(!face.accessibilityLabel.contains("4m"), "\(face.accessibilityLabel)")
        var ran = AgentRow(key: "codex|b", status: .running(stalled: false))
        let young = TrayRowModel.rowTime(ran, facts: SessionFacts(turnStartMs: now - 20_000, lastEventMs: now - 20_000), nowMs: now, lang: .en, spoken: true)
        #expect(young == "now")
        ran.status = .yourTurn(sinceMs: now - 12 * 60_000)
        let ago = TrayRowModel.rowTime(ran, facts: SessionFacts(lastEventMs: now - 12 * 60_000), nowMs: now, lang: .en, spoken: true)
        let plain = ago.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(plain == "12 minutes ago")
    }
}

/// The hidden main menu routes the standard key equivalents; the
/// status item's menu is Open Pulse, Settings…, Quit Pulse.
@Suite("Main menu")
@MainActor
struct MainMenuTests {
    @Test func theMainMenuCarriesTheStandardKeys() {
        let menu = MainMenu.make(lang: .en)
        var keys: [String: Selector] = [:]
        for holder in menu.items {
            for item in holder.submenu?.items ?? [] where !item.keyEquivalent.isEmpty {
                if let action = item.action { keys[item.keyEquivalent + "|\(item.keyEquivalentModifierMask.rawValue)"] = action }
            }
        }
        let command = NSEvent.ModifierFlags.command.rawValue
        #expect(keys["w|\(command)"] == #selector(NSWindow.performClose(_:)), "⌘W closes Settings")
        #expect(keys["c|\(command)"] == #selector(NSText.copy(_:)))
        #expect(keys["a|\(command)"] == #selector(NSText.selectAll(_:)))
        #expect(keys["v|\(command)"] == #selector(NSText.paste(_:)))
        #expect(keys["q|\(command)"] == #selector(MainMenuActions.quit(_:)))
        #expect(keys[",|\(command)"] == #selector(MainMenuActions.settings(_:)))
        let zh = MainMenu.make(lang: .zh).items.map { $0.title }
        #expect(zh.contains(L10n.t(.menuEdit, .zh)))
    }
}

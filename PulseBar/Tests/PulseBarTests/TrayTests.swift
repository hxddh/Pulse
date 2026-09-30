import Foundation
import AppKit
import Testing
import XCTest
@testable import PulseApp
@testable import PulseQA
@testable import PulseCore
@testable import PulseHarvest

// Tray: the row face, header, keys, order, lamp, detail page and copy.

// What a row says is pinned in `RowWordsTests` (below); the focus-honesty
// rule is here.

/// A folder that cannot be a workspace is never opened as one: the editor
/// drops to app precision.
final class BestEffortWorkspaceTests: XCTestCase {
    func testOnlyAnAbsoluteWorkspaceIsOpened() {
        let handle = LandingHandle(term: "vscode")
        let opened = LandingPlan.make(handle: handle, cwd: "/Users/me/my-project", allowAutomation: false)
        XCTAssertEqual(opened.steps.first, LandingStep.openFolder(bundleIDs: HostAppKind.vsCode.bundleIDs, path: "/Users/me/my-project"))
        for cwd in ["", "relative/path", "/", "/tmp", "/private/tmp"] {
            let plan = LandingPlan.make(handle: handle, cwd: cwd, allowAutomation: false)
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

    private func session(_ key: String, _ agent: AgentID = .claude) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = key
        row.task = "Fix the login test"
        row.project = "app"
        row.liveProcess = true
        row.state = .running
        row.lastEventMs = now - minute
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

    @Test func theDetailPageTakesCommandDAndCommandMAndReturn() {
        let open = TrayKeys.State(selected: "a", detail: "a")
        let dismiss = press(open, [.dismiss])
        #expect(dismiss.effect == .dismiss("a"))
        let mute = press(open, [.mute])
        #expect(mute.effect == .toggleMute("a"))
        let go = press(open, [.enter])
        #expect(go.effect == .focus("a"))
    }

    @Test func dismissOnADetailThatIsNotAWaitDoesNothing() {
        let open = TrayKeys.State(selected: "b", detail: "b")
        let outcome = press(open, [.dismiss])
        #expect(outcome.effect == nil)
    }

    // MARK: - Keys: the list

    @Test func escapeOnTheListClosesThePanel() {
        let outcome = press(TrayKeys.State(selected: "a", detail: nil), [.escape])
        #expect(outcome.effect == .closePanel)
        let empty = press(TrayKeys.State(), [.escape], rows: [])
        #expect(empty.effect == .closePanel, "Esc works on an empty list too")
        let down = press(TrayKeys.State(), [.down], rows: [])
        #expect(down.state.selected == nil)
    }

    @Test func commandDAndCommandMActOnTheSelectedRow() {
        let onWait = TrayKeys.State(selected: "a", detail: nil)
        let dismiss = press(onWait, [.dismiss])
        #expect(dismiss.effect == .dismiss("a"))
        let mute = press(onWait, [.mute])
        #expect(mute.effect == .toggleMute("a"))

        let onRunning = TrayKeys.State(selected: "b", detail: nil)
        let notAWait = press(onRunning, [.dismiss])
        #expect(notAWait.effect == nil, "⌘D is not a dismiss on a row that is not waiting")

        let nothingSelected = press(TrayKeys.State(), [.mute])
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

    @Test func aSelectionWhoseRowLeftMovesToTheFirstRow() {
        let gone = TrayKeys.State(selected: "zz", detail: nil)
        let moved = TrayKeys.normalize(gone, rows: rows)
        #expect(moved.selected == "a", "a selection whose row left moves to the first row")
        let none = TrayKeys.normalize(TrayKeys.State(), rows: rows)
        #expect(none.selected == nil, "no selection: nothing is invented")
    }

    /// A bare letter is not the tray's: the tray opens with a row selected,
    /// and a bare D or M must never dismiss or mute.
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
        let mute = TrayKeys.key(keyCode: 46, characters: "m", command: true)
        #expect(mute == .mute)
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

    /// While the tray was open the list was the builder's top-12
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

    @Test func theHeaderCountsWhatMattersInTone() {
        var stalled = session("s")
        stalled.isStalled = true
        var turn = session("t")
        turn.state = .yourTurn(sinceMs: now - minute)
        let model = TrayHeaderModel.make(counts: TrayState.Counts(rows: [blocked("w1"), blocked("w2"), session("r"), stalled, turn]), lang: .en)
        let labels = model.counts.map { "\($0.count) \($0.label)" }
        #expect(labels == ["2 need you", "1 running", "1 stalled", "1 your turn"])
        let tones = model.counts.map { $0.tone }
        #expect(tones == [.waiting, .running, .attention, .idle])
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
        var process = AgentRow(rowKey: RowIdentity.process(agent: .codex, pid: 1), agent: .codex)
        process.state = .processOnly
        let grey = TrayHeaderModel.make(counts: TrayState.Counts(rows: [process]), lang: .zh)
        #expect(grey.title == "1 " + L10n.t(.processOnlyN, .zh))
    }

    // MARK: - The one notice

    private func notice(
        notify: Bool = true, authorized: Bool? = true, banner: Bool = false,
        unconnected: [AgentID] = [], failure: String = "", connected: [AgentID]? = nil
    ) -> TrayNoticeModel? {
        TrayNoticeModel.pick(TrayNoticeModel.Input(
            lang: .en, notifyOnWaiting: notify, notifyAuthorized: authorized,
            bannerFailed: banner, unconnected: unconnected, installFailure: failure, justConnected: connected
        ))
    }

    @Test func atMostOneNoticeInItsOrder() {
        let all = notice(authorized: false, banner: true, unconnected: [.claude])
        #expect(all?.kind == .setup, "connecting comes before notifications")
        #expect(all?.action == .connect)
        let followUp = notice(authorized: false, unconnected: [.gemini], connected: [.claude])
        #expect(followUp?.kind == .setupDone)
        #expect(followUp?.action == .dismissSetup)
        let denied = notice(authorized: false, banner: true)
        #expect(denied?.kind == .notificationsDenied)
        #expect(denied?.action == .openNotificationSettings)
        let notAsked = notice(authorized: nil)
        #expect(notAsked?.kind == .notificationsOff)
        #expect(notAsked?.action == .enableNotifications)
        let failed = notice(authorized: false, failure: "Gemini: broken")
        #expect(failed?.kind == .setupFailed, "a failed install comes before notifications")
        #expect(failed?.action == .openHooksSettings)
        #expect(failed?.text == "Gemini: broken")
        let unconnectedFirst = notice(unconnected: [.claude], failure: "Gemini: broken")
        #expect(unconnectedFirst?.kind == .setup, "agents that can still connect are offered first")
        let banner = notice(banner: true)
        #expect(banner?.kind == .bannerFailed)
        #expect(notice() == nil)
        let optedOut = notice(notify: false, authorized: false)
        #expect(optedOut == nil, "notifications turned off in Pulse are not a problem")
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
        ui.open()
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
        ui.open()
        let rows = store.allRowsForDisplay
        try #require(rows.count >= 2)
        ui.showDetail(rows[0].rowKey)
        store.requestTrayReveal(rowKey: rows[1].rowKey, detail: true)
        ui.applyPendingReveal()
        #expect(ui.keys.detail == rows[1].rowKey)
        #expect(ui.keys.selected == rows[1].rowKey)
    }

    /// One gesture — a menu-bar click and the shortcut open the same
    /// way, on the oldest wait.
    @MainActor
    @Test func everyOpenSelectsTheOldestWait() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        let ui = TrayUI(store: store)
        ui.open()
        let oldest = ui.displayRows.filter(\.isBlocked).min { ($0.wait?.sinceMs ?? 0) < ($1.wait?.sinceMs ?? 0) }
        #expect(oldest != nil)
        #expect(ui.keys.selected == oldest?.rowKey)
    }

    /// A fresh glance selects the first row, so the projection's order is
    /// what makes it the oldest wait: waits first, the oldest first, an
    /// unknown clock last, then the rest.
    @Test func theProjectionListsTheOldestWaitFirst() {
        func blocked(_ key: String, since: Int64) -> AgentRow {
            var row = AgentRow(rowKey: key, agent: .claude)
            row.state = .blocked(RowWait(kind: "Permission", sinceMs: since))
            return row
        }
        var running = AgentRow(rowKey: "run", agent: .codex)
        running.state = .running
        let rows = [running, blocked("new", since: 9_000), blocked("unknown", since: 0), blocked("old", since: 1_000)]
        let order = TrayState.assemble(rows: rows, context: .init(nowMs: 10_000)).rows.map(\.rowKey)
        #expect(order == ["old", "new", "unknown", "run"])
        let onlyUnknown = TrayState.assemble(rows: [running, blocked("unknown", since: 0)], context: .init(nowMs: 10_000)).rows.first?.rowKey
        #expect(onlyUnknown == "unknown")
    }

    /// The shortcuts offered leave the editors' own alone.
    @Test func theShortcutsOfferedDoNotClashWithEditors() {
        let labels = HotkeyChoice.allCases.map(\.label)
        #expect(labels.contains("⌃⌥Space"))
        #expect(labels.contains("⌥⌘P"))
        #expect(!labels.contains("⌘⇧P"), "VS Code / Cursor's command palette")
        #expect(!labels.contains("⌘⇧U"))
        #expect(HotkeyChoice(rawValue: "cmd_shift_p") == nil, "a saved clashing choice reads as off")
        #expect(PulseSettings().hotkey == .off, "still opt-in")
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
    /// Red, green and orange keep their colour; a grey lamp is a template
    /// the menu bar colours like its neighbours.
    func testStatusBarLampsKeepTheirStateColors() {
        let states: [GlanceKind] = [.waiting, .running, .idle, .stalled]
        for state in states {
            XCTAssertEqual(
                PulseBrand.statusBarIcon(for: state).isTemplate,
                state == .idle,
                "\(state): only grey follows the menu bar"
            )
        }
        for lamp in [LampFace.glance(.idle, processOnly: true), LampFace(shape: .hollow, tone: .idle)] {
            XCTAssertTrue(PulseBrand.statusBarIcon(for: lamp).isTemplate, "\(lamp.shape)")
        }
        // Drawn at its own size — never set smaller after drawing, which
        // blurred it.
        XCTAssertEqual(PulseBrand.statusBarIcon(for: .waiting).size, NSSize(width: 16, height: 16))

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
            for glance in [GlanceKind.idle, .running, .stalled, .waiting] {
                let icon = PulseBrand.statusBarIcon(for: glance)
                XCTAssertEqual(
                    icon.isTemplate,
                    glance == .idle,
                    "\(glance) in \(appearanceName.rawValue): a coloured lamp is never flattened to monochrome"
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

/// The product's rules asserted on the surface values `PulseQA`'s
/// `SurfaceCapture` photographs, not on the store behind them: the tray row,
/// header, notice, the detail page and Settings.
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

/// Landing: the handle decides, the plan says how precisely, and the
/// label never promises more than the plan.
@Suite("Landing plan")
struct LandingPlanTests {
    @Test func aTmuxPaneLandsExactlyWithoutAutomation() {
        let handle = LandingHandle("tmux:%3;tmuxsock:/private/tmp/tmux-501/default;iterm:w0t1p0:ABCD;tty:/dev/ttys004;term:tmux;app:com.googlecode.iterm2")
        #expect(handle.tmuxPane == "%3")
        #expect(handle.tmuxSocket == "/private/tmp/tmux-501/default")
        #expect(handle.tty == "ttys004")
        let plan = LandingPlan.make(handle: handle, cwd: "/Users/me/app", allowAutomation: false)
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
        let plan = LandingPlan.make(handle: handle, cwd: "/Users/me/app", allowAutomation: true)
        #expect(plan.steps == [
            .iTermSession(uniqueID: "9F1C-UUID"),
            .ttyTab(tty: "ttys007"),
            .activateApp(bundleIDs: [LandingPlan.iTermBundleID]),
        ])
        #expect(plan.precision == .exact)
    }

    @Test func aTerminalTabIsFoundByItsTTY() {
        let plan = LandingPlan.make(handle: LandingHandle("tty:/dev/ttys001;term:Apple_Terminal"), cwd: "", allowAutomation: true)
        #expect(plan.steps == [.ttyTab(tty: "ttys001"), .activateApp(bundleIDs: [LandingPlan.terminalBundleID])])
        #expect(plan.precision == .exact)
    }

    @Test func ghosttyIsTheAppOnly() {
        let plan = LandingPlan.make(handle: LandingHandle("tty:/dev/ttys002;term:ghostty"), cwd: "/Users/me/app", allowAutomation: true)
        #expect(plan.steps == [.activateApp(bundleIDs: ["com.mitchellh.ghostty"])], "the tab search asks only Terminal and iTerm")
        #expect(plan.precision == .app)
    }

    @Test func anEditorTerminalOpensTheFolderInThatEditor() {
        let vscode = LandingPlan.make(handle: LandingHandle("tty:/dev/ttys005;term:vscode"), cwd: "/Users/me/app", allowAutomation: true, pid: 812)
        #expect(vscode.steps == [
            .openFolder(bundleIDs: HostAppKind.vsCode.bundleIDs, path: "/Users/me/app"),
            .activateApp(bundleIDs: HostAppKind.vsCode.bundleIDs),
            .activateOwner(pid: 812),
        ])
        #expect(vscode.precision == .app)
        let cursor = LandingPlan.make(
            handle: LandingHandle("term:vscode;app:com.todesktop.230313mzl4w4u92"), cwd: "/Users/me/app", allowAutomation: false
        )
        #expect(cursor.steps.first == LandingStep.openFolder(bundleIDs: HostAppKind.cursor.bundleIDs, path: "/Users/me/app"), "Cursor also says vscode")
    }

    @Test func anEmptyHandleFallsBackToTheProcessOwnerOrNothing() {
        #expect(LandingPlan.make(handle: LandingHandle(""), cwd: "/Users/me/app", allowAutomation: true).isEmpty)
        #expect(LandingPlan.make(handle: LandingHandle(), cwd: "", allowAutomation: true).precision == nil)
        let process = LandingPlan.make(handle: LandingHandle(), cwd: "/Users/me/app", allowAutomation: false, pid: 4312)
        #expect(process.steps == [.activateOwner(pid: 4312)])
        #expect(process.precision == .app)
        let ide = LandingPlan.make(handle: LandingHandle(), cwd: "/Users/me/app", allowAutomation: false, pid: 4312, hostApp: .zed)
        #expect(ide.steps.first == LandingStep.openFolder(bundleIDs: HostAppKind.zed.bundleIDs, path: "/Users/me/app"))
    }

    @Test func automationOffNeverScriptsATerminal() {
        let iterm = LandingPlan.make(handle: LandingHandle("iterm:w0t1p0:ABCD;tty:/dev/ttys007;term:iTerm.app"), cwd: "", allowAutomation: false)
        #expect(iterm.steps == [.activateApp(bundleIDs: [LandingPlan.iTermBundleID])])
        #expect(iterm.precision == .app)
        let terminal = LandingPlan.make(handle: LandingHandle("tty:/dev/ttys001"), cwd: "", allowAutomation: false)
        #expect(terminal.isEmpty, "a bare tty with automation off is not a handle")
        for placeholder in ["tty:?", "tty:??", "tty:-"] {
            #expect(LandingPlan.make(handle: LandingHandle(placeholder), cwd: "", allowAutomation: true).isEmpty, "\(placeholder)")
        }
    }

    @Test func theLabelFollowsThePrecision() {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        #expect(!row.canFocusTerminal)
        row.landingPlan = LandingPlan.make(handle: LandingHandle("term:ghostty"), cwd: "", allowAutomation: true)
        #expect(TrayRowModel.focusTitle(row, lang: .en) == "Open app")
        #expect(TrayRowModel.focusTitle(row, lang: .zh) == "打开应用")
        row.landingPlan = LandingPlan.make(handle: LandingHandle("tmux:%1"), cwd: "", allowAutomation: false)
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

    func testDurationUnitsAreLocalized() {
        XCTAssertNotEqual(L10n.t(.durMin, .en), L10n.t(.durMin, .zh), "zh tray showed English units")
        XCTAssertEqual(DurationFormat.label(seconds: 240, lang: .zh, spoken: true), "4 分钟", "a sentence says 分钟")
        XCTAssertEqual(DurationFormat.label(seconds: 240, lang: .en, spoken: true), "4m")
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
        XCTAssertEqual(L10n.t(.waitingSummaryTitle, .en), "%d agents need you")
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

/// Duration wording lives off `StatusStore` so `TrayState` — which is pure
/// and has no store — can put the elapsed wait in the menu bar.
final class DurationFormatTests: XCTestCase {
    func testUnitsCrossOverAtTheRightPlaces() {
        XCTAssertEqual(DurationFormat.label(seconds: 2, lang: .en), "now")
        XCTAssertEqual(DurationFormat.label(seconds: 42, lang: .en), "42s")
        XCTAssertEqual(DurationFormat.label(seconds: 600, lang: .en), "10m")
        XCTAssertEqual(DurationFormat.label(seconds: 7200, lang: .en), "2h")
    }

    /// VoiceOver hears whole words: "4 minutes", "1 hour", never "4m".
    func testSpokenDurationsUseFullUnits() {
        XCTAssertEqual(DurationFormat.full(seconds: 2, lang: .en), "just now")
        XCTAssertEqual(DurationFormat.full(seconds: 1, lang: .zh), "刚刚")
        XCTAssertEqual(DurationFormat.full(seconds: 42, lang: .en), "42 seconds")
        XCTAssertEqual(DurationFormat.full(seconds: 60, lang: .en), "1 minute")
        XCTAssertEqual(DurationFormat.full(seconds: 240, lang: .en), "4 minutes")
        XCTAssertEqual(DurationFormat.full(seconds: 3600, lang: .en), "1 hour")
        XCTAssertEqual(DurationFormat.full(seconds: 7200, lang: .en), "2 hours")
        XCTAssertEqual(DurationFormat.full(seconds: 240, lang: .zh), "4 分钟")
        XCTAssertEqual(DurationFormat.full(seconds: 7200, lang: .zh), "2 小时")
    }

    /// A count picks its form — never "session(s)".
    func testNoCopyUsesAPluralHack() {
        for key in L10n.Key.allCases {
            XCTAssertFalse(L10n.t(key, .en).contains("(s)"), "\(key): a plural hack")
        }
    }

    func testChineseDiffersFromEnglish() {
        XCTAssertNotEqual(
            DurationFormat.label(seconds: 600, lang: .zh),
            DurationFormat.label(seconds: 600, lang: .en)
        )
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
        row.lastEventMs = now - 5 * 60 * 1000
        XCTAssertTrue(row.selfReportFresh(at: now))
        row.lastEventMs = now - 31 * 60 * 1000
        XCTAssertFalse(row.selfReportFresh(at: now), "the headline and the detail page share this gate")
    }

    func testTheLastMessageNeverImpliesWaiting() {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.lastWord = "Waiting for your review."
        row.state = .running
        row.lastEventMs = now
        let detail = DetailModel.make(row: row, lang: .en, nowMs: now)
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
        row.lastEventMs = Int64(Date().timeIntervalSince1970 * 1000)
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
        XCTAssertEqual(s.rowActionNotice(row)?.text, s.tr(.focusFailed))

        var other = liveRow()
        other.rowKey = "codex|s2"
        XCTAssertNil(s.rowActionNotice(other), "a notice belongs to the row that was clicked")
    }

    @MainActor
    func testEveryFailureSentenceIsRealCopyInBothLanguages() {
        // These only ever appear when something went wrong, which is exactly
        // when an untranslated or empty string would be found by a user
        // rather than by us.
        for key in [L10n.Key.focusFailed, .focusAppOnly] {
            XCTAssertFalse(L10n.t(key, .en).isEmpty, "\(key)")
            XCTAssertFalse(L10n.t(key, .zh).isEmpty, "\(key)")
            XCTAssertNotEqual(L10n.t(key, .en), L10n.t(key, .zh), "\(key)")
        }
    }
}

// MARK: - Row words

/// What a row says — the headline and the why — the lamp's one-sentence
/// rule, and the row face and detail page built on them.
@Suite("Row words")
struct RowWordsTests {
    let now: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private func session(_ agent: AgentID = .claude, task: String = "Refactor the settings panes") -> AgentRow {
        var row = AgentRow(rowKey: RowIdentity.session(agent: agent, session: "s1"), agent: agent)
        row.sessionID = "s1"
        row.task = task
        row.project = "pulse"
        row.cwd = "/Users/me/pulse"
        row.source = .hooks
        row.liveProcess = true
        row.state = .running
        row.lastEventMs = now - minute
        return row
    }

    private func blocked(kind: String = "Permission", inFront: Bool = false) -> AgentRow {
        var row = session()
        row.state = .blocked(RowWait(kind: kind, ask: "Bash: npm test", sinceMs: now - 4 * minute, inFront: inFront))
        return row
    }

    private func why(_ row: AgentRow, _ lang: ResolvedLanguage = .en) -> String {
        TrayRowModel.why(row, lang: lang, nowMs: now)
    }

    // MARK: - Why: which evidence, and since when

    @Test func aHookWaitNamesItsEvidenceAndItsAge() {
        let text = why(blocked())
        #expect(text.contains("Claude"))
        #expect(text.contains(L10n.t(.explainKindPermission, .en)))
        #expect(text.contains(TrayRowModel.ago(now - 4 * minute, nowMs: now, lang: .en)))
        #expect(!text.hasSuffix(L10n.t(.explainAskedFront, .en)))
    }

    @Test func aWaitRaisedInFrontSaysWhyThereWasNoBanner() {
        let text = why(blocked(inFront: true))
        #expect(text.hasSuffix(L10n.t(.explainAskedFront, .en)))
    }

    /// The why is plain words — who asked what, and when.
    @Test func aWaitIsSaidInPlainWords() {
        #expect(why(blocked()) == "Claude asked for permission · 4m ago")
        #expect(why(blocked(), .zh) == "Claude 请求权限 · 4 分钟前")
        var process = AgentRow(rowKey: RowIdentity.process(agent: .cursor, pid: 7), agent: .cursor)
        process.state = .processOnly
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
        let text = why(blocked(kind: "Input"))
        #expect(text.contains("Claude"))
        #expect(text.contains(L10n.t(.explainKindInput, .en)))
    }

    @Test func yourTurnSaysHowToClearItWithoutNowAgo() {
        var row = session(.codex)
        row.state = .yourTurn(sinceMs: now - 2_000)
        let text = why(row, .zh)
        #expect(text.contains("Codex"))
        #expect(!text.contains("刚刚前"), "never 'just now ago'")
    }

    @Test func aProcessOnlyRowSaysItIsOnlyAProcess() {
        var row = AgentRow(rowKey: RowIdentity.process(agent: .cursor, pid: 7), agent: .cursor)
        row.liveProcess = true
        row.state = .processOnly
        #expect(why(row) == L10n.t(.explainProcessOnly, .en))
    }

    /// The stall rule is not a setting, so the sentence names the
    /// silence and nothing the person could not have set.
    @Test func aStalledRowNamesTheSilence() {
        var row = session()
        row.lastEventMs = now - 23 * minute
        row.isStalled = true
        let quiet = DurationFormat.label(seconds: 23 * 60, lang: .en, spoken: true)
        let expected = String(format: L10n.t(.explainStalled, .en), quiet)
        #expect(why(row) == expected)
    }

    /// A stalled row's why names its last step: "Nothing new for 23m — last
    /// step: Bash · swift test".
    @Test func aStalledRowNamesItsLastStep() {
        var row = session()
        row.lastEventMs = now - 23 * minute
        row.isStalled = true
        row.lastStep = SessionBook.Step(tool: "Bash", target: "swift test", ms: now - 23 * minute)
        #expect(why(row) == "Nothing new for 23m — last step: Bash · swift test")
        #expect(why(row, .zh) == "已经 23 分钟 没有新动静——上一步：Bash · swift test")
        let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        #expect(face.secondLine == TrayRowModel.SecondLine(kind: .warning, text: why(row)))
    }

    /// A running row's quiet second line is its last step, worded as a
    /// past step; its time slot is this turn's duration.
    @Test func aRunningRowShowsItsLastStepAndItsTurn() {
        var row = session()
        row.turnStartMs = now - 14 * minute
        row.lastStep = SessionBook.Step(tool: "Bash", target: "swift test", ms: now - 12 * minute)
        row.recentSteps = [row.lastStep].compactMap { $0 }
        let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        #expect(face.secondLine == TrayRowModel.SecondLine(kind: .step, text: "Bash · swift test · 12m ago"))
        #expect(face.age == "14m")
        #expect(face.accessibilityLabel.contains("Bash · swift test"))
        let zh = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .zh, nowMs: now))
        #expect(zh.secondLine?.text == "Bash · swift test · 12 分钟前")
        #expect(zh.age == "14 分")
        // Under a minute the turn says so, and the step says "now".
        row.turnStartMs = now - 20_000
        row.lastStep = SessionBook.Step(tool: "Read", target: "", ms: now - 10_000)
        let young = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        #expect(young.age == "<1m")
        #expect(young.secondLine?.text == "Read · now")
    }

    /// No step, no second line: a Cursor or OpenCode row stays one line,
    /// and a row whose turn start is unknown shows when it last moved.
    @Test func aRowWithoutStepsStaysOneLine() {
        let face = TrayRowModel.make(TrayRowModel.Input(row: session(.cursor), lang: .en, nowMs: now))
        #expect(face.secondLine == nil)
        #expect(face.age == String(format: L10n.t(.agoFormat, .en), "1m"))
    }

    /// Step words say what was reported, never that it is still going.
    @Test func noStepWordingSaysRunning() {
        var row = session()
        row.isStalled = true
        row.lastStep = SessionBook.Step(tool: "Edit", target: "a.swift", ms: now - 30 * minute)
        row.recentSteps = [row.lastStep].compactMap { $0 }
        row.turnStartMs = now - 40 * minute
        for lang in [ResolvedLanguage.en, .zh] {
            var texts = [why(row, lang), TrayRowModel.stepLine(row.recentSteps[0], nowMs: now, lang: lang)]
            texts += [L10n.t(.stepStalled, lang), L10n.t(.stepHeading, lang), L10n.t(.stepThisTurn, lang)]
            let detail = DetailModel.make(row: row, lang: lang, nowMs: now)
            texts += detail.steps.flatMap { [$0.label, $0.value] }
            for text in texts {
                #expect(!text.lowercased().contains("running"), "\(text)")
                #expect(!text.contains("正在"), "\(text)")
            }
        }
    }

    /// The detail page lists up to five steps, newest first, and this
    /// turn's duration as a fact.
    @Test func theDetailListsRecentStepsAndThisTurn() {
        let detail = SurfaceFixtures.detailSteps(lang: .en)
        #expect(detail.steps.count == SessionBook.maxSteps)
        #expect(detail.steps.first?.value == "Bash · swift test")
        #expect(detail.steps.last?.value == "Read · Sources/Upload/Queue.swift")
        let turn = detail.facts.first { $0.label == L10n.t(.stepThisTurn, .en) }
        #expect(turn?.value == "14m")
    }

    @Test func aStalledRowWithNoClockSaysSoRatherThanGuess() {
        var row = session()
        row.lastEventMs = 0
        row.isStalled = true
        #expect(why(row) == L10n.t(.explainStalledUnknown, .en))
    }

    @Test func aRunningRowSaysItIsWorking() {
        let text = why(session())
        #expect(text.hasPrefix("Claude is working"), "\(text)")
        var noClock = session()
        noClock.lastEventMs = 0
        #expect(why(noClock) == L10n.t(.explainRunningNoClock, .en))
    }

    /// Orange is only a stall — a turn's error is a fact in the detail page,
    /// not a lamp.
    @Test func anErrorIsNotAnOrangeLamp() {
        var row = session()
        row.lastErrorText = "npm ERR! missing script: test"
        let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        #expect(face.lamp == LampFace(shape: .ring, tone: .running))
    }

    /// A recent row says which rule made it recent.
    @Test func aRecentRowSaysWhichRuleMadeItRecent() {
        var row = session()
        row.liveProcess = false
        row.state = .recent
        row.recentReason = .ended
        row.stateSinceMs = now - 5 * minute
        #expect(why(row).hasPrefix("The session ended"))
        row.recentReason = .atPrompt
        #expect(why(row).hasPrefix("At its prompt"))
        row.recentReason = .quiet
        #expect(why(row).contains("no process to watch"))
    }

    @Test func theSameRowAndInstantAlwaysSayTheSameThing() {
        let input = TrayRowModel.Input(row: blocked(), lang: .en, nowMs: now)
        let first = TrayRowModel.make(input)
        let second = TrayRowModel.make(input)
        #expect(first == second)
    }

    @Test func thePinnedClockIsTheOneTheSentenceMeasuresFrom() {
        let row = blocked()
        let early = TrayRowModel.why(row, lang: .en, nowMs: now)
        let later = TrayRowModel.why(row, lang: .en, nowMs: now + 60 * minute)
        #expect(early != later)
    }

    @Test func languageIsAnInput() {
        let row = blocked()
        #expect(why(row, .en) != why(row, .zh))
    }

    // MARK: - Headline: the tray hero

    @Test func theTaskLeadsEvenWhenWordsAreFresh() {
        var row = session()
        row.lastWord = "All tests pass."
        #expect(TrayRowModel.headline(row, lang: .en, nowMs: now) == "Refactor the settings panes")
    }

    @Test func freshWordsLeadOnlyWithoutATask() {
        var row = session(task: "")
        row.lastWord = "All tests pass."
        #expect(TrayRowModel.headline(row, lang: .en, nowMs: now) == "All tests pass.")
        row.lastEventMs = now - 45 * minute
        #expect(TrayRowModel.headline(row, lang: .en, nowMs: now) == "pulse", "stale words fall back to the project")
    }

    @Test func aSessionWithNothingToSayNamesItsHandle() {
        var row = session(task: "")
        row.project = ""
        #expect(TrayRowModel.headline(row, lang: .en, nowMs: now) == L10n.t(.appSession, .en))
        row.landingPlan = LandingPlan(steps: [.ttyTab(tty: "ttys003")])
        #expect(TrayRowModel.headline(row, lang: .en, nowMs: now) == L10n.t(.terminalSession, .en))
    }

    @Test func aWaitLeadsWithWhatThePersonMustRecognise() {
        var row = blocked()
        row.lastWord = "Fresh words never displace the question."
        #expect(TrayRowModel.headline(row, lang: .en, nowMs: now) == "Refactor the settings panes")
        row.task = ""
        #expect(TrayRowModel.headline(row, lang: .en, nowMs: now) == "pulse")
        row.project = ""
        #expect(TrayRowModel.headline(row, lang: .en, nowMs: now) == L10n.t(.needsYou, .en))
    }

    @Test func aProcessOnlyRowSaysWhatLittleIsTrue() {
        var row = AgentRow(rowKey: RowIdentity.process(agent: .codex, pid: 9), agent: .codex)
        row.task = "never shown"
        row.state = .processOnly
        #expect(TrayRowModel.headline(row, lang: .en, nowMs: now) == L10n.t(.appDetectedNoDetails, .en))
        row.landingPlan = LandingPlan(steps: [.ttyTab(tty: "ttys003")])
        #expect(TrayRowModel.headline(row, lang: .en, nowMs: now) == L10n.t(.terminalDetectedNoDetails, .en))
    }

    @Test func aBlockedRowCarriesItsAsk() {
        let row = blocked()
        #expect(TrayRowModel.ask(row) == "Bash: npm test")
        #expect(TrayRowModel.stateText(row, lang: .en) == L10n.t(.needsYou, .en), "one word per concept")
    }

    // MARK: - The lamp explanation

    @Test func aRedLampSaysOneLine() {
        let waiting = blocked()
        var other = session(.codex)
        other.rowKey = "codex|b"
        let rule = TrayState.lampRule(counts: TrayState.Counts(rows: [waiting, other]), glance: .waiting)
        #expect(rule == .blocked)
        let sentence = TrayState.lampSentence(rule, lang: .en)
        #expect(sentence == L10n.t(.lampRuleBlocked, .en))
        #expect(!sentence.contains("\n"))
    }

    @Test func aProcessOnlySessionIsAGreyRuleNotAnOrangeOne() {
        var process = AgentRow(rowKey: RowIdentity.process(agent: .cursor, pid: 3), agent: .cursor)
        process.liveProcess = true
        process.state = .processOnly
        let rule = TrayState.lampRule(counts: TrayState.Counts(rows: [process]), glance: .idle)
        #expect(rule == .processOnly)
        #expect(TrayState.lampSentence(rule, lang: .zh) == L10n.t(.lampRuleProcessOnly, .zh))
    }

    @Test func aStalledLampNamesNoThreshold() {
        var stalled = session()
        stalled.lastEventMs = now - 30 * minute
        stalled.isStalled = true
        let rule = TrayState.lampRule(counts: TrayState.Counts(rows: [stalled]), glance: .stalled)
        #expect(rule == .stalled)
        let sentence = TrayState.lampSentence(rule, lang: .en)
        #expect(!sentence.contains("20"))
    }

    @Test func aGreyLampWithATurnSaysWhoseTurn() {
        var turn = session(.codex)
        turn.state = .yourTurn(sinceMs: now - minute)
        var process = AgentRow(rowKey: RowIdentity.process(agent: .codex, pid: 4), agent: .codex)
        process.state = .processOnly
        let rule = TrayState.lampRule(counts: TrayState.Counts(rows: [process, turn]), glance: .idle)
        #expect(rule == .yourTurn, "a finished turn outranks a bare process")
    }

    // MARK: - The lamp's shape and tone, per state

    @Test func everyStateHasItsShapeAndTone() {
        var blockedRow = session()
        blockedRow.state = .blocked(RowWait(kind: "Permission"))
        let running = session()
        var stalled = session()
        stalled.isStalled = true
        var turn = session()
        turn.state = .yourTurn(sinceMs: now)
        var recent = session()
        recent.state = .recent
        var process = AgentRow(rowKey: RowIdentity.process(agent: .codex, pid: 5), agent: .codex)
        process.state = .processOnly

        #expect(LampFace.row(blockedRow) == LampFace(shape: .filled, tone: .waiting))
        #expect(LampFace.row(running) == LampFace(shape: .ring, tone: .running))
        #expect(LampFace.row(stalled) == LampFace(shape: .ring, tone: .attention))
        #expect(LampFace.row(turn) == LampFace(shape: .hollow, tone: .idle))
        #expect(LampFace.row(recent) == LampFace(shape: .hollow, tone: .idle))
        #expect(LampFace.row(process) == LampFace(shape: .dotted, tone: .idle), "a process is never orange")
    }

    @Test func theMenuBarLampUsesTheSameShapes() {
        #expect(LampFace.glance(.waiting) == LampFace(shape: .filled, tone: .waiting))
        #expect(LampFace.glance(.running) == LampFace(shape: .ring, tone: .running))
        #expect(LampFace.glance(.stalled) == LampFace(shape: .ring, tone: .attention))
        #expect(LampFace.glance(.idle) == LampFace(shape: .hollow, tone: .idle))
        #expect(LampFace.glance(.idle, processOnly: true) == LampFace(shape: .dotted, tone: .idle))
    }

    // MARK: - The row face

    @Test func aPermissionRowShowsItsAskOnce() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowPermission(), lang: .en)
        #expect(model.lamp == LampFace(shape: .filled, tone: .waiting))
        #expect(model.secondLine == TrayRowModel.SecondLine(kind: .ask, text: "Bash: npm run build"))
        let menu = model.menu.map { $0.action }
        #expect(menu == [.focus, .details, .dismiss, .mute], "every verb is in the menu once")
        // The only time on a waiting row is how long it has waited.
        let waited = TrayRowModel.waitDuration(SurfaceFixtures.rowPermission(), nowMs: SurfaceFixtures.nowMs, lang: .en)
        #expect(model.age == waited)
    }

    /// The context menu teaches the keys: each item carries the tray key
    /// that does the same — the tray has no key legend of its own.
    @Test func theContextMenuShowsEachItemsKey() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowPermission(), lang: .en)
        let keys: [TrayKeys.Key?] = model.menu.map { $0.key }
        let expected: [TrayKeys.Key?] = [.enter, .right, .dismiss, .mute]
        #expect(keys == expected)
    }

    @Test func yourTurnIsQuietAndSaysSo() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowTurn(), lang: .zh)
        #expect(model.lamp == LampFace(shape: .hollow, tone: .idle))
        #expect(model.turnLabel == "轮到你")
        #expect(model.secondLine == nil)
        #expect(model.accessibilityLabel.contains("轮到你"))
    }

    @Test func aProcessOnlyRowIsQuietGrey() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowProcessOnly(), lang: .en)
        #expect(model.lamp == LampFace(shape: .dotted, tone: .idle))
        #expect(model.secondLine == nil, "grey is not a warning")
        let actions = model.menu.map { $0.action }
        #expect(actions == [.details, .mute], "details and mute; nothing to dismiss, nowhere to go")
        #expect(!model.canFocus)
    }

    @Test func aMutedRowSaysSoAndOffersUnmute() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowRunning(), lang: .en, muted: true)
        #expect(model.muted)
        let titles = model.menu.map { $0.title }
        #expect(titles.contains(L10n.t(.unmute, .en)))
    }

    @Test func theProjectIsNotRepeatedWhenItIsTheHeadline() {
        var row = SurfaceFixtures.rowPermission()
        row.task = ""
        let model = SurfaceFixtures.rowModel(row, lang: .en)
        #expect(model.headline == "app")
        #expect(model.project == "")
    }

    @Test func aWaitWithoutWordsNamesItsKind() {
        var row = SurfaceFixtures.rowPermission()
        row.state = .blocked(RowWait(kind: "Permission", sinceMs: SurfaceFixtures.nowMs - 2 * 60_000))
        let model = SurfaceFixtures.rowModel(row, lang: .en)
        #expect(model.secondLine == TrayRowModel.SecondLine(kind: .ask, text: L10n.waitKind("Permission", .en)))
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

    /// The detail page's times say the day when it is not today, each in
    /// the locale's own pattern.
    @Test func theClockSaysTheDayWhenItIsNotToday() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let gb = Locale(identifier: "en_GB")
        let cn = Locale(identifier: "zh_Hans_CN")
        let hour: Int64 = 60 * minute
        let day: Int64 = 24 * hour
        func label(_ ms: Int64, _ lang: ResolvedLanguage, _ locale: Locale) -> String {
            LogClock.label(ms: ms, nowMs: now, lang: lang, timeZone: utc, locale: locale)
        }
        // 2027-01-15 08:00 UTC, a Friday.
        let today = label(now - 3 * hour, .en, gb)
        #expect(today == "05:00")
        let yesterday = label(now - 9 * hour, .en, gb)
        #expect(yesterday.contains("Thu") && yesterday.contains("23:00"), "\(yesterday)")
        let wednesday = label(now - 2 * day, .zh, cn)
        #expect(wednesday.contains("周三") && wednesday.contains("08:00"), "\(wednesday)")
        let older = label(now - 10 * day, .en, gb)
        #expect(older.contains("08:00") && older.contains("05") && !older.contains("Tue"), "month and day, no weekday: \(older)")
    }

    /// Time of day follows the locale: "3:04 PM" in the US, "15:04" in
    /// Britain — never a fixed "HH:mm".
    @Test func theTimeOfDayFollowsTheLocale() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        // 2027-01-15 15:04 UTC.
        let at: Int64 = 1_800_000_000_000 - (1_800_000_000_000 % 86_400_000) + (15 * 60 + 4) * minute
        func label(_ locale: String) -> String {
            LogClock.label(ms: at, nowMs: at + minute, lang: .en, timeZone: utc, locale: Locale(identifier: locale))
                // ICU puts a narrow no-break space before AM/PM.
                .replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        let us = label("en_US")
        #expect(us == "3:04 PM", "\(us)")
        let gb = label("en_GB")
        #expect(gb == "15:04", "\(gb)")
    }

    /// Without an injected locale the clock speaks the app's language in
    /// the person's region.
    @Test func theClockLocaleIsTheAppsLanguage() {
        let us = Locale(identifier: "en_US")
        #expect(LogClock.locale(for: .en, current: us) == us, "the person's own locale when it speaks the app's language")
        let chineseOnUS = LogClock.locale(for: .zh, current: us)
        #expect(chineseOnUS.language.languageCode?.identifier == "zh")
        #expect(chineseOnUS.region?.identifier == "US")
    }

    @Test func theDetailPageSaysTheSameWhyAsTheRow() {
        let row = SurfaceFixtures.rowPermission()
        let face = SurfaceFixtures.rowModel(row, lang: .en)
        let detail = DetailModel.make(row: row, lang: .en, nowMs: SurfaceFixtures.nowMs)
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
        var row = session()
        row.lastEventMs = now - 45 * minute
        row.lastWord = "old"
        let detail = DetailModel.make(row: row, lang: .en, nowMs: now)
        #expect(detail.lastMessage == nil)
    }

    /// No placeholder rows: a fact Pulse does not have is not listed, and
    /// raw values are words.
    @Test func theDetailListsOnlyWhatItKnows() {
        var row = session()
        row.cwd = ""
        row.project = ""
        row.startedMs = 0
        let detail = DetailModel.make(row: row, lang: .en, nowMs: now)
        #expect(detail.facts.isEmpty, "\(detail.facts)")
    }
}

/// The defects a fresh audit turned up.
///
/// Each of these is a place where the code said something it had not
/// measured, dropped work it had been asked to do, or let a click reach
/// nothing without saying so.
final class RowErrorTests: XCTestCase {
    private func liveRow() -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Fix the auth module"
        row.liveProcess = true
        row.state = .running
        row.lastEventMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.source = .hooks
        return row
    }

    // MARK: D-2 · a fault is not crowded out

    /// A turn's last error is shown on the detail page, where
    /// it can be read in full — not guessed into a count.
    func testALastErrorIsTheDetailPagesError() {
        var row = liveRow()
        row.lastErrorText = "npm ERR! missing script: test"
        XCTAssertEqual(DetailModel.make(row: row, lang: .en, nowMs: row.lastEventMs).error, "npm ERR! missing script: test")
        XCTAssertNil(DetailModel.make(row: liveRow(), lang: .en, nowMs: row.lastEventMs).error)
    }

    func testNoErrorsIsNoFault() {
        let why = TrayRowModel.why(liveRow(), lang: .en, nowMs: liveRow().lastEventMs)
        XCTAssertFalse(why.contains("error"), why)
    }
}

/// VoiceOver speaks up only for a new wait — who and what it asks — and
/// says nothing when the count falls or holds.
@Suite("Wait announcement")
struct WaitAnnouncementTests {
    let now: Int64 = 1_800_000_000_000

    private func waiting(_ key: String, _ agent: AgentID, ask: String, since: Int64) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.state = .blocked(RowWait(kind: "Permission", ask: ask, sinceMs: since))
        return row
    }

    @Test func onlyARisingBlockedCountIsAnnounced() {
        let old = waiting("claude|a", .claude, ask: "Bash: npm test", since: now - 600_000)
        let new = waiting("gemini|b", .gemini, ask: "Edit: src/main.swift", since: now - 5_000)
        let rose = WaitAnnouncement.text(previousBlocked: 1, rows: [old, new], lang: .en)
        #expect(rose == "Gemini needs you: Edit: src/main.swift", "the newest wait, in its own words")
        let held = WaitAnnouncement.text(previousBlocked: 2, rows: [old, new], lang: .en)
        #expect(held == nil)
        let fell = WaitAnnouncement.text(previousBlocked: 2, rows: [old], lang: .en)
        #expect(fell == nil, "an answered wait is not announced")
        var running = AgentRow(rowKey: "codex|c", agent: .codex)
        running.state = .running
        let other = WaitAnnouncement.text(previousBlocked: 0, rows: [running], lang: .en)
        #expect(other == nil, "a running session is not announced")
        let first = WaitAnnouncement.text(previousBlocked: nil, rows: [old], lang: .en)
        #expect(first == nil, "the first scan is the baseline")
    }

    @Test func aWaitWithoutWordsSaysWhoAndInChinese() {
        var quiet = AgentRow(rowKey: "pi|a", agent: .pi)
        quiet.state = .blocked(RowWait(kind: "Waiting", sinceMs: now))
        let text = WaitAnnouncement.text(previousBlocked: 0, rows: [quiet], lang: .en)
        #expect(text == "Pi needs you")
        let zh = WaitAnnouncement.text(previousBlocked: 0, rows: [waiting("claude|a", .claude, ask: "Bash: ls", since: now)], lang: .zh)
        #expect(zh == "Claude 需要你：Bash: ls")
    }

    /// A row's VoiceOver label says its time in whole words.
    @Test func aRowsSpokenTimeIsInFullUnits() {
        var row = waiting("claude|a", .claude, ask: "Bash: npm test", since: now - 4 * 60_000)
        row.task = "Fix the flaky test"
        let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        #expect(face.age == "4m", "the drawn time stays compact")
        #expect(face.accessibilityLabel.contains("4 minutes"), "\(face.accessibilityLabel)")
        #expect(!face.accessibilityLabel.contains("4m"), "\(face.accessibilityLabel)")
        var ran = AgentRow(rowKey: "codex|b", agent: .codex)
        ran.state = .running
        ran.turnStartMs = now - 20_000
        ran.lastEventMs = now - 20_000
        let young = TrayRowModel.rowTimeSpoken(ran, nowMs: now, lang: .en)
        #expect(young == "less than a minute")
        ran.state = .yourTurn(sinceMs: now - 12 * 60_000)
        ran.lastEventMs = now - 12 * 60_000
        let ago = TrayRowModel.rowTimeSpoken(ran, nowMs: now, lang: .en)
        #expect(ago == "12 minutes ago")
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
        let titles = menu.items.map { $0.title }
        #expect(titles.count == 3, "Pulse, Edit, Window")
        let zh = MainMenu.make(lang: .zh).items.map { $0.title }
        #expect(zh.contains(L10n.t(.menuEdit, .zh)))
    }
}

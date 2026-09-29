import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 17.0 · Why — the one sentence that says which evidence lit a row, the
/// session's record under it (23.0: its spans in `SessionLog`), and the tray
/// row's face as a value.
final class WhyTests: XCTestCase {
    private let now: Int64 = 1_800_000_000_000
    private let minute: Int64 = 60_000

    // MARK: - The why line

    private func narrator(_ lang: ResolvedLanguage = .en) -> RowNarrator { RowNarrator(lang: lang, nowMs: now) }

    func testAHookWaitNamesItsEvidence() throws {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.waiting = true
        row.waitKind = "Permission"
        row.waitSignal = .hooks
        row.waitSinceMs = now - 8 * minute
        let why = try XCTUnwrap(narrator().whyLine(row))
        XCTAssertTrue(why.contains("Claude"))
        XCTAssertTrue(why.contains(L10n.t(.kindPermission, .en)))
        XCTAssertFalse(why.contains(L10n.t(.whyHookFront, .en)))
        row.waitRaisedInFront = true
        XCTAssertTrue(try XCTUnwrap(narrator().whyLine(row)).hasSuffix(L10n.t(.whyHookFront, .en)),
                      "says why there was no banner")
    }

    func testAPendingWaitNamesTheStepItStoppedAt() throws {
        var row = AgentRow(rowKey: "cursor|s1", agent: .cursor)
        row.waiting = true
        row.waitKind = "Permission"
        row.waitSignal = .pending
        row.tool = "request_approval"
        XCTAssertTrue(try XCTUnwrap(narrator().whyLine(row)).contains("Cursor"))
    }

    func testYourTurnSaysHowToClearIt() throws {
        var row = AgentRow(rowKey: "codex|s1", agent: .codex)
        row.yourTurn = true
        row.turnSinceMs = now - 3 * minute
        let why = try XCTUnwrap(narrator(.zh).whyLine(row))
        XCTAssertTrue(why.hasPrefix("轮到你"))
        XCTAssertFalse(why.contains("刚刚前"))
    }

    func testARunningRowNeedsNoExplaining() {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.liveProcess = true
        row.task = "Refactor the settings panes"
        XCTAssertNil(narrator().whyLine(row))
        row.waiting = true // a wait with no known signal is not explained by guessing
        XCTAssertNil(narrator().whyLine(row))
    }

    func testTheWhyCardIsTheSessionsSpansNewestFirstAndBounded() {
        let row = SurfaceFixtures.rowPermission()
        let spans = (0..<30).map { index -> TimelineSpan in
            let start = now - Int64(30 - index) * minute
            let last = index == 29
            return TimelineSpan(
                state: last ? .blocked : .running, evidence: last ? .hook : .harvest,
                kind: last ? "Permission" : "", startMs: start,
                endMs: last ? nil : start + minute, note: last ? "Bash: npm test" : ""
            )
        }
        let card = WhyCardModel.make(row: row, spans: spans, narrator: narrator())
        XCTAssertEqual(card.lines.count, WhyCardModel.maxLines)
        XCTAssertTrue(card.lines[0].hasPrefix(String(format: L10n.t(.agoFormat, .en), DurationFormat.label(seconds: 60, lang: .en))))
        XCTAssertTrue(card.lines[0].contains(L10n.t(.kindPermission, .en)), card.lines[0])
        XCTAssertTrue(card.lines[0].hasSuffix("Bash: npm test"), "a block says what was asked")
    }

    /// The note a blocked span keeps is bounded and sanitized on the way in.
    func testABlockedSpanKeepsTheRequestSanitizedAndBounded() throws {
        var before = AgentRow(rowKey: "claude|s1", agent: .claude)
        before.liveProcess = true
        var after = before
        after.waiting = true
        after.waitSignal = .hooks
        after.waitKind = "Permission"
        after.waitSinceMs = now - minute
        after.waitMessage = "Bash: curl -H 'Authorization: Bearer sk-abcdefghijklmnopqrstu' api " + String(repeating: "x", count: 400)
        let edge = try XCTUnwrap(SessionTimeline.transitions(previous: [before], current: [after], nowMs: now).first)
        XCTAssertFalse(edge.note.contains("sk-abcdefghijklmnopqrstu"))
        XCTAssertLessThanOrEqual(edge.note.count, SessionLog.noteLimit)
    }

    /// 21.0: the orange states explain themselves.
    func testOrangeRowsSayWhy() throws {
        var process = AgentRow(rowKey: "cursor|p", agent: .cursor)
        process.liveProcess = true
        XCTAssertTrue(try XCTUnwrap(narrator().whyLine(process)).contains("Cursor"))

        var stalled = AgentRow(rowKey: "claude|s2", agent: .claude)
        stalled.task = "Long build"
        stalled.isStalled = true
        stalled.harvestMs = Int64(Date().timeIntervalSince1970 * 1000) - 25 * 60_000
        let rule = RowNarrator(lang: .en, stallMinutes: 20)
        let why = try XCTUnwrap(rule.whyLine(stalled))
        XCTAssertTrue(why.contains("20"), "names the threshold it crossed: \(why)")

        var failed = AgentRow(rowKey: "codex|s3", agent: .codex)
        failed.task = "Migrate"
        failed.outcome = "failed"
        XCTAssertTrue(try XCTUnwrap(narrator().whyLine(failed)).contains("failed"))
    }

    // MARK: - The tray row's face

    func testAPermissionRowShoutsAndOffersItsActions() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowPermission(), lang: .en)
        XCTAssertEqual(model.lamp, .waiting)
        XCTAssertEqual(model.chip?.kind, .waiting)
        XCTAssertNotEqual(model.accent, .none)
        // 21.0: at most two visible verbs — answer it, or put it down.
        XCTAssertEqual(model.strip.map(\.action), [.focus, .dismiss])
        XCTAssertTrue(model.stripAlwaysVisible)
        XCTAssertEqual(model.menu.map(\.action), [.details, .focus, .dismiss, .mute],
                       "every verb is in the menu once")
        XCTAssertNotNil(model.why)
    }

    func testYourTurnIsQuiet() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowTurn(), lang: .zh)
        XCTAssertNotEqual(model.lamp, .waiting)
        XCTAssertEqual(model.chip, TrayRowModel.Chip(kind: .recent, label: "轮到你"))
        XCTAssertEqual(model.accent, .none, "no gutter: the gutter is for blocked")
        XCTAssertFalse(model.stripAlwaysVisible)
        XCTAssertTrue(model.accessibilityLabel.contains("轮到你"))
    }

    func testAProcessOnlyRowPointsAtSupportHealth() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowProcessOnly(), lang: .en)
        XCTAssertEqual(model.lamp, .process)
        XCTAssertTrue(model.strip.isEmpty, "only a wait shows verbs without a click")
        XCTAssertFalse(model.stripAlwaysVisible)
        XCTAssertTrue(model.menu.contains { $0.action == .supportHealth })
        XCTAssertTrue(model.whyInline || model.why == nil, "an orange row explains itself")
        XCTAssertEqual(model.accessibilityHint, L10n.t(.processOnlyHint, .en))
        XCTAssertFalse(model.canPrimary)
    }

    func testEveryRowFixtureSpeaksBothLanguages() {
        for lang in [ResolvedLanguage.en, .zh] {
            for fixture in SurfaceFixtures.all(lang: lang) {
                if case .row(let model, _, _) = fixture.value {
                    XCTAssertFalse(model.hero.isEmpty, fixture.name)
                    XCTAssertFalse(model.accessibilityLabel.isEmpty, fixture.name)
                    XCTAssertEqual(model.lang, lang)
                }
            }
        }
    }
}

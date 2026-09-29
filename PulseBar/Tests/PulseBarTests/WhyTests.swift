import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseRespond

/// 17.0 · Why — the history that remembers what the hooks said, the one
/// sentence that says which evidence lit a row, the export that turns a real
/// sequence into a fixture, and the tray row's face as a value.
final class WhyTests: XCTestCase {
    private let now: Int64 = 1_800_000_000_000
    private let minute: Int64 = 60_000

    private func source(_ lines: [String]) -> AttentionIO.Source {
        AttentionIO.Source(text: AttentionProtocol.header + lines.joined(separator: "\n") + "\n")
    }

    private func line(_ kind: String, ago: Int64, message: String = "", session: String = "s1", front: String = "") -> String {
        ["claude", kind, "\(now - ago)", message, session, "/Users/me/code/app", "", front].joined(separator: "\t")
    }

    // MARK: - History

    func testHistoryKeepsEverySequenceNotJustTheLastEvent() {
        var history = AttentionHistory()
        let changed = history.ingest([source([
            line("permission", ago: 5 * minute, message: "Bash: npm test"),
            line("done", ago: 4 * minute),
            line("stop", ago: 1 * minute, message: "All green."),
        ])], nowMs: now)
        XCTAssertTrue(changed)
        let events = history.history(agent: "claude", session: "s1")
        XCTAssertEqual(events.map(\.kind), ["permission", "done", "turn"], "stored as v3 kinds, in order")
        XCTAssertEqual(events.last?.message, "All green.")
    }

    func testTheSameFileTwiceChangesNothing() {
        var history = AttentionHistory()
        let lines = [line("permission", ago: minute, message: "x")]
        history.ingest([source(lines)], nowMs: now)
        XCTAssertFalse(history.ingest([source(lines)], nowMs: now), "an unchanged scan writes nothing")
    }

    func testHistoryIsBoundedAndForgetsTheSilent() {
        var history = AttentionHistory()
        let many = (0..<(AttentionHistory.perKey + 10)).map { line("turn", ago: Int64(100 - $0) * 1_000) }
        history.ingest([source(many)], nowMs: now)
        XCTAssertEqual(history.history(agent: "claude", session: "s1").count, AttentionHistory.perKey)

        history.ingest([source([line("permission", ago: minute, session: "old")])], nowMs: now)
        history.ingest([], nowMs: now + AttentionHistory.retentionMs + 2 * minute)
        XCTAssertTrue(history.events.isEmpty, "a day of silence forgets the session")
    }

    func testHistoryNeverKeepsWhatTheProtocolRejects() {
        var history = AttentionHistory()
        history.ingest([source([
            ["claude", "totally_made_up", "\(now)", "nope", "s1", ""].joined(separator: "\t"),
            ["not-an-agent", "permission", "\(now)", "nope", "s1", ""].joined(separator: "\t"),
        ])], nowMs: now)
        XCTAssertTrue(history.events.isEmpty)
    }

    func testHistoryIsSanitizedOnTheWayIn() {
        var history = AttentionHistory()
        history.ingest([source([line("permission", ago: minute, message: "Bash: curl -H 'Authorization: Bearer sk-abcdefghijklmnopqrstu' api")])], nowMs: now)
        let message = history.history(agent: "claude", session: "s1").first?.message ?? ""
        XCTAssertFalse(message.contains("sk-abcdefghijklmnopqrstu"))
    }

    /// 22.0: every line is this Mac's, so a `host` column does not split a
    /// session's history in two.
    func testAHostColumnDoesNotSplitASessionsHistory() {
        var history = AttentionHistory()
        var named = line("turn", ago: minute / 2).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        named[6] = "devbox"
        history.ingest([source([line("permission", ago: minute), named.joined(separator: "\t")])], nowMs: now)
        XCTAssertEqual(history.history(agent: "claude", session: "s1").map(\.kind), ["permission", "turn"])
    }

    func testTheStoreWritesAPrivateFileNextToTheAttentionFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-why-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        AttentionIO.pathOverride = home.appendingPathComponent("attention.tsv")
        AttentionHistoryStore.reset()
        defer {
            AttentionIO.pathOverride = nil
            AttentionHistoryStore.reset()
            try? FileManager.default.removeItem(at: home)
        }
        AttentionHistoryStore.ingest([source([line("permission", ago: minute)])], nowMs: now)
        let attributes = try FileManager.default.attributesOfItem(atPath: AttentionHistory.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        AttentionHistoryStore.reset()
        XCTAssertEqual(AttentionHistoryStore.current.history(agent: "claude", session: "s1").count, 1, "survives a restart")
    }

    // MARK: - Export → fixture

    func testAnExportReplaysToTheSameConclusion() {
        var history = AttentionHistory()
        history.ingest([source([
            line("permission", ago: 5 * minute, message: "Bash: npm test"),
            line("stop", ago: 1 * minute, message: "All green."),
        ])], nowMs: now)
        let fixture = AttentionHistory.fixture(history.history(agent: "claude", session: "s1"))
        XCTAssertTrue(fixture.hasPrefix(AttentionProtocol.header))
        XCTAssertFalse(fixture.contains("/Users/me"), "a fixture needs to match rows, not know where the code lives")
        let lines = fixture.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertTrue(lines.allSatisfy {
            $0.split(separator: "\t", omittingEmptySubsequences: false).count == AttentionProtocol.columnCount
        })
        let replayed = AttentionReader.parse(fixture, nowMs: now)
        XCTAssertEqual(replayed.count, 1)
        XCTAssertTrue(replayed[0].isTurn, "the replay reaches the conclusion the live reader reached")
    }

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

    func testTheDetailsTimelineIsNewestFirstAndBounded() {
        let row = SurfaceFixtures.rowPermission()
        let events = (0..<30).map {
            AttentionHistory.Event(agent: "claude", kind: "turn", tsMs: now - Int64(30 - $0) * minute, session: row.sessionID)
        }
        let card = WhyCardModel.make(row: row, history: events, narrator: narrator())
        XCTAssertEqual(card.lines.count, WhyCardModel.maxLines)
        XCTAssertEqual(card.eventCount, 30)
        XCTAssertTrue(card.lines[0].hasPrefix(String(format: L10n.t(.agoFormat, .en), DurationFormat.label(seconds: 60, lang: .en))))
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
        XCTAssertEqual(model.menu.map(\.action), [.focus, .dismiss, .snooze],
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

    func testASnoozedWaitKeepsItsPlaceAndCanBeUndone() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowSnoozed(), lang: .en, snoozeLabel: "Later · 12m")
        XCTAssertEqual(model.chip, TrayRowModel.Chip(kind: .snoozed, label: "Later · 12m"))
        XCTAssertEqual(model.accent, .snoozed)
        XCTAssertTrue(model.strip.contains { $0.action == .unsnooze })
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

    func testRespondOffersDenyAndReviewNeverAllow() {
        let model = TrayRowModel.make(TrayRowModel.Input(
            row: SurfaceFixtures.rowPermission(),
            narrator: narrator(),
            respondOffered: true,
            fateNote: "should not show while an answer is still possible"
        ))
        XCTAssertEqual(model.strip.map(\.action), [.respondReview, .respondDeny])
        XCTAssertNil(model.fateNote)
        XCTAssertFalse(model.strip.contains { $0.title.lowercased().contains("allow") },
                       "Allow lives only beside the full request")
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

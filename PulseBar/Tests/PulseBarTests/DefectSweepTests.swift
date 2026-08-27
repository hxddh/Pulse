import XCTest
@testable import PulseBar

/// 2.3 — the defects a fresh audit at the 2.2 baseline turned up.
///
/// Each of these is a place where the code said something it had not
/// measured, dropped work it had been asked to do, or let a click reach
/// nothing without saying so.
final class DefectSweepTests: XCTestCase {

    @MainActor
    private func store(_ lang: AppLanguage = .en) -> StatusStore {
        let store = StatusStore()
        store.language = lang
        return store
    }

    private func liveRow() -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Fix the auth module"
        row.liveProcess = true
        row.harvestMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.observationSource = .session
        return row
    }

    // MARK: D-1 · a token pair never invents the half nobody reported

    @MainActor
    func testOnlyTheMeasuredSideOfTheTokenPairIsPrinted() {
        let s = store()
        // The failure this replaces: `compactToken` returns "" for 0 and every
        // call site turned that back into a literal 0, so an agent publishing
        // output tokens and not input claimed the turn consumed no input.
        XCTAssertEqual(s.tokenPair(input: 0, output: 4_200), "↓4.2k")
        XCTAssertEqual(s.tokenPair(input: 1_200, output: 0), "↑1.2k")
        XCTAssertEqual(s.tokenPair(input: 1_200, output: 4_200), "↑1.2k ↓4.2k")
    }

    @MainActor
    func testNeitherSideReportedIsNoFactAtAll() {
        XCTAssertEqual(store().tokenPair(input: 0, output: 0), "")
    }

    @MainActor
    func testEachScopeKeepsSayingWhichNumberItIs() {
        // Two token numbers that disagree are a bug report waiting to happen
        // unless each says its span — losing the scope on the one-sided
        // phrasing would have reintroduced exactly that.
        let s = store()
        let latest = s.tokenPair(input: 0, output: 900, scope: .latestCall)
        let reported = s.tokenPair(input: 0, output: 900, scope: .reported)
        XCTAssertTrue(latest.contains("Latest model call"), latest)
        XCTAssertTrue(reported.contains("Agent reported"), reported)
        XCTAssertNotEqual(latest, reported)
    }

    @MainActor
    func testTheRowNeverShowsAZeroItDidNotMeasure() {
        let s = store()
        var row = liveRow()
        row.tokensOut = 4_200
        XCTAssertFalse(s.rowWorkLine(row).contains("↑0"), s.rowWorkLine(row))
        XCTAssertTrue(s.rowWorkLine(row).contains("↓4.2k"))
    }

    // MARK: D-2 · a fault is not crowded out by motion

    @MainActor
    func testTheErrorCountSurvivesAnActiveChange() {
        let s = store()
        var row = liveRow()
        row.sessionErrors = 7
        row.activityChange = .toolChanged
        row.activityChangedMs = row.harvestMs
        // The hole this closes: the observation line stood aside for any
        // change, the signal line's companion sat inside a block
        // `storyOwnsChange` empties for every titled row, and the story line
        // never mentions errors. Seven errors therefore appeared on no line.
        XCTAssertTrue(s.rowObservationLine(row).contains("7"), s.rowObservationLine(row))
    }

    @MainActor
    func testAnErrorChangeIsNotAlsoStatedAsATotal() {
        let s = store()
        var row = liveRow()
        row.sessionErrors = 7
        row.activityChange = .errors(2)
        row.activityChangedMs = row.harvestMs
        // The delta is the news; repeating the total is the same fact twice.
        XCTAssertFalse(s.rowObservationLine(row).contains("7"), s.rowObservationLine(row))
    }

    @MainActor
    func testAQuietRowStillStatesItsErrors() {
        let s = store()
        var row = liveRow()
        row.sessionErrors = 7
        XCTAssertTrue(s.rowObservationLine(row).contains("7"))
    }

    @MainActor
    func testOnlyOneLineOwnsTheFault() {
        let s = store()
        var row = liveRow()
        row.sessionErrors = 7
        row.activityChange = .toolChanged
        row.activityChangedMs = row.harvestMs
        XCTAssertFalse(
            s.rowSignalLine(row).contains("7"),
            "the observation line owns it; two owners is what lost it"
        )
    }

    @MainActor
    func testAProcessOnlyRowKeepsItsFaultOnTheSignalLine() {
        let s = store()
        var row = AgentRow(rowKey: "codex|p1", agent: .codex)
        row.liveProcess = true
        row.observationSource = .process
        row.harvestMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.sessionErrors = 3
        XCTAssertTrue(row.isProcessOnly, "no title and no live tool")
        XCTAssertEqual(s.rowObservationLine(row), "", "this row has no observation line")
        XCTAssertTrue(s.rowSignalLine(row).contains("3"), s.rowSignalLine(row))
    }

    @MainActor
    func testTheBetterScopedCountWins() {
        let s = store()
        var row = liveRow()
        row.errors = 2
        row.sessionErrors = 9
        // Same fact over different spans: emit the wider one, never both.
        let fault = s.faultFact(row)
        XCTAssertTrue(fault.contains("9"), fault)
        XCTAssertFalse(fault.contains("2"), fault)
    }

    @MainActor
    func testNoErrorsIsNoFault() {
        XCTAssertEqual(store().faultFact(liveRow()), "")
    }

    // MARK: D-3 · a coalesced refresh keeps its scope

    @MainActor
    func testMergingTwoScopedRefreshesKeepsBoth() {
        var pending = StatusStore.PendingRefresh(
            reason: "permission-cursor",
            agentFilter: [.cursor]
        )
        pending.absorb(reason: "permission-cline", agentFilter: [.cline])
        XCTAssertEqual(pending.agentFilter, [.cursor, .cline])
        XCTAssertEqual(pending.reason, "permission-cline")
    }

    @MainActor
    func testAFullScanAbsorbsAScopedOne() {
        var pending = StatusStore.PendingRefresh(
            reason: "permission-cursor",
            agentFilter: [.cursor]
        )
        pending.absorb(reason: "timer", agentFilter: nil)
        XCTAssertNil(pending.agentFilter, "a full scan already covers the scoped one")

        var full = StatusStore.PendingRefresh(reason: "timer", agentFilter: nil)
        full.absorb(reason: "permission-cursor", agentFilter: [.cursor])
        XCTAssertNil(full.agentFilter, "and narrowing it afterwards would drop the rest")
    }

    // MARK: D-4 · the files carrying the user's words are private

    func testAPrivateFileIsSixHundredBeforeItsBytesExist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-private-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("ledger.json")
        var temporaryModes: [Int] = []
        PrivateFile.inspectTemporaryFileForTesting = { path in
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            if let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue {
                temporaryModes.append(mode)
            }
        }
        defer {
            PrivateFile.inspectTemporaryFileForTesting = nil
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertTrue(PrivateFile.write(Data("hello".utf8), to: url))
        XCTAssertEqual(temporaryModes, [0o600], "0600 at creation, not after the bytes are visible")
        let published = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((published[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["ledger.json"],
            "the temporary file is renamed into place, never left behind"
        )
    }

    func testAnOlderWorldReadableFileIsBroughtDown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-tighten-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("attention.tsv")
        // What every install made before this rule has on disk.
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.path,
            contents: Data("# pulse-attention v2\n".utf8),
            attributes: [.posixPermissions: 0o644]
        ))

        let fd = url.path.withCString { open($0, O_RDWR) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        PrivateFile.tighten(fileDescriptor: fd)
        close(fd)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTheLedgerRoundTripsThroughItsPrivateWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("attention-ledger.json")

        var ledger = AttentionLedger()
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Something the user actually typed"
        row.waiting = true
        ledger.observe(row: row, nowMs: 1_800_000_000_000)
        ledger.save(to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(AttentionLedger.load(from: url).activeKeys, ["claude|s1"])
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
        for key in [L10n.Key.focusFailed, .respondWriteFailed, .respondRefused, .respondRequestGone] {
            XCTAssertFalse(L10n.t(key, .en).isEmpty, "\(key)")
            XCTAssertFalse(L10n.t(key, .zh).isEmpty, "\(key)")
            XCTAssertNotEqual(L10n.t(key, .en), L10n.t(key, .zh), "\(key)")
        }
    }
}

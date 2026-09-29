import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

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
        row.state = .running
        row.harvestMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.source = .session
        return row
    }

    // MARK: D-2 · a fault is not crowded out

    /// 23.0: D-1 (token pairs) went with the facts; D-2 is one rule now —
    /// a row that reported errors explains its orange lamp with them.
    func testARowThatReportedErrorsSaysSo() {
        var row = liveRow()
        row.errors = 7
        let why = Explain.make(row, lang: .en, nowMs: row.harvestMs).why
        XCTAssertTrue(why.contains("7"), why)
    }

    func testNoErrorsIsNoFault() {
        let why = Explain.make(liveRow(), lang: .en, nowMs: liveRow().harvestMs).why
        XCTAssertFalse(why.contains("error"), why)
    }

    // MARK: D-3 · a coalesced refresh keeps its scope

    @MainActor
    func testMergingTwoScopedRefreshesKeepsBoth() {
        var pending = ScanEngine.PendingRefresh(
            reason: "permission-cursor",
            agentFilter: [.cursor]
        )
        pending.absorb(reason: "permission-cline", agentFilter: [.cline])
        XCTAssertEqual(pending.agentFilter, [.cursor, .cline])
        XCTAssertEqual(pending.reason, "permission-cline")
    }

    @MainActor
    func testAFullScanAbsorbsAScopedOne() {
        var pending = ScanEngine.PendingRefresh(
            reason: "permission-cursor",
            agentFilter: [.cursor]
        )
        pending.absorb(reason: "timer", agentFilter: nil)
        XCTAssertNil(pending.agentFilter, "a full scan already covers the scoped one")

        var full = ScanEngine.PendingRefresh(reason: "timer", agentFilter: nil)
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

    func testTheSessionLogRoundTripsThroughItsPrivateWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session-log.json")

        var log = SessionLog()
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Something the user actually typed"
        row.state = .blocked(RowWait(kind: "Permission", signal: .hooks))
        log.reconcileWaits(rows: [row], released: [], nowMs: 1_800_000_000_000)
        XCTAssertTrue(SessionLogFile.save(log, to: url, nowMs: 1_800_000_000_100))

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let loaded = SessionLogFile.load(from: url, nowMs: 1_800_000_000_200)
        XCTAssertEqual(loaded.waitingKeys, ["claude|s1"])
        XCTAssertEqual(loaded.savedAtMs, 1_800_000_000_100, "the write is stamped, for closing spans after a quit")
        XCTAssertTrue(loaded.hasSameDurableState(as: log))
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

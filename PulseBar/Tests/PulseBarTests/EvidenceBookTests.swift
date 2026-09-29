import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseManaged
@testable import PulseRespond

/// 14.0 · Proof — evidence belongs to the working copy. The book's key, the
/// per-directory ruler, the tray counts (never a pass for what did not run),
/// persistence identity, interrupted-at-quit, and external Candidates.
/// No test here starts a check process.
final class EvidenceBookTests: XCTestCase {
    private var base: URL!
    private let t0: Int64 = 1_800_000_000_000

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-evidence-\(UUID().uuidString)", isDirectory: true)
        EvidenceBook.directoryOverride = base.appendingPathComponent("evidence", isDirectory: true)
        Mission.directoryOverride = base.appendingPathComponent("missions", isDirectory: true)
        ManagedSession.stateDirectoryOverride = base.appendingPathComponent("managed", isDirectory: true)
    }

    override func tearDownWithError() throws {
        EvidenceBook.directoryOverride = nil
        Mission.directoryOverride = nil
        ManagedSession.stateDirectoryOverride = nil
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    @MainActor
    private func evidence(_ outcome: AcceptanceEvidence.Outcome, checkID: String?, root: String = "/tmp/proj") -> AcceptanceEvidence {
        var e = AcceptanceEvidence.make(
            command: "swift test", cwd: root, startedAtMs: t0, finishedAtMs: t0 + 1,
            stdout: Data(), stderr: Data(), exitCode: outcome == .passed ? 0 : 1,
            preFingerprint: CodeFingerprint(sha256: "a"), postFingerprint: CodeFingerprint(sha256: "a"),
            checkID: checkID
        )
        e.outcome = outcome
        return e
    }

    // MARK: - Identity

    @MainActor
    func testOneWorkingCopyHasOneKeyHoweverItIsSpelled() {
        XCTAssertEqual(EvidenceBook.key("/tmp/proj/"), EvidenceBook.key("/tmp/proj"))
        XCTAssertEqual(EvidenceBook.key("/tmp/proj/sub/.."), EvidenceBook.key("/tmp/proj"))
        XCTAssertEqual(EvidenceBook.key(""), "", "no root is never a page")
    }

    // MARK: - The ruler is the opt-in

    @MainActor
    func testSettingChecksIsTheOptInAndClearingThemRemovesThePage() {
        let book = EvidenceBook()
        XCTAssertTrue(book.checks(for: "/tmp/proj").isEmpty)
        book.setChecks([Mission.Check(id: "c1", command: "swift test")], for: "/tmp/proj/")
        XCTAssertEqual(book.checks(for: "/tmp/proj").map(\.command), ["swift test"])
        let file = EvidenceBook.directory().appendingPathComponent(EvidenceBook.fileName(for: EvidenceBook.key("/tmp/proj")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        book.setChecks([], for: "/tmp/proj")
        XCTAssertNil(book.records[EvidenceBook.key("/tmp/proj")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "an empty page leaves no file")
    }

    @MainActor
    func testAPathWithNoRootIsNeverChecked() {
        let book = EvidenceBook(persists: false)
        book.setChecks([Mission.Check(id: "c1", command: "true")], for: "")
        book.runChecks([Mission.Check(id: "c1", command: "true")], at: "")
        XCTAssertTrue(book.records.isEmpty)
        XCTAssertFalse(book.isBusy(at: ""))
    }

    // MARK: - Counts, never a verdict

    @MainActor
    func testTheSummaryNeverCountsWhatDidNotRunOrCouldNotBeConfirmed() {
        let book = EvidenceBook(persists: false)
        let checks = [
            Mission.Check(id: "c1", command: "swift test"),
            Mission.Check(id: "c2", command: "make lint"),
            Mission.Check(id: "c3", command: "make e2e"),
        ]
        book.setChecks(checks, for: "/tmp/proj")
        XCTAssertEqual(book.summary(of: checks, at: "/tmp/proj"), .init(total: 3))

        // c1 failed, c2 passed but the code has not been measured yet, c3 never ran.
        book.adopt(evidence: [evidence(.failed, checkID: "c1"), evidence(.passed, checkID: "c2")], at: "/tmp/proj")
        let summary = book.summary(of: checks, at: "/tmp/proj")
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.failing, 1)
        XCTAssertEqual(summary.passing, 0, "a pass the code was not re-measured against is not yet a pass")
    }

    @MainActor
    func testEvidenceWithoutACheckIDAnswersNoCheck() {
        let book = EvidenceBook(persists: false)
        let checks = [Mission.Check(id: "c1", command: "swift test")]
        book.adopt(evidence: [evidence(.failed, checkID: nil)], at: "/tmp/proj")
        XCTAssertEqual(book.summary(of: checks, at: "/tmp/proj"), .init(total: 1))
    }

    // MARK: - Persistence

    @MainActor
    func testAPageSurvivesARestartAndAnInterruptedCheckIsNotForgotten() throws {
        let book = EvidenceBook()
        book.setChecks([Mission.Check(id: "c1", command: "swift test")], for: "/tmp/proj")
        book.adopt(evidence: [evidence(.failed, checkID: "c1")], at: "/tmp/proj")

        // Simulate a quit with a check in flight.
        let key = EvidenceBook.key("/tmp/proj")
        var record = book.record(for: key)
        record.runningCheck = RunningCheck(command: "make lint", cwd: key, startedAtMs: t0, checkID: "c2")
        let file = EvidenceBook.directory().appendingPathComponent(EvidenceBook.fileName(for: key))
        try JSONEncoder().encode(record).write(to: file)

        let again = EvidenceBook()
        again.loadFromDisk()
        XCTAssertEqual(again.checks(for: "/tmp/proj").map(\.id), ["c1"])
        XCTAssertNil(again.runningCheck(for: "/tmp/proj"))
        XCTAssertEqual(again.evidence(for: "/tmp/proj").map(\.outcome), [.failed, .interrupted])
        XCTAssertEqual(again.evidence(for: "/tmp/proj").last?.checkID, "c2")
    }

    @MainActor
    func testARenamedPageIsRefused() throws {
        let book = EvidenceBook()
        book.setChecks([Mission.Check(id: "c1", command: "swift test")], for: "/tmp/proj")
        let dir = EvidenceBook.directory()
        try FileManager.default.moveItem(
            at: dir.appendingPathComponent(EvidenceBook.fileName(for: EvidenceBook.key("/tmp/proj"))),
            to: dir.appendingPathComponent(EvidenceBook.fileName(for: EvidenceBook.key("/tmp/other")))
        )
        let again = EvidenceBook()
        again.loadFromDisk()
        XCTAssertTrue(again.records.isEmpty, "a page whose root does not hash to its name is not trusted")
    }

    @MainActor
    func testAPageFromANewerSchemaIsRefused() throws {
        var record = EvidenceBook.Record(root: EvidenceBook.key("/tmp/proj"))
        record.schemaVersion = EvidenceBook.Record.currentSchemaVersion + 1
        record.checks = [Mission.Check(id: "c1", command: "swift test")]
        let dir = EvidenceBook.directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: dir.appendingPathComponent(EvidenceBook.fileName(for: record.root)))
        let book = EvidenceBook()
        book.loadFromDisk()
        XCTAssertTrue(book.records.isEmpty)
    }

    @MainActor
    func testAdoptionKeepsTheBound() {
        let book = EvidenceBook(persists: false)
        let many = (0..<(ManagedSession.maxAcceptanceEvidence + 5)).map { _ in evidence(.failed, checkID: nil) }
        book.adopt(evidence: many, at: "/tmp/proj")
        XCTAssertEqual(book.evidence(for: "/tmp/proj").count, ManagedSession.maxAcceptanceEvidence)
    }

    // MARK: - External Candidates

    @MainActor
    func testAnObservedWorkingCopyJoinsAndLeavesAMission() throws {
        let fleet = ManagedFleet()
        fleet.startAction = { _ in }
        fleet.create(Mission.Model(id: "m1", repoRoot: "/r", goal: "A", checks: [Mission.Check(id: "c1", command: "swift test")], createdMs: t0))
        fleet.dispatch(candidate: ManagedSession.Model(id: "s1", task: "A", root: "/tmp/w-s1", isWorktree: true, nowMs: t0), missionID: "m1")

        fleet.addExternal(missionID: "m1", root: "/tmp/mine/", label: "Codex")
        fleet.addExternal(missionID: "m1", root: "/tmp/mine", label: "Codex")
        let externals = try XCTUnwrap(fleet.mission(id: "m1")?.externals)
        XCTAssertEqual(externals.count, 1, "one working copy joins once")
        XCTAssertEqual(externals[0].root, EvidenceBook.key("/tmp/mine"))
        XCTAssertEqual(externals[0].revision, 1, "judged by the contract as it stood when it joined")
        XCTAssertEqual(Mission.loadAll().first?.externals.count, 1, "on disk")

        fleet.addExternal(missionID: "m1", root: "/tmp/w-s1", label: "self")
        XCTAssertEqual(fleet.mission(id: "m1")?.externals.count, 1, "a Candidate Pulse launched is not external")

        fleet.choose(missionID: "m1", candidateID: externals[0].id)
        XCTAssertEqual(fleet.mission(id: "m1")?.chosenCandidateID, externals[0].id)
        fleet.removeExternal(missionID: "m1", externalID: externals[0].id)
        XCTAssertTrue(fleet.mission(id: "m1")?.externals.isEmpty == true)
        XCTAssertNil(fleet.mission(id: "m1")?.chosenCandidateID, "leaving clears the choice")
    }

    @MainActor
    func testAMissionHeldOnlyByAnExternalSurvivesAndGoesWhenItLeaves() throws {
        let fleet = ManagedFleet()
        fleet.startAction = { _ in }
        fleet.create(Mission.Model(id: "m1", repoRoot: "/r", goal: "A", createdMs: t0))
        fleet.addExternal(missionID: "m1", root: "/tmp/mine", label: "Codex")
        fleet.dropIfEmpty(missionID: "m1")
        XCTAssertNotNil(fleet.mission(id: "m1"))

        let again = ManagedFleet()
        again.startAction = { _ in }
        again.reattachFromDisk()
        let external = try XCTUnwrap(again.mission(id: "m1")?.externals.first)
        again.removeExternal(missionID: "m1", externalID: external.id)
        XCTAssertNil(again.mission(id: "m1"))
        XCTAssertTrue(Mission.loadAll().isEmpty)
    }

    // MARK: - The tray fact

    @MainActor
    func testTheTrayFactIsCountsOnlyAndSilentWithoutAResult() {
        var row = AgentRow(rowKey: "codex|s1", agent: .codex)
        row.workspaceRoot = "/tmp/proj"
        let key = EvidenceBook.key("/tmp/proj")
        XCTAssertEqual(RowNarrator(lang: .en).proofFact(row), "")
        XCTAssertEqual(
            RowNarrator(lang: .en, proofSummaries: [key: .init(total: 3, passing: 2, failing: 1)]).proofFact(row),
            "checks 2/3 passing · 1 failing"
        )
        XCTAssertEqual(
            RowNarrator(lang: .zh, proofSummaries: [key: .init(total: 3, passing: 1, stale: 1)]).proofFact(row),
            "检查 1/3 通过 · 1 已过期"
        )
        var remote = row
        remote.host = "devbox"
        remote.observationSource = .remote
        XCTAssertEqual(
            RowNarrator(lang: .en, proofSummaries: [key: .init(total: 3, passing: 3)]).proofFact(remote),
            "", "a remote path names a directory on another machine"
        )
    }
}

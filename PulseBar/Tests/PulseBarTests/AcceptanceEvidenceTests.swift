import XCTest
@testable import PulseBar
@testable import PulseCore

final class AcceptanceEvidenceTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-evidence-\(UUID())")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git(["init", "-q"])
        try Data("one\n".utf8).write(to: repo.appendingPathComponent("tracked"))
        git(["add", "tracked"])
        git(["-c", "user.name=Pulse", "-c", "user.email=pulse@example.invalid", "commit", "-qm", "base"])
    }

    override func tearDownWithError() throws { if let repo { try? FileManager.default.removeItem(at: repo) } }

    private func git(_ args: [String]) {
        let result = ProcessIO.run(executable: "/usr/bin/git", arguments: ["-C", repo.path] + args, timeout: 10)
        XCTAssertEqual(result?.status, 0)
    }

    func testRealRepositoryFingerprintTracksCleanTrackedAndUntrackedContent() throws {
        let clean = try XCTUnwrap(CodeFingerprint.measure(cwd: repo.path))
        XCTAssertEqual(clean, CodeFingerprint.measure(cwd: repo.path))
        try Data("two\n".utf8).write(to: repo.appendingPathComponent("tracked"))
        let tracked = try XCTUnwrap(CodeFingerprint.measure(cwd: repo.path))
        XCTAssertNotEqual(clean, tracked)
        try Data("three\n".utf8).write(to: repo.appendingPathComponent("tracked"))
        let trackedAgain = try XCTUnwrap(CodeFingerprint.measure(cwd: repo.path))
        XCTAssertNotEqual(tracked, trackedAgain, "the patch content, not only dirty status, is identity")
        try Data("draft".utf8).write(to: repo.appendingPathComponent("new"))
        let untracked = try XCTUnwrap(CodeFingerprint.measure(cwd: repo.path))
        XCTAssertNotEqual(trackedAgain, untracked)
        try Data("changed".utf8).write(to: repo.appendingPathComponent("new"))
        XCTAssertNotEqual(untracked, CodeFingerprint.measure(cwd: repo.path))
    }

    func testCommittingTheCheckedContentKeepsItsIdentity() throws {
        try Data("checked\n".utf8).write(to: repo.appendingPathComponent("tracked"))
        try Data("new file\n".utf8).write(to: repo.appendingPathComponent("added"))
        let checked = try XCTUnwrap(CodeFingerprint.measure(cwd: repo.path))
        git(["add", "-A"])
        XCTAssertEqual(checked, CodeFingerprint.measure(cwd: repo.path), "staging is not a content change")
        git(["-c", "user.name=Pulse", "-c", "user.email=pulse@example.invalid", "commit", "-qm", "land"])
        XCTAssertEqual(
            checked, CodeFingerprint.measure(cwd: repo.path),
            "committing exactly what a check passed must not make its evidence stale"
        )
    }

    func testDeletingATrackedFileChangesTheIdentity() throws {
        let before = try XCTUnwrap(CodeFingerprint.measure(cwd: repo.path))
        try FileManager.default.removeItem(at: repo.appendingPathComponent("tracked"))
        let after = try XCTUnwrap(CodeFingerprint.measure(cwd: repo.path))
        XCTAssertNotEqual(before, after)
    }

    func testBlobIDMatchesGit() {
        // `printf 'one\n' | git hash-object --stdin`
        XCTAssertEqual(CodeFingerprint.blobID(Data("one\n".utf8)), "5626abf0f72e58d7a153368ba57db4c673c0e171")
    }

    func testStagedChangesAreIncluded() throws {
        let before = try XCTUnwrap(CodeFingerprint.measure(cwd: repo.path))
        try Data("staged\n".utf8).write(to: repo.appendingPathComponent("tracked"))
        git(["add", "tracked"])
        XCTAssertNotEqual(before, CodeFingerprint.measure(cwd: repo.path))
    }

    func testFingerprintDoesNotRewriteTheGitIndex() throws {
        try Data("dirty\n".utf8).write(to: repo.appendingPathComponent("tracked"))
        let index = repo.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: index)
        XCTAssertNotNil(CodeFingerprint.measure(cwd: repo.path))
        XCTAssertEqual(try Data(contentsOf: index), before)
    }

    func testRealDuringRunMutationInvalidatesEvidence() throws {
        let before = try XCTUnwrap(CodeFingerprint.measure(cwd: repo.path))
        try Data("mutated\n".utf8).write(to: repo.appendingPathComponent("tracked"))
        let after = try XCTUnwrap(CodeFingerprint.measure(cwd: repo.path))
        let evidence = AcceptanceEvidence.make(
            command: "true", cwd: repo.path, startedAtMs: 1, finishedAtMs: 2,
            stdout: Data(), stderr: Data(), exitCode: 0,
            preFingerprint: before, postFingerprint: after
        )
        XCTAssertEqual(evidence.outcome, .invalidatedDuringRun)
    }

    func testUntrackedSymlinkHashesTargetTextWithoutFollowingIt() throws {
        let link = repo.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/not/read/by/pulse")
        XCTAssertNotNil(CodeFingerprint.measure(cwd: repo.path))
    }

    func testBudgetsFailClosed() throws {
        try Data("x".utf8).write(to: repo.appendingPathComponent("new"))
        var limits = CodeFingerprint.Limits.default
        limits.untrackedPaths = 0
        XCTAssertNil(CodeFingerprint.measure(cwd: repo.path, limits: limits))
    }

    func testOutcomeTableAndCodableRoundTrip() throws {
        let a = CodeFingerprint(sha256: "a"), b = CodeFingerprint(sha256: "b")
        let rows: [(Int32?, CodeFingerprint?, CodeFingerprint?, Bool, Bool, AcceptanceEvidence.Outcome)] = [
            (0, a, a, false, false, .passed), (1, a, a, false, false, .failed),
            (0, a, b, false, false, .invalidatedDuringRun),
            (0, nil, a, false, false, .couldNotRun), (nil, a, a, false, false, .couldNotRun),
            (0, a, a, true, false, .timedOut), (0, a, a, false, true, .interrupted),
        ]
        for row in rows {
            let evidence = AcceptanceEvidence.make(
                command: "test", cwd: repo.path, startedAtMs: 1, finishedAtMs: 2,
                stdout: Data("out".utf8), stderr: Data(), exitCode: row.0,
                preFingerprint: row.1, postFingerprint: row.2,
                timedOut: row.3, interrupted: row.4
            )
            XCTAssertEqual(evidence.outcome, row.5)
            XCTAssertEqual(try JSONDecoder().decode(AcceptanceEvidence.self, from: JSONEncoder().encode(evidence)), evidence)
        }
    }

    func testEvidenceOutputIsBounded() {
        let fingerprint = CodeFingerprint(sha256: "same")
        let evidence = AcceptanceEvidence.make(
            command: "test", cwd: repo.path, startedAtMs: 1, finishedAtMs: 2,
            stdout: Data(repeating: 1, count: AcceptanceEvidence.outputLimitBytes + 1),
            stderr: Data(repeating: 2, count: AcceptanceEvidence.outputLimitBytes + 1),
            exitCode: 0, preFingerprint: fingerprint, postFingerprint: fingerprint
        )
        XCTAssertEqual(evidence.stdout.count, AcceptanceEvidence.outputLimitBytes)
        XCTAssertEqual(evidence.stderr.count, AcceptanceEvidence.outputLimitBytes)
    }

    // MARK: - 12.2 · what evidence proves now

    func testEvidenceStandingTable() {
        let a = CodeFingerprint(sha256: "a"), b = CodeFingerprint(sha256: "b")
        func evidence(_ exit: Int32) -> AcceptanceEvidence {
            AcceptanceEvidence.make(
                command: "t", cwd: repo.path, startedAtMs: 1, finishedAtMs: 2,
                stdout: Data(), stderr: Data(), exitCode: exit,
                preFingerprint: a, postFingerprint: a
            )
        }
        XCTAssertEqual(EvidenceStanding.of(evidence(0), current: a, measured: true), .passing)
        XCTAssertEqual(EvidenceStanding.of(evidence(0), current: b, measured: true), .stale)
        XCTAssertEqual(EvidenceStanding.of(evidence(0), current: nil, measured: true), .unverified)
        XCTAssertEqual(EvidenceStanding.of(evidence(0), current: a, measured: false), .measuring)
        XCTAssertEqual(EvidenceStanding.of(evidence(1), current: a, measured: true), .notPassing)
    }

    @MainActor
    func testTheRunnerKnowsWhenAPassGoesStale() async throws {
        let runner = AcceptanceRunner(root: repo.path)
        let ran = expectation(description: "check finished")
        var result: AcceptanceEvidence?
        runner.run(command: "true") { evidence in
            result = evidence
            ran.fulfill()
        }
        await fulfillment(of: [ran], timeout: 30)
        let evidence = try XCTUnwrap(result)
        XCTAssertEqual(runner.standing(of: evidence), .passing, "measured by the check itself")

        try Data("edited elsewhere\n".utf8).write(to: repo.appendingPathComponent("tracked"))
        let measured = expectation(description: "re-measured")
        measured.assertForOverFulfill = false
        runner.onChange = { measured.fulfill() }
        runner.refresh()
        await fulfillment(of: [measured], timeout: 30)
        XCTAssertEqual(runner.standing(of: evidence), .stale)
    }
}

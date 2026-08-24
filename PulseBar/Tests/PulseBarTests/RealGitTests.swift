import CryptoKit
import XCTest
@testable import PulseBar

/// 2.6 shipped against git's documented porcelain contract without ever
/// running git — every WorkspaceEffect test injected a fake runner, so they
/// proved "given this output, Pulse reads it so", never that git produces
/// that output. The release notes called it a known limitation and said only
/// a real machine could close it.
///
/// The CI runner **is** a real machine. These tests build a real repository
/// in a temporary directory and run the real `measure()` against it — the
/// same pattern `testTheRealParentLookupAgreesWithTheKernel` uses for
/// `sysctl`. The container-side rehearsal against git 2.43 confirmed every
/// expectation below, including the one that matters most: without
/// `--no-optional-locks` the index really is rewritten by `git status`, and
/// with it the index really is untouched.
final class RealGitTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000
    private var repo: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: WorkspaceEffect.executable),
            "no git on this machine — the fixture tests still hold the parsing"
        )
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-realgit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git(["init", "-q", "."])
        try write("a\nb\nc\n", to: "f1.txt")
        try write("x\n", to: "f2.txt")
        git(["add", "."])
        commit("one")
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
    }

    /// Repository plumbing for the fixture itself. Deliberately NOT through
    /// `WorkspaceEffect.runner` — the allowed-verbs test stays truthful, and
    /// the code under test never learns to run `add` or `commit`.
    @discardableResult
    private func git(_ arguments: [String]) -> ProcessIO.Result? {
        ProcessIO.run(
            executable: WorkspaceEffect.executable,
            arguments: ["-C", repo.path] + arguments,
            timeout: 10
        )
    }

    private func commit(_ message: String) {
        git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", message])
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - The counts, against real output

    func testARealDirtyTreeMeasuresItsRealCounts() throws {
        // Modify tracked (+3 −1 net of a changed line), delete tracked,
        // create untracked — the same shape the container rehearsal used.
        try write("a\nB\nc\nd\ne\n", to: "f1.txt")
        try FileManager.default.removeItem(at: repo.appendingPathComponent("f2.txt"))
        try write("new\n", to: "f3.txt")

        let measurement = WorkspaceEffect.measure(root: repo.path, nowMs: now)
        XCTAssertEqual(measurement.changedPaths, 3, "M + D + ?? are all changed paths")
        XCTAssertEqual(measurement.insertions, 3)
        XCTAssertEqual(measurement.deletions, 2)
        XCTAssertEqual(measurement.head.count, 40, "a real commit id came back")
    }

    func testARealCleanTreeIsZeroNotUnknown() {
        let measurement = WorkspaceEffect.measure(root: repo.path, nowMs: now)
        XCTAssertTrue(measurement.isKnown)
        XCTAssertTrue(measurement.nothingLanded)
        XCTAssertEqual(measurement.insertions, 0)
        XCTAssertEqual(measurement.deletions, 0)
    }

    func testUntrackedOnlyWorkAgainstRealGit() throws {
        try write("draft\n", to: "notes.md")
        let measurement = WorkspaceEffect.measure(root: repo.path, nowMs: now)
        XCTAssertEqual(measurement.changedPaths, 1)
        XCTAssertEqual(measurement.insertions, -1, "no diff against HEAD is not zero lines")
    }

    func testARealNonRepositoryIsNil() {
        XCTAssertNil(
            WorkspaceEffect.repositoryRoot(of: FileManager.default.temporaryDirectory.path)
        )
    }

    func testASubdirectoryResolvesToItsRealRoot() throws {
        let sub = repo.appendingPathComponent("deep/inside", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let root = WorkspaceEffect.repositoryRoot(of: sub.path)
        // Compare resolved paths: on macOS /tmp is a symlink into /private,
        // and git prints the physical path.
        XCTAssertEqual(
            URL(fileURLWithPath: root ?? "").resolvingSymlinksInPath().path,
            repo.resolvingSymlinksInPath().path
        )
    }

    // MARK: - The read-only guarantee, against a real index

    func testAMeasurementLeavesTheRealIndexByteForByteAlone() throws {
        // Force the stat cache stale so a default `git status` would want to
        // rewrite the index — the exact hazard --no-optional-locks exists for.
        // The container rehearsal confirmed the flagless run really does
        // rewrite it under this setup.
        let f1 = repo.appendingPathComponent("f1.txt")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 946_684_800)],
            ofItemAtPath: f1.path
        )
        let index = repo.appendingPathComponent(".git/index")
        let before = SHA256.hash(data: try Data(contentsOf: index))

        _ = WorkspaceEffect.measure(root: repo.path, nowMs: now)

        let after = SHA256.hash(data: try Data(contentsOf: index))
        XCTAssertEqual(before, after, "a bystander must not write the index")
    }

    // MARK: - A commit is something landing (G-1), against real commits

    func testARealCommitIsNoticedBetweenTwoMeasurements() throws {
        var store = WorkspaceEffectStore()
        store.record(WorkspaceEffect.measure(root: repo.path, nowMs: now), tookMs: 1, nowMs: now)

        try write("a\nb\nc\nmore\n", to: "f1.txt")
        git(["add", "."])
        commit("two")

        let later = now + WorkspaceEffectStore.freshnessMs
        store.record(WorkspaceEffect.measure(root: repo.path, nowMs: later), tookMs: 1, nowMs: later)
        XCTAssertTrue(
            store.headMovedRecently(root: repo.path, nowMs: later),
            "the tree is clean again, and that is the opposite of nothing landing"
        )
        // And the tree really is clean, so without G-1 the story line would
        // have accused this agent at its most productive moment.
        XCTAssertTrue(WorkspaceEffect.measure(root: repo.path, nowMs: later).nothingLanded)
    }

    func testARepositoryWithNoCommitsHasNoHeadAndSaysNothing() throws {
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-realgit-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        _ = ProcessIO.run(
            executable: WorkspaceEffect.executable,
            arguments: ["-C", bare.path, "init", "-q", "."],
            timeout: 10
        )
        let measurement = WorkspaceEffect.measure(root: bare.path, nowMs: now)
        XCTAssertEqual(measurement.head, "", "no HEAD is an empty id, never a fabricated one")
    }
}

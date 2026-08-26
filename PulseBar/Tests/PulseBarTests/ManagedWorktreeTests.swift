import XCTest
@testable import PulseBar

/// 5.0-β — the workspace verbs, against a real repository (the RealGitTests
/// pattern: the CI runner is a real machine). Plus the pure guards that must
/// hold before any path reaches git.
final class ManagedWorktreeTests: XCTestCase {

    private var repo: URL!
    private var base: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: WorkspaceEffect.executable),
            "no git on this machine"
        )
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-mwt-repo-\(UUID().uuidString)", isDirectory: true)
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-mwt-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        ManagedWorktree.baseOverride = base
        git(["init", "-q", "."])
        try "hello\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "one"])
    }

    override func tearDownWithError() throws {
        ManagedWorktree.baseOverride = nil
        if let repo { try? FileManager.default.removeItem(at: repo) }
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    @discardableResult
    private func git(_ arguments: [String]) -> ProcessIO.Result? {
        ProcessIO.run(
            executable: WorkspaceEffect.executable,
            arguments: ["-C", repo.path] + arguments,
            timeout: 10
        )
    }

    // MARK: - Pure guards

    func testTheSlugIsBranchSafeAndBounded() {
        let slug = ManagedWorktree.slug(task: "Fix the LOGIN bug! (urgent) 中文 #42", nowMs: 1_800_000_123_000)
        XCTAssertTrue(slug.hasPrefix("fix-the-login-bug-"), slug)
        XCTAssertNil(slug.rangeOfCharacter(from: CharacterSet.alphanumerics.union(.init(charactersIn: "-")).inverted))
        XCTAssertEqual(ManagedWorktree.slug(task: "!!!", nowMs: 5_000).hasPrefix("task-"), true)
    }

    func testOnlyPathsInsideTheNamespaceCountAsPulseWorktrees() {
        let inside = ManagedWorktree.baseDirectory().appendingPathComponent("repo/x").path
        XCTAssertTrue(ManagedWorktree.isPulseWorktree(inside))
        XCTAssertFalse(ManagedWorktree.isPulseWorktree("/Users/me/code/project"))
        XCTAssertFalse(ManagedWorktree.isPulseWorktree(ManagedWorktree.baseDirectory().path),
                       "the namespace root itself is not a worktree")
    }

    // MARK: - The real verb

    func testCreateMakesARealWorktreeOnItsOwnBranch() throws {
        let result = ManagedWorktree.create(repoRoot: repo.path, slug: "test-slug-1")
        guard case .success(let path) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertTrue(ManagedWorktree.isPulseWorktree(path))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/f.txt"),
                      "the worktree carries the repository's content")
        // The branch is namespaced, and the worktree is a real checkout of it.
        let head = ProcessIO.run(
            executable: WorkspaceEffect.executable,
            arguments: ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"],
            timeout: 10
        )
        XCTAssertEqual(
            String(decoding: head?.stdout ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "pulse/test-slug-1"
        )
    }

    func testANonRepositoryRefusesBeforeGitEverRuns() {
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-mwt-plain-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        XCTAssertEqual(
            ManagedWorktree.create(repoRoot: plain.path, slug: "s"),
            .failure(.notARepository)
        )
    }
}

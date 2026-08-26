import XCTest
@testable import PulseBar

/// 5.0-γ — acceptance verbs, proven against a real repository with a real
/// (local, bare) origin. The namespace guard and the compare-URL parser are
/// pure and pinned first; then the whole chain: change → commit → push →
/// branch exists on the origin.
final class ManagedAcceptanceTests: XCTestCase {

    private var repo: URL!
    private var origin: URL!
    private var base: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: WorkspaceEffect.executable),
            "no git on this machine"
        )
        let tmp = FileManager.default.temporaryDirectory
        repo = tmp.appendingPathComponent("pulse-acc-repo-\(UUID().uuidString)", isDirectory: true)
        origin = tmp.appendingPathComponent("pulse-acc-origin-\(UUID().uuidString)", isDirectory: true)
        base = tmp.appendingPathComponent("pulse-acc-base-\(UUID().uuidString)", isDirectory: true)
        ManagedWorktree.baseOverride = base
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        git(origin.path, ["init", "-q", "--bare", "."])
        git(repo.path, ["init", "-q", "."])
        try "hello\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        git(repo.path, ["add", "."])
        git(repo.path, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "one"])
        git(repo.path, ["remote", "add", "origin", origin.path])
    }

    override func tearDownWithError() throws {
        ManagedWorktree.baseOverride = nil
        for url in [repo, origin, base] {
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    @discardableResult
    private func git(_ dir: String, _ arguments: [String]) -> ProcessIO.Result? {
        ProcessIO.run(
            executable: WorkspaceEffect.executable,
            arguments: ["-C", dir] + arguments,
            timeout: 10
        )
    }

    // MARK: - Pure guards

    func testEveryVerbRefusesOutsideTheNamespace() {
        XCTAssertEqual(
            ManagedAcceptance.commit(worktree: repo.path, message: "m"),
            .outsideNamespace,
            "the user's own checkout is untouchable even with a message"
        )
        XCTAssertEqual(
            ManagedAcceptance.push(worktree: repo.path, branch: "pulse/x"),
            .outsideNamespace
        )
    }

    func testAnEmptyCommitMessageRefusesBeforeGitRuns() {
        let inside = ManagedWorktree.baseDirectory().appendingPathComponent("r/w").path
        XCTAssertEqual(
            ManagedAcceptance.commit(worktree: inside, message: "   "),
            .gitFailed("empty message")
        )
    }

    func testPushRefusesANonPulseBranch() {
        let inside = ManagedWorktree.baseDirectory().appendingPathComponent("r/w").path
        XCTAssertEqual(
            ManagedAcceptance.push(worktree: inside, branch: "main"),
            .gitFailed("not a pulse branch")
        )
    }

    func testTheCompareURLKnowsEveryGitHubRemoteShapeAndNothingElse() {
        for origin in [
            "git@github.com:me/proj.git",
            "https://github.com/me/proj.git",
            "https://github.com/me/proj",
            "ssh://git@github.com/me/proj.git",
        ] {
            XCTAssertEqual(
                ManagedAcceptance.compareURL(originURL: origin, branch: "pulse/fix-1")?.absoluteString,
                "https://github.com/me/proj/compare/pulse%2Ffix-1?expand=1",
                origin
            )
        }
        XCTAssertNil(ManagedAcceptance.compareURL(originURL: "https://gitlab.com/me/proj.git", branch: "b"),
                     "a guessed URL is not honesty — no button for non-GitHub remotes")
        XCTAssertNil(ManagedAcceptance.compareURL(originURL: "", branch: "b"))
    }

    // MARK: - The real chain

    func testChangeCommitPushLandsTheBranchOnTheOrigin() throws {
        guard case .success(let worktree) = ManagedWorktree.create(repoRoot: repo.path, slug: "acc-1") else {
            return XCTFail("worktree create failed")
        }
        try "changed\n".write(
            to: URL(fileURLWithPath: worktree).appendingPathComponent("f.txt"),
            atomically: true, encoding: .utf8
        )
        // Commit needs an identity; give the worktree a local one the way a
        // user's global config would.
        git(worktree, ["config", "user.email", "t@t"])
        git(worktree, ["config", "user.name", "t"])

        XCTAssertNil(ManagedAcceptance.commit(worktree: worktree, message: "land it"))
        XCTAssertEqual(ManagedAcceptance.branch(worktree: worktree), "pulse/acc-1")
        XCTAssertNil(ManagedAcceptance.push(worktree: worktree, branch: "pulse/acc-1"))

        // The origin — a real bare repository — now has the branch with the
        // committed content.
        let heads = git(origin.path, ["branch", "--list", "pulse/acc-1"])
        XCTAssertTrue(
            String(decoding: heads?.stdout ?? Data(), as: UTF8.self).contains("pulse/acc-1"),
            "the branch reached the origin"
        )
        let show = git(origin.path, ["show", "pulse/acc-1:f.txt"])
        XCTAssertEqual(String(decoding: show?.stdout ?? Data(), as: UTF8.self), "changed\n")
        XCTAssertEqual(ManagedAcceptance.originURL(worktree: worktree), origin.path)
    }
}

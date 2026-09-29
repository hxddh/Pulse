import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// Re-arming attention.tsv used to tear down every other watch with it
/// (U-4). Since 22.0 removed the remote inbox the other watch is the
/// activity spool, and the rule is the same: each watch re-arms alone.
final class AttentionWatcherReArmTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        AttentionIO.pathOverride = home.appendingPathComponent("attention.tsv")
    }

    override func tearDownWithError() throws {
        AttentionIO.pathOverride = nil
        try? FileManager.default.removeItem(at: home)
    }

    func testReArmingTheFileWatchLeavesTheActivityWatchAlone() {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start(onChange: {}, onActivity: {})
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(watcher.isWatchingActivity)

        // What the delete/rename handler does after an atomic replace — which
        // is what every hook write looks like from the outside.
        watcher.arm()
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(
            watcher.isWatchingActivity,
            "activity.d/ must keep waking Pulse after attention.tsv is replaced"
        )
    }

    func testReArmingTheActivityWatchLeavesTheFileWatchAlone() {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start(onChange: {}, onActivity: {})
        watcher.armActivity()
        XCTAssertTrue(watcher.isWatchingFile)
        XCTAssertTrue(watcher.isWatchingActivity)
    }

    /// A deleted file cannot be reopened, so the watch would have stayed dead
    /// for the life of the process.
    func testAFileThatWasDeletedIsRecreatedAndWatchedAgain() throws {
        let watcher = AttentionWatcher()
        defer { watcher.stop() }
        watcher.start {}
        let file = try XCTUnwrap(AttentionIO.pathOverride)
        try FileManager.default.removeItem(at: file)

        watcher.arm()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(watcher.isWatchingFile)
    }

    func testStopTearsDownEveryWatch() {
        let watcher = AttentionWatcher()
        watcher.start(onChange: {}, onActivity: {})
        watcher.stop()
        XCTAssertFalse(watcher.isWatchingFile)
        XCTAssertFalse(watcher.isWatchingActivity)
    }
}

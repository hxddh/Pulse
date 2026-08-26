import XCTest
@testable import PulseBar

/// 6.0-α — the supervisor's contracts: the state round-trip (including the
/// honest interrupted mapping), filename identity, the queue under its cap,
/// bounded persistence, and removal. The start action is injected so the
/// queue is pinned without spawning a process.
@MainActor
final class ManagedFleetTests: XCTestCase {

    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-fleet-\(UUID().uuidString)", isDirectory: true)
        ManagedSession.stateDirectoryOverride = stateDir
    }

    override func tearDownWithError() throws {
        ManagedSession.stateDirectoryOverride = nil
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    private func model(_ id: String, task: String = "do the thing") -> ManagedSession.Model {
        var m = ManagedSession.Model(id: id, task: task, root: "/tmp/w", isWorktree: true, nowMs: 1_800_000_000_000)
        m.pendingPrompt = task
        return m
    }

    // MARK: - The state round-trip

    func testAStateSurvivesTheRoundTripFieldForField() {
        var m = model("s1")
        m.claudeSessionID = "abc"
        m.modelName = "claude-fable-5"
        m.entries = [.init(kind: .agent, text: "hello", tsMs: 5)]
        m.turns = 3
        m.totalCostUSD = 1.25
        m.tokensIn = 10
        m.tokensOut = 20
        m.runCommand = "swift test"
        m.attemptGroup = "g1"
        XCTAssertTrue(ManagedSession.persist(m))
        let loaded = ManagedSession.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0], m)
    }

    func testARunningTurnComesBackInterruptedNeverInvented() {
        var m = model("s1")
        m.status = .running
        ManagedSession.persist(m)
        XCTAssertEqual(ManagedSession.loadAll().first?.status, .interrupted,
                       "nobody witnessed how that turn ended")
    }

    func testAQueuedSessionComesBackQueuedWithItsPromptIntact() {
        var m = model("s1", task: "the held task")
        m.status = .queued
        ManagedSession.persist(m)
        let loaded = ManagedSession.loadAll().first
        XCTAssertEqual(loaded?.status, .queued)
        XCTAssertEqual(loaded?.pendingPrompt, "the held task")
    }

    func testAFailureKeepsItsReasonAcrossTheRestart() {
        var m = model("s1")
        m.status = .failed("error_max_turns")
        ManagedSession.persist(m)
        XCTAssertEqual(ManagedSession.loadAll().first?.status, .failed("error_max_turns"))
    }

    func testFilenameDecidesIdentityHereToo() throws {
        ManagedSession.persist(model("honest"))
        // A renamed state file claims an identity its body does not carry.
        try FileManager.default.moveItem(
            at: ManagedSession.stateURL(id: "honest"),
            to: ManagedSession.stateURL(id: "impostor")
        )
        XCTAssertTrue(ManagedSession.loadAll().isEmpty, "body/filename mismatch is refused")
    }

    // MARK: - The queue under its cap

    private func testFleet() -> ManagedFleet {
        let fleet = ManagedFleet()
        fleet.startAction = { $0.adoptStatusForTesting(.running) }
        return fleet
    }

    func testTheCapHoldsAndAFreedSlotPumpsTheQueue() {
        let fleet = testFleet()
        for index in 0..<5 { fleet.dispatch(model: model("s\(index)")) }
        XCTAssertEqual(fleet.runningCount, ManagedFleet.maxConcurrent)
        XCTAssertEqual(fleet.runners.filter { $0.model.status == .queued }.count, 2)

        // One turn ends — the next queued session starts on its own.
        fleet.runners[0].adoptStatusForTesting(.idle)
        XCTAssertEqual(fleet.runningCount, ManagedFleet.maxConcurrent)
        XCTAssertEqual(fleet.runners.filter { $0.model.status == .queued }.count, 1)
    }

    func testReattachRepumpsAPersistedQueue() {
        var m = model("s1")
        m.status = .queued
        ManagedSession.persist(m)
        let fleet = testFleet()
        fleet.reattachFromDisk()
        XCTAssertEqual(fleet.runners.count, 1)
        XCTAssertEqual(fleet.runners[0].model.status, .running,
                       "a queued survivor starts as soon as a slot exists")
    }

    // MARK: - Bounded persistence and removal

    func testPersistenceWritesOnStatusMovesNotOnEveryChange() throws {
        let fleet = testFleet()
        fleet.dispatch(model: model("s1"))
        let url = ManagedSession.stateURL(id: "s1")
        // Dispatch pumped it straight to running, and that state is on disk.
        let afterStart = try Data(contentsOf: url)
        XCTAssertTrue(String(decoding: afterStart, as: UTF8.self).contains("\"running\""))
        // A change that moves nothing does not rewrite the file.
        fleet.runners[0].adoptStatusForTesting(.running)
        XCTAssertEqual(try Data(contentsOf: url), afterStart)
        // A real move rewrites it.
        fleet.runners[0].adoptStatusForTesting(.idle)
        XCTAssertNotEqual(try Data(contentsOf: url), afterStart)
    }

    func testRemoveDeletesTheRecordButRefusesARunningSession() {
        let fleet = testFleet()
        fleet.dispatch(model: model("s1"))
        XCTAssertEqual(fleet.runners[0].model.status, .running)
        fleet.remove(managedID: "s1")
        XCTAssertEqual(fleet.runners.count, 1, "a running session cannot be cleared away")

        fleet.runners[0].adoptStatusForTesting(.idle)
        fleet.remove(managedID: "s1")
        XCTAssertTrue(fleet.runners.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ManagedSession.stateURL(id: "s1").path))
    }
}

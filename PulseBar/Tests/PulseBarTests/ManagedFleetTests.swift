import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseManaged
@testable import PulseRespond

/// 6.0-α — the supervisor's contracts: the state round-trip (including the
/// honest interrupted mapping), filename identity, the queue under its cap,
/// bounded persistence, and removal. The start action is injected so the
/// queue is pinned without spawning a process.
@MainActor
final class ManagedFleetTests: XCTestCase {

    private final class FakeRuntimeSession: ManagedRuntimeSession {
        var onEvent: ((ManagedRuntimeEvent) -> Void)?
        var onTurnEnd: ((ManagedTurnEnd) -> Void)?
        private(set) var binds: [(continuation: String?, managedID: String)] = []
        private(set) var prompts: [String] = []
        private(set) var approvals: [(id: String, decision: ManagedApprovalDecision)] = []

        func startOrResume(continuation: String?, root: String, managedID: String) -> String? {
            binds.append((continuation, managedID))
            return nil
        }

        func send(prompt: String) -> String? {
            prompts.append(prompt)
            onEvent?(.continuation("fake-thread"))
            onEvent?(.model("fake-model"))
            onEvent?(.result(ManagedRuntimeResult(
                text: "finished", costUSD: nil, tokensIn: 3, tokensOut: 2, errorDetail: nil
            )))
            onTurnEnd?(ManagedTurnEnd(exitStatus: 0))
            return nil
        }

        func resolveApproval(id: String, decision: ManagedApprovalDecision) {
            approvals.append((id, decision))
        }

        func cancel() -> Bool { true }
        func shutdown() {}
    }

    private final class FakeRuntime: ManagedRuntime {
        let id = "fake"
        let agent: AgentID = .claude
        let session = FakeRuntimeSession()

        func executable() -> String? { "/usr/bin/true" }
        func canStart(prompt: String, continuation: String?) -> Bool { !prompt.isEmpty }
        func makeSession() -> any ManagedRuntimeSession { session }
    }

    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-fleet-\(UUID().uuidString)", isDirectory: true)
        ManagedSession.stateDirectoryOverride = stateDir
        EvidenceBook.directoryOverride = stateDir.appendingPathComponent("evidence", isDirectory: true)
    }

    override func tearDownWithError() throws {
        ManagedSession.stateDirectoryOverride = nil
        EvidenceBook.directoryOverride = nil
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
        m.continuationID = "abc"
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

    /// 14.0: evidence is no longer session state. A schema-4 file that
    /// still carries it hands it over once — bounded, with a check that was
    /// in flight at quit coming back as interrupted — and the rewritten
    /// file no longer holds it.
    func testLegacyEvidenceIsCarriedOutOfTheSessionState() throws {
        let m = model("carrier")
        XCTAssertTrue(ManagedSession.persist(m))
        let url = ManagedSession.stateURL(id: "carrier")
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertNil(object["acceptanceEvidence"], "schema 5 does not write evidence")
        XCTAssertNil(object["runningCheck"])
        let fingerprint = CodeFingerprint(sha256: "same")
        let old = (0..<(ManagedSession.maxAcceptanceEvidence + 5)).map { index in
            AcceptanceEvidence.make(
                command: "check \(index)", cwd: m.root,
                startedAtMs: Int64(index), finishedAtMs: Int64(index + 1),
                stdout: Data(), stderr: Data(), exitCode: 0,
                preFingerprint: fingerprint, postFingerprint: fingerprint
            )
        }
        object["schemaVersion"] = 4
        object["acceptanceEvidence"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old))
        object["runningCheck"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(RunningCheck(command: "swift test", cwd: m.root, startedAtMs: 42))
        )
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let loaded = try XCTUnwrap(ManagedSession.loadAll().first)
        XCTAssertEqual(loaded.carriedEvidence.count, ManagedSession.maxAcceptanceEvidence)
        XCTAssertEqual(loaded.carriedEvidence.last?.outcome, .interrupted)
        XCTAssertEqual(loaded.carriedEvidence.last?.command, "swift test")

        XCTAssertTrue(ManagedSession.persist(loaded))
        let rewritten = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(rewritten["schemaVersion"] as? Int, ManagedSession.State.currentSchemaVersion)
        XCTAssertNil(rewritten["acceptanceEvidence"])
        XCTAssertTrue(try XCTUnwrap(ManagedSession.loadAll().first).carriedEvidence.isEmpty)
    }

    func testReattachMovesCarriedEvidenceIntoTheBook() throws {
        let m = model("carrier")
        XCTAssertTrue(ManagedSession.persist(m))
        let url = ManagedSession.stateURL(id: "carrier")
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["schemaVersion"] = 4
        object["runningCheck"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(RunningCheck(command: "swift test", cwd: m.root, startedAtMs: 42))
        )
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let fleet = testFleet()
        fleet.startAction = { _ in }
        fleet.reattachFromDisk()
        XCTAssertEqual(fleet.evidence.evidence(for: m.root).map(\.outcome), [.interrupted])
        XCTAssertEqual(fleet.runners.first?.acceptanceEvidence.map(\.outcome), [.interrupted],
                       "the Candidate reads its worktree's page")
        let rewritten = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(rewritten["schemaVersion"] as? Int, ManagedSession.State.currentSchemaVersion)
        XCTAssertNil(rewritten["runningCheck"])

        // A second launch finds the evidence in the book, not twice.
        let again = testFleet()
        again.startAction = { _ in }
        again.reattachFromDisk()
        XCTAssertEqual(again.evidence.evidence(for: m.root).count, 1)
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

    func testLegacyClaudeStateMigratesToTheVersionedRuntimeShape() throws {
        var original = model("legacy")
        original.continuationID = "old-session"
        XCTAssertTrue(ManagedSession.persist(original))
        let url = ManagedSession.stateURL(id: "legacy")
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["schemaVersion"] = nil
        object["runtimeID"] = nil
        object["continuationID"] = nil
        object["acceptanceEvidence"] = nil
        object["claudeSessionID"] = "old-session"
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let loaded = try XCTUnwrap(ManagedSession.loadAll().first)
        XCTAssertEqual(loaded.runtimeID, "claude")
        XCTAssertEqual(loaded.continuationID, "old-session")

        XCTAssertTrue(ManagedSession.persist(loaded))
        let migrated = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(migrated["schemaVersion"] as? Int, ManagedSession.State.currentSchemaVersion)
        XCTAssertEqual(migrated["runtimeID"] as? String, "claude")
        XCTAssertEqual(migrated["continuationID"] as? String, "old-session")
        XCTAssertNil(migrated["claudeSessionID"])
    }

    func testInvalidSchemasAndUnsupportedRuntimesAreRefused() throws {
        XCTAssertTrue(ManagedSession.persist(model("future")))
        let url = ManagedSession.stateURL(id: "future")
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertTrue(ManagedSession.loadAll().isEmpty)

        object["schemaVersion"] = 0
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertTrue(ManagedSession.loadAll().isEmpty)

        XCTAssertTrue(ManagedSession.persist(model("future")))
        object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["runtimeID"] = "future-runtime"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertTrue(ManagedSession.loadAll().isEmpty)
    }

    func testRunnerSeesOnlyNormalizedRuntimeSessionEvents() {
        var m = model("runtime")
        m.runtimeID = "fake"
        let runner = ManagedSessionRunner(model: m, runtime: FakeRuntime())
        runner.send(prompt: "do it")

        XCTAssertEqual(runner.model.status, .idle)
        XCTAssertEqual(runner.model.continuationID, "fake-thread")
        XCTAssertEqual(runner.model.modelName, "fake-model")
        XCTAssertEqual(runner.model.lastResultText, "finished")
        XCTAssertEqual(runner.model.tokensIn, 3)
        XCTAssertEqual(runner.model.tokensOut, 2)
        XCTAssertEqual(runner.model.entries.first?.kind, .user)
    }

    // MARK: - The session-shaped boundary (12.2)

    func testASessionIsBoundOnceAndEachTurnIsASend() {
        var m = model("bound")
        m.runtimeID = "fake"
        m.continuationID = "resume-me"
        let runtime = FakeRuntime()
        let runner = ManagedSessionRunner(model: m, runtime: runtime)
        runner.send(prompt: "first")
        runner.send(prompt: "second")
        XCTAssertEqual(runtime.session.binds.count, 1, "bound once, not per turn")
        XCTAssertEqual(runtime.session.binds.first?.continuation, "resume-me")
        XCTAssertEqual(runtime.session.binds.first?.managedID, "bound")
        XCTAssertEqual(runtime.session.prompts, ["first", "second"])
    }

    func testAnApprovalReachesTheRuntimeThatAskedForIt() {
        var m = model("asker")
        m.runtimeID = "fake"
        let runtime = FakeRuntime()
        let runner = ManagedSessionRunner(model: m, runtime: runtime)
        runner.resolveApproval(id: "req-1", decision: .deny(message: "no"))
        XCTAssertEqual(runtime.session.approvals.map(\.id), ["req-1"])
        XCTAssertEqual(runtime.session.approvals.first?.decision, .deny(message: "no"))
    }

    func testATurnEndWithoutAResultSaysHowItEnded() {
        XCTAssertEqual(ManagedTurnEnd(exitStatus: 0).failureText, "exit 0")
        XCTAssertEqual(ManagedTurnEnd(exitStatus: 1, diagnostic: "auth expired").failureText, "auth expired")
        XCTAssertEqual(ManagedTurnEnd(exitStatus: nil).failureText, "turn ended without a result")
    }

    func testAManagedRowIsTheRuntimesAgent() {
        var m = model("row")
        m.runtimeID = "claude"
        XCTAssertEqual(ManagedSessionSource.row(for: m).agent, .claude)
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

    func testPersistenceWritesOnlyOnDurableMoves() throws {
        let fleet = testFleet()
        fleet.dispatch(model: model("s1"))
        let url = ManagedSession.stateURL(id: "s1")
        // Dispatch pumped it straight to running, and that state is on disk.
        let afterStart = try Data(contentsOf: url)
        XCTAssertTrue(String(decoding: afterStart, as: UTF8.self).contains("\"running\""))
        // A change that moves nothing does not rewrite the file.
        fleet.runners[0].adoptStatusForTesting(.running)
        XCTAssertEqual(try Data(contentsOf: url), afterStart)
        // The user's acceptance command is durable even without a status move.
        fleet.runners[0].setRunCommand("swift test")
        let afterCommand = try Data(contentsOf: url)
        XCTAssertNotEqual(afterCommand, afterStart)
        XCTAssertTrue(String(decoding: afterCommand, as: UTF8.self).contains("swift test"))
        // A real move rewrites it.
        fleet.runners[0].adoptStatusForTesting(.idle)
        XCTAssertNotEqual(try Data(contentsOf: url), afterCommand)
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

import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseManaged
@testable import PulseRespond

/// 13.0 · Missions — the contract, its revisions, per-check standing,
/// persistence, migration from pre-13.0 sessions, and the fleet's part.
/// Pure where possible; the fleet part never spawns a process.
@MainActor
final class MissionTests: XCTestCase {
    private var missionDir: URL!
    private var stateDir: URL!
    private let t0: Int64 = 1_800_000_000_000

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-mission-\(UUID().uuidString)", isDirectory: true)
        missionDir = base.appendingPathComponent("missions", isDirectory: true)
        stateDir = base.appendingPathComponent("managed", isDirectory: true)
        Mission.directoryOverride = missionDir
        ManagedSession.stateDirectoryOverride = stateDir
    }

    override func tearDownWithError() throws {
        Mission.directoryOverride = nil
        ManagedSession.stateDirectoryOverride = nil
        if let missionDir { try? FileManager.default.removeItem(at: missionDir.deletingLastPathComponent()) }
    }

    private func check(_ id: String, _ command: String) -> Mission.Check {
        Mission.Check(id: id, command: command)
    }

    private func session(_ id: String, group: String = "", command: String = "", at offset: Int64 = 0) -> ManagedSession.Model {
        var m = ManagedSession.Model(id: id, task: "Fix the flaky login test", root: "/tmp/w-\(id)", isWorktree: true, nowMs: t0 + offset)
        m.attemptGroup = group
        m.runCommand = command
        return m
    }

    private func evidence(_ outcome: AcceptanceEvidence.Outcome, checkID: String?, exit: Int32 = 0) -> AcceptanceEvidence {
        var e = AcceptanceEvidence.make(
            command: "swift test", cwd: "/tmp/w", startedAtMs: t0, finishedAtMs: t0 + 1,
            stdout: Data(), stderr: Data(), exitCode: exit,
            preFingerprint: CodeFingerprint(sha256: "a"), postFingerprint: CodeFingerprint(sha256: "a"),
            checkID: checkID
        )
        e.outcome = outcome
        return e
    }

    // MARK: - Contract

    func testTheAgentIsToldTheGoalAndConstraintsButNeverTheChecks() {
        let mission = Mission.Model(
            id: "m1", repoRoot: "/r", goal: "Make login fast",
            constraints: "Do not touch the schema",
            checks: [check("c1", "swift test")], createdMs: t0
        )
        XCTAssertTrue(mission.contract.prompt.contains("Make login fast"))
        XCTAssertTrue(mission.contract.prompt.contains("Do not touch the schema"))
        XCTAssertFalse(mission.contract.prompt.contains("swift test"), "the checks are the user's ruler")
        XCTAssertEqual(mission.title, "Make login fast")
    }

    func testEditingBeforeAnyCandidateStartedChangesTheContractInPlace() {
        var mission = Mission.Model(id: "m1", repoRoot: "/r", goal: "A", createdMs: t0)
        mission.revise(goal: "B", constraints: "", checks: [], frozen: false)
        XCTAssertEqual(mission.contracts.count, 1)
        XCTAssertEqual(mission.contract.revision, 1)
        XCTAssertEqual(mission.contract.goal, "B")
    }

    func testEditingAfterACandidateStartedMakesANewRevisionAndKeepsTheOld() {
        var mission = Mission.Model(id: "m1", repoRoot: "/r", goal: "A", checks: [check("c1", "make")], createdMs: t0)
        mission.revise(goal: "A", constraints: "", checks: [check("c1", "make"), check("c2", "lint")], frozen: true)
        XCTAssertEqual(mission.contract.revision, 2)
        XCTAssertEqual(mission.contract(revision: 1)?.checks.map(\.id), ["c1"])
        XCTAssertEqual(mission.contract.checks.map(\.id), ["c1", "c2"])
        // An edit that changes nothing is not a revision.
        mission.revise(goal: "A", constraints: "", checks: mission.contract.checks, frozen: true)
        XCTAssertEqual(mission.contract.revision, 2)
    }

    func testChecksFromLinesDropBlanksAndDuplicatesAndKeepOrder() {
        var n = 0
        let checks = Mission.checks(fromLines: "swift test\n\n  make lint \nswift test\n", newID: { n += 1; return "c\(n)" })
        XCTAssertEqual(checks.map(\.command), ["swift test", "make lint"])
        XCTAssertEqual(checks.map(\.id), ["c1", "c2"])
    }

    func testAnUnchangedCommandKeepsItsIdAcrossAnEdit() {
        let previous = [check("keep", "swift test"), check("gone", "make lint")]
        let revised = Mission.revisedChecks(fromLines: "swift test\nnpm test", previous: previous, newID: { "new" })
        XCTAssertEqual(revised, [check("keep", "swift test"), check("new", "npm test")])
    }

    // MARK: - Lifecycle

    func testReadyMeansNothingIsRunningNotThatItIsRight() {
        let mission = Mission.Model(id: "m1", repoRoot: "/r", goal: "A", createdMs: t0)
        XCTAssertEqual(mission.lifecycle(candidateStatuses: []), .draft)
        XCTAssertEqual(mission.lifecycle(candidateStatuses: [.idle, .queued]), .running)
        XCTAssertEqual(mission.lifecycle(candidateStatuses: [.idle, .failed("x")]), .ready)
        var archived = mission
        archived.archived = true
        XCTAssertEqual(archived.lifecycle(candidateStatuses: [.running]), .archived)
    }

    // MARK: - Per-check standing

    func testEachCellSaysExactlyWhatIsKnown() {
        let mission = Mission.Model(
            id: "m1", repoRoot: "/r", goal: "A",
            checks: [check("c1", "swift test"), check("c2", "make lint")], createdMs: t0
        )
        var candidate = session("s1")
        candidate.missionID = "m1"
        candidate.contractRevision = 1
        let judge: (AcceptanceEvidence) -> EvidenceStanding = { $0.outcome == .passed ? .passing : .notPassing }

        XCTAssertEqual(Mission.standing(of: mission.contract.checks[0], candidate: candidate, mission: mission, judge: judge), .notRun)

        candidate.runningCheck = RunningCheck(command: "swift test", cwd: "/tmp", startedAtMs: t0, checkID: "c1")
        XCTAssertEqual(Mission.standing(of: mission.contract.checks[0], candidate: candidate, mission: mission, judge: judge), .running)
        candidate.runningCheck = nil

        // Evidence without a check id (ad hoc, or pre-13.0) never answers a check.
        candidate.acceptanceEvidence = [evidence(.passed, checkID: nil)]
        XCTAssertEqual(Mission.standing(of: mission.contract.checks[0], candidate: candidate, mission: mission, judge: judge), .notRun)

        let failed = evidence(.failed, checkID: "c1", exit: 2)
        candidate.acceptanceEvidence.append(failed)
        XCTAssertEqual(
            Mission.standing(of: mission.contract.checks[0], candidate: candidate, mission: mission, judge: judge),
            .evidence(.notPassing, failed)
        )
        XCTAssertEqual(Mission.standing(of: mission.contract.checks[1], candidate: candidate, mission: mission, judge: judge), .notRun)
    }

    func testANewRulerIsNeverLaidOverAnOldCandidate() {
        var mission = Mission.Model(id: "m1", repoRoot: "/r", goal: "A", checks: [check("c1", "swift test")], createdMs: t0)
        mission.revise(goal: "A", constraints: "", checks: [check("c1", "swift test"), check("c2", "make lint")], frozen: true)
        var old = session("s1")
        old.missionID = "m1"
        old.contractRevision = 1
        let judge: (AcceptanceEvidence) -> EvidenceStanding = { _ in .passing }
        XCTAssertEqual(Mission.standing(of: check("c2", "make lint"), candidate: old, mission: mission, judge: judge), .notInContract)
        XCTAssertEqual(Mission.standing(of: check("c1", "swift test"), candidate: old, mission: mission, judge: judge), .notRun)
    }

    func testTheNewestEvidenceForEachCheckSurvivesTrimming() {
        var list = [evidence(.passed, checkID: "c1")]
        for _ in 0..<(ManagedSession.maxAcceptanceEvidence + 5) {
            list.append(evidence(.failed, checkID: nil))
        }
        let trimmed = ManagedSession.trimEvidence(list)
        XCTAssertEqual(trimmed.count, ManagedSession.maxAcceptanceEvidence)
        XCTAssertTrue(trimmed.contains { $0.checkID == "c1" }, "the only answer to c1 must not be pushed out")
    }

    // MARK: - Persistence

    func testAMissionRoundTripsAndABadFileIsRefused() throws {
        var mission = Mission.Model(id: "m-1", repoRoot: "/r", goal: "A", checks: [check("c1", "make")], createdMs: t0)
        mission.candidateIDs = ["s1", "s2"]
        mission.chosenCandidateID = "s2"
        XCTAssertTrue(Mission.persist(mission))
        XCTAssertEqual(Mission.loadAll(), [mission])

        // Identity: the filename decides.
        let data = try Data(contentsOf: Mission.url(id: "m-1"))
        try data.write(to: missionDir.appendingPathComponent("impostor.json"))
        // Newer schema than this build: refused, not guessed at.
        var future = mission
        future.id = "m-2"
        future.schemaVersion = Mission.Model.currentSchemaVersion + 1
        try JSONEncoder().encode(future).write(to: Mission.url(id: "m-2"))
        XCTAssertEqual(Mission.loadAll().map(\.id), ["m-1"])
    }

    func testAnUnsafeIdIsNeverWritten() {
        let mission = Mission.Model(id: "../escape", repoRoot: "/r", goal: "A", createdMs: t0)
        XCTAssertFalse(Mission.persist(mission))
    }

    func testTheSessionStateCarriesItsMissionAndOldStatesStillLoad() throws {
        var m = session("s1")
        m.missionID = "m1"
        m.contractRevision = 2
        let state = ManagedSession.State(model: m)
        let decoded = try JSONDecoder().decode(ManagedSession.State.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.model().missionID, "m1")
        XCTAssertEqual(decoded.model().contractRevision, 2)

        // A schema-3 file (no mission fields) still loads, unassigned.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        legacy["schemaVersion"] = 3
        legacy.removeValue(forKey: "missionID")
        legacy.removeValue(forKey: "contractRevision")
        let old = try JSONDecoder().decode(
            ManagedSession.State.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertEqual(old.model().missionID, "")
    }

    // MARK: - Migration

    func testAttemptGroupsBecomeOneMissionAndStandaloneSessionsTheirOwn() {
        let sessions = [
            session("a1", group: "g", command: "swift test"),
            session("a2", group: "g", at: 1),
            session("solo", at: 2),
        ]
        let result = Mission.migrate(sessions: sessions, existing: [])
        XCTAssertEqual(result.missions.count, 2)
        let group = result.missions.first { $0.id == "legacy-g-g" }
        XCTAssertEqual(group?.candidateIDs, ["a1", "a2"])
        XCTAssertEqual(group?.contract.checks.map(\.command), ["swift test"], "the remembered command becomes a check")
        XCTAssertTrue(group?.legacy == true)
        XCTAssertEqual(result.missions.first { $0.id == "legacy-s-solo" }?.candidateIDs, ["solo"])
        XCTAssertEqual(Set(result.sessions.map(\.missionID)), ["legacy-g-g", "legacy-s-solo"])
        XCTAssertTrue(result.sessions.allSatisfy { $0.contractRevision == 1 })
    }

    func testMigrationNeverManufacturesEvidence() {
        var old = session("a1", command: "swift test")
        old.acceptanceEvidence = [evidence(.passed, checkID: nil)]
        let result = Mission.migrate(sessions: [old], existing: [])
        let mission = result.missions[0]
        let judge: (AcceptanceEvidence) -> EvidenceStanding = { _ in .passing }
        XCTAssertEqual(
            Mission.standing(of: mission.contract.checks[0], candidate: result.sessions[0], mission: mission, judge: judge),
            .notRun,
            "an old pass of the same command is history, not an answer to the migrated check"
        )
    }

    func testMigrationIsIdempotent() {
        let first = Mission.migrate(sessions: [session("a1", group: "g"), session("a2", group: "g", at: 1)], existing: [])
        let second = Mission.migrate(sessions: first.sessions, existing: first.missions)
        XCTAssertEqual(second.missions, first.missions)
        XCTAssertTrue(second.sessions.isEmpty, "nothing left to assign")
    }

    func testACandidateWhoseMissionFileIsGoneGetsItBack() {
        var orphan = session("s1")
        orphan.missionID = "m-lost"
        orphan.contractRevision = 1
        let result = Mission.migrate(sessions: [orphan], existing: [])
        XCTAssertEqual(result.missions.map(\.id), ["m-lost"])
        XCTAssertEqual(result.missions[0].candidateIDs, ["s1"])
        XCTAssertTrue(result.sessions.isEmpty, "its assignment was already right")
    }

    // MARK: - The fleet's part

    func testDispatchingACandidateBindsItToTheCurrentContract() {
        let fleet = ManagedFleet()
        fleet.startAction = { _ in }
        var mission = Mission.Model(
            id: "m1", repoRoot: "/r", goal: "Make login fast",
            constraints: "No schema changes", checks: [check("c1", "swift test")], createdMs: t0
        )
        mission.revise(goal: "Make login fast", constraints: "No schema changes", checks: [check("c1", "swift test")], frozen: false)
        fleet.create(mission)
        fleet.dispatch(candidate: session("s1"), missionID: "m1")

        let runner = fleet.candidates(of: "m1").first
        XCTAssertEqual(runner?.model.missionID, "m1")
        XCTAssertEqual(runner?.model.contractRevision, 1)
        XCTAssertEqual(runner?.model.pendingPrompt, "Make login fast\n\nNo schema changes")
        XCTAssertEqual(fleet.mission(id: "m1")?.candidateIDs, ["s1"])
        XCTAssertEqual(Mission.loadAll().first?.candidateIDs, ["s1"], "the Mission is on disk")
    }

    func testChoosingMarksOnlyAndChoosingAgainClears() {
        let fleet = ManagedFleet()
        fleet.startAction = { _ in }
        fleet.create(Mission.Model(id: "m1", repoRoot: "/r", goal: "A", createdMs: t0))
        fleet.dispatch(candidate: session("s1"), missionID: "m1")
        fleet.dispatch(candidate: session("s2"), missionID: "m1")
        fleet.choose(missionID: "m1", candidateID: "s2")
        XCTAssertEqual(fleet.mission(id: "m1")?.chosenCandidateID, "s2")
        fleet.choose(missionID: "m1", candidateID: "s2")
        XCTAssertNil(fleet.mission(id: "m1")?.chosenCandidateID)
        fleet.choose(missionID: "m1", candidateID: "not-a-candidate")
        XCTAssertNil(fleet.mission(id: "m1")?.chosenCandidateID)
    }

    func testRemovingTheLastCandidateRemovesTheMission() {
        let fleet = ManagedFleet()
        fleet.startAction = { _ in }
        fleet.create(Mission.Model(id: "m1", repoRoot: "/r", goal: "A", createdMs: t0))
        fleet.dispatch(candidate: session("s1"), missionID: "m1")
        fleet.remove(managedID: "s1")
        XCTAssertNil(fleet.mission(id: "m1"))
        XCTAssertTrue(Mission.loadAll().isEmpty)
    }

    func testAFailedFirstDispatchLeavesNoEmptyMission() {
        let fleet = ManagedFleet()
        fleet.create(Mission.Model(id: "m1", repoRoot: "/r", goal: "A", createdMs: t0))
        fleet.dropIfEmpty(missionID: "m1")
        XCTAssertNil(fleet.mission(id: "m1"))
        XCTAssertTrue(Mission.loadAll().isEmpty)
    }

    func testReattachMigratesPreMissionSessionsOnce() {
        XCTAssertTrue(ManagedSession.persist(session("a1", group: "g", command: "swift test")))
        XCTAssertTrue(ManagedSession.persist(session("a2", group: "g", at: 1)))

        let fleet = ManagedFleet()
        fleet.startAction = { _ in }
        fleet.reattachFromDisk()
        XCTAssertEqual(fleet.missions.map(\.id), ["legacy-g-g"])
        XCTAssertEqual(fleet.candidates(of: "legacy-g-g").map(\.model.id), ["a1", "a2"])
        XCTAssertEqual(ManagedSession.loadAll().map(\.missionID), ["legacy-g-g", "legacy-g-g"], "assignments are on disk")

        let again = ManagedFleet()
        again.startAction = { _ in }
        again.reattachFromDisk()
        XCTAssertEqual(again.missions, fleet.missions)
    }
}

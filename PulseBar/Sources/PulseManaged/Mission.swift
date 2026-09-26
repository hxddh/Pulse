import Foundation
import PulseCore

/// 13.0 — a result the user asked for, and how they will know it is done.
///
/// Before 13.0 a managed session owned a prompt and, at most, one remembered
/// check command; "the same task tried three ways" was an `attemptGroup` id and
/// nothing else. A Mission is the durable thing above that: the goal, the
/// user's constraints, the ordered checks that define "done", and the
/// Candidates (managed sessions) produced for it.
///
/// The contract — goal, constraints, checks — freezes when the first
/// Candidate starts. Editing it afterwards makes a new revision; a Candidate
/// keeps the revision it was started on, so a new ruler is never laid over an
/// old result. An agent cannot change the contract: only `revise` does, and
/// only the user's own edit calls it.
///
/// Nothing here ranks. `chosenCandidateID` is the user's explicit choice and
/// changes nothing but what the Workbench shows as chosen — no git write.
package enum Mission {
    package static let maxContracts = 20
    package static let maxChecks = 12
    package static let maxGoalLength = 8_000
    package static let maxConstraintsLength = 4_000
    package static let maxCommandLength = 1_000

    package struct Check: Codable, Equatable, Hashable, Sendable {
        package var id: String
        package var command: String

        package init(id: String, command: String) {
            self.id = id
            self.command = command
        }
    }

    /// One revision of what the user asked for.
    package struct Contract: Codable, Equatable, Sendable {
        package var revision: Int
        package var goal: String
        package var constraints: String
        package var checks: [Check]

        package init(revision: Int, goal: String, constraints: String, checks: [Check]) {
            self.revision = revision
            self.goal = goal
            self.constraints = constraints
            self.checks = checks
        }

        /// What the agent is told. Constraints ride along because they are
        /// part of the task; the checks do not — they are how the user will
        /// judge the result, and the agent has no say in them.
        package var prompt: String {
            let extra = constraints.trimmingCharacters(in: .whitespacesAndNewlines)
            return extra.isEmpty ? goal : goal + "\n\n" + extra
        }
    }

    /// Where a Mission stands. Derived from its Candidates — `ready` means
    /// none is still running, **not** that the result is right.
    package enum Lifecycle: String, Equatable, Sendable {
        case draft, running, ready, archived
    }

    package struct Model: Codable, Equatable, Sendable {
        package static let currentSchemaVersion = 1

        package var schemaVersion = Model.currentSchemaVersion
        package var id: String
        package var title: String
        package var repoRoot: String
        package var createdMs: Int64
        /// Ascending by revision; the last one is current.
        package var contracts: [Contract]
        /// Dispatch order — the only order the Workbench ever shows.
        package var candidateIDs: [String] = []
        package var chosenCandidateID: String? = nil
        package var archived = false
        /// Migrated from a pre-13.0 attempt group or standalone session:
        /// its goal is the session title, the only part of the task that was
        /// ever persisted.
        package var legacy = false

        package init(
            id: String,
            repoRoot: String,
            goal: String,
            constraints: String = "",
            checks: [Check] = [],
            createdMs: Int64
        ) {
            self.id = id
            self.repoRoot = repoRoot
            self.createdMs = createdMs
            let contract = Contract(
                revision: 1,
                goal: Mission.bound(goal, Mission.maxGoalLength),
                constraints: Mission.bound(constraints, Mission.maxConstraintsLength),
                checks: Array(checks.prefix(Mission.maxChecks))
            )
            self.contracts = [contract]
            self.title = Mission.title(from: contract.goal)
        }

        package var contract: Contract {
            contracts[contracts.count - 1]
        }

        package func contract(revision: Int) -> Contract? {
            contracts.first { $0.revision == revision }
        }

        /// Edit the contract. Before any Candidate started it is edited in
        /// place; afterwards the edit is a new revision, and the previous one
        /// stays for the Candidates that ran against it.
        package mutating func revise(goal: String, constraints: String, checks: [Check], frozen: Bool) {
            let next = Contract(
                revision: frozen ? contract.revision + 1 : contract.revision,
                goal: Mission.bound(goal, Mission.maxGoalLength),
                constraints: Mission.bound(constraints, Mission.maxConstraintsLength),
                checks: Array(checks.prefix(Mission.maxChecks))
            )
            guard next != contract else { return }
            if frozen {
                contracts.append(next)
                if contracts.count > Mission.maxContracts {
                    contracts.removeFirst(contracts.count - Mission.maxContracts)
                }
            } else {
                contracts[contracts.count - 1] = next
            }
            title = Mission.title(from: next.goal)
        }

        package func lifecycle(candidateStatuses: [ManagedSession.Status]) -> Lifecycle {
            if archived { return .archived }
            if candidateStatuses.isEmpty { return .draft }
            let active = candidateStatuses.contains { $0 == .running || $0 == .queued }
            return active ? .running : .ready
        }
    }

    // MARK: - Per-check standing

    /// One cell of the comparison: what is known about one check on one
    /// Candidate. Built from persisted evidence only.
    package enum CheckStanding: Equatable, Sendable {
        /// Not part of the contract revision this Candidate ran against.
        case notInContract
        case notRun
        case running
        case evidence(EvidenceStanding, AcceptanceEvidence)
    }

    package static func standing(
        of check: Check,
        candidate: ManagedSession.Model,
        mission: Model,
        judge: (AcceptanceEvidence) -> EvidenceStanding
    ) -> CheckStanding {
        let revision = mission.contract(revision: candidate.contractRevision) ?? mission.contract
        guard revision.checks.contains(where: { $0.id == check.id }) else { return .notInContract }
        if candidate.runningCheck?.checkID == check.id { return .running }
        guard let latest = candidate.acceptanceEvidence.last(where: { $0.checkID == check.id }) else {
            return .notRun
        }
        return .evidence(judge(latest), latest)
    }

    // MARK: - Composer input

    /// One command per line, blank lines and duplicates dropped, bounded.
    package static func checks(fromLines text: String, newID: () -> String) -> [Check] {
        var seen = Set<String>()
        var out: [Check] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let command = raw.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty, command.count <= maxCommandLength, seen.insert(command).inserted
            else { continue }
            out.append(Check(id: newID(), command: command))
            if out.count == maxChecks { break }
        }
        return out
    }

    /// Re-read an edited check list, keeping the id of every command that
    /// did not change so its evidence still answers it.
    package static func revisedChecks(
        fromLines text: String,
        previous: [Check],
        newID: () -> String
    ) -> [Check] {
        var byCommand: [String: String] = [:]
        for check in previous where byCommand[check.command] == nil {
            byCommand[check.command] = check.id
        }
        return checks(fromLines: text, newID: { "" }).map { check in
            Check(id: byCommand[check.command] ?? newID(), command: check.command)
        }
    }

    // MARK: - Migration (pre-13.0 sessions → Missions)

    /// Sessions from before Missions existed get one. An attempt group
    /// becomes one Mission with its sessions as Candidates; a standalone
    /// session becomes a single-Candidate Mission. A remembered check command
    /// becomes one check that **has not run** — old evidence stays the
    /// session's history and never answers the new check.
    ///
    /// Idempotent: ids are derived from the group or session, and sessions
    /// that already name a Mission are left alone.
    package static func migrate(
        sessions: [ManagedSession.Model],
        existing: [Model]
    ) -> (missions: [Model], sessions: [ManagedSession.Model]) {
        var missions = existing
        var index: [String: Int] = [:]
        for (i, mission) in missions.enumerated() { index[mission.id] = i }
        var updated: [ManagedSession.Model] = []
        for session in sessions.sorted(by: { $0.startedMs < $1.startedMs }) {
            let needsAssignment = session.missionID.isEmpty || !validID(session.missionID)
            let missionID = needsAssignment
                ? (session.attemptGroup.isEmpty
                    ? "legacy-s-" + session.id
                    : "legacy-g-" + session.attemptGroup)
                : session.missionID
            if index[missionID] == nil {
                // Either a pre-13.0 session, or a Candidate whose Mission file
                // is gone: rebuild what can honestly be rebuilt — the title as
                // goal, the remembered command as an unrun check.
                let command = session.runCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                var mission = Model(
                    id: missionID,
                    repoRoot: session.root,
                    goal: session.title,
                    checks: command.isEmpty ? [] : [Check(id: missionID + "-c1", command: command)],
                    createdMs: session.startedMs
                )
                mission.legacy = true
                index[missionID] = missions.count
                missions.append(mission)
            }
            if let i = index[missionID], !missions[i].candidateIDs.contains(session.id) {
                missions[i].candidateIDs.append(session.id)
            }
            if needsAssignment {
                var moved = session
                moved.missionID = missionID
                moved.contractRevision = 1
                updated.append(moved)
            }
        }
        return (missions, updated)
    }

    // MARK: - Persistence

    /// `~/Library/Application Support/Pulse/missions` — overridable for tests.
    nonisolated(unsafe) package static var directoryOverride: URL?

    package static func directory() -> URL {
        if let directoryOverride { return directoryOverride }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Pulse/missions", isDirectory: true)
    }

    package static func url(id: String) -> URL {
        directory().appendingPathComponent(id + ".json")
    }

    /// 0600 via PrivateFile — the goal is the user's own words.
    @discardableResult
    package static func persist(_ mission: Model) -> Bool {
        guard validID(mission.id) else { return false }
        try? FileManager.default.createDirectory(at: directory(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(mission) else { return false }
        return PrivateFile.write(data, to: url(id: mission.id))
    }

    package static func remove(id: String) {
        guard validID(id) else { return }
        try? FileManager.default.removeItem(at: url(id: id))
    }

    package static func loadAll() -> [Model] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory().path)
        else { return [] }
        var out: [Model] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let fileURL = directory().appendingPathComponent(name)
            guard let data = SafeRead.regularFile(atPath: fileURL.path, limit: 4 * 1024 * 1024),
                  let mission = try? JSONDecoder().decode(Model.self, from: data)
            else {
                DebugLog.write("mission refused file=\(name) reason=decode")
                continue
            }
            // Newer than this build: refuse and say so, never guess.
            guard mission.schemaVersion <= Model.currentSchemaVersion else {
                DebugLog.write("mission refused file=\(name) reason=schema")
                continue
            }
            // Filename decides identity — the spool rule.
            guard name == mission.id + ".json", !mission.contracts.isEmpty else {
                DebugLog.write("mission refused file=\(name) reason=identity")
                continue
            }
            out.append(mission)
        }
        return out.sorted { $0.createdMs < $1.createdMs }
    }

    package static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // MARK: - Helpers

    static func bound(_ text: String, _ limit: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) : t
    }

    static func title(from goal: String) -> String {
        let firstLine = goal.split(whereSeparator: \.isNewline).first.map(String.init) ?? goal
        let cleaned = ContentSanitizer.redact(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > ManagedSession.maxTitleLength
            ? String(cleaned.prefix(ManagedSession.maxTitleLength)) + "…"
            : cleaned
    }
}

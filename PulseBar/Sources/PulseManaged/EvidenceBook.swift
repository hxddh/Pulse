import CryptoKit
import Foundation
import PulseCore

/// 14.0 · acceptance evidence belongs to a working copy, not to a session.
///
/// Until 13.0 checks, evidence and "is that pass still current" lived inside
/// `ManagedSessionRunner`: only a session Pulse had launched could be held to
/// the user's ruler. Most real work happens in sessions the user started
/// themselves — Claude Code, Codex, Cursor in their own terminals — and those
/// were observed, measured for what changed on disk, and never checked.
///
/// The book keys everything by the working copy's root: the user's checks for
/// that directory, the evidence each check produced, the check running now,
/// and the one `AcceptanceRunner` that knows the current code identity. A
/// managed Candidate reads its own worktree's page; an observed session reads
/// the page of the directory it works in. Checks only ever run on the user's
/// click, and the agent never sees them.
///
/// One 0600 file per root under `Pulse/evidence`, named by a digest of the
/// root and refused when the root inside does not hash to its name.
@MainActor
package final class EvidenceBook {
    /// The on-disk page for one working copy.
    package struct Record: Codable, Equatable, Sendable {
        package static let currentSchemaVersion = 1

        package var schemaVersion = Record.currentSchemaVersion
        package var root: String
        /// The user's own ruler for this working copy (observed sessions).
        /// Mission Candidates are judged by their Mission's contract instead.
        package var checks: [Mission.Check] = []
        package var evidence: [AcceptanceEvidence] = []
        package var runningCheck: RunningCheck? = nil

        package init(root: String) {
            self.root = root
        }

        package var isEmpty: Bool {
            checks.isEmpty && evidence.isEmpty && runningCheck == nil
        }
    }

    /// What the tray may say about a working copy's checks: counts only.
    package struct Summary: Equatable, Sendable {
        package var total = 0
        package var passing = 0
        package var failing = 0
        package var stale = 0

        package init(total: Int = 0, passing: Int = 0, failing: Int = 0, stale: Int = 0) {
            self.total = total
            self.passing = passing
            self.failing = failing
            self.stale = stale
        }
    }

    /// Fired after any change a surface shows.
    package var onChange: (() -> Void)?

    package private(set) var records: [String: Record] = [:]
    private var runners: [String: AcceptanceRunner] = [:]
    private var queues: [String: [Mission.Check]] = [:]
    private let persists: Bool

    package init(persists: Bool = true) {
        self.persists = persists
    }

    // MARK: - Identity

    /// The key for a root: the standardized absolute path.
    package nonisolated static func key(_ root: String) -> String {
        guard !root.isEmpty else { return "" }
        return URL(fileURLWithPath: root).standardizedFileURL.path
    }

    // MARK: - Reading

    package func record(for root: String) -> Record {
        let key = Self.key(root)
        return records[key] ?? Record(root: key)
    }

    package func evidence(for root: String) -> [AcceptanceEvidence] {
        records[Self.key(root)]?.evidence ?? []
    }

    package func runningCheck(for root: String) -> RunningCheck? {
        records[Self.key(root)]?.runningCheck
    }

    package func checks(for root: String) -> [Mission.Check] {
        records[Self.key(root)]?.checks ?? []
    }

    package func queued(at root: String) -> [Mission.Check] {
        queues[Self.key(root)] ?? []
    }

    package func isChecking(at root: String) -> Bool {
        runners[Self.key(root)]?.isChecking ?? false
    }

    /// A check running or waiting its turn.
    package func isBusy(at root: String) -> Bool {
        isChecking(at: root) || !queued(at: root).isEmpty
    }

    /// The runner that knows this working copy's current code identity.
    package func runner(for root: String) -> AcceptanceRunner {
        let key = Self.key(root)
        if let runner = runners[key] { return runner }
        let runner = AcceptanceRunner(root: key)
        runner.onChange = { [weak self] in self?.runnerChanged(key) }
        runners[key] = runner
        return runner
    }

    package func standing(of evidence: AcceptanceEvidence, at root: String) -> EvidenceStanding {
        runner(for: root).standing(of: evidence)
    }

    /// Re-measure the working copy now (off main). Opening a view that
    /// shows evidence asks for this; nothing measures on its own except a
    /// live pass's slow watch.
    package func refresh(at root: String) {
        guard !Self.key(root).isEmpty, !evidence(for: root).isEmpty else { return }
        runner(for: root).refresh()
    }

    /// Counts for `checks` against the newest evidence of each, judged on
    /// the code as it is now. A check with no evidence counts toward
    /// `total` only — never toward passing.
    package func summary(of checks: [Mission.Check], at root: String) -> Summary {
        var summary = Summary(total: checks.count)
        let all = evidence(for: root)
        for check in checks {
            guard let latest = all.last(where: { $0.checkID == check.id }) else { continue }
            switch standing(of: latest, at: root) {
            case .passing: summary.passing += 1
            case .stale: summary.stale += 1
            case .notPassing: summary.failing += 1
            // "Could not confirm" is not a failure, and not a pass either.
            case .unverified, .measuring: break
            }
        }
        return summary
    }

    // MARK: - The user's ruler for a working copy

    /// Setting checks is the opt-in: a working copy with none is never
    /// checked. Unchanged commands keep their ids, so their evidence still
    /// answers them.
    package func setChecks(_ checks: [Mission.Check], for root: String) {
        let key = Self.key(root)
        guard !key.isEmpty else { return }
        var record = self.record(for: key)
        let bounded = Array(checks.prefix(Mission.maxChecks))
        guard record.checks != bounded else { return }
        record.checks = bounded
        store(record)
        onChange?()
    }

    // MARK: - Running

    /// One check, bound to the code before and after it.
    package func runCheck(
        command rawCommand: String,
        checkID: String?,
        at root: String,
        completion: (() -> Void)? = nil
    ) {
        let key = Self.key(root)
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !command.isEmpty else { return }
        let runner = self.runner(for: key)
        guard !runner.isChecking else { return }
        var record = self.record(for: key)
        record.runningCheck = RunningCheck(
            command: command, cwd: key,
            startedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            checkID: checkID
        )
        // Written before the process starts: a check the app does not live to
        // finish comes back as interrupted, never as a result nobody saw.
        store(record)
        onChange?()
        runner.run(command: command) { [weak self] evidence in
            guard let self else { return }
            var tagged = evidence
            tagged.checkID = checkID
            var finished = self.record(for: key)
            finished.runningCheck = nil
            finished.evidence.append(tagged)
            finished.evidence = ManagedSession.trimEvidence(finished.evidence)
            self.store(finished)
            self.runners[key]?.watch(latest: finished.evidence.last)
            completion?()
            self.onChange?()
        }
    }

    /// Checks in the user's order, one at a time, carrying on after a
    /// failure: a comparison needs the whole ruler applied.
    package func runChecks(_ checks: [Mission.Check], at root: String) {
        let key = Self.key(root)
        guard !key.isEmpty, !checks.isEmpty, !isBusy(at: key) else { return }
        queues[key] = checks
        runNext(at: key)
    }

    /// Stop the running check (recorded as interrupted) and drop the rest
    /// (they stay not run).
    package func cancel(at root: String) {
        let key = Self.key(root)
        guard isBusy(at: key) else { return }
        queues[key] = nil
        runners[key]?.cancel()
        onChange?()
    }

    /// Forget checks that have not started — the code is about to change
    /// under them (a new turn).
    package func dropQueue(at root: String) {
        queues[Self.key(root)] = nil
    }

    private func runNext(at key: String) {
        guard var queue = queues[key], !queue.isEmpty else {
            queues[key] = nil
            onChange?()
            return
        }
        let next = queue.removeFirst()
        queues[key] = queue.isEmpty ? nil : queue
        runCheck(command: next.command, checkID: next.id, at: key) { [weak self] in
            self?.runNext(at: key)
        }
        // A check that could not start ends the queue rather than spinning.
        if !isChecking(at: key) { queues[key] = nil }
    }

    private func runnerChanged(_ key: String) {
        runners[key]?.watch(latest: records[key]?.evidence.last)
        onChange?()
    }

    // MARK: - Migration

    /// Evidence that used to live in a managed session's state (≤ 13.0).
    package func adopt(evidence: [AcceptanceEvidence], at root: String) {
        let key = Self.key(root)
        guard !key.isEmpty, !evidence.isEmpty else { return }
        var record = self.record(for: key)
        record.evidence = ManagedSession.trimEvidence(record.evidence + evidence)
        store(record)
        if record.evidence.last?.outcome == .passed { runner(for: key).refresh() }
    }

    // MARK: - Persistence

    /// `~/Library/Application Support/Pulse/evidence` — overridable for tests.
    nonisolated(unsafe) package static var directoryOverride: URL?

    package nonisolated static func directory() -> URL {
        if let directoryOverride { return directoryOverride }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Pulse/evidence", isDirectory: true)
    }

    package nonisolated static func fileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(digest.prefix(32)) + ".json"
    }

    /// Load every page. A check that was running when the app went away comes
    /// back as interrupted evidence.
    package func loadFromDisk() {
        guard persists else { return }
        let dir = Self.directory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = SafeRead.regularFile(atPath: url.path, limit: 8 * 1024 * 1024),
                  var record = try? JSONDecoder().decode(Record.self, from: data)
            else {
                DebugLog.write("evidence refused file=\(name) reason=decode")
                continue
            }
            guard record.schemaVersion <= Record.currentSchemaVersion else {
                DebugLog.write("evidence refused file=\(name) reason=schema")
                continue
            }
            let key = Self.key(record.root)
            guard !key.isEmpty, Self.fileName(for: key) == name else {
                DebugLog.write("evidence refused file=\(name) reason=identity")
                continue
            }
            record.root = key
            if let running = record.runningCheck {
                record.runningCheck = nil
                record.evidence = ManagedSession.trimEvidence(record.evidence + [running.interruptedEvidence()])
                write(record)
            }
            records[key] = record
            if record.evidence.last?.outcome == .passed { runner(for: key).refresh() }
        }
    }

    package func shutdown() {
        for runner in runners.values { runner.shutdown() }
    }

    private func store(_ record: Record) {
        let key = Self.key(record.root)
        guard !key.isEmpty else { return }
        if record.isEmpty {
            records[key] = nil
            if persists { try? FileManager.default.removeItem(at: Self.directory().appendingPathComponent(Self.fileName(for: key))) }
        } else {
            records[key] = record
            write(record)
        }
    }

    private func write(_ record: Record) {
        guard persists else { return }
        let dir = Self.directory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record) else { return }
        _ = PrivateFile.write(data, to: dir.appendingPathComponent(Self.fileName(for: Self.key(record.root))))
    }
}

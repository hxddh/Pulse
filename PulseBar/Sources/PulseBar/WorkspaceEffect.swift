import Foundation

/// What actually changed on disk.
///
/// Every other fact Pulse has is either something the agent wrote about
/// itself (transcripts, caches) or the fact that a process is alive (`ps`).
/// Both answer *what is it doing*. Neither has ever been able to answer
/// **what did it get done** — a session can talk for an hour, burn a core,
/// and leave the working copy untouched, and until now that looked exactly
/// like progress.
///
/// This is the first evidence axis that is not a vendor's account of itself:
/// a change on disk is not a claim, and it needs **no adapter** — a working
/// copy belongs to no vendor, so one implementation covers all 32 agents and
/// every agent added after them.
///
/// Three commands, all `--no-optional-locks`. That flag is not optional:
/// `git status` refreshes and **writes back** the index stat cache by
/// default, which would break the read-only rule and contend for
/// `index.lock` with the user's own git commands. The flag exists precisely
/// for bystanders like editors and status bars.
enum WorkspaceEffect {
    /// Counts only. No path, no branch, no diff text ever leaves this type —
    /// those are content, and this axis is about magnitude.
    struct Measurement: Equatable {
        /// Canonical repository root, used to tell two agents in the same
        /// working copy apart from two agents in different ones. Never shown.
        var root: String = ""
        /// Changed paths including newly created files. -1 = not known.
        var changedPaths: Int = -1
        /// Tracked changes against HEAD. -1 = not known.
        var insertions: Int = -1
        var deletions: Int = -1
        var measuredAtMs: Int64 = 0

        /// **-1 is not 0.** "Measured, and nothing has landed" is the whole
        /// point of this axis; "not measured" must never wear its clothes.
        var isKnown: Bool { changedPaths >= 0 }
        /// Measured, and the working copy is exactly as it was.
        var nothingLanded: Bool { changedPaths == 0 }
        var hasLineCounts: Bool { insertions >= 0 || deletions >= 0 }
    }

    static let executable = "/usr/bin/git"
    /// A working copy that cannot answer in this long is a working copy Pulse
    /// will not wait on. A menu-bar tool blocking on someone's monorepo is
    /// the energy-hog failure the whole cadence design exists to avoid.
    static let timeout: TimeInterval = 1.5
    /// Past this a root is put in backoff and reported as unknown until the
    /// penalty expires — honest, and self-limiting.
    static let slowMeasurementMs = 900
    static let backoffMs: Int64 = 5 * 60 * 1000
    /// `git status` on a huge tree can print a great deal. Only the line
    /// count is wanted, so the read stays small.
    static let outputLimit = 512 * 1024

    // MARK: - Pure parsing

    /// `7 files changed, 142 insertions(+), 38 deletions(-)`
    ///
    /// Every clause is optional: a pure-addition diff has no deletions, a
    /// pure-deletion diff has no insertions, and a mode-only change has
    /// neither. A clause that is absent is **0 for that clause**, because the
    /// line itself is git's complete statement about the diff — unlike a
    /// failed command, which is not a statement at all.
    static func parseShortstat(_ raw: String) -> (files: Int, insertions: Int, deletions: Int)? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        func number(before keyword: String) -> Int? {
            // Fields are `N word`, comma separated. Match on the prefix so
            // "insertion(+)" and "insertions(+)" both land.
            for field in line.split(separator: ",") {
                let parts = field.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, parts[1].hasPrefix(keyword) else { continue }
                guard let value = Int(parts[0]), value >= 0 else { return nil }
                return value
            }
            return nil
        }
        guard let files = number(before: "file") else { return nil }
        return (files, number(before: "insertion") ?? 0, number(before: "deletion") ?? 0)
    }

    /// One changed path per line in `--porcelain=v1`, untracked files included
    /// as `??`. Blank lines are not paths.
    static func parsePorcelainCount(_ raw: String) -> Int {
        raw.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    /// A root is only usable if git printed an absolute path and nothing else.
    static func parseToplevel(_ raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("/"), line.count > 1, !line.contains("\n") else { return nil }
        return line
    }

    /// Which live rows share a working copy.
    ///
    /// The fact no single agent can see: each one knows only itself, so two
    /// agents editing the same checkout is invisible from inside either. It
    /// is plainly visible from here, and it is the one thing on this axis
    /// that no other tool could report.
    ///
    /// Remote rows never take part — their path describes another machine's
    /// disk, and a collision there would be pure invention.
    static func collisionCounts(_ rows: [AgentRow]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in rows where !row.isRemote && row.liveProcess && !row.workspaceRoot.isEmpty {
            counts[row.workspaceRoot, default: 0] += 1
        }
        return counts.filter { $0.value >= 2 }
    }

    // MARK: - Bounded execution

    /// The exact argv for one command, so the read-only guarantee is a
    /// testable property of this type rather than a promise in a comment.
    ///
    /// `--no-optional-locks` leads every invocation. Without it `git status`
    /// refreshes and **writes back** the index stat cache, which would break
    /// the read-only rule and contend for `index.lock` with the user's own
    /// git commands.
    static func arguments(for command: [String], in directory: String) -> [String] {
        ["--no-optional-locks", "-C", directory] + command
    }

    /// Test seam: every command this type runs goes through here, so the
    /// rules above can be held to fixtures without a repository on disk.
    static var runner: (String, [String]) -> ProcessIO.Result? = { directory, command in
        ProcessIO.run(
            executable: executable,
            arguments: arguments(for: command, in: directory),
            timeout: timeout,
            outputLimit: outputLimit
        )
    }

    private static func text(_ result: ProcessIO.Result?) -> String? {
        guard let result, !result.timedOut, result.status == 0 else { return nil }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// Repository root for a working directory, or nil when it is not one.
    /// Cheap and stable: `rev-parse` touches no index, and a directory's root
    /// does not change, so callers cache this for the life of the row.
    static func repositoryRoot(of directory: String) -> String? {
        guard let out = text(runner(directory, ["rev-parse", "--show-toplevel"])) else { return nil }
        return parseToplevel(out)
    }

    /// One measurement of one working copy. Returns an unknown measurement
    /// rather than nil when git answered but said nothing usable — the
    /// difference between "no repository here" (nil) and "a repository that
    /// has not moved" (0) is exactly what this axis exists to state.
    static func measure(root: String, nowMs: Int64) -> Measurement {
        var measurement = Measurement(root: root, measuredAtMs: nowMs)
        guard let status = text(runner(root, ["status", "--porcelain=v1"])) else {
            return measurement
        }
        measurement.changedPaths = parsePorcelainCount(status)
        // Line counts are a second, softer fact: a working copy with only
        // untracked files has changed paths and no diff against HEAD, and
        // that is not a failure.
        if let shortstat = text(runner(root, ["diff", "--shortstat", "HEAD"])),
           let parsed = parseShortstat(shortstat) {
            measurement.insertions = parsed.insertions
            measurement.deletions = parsed.deletions
        } else if measurement.changedPaths == 0 {
            // Nothing changed at all, so the absent diff is agreement rather
            // than an unanswered question.
            measurement.insertions = 0
            measurement.deletions = 0
        }
        return measurement
    }
}

/// Per-root cache, cadence and the slow-repository circuit.
///
/// Kept apart from the measuring so the policy — how often, how many, when to
/// give up on a root — can be tested on a fake clock without running git.
struct WorkspaceEffectStore {
    /// How long a measurement stands before it is worth taking again. Well
    /// above the fastest probe tick: a working copy does not change faster
    /// than a person can read about it, and each measurement is two forks.
    static let freshnessMs: Int64 = 10_000
    /// A ceiling on how many distinct working copies are measured per tick,
    /// so a machine with a dozen agents cannot turn one scan into two dozen
    /// subprocesses.
    static let maxRootsPerTick = 6
    /// Bound on retained roots — the same shape as the CPU sample store.
    static let maxRoots = 64

    private var measurements: [String: WorkspaceEffect.Measurement] = [:]
    private var backoffUntilMs: [String: Int64] = [:]
    /// Working directory → repository root, cached for the life of the app.
    /// A directory's root does not change, and `rev-parse` is the one call
    /// here that touches no index — but it is still a fork, so it is paid
    /// once per directory rather than once per tick. An empty value is a
    /// remembered "not a repository", so a plain folder is not re-asked
    /// every scan either.
    private var rootByDirectory: [String: String] = [:]

    /// Resolve the directories this scan cares about, measure the roots that
    /// are due, and hand back a table keyed by directory for the builder.
    ///
    /// Runs on the scan queue: two forks per root, bounded and capped.
    mutating func refresh(directories: [String], nowMs: Int64) -> [String: WorkspaceEffect.Measurement] {
        let wanted = Array(Set(directories.filter { $0.hasPrefix("/") && $0.count > 1 }))
        for directory in wanted where rootByDirectory[directory] == nil {
            rootByDirectory[directory] = WorkspaceEffect.repositoryRoot(of: directory) ?? ""
        }
        let roots = Array(Set(wanted.compactMap { directory -> String? in
            let root = rootByDirectory[directory] ?? ""
            return root.isEmpty ? nil : root
        }))
        for root in due(roots: roots, nowMs: nowMs) {
            let started = Date()
            let measurement = WorkspaceEffect.measure(root: root, nowMs: nowMs)
            record(
                measurement,
                tookMs: Int(Date().timeIntervalSince(started) * 1000),
                nowMs: nowMs
            )
        }
        var byDirectory: [String: WorkspaceEffect.Measurement] = [:]
        for directory in wanted {
            let root = rootByDirectory[directory] ?? ""
            guard !root.isEmpty else { continue }
            // A root inside its penalty reports unknown rather than a stale
            // number wearing a fresh timestamp.
            guard !isInBackoff(root, nowMs: nowMs), let measurement = measurement(for: root) else {
                byDirectory[directory] = WorkspaceEffect.Measurement(root: root)
                continue
            }
            byDirectory[directory] = measurement
        }
        return byDirectory
    }

    /// Roots that are stale enough to be worth measuring again, oldest first,
    /// bounded, and skipping anything inside its backoff penalty.
    func due(roots: [String], nowMs: Int64) -> [String] {
        roots
            .filter { (backoffUntilMs[$0] ?? 0) <= nowMs }
            .filter { nowMs - (measurements[$0]?.measuredAtMs ?? 0) >= Self.freshnessMs }
            .sorted { (measurements[$0]?.measuredAtMs ?? 0) < (measurements[$1]?.measuredAtMs ?? 0) }
            .prefix(Self.maxRootsPerTick)
            .map { $0 }
    }

    /// Record a measurement and, when it cost too much, stop asking this root
    /// for a while. The measurement is still recorded: a slow answer is a
    /// real answer, and dropping it would report unknown for something that
    /// was in fact measured.
    mutating func record(_ measurement: WorkspaceEffect.Measurement, tookMs: Int, nowMs: Int64) {
        guard !measurement.root.isEmpty else { return }
        measurements[measurement.root] = measurement
        if tookMs >= WorkspaceEffect.slowMeasurementMs {
            backoffUntilMs[measurement.root] = nowMs + WorkspaceEffect.backoffMs
        } else {
            backoffUntilMs.removeValue(forKey: measurement.root)
        }
        prune()
    }

    func measurement(for root: String) -> WorkspaceEffect.Measurement? {
        measurements[root]
    }

    func isInBackoff(_ root: String, nowMs: Int64) -> Bool {
        (backoffUntilMs[root] ?? 0) > nowMs
    }

    private mutating func prune() {
        guard measurements.count > Self.maxRoots else { return }
        let keep = measurements
            .sorted { $0.value.measuredAtMs > $1.value.measuredAtMs }
            .prefix(Self.maxRoots)
        measurements = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        backoffUntilMs = backoffUntilMs.filter { measurements[$0.key] != nil }
    }
}

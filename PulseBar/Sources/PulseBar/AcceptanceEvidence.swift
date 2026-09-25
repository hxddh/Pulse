import CryptoKit
import Foundation

/// Durable facts produced by one user-defined acceptance check. This type is
/// deliberately independent of the runner and UI so persisted evidence can be
/// decoded and judged again after either changes.
struct AcceptanceEvidence: Codable, Equatable {
    static let outputLimitBytes = 64 * 1024

    enum Outcome: String, Codable, Equatable {
        case passed, failed, timedOut, couldNotRun
        case invalidatedDuringRun, interrupted
    }

    var command: String
    var cwd: String
    var startedAtMs: Int64
    var finishedAtMs: Int64
    var stdout: Data
    var stderr: Data
    var exitCode: Int32?
    var preFingerprint: CodeFingerprint?
    var postFingerprint: CodeFingerprint?
    var outcome: Outcome

    /// Pure state table. Callers bound output before constructing this value.
    static func make(
        command: String,
        cwd: String,
        startedAtMs: Int64,
        finishedAtMs: Int64,
        stdout: Data,
        stderr: Data,
        exitCode: Int32?,
        preFingerprint: CodeFingerprint?,
        postFingerprint: CodeFingerprint?,
        timedOut: Bool = false,
        interrupted: Bool = false
    ) -> AcceptanceEvidence {
        let outcome: Outcome
        if interrupted {
            outcome = .interrupted
        } else if timedOut {
            outcome = .timedOut
        } else if exitCode == nil || preFingerprint == nil || postFingerprint == nil {
            outcome = .couldNotRun
        } else if preFingerprint != postFingerprint {
            outcome = .invalidatedDuringRun
        } else if exitCode == 0 {
            outcome = .passed
        } else {
            outcome = .failed
        }
        return AcceptanceEvidence(
            command: command, cwd: cwd, startedAtMs: startedAtMs,
            finishedAtMs: finishedAtMs,
            stdout: Data(stdout.suffix(outputLimitBytes)),
            stderr: Data(stderr.suffix(outputLimitBytes)),
            exitCode: exitCode, preFingerprint: preFingerprint,
            postFingerprint: postFingerprint, outcome: outcome
        )
    }
}

/// A check that has started and not yet produced evidence. Persisted, so a
/// check the app did not live to finish comes back as `interrupted` rather
/// than vanishing — and never as a result nobody saw.
struct RunningCheck: Codable, Equatable {
    var command: String
    var cwd: String
    var startedAtMs: Int64

    func interruptedEvidence() -> AcceptanceEvidence {
        AcceptanceEvidence.make(
            command: command, cwd: cwd, startedAtMs: startedAtMs, finishedAtMs: startedAtMs,
            stdout: Data(), stderr: Data(), exitCode: nil,
            preFingerprint: nil, postFingerprint: nil, interrupted: true
        )
    }
}

/// SHA-256 identity of the exact Git worktree content relevant to a check.
/// `nil` is the only unknown representation: partial identities are unsafe.
///
/// The identity is the **content** of the worktree — every path with its mode
/// and blob id — never the commit it happens to sit on. 11.0.3 fed `HEAD` and
/// a diff against it, so committing the very code a check had just passed
/// produced a new identity and the evidence read as stale at exactly the
/// moment it mattered. Measuring stays read-only: blob ids for changed and
/// untracked files are computed here, nothing is written to the object store
/// or the index.
struct CodeFingerprint: Codable, Equatable {
    var sha256: String

    struct Limits: Equatable {
        var gitOutputBytes = 32 * 1024 * 1024
        var untrackedFileBytes = 16 * 1024 * 1024
        var totalUntrackedBytes = 64 * 1024 * 1024
        var untrackedPaths = 10_000
        var pathBytes = 16 * 1024
        var gitTimeout: TimeInterval = 15

        static let `default` = Limits()
    }

    /// One worktree path as Git would record it.
    struct Entry: Equatable {
        var mode: String
        var object: String
    }

    static func measure(
        cwd: String,
        gitExecutable: String = "/usr/bin/git",
        limits: Limits = .default
    ) -> CodeFingerprint? {
        guard limits.gitOutputBytes > 0, limits.untrackedFileBytes >= 0,
              limits.totalUntrackedBytes >= 0, limits.untrackedPaths >= 0,
              limits.pathBytes > 0, limits.gitTimeout > 0 else { return nil }

        let environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_OPTIONAL_LOCKS": "0"], uniquingKeysWith: { _, required in required }
        )
        func git(_ arguments: [String]) -> Data? {
            guard let result = ProcessIO.run(
                executable: gitExecutable, arguments: ["-C", cwd] + arguments,
                environment: environment, timeout: limits.gitTimeout,
                outputLimit: limits.gitOutputBytes + 1
            ), !result.timedOut, result.status == 0,
                  result.stdout.count <= limits.gitOutputBytes,
                  result.stderr.count <= limits.gitOutputBytes else { return nil }
            return result.stdout
        }
        func strictString(_ data: Data) -> String? { String(data: data, encoding: .utf8) }

        guard let rootData = git(["rev-parse", "--show-toplevel"]),
              let rootText = strictString(rootData)?.trimmingCharacters(in: .newlines),
              !rootText.isEmpty,
              let tree = git(["-C", rootText, "ls-tree", "-r", "-z", "--full-tree", "HEAD"]),
              // Plumbing only: porcelain `git diff` may refresh the index.
              // `diff-index` names every tracked path whose worktree content
              // may differ from HEAD, staged or not, without writing anything.
              let changed = git(["-C", rootText, "diff-index", "--raw", "-z", "HEAD", "--"]),
              let names = git(["-C", rootText, "ls-files", "--others", "--exclude-standard", "-z"])
        else { return nil }

        let root = URL(fileURLWithPath: rootText, isDirectory: true).resolvingSymlinksInPath()
        guard root.path.utf8.count <= limits.pathBytes,
              var entries = parseTree(tree),
              let changedPaths = parseChangedPaths(changed)
        else { return nil }
        let untracked = names.split(separator: 0, omittingEmptySubsequences: true)
        guard untracked.count <= limits.untrackedPaths else { return nil }
        // Blob ids in this repository's own object format, so an unchanged
        // file hashed here matches the id HEAD already records for it.
        let sha256Objects = entries.values.first.map { $0.object.count == 64 } ?? false

        var total = 0
        func worktreeEntry(_ relative: String) -> Entry?? {
            guard relative.utf8.count <= limits.pathBytes, !relative.hasPrefix("/"),
                  !relative.split(separator: "/").contains("..") else { return .some(nil) }
            let url = root.appendingPathComponent(relative)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
            catch {
                // Gone from the worktree: a deletion, not an unknown.
                return FileManager.default.fileExists(atPath: url.path) ? .some(nil) : .none
            }
            let type = attributes[.type] as? FileAttributeType
            let content: Data
            let mode: String
            do {
                if type == .typeSymbolicLink {
                    content = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
                    mode = "120000"
                } else {
                    let resolved = url.resolvingSymlinksInPath().path
                    let isWithinRoot = root.path == "/" ? resolved.hasPrefix("/") : resolved.hasPrefix(root.path + "/")
                    guard type == .typeRegular, isWithinRoot else { return .some(nil) }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var data = Data()
                    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        guard data.count <= limits.untrackedFileBytes - chunk.count,
                              total <= limits.totalUntrackedBytes - chunk.count else { return .some(nil) }
                        data.append(chunk)
                        total += chunk.count
                    }
                    content = data
                    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                    mode = permissions & 0o111 != 0 ? "100755" : "100644"
                }
            } catch { return .some(nil) }
            guard content.count <= limits.untrackedFileBytes else { return .some(nil) }
            if mode == "120000" {
                guard total <= limits.totalUntrackedBytes - content.count else { return .some(nil) }
                total += content.count
            }
            return .some(Entry(mode: mode, object: blobID(content, sha256: sha256Objects)))
        }

        for path in changedPaths {
            switch worktreeEntry(path) {
            case .none: entries[path] = nil
            case .some(nil): return nil
            case .some(let entry?): entries[path] = entry
            }
        }
        for bytes in untracked {
            guard let relative = strictString(Data(bytes)) else { return nil }
            guard case .some(let entry?) = worktreeEntry(relative) else { return nil }
            entries[relative] = entry
        }
        return identity(root: root.path, entries: entries)
    }

    /// Pure: the identity of a set of worktree entries.
    static func identity(root: String, entries: [String: Entry]) -> CodeFingerprint {
        var hasher = SHA256()
        func feed(_ label: String, _ data: Data) {
            hasher.update(data: Data("\(label):\(data.count):".utf8))
            hasher.update(data: data)
        }
        feed("fingerprint", Data("content-v2".utf8))
        feed("root", Data(root.utf8))
        for path in entries.keys.sorted() {
            guard let entry = entries[path] else { continue }
            feed("path", Data(path.utf8))
            feed("mode", Data(entry.mode.utf8))
            feed("object", Data(entry.object.utf8))
        }
        return CodeFingerprint(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Git's own blob id for `content`, so a file hashed here and the same
    /// file recorded in HEAD compare equal.
    static func blobID(_ content: Data, sha256: Bool = false) -> String {
        var header = Data("blob \(content.count)".utf8)
        header.append(0)
        if sha256 {
            var hasher = SHA256()
            hasher.update(data: header)
            hasher.update(data: content)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var hasher = Insecure.SHA1()
        hasher.update(data: header)
        hasher.update(data: content)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `ls-tree -r -z`: `<mode> SP <type> SP <object> TAB <path> NUL`.
    static func parseTree(_ data: Data) -> [String: Entry]? {
        var entries: [String: Entry] = [:]
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: 9),
                  let meta = String(data: Data(record[record.startIndex..<tab]), encoding: .utf8),
                  let path = String(data: Data(record[record.index(after: tab)...]), encoding: .utf8)
            else { return nil }
            let fields = meta.split(separator: " ")
            guard fields.count == 3 else { return nil }
            entries[path] = Entry(mode: String(fields[0]), object: String(fields[2]))
        }
        return entries
    }

    /// `diff-index --raw -z`: `:<modes and ids> <status> NUL <path> NUL`.
    /// Only the paths matter — their content is measured, not trusted.
    static func parseChangedPaths(_ data: Data) -> [String]? {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var paths: [String] = []
        var index = 0
        while index < fields.count {
            guard fields[index].first == UInt8(ascii: ":"), index + 1 < fields.count,
                  let path = String(data: Data(fields[index + 1]), encoding: .utf8)
            else { return nil }
            paths.append(path)
            index += 2
        }
        return paths
    }
}

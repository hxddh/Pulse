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

/// SHA-256 identity of the exact Git worktree content relevant to a check.
/// `nil` is the only unknown representation: partial identities are unsafe.
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
              let headData = git(["rev-parse", "--verify", "HEAD"]),
              let head = strictString(headData)?.trimmingCharacters(in: .newlines),
              !head.isEmpty,
              // Plumbing only: porcelain `git diff` may refresh the index.
              // `diff-index` covers staged and unstaged tracked content
              // without turning this measurement into a write operation.
              let diff = git(["diff-index", "-p", "--binary", "HEAD", "--"]),
              let names = git(["ls-files", "--others", "--exclude-standard", "-z"])
        else { return nil }

        let root = URL(fileURLWithPath: rootText, isDirectory: true).resolvingSymlinksInPath()
        guard root.path.utf8.count <= limits.pathBytes else { return nil }
        let entries = names.split(separator: 0, omittingEmptySubsequences: true)
        guard entries.count <= limits.untrackedPaths else { return nil }

        var hasher = SHA256()
        func feed(_ label: String, _ data: Data) {
            hasher.update(data: Data("\(label):\(data.count):".utf8))
            hasher.update(data: data)
        }
        feed("root", Data(root.path.utf8))
        feed("head", Data(head.utf8))
        feed("diff", diff)

        var total = 0
        for bytes in entries {
            let pathData = Data(bytes)
            guard pathData.count <= limits.pathBytes,
                  let relative = strictString(pathData), !relative.hasPrefix("/"),
                  !relative.split(separator: "/").contains("..") else { return nil }
            let url = root.appendingPathComponent(relative)
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]) }
            catch { return nil }

            let content: Data
            do {
                if values.isSymbolicLink == true {
                    content = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
                } else {
                    let resolved = url.resolvingSymlinksInPath().path
                    let isWithinRoot = root.path == "/" ? resolved.hasPrefix("/") : resolved.hasPrefix(root.path + "/")
                    guard values.isRegularFile == true, isWithinRoot else { return nil }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var data = Data()
                    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        guard data.count <= limits.untrackedFileBytes - chunk.count,
                              total <= limits.totalUntrackedBytes - chunk.count else { return nil }
                        data.append(chunk)
                        total += chunk.count
                    }
                    content = data
                }
            } catch { return nil }
            guard content.count <= limits.untrackedFileBytes else { return nil }
            guard total <= limits.totalUntrackedBytes - (values.isSymbolicLink == true ? content.count : 0)
            else { return nil }
            if values.isSymbolicLink == true { total += content.count }
            feed("path", pathData)
            feed(values.isSymbolicLink == true ? "link" : "file", content)
        }
        return CodeFingerprint(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

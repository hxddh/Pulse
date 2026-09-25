import Foundation
import Darwin

/// 12.0-α — the vendor boundary for a Pulse-owned session.
///
/// A runtime session owns its process topology and wire format. Claude uses
/// one child per turn; Codex can later keep an App Server child alive for the
/// candidate. The runner above this boundary sees only normalized events and
/// lifecycle operations, so Fleet, persistence and worktrees stay shared.
enum ManagedRuntimeEvent {
    case continuation(String)
    case model(String)
    case entries([TranscriptReader.Entry])
    case result(ManagedRuntimeResult)
    case unknown
    case unparsed
}

struct ManagedRuntimeResult {
    var text: String
    var costUSD: Double?
    var tokensIn: Int?
    var tokensOut: Int?
    var errorDetail: String?
}

@MainActor
protocol ManagedRuntimeSession: AnyObject {
    var onEvent: ((ManagedRuntimeEvent) -> Void)? { get set }
    var onFinish: ((_ exitCode: Int32, _ stderrTail: Data) -> Void)? { get set }

    func start(prompt: String, continuation: String?, root: String, managedID: String) -> String?
    func cancel() -> Bool
    func shutdown()
}

@MainActor
protocol ManagedRuntime {
    var id: String { get }
    func executable() -> String?
    func canStart(prompt: String, continuation: String?) -> Bool
    func makeSession() -> any ManagedRuntimeSession
}

@MainActor
enum ManagedRuntimeRegistry {
    static let claude: any ManagedRuntime = ClaudeManagedRuntime()

    static func runtime(id: String) -> (any ManagedRuntime)? {
        id == claude.id ? claude : nil
    }
}

/// Claude's complete vendor shape: discovery, argv, stream decoder and its
/// one-child-per-turn process. Nothing outside this type knows Claude's wire.
@MainActor
struct ClaudeManagedRuntime: ManagedRuntime {
    let id = "claude"

    func executable() -> String? { Self.executable() }
    func canStart(prompt: String, continuation: String?) -> Bool {
        Self.arguments(prompt: prompt, continuation: continuation) != nil
    }

    nonisolated static func executable(
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
        ]
        return candidates.first(where: fileExists)
    }

    nonisolated static func arguments(
        prompt: String,
        continuation: String?,
        permissionConfigPath: String? = nil
    ) -> [String]? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var args = ["-p", trimmed, "--output-format", "stream-json", "--verbose"]
        if let continuation, !continuation.isEmpty {
            guard WorkbenchAnswer.validSessionID(continuation) else { return nil }
            args += ["--resume", continuation]
        }
        if let permissionConfigPath {
            args += ["--mcp-config", permissionConfigPath,
                     "--permission-prompt-tool", "mcp__pulse__approve"]
        }
        return args
    }

    nonisolated static func decode(line: Data) -> [ManagedRuntimeEvent] {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return [.unparsed]
        }
        let continuation = (object["session_id"] as? String) ?? ""
        let type = (object["type"] as? String) ?? ""
        var events: [ManagedRuntimeEvent] = []
        if !continuation.isEmpty { events.append(.continuation(continuation)) }
        switch type {
        case "system":
            if let model = object["model"] as? String, !model.isEmpty {
                events.append(.model(model))
            }
            if events.isEmpty { events.append(.unknown) }
        case "assistant", "user":
            events.append(.entries(TranscriptReader.entries(from: object)))
        case "result":
            let usage = object["usage"] as? [String: Any]
            let isError = (object["is_error"] as? Bool) ?? false
            let subtype = (object["subtype"] as? String) ?? "error"
            events.append(.result(ManagedRuntimeResult(
                text: (object["result"] as? String) ?? "",
                costUSD: object["total_cost_usd"] as? Double,
                tokensIn: usage?["input_tokens"] as? Int,
                tokensOut: usage?["output_tokens"] as? Int,
                errorDetail: isError ? subtype : nil
            )))
        default:
            events.append(.unknown)
        }
        return events
    }

    func makeSession() -> any ManagedRuntimeSession { Session() }

    @MainActor
    fileprivate final class Session: ManagedRuntimeSession {
        var onEvent: ((ManagedRuntimeEvent) -> Void)?
        var onFinish: ((Int32, Data) -> Void)?

        private var process: Process?
        private var lineBuffer = ManagedSession.LineBuffer()
        private var stderrTail = Data()
        /// Which turn the reader threads belong to; late deliveries from an
        /// earlier child are dropped rather than mixed into this one.
        private var turn = 0

        func start(prompt: String, continuation: String?, root: String, managedID: String) -> String? {
            guard let executable = ClaudeManagedRuntime.executable() else {
                return "claude-not-found"
            }
            guard let arguments = ClaudeManagedRuntime.arguments(
                prompt: prompt,
                continuation: continuation,
                permissionConfigPath: ManagedPermission.ensureConfig(managedID: managedID)
            ) else { return "invalid-turn" }

            let child = Process()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = arguments
            child.currentDirectoryURL = URL(fileURLWithPath: root)
            let out = Pipe()
            let err = Pipe()
            child.standardOutput = out
            child.standardError = err
            child.standardInput = FileHandle.nullDevice
            lineBuffer = ManagedSession.LineBuffer()
            stderrTail = Data()
            turn += 1
            let turnID = turn

            // One reader thread per pipe, and the exit is only reported once
            // both pipes have reached EOF *and* the child has exited. Every
            // hop to the main queue comes from the same thread in the order
            // the bytes arrived, so the last stdout chunk — usually the
            // `result` event — is always consumed before the turn ends.
            // 11.0.3 raced a `Task` per chunk against a `Task` for the exit,
            // and a successful turn could end as `failed("exit 0")`.
            let exited = DispatchSemaphore(value: 0)
            let stderrDone = DispatchSemaphore(value: 0)
            let exitCode = ManagedExitCode()
            child.terminationHandler = { finished in
                exitCode.value = finished.terminationStatus
                exited.signal()
            }
            do {
                try child.run()
                process = child
            } catch {
                turn += 1
                return "spawn: \(error.localizedDescription)"
            }
            let target = ManagedSessionRef(self)
            let errHandle = err.fileHandleForReading
            Thread.detachNewThread {
                while let chunk = try? errHandle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { target.session?.consumeStderr(chunk, turn: turnID) }
                    }
                }
                stderrDone.signal()
            }
            let outHandle = out.fileHandleForReading
            Thread.detachNewThread {
                while let chunk = try? outHandle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { target.session?.consume(chunk, turn: turnID) }
                    }
                }
                stderrDone.wait()
                exited.wait()
                let code = exitCode.value
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { target.session?.finished(exitCode: code, turn: turnID) }
                }
            }
            return nil
        }

        func cancel() -> Bool {
            guard let child = process, child.isRunning else { return false }
            child.terminate()
            let pid = child.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                // Only the child we started: once it has exited and been
                // reaped its pid may already belong to something else.
                if child.isRunning { kill(pid, SIGKILL) }
            }
            return true
        }

        func shutdown() {
            guard let child = process, child.isRunning else { return }
            child.terminate()
        }

        fileprivate func consume(_ chunk: Data, turn chunkTurn: Int) {
            guard chunkTurn == turn else { return }
            for line in lineBuffer.lines(from: chunk) {
                for event in ClaudeManagedRuntime.decode(line: line) { onEvent?(event) }
            }
        }

        fileprivate func consumeStderr(_ chunk: Data, turn chunkTurn: Int) {
            guard chunkTurn == turn else { return }
            stderrTail.append(chunk)
            if stderrTail.count > 4_096 { stderrTail = stderrTail.suffix(4_096) }
        }

        fileprivate func finished(exitCode: Int32, turn finishedTurn: Int) {
            guard finishedTurn == turn else { return }
            if let tail = lineBuffer.flush() {
                for event in ClaudeManagedRuntime.decode(line: tail) { onEvent?(event) }
            }
            process = nil
            onFinish?(exitCode, stderrTail)
        }
    }
}

/// Written once by a termination handler, read once after the `exited`
/// semaphore — the semaphore is the synchronisation.
private final class ManagedExitCode: @unchecked Sendable {
    var value: Int32 = -1
}

/// A weak reference the reader threads can carry: the session is main-actor
/// state, touched only inside `MainActor.assumeIsolated` on the main queue.
private final class ManagedSessionRef: @unchecked Sendable {
    weak var session: ClaudeManagedRuntime.Session?
    init(_ session: ClaudeManagedRuntime.Session) { self.session = session }
}

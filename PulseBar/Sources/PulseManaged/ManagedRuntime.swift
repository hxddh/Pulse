import Foundation
import PulseCore
import Darwin

/// Outcome-α — the vendor boundary for a Pulse-owned session.
///
/// A runtime session owns its process topology and wire format. Claude uses
/// one child per turn; Codex can later keep an App Server child alive for the
/// candidate. The runner above this boundary sees only normalized events and
/// lifecycle operations, so Fleet, persistence and worktrees stay shared.
package enum ManagedRuntimeEvent {
    case continuation(String)
    case model(String)
    case entries([TranscriptReader.Entry])
    case result(ManagedRuntimeResult)
    case unknown
    case unparsed
}

package struct ManagedRuntimeResult {
    package var text: String
    package var costUSD: Double?
    package var tokensIn: Int?
    package var tokensOut: Int?
    package var errorDetail: String?
}

/// How a turn ended, in the runtime's own terms. A per-turn runtime (Claude)
/// reports its child's exit; a long-lived one reports the turn's completion
/// without implying any process went away.
package struct ManagedTurnEnd: Equatable {
    /// The child's exit status, when a child per turn is the topology.
    package var exitStatus: Int32?
    /// The runtime's last diagnostic words (stderr tail, protocol error), if any.
    package var diagnostic: String = ""

    /// The sentence a turn that ended without a result event gets.
    package var failureText: String {
        if !diagnostic.isEmpty { return diagnostic }
        return exitStatus.map { "exit \($0)" } ?? "turn ended without a result"
    }
}

/// The user's decision on one permission request, as the runtime delivers it.
/// Single-use by construction: there is no "for the session" variant, and
/// there must never be one (no always-allow).
package enum ManagedApprovalDecision: Equatable {
    case allow
    case deny(message: String)
}

/// The session-shaped vendor boundary (plan-outcome, Outcome-α). The runner
/// above it knows a session's user semantics — bind it, send it a turn,
/// cancel it, answer its asks, shut it down — and nothing about processes,
/// pipes or wire formats. Claude spawns a child per turn behind `send`; an
/// App-Server runtime would keep one child for the whole session. Both fit.
@MainActor
package protocol ManagedRuntimeSession: AnyObject {
    var onEvent: ((ManagedRuntimeEvent) -> Void)? { get set }
    var onTurnEnd: ((ManagedTurnEnd) -> Void)? { get set }

    /// Bind the session to its identity, worktree and (for a resumed
    /// session) its continuation. Returns an error sentence, nil on success.
    func startOrResume(continuation: String?, root: String, managedID: String) -> String?
    /// Start one turn with the user's words. Returns an error sentence.
    func send(prompt: String) -> String?
    func cancel() -> Bool
    /// Deliver the user's decision on a request this session raised.
    func resolveApproval(id: String, decision: ManagedApprovalDecision)
    func shutdown()
}

@MainActor
package protocol ManagedRuntime {
    var id: String { get }
    /// The agent this runtime's sessions are rows of.
    var agent: AgentID { get }
    func executable() -> String?
    func canStart(prompt: String, continuation: String?) -> Bool
    func makeSession() -> any ManagedRuntimeSession
}

@MainActor
package enum ManagedRuntimeRegistry {
    package static let claude: any ManagedRuntime = ClaudeManagedRuntime()
    package static let all: [any ManagedRuntime] = [claude]

    package static func runtime(id: String) -> (any ManagedRuntime)? {
        all.first { $0.id == id }
    }

    /// Runtime ids this build can drive. Persisted sessions of any other
    /// runtime are refused, not guessed at.
    package nonisolated static let knownIDs: Set<String> = ["claude"]
}

/// Claude's complete vendor shape: discovery, argv, stream decoder and its
/// one-child-per-turn process. Nothing outside this type knows Claude's wire.
@MainActor
package struct ClaudeManagedRuntime: ManagedRuntime {
    package let id = "claude"
    package let agent: AgentID = .claude

    package func executable() -> String? { Self.executable() }
    package func canStart(prompt: String, continuation: String?) -> Bool {
        Self.arguments(prompt: prompt, continuation: continuation) != nil
    }

    package nonisolated static func executable(
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

    package nonisolated static func arguments(
        prompt: String,
        continuation: String?,
        permissionConfigPath: String? = nil
    ) -> [String]? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var args = ["-p", trimmed, "--output-format", "stream-json", "--verbose"]
        if let continuation, !continuation.isEmpty {
            guard ManagedSessionID.isValid(continuation) else { return nil }
            args += ["--resume", continuation]
        }
        if let permissionConfigPath {
            args += ["--mcp-config", permissionConfigPath,
                     "--permission-prompt-tool", "mcp__pulse__approve"]
        }
        return args
    }

    package nonisolated static func decode(line: Data) -> [ManagedRuntimeEvent] {
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

    package func makeSession() -> any ManagedRuntimeSession { Session() }

    @MainActor
    fileprivate final class Session: ManagedRuntimeSession {
        package var onEvent: ((ManagedRuntimeEvent) -> Void)?
        package var onTurnEnd: ((ManagedTurnEnd) -> Void)?

        private var root = ""
        private var managedID = ""
        /// The Claude session id to `--resume`; taken from the stream as soon
        /// as the first turn names it.
        private var continuation: String?
        private var bound = false

        private var process: Process?
        private var lineBuffer = ManagedSession.LineBuffer()
        private var stderrTail = Data()
        /// Which turn the reader threads belong to; late deliveries from an
        /// earlier child are dropped rather than mixed into this one.
        private var turn = 0

        package func startOrResume(continuation: String?, root: String, managedID: String) -> String? {
            guard ClaudeManagedRuntime.executable() != nil else { return "claude-not-found" }
            self.continuation = continuation
            self.root = root
            self.managedID = managedID
            bound = true
            return nil
        }

        package func resolveApproval(id: String, decision: ManagedApprovalDecision) {
            // Claude's permission-prompt MCP server polls for this file.
            switch decision {
            case .allow:
                ManagedPermission.writeVerdict(ManagedPermission.Verdict(id: id, allow: true, message: ""))
            case .deny(let message):
                ManagedPermission.writeVerdict(ManagedPermission.Verdict(id: id, allow: false, message: message))
            }
        }

        package func send(prompt: String) -> String? {
            guard bound else { return "session-not-started" }
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

        package func cancel() -> Bool {
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

        package func shutdown() {
            guard let child = process, child.isRunning else { return }
            child.terminate()
        }

        fileprivate func consume(_ chunk: Data, turn chunkTurn: Int) {
            guard chunkTurn == turn else { return }
            for line in lineBuffer.lines(from: chunk) {
                for event in ClaudeManagedRuntime.decode(line: line) { deliver(event) }
            }
        }

        /// The session learns its own continuation from the stream, so the
        /// next `send` resumes without the runner handing it back.
        private func deliver(_ event: ManagedRuntimeEvent) {
            if case .continuation(let id) = event, continuation == nil, !id.isEmpty {
                continuation = id
            }
            onEvent?(event)
        }

        fileprivate func consumeStderr(_ chunk: Data, turn chunkTurn: Int) {
            guard chunkTurn == turn else { return }
            stderrTail.append(chunk)
            if stderrTail.count > 4_096 { stderrTail = stderrTail.suffix(4_096) }
        }

        fileprivate func finished(exitCode: Int32, turn finishedTurn: Int) {
            guard finishedTurn == turn else { return }
            if let tail = lineBuffer.flush() {
                for event in ClaudeManagedRuntime.decode(line: tail) { deliver(event) }
            }
            process = nil
            let words = String(decoding: stderrTail.suffix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onTurnEnd?(ManagedTurnEnd(exitStatus: exitCode, diagnostic: words))
        }
    }
}

/// Written once by a termination handler, read once after the `exited`
/// semaphore — the semaphore is the synchronisation.
private final class ManagedExitCode: @unchecked Sendable {
    package var value: Int32 = -1
}

/// A weak reference the reader threads can carry: the session is main-actor
/// state, touched only inside `MainActor.assumeIsolated` on the main queue.
private final class ManagedSessionRef: @unchecked Sendable {
    package weak var session: ClaudeManagedRuntime.Session?
    package init(_ session: ClaudeManagedRuntime.Session) { self.session = session }
}

/// What a vendor session id may look like before Pulse puts it on a command
/// line (`--resume <id>`). 12.3: the rule lives with the runtime that relies
/// on it; `WorkbenchAnswer.validSessionID` forwards here.
package enum ManagedSessionID {
    package static func isValid(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 128 else { return false }
        return raw.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == ".")
        }
    }
}

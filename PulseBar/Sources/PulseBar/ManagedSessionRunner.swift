import Foundation

/// 5.0-β / 12.0-α — one managed session's vendor-neutral turn life. The
/// runtime session owns child processes and wire decoding; this runner owns
/// the shared model, turn status and worktree measurement.
///
/// Runtime callbacks arrive on the main actor before touching the model — the
/// same discipline every other collector follows.
@MainActor
final class ManagedSessionRunner {
    private(set) var model: ManagedSession.Model
    /// Fired after every model change, on the main actor.
    var onChange: (() -> Void)?

    private let runtime: any ManagedRuntime
    private let runtimeSession: any ManagedRuntimeSession

    init(model: ManagedSession.Model, runtime: (any ManagedRuntime)? = nil) {
        self.model = model
        guard let resolved = runtime ?? ManagedRuntimeRegistry.runtime(id: model.runtimeID) else {
            preconditionFailure("unsupported managed runtime: \(model.runtimeID)")
        }
        self.runtime = resolved
        self.runtimeSession = resolved.makeSession()
        runtimeSession.onEvent = { [weak self] event in
            guard let self else { return }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            self.update { $0.apply(event: event, nowMs: nowMs) }
        }
        runtimeSession.onFinish = { [weak self] exitCode, stderrTail in
            self?.finishedTurn(exitCode: exitCode, stderrTail: stderrTail)
        }
    }

    var isRunning: Bool { model.status == .running }

    /// 6.0-α: the fleet found a slot for a queued session. Sends the held
    /// prompt; an empty one falls to failed so the queue cannot spin on it.
    func beginQueuedTurn() {
        guard model.status == .queued else { return }
        let prompt = model.pendingPrompt
        update { $0.pendingPrompt = "" }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            update { $0.status = .failed("empty prompt") }
            return
        }
        send(prompt: prompt)
    }

    /// Start the next turn with the user's words. Refuses while a turn is
    /// in flight; every refusal is visible through the model's status.
    func send(prompt: String) {
        guard !isRunning else { return }
        guard runtime.executable() != nil else {
            update { $0.status = .failed("\(runtime.id)-not-found") }
            return
        }
        let continuation = model.continuationID.isEmpty ? nil : model.continuationID
        guard runtime.canStart(prompt: prompt, continuation: continuation) else { return }
        // The user's words are part of the record the moment they are sent.
        let sent = TranscriptReader.Entry(
            kind: .user,
            text: ContentSanitizer.redact(prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
            tsMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        update {
            $0.entries.append(sent)
            $0.status = .running
            $0.lastErrorText = ""
        }
        if let error = runtimeSession.start(
            prompt: prompt, continuation: continuation, root: model.root, managedID: model.id
        ) {
            update { $0.status = .failed(error) }
        } else {
            DebugLog.write(
                "managed turn start id=\(model.id) runtime=\(runtime.id) resume=\(continuation != nil)"
            )
        }
    }

    /// SIGTERM now; SIGKILL if it lingers. The status says cancelled from
    /// the click, so the termination handler knows not to call it a failure.
    func cancel() {
        guard isRunning, runtimeSession.cancel() else { return }
        update { $0.status = .cancelled }
        DebugLog.write("managed cancel id=\(model.id)")
    }

    /// Test seam: drive queue/persistence semantics without a process.
    /// Never called from product code.
    func adoptStatusForTesting(_ status: ManagedSession.Status) {
        update { $0.status = status }
    }

    /// 6.0-γ: the per-session run-check command, remembered (persisted with
    /// the next status move).
    func setRunCommand(_ command: String) {
        update { $0.runCommand = command }
    }

    /// 6.0-γ: what this turn left on disk — measured with the same
    /// read-only plumbing as everything else, once per turn end, off main.
    private func measureTurnEffect() {
        let root = model.root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let measurement = WorkspaceEffect.measure(root: root, nowMs: nowMs)
            Task { @MainActor [weak self] in
                guard let self, measurement.isKnown,
                      measurement.insertions >= 0, measurement.deletions >= 0
                else { return }
                self.update {
                    $0.lastTurnEffect = (measurement.insertions, measurement.deletions)
                }
            }
        }
    }

    /// Quit-time reaping — no orphaned agents burning tokens after the tray
    /// icon is gone.
    func terminateForShutdown() {
        runtimeSession.shutdown()
    }

    private func finishedTurn(exitCode: Int32, stderrTail: Data) {
        update {
            switch $0.status {
            case .running:
                // No result event claimed this exit. Zero is not success
                // here — success speaks through the stream; a silent clean
                // exit is still an answer that never arrived.
                let stderrText = String(decoding: stderrTail.suffix(300), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                $0.status = .failed(stderrText.isEmpty ? "exit \(exitCode)" : stderrText)
                if $0.lastErrorText.isEmpty { $0.lastErrorText = "exit \(exitCode)" }
            case .idle, .failed, .cancelled, .queued, .interrupted:
                // The last three cannot follow a child exit in practice —
                // but a no-op is the honest handling if one ever does.
                break
            }
        }
        if model.status == .idle {
            measureTurnEffect()
        } else if case .failed = model.status {
            measureTurnEffect()
        }
        DebugLog.write("managed turn end id=\(model.id) exit=\(exitCode) status=\(model.status)")
    }

    private func update(_ mutate: (inout ManagedSession.Model) -> Void) {
        mutate(&model)
        onChange?()
    }
}

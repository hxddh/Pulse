import Foundation
import PulseCore

/// 5.0-β / Outcome-α — one managed session's vendor-neutral turn life. The
/// runtime session owns child processes and wire decoding; this runner owns
/// the shared model, turn status and worktree measurement.
///
/// Runtime callbacks arrive on the main actor before touching the model — the
/// same discipline every other collector follows.
@MainActor
package final class ManagedSessionRunner {
    package private(set) var model: ManagedSession.Model
    /// Fired after every model change, on the main actor.
    package var onChange: (() -> Void)?

    private let runtime: any ManagedRuntime
    private let runtimeSession: any ManagedRuntimeSession
    /// `startOrResume` has run: the session knows its identity and worktree.
    private var sessionBound = false
    /// Checks and the code they ran against (12.2 · out of the view).
    package let acceptance: AcceptanceRunner
    package var isChecking: Bool { acceptance.isChecking }

    package init(model: ManagedSession.Model, runtime: (any ManagedRuntime)? = nil) {
        self.model = model
        guard let resolved = runtime ?? ManagedRuntimeRegistry.runtime(id: model.runtimeID) else {
            preconditionFailure("unsupported managed runtime: \(model.runtimeID)")
        }
        self.runtime = resolved
        self.runtimeSession = resolved.makeSession()
        self.acceptance = AcceptanceRunner(root: model.root)
        acceptance.onChange = { [weak self] in self?.acceptanceChanged() }
        // A persisted pass is only worth knowing about if it is still true.
        if model.acceptanceEvidence.last?.outcome == .passed {
            acceptance.refresh()
        }
        runtimeSession.onEvent = { [weak self] event in
            guard let self else { return }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            self.update { $0.apply(event: event, nowMs: nowMs) }
        }
        runtimeSession.onTurnEnd = { [weak self] end in
            self?.finishedTurn(end)
        }
    }

    package var isRunning: Bool { model.status == .running }

    /// 6.0-α: the fleet found a slot for a queued session. Sends the held
    /// prompt; an empty one falls to failed so the queue cannot spin on it.
    package func beginQueuedTurn() {
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
    package func send(prompt: String) {
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
        if !sessionBound {
            if let error = runtimeSession.startOrResume(
                continuation: continuation, root: model.root, managedID: model.id
            ) {
                update { $0.status = .failed(error) }
                return
            }
            sessionBound = true
        }
        if let error = runtimeSession.send(prompt: prompt) {
            update { $0.status = .failed(error) }
        } else {
            DebugLog.write(
                "managed turn start id=\(model.id) runtime=\(runtime.id) resume=\(continuation != nil)"
            )
        }
    }

    /// SIGTERM now; SIGKILL if it lingers. The status says cancelled from
    /// the click, so the termination handler knows not to call it a failure.
    package func cancel() {
        guard isRunning, runtimeSession.cancel() else { return }
        update { $0.status = .cancelled }
        DebugLog.write("managed cancel id=\(model.id)")
    }

    /// Test seam: drive queue/persistence semantics without a process.
    /// Never called from product code.
    package func adoptStatusForTesting(_ status: ManagedSession.Status) {
        update { $0.status = status }
    }

    /// 6.0-γ: the per-session run-check command, remembered.
    package func setRunCommand(_ command: String) {
        update { $0.runCommand = command }
    }

    /// Outcome-β: run the user's check and retain evidence bound to the exact
    /// code before and after it. Process work stays off the main actor; only
    /// the finished durable fact crosses back.
    package func runCheck(command rawCommand: String, completion: (() -> Void)? = nil) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !isChecking, !command.isEmpty else { return }
        update {
            $0.runCommand = command
            $0.runningCheck = RunningCheck(
                command: command, cwd: $0.root,
                startedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }
        acceptance.run(command: command) { [weak self] evidence in
            guard let self else { return }
            self.update {
                $0.runningCheck = nil
                $0.acceptanceEvidence.append(evidence)
                if $0.acceptanceEvidence.count > ManagedSession.maxAcceptanceEvidence {
                    $0.acceptanceEvidence.removeFirst(
                        $0.acceptanceEvidence.count - ManagedSession.maxAcceptanceEvidence
                    )
                }
            }
            completion?()
        }
    }

    /// Where the newest evidence stands against the code as it is now.
    package var latestEvidenceStanding: EvidenceStanding? {
        model.acceptanceEvidence.last.map { acceptance.standing(of: $0) }
    }

    private func acceptanceChanged() {
        acceptance.watch(latest: model.acceptanceEvidence.last)
        onChange?()
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
    package func terminateForShutdown() {
        runtimeSession.shutdown()
        // A check must not outlive the app that was going to record it; the
        // persisted `runningCheck` reloads as interrupted.
        acceptance.shutdown()
    }

    /// Stop the running check and its whole process group.
    package func cancelCheck() {
        acceptance.cancel()
    }

    /// The user's decision on a permission request this session raised.
    package func resolveApproval(id: String, decision: ManagedApprovalDecision) {
        runtimeSession.resolveApproval(id: id, decision: decision)
    }

    private func finishedTurn(_ end: ManagedTurnEnd) {
        update {
            switch $0.status {
            case .running:
                // No result event claimed this end. A clean exit is not
                // success here — success speaks through the stream; a silent
                // end is still an answer that never arrived.
                $0.status = .failed(end.failureText)
                if $0.lastErrorText.isEmpty {
                    $0.lastErrorText = end.exitStatus.map { "exit \($0)" } ?? end.failureText
                }
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
        // A turn is the agent editing the worktree: a pass from before it is
        // re-judged now, not whenever someone next opens the inspector.
        if model.acceptanceEvidence.last != nil { acceptance.refresh() }
        DebugLog.write(
            "managed turn end id=\(model.id) exit=\(end.exitStatus.map(String.init) ?? "-") status=\(model.status)"
        )
    }

    private func update(_ mutate: (inout ManagedSession.Model) -> Void) {
        mutate(&model)
        onChange?()
    }
}

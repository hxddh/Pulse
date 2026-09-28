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
    /// 14.0 · checks, evidence and the code they ran against belong to the
    /// working copy, not to the session: this Candidate reads its own
    /// worktree's page in the book it was given.
    package let evidenceBook: EvidenceBook
    package var acceptance: AcceptanceRunner { evidenceBook.runner(for: model.root) }
    package var isChecking: Bool { evidenceBook.isChecking(at: model.root) }
    /// The evidence recorded for this Candidate's worktree.
    package var acceptanceEvidence: [AcceptanceEvidence] { evidenceBook.evidence(for: model.root) }
    package var runningCheck: RunningCheck? { evidenceBook.runningCheck(for: model.root) }

    package init(
        model: ManagedSession.Model,
        runtime: (any ManagedRuntime)? = nil,
        evidence: EvidenceBook? = nil
    ) {
        self.model = model
        guard let resolved = runtime ?? ManagedRuntimeRegistry.runtime(id: model.runtimeID) else {
            preconditionFailure("unsupported managed runtime: \(model.runtimeID)")
        }
        self.runtime = resolved
        self.runtimeSession = resolved.makeSession()
        self.evidenceBook = evidence ?? EvidenceBook(persists: false)
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
        // A new turn changes the code the queued checks would measure; they
        // do not start. One already running finishes and is judged by the
        // fingerprint rule (it will read as changed during the run).
        evidenceBook.dropQueue(at: model.root)
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
    /// code before and after it — in the worktree's page of the book.
    package func runCheck(
        command rawCommand: String,
        checkID: String? = nil,
        completion: (() -> Void)? = nil
    ) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !isChecking, !command.isEmpty else { return }
        // Only an ad-hoc check is remembered as "the" command; Mission checks
        // live in the Mission's contract.
        if checkID == nil { update { $0.runCommand = command } }
        evidenceBook.runCheck(command: command, checkID: checkID, at: model.root, completion: completion)
    }

    // MARK: - Mission checks (13.0)

    /// Checks still waiting their turn in this Candidate's worktree.
    package var queuedChecks: [Mission.Check] { evidenceBook.queued(at: model.root) }
    package var isRunningChecks: Bool { evidenceBook.isBusy(at: model.root) }

    /// Run a Mission's checks in the user's order, one at a time; a failure
    /// does not stop the rest. Refused while a turn or a check runs.
    package func runChecks(_ checks: [Mission.Check]) {
        guard !isRunning else { return }
        evidenceBook.runChecks(checks, at: model.root)
    }

    /// Stop the running check (interrupted) and drop the rest (not run).
    package func cancelChecks() {
        evidenceBook.cancel(at: model.root)
    }

    /// Where the newest evidence stands against the code as it is now.
    package var latestEvidenceStanding: EvidenceStanding? {
        acceptanceEvidence.last.map { evidenceBook.standing(of: $0, at: model.root) }
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
        // Checks are the book's: the fleet shuts it down once, and a persisted
        // running check reloads as interrupted.
    }

    /// Stop the running check and its whole process group.
    package func cancelCheck() {
        evidenceBook.cancel(at: model.root)
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
        evidenceBook.refresh(at: model.root)
        DebugLog.write(
            "managed turn end id=\(model.id) exit=\(end.exitStatus.map(String.init) ?? "-") status=\(model.status)"
        )
    }

    private func update(_ mutate: (inout ManagedSession.Model) -> Void) {
        mutate(&model)
        onChange?()
    }
}

import Foundation

/// 5.0-β — one managed session's process life (scene BG). The pure state
/// lives in `ManagedSession.Model`; this class owns exactly the part tests
/// cannot: a child process per turn, its pipes, and its death.
///
/// Threading: pipe callbacks arrive on background queues and are marshalled
/// to the main actor before touching the model — the same discipline every
/// other collector follows. Lifecycle: one turn = one child; cancel is
/// SIGTERM with a SIGKILL follow-up (the ProcessIO lesson); the source
/// terminates every child on quit.
@MainActor
final class ManagedSessionRunner {
    private(set) var model: ManagedSession.Model
    /// Fired after every model change, on the main actor.
    var onChange: (() -> Void)?

    private var process: Process?
    private var lineBuffer = ManagedSession.LineBuffer()
    private var stderrTail = Data()

    init(model: ManagedSession.Model) {
        self.model = model
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
        guard let executable = ManagedSession.claudeExecutable() else {
            update { $0.status = .failed("claude-not-found") }
            return
        }
        let resume = model.claudeSessionID.isEmpty ? nil : model.claudeSessionID
        guard let arguments = ManagedSession.arguments(
            prompt: prompt,
            resumeSessionID: resume,
            // 6.0-β: nil only if the config could not be written — the turn
            // still runs, with the 5.0 silent-deny behavior, rather than
            // refusing to work at all.
            permissionConfigPath: ManagedPermission.ensureConfig(managedID: model.id)
        ) else {
            return
        }
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

        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.currentDirectoryURL = URL(fileURLWithPath: model.root)
        let out = Pipe()
        let err = Pipe()
        child.standardOutput = out
        child.standardError = err
        child.standardInput = FileHandle.nullDevice
        lineBuffer = ManagedSession.LineBuffer()
        stderrTail = Data()

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stderrTail.append(chunk)
                if self.stderrTail.count > 4_096 {
                    self.stderrTail = self.stderrTail.suffix(4_096)
                }
            }
        }
        child.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor [weak self] in self?.finishedTurn(exitCode: code, pipes: (out, err)) }
        }
        do {
            try child.run()
            process = child
            DebugLog.write("managed turn start id=\(model.id) resume=\(resume != nil)")
        } catch {
            update { $0.status = .failed("spawn: \(error.localizedDescription)") }
        }
    }

    /// SIGTERM now; SIGKILL if it lingers. The status says cancelled from
    /// the click, so the termination handler knows not to call it a failure.
    func cancel() {
        guard let child = process, isRunning else { return }
        update { $0.status = .cancelled }
        child.terminate()
        let pid = child.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            kill(pid, SIGKILL)
        }
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
        guard let child = process, child.isRunning else { return }
        child.terminate()
    }

    // MARK: - Stream plumbing (main actor from here on)

    private func consume(_ chunk: Data) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let lines = lineBuffer.lines(from: chunk)
        guard !lines.isEmpty else { return }
        update {
            for line in lines { $0.apply(line: line, nowMs: nowMs) }
        }
    }

    private func finishedTurn(exitCode: Int32, pipes: (Pipe, Pipe)) {
        pipes.0.fileHandleForReading.readabilityHandler = nil
        pipes.1.fileHandleForReading.readabilityHandler = nil
        // Drain what the handlers had not seen yet, then the carry.
        let rest = pipes.0.fileHandleForReading.readDataToEndOfFile()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        update {
            for line in self.lineBuffer.lines(from: rest) { $0.apply(line: line, nowMs: nowMs) }
            if let tail = self.lineBuffer.flush() { $0.apply(line: tail, nowMs: nowMs) }
            switch $0.status {
            case .running:
                // No result event claimed this exit. Zero is not success
                // here — success speaks through the stream; a silent clean
                // exit is still an answer that never arrived.
                let stderrText = String(decoding: self.stderrTail.suffix(300), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                $0.status = .failed(stderrText.isEmpty ? "exit \(exitCode)" : stderrText)
                if $0.lastErrorText.isEmpty { $0.lastErrorText = "exit \(exitCode)" }
            case .idle, .failed, .cancelled, .queued, .interrupted:
                // The last three cannot follow a child exit in practice —
                // but a no-op is the honest handling if one ever does.
                break
            }
        }
        process = nil
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

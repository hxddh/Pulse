import Foundation
import PulseCore

/// One managed session's acceptance checks and its knowledge of the code
/// they ran against — outside any view.
///
/// Until 12.2 whether a pass was still current lived in the inspector's
/// `@State`: it was only known while that window was open, the compare card
/// could not say it at all, and a session edited in another app kept showing
/// its old pass until the inspector happened to re-measure. The runner now
/// owns the current fingerprint and, while its newest evidence is a pass that
/// could go stale, re-measures on a slow cadence. Nothing is measured for a
/// session whose newest evidence is not a pass.
@MainActor
package final class AcceptanceRunner {
    /// How often a live pass is re-checked against the worktree.
    package static let watchIntervalSeconds: Double = 10

    package let root: String
    /// Fired after any change the UI shows.
    package var onChange: (() -> Void)?

    package private(set) var isChecking = false
    package private(set) var currentFingerprint: CodeFingerprint?
    package private(set) var fingerprintMeasured = false

    private var control: ProcessIO.CheckControl?
    private var measureInFlight = false
    private var measureQueued = false
    private var watchTask: Task<Void, Never>?

    package init(root: String) {
        self.root = root
    }

    package func standing(of evidence: AcceptanceEvidence) -> EvidenceStanding {
        EvidenceStanding.of(evidence, current: currentFingerprint, measured: fingerprintMeasured)
    }

    /// Run `command` in the worktree, bound to the code before and after it.
    /// Process work stays off the main actor; only the finished fact returns.
    package func run(command: String, completion: @escaping (AcceptanceEvidence) -> Void) {
        // Called only from the main-actor Task below.
        let deliver = Unchecked(completion)
        guard !isChecking else { return }
        isChecking = true
        let control = ProcessIO.CheckControl()
        self.control = control
        let root = self.root
        onChange?()
        DispatchQueue.global(qos: .userInitiated).async {
            let startedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            let before = CodeFingerprint.measure(cwd: root)
            let result = ProcessIO.runCheck(
                command: command,
                currentDirectory: root,
                timeout: 300,
                outputLimit: AcceptanceEvidence.outputLimitBytes,
                control: control
            )
            let after = CodeFingerprint.measure(cwd: root)
            let evidence = AcceptanceEvidence.make(
                command: command,
                cwd: root,
                startedAtMs: startedAtMs,
                finishedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                stdout: result?.stdout ?? Data(),
                stderr: result?.stderr ?? Data(),
                exitCode: result?.status,
                preFingerprint: before,
                postFingerprint: after,
                timedOut: result?.timedOut ?? false,
                // Stopped by the user: the honest name is "interrupted" —
                // it did not pass and it did not fail.
                interrupted: result?.cancelled ?? false
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isChecking = false
                self.control = nil
                // The code the check just measured is the current code.
                self.currentFingerprint = after
                self.fingerprintMeasured = true
                deliver.value(evidence)
                self.onChange?()
            }
        }
    }

    /// Stop the running check and its whole process group.
    package func cancel() {
        control?.cancel()
    }

    /// Measure the worktree now (off main); overlapping requests coalesce.
    package func refresh() {
        guard !root.isEmpty else { return }
        if measureInFlight {
            measureQueued = true
            return
        }
        measureInFlight = true
        let root = self.root
        DispatchQueue.global(qos: .utility).async {
            let fingerprint = CodeFingerprint.measure(cwd: root)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = fingerprint != self.currentFingerprint || !self.fingerprintMeasured
                self.currentFingerprint = fingerprint
                self.fingerprintMeasured = true
                self.measureInFlight = false
                if changed { self.onChange?() }
                if self.measureQueued {
                    self.measureQueued = false
                    self.refresh()
                }
            }
        }
    }

    /// Keep watching only while `latest` is a pass that is still current —
    /// that is the one standing a silent edit can falsify. Anything else
    /// (no evidence, a failure, already stale) needs no clock at all.
    package func watch(latest: AcceptanceEvidence?) {
        let live = latest.map { standing(of: $0) == .passing || standing(of: $0) == .measuring } ?? false
        if live, watchTask == nil {
            let seconds = Self.watchIntervalSeconds
            watchTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    if Task.isCancelled { break }
                    self?.refresh()
                }
            }
        } else if !live {
            watchTask?.cancel()
            watchTask = nil
        }
    }

    package func shutdown() {
        watchTask?.cancel()
        watchTask = nil
        control?.cancel()
    }
}

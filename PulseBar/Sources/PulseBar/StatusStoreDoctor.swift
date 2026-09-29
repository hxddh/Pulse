import AppKit
import Foundation

/// 19.0 · the self-check — the store's side: run it on the user's click,
/// keep the result for the view, copy the redacted text on another click.
@MainActor
extension StatusStore {
    /// This run's local Respond verdicts, by fate — the one fact only the
    /// store holds.
    var doctorRespondTally: DoctorProbe.RespondTally {
        var tally = DoctorProbe.RespondTally()
        tally.enabled = respondLocalEnabled
        for decided in respondDecided.values where decided.isLocal {
            tally.written += 1
            switch decided.fate {
            case .taken: tally.taken += 1
            case .expired: tally.expired += 1
            case .waiting, .unknown: break
            }
        }
        return tally
    }

    /// 20.0: what the parsers got from each agent's session files this run —
    /// counts only. Remote rows are another machine's reading, not this one's.
    var doctorReadCoverage: [String: DoctorModel.Coverage] {
        var coverage: [String: DoctorModel.Coverage] = [:]
        for row in cachedAll where row.observationSource == .session && row.host.isEmpty {
            let key = row.agent.rawValue
            var item = coverage[key] ?? DoctorModel.Coverage(
                name: row.agent.displayName,
                expectsLastWord: row.agent.spec.transcripts != .none
            )
            item.sessions += 1
            if row.usefulTask != nil { item.withTask += 1 }
            if !row.lastWord.isEmpty { item.withLastWord += 1 }
            coverage[key] = item
        }
        return coverage
    }

    func runDoctor() {
        guard !isRunningDoctor else { return }
        isRunningDoctor = true
        let home = HooksInstaller.homeURL
        let tally = doctorRespondTally
        let coverage = doctorReadCoverage
        let lang = self.lang
        DebugLog.write("self-check started")
        Task.detached(priority: .userInitiated) {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let facts = DoctorProbe.gather(home: home, respond: tally, coverage: coverage, nowMs: nowMs)
            let report = DoctorModel.evaluate(facts, lang: lang)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.doctorReport = report
                self.isRunningDoctor = false
                DebugLog.write("self-check done: \(report.checks.map { "\($0.id)=\($0.verdict.rawValue)" }.joined(separator: " "))")
            }
        }
    }

    /// Only on the user's click, only to their own clipboard.
    func copyDoctorReport() {
        guard let report = doctorReport else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(DoctorModel.text(report), forType: .string)
        didCopyDoctorReport = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            self?.didCopyDoctorReport = false
        }
    }
}

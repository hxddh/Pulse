import AppKit
import Foundation

/// 19.0 · the self-check — the store's side: run it on the user's click,
/// keep the result for the view, copy the redacted text on another click.
@MainActor
extension StatusStore {
    /// 20.0: what the parsers got from each agent's session files this run —
    /// counts only.
    var doctorReadCoverage: [String: DoctorModel.Coverage] {
        var coverage: [String: DoctorModel.Coverage] = [:]
        for row in cachedAll where row.observationSource == .session {
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
        let coverage = doctorReadCoverage
        let lang = self.lang
        DebugLog.write("self-check started")
        Task.detached(priority: .userInitiated) {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let facts = DoctorProbe.gather(home: home, coverage: coverage, nowMs: nowMs)
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

extension StatusStore {
    /// 21.0: the self-check's next step, taken from the self-check.
    func performDoctorFix(_ fix: DoctorModel.Fix) {
        switch fix {
        case .installHooks:
            installHooks()
        case .copyShapeReport:
            copyHarvestShapeReport()
        case .openConnections:
            openSettings(focusWaitingSignals: true)
        }
    }

    /// 21.0: when Pulse last read, how often it reads, and what that has
    /// cost over the last hour — the facts that were only in the clipboard
    /// dump. Read by the Health window.
    var scanHealthLine: String {
        let now = Date()
        var parts: [String] = []
        // `lastScanAt` moves on every applied scan; `snapshot.updatedAt`
        // only when the snapshot publishes, so it can read a minute stale.
        let lastRead = Self.lastReadDate(lastScanAt: lastScanAt, snapshotUpdatedAt: snapshot.updatedAt)
        if let lastRead {
            let ago = now.timeIntervalSince(lastRead)
            parts.append(ago < 5
                ? tr(.lastReadJustNow)
                : String(format: tr(.lastReadAgo), DurationFormat.label(seconds: ago, lang: lang)))
        }
        parts.append(probeIntervalDescription)
        let reads = probeStats.harvestCount(now: now)
        if reads > 0 {
            if let avg = probeStats.averageHarvestMs(now: now) {
                parts.append(String(format: tr(.readsLastHourAvg), reads, avg))
            } else {
                parts.append(String(format: tr(.readsLastHour), reads))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Pure: when Pulse last read the world — the newer of the last applied
    /// scan and the last published snapshot; nil before either.
    nonisolated static func lastReadDate(lastScanAt: Date?, snapshotUpdatedAt: Date) -> Date? {
        let published: Date? = snapshotUpdatedAt == .distantPast ? nil : snapshotUpdatedAt
        switch (lastScanAt, published) {
        case let (scan?, snap?): return max(scan, snap)
        case let (scan?, nil): return scan
        case let (nil, snap?): return snap
        case (nil, nil): return nil
        }
    }
}

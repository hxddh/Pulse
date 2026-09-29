import Foundation
import AppKit

/// Diagnostics (23.0; it was Health) — the model's side: per-agent health
/// from the hooks and the rows, the copy each agent line shows, the one
/// report, the self-check, and the window's value (`diagnosticsModel`).
///
/// 24.0: there is no collector to diagnose. What Pulse can say about an
/// agent is whether its hook is installed, whether it has fired, which
/// sessions its events put on the list, and which of its processes have not
/// spoken yet.
@MainActor
extension StatusStore {
    /// The process scan's cadence, for Diagnostics and the report.
    var probeIntervalDescription: String {
        engine.probeIntervalDescription(lang: lang)
    }

    private func flashCopiedDiagnostics() {
        diagnostics.didCopyDiagnostics = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            self?.diagnostics.didCopyDiagnostics = false
        }
    }

    /// 23.0 · the one report: the path-free support report, then the
    /// self-check when it has run. Only on the user's click, only to their
    /// own clipboard.
    func reportText() -> String {
        var parts = [safeSupportReport()]
        if let report = diagnostics.doctorReport { parts.append(DoctorModel.text(report)) }
        return parts.joined(separator: "\n\n")
    }

    func copyReport() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(reportText(), forType: .string)
        flashCopiedDiagnostics()
        DebugLog.write("report copied")
    }

    /// A previewable, deliberately path-free support report: hook states,
    /// counts and ages — never prompts, session ids, paths or command lines.
    func safeSupportReport() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let authLabel: String = {
            switch notifyAuthorized {
            case .some(true): return "authorized"
            case .some(false): return "denied"
            case .none: return "unknown"
            }
        }()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var lines = [
            "Pulse safe support report",
            PulseVersion.fingerprint,
            "channel: \(PulseVersion.distributionChannel)",
            "notarized: \(PulseVersion.isNotarized)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "gatekeeperReady: \(PulseVersion.isGatekeeperReady)",
            "waitingNone: \(AgentID.waitingNoneAgents.map(\.rawValue).joined(separator: ","))",
            "notifications: authorization=\(authLabel) notifyWaiting=\(settings.notifyOnWaiting) queued=\(sessionLog.queuedKeys.count)",
            "processScan: \(probeIntervalDescription)",
            "launchAtLogin: \(settings.launchAtLogin) applied=\(loginItemApplied.map(String.init) ?? "untouched")",
            "sessions: book=\(engine.book.sessions.count) rows=\(cachedAll.count) exitWatch=\(engine.exitWatch.watchedCount) transcripts=\(engine.transcripts.count)",
            sessionLogDiagnostics,
        ]
        for item in supportHealth {
            let age = item.lastEventMs > 0 ? String(max(0, (nowMs - item.lastEventMs) / 1000)) : "-"
            lines.append(
                "\(item.agent.rawValue): \(item.disposition) hook=\(item.hookInstalled) present=\(item.vendorPresent) "
                    + "lastEventAgeSec=\(age) sessions=\(item.sessionCount) processOnly=\(item.processOnlyCount)"
            )
        }
        return ContentSanitizer.redact(lines.joined(separator: "\n"))
    }

    var supportHealth: [AgentSupportHealth] {
        // Cached by the engine: a Diagnostics redraw reads no file.
        let events = previewWaitingEventTimes ?? engine.latestHookEventMs
        return AgentID.priority.map { agent in
            let rows = cachedAll.filter { $0.agent == agent }
            return AgentSupportHealth(
                agent: agent,
                hookInstalled: hooksStatus.isInstalled(for: agent),
                vendorPresent: HooksInstaller.vendorPresent(agent),
                lastEventMs: events[agent] ?? 0,
                sessionCount: rows.filter { !$0.isProcessOnly }.count,
                processOnlyCount: rows.filter(\.isProcessOnly).count,
                focusPrecision: Self.supportFocus(in: rows)
            )
        }
    }

    /// Exact only when every reachable row lands exactly — the honest floor.
    nonisolated static func supportFocus(in rows: [AgentRow]) -> LandingPlan.Precision? {
        let precisions = rows.compactMap(\.landingPlan.precision)
        guard !precisions.isEmpty else { return nil }
        return precisions.allSatisfy { $0 == .exact } ? .exact : .app
    }

    /// One line on the session log for the diagnostics copy — counts only.
    var sessionLogDiagnostics: String {
        "sessionLog: sessions=\(sessionLog.sessions.count) waiting=\(sessionLog.waitingKeys.count) "
            + "waits=\(sessionLog.waitCount) baseline=\(sessionLog.baselineEstablished)"
    }

    // MARK: - One agent, in sentences

    /// What each agent's line says when it is opened: its hook and when it
    /// last fired, what is on the list, how a Waiting reaches Pulse, how a
    /// session would be focused.
    func supportDetails(_ item: AgentSupportHealth) -> [String] {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var details: [String] = []
        if item.agent == .cursor { details.append(tr(.supportSharedCursor)) }
        if item.hookInstalled {
            details.append(tr(.settingsHookInstalled))
            if item.lastEventMs > 0 {
                let seconds = Double(max(0, nowMs - item.lastEventMs)) / 1000
                details.append(String(format: tr(.settingsHookLastEvent), DurationFormat.label(seconds: seconds, lang: lang)))
            } else {
                details.append(tr(.settingsHookNoEvent))
            }
        } else {
            details.append(item.vendorPresent ? tr(.hooksMissing) : tr(.settingsHookNotFound))
        }
        if item.sessionCount > 0 {
            details.append(String(format: tr(.supportSessions), item.sessionCount))
        }
        if item.processOnlyCount > 0 {
            details.append(String(format: tr(.supportProcessOnly), item.processOnlyCount))
        }
        details.append(item.agent.waitingSource == .hooks ? tr(.supportWaitingHooks) : tr(.supportWaitingNoneDetail))
        if item.sessionCount + item.processOnlyCount > 0 { details.append(supportFocusDetail(item)) }
        return details
    }

    /// Diagnostics' Focus fact — observation-only when nothing is clickable.
    func supportFocusDetail(_ health: AgentSupportHealth) -> String {
        switch health.focusPrecision {
        case .exact: return tr(.supportFocusExact)
        case .app: return tr(.supportFocusApp)
        case nil: return tr(.supportFocusNone)
        }
    }

    // MARK: - The self-check (19.0)

    func runDoctor() {
        guard !diagnostics.isRunningDoctor else { return }
        diagnostics.isRunningDoctor = true
        let home = HooksInstaller.homeURL
        let lang = self.lang
        let lastFire = engine.latestHookEvents
        DebugLog.write("self-check started")
        Task.detached(priority: .userInitiated) {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let facts = DoctorProbe.gather(home: home, nowMs: nowMs, lastFire: lastFire)
            let report = DoctorModel.evaluate(facts, lang: lang)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.diagnostics.doctorReport = report
                self.diagnostics.isRunningDoctor = false
                DebugLog.write("self-check done: \(report.checks.map { "\($0.id)=\($0.verdict.rawValue)" }.joined(separator: " "))")
            }
        }
    }

    /// 21.0: the self-check's next step, taken from the self-check.
    func performDoctorFix(_ fix: DoctorModel.Fix) {
        switch fix {
        case .installHooks: installHooks()
        case .openConnections: openSettings(focus: .waitingSignals)
        }
    }

    /// When Pulse last looked, how often it looks for processes, and what
    /// the tray leaves out. Read by Diagnostics.
    var scanHealthLine: String {
        let now = Date()
        var parts: [String] = []
        let lastRead = Self.lastReadDate(lastScanAt: engine.lastScanAt, snapshotUpdatedAt: snapshot.updatedAt)
        if let lastRead {
            let ago = now.timeIntervalSince(lastRead)
            parts.append(ago < 5
                ? tr(.lastReadJustNow)
                : String(format: tr(.lastReadAgo), DurationFormat.label(seconds: ago, lang: lang)))
        }
        parts.append(probeIntervalDescription)
        if snapshot.staleHidden > 0 {
            let names = L10n.joinNames(snapshot.staleHiddenAgents.prefix(3).map(\.displayName), lang)
            parts.append(String(format: tr(.staleHidden), snapshot.staleHidden, names))
        }
        return parts.joined(separator: " · ")
    }

    /// Pure: when Pulse last looked — the newer of the last projection and
    /// the last published snapshot; nil before either.
    nonisolated static func lastReadDate(lastScanAt: Date?, snapshotUpdatedAt: Date) -> Date? {
        let published: Date? = snapshotUpdatedAt == .distantPast ? nil : snapshotUpdatedAt
        switch (lastScanAt, published) {
        case let (scan?, snap?): return max(scan, snap)
        case let (scan?, nil): return scan
        case let (nil, snap?): return snap
        case (nil, nil): return nil
        }
    }

    // MARK: - Diagnostics (23.0)

    /// The Diagnostics window as a value.
    func diagnosticsModel(activityAgent: AgentID?) -> DiagnosticsModel {
        var banners: [DiagnosticsModel.Problem] = []
        if isVersionMismatch, let bundle = PulseVersion.bundleVersion {
            banners.append(.init(
                id: "version",
                text: String(format: tr(.versionMismatchHint), PulseVersion.semver, bundle)
            ))
        }
        if needsHooksNudge {
            banners.append(.init(
                id: "hooks", text: tr(.hooksNudge),
                fix: .installHooks, fixTitle: DiagnosticsModel.fixTitle(.installHooks, lang: lang)
            ))
        }
        let agents = supportHealth.map { item -> DiagnosticsModel.Agent in
            let fix = DiagnosticsModel.fix(for: item)
            return DiagnosticsModel.Agent(
                agent: item.agent,
                name: item.agent.displayName,
                state: DiagnosticsModel.stateWord(item.disposition, lang: lang),
                tone: DiagnosticsModel.tone(item.disposition),
                severity: DiagnosticsModel.severity(item.disposition),
                fix: fix,
                fixTitle: fix.map { DiagnosticsModel.fixTitle($0, lang: lang) } ?? "",
                warning: nil,
                details: supportDetails(item)
            )
        }
        return DiagnosticsModel.make(DiagnosticsModel.Input(
            lang: lang,
            scanLine: scanHealthLine,
            banners: banners,
            doctor: diagnostics.doctorReport,
            doctorRunning: diagnostics.isRunningDoctor,
            agents: agents,
            activity: activityLog(agent: activityAgent),
            activityAgents: activityAgents,
            copied: diagnostics.didCopyDiagnostics
        ))
    }

    func performDiagnosticsFix(_ fix: DiagnosticsModel.Fix) {
        switch fix {
        case .installHooks: installHooks()
        case .doctor(let doctorFix): performDoctorFix(doctorFix)
        }
    }
}

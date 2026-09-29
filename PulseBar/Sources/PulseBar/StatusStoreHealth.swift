import Foundation
import AppKit

/// Diagnostics (23.0; it was Health) — the model's side: per-agent health
/// built from the rows and the engine's collector bookkeeping, the copy each
/// agent line shows, the one report, the self-check, and the window's value
/// (`diagnosticsModel`).
@MainActor
extension StatusStore {
    /// Current cadence, for Diagnostics and the report ("probing every 5s").
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

    /// A previewable, deliberately path-free support report. It contains
    /// adapter health and capability booleans, never prompts, session IDs,
    /// workspace paths, tool payloads, or command lines.
    func safeSupportReport() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let authLabel: String = {
            switch notifyAuthorized {
            case .some(true): return "authorized"
            case .some(false): return "denied"
            case .none: return "unknown"
            }
        }()
        let timeoutAgents = engine.collectorHealthByAgent.values
            .filter { $0.errorKind == "native_timeout" }
            .map(\.id.rawValue)
            .sorted()
            .joined(separator: ",")
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let healthItems = supportHealth
        let factPresent = healthItems.reduce(0) { $0 + $1.usefulFactCount }
        let factPossible = healthItems.reduce(0) { $0 + $1.usefulFactTotal }
        let limitedAgents = healthItems.filter { $0.disposition == .limited }.count
        let failures = engine.harvestSupervisor.failureTimeline(nowMs: nowMs)
        var lines = [
            "Pulse safe support report",
            PulseVersion.fingerprint,
            "channel: \(PulseVersion.distributionChannel)",
            "notarized: \(PulseVersion.isNotarized)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Agents: \(healthItems.count)",
            "waitingNone: \(AgentID.waitingNoneAgents.map(\.rawValue).joined(separator: ","))",
            "gatekeeperReady: \(PulseVersion.isGatekeeperReady)",
            "appDataScan: \(settings.readProtectedAppData ? "all" : "disabled")",
            "appDataGrant: \(settings.readProtectedAppData ? "all" : "none")",
            "notifications: authorization=\(authLabel) notifyWaiting=\(settings.notifyOnWaiting) queued=\(sessionLog.queuedKeys.count)",
            "probeCadence: \(probeIntervalDescription)",
            "launchAtLogin: \(settings.launchAtLogin) applied=\(loginItemApplied.map(String.init) ?? "untouched")",
            "harvest: native (no external runtime)",
            "collectorScan: \(collectorScanIncomplete ? "partial" : "complete")",
            "timeoutAgents: \(timeoutAgents.isEmpty ? "-" : timeoutAgents)",
            "factCoverage: present=\(factPresent) possible=\(factPossible) limitedAgents=\(limitedAgents)",
            sessionLogDiagnostics,
            "harvestSupervisor: \(engine.harvestSupervisor.summary(nowMs: nowMs))",
        ]
        if failures.isEmpty {
            lines.append("failureTimeline: -")
        } else {
            lines.append("failureTimeline:")
            for entry in failures {
                let ageSec = max(0, (nowMs - entry.atMs) / 1000)
                lines.append(
                    "  \(entry.agent.rawValue)=\(entry.error) ageSec=\(ageSec)"
                )
            }
        }
        for item in healthItems {
            let waiting = item.agent.waitingSource == .none
                ? "n/a"
                : String(item.waitingSignalReady)
            let health = engine.collectorHealthByAgent[item.agent]
            let err = health?.errorKind.isEmpty == false ? health!.errorKind : "-"
            let dur = health?.durationMs ?? 0
            let harvest = item.agent.harvestSource == .bestEffortCache ? "cache" : "session"
            lines.append(
                "\(item.agent.rawValue): \(item.collectorState.rawValue) "
                    + "disposition=\(item.disposition) evidence=\(item.evidence?.rawValue ?? "none") "
                    + "harvest=\(harvest) "
                    + "goal=\(item.hasGoal) workspace=\(item.hasWorkspace) "
                    + "activity=\(item.hasActivity) progress=\(item.hasProgress) "
                    + "waiting=\(waiting) "
                    + "score=\(item.usefulFactCount)/\(item.usefulFactTotal) "
                    + "privacyLimited=\(item.privacyLimited) "
                    + "error=\(err) durationMs=\(dur) "
                    // How the adapter reached that result. Without this line an
                    // `observed` adapter with a blank hero looked identical to a
                    // healthy one, and finding out which layer lost the title
                    // cost a release.
                    + "explain=[\(health?.explain.summary ?? "-")]"
            )
        }
        return ContentSanitizer.redact(lines.joined(separator: "\n"))
    }

    /// The vendor-shape report, on the clipboard, from a button.
    ///
    /// `--harvest-shape` has been the one diagnostic that only a terminal could
    /// produce, and it is exactly the evidence a parsing fix needs: which keys
    /// an agent actually writes, rather than which keys someone inferred. Two
    /// releases of parsing work have stayed deliberately empty waiting for it.
    /// It walks the session stores, so it runs off the main thread and only
    /// when asked.
    @MainActor
    func copyHarvestShapeReport() {
        guard !diagnostics.isCopyingShapeReport else { return }
        diagnostics.isCopyingShapeReport = true
        let readAppData = settings.readProtectedAppData
        DispatchQueue.global(qos: .userInitiated).async {
            let safe = ContentSanitizer.redact(
                NativeActivityHarvest.shapeReport(allowAppData: readAppData)
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(safe, forType: .string)
                self.diagnostics.isCopyingShapeReport = false
                self.diagnostics.didCopyShapeReport = true
                DebugLog.write("harvest shape report copied bytes=\(safe.utf8.count)")
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                self.diagnostics.didCopyShapeReport = false
            }
        }
    }

    var supportHealth: [AgentSupportHealth] {
        // Cached by the scan: a Diagnostics redraw reads no file.
        let waitingEvents = previewWaitingEventTimes ?? engine.latestHookEventMs
        // Cursor Agent is a transport identity, not a second product. Its
        // process/session rows are normalized into Cursor by SnapshotBuilder;
        // listing it again here made the coverage screen claim two adapters
        // and split the same health result into duplicate entries.
        let displayAgents = AgentID.priority.filter { $0 != .cursorAgent }
        return displayAgents.map { agent in
            let rows = cachedAll.filter {
                $0.agent == agent || (agent == .cursor && $0.agent == .cursorAgent)
            }
            let health = engine.collectorHealthByAgent[agent]
                ?? (agent == .cursor ? engine.collectorHealthByAgent[.cursorAgent] : nil)
            let strongest: ObservationSource? = {
                if rows.contains(where: { $0.source == .session }) { return .session }
                if rows.contains(where: { $0.source == .cache }) { return .cache }
                if !rows.isEmpty { return .process }
                return nil
            }()
            let process = engine.processesByAgent[agent]
                ?? (agent == .cursor ? engine.processesByAgent[.cursorAgent] : nil)
            let measured = health?.factClasses ?? []
            return AgentSupportHealth(
                agent: agent,
                collectorState: health?.state ?? .unscanned,
                collectorDurationMs: health?.durationMs ?? 0,
                collectorRows: health?.rowCount ?? 0,
                sourcePresent: health?.sourcePresent ?? false,
                collectorErrorKind: health?.errorKind ?? "",
                processDetected: rows.contains(where: \.liveProcess),
                processEvidence: process?.evidence,
                processStartedMs: process?.startedMs ?? 0,
                processCount: process?.count ?? 0,
                evidence: strongest,
                // This clock is when Pulse successfully read the adapter, not
                // when the vendor session last changed. Reusing row.harvestMs
                // here made a healthy idle collector look months stale.
                lastSuccessfulReadMs: engine.lastSuccessfulReadByAgent[agent] ?? 0,
                lastWaitingSignalMs: waitingEvents[agent] ?? 0,
                hasGoal: rows.contains { $0.usefulTask != nil },
                hasWorkspace: rows.contains { !$0.displayPath.isEmpty },
                // Process age is evidence that an executable exists, not an
                // Agent activity feed. Keep the activity fact reserved for a
                // session/cache timestamp so process-only rows cannot claim
                // 4/4 core facts while simultaneously admitting the feed is
                // unavailable.
                hasActivity: rows.contains {
                    $0.harvestMs > 0 && ($0.source == .session || $0.source == .cache)
                },
                // What the session is getting on with: its plan, its words,
                // its errors, its model — or, measured by the collector this
                // scan, its tools and tokens.
                hasProgress: rows.contains {
                    !$0.planSteps.isEmpty || !$0.lastWord.isEmpty || $0.errors > 0 || !$0.model.isEmpty
                } || !measured.isDisjoint(with: ["tool", "tokens", "progress", "plan", "word", "error", "model"]),
                waitingSignalReady: waitingSignalReady(for: agent),
                privacyLimited: settings.isPrivacyLimited(agent),
                hasActionSignal: measured.contains("tool"),
                hasModelSignal: rows.contains { !$0.model.isEmpty } || measured.contains("model"),
                hasResourceSignal: measured.contains("tokens") || rows.contains { $0.errors > 0 },
                focusTier: bestSupportFocus(in: rows),
                focusTTYNeedsOptIn: supportTTYNeedsOptIn(in: rows),
                activityAgeSeconds: {
                    let clocks = rows.map(\.lastActivityMs).filter { $0 > 0 }
                    guard let newest = clocks.max() else { return 0 }
                    return max(0, Date().timeIntervalSince1970 - Double(newest) / 1000.0)
                }(),
                hasStalledLive: rows.contains { $0.liveProcess && $0.isStalled },
                collectorExplain: health?.explain ?? ActivityHarvest.CollectorExplain(),
                factClasses: health?.factClasses ?? [],
                looksDrifted: health?.looksDrifted ?? false
            )
        }
    }

    /// Prefer Warp → host workspace → host app → TTY — honesty order.
    private func bestSupportFocus(in rows: [AgentRow]) -> FocusTier? {
        let tiers = rows.compactMap(\.focusTier)
        if tiers.contains(where: { if case .warp = $0 { return true }; return false }) {
            return .warp
        }
        if let host = tiers.compactMap({ tier -> HostAppKind? in
            if case .hostWorkspace(let kind) = tier { return kind }
            return nil
        }).first {
            return .hostWorkspace(host)
        }
        if let host = tiers.compactMap({ tier -> HostAppKind? in
            if case .hostApp(let kind) = tier { return kind }
            return nil
        }).first {
            return .hostApp(host)
        }
        if tiers.contains(where: { if case .tty = $0 { return true }; return false }) {
            return .tty
        }
        return nil
    }

    /// Real TTY on a row that still has no advertised focus (Automation off).
    private func supportTTYNeedsOptIn(in rows: [AgentRow]) -> Bool {
        guard !settings.allowTerminalAutomation else { return false }
        return rows.contains { row in
            guard row.focusTier == nil, !row.viaWarp, row.hostApp == nil else { return false }
            var t = row.tty.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("/dev/") { t = String(t.dropFirst(5)) }
            return !t.isEmpty && t != "?" && t != "??" && t != "-"
        }
    }

    var privacyLimitedAgents: [AgentSupportHealth] {
        supportHealth.filter(\.privacyLimited)
    }

    var privacyLimitedCount: Int { privacyLimitedAgents.count }

    /// Banner when protected agents are out of reach (the app-data switch
    /// is off and at least one of them matters here).
    var privacyBannerText: String? {
        guard !settings.readProtectedAppData, privacyLimitedCount > 0 else { return nil }
        return tr(.supportCollectorPrivacyLimitedDetail)
    }

    /// Incomplete-scan banner: timeout-with-rows is not the same claim as a
    /// blank failure.
    var scanIncompleteBannerText: String? {
        guard collectorScanIncomplete else { return nil }
        let timedOutWithRows = engine.collectorHealthByAgent.values.contains {
            $0.errorKind == "native_timeout" && $0.rowCount > 0
        }
        if timedOutWithRows {
            return tr(.supportScanIncompleteTimeout)
        }
        return tr(.supportScanIncomplete)
    }

    /// One line on the session log for the diagnostics copy — counts only.
    var sessionLogDiagnostics: String {
        "sessionLog: sessions=\(sessionLog.sessions.count) waiting=\(sessionLog.waitingKeys.count) "
            + "suppressed=\(sessionLog.suppressedKeys.count) waits=\(sessionLog.waitCount) "
            + "baseline=\(sessionLog.baselineEstablished)"
    }

    private func waitingSignalReady(for agent: AgentID) -> Bool {
        switch agent.waitingSource {
        case .hooks:
            if hooksStatus.isInstalled(for: agent) { return true }
            // Codex also has a harvest-pending Waiting path (README matrix).
            if agent == .codex {
                let state = engine.collectorHealthByAgent[agent]?.state ?? .unscanned
                return state == .observed || state == .noRecentData
            }
            return false
        case .harvestPending:
            let state = engine.collectorHealthByAgent[agent]?.state
                ?? (agent == .cursor ? engine.collectorHealthByAgent[.cursorAgent]?.state : nil)
                ?? .unscanned
            // A source that exists but yielded no usable session cannot yet
            // prove a pending signal. Counting `.noSessions` as ready made a
            // process-only Amp row read “1/5 useful signals” despite having no
            // activity feed or actionable Waiting route.
            return state == .observed || state == .noRecentData
        case .none:
            return false
        }
    }

    func supportEvidenceLabel(_ health: AgentSupportHealth) -> String {
        // A bounded timeout that already returned rows is a partial read, not
        // an empty adapter failure. Keep the error detail in the inspector,
        // but classify the row as limited so useful evidence remains primary.
        if health.collectorState == .failed, health.collectorRows > 0 {
            return tr(.supportLimited)
        }
        if health.collectorState == .failed { return tr(.supportCollectorFailed) }
        if health.collectorState == .unscanned { return tr(.supportCollectorUnscanned) }
        if health.collectorState == .permissionDenied { return tr(.supportCollectorPermission) }
        if health.collectorState == .schemaMismatch { return tr(.supportCollectorSchema) }
        if health.privacyLimited, !health.isObserved {
            return tr(.supportCollectorPrivacyLimited)
        }
        if health.collectorState == .sourceAbsent, !health.isObserved {
            return tr(.supportCollectorSourceAbsent)
        }
        if [.noRecentData, .noSessions].contains(health.collectorState), !health.isObserved {
            return tr(.supportCollectorNoSessions)
        }
        guard health.isObserved else { return tr(.supportNotDetected) }
        switch health.evidence {
        case .session: return tr(.supportStructured)
        case .cache: return tr(.supportCache)
        case .process: return tr(.supportProcess)
        case .none: return tr(.supportDetected)
        }
    }

    func supportAdapterDetail(_ health: AgentSupportHealth) -> String {
        var facts: [String] = []
        if health.agent == .cursor {
            facts.append(tr(.supportSharedCursor))
        }
        switch health.collectorState {
        case .observed:
            facts.append(String(
                format: tr(.supportCollectorObserved),
                health.collectorRows,
                health.collectorDurationMs
            ))
        case .noRecentData, .noSessions:
            facts.append(String(
                format: tr(.supportCollectorNoSessionsDetail),
                health.collectorDurationMs
            ))
            if health.privacyLimited {
                facts.append(tr(.supportCollectorPrivacyLimitedDetail))
            }
        case .sourceAbsent:
            facts.append(
                health.privacyLimited
                    ? tr(.supportCollectorPrivacyLimitedDetail)
                    : tr(.supportCollectorSourceAbsentDetail)
            )
        case .permissionDenied:
            facts.append(tr(.supportCollectorPermissionDetail))
        case .schemaMismatch:
            facts.append(tr(.supportCollectorSchemaDetail))
        case .failed:
            let kind = health.collectorErrorKind.isEmpty ? tr(.supportCollectorFailed) : health.collectorErrorKind
            facts.append(String(format: tr(.supportCollectorFailedDetail), kind))
        case .unscanned:
            facts.append(tr(.supportCollectorUnscannedDetail))
        }
        return facts.joined(separator: " · ")
    }

    /// What the adapter actually read this pass: files opened, bytes spent,
    /// facts produced, and whether any window was truncated. Empty when the
    /// adapter never got to read anything, so the line disappears instead of
    /// printing a row of zeros.
    ///
    /// This is the half of `CollectorExplain` that says how much work happened.
    /// `supportCollectorOutcomeDetail` says what came of it.
    func supportReadingDetail(_ health: AgentSupportHealth) -> String {
        let explain = health.collectorExplain
        var facts: [String] = []
        if explain.filesRead > 0 {
            facts.append(String(format: tr(.supportExplainFiles), explain.filesRead))
        }
        let size = AgentRow.compactBytes(explain.bytesRead)
        if !size.isEmpty { facts.append(size) }
        if explain.factsParsed > 0 {
            facts.append(String(format: tr(.supportExplainFacts), explain.factsParsed))
        }
        // Said last and said plainly: once a window is truncated every count
        // above it is a floor. Printing the numbers without this would be the
        // estimate-as-total the whole project forbids.
        if explain.truncated { facts.append(tr(.supportExplainTruncated)) }
        return facts.joined(separator: " · ")
    }

    /// What came of the read: where the headline came from, or which layer
    /// lost it. The second one is the question Support Health exists to
    /// answer and the one that used to require reading debug.log.
    /// 2.9 · declared vs measured: which fact classes actually came out of
    /// the latest scan, and the one degradation worth naming out loud —
    /// a structured adapter that produced rows but zero core facts. Names
    /// only; no values, no paths.
    func supportYieldDetail(_ item: AgentSupportHealth) -> String {
        if item.looksDrifted {
            return tr(.supportYieldDrifted)
        }
        guard !item.factClasses.isEmpty else { return "" }
        let order = ["task", "tool", "tokens", "progress", "plan", "word", "error", "model", "workspace"]
        let present = order.filter { item.factClasses.contains($0) }
        guard !present.isEmpty else { return "" }
        return String(format: tr(.supportYield), present.joined(separator: " · "))
    }

    func supportCollectorOutcomeDetail(_ health: AgentSupportHealth) -> String {
        let explain = health.collectorExplain
        if !explain.emptyReason.isEmpty {
            return String(format: tr(.supportExplainEmpty), collectorEmptyReasonLabel(explain.emptyReason))
        }
        guard !explain.heroOrigin.isEmpty else { return "" }
        return String(format: tr(.supportExplainHero), collectorOriginLabel(explain.heroOrigin))
    }

    /// The adapter's fixed tag, in words. An unknown tag is passed through
    /// rather than swallowed — a new reason must be visible the day it ships,
    /// not the release after somebody notices the blank.
    func collectorEmptyReasonLabel(_ raw: String) -> String {
        switch raw {
        case "no_source": return tr(.supportEmptyNoSource)
        case "deadline": return tr(.supportEmptyDeadline)
        case "no_readable_file": return tr(.supportEmptyNoReadableFile)
        case "no_parsable_record": return tr(.supportEmptyNoParsableRecord)
        case "facts_without_display_signal": return tr(.supportEmptyNoDisplaySignal)
        case "no_user_goal_in_records": return tr(.supportEmptyNoUserGoal)
        default: return raw
        }
    }

    func collectorOriginLabel(_ raw: String) -> String {
        switch raw {
        case "chrome": return tr(.supportOriginChrome)
        case "fallback_text": return tr(.supportOriginFallbackText)
        case "cache_title": return tr(.supportOriginCacheTitle)
        case "tool_title": return tr(.supportOriginToolTitle)
        case "user_prompt": return tr(.supportOriginUserPrompt)
        case "session_name": return tr(.supportOriginSessionName)
        default: return raw
        }
    }

    func supportCoverageDetail(_ health: AgentSupportHealth) -> String {
        guard health.isObserved else { return "" }
        var facts: [String] = []
        if health.isObserved {
            if health.hasGoal { facts.append(tr(.supportGoal)) }
            if health.hasWorkspace { facts.append(tr(.supportWorkspace)) }
            if health.hasActivity { facts.append(tr(.supportActivity)) }
            if health.hasProgress { facts.append(tr(.supportProgress)) }
            facts.append(String(
                format: tr(.supportFactCoverage),
                health.observedFactCount,
                health.usefulFactTotal
            ))
        }
        return facts.joined(separator: " · ")
    }

    /// The score pills answer “how much can Pulse observe?”; this answers the
    /// next question, “what did it actually observe?” Keeping one compact,
    /// representative session per adapter makes the 31-agent matrix useful
    /// without turning it into a transcript or exposing raw session IDs.
    func supportObservedDetail(_ health: AgentSupportHealth) -> String {
        // Cursor Agent is normalized into Cursor for the user-facing support
        // row. Keep the evidence lookup normalized too; otherwise a Cursor
        // Agent-only session can score correctly above and still render as
        // "no usable session signals" below it.
        let candidates = cachedAll.filter {
            $0.agent == health.agent || (health.agent == .cursor && $0.agent == .cursorAgent)
        }
        guard let row = candidates.max(by: { lhs, rhs in
            let left = (
                lhs.isBlocked ? 4 : 0,
                lhs.liveProcess ? 2 : 0,
                lhs.harvestMs
            )
            let right = (
                rhs.isBlocked ? 4 : 0,
                rhs.liveProcess ? 2 : 0,
                rhs.harvestMs
            )
            return left < right
        }) else { return "" }

        var facts: [String] = []
        if let task = row.usefulTask { facts.append(task) }
        if !row.displayPath.isEmpty { facts.append(row.displayPath) }
        let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { facts.append(String(format: tr(.modelFact), model)) }
        if row.errors > 0 {
            facts.append(row.errors == 1 ? tr(.errorFactOne) : String(format: tr(.errorsFact), row.errors))
        }
        guard !facts.isEmpty else { return "" }
        let clipped = facts.prefix(4).joined(separator: " · ")
        return String(format: tr(.supportObservedSignals), clipped)
    }

    func supportTimelineDetail(_ health: AgentSupportHealth) -> String {
        var facts: [String] = []
        if health.processDetected {
            let evidence = health.processEvidence == .pathSignature
                ? tr(.supportDetectedPath)
                : tr(.supportDetectedExecutable)
            facts.append(evidence)
            if health.processStartedMs > 0 {
                let seconds = max(
                    0,
                    Date().timeIntervalSince1970 - Double(health.processStartedMs) / 1000.0
                )
                facts.append(String(
                    format: tr(.processAge),
                    DurationFormat.label(seconds: seconds, lang: lang)
                ))
            }
            if health.processCount > 1 {
                facts.append(String(format: tr(.processCount), health.processCount))
            }
        }
        facts.append(supportWaitingLabel(health.agent))
        if health.hasStalledLive {
            if health.activityAgeSeconds > 0 {
                facts.append(String(
                    format: tr(.stalledFor),
                    DurationFormat.label(seconds: health.activityAgeSeconds, lang: lang)
                ))
            } else {
                facts.append(tr(.stalled))
            }
        } else if health.hasActivity, health.activityAgeSeconds > 0 {
            facts.append(String(
                format: tr(.agoFormat),
                DurationFormat.label(seconds: health.activityAgeSeconds, lang: lang)
            ))
        } else if health.processDetected, !health.hasActivity {
            facts.append(tr(.noActivityYet))
        }
        if health.lastWaitingSignalMs > 0 {
            let seconds = max(
                0,
                Date().timeIntervalSince1970 - Double(health.lastWaitingSignalMs) / 1000.0
            )
            facts.append(String(
                format: tr(.supportLastSignal),
                DurationFormat.label(seconds: seconds, lang: lang)
            ))
        }
        if health.lastSuccessfulReadMs > 0 {
            let seconds = max(
                0,
                Date().timeIntervalSince1970 - Double(health.lastSuccessfulReadMs) / 1000.0
            )
            facts.append(String(
                format: tr(.supportLastRead),
                DurationFormat.label(seconds: seconds, lang: lang)
            ))
        }
        return facts.joined(separator: " · ")
    }

    func supportMissingDetail(_ health: AgentSupportHealth) -> String? {
        let missing = health.missingCapabilities.map { capability -> String in
            switch capability {
            case .notDetected: return tr(.supportNotDetected)
            case .activityFeed: return tr(.supportMissingFeed)
            case .goal: return tr(.supportMissingGoal)
            case .workspace: return tr(.supportMissingWorkspace)
            case .waitingSignal: return tr(.supportMissingWaiting)
            }
        }
        if health.isObserved, !missing.isEmpty {
            return String(format: tr(.supportMissing), missing.joined(separator: ", "))
        }
        return nil
    }

    private func supportWaitingLabel(_ agent: AgentID) -> String {
        switch agent.waitingSource {
        case .hooks: return tr(.supportWaitingHooks)
        case .harvestPending: return tr(.supportWaitingHarvest)
        case .none: return tr(.supportWaitingNoneDetail)
        }
    }

    /// Compact collector failure age for Support diagnostics (empty when clean).
    func supportFailureTimelineDetail(_ health: AgentSupportHealth) -> String? {
        let state = engine.harvestSupervisor.state(for: health.agent)
        guard state.lastFailureAtMs > 0, !state.lastError.isEmpty else { return nil }
        let seconds = max(0, Date().timeIntervalSince1970 - Double(state.lastFailureAtMs) / 1000.0)
        return String(
            format: tr(.supportFailureTimelineEntry),
            state.lastError,
            DurationFormat.label(seconds: seconds, lang: lang)
        )
    }

    /// Support Health Focus fact — observation-only when nothing is clickable.
    func supportFocusDetail(_ health: AgentSupportHealth) -> String {
        if let tier = health.focusTier {
            switch tier {
            case .warp: return tr(.supportFocusWarp)
            case .hostWorkspace(let kind):
                return String(format: tr(.supportFocusHostWorkspace), kind.displayName)
            case .hostApp(let kind):
                return String(format: tr(.supportFocusHost), kind.displayName)
            case .tty: return tr(.supportFocusTTY)
            }
        }
        if health.focusTTYNeedsOptIn {
            return tr(.supportFocusTTYNeedsOptIn)
        }
        return tr(.supportFocusNone)
    }

    /// Thin vs deep observation — never let a cache/none Agent look session-deep.
    /// Rich cache (goal + workspace/activity) stays Limited but says so honestly.
    /// Waiting-none still exposes harvest depth so ZCode/Trae cannot hide behind
    /// “Waiting unavailable” alone (0.70 Contract Honesty).
    func supportDepthDetail(_ health: AgentSupportHealth) -> String {
        let harvest: String
        switch health.agent.harvestSource {
        case .bestEffortCache:
            let rich = health.hasGoal && (health.hasWorkspace || health.hasActivity)
            harvest = rich ? tr(.supportDepthCachePartial) : tr(.supportDepthCacheThin)
        case .structuredSession:
            harvest = tr(.supportDepthSession)
        }
        if health.agent.waitingSource == .none {
            return "\(tr(.supportDepthWaitingNone)) · \(harvest)"
        }
        return harvest
    }

    // MARK: - The self-check (19.0)

    /// 20.0: what the parsers got from each agent's session files this run —
    /// counts only.
    var doctorReadCoverage: [String: DoctorModel.Coverage] {
        var coverage: [String: DoctorModel.Coverage] = [:]
        for row in cachedAll where row.source == .session {
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
        guard !diagnostics.isRunningDoctor else { return }
        diagnostics.isRunningDoctor = true
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
                self.diagnostics.doctorReport = report
                self.diagnostics.isRunningDoctor = false
                DebugLog.write("self-check done: \(report.checks.map { "\($0.id)=\($0.verdict.rawValue)" }.joined(separator: " "))")
            }
        }
    }

    /// 21.0: the self-check's next step, taken from the self-check.
    func performDoctorFix(_ fix: DoctorModel.Fix) {
        switch fix {
        case .installHooks:
            installHooks()
        case .copyShapeReport:
            copyHarvestShapeReport()
        case .openConnections:
            openSettings(focus: .waitingSignals)
        }
    }

    /// 21.0: when Pulse last read, how often it reads, and what that has
    /// cost over the last hour — the facts that were only in the clipboard
    /// dump — and what the tray leaves out. Read by Diagnostics.
    var scanHealthLine: String {
        let now = Date()
        var parts: [String] = []
        // `lastScanAt` moves on every applied scan; `snapshot.updatedAt`
        // only when the snapshot publishes, so it can read a minute stale.
        let lastRead = Self.lastReadDate(lastScanAt: engine.lastScanAt, snapshotUpdatedAt: snapshot.updatedAt)
        if let lastRead {
            let ago = now.timeIntervalSince(lastRead)
            parts.append(ago < 5
                ? tr(.lastReadJustNow)
                : String(format: tr(.lastReadAgo), DurationFormat.label(seconds: ago, lang: lang)))
        }
        parts.append(probeIntervalDescription)
        // 23.0: what the tray leaves out is counted here, not in the tray.
        if snapshot.staleHidden > 0 {
            let names = L10n.joinNames(snapshot.staleHiddenAgents.prefix(3).map(\.displayName), lang)
            parts.append(String(format: tr(.staleHidden), snapshot.staleHidden, names))
        }
        if snapshot.cappedSessions > 0 {
            parts.append(String(format: tr(.cappedSessions), snapshot.cappedSessions))
        }
        let reads = engine.probeStats.harvestCount(now: now)
        if reads > 0 {
            if let avg = engine.probeStats.averageHarvestMs(now: now) {
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
        if let privacy = privacyBannerText {
            banners.append(.init(
                id: "privacy", text: privacy,
                fix: .openDataAccess, fixTitle: DiagnosticsModel.fixTitle(.openDataAccess, lang: lang)
            ))
        }
        if let incomplete = scanIncompleteBannerText {
            banners.append(.init(
                id: "scan", text: incomplete,
                fix: .retryScan, fixTitle: DiagnosticsModel.fixTitle(.retryScan, lang: lang)
            ))
        }
        let agents = supportHealth.map { item -> DiagnosticsModel.Agent in
            let fix = DiagnosticsModel.fix(item.repair)
            var warning: String?
            if item.looksDrifted {
                warning = supportYieldDetail(item)
            } else if item.collectorErrorKind == "native_timeout" {
                warning = tr(.qualityReasonScanTimeout)
            }
            var details = [
                supportEvidenceLabel(item),
                supportFocusDetail(item),
                supportDepthDetail(item),
                supportCoverageDetail(item),
                supportObservedDetail(item),
                supportTimelineDetail(item),
                supportMissingDetail(item) ?? "",
                supportAdapterDetail(item),
                supportReadingDetail(item),
                supportCollectorOutcomeDetail(item),
                supportFailureTimelineDetail(item) ?? "",
            ]
            if !item.looksDrifted { details.append(supportYieldDetail(item)) }
            return DiagnosticsModel.Agent(
                agent: item.agent,
                name: item.agent.displayName,
                state: DiagnosticsModel.stateWord(item.disposition, lang: lang),
                tone: DiagnosticsModel.tone(item.disposition),
                severity: DiagnosticsModel.severity(item.disposition),
                fix: fix,
                fixTitle: fix.map { DiagnosticsModel.fixTitle($0, lang: lang) } ?? "",
                warning: warning,
                details: details.filter { !$0.isEmpty }
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
        case .retryScan: refresh(reason: "diagnostics-retry")
        case .openDataAccess: openSettings(focus: .appData)
        case .openHooksSettings: openSettings(focus: .waitingSignals)
        case .doctor(let doctorFix): performDoctorFix(doctorFix)
        }
    }
}

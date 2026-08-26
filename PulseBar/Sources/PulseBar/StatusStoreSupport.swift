import Foundation
import AppKit

/// 4.0-γ file split — Support & diagnostics — reports, health detail, observation gaps.
/// Behavior-frozen: every member moved verbatim from StatusStore.swift;
/// the full test suite is the contract that nothing changed.
extension StatusStore {
    /// Claude/Codex live but hooks not wired — tray nudge only.
    var needsHooksNudge: Bool {
        guard hooksStatus == .missing || hooksStatus == .unknown else { return false }
        return cachedAll.contains {
            $0.liveProcess && ($0.agent == .claude || $0.agent == .codex)
        }
    }

    /// Live agent with no Waiting path (not hooks-dependent) — one-line honesty, not a HUD.
    var needsWaitingSignalNudge: Bool {
        if needsHooksNudge { return false }
        return firstLiveWaitingNoneAgent != nil
    }

    /// First live Waiting-none agent still without an active wait — Reach funnel focus target.
    var firstLiveWaitingNoneAgent: AgentID? {
        cachedAll.first {
            $0.liveProcess && $0.agent.waitingSource == .none && !$0.waiting
        }?.agent
    }

    /// Packaged bundle version disagrees with the compiled semver — usually a
    /// stale `Pulse.app` next to a fresh build. Worth saying out loud.
    var isVersionMismatch: Bool {
        // XCTest and deterministic tray fixtures run from a host bundle whose
        // version is unrelated to Pulse. Do not let that harness detail hide
        // the fixture's observable Waiting signal or affect its screenshots;
        // real packaged launches still keep stale-bundle diagnosis first.
        if previewFixtureActive { return false }
        if case .mismatch = PulseVersion.channel { return true }
        return false
    }

    /// Everything a bug report needs, in one paste.
    func diagnosticsText() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines: [String] = [
            PulseVersion.fingerprint,
            "channel: \(isVersionMismatch ? "mismatch" : PulseVersion.distributionChannel)",
            "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "lang: \(language.rawValue) · autoProbe: \(autoProbe)",
            "appDataScan: \(appDataScanDescription)",
            "harvest: native (no external runtime)",
            "hooks: \(hooksStatus.label(lang: lang))",
            "glance: \(snapshot.glance) · rows: \(snapshot.rows.count)/\(snapshot.totalCount)",
            "cadence: \(probeIntervalDescription) · \(probeStats.summary(now: Date()))",
        ]
        let collector = supportHealth
        let collectorCounts = Dictionary(grouping: collector, by: \.collectorState).mapValues(\.count)
        lines.append("collectorScan: \(collectorScanIncomplete ? "partial" : "complete")")
        lines.append(
            "collectors: observed=\(collectorCounts[.observed] ?? 0) "
                + "sourceAbsent=\(collectorCounts[.sourceAbsent] ?? 0) "
                + "noSessions=\((collectorCounts[.noSessions] ?? 0) + (collectorCounts[.noRecentData] ?? 0)) "
                + "permission=\(collectorCounts[.permissionDenied] ?? 0) "
                + "schema=\(collectorCounts[.schemaMismatch] ?? 0) "
                + "failed=\(collectorCounts[.failed] ?? 0) "
                + "unscanned=\(collectorCounts[.unscanned] ?? 0)"
            )
        let notificationAuthorization = notifyAuthorized.map { String($0) } ?? "unknown"
        lines.append(
            "notifications: authorization=\(notificationAuthorization) "
                + "notifyWaiting=\(notifyOnWaiting) pending=\(pendingWaitingNotifications.count) "
                + "queued=\(attentionLedger.queuedKeys.count)"
        )
        lines.append("harvestSupervisor: \(harvestSupervisor.summary(nowMs: Int64(Date().timeIntervalSince1970 * 1000)))")
        lines.append(
            "attentionLedger: active=\(attentionLedger.activeKeys.count) "
                + "events=\(attentionLedger.events.count) baseline=\(attentionLedger.baselineEstablished)"
        )
        let failedCollectors = collector.filter { $0.collectorState.isIssue }
        if !failedCollectors.isEmpty {
            lines.append(
                "collectorErrors: " + failedCollectors.map {
                    "\($0.agent.rawValue)=\($0.collectorErrorKind.isEmpty ? "unknown" : $0.collectorErrorKind)"
                }.joined(separator: ",")
            )
        }
        if let err = snapshot.probeError { lines.append("probeError: \(err)") }
        lines.append("runningBundle: \(installReport.runningURL.path)")
        lines.append("installCopies: \(installReport.copies.count)")
        for row in cachedAll.prefix(8) {
            lines.append(
                "  \(row.agent.rawValue) waiting=\(row.waiting) live=\(row.liveProcess) "
                    + "signal=\(row.waitSignal?.rawValue ?? "-") sub=\(row.subRunning)/\(row.subTotal)"
            )
        }
        return lines.joined(separator: "\n")
    }

    func copyDiagnostics() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(diagnosticsText(), forType: .string)
        didCopyDiagnostics = true
        DebugLog.write("diagnostics copied")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            self?.didCopyDiagnostics = false
        }
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
        let grantLabel: String = {
            switch appDataGrantMode {
            case .all: return "all"
            case .scoped(let n): return "scoped:\(n)"
            case .none: return "none"
            }
        }()
        let timeoutAgents = collectorHealthByAgent.values
            .filter { $0.errorKind == "native_timeout" }
            .map(\.id.rawValue)
            .sorted()
            .joined(separator: ",")
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let healthItems = supportHealth
        let factPresent = healthItems.reduce(0) { $0 + $1.usefulFactCount }
        let factPossible = healthItems.reduce(0) { $0 + $1.usefulFactTotal }
        let limitedAgents = healthItems.filter { $0.disposition == .limited }.count
        let failures = harvestSupervisor.failureTimeline(nowMs: nowMs)
        var lines = [
            "Pulse safe support report",
            PulseVersion.fingerprint,
            "channel: \(PulseVersion.distributionChannel)",
            "notarized: \(PulseVersion.isNotarized)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Agents: \(healthItems.count)",
            "waitingNone: \(Self.attentionSampleAgents.map(\.rawValue).joined(separator: ","))",
            "gatekeeperReady: \(PulseVersion.isGatekeeperReady)",
            "appDataScan: \(appDataScanDescription)",
            "appDataGrant: \(grantLabel)",
            "notifications: authorization=\(authLabel) notifyWaiting=\(notifyOnWaiting) pending=\(pendingWaitingNotifications.count)",
            "probeCadence: \(probeIntervalDescription)",
            "launchAtLogin: \(launchAtLogin) applied=\(loginItemApplied.map(String.init) ?? "untouched")",
            "harvest: native (no external runtime)",
            "remoteFleet: \(remoteFleetSummary)",
            "sessionDigests: \(HarvestDigests.summary)",
            "collectorScan: \(collectorScanIncomplete ? "partial" : "complete")",
            "timeoutAgents: \(timeoutAgents.isEmpty ? "-" : timeoutAgents)",
            "factCoverage: present=\(factPresent) possible=\(factPossible) limitedAgents=\(limitedAgents)",
            "attentionLedger: active=\(attentionLedger.activeKeys.count) events=\(attentionLedger.events.count) baseline=\(attentionLedger.baselineEstablished)",
            "harvestSupervisor: \(harvestSupervisor.summary(nowMs: nowMs))",
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
            let health = collectorHealthByAgent[item.agent]
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

    /// Remote sources, named. A fleet you cannot see is the problem 1.0 set
    /// out to fix; a fleet Pulse silently failed to read would be the same
    /// problem wearing a different coat.
    var remoteFleetSummary: String {
        let rows = cachedAll.filter(\.isRemote)
        let hosts = Set(rows.map(\.host)).sorted().joined(separator: ",")
        let lost = rows.filter(\.lostContact).count
        let files = AttentionIO.readInbox().count
        return "inbox=\(files) hosts=\(hosts.isEmpty ? "-" : hosts) rows=\(rows.count) lost=\(lost)"
    }

    func copySafeSupportReport() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(safeSupportReport(), forType: .string)
        didCopyDiagnostics = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            self?.didCopyDiagnostics = false
        }
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
        guard !isCopyingShapeReport else { return }
        isCopyingShapeReport = true
        let allowAll = allowAppData
        let agents = harvestAppDataAgents
        DispatchQueue.global(qos: .userInitiated).async {
            let safe = ContentSanitizer.redact(
                NativeActivityHarvest.shapeReport(
                    allowAppData: allowAll,
                    appDataAgents: agents
                )
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(safe, forType: .string)
                self.isCopyingShapeReport = false
                self.didCopyShapeReport = true
                DebugLog.write("harvest shape report copied bytes=\(safe.utf8.count)")
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                self.didCopyShapeReport = false
            }
        }
    }

    @MainActor
    func exportSafeSupportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pulse-support-\(Int(Date().timeIntervalSince1970)).txt"
        panel.canCreateDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let data = ContentSanitizer.redact(self.safeSupportReport()).data(using: .utf8) ?? Data()
                try data.write(to: url, options: .atomic)
                DebugLog.write("safe support report exported")
            } catch {
                DebugLog.write("safe support report export failed \(error.localizedDescription)")
            }
        }
    }

    var supportHealth: [AgentSupportHealth] {
        let waitingEvents = previewWaitingEventTimes ?? AttentionIO.latestEventTimes()
        // Cursor Agent is a transport identity, not a second product. Its
        // process/session rows are normalized into Cursor by SnapshotBuilder;
        // listing it again here made the coverage screen claim two adapters
        // and split the same health result into duplicate entries.
        let displayAgents = AgentID.priority.filter { $0 != .cursorAgent }
        return displayAgents.map { agent in
            let rows = cachedAll.filter {
                $0.agent == agent || (agent == .cursor && $0.agent == .cursorAgent)
            }
            let health = collectorHealthByAgent[agent]
                ?? (agent == .cursor ? collectorHealthByAgent[.cursorAgent] : nil)
            let strongest: ObservationSource? = {
                if rows.contains(where: { $0.observationSource == .session }) { return .session }
                if rows.contains(where: { $0.observationSource == .cache }) { return .cache }
                if rows.contains(where: { $0.observationSource == .process }) { return .process }
                return nil
            }()
            return AgentSupportHealth(
                agent: agent,
                collectorState: health?.state ?? .unscanned,
                collectorDurationMs: health?.durationMs ?? 0,
                collectorRows: health?.rowCount ?? 0,
                sourcePresent: health?.sourcePresent ?? false,
                collectorErrorKind: health?.errorKind ?? "",
                processDetected: rows.contains(where: \.liveProcess),
                processEvidence: rows.compactMap(\.processEvidence).first,
                processStartedMs: rows
                    .filter(\.liveProcess)
                    .map(\.processStartedMs)
                    .filter { $0 > 0 }
                    .min() ?? 0,
                processCount: rows.map(\.processCount).max() ?? 0,
                evidence: strongest,
                // This clock is when Pulse successfully read the adapter, not
                // when the vendor session last changed. Reusing row.harvestMs
                // here made a healthy idle collector look months stale.
                lastSuccessfulReadMs: lastSuccessfulReadByAgent[agent] ?? 0,
                lastWaitingSignalMs: waitingEvents[agent] ?? 0,
                hasGoal: rows.contains { $0.usefulTask != nil },
                hasWorkspace: rows.contains { !$0.displayPath.isEmpty },
                // Process age is evidence that an executable exists, not an
                // Agent activity feed. Keep the activity fact reserved for a
                // session/cache timestamp so process-only rows cannot claim
                // 4/4 core facts while simultaneously admitting the feed is
                // unavailable.
                hasActivity: rows.contains {
                    $0.harvestMs > 0 && $0.observationSource != .process
                },
                hasProgress: rows.contains {
                    !$0.phase.isEmpty || !$0.tool.isEmpty || !$0.outcome.isEmpty
                        || $0.progressDone > 0 || $0.progressTotal > 0
                        || $0.tokensIn > 0 || $0.tokensOut > 0
                        || $0.subTotal > 0 || $0.errors > 0 || $0.files > 0
                        || $0.contextPercent > 0 || !$0.model.isEmpty || !$0.mode.isEmpty
                },
                waitingSignalReady: waitingSignalReady(for: agent),
                privacyLimited: agent.requiresAppDataOptIn && !isAppDataAllowed(for: agent),
                hasActionSignal: rows.contains { !$0.tool.isEmpty },
                hasModelSignal: rows.contains { !$0.model.isEmpty },
                hasResourceSignal: rows.contains {
                    $0.tokensIn > 0 || $0.tokensOut > 0 || $0.records > 0
                        || $0.errors > 0 || $0.files > 0 || $0.contextPercent > 0
                },
                focusTier: bestSupportFocus(in: rows),
                focusTTYNeedsOptIn: supportTTYNeedsOptIn(in: rows),
                activityAgeSeconds: {
                    let clocks = rows.compactMap { row -> Int64? in
                        let ms = max(row.harvestMs, row.activityChangedMs)
                        return ms > 0 ? ms : nil
                    }
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
        guard !allowTerminalAutomation else { return false }
        return rows.contains { row in
            guard row.focusTier == nil, !row.viaWarp, row.hostApp == nil else { return false }
            var t = row.tty.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("/dev/") { t = String(t.dropFirst(5)) }
            return !t.isEmpty && t != "?" && t != "??" && t != "-"
        }
    }

    /// Full session inventory for the tray search surface. The normal glance
    /// uses `snapshot.rows`; a query must search the bounded 500-row index so a
    /// session hidden behind the twelve-row viewport is still discoverable.
    var allRowsForDisplay: [AgentRow] { cachedAll }

    /// Resolve a row for the detail inspector from the full index, not glance.
    func rowForDetail(rowKey: String) -> AgentRow? {
        cachedAll.first(where: { $0.rowKey == rowKey })
            ?? snapshot.rows.first(where: { $0.rowKey == rowKey })
    }

    /// Localized Limited-data / gap explanation — never a bare "Process only".
    func observationQualitySummary(_ row: AgentRow) -> String {
        if !row.quality.isLimited, row.observationSource == .session {
            return tr(.sessionEvidence)
        }
        guard let gap = row.quality.missing.first else {
            switch row.observationSource {
            case .session: return tr(.sessionEvidence)
            case .cache: return tr(.cacheEvidence)
            case .process:
                return "\(tr(.limitedData)) · \(tr(.qualityNextOpenAgent))"
            case .remote:
                return tr(.remoteEvidence)
            }
        }
        return "\(observationGapReason(gap)) · \(observationGapNextStep(gap))"
    }

    func observationGapReason(_ gap: ObservationGap) -> String {
        switch gap.reason {
        case "privacy_limited": return tr(.supportCollectorPrivacyLimitedDetail)
        case "process_only": return tr(.qualityReasonProcessOnly)
        case "cache_conditional": return tr(.qualityReasonCache)
        case "cache_thin": return tr(.qualityReasonCacheThin)
        case "waiting_no_detail": return tr(.qualityReasonWaitingNoDetail)
        case "waiting_unsupported": return tr(.supportWaitingNoneDetail)
        case "scan_timeout": return tr(.qualityReasonScanTimeout)
        case "remote_event_only": return tr(.remoteEvidence)
        default: return tr(.qualityReasonNotEmitted)
        }
    }

    func observationGapNextStep(_ gap: ObservationGap) -> String {
        switch gap.nextStep {
        case "enable_app_data": return tr(.supportEnableData)
        case "wait_for_vendor_cache": return tr(.qualityNextWaitCache)
        case "use_attention_bridge": return tr(.qualityNextAttentionBridge)
        case "retry_scan": return tr(.qualityNextRetryScan)
        case "open_agent_for_session": return tr(.qualityNextOpenAgent)
        case "wait_for_remote_host": return tr(.remoteNoFocus)
        default: return tr(.qualityNextOpenAgent)
        }
    }

    /// Details lists actionable gaps first so truncation cannot hide the fix.
    func prioritizedObservationGaps(_ gaps: [ObservationGap]) -> [ObservationGap] {
        let actionable: Set<String> = ["use_attention_bridge", "enable_app_data"]
        return gaps.enumerated().sorted { left, right in
            let leftAct = actionable.contains(left.element.nextStep)
            let rightAct = actionable.contains(right.element.nextStep)
            if leftAct != rightAct { return leftAct && !rightAct }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// How deep App Data is currently granted — drives Support Health copy so
    /// a scoped Cursor grant is not described as "scan is off".
    enum AppDataGrantMode: Equatable {
        case all
        case scoped(Int)
        case none
    }

    var appDataGrantMode: AppDataGrantMode {
        if allowAppData { return .all }
        let count = appDataAgents.filter { $0 != .cursorAgent }.count
        return count == 0 ? .none : .scoped(count)
    }

    var privacyLimitedAgents: [AgentSupportHealth] {
        supportHealth.filter(\.privacyLimited)
    }

    var privacyLimitedCount: Int { privacyLimitedAgents.count }

    /// Banner when some protected agents remain privacy-limited.
    var privacyBannerText: String? {
        guard privacyLimitedCount > 0 else { return nil }
        switch appDataGrantMode {
        case .all:
            return nil
        case .none:
            return tr(.supportCollectorPrivacyLimitedDetail)
        case .scoped(let granted):
            return String(
                format: tr(.supportCollectorPrivacyLimitedScoped),
                granted,
                privacyLimitedCount
            )
        }
    }

    var firstPrivacyLimitedAgent: AgentID? {
        privacyLimitedAgents.first?.agent
    }

    /// Incomplete-scan banner: timeout-with-rows is not the same claim as a
    /// blank failure.
    var scanIncompleteBannerText: String? {
        guard collectorScanIncomplete else { return nil }
        let timedOutWithRows = collectorHealthByAgent.values.contains {
            $0.errorKind == "native_timeout" && $0.rowCount > 0
        }
        if timedOutWithRows {
            return tr(.supportScanIncompleteTimeout)
        }
        return tr(.supportScanIncomplete)
    }

    /// Short tray notice sharing the Support incomplete vocabulary.
    var trayScanIncompleteNotice: String? {
        scanIncompleteBannerText
    }

    func confidenceLabel(_ confidence: ObservationConfidence) -> String {
        switch confidence {
        case .high: return tr(.qualityConfidenceHigh)
        case .medium: return tr(.qualityConfidenceMedium)
        case .low: return tr(.qualityConfidenceLow)
        }
    }

    func factKeyLabel(_ key: ObservationFactKey) -> String {
        switch key {
        case .task: return tr(.supportGoal)
        case .workspace: return tr(.supportWorkspace)
        case .action: return tr(.supportAction)
        case .phase: return tr(.detailPhase)
        case .model: return tr(.supportModel)
        case .progress: return tr(.supportProgress)
        case .error: return tr(.detailErrors)
        case .waitingReason: return tr(.supportMissingWaiting)
        case .evidence: return tr(.supportEvidence)
        case .freshness: return tr(.supportLastRead)
        }
    }

    func attentionEvent(for rowKey: String) -> AttentionLedger.Event? {
        attentionLedger.events.last(where: { $0.rowKey == rowKey && $0.isActive })
            ?? attentionLedger.events.last(where: { $0.rowKey == rowKey })
    }

    private func waitingSignalReady(for agent: AgentID) -> Bool {
        switch agent.waitingSource {
        case .hooks:
            if hooksStatus.isInstalled(for: agent) { return true }
            // Codex also has a harvest-pending Waiting path (README matrix).
            if agent == .codex {
                let state = collectorHealthByAgent[agent]?.state ?? .unscanned
                return state == .observed || state == .noRecentData
            }
            return false
        case .harvestPending:
            let state = collectorHealthByAgent[agent]?.state
                ?? (agent == .cursor ? collectorHealthByAgent[.cursorAgent]?.state : nil)
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
        case .remote: return tr(.remoteEvidence)
        case .none: return tr(.supportDetected)
        }
    }

    func supportHealthDetail(_ health: AgentSupportHealth) -> String {
        [
            supportAdapterDetail(health),
            // The outcome sentence rides along so VoiceOver hears the reason a
            // row is empty, not only that it is.
            supportCollectorOutcomeDetail(health),
            supportCoverageDetail(health),
            supportTimelineDetail(health),
            supportMissingDetail(health),
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
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
                lhs.waiting ? 4 : 0,
                lhs.liveProcess ? 2 : 0,
                lhs.harvestMs
            )
            let right = (
                rhs.waiting ? 4 : 0,
                rhs.liveProcess ? 2 : 0,
                rhs.harvestMs
            )
            return left < right
        }) else { return "" }

        var facts: [String] = []
        func nonEmpty(_ raw: String) -> String? {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if let task = row.usefulTask { facts.append(task) }
        if !row.displayPath.isEmpty { facts.append(row.displayPath) }
        if let phase = readablePhase(row.phase, waiting: row.waiting) { facts.append(phase) }
        if let tool = nonEmpty(row.tool) {
            let action = readableAction(tool)
            // Support diagnostics have more room than the tray's default row.
            // Keep generic and previously unknown tools visible as a safe,
            // human-readable last action instead of dropping the only
            // capability signal an adapter emitted. Avoid saying "Testing"
            // twice when the structured phase already supplied that fact.
            if !action.isEmpty,
               !facts.contains(where: { $0.caseInsensitiveCompare(action) == .orderedSame }) {
                facts.append(String(format: tr(.lastAction), action))
            }
        }
        if let model = nonEmpty(row.model) {
            facts.append(String(format: tr(.modelFact), readableModel(model)))
        }
        if let mode = nonEmpty(readableMode(row.mode)) { facts.append(mode) }
        if row.progressTotal > 0 {
            facts.append(String(format: tr(.progressFact), row.progressDone, row.progressTotal))
        } else if row.progressDone > 0 {
            facts.append(String(format: tr(.turnsFact), row.progressDone))
        }
        if row.errors > 0 {
            facts.append(row.errors == 1 ? tr(.errorFactOne) : String(format: tr(.errorsFact), row.errors))
        }
        if row.files > 0 { facts.append(String(format: tr(.filesFact), row.files)) }
        if row.contextPercent > 0 { facts.append(String(format: tr(.contextFact), row.contextPercent)) }
        let tokens = tokenPair(input: row.tokensIn, output: row.tokensOut, scope: .reported)
        if !tokens.isEmpty { facts.append(tokens) }
        // Record count is a collector diagnostic, not execution progress. It
        // belongs in Adapter diagnostics; letting it occupy the observed-fact
        // line made a session with only a transcript look more informative than
        // one with a real action, outcome, or token signal.
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
        let state = harvestSupervisor.state(for: health.agent)
        guard state.lastFailureAtMs > 0, !state.lastError.isEmpty else { return nil }
        let seconds = max(0, Date().timeIntervalSince1970 - Double(state.lastFailureAtMs) / 1000.0)
        return String(
            format: tr(.supportFailureTimelineEntry),
            state.lastError,
            DurationFormat.label(seconds: seconds, lang: lang)
        )
    }
}

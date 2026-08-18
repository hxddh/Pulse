import AppKit
import SwiftUI

/// A focused, evidence-first inspector for one concrete session.
///
/// The tray stays scan-friendly; this surface is where the complete operational
/// picture belongs. Raw tool/skill identifiers are deliberately behind a
/// disclosure so they remain available for debugging without becoming the
/// primary user-facing meaning.
@MainActor
final class AgentDetailWindowController: NSObject, NSWindowDelegate {
    static let shared = AgentDetailWindowController()

    private var window: NSWindow?
    private var hosting: NSHostingController<AgentDetailView>?

    func show(store: StatusStore, row: AgentRow) {
        if let window, let hosting {
            hosting.rootView = AgentDetailView(store: store, rowKey: row.rowKey)
            window.title = "\(row.agent.displayName) · \(store.tr(.details))"
            present(window)
            return
        }
        let host = NSHostingController(rootView: AgentDetailView(store: store, rowKey: row.rowKey))
        let win = NSWindow(contentViewController: host)
        win.title = "\(row.agent.displayName) · \(store.tr(.details))"
        win.identifier = NSUserInterfaceItemIdentifier("pulse-agent-detail")
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 620, height: 560))
        win.contentMinSize = NSSize(width: 520, height: 420)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hosting = host
        window = win
        present(win)
    }

    private func present(_ window: NSWindow) {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        SettingsPresenter.restoreAccessoryIfNeeded()
    }
}

private struct AgentDetailView: View {
    @ObservedObject var store: StatusStore
    let rowKey: String

    private var row: AgentRow? {
        store.rowForDetail(rowKey: rowKey)
    }

    var body: some View {
        Group {
            if let row {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        identity(row)
                        storyCard(row)
                        if row.waiting { waitingCard(row) }
                        if let inbound = store.respondRequest(for: row) {
                            respondCard(row, inbound)
                        }
                        facts(row)
                        evidenceCard(row)
                        qualityCard(row)
                        rawEvidence(row)
                        actions(row)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    store.tr(.noActivityYet),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(store.tr(.supportNoObservedSignals))
                )
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func identity(_ row: AgentRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AgentIconView(id: row.agent)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.usefulTask ?? row.agent.displayName)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .lineLimit(3)
                Text("\(row.agent.displayName) · \(statusLabel(row))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !row.displayPath.isEmpty {
                    Text(row.displayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
    }

    private func storyCard(_ row: AgentRow) -> some View {
        let story = store.rowStoryLine(row)
        let changed = store.rowActivityChange(row)
        return Group {
            if !story.isEmpty || !changed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.tr(.rowStoryHeading))
                        .font(.headline)
                    if !story.isEmpty {
                        Text(story)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !changed.isEmpty, !store.storyOwnsChange(row) {
                        Text(changed)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
    }

    private func waitingCard(_ row: AgentRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(store.tr(.needsYou), systemImage: "bell.badge.fill")
                .font(.headline)
                .foregroundStyle(GlanceKind.waiting.lampColor)
            Text(store.notificationBody(row))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let event = store.attentionEvent(for: row.rowKey) {
                waitingTimeline(event)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(GlanceKind.waiting.lampColor.opacity(0.10))
        )
    }

    /// Respond (scene AR). The full request lives HERE, not in the tray row:
    /// Allow may only appear next to the complete text it would approve —
    /// approving a 200-character summary is the blind approve the invariant
    /// forbids. Deny carries no such requirement.
    private func respondCard(_ row: AgentRow, _ inbound: RespondSpool.InboundRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "\(store.tr(.respondHeading)) · \(inbound.toolName.isEmpty ? row.agent.displayName : inbound.toolName)",
                systemImage: "arrowshape.turn.up.left"
            )
            .font(.headline)
            Text(store.tr(.respondFullRequest))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(inbound.request.fullRequest)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            if store.respondVerdictSent(row) {
                Text(store.tr(.respondSentNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Button(store.tr(.respondDeny)) { store.respondDeny(row) }
                    if inbound.request.canOfferAllow {
                        Button(store.tr(.respondAllow)) { store.respondAllow(row) }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func waitingTimeline(_ event: AttentionLedger.Event) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.tr(.waitingTimeline))
                .font(.caption.weight(.semibold))
                .padding(.top, 4)
            timelineRow(store.tr(.waitingQueuedAt), ms: event.queuedAtMs)
            if event.notifiedAtMs > 0 {
                timelineRow(store.tr(.waitingNotifiedAt), ms: event.notifiedAtMs)
            } else if event.queuedAtMs > 0 {
                Text(store.tr(.waitingNotifyPending))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            timelineRow(store.tr(.waitingAcknowledgedAt), ms: event.acknowledgedAtMs)
            timelineRow(store.tr(.waitingSnoozedUntil), ms: event.snoozedUntilMs)
            timelineRow(store.tr(.waitingResolvedAt), ms: event.resolvedAtMs)
        }
    }

    private func timelineRow(_ label: String, ms: Int64) -> some View {
        Group {
            if ms > 0 {
                Text("\(label) · \(relativeMs(ms))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func relativeMs(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        return date.formatted(.relative(presentation: .named))
    }

    private func qualityCard(_ row: AgentRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.tr(.supportEvidence))
                .font(.headline)
            Text(store.observationQualitySummary(row))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if !row.quality.facts.isEmpty {
                Text(
                    row.quality.facts
                        .map { store.factKeyLabel($0) }
                        .sorted()
                        .joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !row.quality.missing.isEmpty {
                let gaps = store.prioritizedObservationGaps(row.quality.missing)
                ForEach(Array(gaps.prefix(4).enumerated()), id: \.offset) { _, gap in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(store.factKeyLabel(gap.key)): \(store.observationGapReason(gap)) → \(store.observationGapNextStep(gap))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if gap.nextStep == "enable_app_data" {
                            Button(store.tr(.supportEnableData)) {
                                store.openSettings(focusAppDataFor: row.agent)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        } else if gap.nextStep == "use_attention_bridge" {
                            Button(store.tr(.setupWaitingSignals)) {
                                store.openSettings(
                                    focusWaitingSignals: true,
                                    focusWaitingAgent: row.agent
                                )
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
            }
            let health = store.supportHealth.first(where: { $0.agent == row.agent })
            Text("\(store.tr(.supportLastRead)): \(row.quality.freshnessMs > 0 ? relativeMs(row.quality.freshnessMs) : "—") · \(store.confidenceLabel(row.quality.confidence))")
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let health, !health.collectorErrorKind.isEmpty {
                Text(String(format: store.tr(.supportCollectorFailedDetail), health.collectorErrorKind))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let health, health.lastSuccessfulReadMs > 0 {
                Text("\(store.tr(.supportLastRead)): \(relativeMs(health.lastSuccessfulReadMs))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func facts(_ row: AgentRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.tr(.supportHealth))
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                fact(store.tr(.detailPhase), value: store.detailPhase(row))
                fact(store.tr(.lastActive), value: store.lastActivityLabel(row))
                fact(store.tr(.lastAction), value: row.tool.isEmpty ? "—" : store.detailLastAction(row))
                fact(store.tr(.supportModel), value: row.model.isEmpty ? "—" : row.model)
                fact(store.tr(.supportProgress), value: progress(row))
                fact(store.tr(.supportResources), value: resources(row))
                fact(store.tr(.supportEvidence), value: evidence(row))
                // 1.2: what the whole transcript says, not just its two ends.
                // Details is where EXPERIENCE puts complete evidence, so the
                // digest's session-wide facts belong here rather than spending
                // one of the tray row's four slots.
                fact(store.tr(.toolsUsed), value: row.toolSummary.isEmpty ? "—" : row.toolSummary)
                if row.sessionErrors > 0 {
                    fact(
                        store.tr(.sessionErrorsLabel),
                        value: String(format: store.tr(.sessionErrors), row.sessionErrors)
                    )
                }
                if row.isLooping {
                    fact(
                        String(format: store.tr(.loopingTool), row.loopTool, row.loopCount),
                        value: store.tr(.loopingHint)
                    )
                }
                fact(store.tr(.session), value: row.sessionID.isEmpty ? "—" : short(row.sessionID))
            }
        }
    }

    /// 2.1 Evidence — everything the session digest knows and the tray row has
    /// no slot for.
    ///
    /// The four-fact cap on a tray row is not a budget to be negotiated, it is
    /// the reason the row stays scannable. `EXPERIENCE.md` puts *complete
    /// evidence* here instead, and this is that: the walk it took, what the
    /// whole session cost, whether it is still moving, how long it has been
    /// going, and — the honest half — how much of the transcript has actually
    /// been read.
    ///
    /// `@MainActor` is explicit because only `body` gets it implicitly; a
    /// helper reaching into `StatusStore` without it does not compile.
    @MainActor
    private func evidenceCard(_ row: AgentRow) -> some View {
        let timeline = store.evidenceTimeline(row)
        let tokens = store.evidenceSessionTokens(row)
        let length = store.evidenceSessionLength(row)
        let read = store.evidenceReadState(row)
        return Group {
            if store.hasSessionEvidence(row) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.tr(.evidenceHeading))
                        .font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        if !timeline.isEmpty {
                            fact(store.tr(.evidenceTimeline), value: timeline)
                        }
                        if !tokens.isEmpty {
                            fact(store.tr(.evidenceSessionTokens), value: tokens)
                        }
                        // Always present once the card is up: "—" is the
                        // answer when nothing measured the rate, and the note
                        // below says so out loud.
                        fact(store.tr(.evidenceRate), value: store.evidenceRate(row))
                        // Compute sits beside output on purpose: together they
                        // say which of the three states this session is in —
                        // producing, thinking, or stopped.
                        fact(store.tr(.evidenceCPU), value: store.evidenceCPU(row))
                        if let memory = store.evidenceMemory(row) {
                            fact(store.tr(.evidenceMemory), value: memory)
                        }
                        if !length.isEmpty {
                            fact(store.tr(.evidenceSessionLength), value: length)
                        }
                        if !read.isEmpty {
                            fact(store.tr(.evidenceRead), value: read)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if !timeline.isEmpty {
                            note(store.tr(.evidenceTimelineHint))
                        }
                        // Two token numbers on one page disagree unless each
                        // says its scope. 1.1 named this fork and declined to
                        // let either overwrite the other; showing both without
                        // this sentence would have been the worse outcome.
                        if !tokens.isEmpty {
                            note(store.tr(.evidenceSessionTokensHint))
                        }
                        note(store.evidenceRateNote(row))
                        note(store.evidenceCPUNote(row))
                    }
                    // Letting qualitative facts out before the read completes
                    // is this version's choice; saying so is the price of it.
                    if store.evidenceCountsArePartial(row) {
                        Text(store.tr(.evidenceReadPartialHint))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One label/value pair.
    ///
    /// The label column is decoration for VoiceOver — it would otherwise be
    /// read as a standalone element, and the value column would be read as a
    /// bare string with no idea what it measures. An em dash placeholder is
    /// meaningless when spoken, so an absent fact says "unknown" out loud while
    /// still rendering as "—".
    private func fact(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(value.isEmpty || value == "—" ? "—" : value)
                .font(.callout)
                .textSelection(.enabled)
                .accessibilityLabel(label)
                .accessibilityValue(
                    value.isEmpty || value == "—" ? store.tr(.a11yUnknown) : value
                )
        }
    }

    private func rawEvidence(_ row: AgentRow) -> some View {
        DisclosureGroup(store.tr(.supportAdapterDiagnostics)) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(store.tr(.detailTool)): \(row.tool.isEmpty ? "—" : row.tool)")
                Text("\(store.tr(.detailSkill)): \(row.skill.isEmpty ? "—" : row.skill)")
                Text("\(store.tr(.detailPhase)): \(row.phase.isEmpty ? "—" : row.phase)")
                Text("\(store.tr(.detailOutcome)): \(row.outcome.isEmpty ? "—" : row.outcome)")
                Text("\(store.tr(.detailEvidence)): \(row.observationSource.rawValue)")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.top, 6)
        }
        .font(.subheadline)
    }

    private func actions(_ row: AgentRow) -> some View {
        HStack(spacing: 12) {
            if row.canFocusTerminal {
                Button(store.focusActionTitle(row)) { store.focusTerminal(row) }
            }
            if row.waiting {
                Button(store.tr(.dismissWait)) { store.dismissWaiting(row) }
                Button(row.isSnoozed ? store.tr(.snoozed) : store.tr(.snooze)) {
                    row.isSnoozed ? store.unsnooze(row) : store.snooze(row)
                }
            }
            Button(store.tr(.supportHealth)) { store.openSupportHealth() }
        }
        .buttonStyle(.bordered)
    }

    private func statusLabel(_ row: AgentRow) -> String {
        if row.waiting { return store.tr(.needsYou) }
        if row.isStalled { return store.tr(.stalled) }
        if row.isRecentOnly { return store.tr(.recent) }
        return store.tr(.running)
    }

    private func progress(_ row: AgentRow) -> String {
        if row.progressTotal > 0 { return "\(row.progressDone)/\(row.progressTotal)" }
        if row.progressDone > 0 { return "\(row.progressDone)" }
        return row.phase.isEmpty ? "—" : row.phase
    }

    private func resources(_ row: AgentRow) -> String {
        var bits: [String] = []
        if row.tokensIn > 0 || row.tokensOut > 0 { bits.append("↑\(AgentRow.compactToken(row.tokensIn)) ↓\(AgentRow.compactToken(row.tokensOut))") }
        if row.files > 0 { bits.append("\(row.files) \(store.tr(.detailFiles))") }
        if row.errors > 0 { bits.append("\(row.errors) \(store.tr(.detailErrors))") }
        if row.contextPercent > 0 { bits.append("\(store.tr(.detailContext)) \(row.contextPercent)%") }
        return bits.isEmpty ? "—" : bits.joined(separator: " · ")
    }

    private func evidence(_ row: AgentRow) -> String {
        switch row.observationSource {
        case .session: return store.tr(.supportStructured)
        case .cache: return store.tr(.supportCache)
        case .process: return store.tr(.supportProcess)
        case .remote: return store.tr(.remoteEvidence)
        }
    }

    private func short(_ raw: String) -> String {
        raw.count <= 28 ? raw : String(raw.prefix(12)) + "…" + String(raw.suffix(10))
    }
}

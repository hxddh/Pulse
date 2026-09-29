import SwiftUI

// 21.0 Clarity: what the Details window held that the Workbench inspector did
// not — the Why card with its hook history, the waiting timeline, and how
// Pulse reads the session. The Details window was a third inspector for one
// row (tray card, Details, Workbench), with its own Respond card; it is gone
// and these two cards live in the Workbench.

/// The store-bound owner of the Why card: builds the value, carries out the
/// export, remembers what the export did.
struct WhyDetailSection: View {
    var store: StatusStore
    let row: AgentRow
    @State private var notice = ""

    var body: some View {
        let model = store.whyCard(row)
        if !model.isEmpty {
            WhyCardView(model: model, send: { intent in
                switch intent {
                case .export:
                    let count = store.copyAttentionFixture(row)
                    notice = String(format: store.tr(.whyExported), count)
                }
            }, notice: notice)
        }
    }
}

/// How Pulse sees this session: the evidence it has, what it is missing and
/// why, when it last read, the waiting timeline, and the raw identifiers —
/// folded, because it answers "why does the row say that", not "what is it
/// doing".
struct SessionDiagnosticsCard: View {
    var store: StatusStore
    let row: AgentRow
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: PulseTheme.Space.s) {
                Text(store.observationQualitySummary(row))
                    .font(PulseTheme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.quality.facts.isEmpty {
                    Text(row.quality.facts.map { store.factKeyLabel($0) }.sorted().joined(separator: " · "))
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(store.prioritizedObservationGaps(row.quality.missing).prefix(4).enumerated()), id: \.offset) { _, gap in
                    HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.s) {
                        Text("\(store.factKeyLabel(gap.key)): \(store.observationGapReason(gap)) → \(store.observationGapNextStep(gap))")
                            .font(PulseTheme.Font.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if gap.nextStep == "enable_app_data" {
                            Button(store.tr(.supportEnableData)) {
                                store.openSettings(focusAppDataFor: row.agent)
                            }
                            .buttonStyle(.link)
                        } else if gap.nextStep == "use_attention_bridge" {
                            Button(store.tr(.setupWaitingSignals)) {
                                store.openSettings(focusWaitingSignals: true, focusWaitingAgent: row.agent)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                Text("\(store.tr(.supportLastRead)): \(row.quality.freshnessMs > 0 ? relative(row.quality.freshnessMs) : "—") · \(store.confidenceLabel(row.quality.confidence))")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                if let health = store.supportHealth.first(where: { $0.agent == row.agent }),
                   !health.collectorErrorKind.isEmpty {
                    Text(String(format: store.tr(.supportCollectorFailedDetail), health.collectorErrorKind))
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(PulseTheme.Tone.attention.color)
                }
                if row.waiting, let event = store.attentionEvent(for: row.rowKey) {
                    timeline(event)
                }
                VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                    Text("\(store.tr(.detailTool)): \(row.tool.isEmpty ? "—" : row.tool)")
                    Text("\(store.tr(.detailSkill)): \(row.skill.isEmpty ? "—" : row.skill)")
                    Text("\(store.tr(.detailPhase)): \(row.phase.isEmpty ? "—" : row.phase)")
                    Text("\(store.tr(.detailOutcome)): \(row.outcome.isEmpty ? "—" : row.outcome)")
                    Text("\(store.tr(.detailEvidence)): \(row.observationSource.rawValue)")
                    if !row.sessionID.isEmpty { Text("session: \(row.sessionID)") }
                }
                .font(PulseTheme.Font.code)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .padding(.top, PulseTheme.Space.s)
        } label: {
            Text(store.tr(.inspectorHowPulseSees))
                .font(PulseTheme.Font.heading)
        }
        .pulseCard()
    }

    private func timeline(_ event: AttentionLedger.Event) -> some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
            Text(store.tr(.waitingTimeline))
                .font(PulseTheme.Font.bodyEmphasis)
            line(store.tr(.waitingQueuedAt), ms: event.queuedAtMs)
            if event.notifiedAtMs > 0 {
                line(store.tr(.waitingNotifiedAt), ms: event.notifiedAtMs)
            } else if event.queuedAtMs > 0 {
                Text(store.tr(.waitingNotifyPending))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            line(store.tr(.waitingAcknowledgedAt), ms: event.acknowledgedAtMs)
            line(store.tr(.waitingSnoozedUntil), ms: event.snoozedUntilMs)
            line(store.tr(.waitingResolvedAt), ms: event.resolvedAtMs)
        }
    }

    @ViewBuilder
    private func line(_ label: String, ms: Int64) -> some View {
        if ms > 0 {
            Text("\(label) · \(relative(ms))")
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func relative(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000.0).formatted(.relative(presentation: .named))
    }
}

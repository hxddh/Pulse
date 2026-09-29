import SwiftUI

// 21.0 Clarity: the Why card and how Pulse reads the session, shown in the
// row's detail view (22.0). 23.0: the Why card reads the session log; the
// waiting timeline that repeated the notification audit is gone.

/// The store-bound owner of the Why card: builds the value.
struct WhyDetailSection: View {
    var store: StatusStore
    let row: AgentRow

    var body: some View {
        let model = store.whyCard(row)
        if !model.isEmpty {
            WhyCardView(model: model)
        }
    }
}

/// How Pulse sees this session: the evidence it has, what it is missing and
/// why, when it last read, and the raw identifiers —
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
                                store.openSettings(focusWaitingSignals: true)
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
                VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                    Text("\(store.tr(.detailTool)): \(row.tool.isEmpty ? "—" : row.tool)")
                    Text("\(store.tr(.detailSkill)): \(row.skill.isEmpty ? "—" : row.skill)")
                    Text("\(store.tr(.detailPhase)): \(row.phase.isEmpty ? "—" : row.phase)")
                    Text("\(store.tr(.detailOutcome)): \(row.outcome.isEmpty ? "—" : row.outcome)")
                    Text("\(store.tr(.detailEvidence)): \(row.observationSource.rawValue)")
                    if !row.sessionID.isEmpty { Text("\(store.tr(.session)): \(row.sessionID)") }
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

    private func relative(_ ms: Int64) -> String {
        Self.relativeText(ms: ms, now: Date(), lang: store.lang)
    }

    /// Pure: a relative time in the app's language, not the system's — a
    /// Chinese Pulse on an English Mac said "5 minutes ago".
    static func relativeText(ms: Int64, now: Date, lang: ResolvedLanguage) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: lang == .zh ? "zh-Hans" : "en")
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: Double(ms) / 1000.0),
            relativeTo: now
        )
    }
}

// 3.0-α: the support-health scene, moved verbatim out of PulseApp.swift.

import SwiftUI
import AppKit

@MainActor
struct SupportCoverageView: View {
    var store: StatusStore
    @State private var query = ""
    // Support coverage is an inspection surface, not an alert inbox. Starting
    // on Observed keeps the first scan useful while “All” remains the explicit
    // path for auditing every covered adapter, including missing local sources.
    // The full roster is the product contract. Start on All so an adapter
    // without local evidence is visible with a concrete reason instead of
    // disappearing behind an Observed-only filter.
    @State private var filter: SupportFilter = .all
    @State private var showSafeReport = false
    @State private var activityAgent: AgentID?

    enum SupportFilter: String, CaseIterable, Identifiable {
        case needsAction
        case limited
        case available
        case notInstalled
        case noRecentSession
        case permissionDenied
        case unscanned
        case all

        var id: String { rawValue }
    }

    private var filtered: [AgentSupportHealth] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.supportHealth
            .filter { item in
                switch filter {
                case .needsAction: return item.disposition == .needsAction
                case .limited: return item.disposition == .limited
                case .available: return item.disposition == .available
                case .notInstalled: return item.disposition == .notInstalled
                case .noRecentSession: return item.disposition == .noRecentSession
                case .permissionDenied: return item.disposition == .permissionDenied
                case .unscanned: return item.disposition == .unscanned
                case .all:
                    return true
                }
            }
            .filter {
                text.isEmpty
                    || $0.agent.displayName.localizedCaseInsensitiveContains(text)
                    || store.supportEvidenceLabel($0).localizedCaseInsensitiveContains(text)
                    || store.supportHealthDetail($0).localizedCaseInsensitiveContains(text)
            }
            .sorted {
                let left = severity($0.disposition)
                let right = severity($1.disposition)
                if left != right { return left > right }
                let lp = AgentID.priority.firstIndex(of: $0.agent) ?? 999
                let rp = AgentID.priority.firstIndex(of: $1.agent) ?? 999
                return lp < rp
            }
    }

    private func severity(_ disposition: SupportDisposition) -> Int {
        switch disposition {
        case .needsAction: return 7
        case .permissionDenied: return 6
        case .limited: return 5
        case .unscanned: return 4
        case .noRecentSession: return 3
        case .notInstalled: return 2
        case .available: return 1
        }
    }

    private func filterLabel(_ filter: SupportFilter) -> String {
        switch filter {
        case .needsAction:
            return String(format: store.tr(.supportNeedsActionCount), needsActionCount)
        case .limited:
            return String(format: store.tr(.supportLimitedCount), limitedCount)
        case .available:
            return String(format: store.tr(.supportAvailableCount), availableCount)
        case .notInstalled:
            return String(format: store.tr(.supportNotInstalledCount), notInstalledCount)
        case .noRecentSession:
            return String(format: store.tr(.supportNoRecentCount), noRecentCount)
        case .permissionDenied:
            return String(format: store.tr(.supportPermissionDeniedCount), permissionDeniedCount)
        case .unscanned:
            return String(format: store.tr(.supportUnscannedCount), unscannedCount)
        case .all: return store.tr(.supportFilterAll)
        }
    }

    private var needsActionCount: Int {
        store.supportHealth.filter { $0.disposition == .needsAction }.count
    }
    private var limitedCount: Int {
        store.supportHealth.filter { $0.disposition == .limited }.count
    }
    private var availableCount: Int {
        store.supportHealth.filter { $0.disposition == .available }.count
    }
    private var notInstalledCount: Int {
        store.supportHealth.filter { $0.disposition == .notInstalled }.count
    }
    private var noRecentCount: Int {
        store.supportHealth.filter { $0.disposition == .noRecentSession }.count
    }
    private var permissionDeniedCount: Int {
        store.supportHealth.filter { $0.disposition == .permissionDenied }.count
    }
    private var unscannedCount: Int {
        store.supportHealth.filter { $0.disposition == .unscanned }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: PulseTheme.Space.m) {
                    header
                    selfCheck
                    // 22.0: what happened, across sessions — state changes
                    // and what became of each banner.
                    ActivityLogView(
                        model: store.activityLog(agent: activityAgent),
                        lang: store.lang,
                        agents: store.activityAgents,
                        filter: $activityAgent
                    )
                    .pulseCard()
                    banners
                    HStack(spacing: PulseTheme.Space.s) {
                        Text(store.tr(.healthAgentsHeading))
                            .font(PulseTheme.Font.heading)
                        Spacer(minLength: PulseTheme.Space.s)
                        Picker("", selection: $filter) {
                            ForEach(SupportFilter.allCases) {
                                Text(filterLabel($0)).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                    }
                    Text(summaryLine)
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if showSafeReport { safeReport }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { item in
                            SupportHealthRow(item: item, store: store)
                                .padding(.vertical, PulseTheme.Space.s + 2)
                            if item.id != filtered.last?.id {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                    .overlay {
                        if filtered.isEmpty {
                            ContentUnavailableView(
                                store.tr(.supportNoFilterResults),
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                        }
                    }
                }
                .padding(PulseTheme.Space.xl)
            }
        }
        .frame(minWidth: 580, minHeight: 320)
        .searchable(text: $query, prompt: store.tr(.supportSearch))
    }

    /// Title, what was last read and when, and the one report to copy.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.m) {
            VStack(alignment: .leading, spacing: PulseTheme.Space.xs) {
                Text(store.tr(.healthTitle))
                    .font(PulseTheme.Font.title)
                // 21.0: when Pulse last read, how often, what it cost —
                // until now only in the clipboard dump.
                Text(store.scanHealthLine)
                    .font(PulseTheme.Font.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: PulseTheme.Space.s)
            Menu {
                Button(store.diagnostics.didCopyDiagnostics ? store.tr(.copied) : store.tr(.copyDiagnostics)) {
                    store.copyDiagnostics()
                }
                Button(store.tr(.supportCopySafeReport)) { store.copySafeSupportReport() }
                Button(store.tr(.exportSafeReport)) { store.exportSafeSupportReport() }
                Button(shapeButtonTitle) { store.copyHarvestShapeReport() }
                    .disabled(store.diagnostics.isCopyingShapeReport)
                Divider()
                Button(showSafeReport ? store.tr(.healthHideReport) : store.tr(.healthShowReport)) {
                    showSafeReport.toggle()
                }
            } label: {
                Label(store.tr(.healthReport), systemImage: "doc.on.clipboard")
            }
            .fixedSize()
            Button(store.tr(.supportRetry)) { store.refresh(reason: "health-refresh") }
                .disabled(store.isRefreshing)
        }
    }

    /// The self-check first: what this Mac can prove about the contracts
    /// Pulse depends on, with the fix beside each finding.
    private var selfCheck: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.s) {
            HStack(spacing: PulseTheme.Space.s) {
                Text(store.tr(.doctorRun))
                    .font(PulseTheme.Font.heading)
                if store.diagnostics.isRunningDoctor { ProgressView().controlSize(.small) }
                Spacer(minLength: PulseTheme.Space.s)
                Button(store.diagnostics.doctorReport == nil ? store.tr(.healthRunCheck) : store.tr(.healthRunAgain)) {
                    store.runDoctor()
                }
                .disabled(store.diagnostics.isRunningDoctor)
            }
            if let report = store.diagnostics.doctorReport {
                DoctorReportView(
                    report: report,
                    copied: store.diagnostics.didCopyDoctorReport,
                    onCopy: { store.copyDoctorReport() },
                    onFix: { store.performDoctorFix($0) }
                )
            } else {
                Text(store.tr(.doctorHint))
                    .font(PulseTheme.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pulseCard()
    }

    @ViewBuilder
    private var banners: some View {
        if let privacy = store.privacyBannerText {
            HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.s) {
                Label(privacy, systemImage: "lock")
                    .foregroundStyle(PulseTheme.Tone.attention.color)
                Spacer(minLength: PulseTheme.Space.s)
                Button(store.tr(.settings)) {
                    store.openSettings(focus: .appData)
                }
            }
            .font(PulseTheme.Font.body)
        }
        if let incomplete = store.scanIncompleteBannerText {
            HStack(spacing: PulseTheme.Space.s) {
                Label(incomplete, systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(PulseTheme.Tone.attention.color)
                Spacer(minLength: PulseTheme.Space.s)
                Button(store.tr(.supportRetry)) {
                    store.refresh(reason: "support-retry")
                }
            }
            .font(PulseTheme.Font.body)
        }
    }

    private var safeReport: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.s) {
            ScrollView {
                Text(store.safeSupportReport())
                    .font(PulseTheme.Font.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .pulseInner()
            Text(store.tr(.supportShapeHint))
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shapeButtonTitle: String {
        if store.diagnostics.isCopyingShapeReport { return store.tr(.supportShapeReading) }
        return store.diagnostics.didCopyShapeReport ? store.tr(.copied) : store.tr(.supportCopyShapeReport)
    }

    private var summaryLine: String {
        // One sentence, one table entry. It was two inline literals switched on
        // `store.lang`, which is the one thing EXPERIENCE §4 forbids for
        // user-facing copy: the translation drifts where nobody is looking.
        String(
            format: store.tr(.supportSummaryLine),
            availableCount,
            needsActionCount,
            limitedCount,
            notInstalledCount,
            noRecentCount,
            permissionDeniedCount,
            unscannedCount
        )
    }
}

@MainActor
struct SupportHealthRow: View {
    let item: AgentSupportHealth
    var store: StatusStore
    @State private var diagnosticsExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: PulseTheme.Space.s) {
            AgentIconView(id: item.agent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: PulseTheme.Space.xs) {
                HStack(spacing: PulseTheme.Space.s) {
                    Text(item.agent.displayName)
                        .font(PulseTheme.Font.hero)
                    PulseChip(label: dispositionLabel, tone: tone)
                    Text(store.supportEvidenceLabel(item))
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                }
                // 2.9 / 21.0: declared vs measured. Drift is the difference
                // between "the agent is idle" and "Pulse stopped seeing"; it
                // was four clicks deep inside a disclosure.
                if item.looksDrifted {
                    Label(store.supportYieldDetail(item), systemImage: "exclamationmark.triangle")
                        .font(PulseTheme.Font.body)
                        .foregroundStyle(PulseTheme.Tone.attention.color)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(store.supportFocusDetail(item))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)

                Text(store.supportDepthDetail(item))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)

                if item.isObserved {
                    HStack(spacing: 6) {
                        SupportFactPill(
                            label: store.tr(.supportGoal),
                            present: item.hasGoal,
                            store: store
                        )
                        SupportFactPill(
                            label: store.tr(.supportWorkspace),
                            present: item.hasWorkspace,
                            store: store
                        )
                        SupportFactPill(
                            label: store.tr(.supportActivity),
                            present: item.hasActivity,
                            store: store
                        )
                        SupportFactPill(
                            label: store.tr(.supportProgress),
                            present: item.hasProgress,
                            store: store
                        )
                        Text(String(
                            format: store.tr(.supportUsefulCoverage),
                            item.usefulFactCount,
                            item.usefulFactTotal
                        ))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                    .font(PulseTheme.Font.caption)

                    HStack(spacing: 6) {
                        SupportFactPill(
                            label: store.tr(.supportAction),
                            present: item.hasActionSignal,
                            store: store
                        )
                        SupportFactPill(
                            label: store.tr(.supportModel),
                            present: item.hasModelSignal,
                            store: store
                        )
                        SupportFactPill(
                            label: store.tr(.supportResources),
                            present: item.hasResourceSignal,
                            store: store
                        )
                    }
                    .font(PulseTheme.Font.caption)

                    let observed = store.supportObservedDetail(item)
                    Text(observed.isEmpty ? store.tr(.supportNoObservedSignals) : observed)
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                } else if item.privacyLimited
                    || item.disposition == .limited
                    || item.disposition == .unscanned
                    || item.disposition == .permissionDenied
                {
                    // Capability gaps stay visible when the adapter has not
                    // produced a row — otherwise Support Health collapses to
                    // disposition labels alone.
                    HStack(spacing: 6) {
                        SupportFactPill(label: store.tr(.supportGoal), present: false, store: store)
                        SupportFactPill(label: store.tr(.supportWorkspace), present: false, store: store)
                        SupportFactPill(label: store.tr(.supportActivity), present: false, store: store)
                        SupportFactPill(label: store.tr(.supportProgress), present: false, store: store)
                    }
                    .font(PulseTheme.Font.caption)
                }

                let timeline = store.supportTimelineDetail(item)
                if !timeline.isEmpty {
                    Text(timeline)
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if item.collectorErrorKind == "native_timeout" {
                    Label(store.tr(.qualityReasonScanTimeout), systemImage: "clock")
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(PulseTheme.Tone.attention.color)
                }

                if let missing = store.supportMissingDetail(item) {
                    Label(missing, systemImage: "info.circle")
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(PulseTheme.Tone.attention.color)
                }

                if item.repair != .none {
                    Button(repairLabel) {
                        switch item.repair {
                        case .installHooks: store.installHooks()
                        case .retry: store.refresh(reason: "support-retry")
                        case .openSettings: store.openSettings(focus: .appData)
                        case .runAgent: store.focusAgent(idRaw: item.agent.rawValue)
                        case .openAttentionBridge:
                            store.openSettings(focus: .waitingSignals)
                        case .none: break
                        }
                    }
                    .buttonStyle(.link)
                    .font(PulseTheme.Font.caption)
                }

                // `repair` is the actionable primary path. Privacy-limited and
                // retryable rows used to render the same action a second time
                // through `nextActionLabel`, which made Support Health read as
                // duplicated and visually noisy. Keep one action per row; the
                // detail/diagnostics disclosure still carries the full reason.
                if item.repair == .none, let action = nextActionLabel {
                    if item.privacyLimited {
                        Button(action) { store.openSettings(focus: .appData) }
                            .buttonStyle(.link)
                            .font(PulseTheme.Font.caption)
                    } else if [.failed, .permissionDenied, .schemaMismatch, .unscanned].contains(item.collectorState) {
                        Button(action) { store.refresh(reason: "support-retry-\(item.agent.rawValue)") }
                            .buttonStyle(.link)
                            .font(PulseTheme.Font.caption)
                    } else if item.agent.harvestSource == .bestEffortCache,
                              item.evidence == .cache || item.evidence == .process {
                        Label(action, systemImage: "arrow.right.circle")
                            .font(PulseTheme.Font.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label(action, systemImage: "arrow.right.circle")
                            .font(PulseTheme.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let failure = store.supportFailureTimelineDetail(item) {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(PulseTheme.Tone.attention.color)
                }

                DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.supportAdapterDetail(item))
                            .font(PulseTheme.Font.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // How the adapter got there. Collected since 1.2 and
                        // until now only written to debug.log, which left "why
                        // is this row empty" answerable only from a terminal.
                        let reading = store.supportReadingDetail(item)
                        if !reading.isEmpty {
                            Text(reading)
                                .font(PulseTheme.Font.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        let outcome = store.supportCollectorOutcomeDetail(item)
                        if !outcome.isEmpty {
                            Text(outcome)
                                .font(PulseTheme.Font.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // 2.9: declared vs measured. Drift is the one line
                        // here that must not whisper — it is the difference
                        // between "the agent is idle" and "Pulse stopped
                        // seeing", and it was invisible until now.
                        let yield = store.supportYieldDetail(item)
                        if !yield.isEmpty, !item.looksDrifted {
                            Text(yield)
                                .font(PulseTheme.Font.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)
                } label: {
                    Text(store.tr(.supportAdapterDiagnostics))
                }
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.agent.displayName), \(store.supportEvidenceLabel(item)), "
                + store.supportHealthDetail(item)
        )
    }

    /// 21.0: the product's tones, not a palette of its own — no purple,
    /// no second red. Red is for a blocked agent, so nothing here is red.
    private var tone: PulseTheme.Tone {
        switch item.disposition {
        case .needsAction, .limited, .permissionDenied: return .attention
        case .available: return .running
        case .notInstalled, .noRecentSession, .unscanned: return .idle
        }
    }

    private var dispositionLabel: String {
        switch item.disposition {
        case .needsAction: return store.tr(.supportNeedsAction)
        case .limited: return store.tr(.supportLimited)
        case .available: return store.tr(.supportAvailable)
        case .notInstalled: return store.tr(.supportNotInstalled)
        case .noRecentSession: return store.tr(.supportNoRecentSession)
        case .permissionDenied: return store.tr(.supportPermissionDenied)
        case .unscanned: return store.tr(.supportUnscanned)
        }
    }

    private var repairLabel: String {
        switch item.repair {
        case .installHooks: return store.tr(.installHooks)
        case .retry: return store.tr(.supportRetry)
        case .openSettings: return store.tr(.supportEnableData)
        case .runAgent: return store.tr(.supportRunAgent)
        case .openAttentionBridge: return store.tr(.setupWaitingSignals)
        case .none: return ""
        }
    }

    private var nextActionLabel: String? {
        if item.privacyLimited { return store.tr(.supportEnableData) }
        switch item.collectorState {
        case .failed, .schemaMismatch, .unscanned:
            return store.tr(.supportRetry)
        case .permissionDenied:
            return store.tr(.supportEnableData)
        case .sourceAbsent, .noSessions, .noRecentData:
            return item.isObserved ? nil : store.tr(.supportRunAgent)
        case .observed:
            if item.agent.harvestSource == .bestEffortCache,
               item.disposition == .limited,
               !item.privacyLimited {
                return store.tr(.qualityNextWaitCache)
            }
            return nil
        }
    }
}

private struct SupportFactPill: View {
    let label: String
    let present: Bool
    var store: StatusStore

    var body: some View {
        Label(
            label,
            systemImage: present ? "checkmark.circle.fill" : "circle"
        )
        .foregroundStyle(present ? Color.secondary : Color.secondary.opacity(0.5))
        .labelStyle(.titleAndIcon)
        // Presence was carried by the glyph and a 50% opacity drop alone, so
        // VoiceOver read "Goal" identically whether the fact was there or not
        // — the one thing the pill exists to say.
        .accessibilityLabel(label)
        .accessibilityValue(present ? store.tr(.a11yPresent) : store.tr(.a11yUnknown))
    }
}

/// 22.0: the Activity log — renders a value; the filter is the only state.
struct ActivityLogView: View {
    let model: ActivityLogModel
    let lang: ResolvedLanguage
    var agents: [AgentID] = []
    @Binding var filter: AgentID?

    private func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.s) {
            HStack {
                Text(t(.activityHeading))
                    .font(PulseTheme.Font.heading)
                Spacer(minLength: PulseTheme.Space.s)
                if !agents.isEmpty {
                    Picker("", selection: $filter) {
                        Text(t(.activityAllAgents)).tag(AgentID?.none)
                        ForEach(agents, id: \.self) { agent in
                            Text(agent.displayName).tag(AgentID?.some(agent))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if model.entries.isEmpty {
                Text(t(.activityEmpty))
                    .font(PulseTheme.Font.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.s) {
                        Text(entry.clock)
                            .font(PulseTheme.Font.code)
                            .foregroundStyle(.secondary)
                        Circle()
                            .fill(entry.tone == .idle ? Color.secondary : entry.tone.color)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.text)
                                .font(PulseTheme.Font.body)
                            let who = [entry.agent?.displayName ?? "", entry.place].filter { !$0.isEmpty }.joined(separator: " · ")
                            if !who.isEmpty {
                                Text(who)
                                    .font(PulseTheme.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}


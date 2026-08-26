// 3.0-α: the support-health scene, moved verbatim out of PulseApp.swift.

import SwiftUI
import AppKit

@MainActor
struct SupportCoverageView: View {
    @ObservedObject var store: StatusStore
    @State private var query = ""
    // Support coverage is an inspection surface, not an alert inbox. Starting
    // on Observed keeps the first scan useful while “All” remains the explicit
    // path for auditing every covered adapter, including missing local sources.
    // The full roster is the product contract. Start on All so an adapter
    // without local evidence is visible with a concrete reason instead of
    // disappearing behind an Observed-only filter.
    @State private var filter: SupportFilter = .all
    @State private var showSafeReport = false

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
            VStack(alignment: .leading, spacing: 8) {
                Text(store.tr(.supportHealth))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(store.tr(.supportHealthHint))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let privacy = store.privacyBannerText {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(
                            privacy,
                            systemImage: "lock"
                        )
                        .foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        Button(store.tr(.settings)) {
                            store.openSettings(focusAppDataFor: store.firstPrivacyLimitedAgent)
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
                if let incomplete = store.scanIncompleteBannerText {
                    HStack(spacing: 8) {
                        Label(incomplete, systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        Button(store.tr(.supportRetry)) {
                            store.refresh(reason: "support-retry")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
                HStack(spacing: 12) {
                    Label(
                        String(format: store.tr(.supportNeedsActionCount), needsActionCount),
                        systemImage: "exclamationmark.triangle"
                    )
                    Label(
                        String(format: store.tr(.supportLimitedCount), limitedCount),
                        systemImage: "info.circle"
                    )
                    Label(
                        String(format: store.tr(.supportAvailableCount), availableCount),
                        systemImage: "checkmark.circle"
                    )
                    Label(
                        String(format: store.tr(.supportNotInstalledCount), notInstalledCount),
                        systemImage: "square.dashed"
                    )
                    Label(
                        String(format: store.tr(.supportPermissionDeniedCount), permissionDeniedCount),
                        systemImage: "lock"
                    )
                    Spacer()
                    Button(store.tr(.supportSafeReport)) { showSafeReport.toggle() }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $filter) {
                    ForEach(SupportFilter.allCases) {
                        Text(filterLabel($0)).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240, alignment: .leading)
                .labelsHidden()
                if showSafeReport {
                    VStack(alignment: .trailing, spacing: 6) {
                        ScrollView {
                            Text(store.safeSupportReport())
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 108)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.primary.opacity(0.045))
                        )
                        HStack(spacing: 10) {
                            Button(store.tr(.exportSafeReport)) { store.exportSafeSupportReport() }
                            Button(
                                store.didCopyDiagnostics ? store.tr(.copied) : store.tr(.supportCopySafeReport)
                            ) { store.copySafeSupportReport() }
                        }
                        // The one diagnostic that used to need a terminal.
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(store.tr(.supportShapeHint))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(shapeButtonTitle) { store.copyHarvestShapeReport() }
                                .disabled(store.isCopyingShapeReport)
                                .accessibilityLabel(store.tr(.supportCopyShapeReport))
                                .accessibilityValue(store.tr(.supportShapeHint))
                        }
                    }
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { item in
                        SupportHealthRow(item: item, store: store)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                        if item.id != filtered.last?.id {
                            Divider().padding(.leading, 54)
                        }
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
        .frame(minWidth: 580, minHeight: 280)
        .background(Color(nsColor: .windowBackgroundColor))
        .searchable(text: $query, prompt: store.tr(.supportSearch))
    }

    private var shapeButtonTitle: String {
        if store.isCopyingShapeReport { return store.tr(.supportShapeReading) }
        return store.didCopyShapeReport ? store.tr(.copied) : store.tr(.supportCopyShapeReport)
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
    @ObservedObject var store: StatusStore
    @State private var diagnosticsExpanded = true

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
                .accessibilityHidden(true)
            AgentIconView(id: item.agent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.agent.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(dispositionLabel)
                        .font(.caption)
                        .foregroundStyle(statusLabelColor)
                    Text(store.supportEvidenceLabel(item))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(store.supportFocusDetail(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(store.supportDepthDetail(item))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

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
                    .font(.caption)

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
                    .font(.caption)

                    let observed = store.supportObservedDetail(item)
                    Text(observed.isEmpty ? store.tr(.supportNoObservedSignals) : observed)
                        .font(.caption)
                        .foregroundStyle(observed.isEmpty ? .tertiary : .secondary)
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
                    .font(.caption)
                }

                let timeline = store.supportTimelineDetail(item)
                if !timeline.isEmpty {
                    Text(timeline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if item.collectorErrorKind == "native_timeout" {
                    Label(store.tr(.qualityReasonScanTimeout), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let missing = store.supportMissingDetail(item) {
                    Label(missing, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if item.repair != .none {
                    Button(repairLabel) {
                        switch item.repair {
                        case .installHooks: store.installHooks()
                        case .retry: store.refresh(reason: "support-retry")
                        case .openSettings: store.openSettings(focusAppDataFor: item.agent)
                        case .runAgent: store.focusAgent(idRaw: item.agent.rawValue)
                        case .openAttentionBridge:
                            store.openSettings(
                                focusWaitingSignals: true,
                                focusWaitingAgent: item.agent
                            )
                        case .none: break
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                // `repair` is the actionable primary path. Privacy-limited and
                // retryable rows used to render the same action a second time
                // through `nextActionLabel`, which made Support Health read as
                // duplicated and visually noisy. Keep one action per row; the
                // detail/diagnostics disclosure still carries the full reason.
                if item.repair == .none, let action = nextActionLabel {
                    if item.privacyLimited {
                        Button(action) { store.openSettings(focusAppDataFor: item.agent) }
                            .buttonStyle(.link)
                            .font(.caption)
                    } else if [.failed, .permissionDenied, .schemaMismatch, .unscanned].contains(item.collectorState) {
                        Button(action) { store.refresh(reason: "support-retry-\(item.agent.rawValue)") }
                            .buttonStyle(.link)
                            .font(.caption)
                    } else if item.agent.harvestSource == .bestEffortCache,
                              item.evidence == .cache || item.evidence == .process {
                        Label(action, systemImage: "arrow.right.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label(action, systemImage: "arrow.right.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let failure = store.supportFailureTimelineDetail(item) {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.supportAdapterDetail(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // How the adapter got there. Collected since 1.2 and
                        // until now only written to debug.log, which left "why
                        // is this row empty" answerable only from a terminal.
                        let reading = store.supportReadingDetail(item)
                        if !reading.isEmpty {
                            Text(reading)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        let outcome = store.supportCollectorOutcomeDetail(item)
                        if !outcome.isEmpty {
                            Text(outcome)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // 2.9: declared vs measured. Drift is the one line
                        // here that must not whisper — it is the difference
                        // between "the agent is idle" and "Pulse stopped
                        // seeing", and it was invisible until now.
                        let yield = store.supportYieldDetail(item)
                        if !yield.isEmpty {
                            Text(yield)
                                .font(.caption2)
                                .foregroundStyle(item.looksDrifted ? Color.orange : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)
                } label: {
                    Text(store.tr(.supportAdapterDiagnostics))
                }
                .font(.caption)
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

    private var statusLabelColor: Color {
        switch item.disposition {
        case .needsAction: return .red
        case .limited: return .orange
        case .available: return GlanceKind.running.lampColor
        case .notInstalled, .noRecentSession, .unscanned: return .secondary.opacity(0.65)
        case .permissionDenied: return .purple
        }
    }

    private var statusColor: Color {
        switch item.disposition {
        case .needsAction: return .red
        case .limited: return .orange
        case .available: return GlanceKind.running.lampColor
        case .notInstalled, .noRecentSession, .unscanned: return .gray
        case .permissionDenied: return .purple
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
    @ObservedObject var store: StatusStore

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

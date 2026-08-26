// 3.0-β Mission Control — the workbench scene.
//
// The rule split that makes this window possible (EXPERIENCE §Workbench):
// "counts and short names only" is the law of the tray and of anything that
// crosses machines — it was never meant to be the law of the product. This
// window shows the user's own sessions on the user's own machine: local,
// read-only, sanitized where the text is an agent's self-report, and nothing
// here ever leaves the machine. The tray keeps every rule it had.

import SwiftUI
import AppKit

@MainActor
struct WorkbenchView: View {
    @ObservedObject var store: StatusStore
    @State private var selectedKey: String?

    private var rows: [AgentRow] { store.allRows }

    private var selectedRow: AgentRow? {
        rows.first { $0.rowKey == selectedKey }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            if let row = selectedRow {
                SessionInspectorView(store: store, row: row)
                    .id(row.rowKey)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if selectedKey == nil {
                // Open on whoever needs the user first — the tray's own
                // priority, carried over.
                selectedKey = rows.first(where: \.waiting)?.rowKey ?? rows.first?.rowKey
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedKey) {
            ForEach(TraySection.allCases, id: \.self) { section in
                let sectionRows = rows.filter { $0.section == section }
                if !sectionRows.isEmpty {
                    Section(store.tr(section.titleKey)) {
                        ForEach(sectionRows, id: \.rowKey) { row in
                            WorkbenchSidebarRow(store: store, row: row)
                                .tag(row.rowKey)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(rows.isEmpty ? store.tr(.workbenchNoSessions) : store.tr(.workbenchSelectHint))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct WorkbenchSidebarRow: View {
    @ObservedObject var store: StatusStore
    let row: AgentRow

    private var lamp: Color {
        if row.waiting { return .red }
        if row.isStalled { return .orange }
        if row.isRecentOnly { return .secondary.opacity(0.6) }
        return GlanceKind.running.lampColor
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(lamp).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.agent.displayName)
                        .font(.callout.weight(.semibold))
                    if row.isRemote, !row.host.isEmpty {
                        Text(row.host)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let task = row.usefulTask {
                    Text(task)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct SessionInspectorView: View {
    @ObservedObject var store: StatusStore
    let row: AgentRow

    /// The user's draft reply for the resume channel. Lives on the inspector,
    /// which the split view recreates per `.id(rowKey)` — a draft never leaks
    /// from one session into another's answer box.
    @State private var answerDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if row.isRecentOnly {
                    // 复盘 (scene BC): an ended session is reviewed, not
                    // watched. The diff — what actually landed — leads; the
                    // plan's final state and last words follow; there is no
                    // "right now" card because there is no now (陈旧不冒充
                    // 此刻). The checklist shows ungated here: its final
                    // state is the point, and the banner above already says
                    // this is history.
                    header
                    reviewCard
                    effectCard
                    if !row.planSteps.isEmpty || !row.planStep.isEmpty { planCard }
                    if !row.lastWord.isEmpty || !row.lastErrorText.isEmpty { wordsCard }
                    evidenceCard
                } else {
                    header
                    if row.waiting { waitCard }
                    nowCard
                    // Same freshness rule as the tray and Details: a
                    // 30-minute-silent plan is withdrawn, not re-dressed.
                    if row.selfReportFresh,
                       !row.planSteps.isEmpty || !row.planStep.isEmpty { planCard }
                    if row.selfReportFresh,
                       !row.lastWord.isEmpty || !row.lastErrorText.isEmpty { wordsCard }
                    evidenceCard
                    effectCard
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Cards

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.agent.displayName)
                    .font(.title2.weight(.semibold))
                if row.isRemote, !row.host.isEmpty {
                    Text(row.host)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !row.model.isEmpty {
                    Text(row.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let task = row.usefulTask {
                Text(task)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if !row.displayPath.isEmpty {
                    Text(row.displayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(store.lastActivityLabel(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var waitCard: some View {
        card(store.tr(.workbenchWait)) {
            if !row.waitMessage.isEmpty {
                Text(row.waitMessage)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 回答 (scene BB): the two channels, routed by the same pure
            // function the tests pin. Respond wins when a full request is
            // attached; resume appears only for a local resumable session.
            switch store.workbenchAnswerChannel(row) {
            case .respond:
                if let inbound = store.respondRequest(for: row) {
                    respondSection(inbound)
                }
            case .resume:
                resumeSection
            case .focusOnly, .none:
                EmptyView()
            }
            HStack(spacing: 10) {
                if row.canFocusTerminal {
                    Button(store.focusActionTitle(row)) { store.focusTerminal(row) }
                }
                Button(store.tr(.dismissWait)) { store.dismissWaiting(row) }
                Button(row.isSnoozed ? store.tr(.snoozed) : store.tr(.snooze)) {
                    row.isSnoozed ? store.unsnooze(row) : store.snooze(row)
                }
            }
            .buttonStyle(.bordered)
            // Every verb's exit is visible where the button was pressed —
            // a copy, a refusal, a verdict that could not be written.
            if let notice = store.rowActionNotice(row) {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The Respond card, workbench edition — same rules as Details (scene
    /// AR): Allow only next to the complete text it would approve, Deny
    /// always available, the fate note replacing the buttons once a verdict
    /// is written. The store methods are the tested ones; nothing re-decides
    /// here.
    private func respondSection(_ inbound: RespondSpool.InboundRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(store.tr(.respondFullRequest)) · \(inbound.toolName.isEmpty ? row.agent.displayName : inbound.toolName)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(inbound.request.fullRequest)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            if let fate = store.respondFateNote(row) {
                Text(fate)
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
    }

    /// The resume channel: a reply box and one button that copies the exact
    /// command — Pulse never runs it (scene BB; the hint says so out loud).
    private var resumeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.tr(.workbenchAnswerHeading))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(store.tr(.workbenchAnswerPlaceholder), text: $answerDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
            Button(store.tr(.workbenchAnswerCopy)) {
                store.copyResumeCommand(row, answer: answerDraft)
            }
            .buttonStyle(.bordered)
            Text(store.tr(.workbenchAnswerHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 复盘 banner (scene BC): names what this mode is — acceptance of a
    /// finished session — and repeats the boundary: Pulse never touches the
    /// repository.
    private var reviewCard: some View {
        card(store.tr(.workbenchReview)) {
            Text(store.tr(.workbenchReviewHint))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let story = store.rowStoryLine(row)
            if !story.isEmpty {
                Text(story)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nowCard: some View {
        card(store.tr(.detailLiveAction)) {
            if row.liveActionFresh, !row.liveTool.isEmpty {
                Text(row.liveTarget.isEmpty ? row.liveTool : row.liveTool + " · " + row.liveTarget)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            let story = store.rowStoryLine(row)
            if !story.isEmpty {
                Text(story)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !(row.liveActionFresh && !row.liveTool.isEmpty) && store.rowStoryLine(row).isEmpty {
                Text(store.detailPhase(row))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var planCard: some View {
        card(store.tr(.detailPlan)) {
            if row.progressTotal > 0 {
                Text(String(format: store.tr(.progressFact), row.progressDone, row.progressTotal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(row.planSteps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(step.state == .done ? "✓" : step.state == .current ? "▸" : "·")
                        .font(.body.monospaced())
                        .foregroundStyle(step.state == .current ? .primary : .secondary)
                    Text(step.text)
                        .font(.body)
                        .foregroundStyle(step.state == .current ? .primary : .secondary)
                        .strikethrough(step.state == .done)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var wordsCard: some View {
        card(store.tr(.detailLastWord)) {
            if !row.lastWord.isEmpty {
                Text(row.lastWord)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !row.lastErrorText.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(store.tr(.detailLastError))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(row.lastErrorText)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var evidenceCard: some View {
        card(store.tr(.evidenceHeading)) {
            let timeline = store.evidenceTimeline(row)
            if !timeline.isEmpty { labeled(store.tr(.evidenceTimeline), timeline) }
            let tokens = store.evidenceSessionTokens(row)
            if !tokens.isEmpty { labeled(store.tr(.evidenceSessionTokens), tokens) }
            labeled(store.tr(.evidenceRate), store.evidenceRate(row))
            labeled(store.tr(.evidenceCPU), store.evidenceCPU(row))
            let length = store.evidenceSessionLength(row)
            if !length.isEmpty { labeled(store.tr(.evidenceSessionLength), length) }
        }
    }

    private var effectCard: some View {
        card(store.tr(.workbenchDiff)) {
            WorkspaceDiffSection(store: store, row: row)
        }
    }

    // MARK: - Small pieces

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}

/// The counts' own content: the working copy's patch against HEAD, loaded on
/// demand (a click, never a timer — energy is a hard constraint), through
/// the same read-only plumbing the measurement uses. Local rows with a
/// disk-confirmed root only; a remote row's path describes another machine.
@MainActor
private struct WorkspaceDiffSection: View {
    @ObservedObject var store: StatusStore
    let row: AgentRow

    @State private var patch: String?
    @State private var truncated = false
    @State private var failed = false
    @State private var loading = false

    private var counts: String? {
        guard row.changedPaths >= 0 else { return nil }
        var bits = [String(format: store.tr(.effectFiles), row.changedPaths)]
        if row.insertions >= 0, row.deletions >= 0 {
            bits.append("+\(row.insertions) −\(row.deletions)")
        }
        return bits.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let counts {
                Text(counts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if row.isRemote || row.workspaceRoot.isEmpty {
                // Nothing to show and nothing to pretend: a remote row's
                // disk is elsewhere; an unconfirmed root is not quoted.
                if row.changedPaths < 0 {
                    Text(store.tr(.workbenchDiffUnavailable))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if row.changedPaths == 0 {
                Text(store.tr(.workbenchDiffClean))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let patch {
                if truncated {
                    Text(store.tr(.workbenchDiffTruncated))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(patch)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 360)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            } else if failed {
                Text(store.tr(.workbenchDiffUnavailable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    load()
                } label: {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(store.tr(.workbenchDiffLoad))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(loading)
            }
        }
    }

    private func load() {
        guard !loading else { return }
        loading = true
        let root = row.workspaceRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let result = WorkspaceEffect.patch(root: root)
            DispatchQueue.main.async {
                loading = false
                if let result {
                    patch = result.text
                    truncated = result.truncated
                } else {
                    failed = true
                }
            }
        }
    }
}

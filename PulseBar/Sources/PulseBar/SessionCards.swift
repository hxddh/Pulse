// 7.0-α — one presentation truth, two containers (scene BM).
//
// Until now the wait card, the Respond card, the permission card and the
// managed reply each existed twice: once in the workbench, once nowhere the
// user actually lives. This file is the single set: every card takes a
// `compact` flag — the popup renders the compact face, the workbench the
// full one — so any information written once reaches both surfaces, and the
// two can never drift apart again.

import SwiftUI

/// Respond (scene AR/AU/BB): the full request, Deny always, Allow only
/// beside the complete text, the fate note once a verdict is written.
@MainActor
struct SessionRespondCard: View {
    @ObservedObject var store: StatusStore
    let row: AgentRow
    let inbound: RespondSpool.InboundRequest
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Text("\(store.tr(.respondFullRequest)) · \(inbound.toolName.isEmpty ? row.agent.displayName : inbound.toolName)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(inbound.request.fullRequest)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: compact ? 120 : 200)
            .padding(compact ? 6 : 8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: TrayChrome.innerRadius))
            if let fate = store.respondFateNote(row) {
                Text(fate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Button(store.tr(.respondDeny)) { store.respondDeny(row) }
                    if inbound.request.canOfferAllow {
                        Button(store.tr(.respondAllow)) { store.respondAllow(row) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .small : .regular)
            }
        }
    }
}

/// 6.0-β's permission ask (scene BJ), now shared: full input, truncation
/// withdraws Allow, the hint that silence denies.
@MainActor
struct SessionPermissionCard: View {
    @ObservedObject var store: StatusStore
    let request: ManagedPermission.Request
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Label(
                "\(store.tr(.managedPermissionHeading)) · \(request.toolName)",
                systemImage: "hand.raised"
            )
            .font(compact ? .caption.weight(.semibold) : .headline)
            .foregroundStyle(.orange)
            ScrollView {
                Text(request.inputJSON)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: compact ? 120 : 220)
            .padding(compact ? 6 : 8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: TrayChrome.innerRadius))
            if request.truncated {
                Text(store.tr(.managedPermissionTruncated))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button(store.tr(.respondDeny)) {
                    store.managedPermissionDecide(id: request.id, allow: false)
                }
                if request.canOfferAllow {
                    Button(store.tr(.respondAllow)) {
                        store.managedPermissionDecide(id: request.id, allow: true)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .small : .regular)
            if !compact {
                Text(store.tr(.managedPermissionHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The managed session's turn state and reply, shared: a running turn shows
/// the tool and a stop button; idle shows the reply box (a real turn);
/// queued and interrupted say so honestly.
@MainActor
struct SessionManagedReply: View {
    @ObservedObject var store: StatusStore
    let row: AgentRow
    var compact = false

    @State private var reply = ""

    private var runner: ManagedSessionRunner? { store.managedRunner(for: row) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch runner?.model.status {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(row.tool.isEmpty
                         ? store.tr(.managedRunning)
                         : store.tr(.managedRunning) + " · " + row.tool)
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(store.tr(.managedCancel)) { runner?.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            case .queued:
                Text(store.tr(.managedQueuedNote))
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
            case .interrupted:
                Text(store.tr(.managedInterrupted))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                replyField
            case .idle, .failed, .cancelled:
                replyField
            case nil:
                EmptyView()
            }
        }
    }

    private var replyField: some View {
        HStack(spacing: 8) {
            TextField(store.tr(.managedReplyPlaceholder), text: $reply, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(compact ? 1...3 : 2...6)
            Button(store.tr(.managedSend)) {
                let text = reply
                reply = ""
                runner?.send(prompt: text)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .small : .regular)
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// The agent's own checklist, bounded for the compact face.
@MainActor
struct SessionPlanCompact: View {
    @ObservedObject var store: StatusStore
    let row: AgentRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if row.progressTotal > 0 {
                Text(String(format: store.tr(.progressFact), row.progressDone, row.progressTotal))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(row.planSteps.prefix(4).enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(step.state == .done ? "✓" : step.state == .current ? "▸" : "·")
                        .font(.caption.monospaced())
                        .foregroundStyle(step.state == .current ? .primary : .secondary)
                    Text(step.text)
                        .font(.caption)
                        .foregroundStyle(step.state == .current ? .primary : .secondary)
                        .strikethrough(step.state == .done)
                        .lineLimit(1)
                }
            }
            if row.planSteps.count > 4 {
                Text("… \(row.planSteps.count - 4)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// 11.0-α (scene BV) — the digest tier: information in place, actions
/// behind the chevron. A live row on an uncrowded panel carries this by
/// default — its unclipped latest words (only when the hero had to clip
/// them), its current plan step, and what it has landed. Nothing here is
/// interactive; the act surfaces stay on the full depth.
@MainActor
struct SessionBriefCard: View {
    @ObservedObject var store: StatusStore
    let row: AgentRow

    /// Mirrors `AgentRowButton.heroLimit`: below it the hero already shows
    /// the whole sentence and repeating it would be the same fact twice.
    static let heroClipThreshold = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if row.selfReportFresh, row.lastWord.count > Self.heroClipThreshold {
                Text(row.lastWord)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if row.selfReportFresh, !row.planStep.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("▸")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(row.planStep)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if row.hasWorkspaceEffect, row.changedPaths > 0,
               row.insertions >= 0, row.deletions >= 0 {
                Text("+\(row.insertions) −\(row.deletions)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 10.0 (scene BS) — the collapsed row's former five lines, intact where
/// understanding lives: narrative, motion, observation, work, where/when.
/// Nothing was deleted in the recomposition; it moved here.
@MainActor
struct SessionPanorama: View {
    @ObservedObject var store: StatusStore
    let row: AgentRow

    var body: some View {
        let lines = [
            store.rowStoryLine(row),
            store.rowSignalLine(row),
            store.rowObservationLine(row),
            store.rowWorkLine(row),
            store.rowContextLine(row),
        ].filter { !$0.isEmpty }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                }
            }
        }
    }
}

/// 8.0 — the work-style detail (scene BN): how this session works, every
/// collected fact labelled — tool timeline, workflow skill, model, session
/// tokens, context. Absent facts are absent; nothing here is recomputed.
@MainActor
struct SessionWorkDetail: View {
    @ObservedObject var store: StatusStore
    let row: AgentRow

    var body: some View {
        let facts = store.workDetailFacts(row)
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(facts, id: \.self) { fact in
                    Text(fact)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                }
            }
        }
    }
}

/// 7.0-β — the expanded row: the popup's in-place mini-inspector (scene BM).
/// Everything the user needs to UNDERSTAND and ACT lives here; the workbench
/// remains the place to read whole conversations and land work.
@MainActor
struct TrayExpandedCard: View {
    @ObservedObject var store: StatusStore
    let row: AgentRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The task title, demoted from hero when fresh words replaced it
            // — still one glance away.
            if let task = row.usefulTask {
                Text(task)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            // The agent's latest words in full (the collapsed hero clips).
            if row.selfReportFresh, !row.lastWord.isEmpty {
                Text(row.lastWord)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !row.lastErrorText.isEmpty {
                Text(row.lastErrorText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if row.selfReportFresh, !row.planSteps.isEmpty {
                SessionPlanCompact(store: store, row: row)
            }
            // 8.0/10.0: how it works — timeline, skill, sub-agents — then
            // the five-line panorama the collapsed row no longer stacks.
            SessionWorkDetail(store: store, row: row)
            SessionPanorama(store: store, row: row)

            // 8.0-γ: the managed conversation's last moves, ambient — the
            // stream is first-hand and already in memory. Observed rows keep
            // the workbench for their transcript (a disk read per repaint is
            // not an ambient cost).
            if row.isManaged,
               let entries = store.managedRunner(for: row)?.model.entries,
               !entries.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(entries.suffix(5).enumerated()), id: \.offset) { _, entry in
                        ManagedEntryRow(store: store, agentName: row.agent.displayName, entry: entry)
                    }
                }
                .padding(TrayChrome.cardSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: TrayChrome.innerRadius))
            }

            // Act where you read: managed asks first, then Respond, then the
            // managed reply, then the classic wait actions.
            ForEach(store.managedPermissionRequests(for: row), id: \.id) { request in
                SessionPermissionCard(store: store, request: request, compact: true)
            }
            if row.waiting, let inbound = store.respondRequest(for: row) {
                SessionRespondCard(store: store, row: row, inbound: inbound, compact: true)
            }
            if row.isManaged {
                SessionManagedReply(store: store, row: row, compact: true)
            }
            HStack(spacing: 10) {
                if row.waiting {
                    Button(store.tr(.dismissWait)) { store.dismissWaiting(row) }
                    Button(row.isSnoozed ? store.tr(.snoozed) : store.tr(.snooze)) {
                        row.isSnoozed ? store.unsnooze(row) : store.snooze(row)
                    }
                }
                Button(store.tr(.trayOpenInWorkbench)) {
                    store.workbenchSelectKey = row.rowKey
                    store.openWorkbench()
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .font(TrayChrome.actionFont)
        }
        .padding(TrayChrome.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: TrayChrome.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: TrayChrome.cardRadius)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

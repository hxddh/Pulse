// 7.0-α — one presentation truth, two containers (scene BM).
//
// Until 7.0 the wait card, the Respond card, the permission card and the
// managed reply each existed twice: once in the workbench, once nowhere the
// user actually lives. This file is the single set: every card takes a
// `compact` flag — the popup renders the compact face, the workbench the
// full one — so any information written once reaches both surfaces, and the
// two can never drift apart again.
//
// 19.0: every card renders a value (`RowCardModel` and its parts) and sends
// `RowCardModel.Action`; none of them sees the store. `surface_check.py`
// keeps it so, and `SurfaceFixtures` renders each one on CI.

import SwiftUI

/// Respond (scene AR/AU/BB): the full request, Deny always, Allow only
/// beside the complete text, the fate note once a verdict is written.
struct RespondCardFace: View {
    let model: RowCardModel.Respond
    var compact = false
    var send: (RowCardModel.Action) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Text(model.heading)
                .font(PulseTheme.Font.chip)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(model.fullRequest)
                    .font(PulseTheme.Font.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: compact ? 120 : 200)
            .pulseInner(padding: compact ? PulseTheme.Space.xs : PulseTheme.Space.s)
            if let fate = model.fateNote {
                Text(fate)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Button(model.deny) { send(.respondDeny(requestID: model.requestID, digest: model.digest)) }
                    if model.canOfferAllow {
                        Button(model.allow) { send(.respondAllow(requestID: model.requestID, digest: model.digest)) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .small : .regular)
            }
        }
    }
}

/// 6.0-β's permission ask (scene BJ), shared: full input, truncation
/// withdraws Allow, the hint that silence denies.
struct PermissionCardFace: View {
    let model: RowCardModel.Permission
    var compact = false
    var send: (RowCardModel.Action) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            // Red means blocked: the agent is stopped on this ask.
            Label(model.heading, systemImage: "hand.raised")
                .font(compact ? PulseTheme.Font.chip : PulseTheme.Font.heading)
                .foregroundStyle(PulseTheme.Tone.waiting.color)
            ScrollView {
                Text(model.input)
                    .font(PulseTheme.Font.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: compact ? 120 : 220)
            .pulseInner(padding: compact ? PulseTheme.Space.xs : PulseTheme.Space.s)
            if let note = model.truncatedNote {
                Text(note)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(PulseTheme.Tone.attention.color)
            }
            HStack(spacing: 10) {
                Button(model.deny) { send(.permission(id: model.id, allow: false)) }
                if model.canOfferAllow {
                    Button(model.allow) { send(.permission(id: model.id, allow: true)) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .small : .regular)
            if !compact {
                Text(model.hint)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The managed session's turn state and reply, shared: a running turn shows
/// the tool and a stop button; idle shows the reply box (a real turn);
/// queued and interrupted say so honestly.
struct ManagedReplyFace: View {
    let model: RowCardModel.Reply
    var compact = false
    var send: (RowCardModel.Action) -> Void = { _ in }

    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.turn {
            case .running(let label):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(label)
                        .font(compact ? PulseTheme.Font.caption : PulseTheme.Font.body)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.cancel) { send(.managedCancel) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            case .queued(let note):
                Text(note)
                    .font(compact ? PulseTheme.Font.caption : PulseTheme.Font.body)
                    .foregroundStyle(.secondary)
            case .interrupted(let note):
                Text(note)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(PulseTheme.Tone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
                replyField
            case .open:
                replyField
            }
        }
    }

    private var replyField: some View {
        HStack(spacing: 8) {
            TextField(model.placeholder, text: $reply, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(compact ? 1...3 : 2...6)
            Button(model.send) {
                let text = reply
                reply = ""
                send(.managedSend(text))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .small : .regular)
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// The agent's own checklist, bounded for the compact face.
struct PlanCompactFace: View {
    let model: RowCardModel.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let progress = model.progress {
                Text(progress)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(model.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(step.mark)
                        .font(PulseTheme.Font.code)
                        .foregroundStyle(step.current ? .primary : .secondary)
                    Text(step.text)
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(step.current ? .primary : .secondary)
                        .strikethrough(step.done)
                        .lineLimit(1)
                }
            }
            if model.overflow > 0 {
                Text("… \(model.overflow)")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 11.0-α (scene BV) — the digest tier: information in place, actions
/// behind the chevron. A live row on an uncrowded panel carries this by
/// default — its unclipped latest words (only when the hero had to clip
/// them), its current plan step, and what it has landed. Nothing here is
/// interactive; the act surfaces stay on the full depth.
struct BriefCardFace: View {
    let model: RowCardModel.Brief

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let words = model.fullWords {
                Text(words)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let step = model.planStep {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("▸")
                        .font(PulseTheme.Font.code)
                        .foregroundStyle(.secondary)
                    Text(step)
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let effect = model.effect {
                Text(effect)
                    .font(PulseTheme.Font.code)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 8.0 / 10.0 (scenes BN, BS) — labelled facts, one per line: the work-style
/// detail (timeline, skill, model, tokens) and the panorama (narrative,
/// motion, observation, work, where/when). Absent facts are absent.
struct FactLinesFace: View {
    let lines: [String]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                }
            }
        }
    }
}

/// One line of a managed conversation.
struct ManagedEntryFace: View {
    let model: RowCardModel.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.label)
                .font(PulseTheme.Font.chip)
                .foregroundStyle(labelColor)
                .frame(width: 76, alignment: .trailing)
            Text(model.text)
                .font(model.monospaced ? PulseTheme.Font.code : PulseTheme.Font.body)
                .foregroundStyle(model.tone == .error ? AnyShapeStyle(PulseTheme.Tone.attention.color) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var labelColor: Color {
        switch model.tone {
        case .user: return .accentColor
        case .agent: return .primary
        case .tool: return .secondary
        case .error: return PulseTheme.Tone.attention.color
        }
    }
}

/// 8.0-β inbox (scene BN): a blocked agent's ask must not cost a click —
/// managed permission cards, the Respond card and a dead turn's recovery box
/// live in the list itself.
struct RowAsksFace: View {
    let model: RowCardModel
    var send: (RowCardModel.Action) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: TrayChrome.cardSpacing) {
            ForEach(model.permissions) { permission in
                PermissionCardFace(model: permission, compact: true, send: send)
            }
            if let respond = model.respond {
                RespondCardFace(model: respond, compact: true, send: send)
            }
            if model.needsRecovery, let reply = model.reply {
                ManagedReplyFace(model: reply, compact: true, send: send)
            }
        }
        .pulseCard(padding: TrayChrome.cardPadding)
    }
}

/// 7.0-β — the expanded row: the popup's in-place mini-inspector (scene BM).
/// Everything the user needs to UNDERSTAND and ACT lives here; the workbench
/// remains the place to read whole conversations and land work.
struct TrayExpandedFace: View {
    let model: RowCardModel
    var send: (RowCardModel.Action) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The task title, demoted from hero when fresh words replaced it
            // — still one glance away.
            if let task = model.task {
                Text(task)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            // The agent's latest words in full (the collapsed hero clips).
            if let words = model.lastWord {
                Text(words)
                    .font(PulseTheme.Font.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.errorText {
                Text(error)
                    .font(PulseTheme.Font.code)
                    .foregroundStyle(PulseTheme.Tone.attention.color)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if let plan = model.plan {
                PlanCompactFace(model: plan)
            }
            // 8.0/10.0: how it works — timeline, skill, sub-agents — then
            // the five-line panorama the collapsed row no longer stacks.
            FactLinesFace(lines: model.workFacts)
            FactLinesFace(lines: model.panorama)

            // 8.0-γ: the managed conversation's last moves, ambient — the
            // stream is first-hand and already in memory. Observed rows keep
            // the workbench for their transcript (a disk read per repaint is
            // not an ambient cost).
            if !model.entries.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                        ManagedEntryFace(model: entry)
                    }
                }
                .pulseInner(padding: TrayChrome.cardSpacing)
            }

            // Act where you read: managed asks first, then Respond, then the
            // managed reply, then the classic wait actions.
            ForEach(model.permissions) { permission in
                PermissionCardFace(model: permission, compact: true, send: send)
            }
            if let respond = model.respond {
                RespondCardFace(model: respond, compact: true, send: send)
            }
            if let reply = model.reply {
                ManagedReplyFace(model: reply, compact: true, send: send)
            }
            HStack(spacing: 10) {
                ForEach(Array(model.waitActions.enumerated()), id: \.offset) { _, item in
                    Button(item.title) { send(item.action) }
                }
                Button(model.openWorkbench) { send(.openWorkbench) }
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .font(TrayChrome.actionFont)
        }
        .pulseCard(padding: TrayChrome.cardPadding)
    }
}

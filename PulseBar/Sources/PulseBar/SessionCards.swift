// 7.0-α — one presentation truth for the cards under a tray row (scene BM).
// Every card takes a `compact` flag, so a future container can render the
// full face of the same card rather than a second copy of it.
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
/// them) and its current plan step. Nothing here is
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

/// 8.0-β inbox (scene BN): a blocked agent's ask must not cost a click —
/// the Respond card lives in the list itself.
struct RowAsksFace: View {
    let model: RowCardModel
    var send: (RowCardModel.Action) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: TrayChrome.cardSpacing) {
            if let respond = model.respond {
                RespondCardFace(model: respond, compact: true, send: send)
            }
        }
        .pulseCard(padding: TrayChrome.cardPadding)
    }
}

/// 7.0-β — the expanded row: the popup's in-place mini-inspector (scene BM).
/// Everything the user needs to UNDERSTAND and ACT lives here.
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

            // Act where you read: Respond, then the classic wait actions.
            if let respond = model.respond {
                RespondCardFace(model: respond, compact: true, send: send)
            }
            HStack(spacing: 10) {
                ForEach(Array(model.waitActions.enumerated()), id: \.offset) { _, item in
                    Button(item.title) { send(item.action) }
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .font(TrayChrome.actionFont)
        }
        .pulseCard(padding: TrayChrome.cardPadding)
    }
}

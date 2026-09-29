// 7.0-α — one presentation truth for the cards under a tray row (scene BM).
// Every card takes a `compact` flag, so a future container can render the
// full face of the same card rather than a second copy of it.
//
// 19.0: every card renders a value (`RowCardModel` and its parts) and sends
// `RowCardModel.Action`; none of them sees the store. `surface_check.py`
// keeps it so, and `SurfaceFixtures` renders each one on CI.

import SwiftUI

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


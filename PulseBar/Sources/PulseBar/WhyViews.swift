import SwiftUI

/// 17.0 · renders a `WhyCardModel` and nothing else (`SurfaceCapture`).
struct WhyCardView: View {
    let model: WhyCardModel
    var send: (WhyIntent) -> Void = { _ in }
    /// What the last export did, set by the owner.
    var notice: String = ""

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let why = model.why {
                Text(why)
                    .font(PulseTheme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(t(.whyTimeline))
                .font(PulseTheme.Font.chip)
                .foregroundStyle(.secondary)
            if model.lines.isEmpty {
                Text(t(.whyNoHistory))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(PulseTheme.Font.code)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                HStack(spacing: 10) {
                    Button(t(.whyExport)) { send(.export) }
                        .buttonStyle(.link)
                        .font(PulseTheme.Font.caption)
                    if !notice.isEmpty {
                        Text(notice)
                            .font(PulseTheme.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .pulseCard()
    }
}

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
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(t(.whyTimeline))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if model.lines.isEmpty {
                Text(t(.whyNoHistory))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                HStack(spacing: 10) {
                    Button(t(.whyExport)) { send(.export) }
                        .buttonStyle(.link)
                        .font(.caption)
                    if !notice.isEmpty {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

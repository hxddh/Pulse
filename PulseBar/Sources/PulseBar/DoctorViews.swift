import SwiftUI

/// 19.0 · the self-check's result, rendered from a value. One line per
/// contract: the verdict, what the facts showed, and — when there is one —
/// the next thing to do.
struct DoctorReportView: View {
    let report: DoctorModel.Report
    var copied = false
    var onCopy: () -> Void = {}

    private var copy: DoctorModel.Copy { DoctorModel.Copy(lang: report.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.header)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ForEach(report.checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(check.verdict))
                        .foregroundStyle(tint(check.verdict))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title)
                            .font(.callout.weight(.semibold))
                        Text(check.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !check.next.isEmpty {
                            Text("→ " + check.next)
                                .font(.caption)
                                .foregroundStyle(check.verdict == .attention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(copy.verdict(check.verdict))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(tint(check.verdict))
                }
                .accessibilityElement(children: .combine)
            }
            Button(copied ? (report.lang == .zh ? "已复制" : "Copied") : (report.lang == .zh ? "复制报告" : "Copy report"), action: onCopy)
                .controlSize(.small)
        }
    }

    private func symbol(_ verdict: DoctorModel.Verdict) -> String {
        switch verdict {
        case .works: return "checkmark.circle.fill"
        case .unproven: return "questionmark.circle"
        case .attention: return "exclamationmark.triangle.fill"
        case .absent: return "minus.circle"
        }
    }

    private func tint(_ verdict: DoctorModel.Verdict) -> Color {
        switch verdict {
        case .works: return .green
        case .unproven: return .secondary
        case .attention: return .orange
        case .absent: return .secondary
        }
    }
}

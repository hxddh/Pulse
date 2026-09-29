import SwiftUI

/// 19.0 · the self-check's result, rendered from a value. One line per
/// contract: the verdict, what the facts showed, and — when there is one —
/// the next thing to do. 21.0: where Pulse can take that step itself, it is
/// a button beside the sentence, not an instruction to go and find one.
struct DoctorReportView: View {
    let report: DoctorModel.Report
    var copied = false
    var onCopy: () -> Void = {}
    var onFix: (DoctorModel.Fix) -> Void = { _ in }

    private var copy: DoctorModel.Copy { DoctorModel.Copy(lang: report.lang) }
    private func t(_ key: L10n.Key) -> String { L10n.t(key, report.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.s) {
            Text(report.header)
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ForEach(report.checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.s) {
                    Image(systemName: symbol(check.verdict))
                        .foregroundStyle(tint(check.verdict))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                        Text(check.title)
                            .font(PulseTheme.Font.bodyEmphasis)
                        Text(check.detail)
                            .font(PulseTheme.Font.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !check.next.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.s) {
                                Text("→ " + check.next)
                                    .font(PulseTheme.Font.caption)
                                    .foregroundStyle(check.verdict == .attention
                                        ? AnyShapeStyle(PulseTheme.Tone.attention.color)
                                        : AnyShapeStyle(.secondary))
                                    .fixedSize(horizontal: false, vertical: true)
                                if let fix = DoctorModel.fix(for: check, lang: report.lang) {
                                    Button(fixTitle(fix)) { onFix(fix) }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Text(copy.verdict(check.verdict))
                        .font(PulseTheme.Font.chip)
                        .foregroundStyle(tint(check.verdict))
                }
                .accessibilityElement(children: .combine)
            }
            Button(copied ? t(.copied) : t(.doctorCopyReport), action: onCopy)
                .controlSize(.small)
        }
    }

    private func fixTitle(_ fix: DoctorModel.Fix) -> String {
        switch fix {
        case .installHooks: return t(.installHooks)
        case .copyShapeReport: return t(.supportCopyShapeReport)
        case .openConnections: return t(.settings)
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
        case .works: return PulseTheme.Tone.running.color
        case .unproven, .absent: return .secondary
        case .attention: return PulseTheme.Tone.attention.color
        }
    }
}

import Foundation

/// 22.0 · Lamp — "why didn't I get a banner?", answered from the ledger.
///
/// Every wait already had a durable event (`AttentionLedger`); what it did
/// not keep was the decision about the banner, and the timeline the UI drew
/// from it lost its first line (`queuedAtMs` is zeroed once delivered) and
/// vanished the moment the wait resolved. This value renders one event as a
/// short, ordered account: raised, what happened to the banner and why,
/// clicked, resolved.
struct NotificationAuditModel: Equatable {
    var lines: [String]

    static func make(event: AttentionLedger.Event, lang: ResolvedLanguage) -> NotificationAuditModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: lang == .zh ? "zh-Hans" : "en")
        formatter.dateFormat = "HH:mm"
        func clock(_ ms: Int64) -> String {
            formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        var lines: [String] = []
        lines.append(String(format: t(.auditRaised), clock(event.observedAtMs)))
        if let outcome = event.delivery {
            let at = event.deliveryAtMs.map(clock) ?? ""
            lines.append(String(format: outcomeText(outcome, lang: lang), at))
        } else if event.notifiedAtMs > 0 {
            lines.append(String(format: t(.auditPosted), clock(event.notifiedAtMs)))
        } else if event.queuedAtMs > 0 {
            lines.append(String(format: t(.auditQueued), clock(event.queuedAtMs)))
        }
        if let clicked = event.clickedAtMs {
            lines.append(String(format: t(.auditClicked), clock(clicked)))
        }
        if event.acknowledgedAtMs > 0 {
            lines.append(String(format: t(.auditAcknowledged), clock(event.acknowledgedAtMs)))
        }
        if event.resolvedAtMs > 0 {
            lines.append(String(format: t(.auditResolved), clock(event.resolvedAtMs)))
        }
        return NotificationAuditModel(lines: lines)
    }

    /// A `%@` format for the outcome at a time.
    static func outcomeText(_ outcome: String, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch outcome {
        case "posted": return t(.auditPosted)
        case "summary": return t(.auditSummary)
        default:
            switch WaitingDelivery.SkipReason(rawValue: outcome) {
            case .inFront?: return t(.auditSkipInFront)
            case .muted?: return t(.auditSkipMuted)
            case .acknowledged?: return t(.auditSkipAcknowledged)
            case .held?: return t(.auditSkipHeld)
            case .notifyOff?: return t(.auditSkipNotifyOff)
            case .notAuthorized?: return t(.auditSkipNotAuthorized)
            case .atLaunch?: return t(.auditSkipAtLaunch)
            case .rejected?: return t(.auditSkipRejected)
            case nil: return t(.auditPosted)
            }
        }
    }
}

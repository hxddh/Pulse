import Foundation

/// 22.0 · Lamp — "why didn't I get a banner?", answered from the log.
///
/// Every wait has a record in `SessionLog` (23.0; the ledger before it) that
/// keeps the decision about its banner. This value renders one wait as a
/// short, ordered account: raised, what happened to the banner and why,
/// clicked, dismissed, resolved — each time with its day when it was not
/// today (`LogClock`).
struct NotificationAuditModel: Equatable {
    var lines: [String]

    static func make(
        wait: SessionLog.Wait,
        nowMs: Int64,
        lang: ResolvedLanguage,
        timeZone: TimeZone = .current
    ) -> NotificationAuditModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        func clock(_ ms: Int64) -> String {
            LogClock.label(ms: ms, nowMs: nowMs, lang: lang, timeZone: timeZone)
        }
        var lines: [String] = []
        lines.append(String(format: t(.auditRaised), clock(wait.raisedMs)))
        if let outcome = wait.outcome {
            let at = wait.outcomeMs.map(clock) ?? ""
            lines.append(String(format: outcomeText(outcome, lang: lang), at))
        } else if let notified = wait.notifiedMs {
            lines.append(String(format: t(.auditPosted), clock(notified)))
        } else if let queued = wait.queuedMs {
            lines.append(String(format: t(.auditQueued), clock(queued)))
        }
        if let clicked = wait.clickedMs {
            lines.append(String(format: t(.auditClicked), clock(clicked)))
        }
        if let dismissed = wait.dismissedMs {
            lines.append(String(format: t(.auditAcknowledged), clock(dismissed)))
        }
        if let resolved = wait.resolvedMs {
            lines.append(String(format: t(.auditResolved), clock(resolved)))
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

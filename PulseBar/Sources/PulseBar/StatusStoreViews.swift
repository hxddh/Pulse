import Foundation
import AppKit

/// What views draw, computed from the model: the row and detail values and
/// the tray's one-line notices. Nothing here writes state.
@MainActor
extension StatusStore {
    // MARK: - Row models

    /// The stall rule in minutes, for `Explain`'s why.
    var stallMinutes: Int { Int(AgentRow.stalledSeconds / 60) }

    /// 17.0: the tray row's face, as a value — the store contributes only
    /// what only it knows.
    func trayRowModel(_ row: AgentRow) -> TrayRowModel {
        TrayRowModel.make(TrayRowModel.Input(
            row: row,
            lang: lang,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            stallMinutes: stallMinutes,
            notice: rowActionNotice(row),
            needsReach: isWaitingNoneNeedsReach(row),
            muted: settings.mutedAgents.contains(row.agent)
        ))
    }

    /// 23.0: one session in full — the detail page's value. Reads
    /// `logRevision` (through the audit and the strip), so a banner outcome
    /// that lands while the page is open redraws it.
    func detailModel(_ row: AgentRow) -> DetailModel {
        DetailModel.make(
            row: row,
            face: trayRowModel(row),
            lang: lang,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            stallMinutes: stallMinutes,
            audit: notificationAudit(for: row),
            timeline: timelineStrip(for: row)
        )
    }

    /// Full session inventory for the tray search surface. The normal glance
    /// uses `snapshot.rows`; a query must search every retained row so a
    /// session hidden behind the visible window is still discoverable.
    var allRowsForDisplay: [AgentRow] { cachedAll }

    // MARK: - The tray's one notice

    /// Claude/Codex live but hooks not wired — tray nudge only.
    var needsHooksNudge: Bool {
        // The user took the hooks out on purpose; do not keep offering them.
        if settings.hooksNudgeOff { return false }
        guard hooksStatus == .missing || hooksStatus == .unknown else { return false }
        return cachedAll.contains {
            $0.liveProcess && ($0.agent == .claude || $0.agent == .codex)
        }
    }

    /// Live agent with no Waiting path (not hooks-dependent) — one-line honesty, not a HUD.
    var needsWaitingSignalNudge: Bool {
        if needsHooksNudge { return false }
        return firstLiveWaitingNoneAgent != nil
    }

    /// First live Waiting-none agent still without an active wait — Reach funnel focus target.
    var firstLiveWaitingNoneAgent: AgentID? {
        cachedAll.first {
            $0.liveProcess && $0.agent.waitingSource == .none && !$0.isBlocked
        }?.agent
    }

    /// Packaged bundle version disagrees with the compiled semver — usually a
    /// stale `Pulse.app` next to a fresh build. Worth saying out loud.
    var isVersionMismatch: Bool {
        // Deterministic tray fixtures run from a host bundle whose version is
        // unrelated to Pulse; real packaged launches keep stale-bundle
        // diagnosis first.
        if previewFixtureActive { return false }
        if case .mismatch = PulseVersion.channel { return true }
        return false
    }

    /// A live Waiting row with the user's Waiting-notification preference on,
    /// but no usable macOS authorization. This is intentionally level-based:
    /// the in-tray prompt remains until the user fixes the route or turns the
    /// preference off, so an approval cannot be missed between scans.
    var waitingNotificationNeedsSetup: Bool {
        settings.notifyOnWaiting && notifyAuthorized != true && cachedAll.contains(where: \.isBlocked)
    }

    var maintenanceNoticeText: String? {
        if isVersionMismatch { return tr(.versionStale) }
        // Never request permission implicitly from a background scan; say
        // it is missing and give the notice a direct action.
        if waitingNotificationNeedsSetup {
            return notifyAuthorized == false
                ? tr(.waitingNotifyDenied)
                : tr(.waitingNotifyNotConfigured)
        }
        if waitingBannerFailed, cachedAll.contains(where: \.isBlocked) { return tr(.waitingBannerFailed) }
        // 21.0: Claude or Codex is running without hooks. Waiting still
        // works without them, so this is an offer, not an alarm.
        if needsHooksNudge { return tr(.hooksNudge) }
        if needsWaitingSignalNudge { return tr(.waitingSignalNudge) }
        if case .available = updateStatus { return updateStatusText }
        return nil
    }

    func performMaintenanceNoticeAction() {
        if waitingNotificationNeedsSetup {
            if notifyAuthorized == false {
                openSystemNotificationSettings()
            } else {
                openSettings()
            }
            return
        }
        if waitingBannerFailed, cachedAll.contains(where: \.isBlocked) {
            openSystemNotificationSettings()
            return
        }
        if needsHooksNudge {
            installHooks()
            return
        }
        if needsWaitingSignalNudge {
            openSettings(focus: .waitingSignals)
            return
        }
        if let url = updateAvailableURL {
            NSWorkspace.shared.open(url)
        } else {
            openSettings()
        }
    }

    // MARK: - Settings copy

    var updateStatusText: String {
        switch updateStatus {
        case .idle: return tr(.updateIdle)
        case .checking: return tr(.updateChecking)
        case .current:
            if PulseVersion.prefersPrereleaseUpdates {
                return tr(.updateCurrentPrerelease)
            }
            if PulseVersion.distributionChannel == "stable" {
                return tr(.updateCurrentStable)
            }
            return tr(.updateCurrent)
        case .available(let release): return String(format: tr(.updateAvailable), release.version)
        case .failed(let failure): return "\(tr(.updateFailed)) · \(updateFailureText(failure))"
        }
    }

    var updateAvailableURL: URL? {
        if case .available(let release) = updateStatus, !release.pageURL.isEmpty {
            return URL(string: release.pageURL)
        }
        return nil
    }

    /// 21.0: the reason in the person's language; only the system's own
    /// network message stays as the system wrote it.
    func updateFailureText(_ failure: UpdateCheck.Failure) -> String {
        switch failure {
        case .badFeed: return tr(.updateFailedBadFeed)
        case .network(let message):
            return message.isEmpty ? tr(.updateFailedNetwork) : "\(tr(.updateFailedNetwork)) (\(message))"
        case .http(let code): return String(format: tr(.updateFailedHTTP), code)
        case .badResponse: return tr(.updateFailedBadResponse)
        case .noTag: return tr(.updateFailedNoTag)
        }
    }

    var hookSelfTestText: String {
        switch hookSelfTestResult {
        case .idle: return tr(.hookTestIdle)
        case .running: return tr(.hookTestRunning)
        case .passed(let date):
            return "\(tr(.hookTestPassed)) · \(relative(date))"
        case .failed(let message):
            return "\(tr(.hookTestFailed)) · \(message)"
        }
    }
}

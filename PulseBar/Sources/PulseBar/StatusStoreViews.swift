import Foundation
import AppKit

/// What views draw, computed from the model: the row and detail values and
/// the tray's one-line notices. Nothing here writes state.
@MainActor
extension StatusStore {
    // MARK: - Row models

    /// 17.0: the tray row's face, as a value — the store contributes only
    /// what only it knows.
    func trayRowModel(_ row: AgentRow) -> TrayRowModel {
        TrayRowModel.make(TrayRowModel.Input(
            row: row,
            lang: lang,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
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
            lang: lang,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            muted: settings.mutedAgents.contains(row.agent),
            audit: notificationAudit(for: row),
            timeline: timelineStrip(for: row)
        )
    }

    /// 23.0: the tray header — the why in counts and the freshness, against
    /// the caller's clock (the header's own timeline ticks it).
    func trayHeaderModel(now: Date) -> TrayHeaderModel {
        let lastRead = Self.lastReadDate(lastScanAt: engine.lastScanAt, snapshotUpdatedAt: snapshot.updatedAt)
        return TrayHeaderModel.make(TrayHeaderModel.Input(
            rows: cachedAll,
            lang: lang,
            nowMs: Int64(now.timeIntervalSince1970 * 1000),
            lastScanMs: lastRead.map { Int64($0.timeIntervalSince1970 * 1000) },
            intervalSeconds: engine.currentInterval,
            lastScanIntervalSeconds: engine.lastScanInterval,
            asleep: engine.powerParked
        ))
    }

    /// Full session inventory for the tray search surface. The normal glance
    /// uses `snapshot.rows`; a query must search every retained row so a
    /// session hidden behind the visible window is still discoverable.
    var allRowsForDisplay: [AgentRow] { cachedAll }

    // MARK: - The tray's one notice

    /// A live agent whose hook is not wired — tray nudge only (24.0: any of
    /// the seven, not just Claude and Codex).
    var needsHooksNudge: Bool {
        // The user took the hooks out on purpose; do not keep offering them.
        if settings.hooksNudgeOff { return false }
        if case .failed = hooksStatus { return false }
        return cachedAll.contains {
            $0.liveProcess && !hooksStatus.isInstalled(for: $0.agent)
        }
    }

    /// Packaged bundle version disagrees with the compiled semver — usually a
    /// stale `Pulse.app` next to a fresh build. Diagnostics and Settings say
    /// so.
    var isVersionMismatch: Bool {
        // Deterministic tray fixtures run from a host bundle whose version is
        // unrelated to Pulse; real packaged launches keep stale-bundle
        // diagnosis first.
        if previewFixtureActive { return false }
        if case .mismatch = PulseVersion.channel { return true }
        return false
    }

    /// 23.0: at most one notice, with one action (`TrayNoticeModel.pick`).
    var trayNotice: TrayNoticeModel? {
        TrayNoticeModel.pick(TrayNoticeModel.Input(
            lang: lang,
            notifyOnWaiting: settings.notifyOnWaiting,
            notifyAuthorized: notifyAuthorized,
            bannerFailed: waitingBannerFailed && cachedAll.contains(where: \.isBlocked),
            hooksMissing: needsHooksNudge,
            scanIncomplete: collectorScanIncomplete
        ))
    }

    func performTrayNotice(_ action: TrayNoticeModel.Action) {
        switch action {
        case .openNotificationSettings: openSystemNotificationSettings()
        case .enableNotifications: requestNotificationAuthorization()
        case .installHooks: installHooks()
        case .openDiagnostics: openDiagnostics()
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

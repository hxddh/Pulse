import Foundation
import AppKit

/// What views draw, computed from the model: the row and detail values and
/// the tray's one-line notices. Nothing here writes state.
@MainActor
extension StatusStore {
    // MARK: - Row models

    /// The tray row's face, as a value — the store contributes only
    /// what only it knows.
    func trayRowModel(_ row: AgentRow) -> TrayRowModel {
        TrayRowModel.make(TrayRowModel.Input(
            row: row,
            lang: lang,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            notice: rowActionNotice(row),
            muted: settings.mutedAgents.contains(row.agent)
        ))
    }

    /// One session in full — the detail page's value.
    func detailModel(_ row: AgentRow) -> DetailModel {
        DetailModel.make(
            row: row,
            lang: lang,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            muted: settings.mutedAgents.contains(row.agent)
        )
    }

    /// The tray header — the why, in counts.
    var trayHeaderModel: TrayHeaderModel {
        TrayHeaderModel.make(rows: cachedAll, lang: lang)
    }

    /// Every retained row, not only the visible window: the open tray keeps
    /// a row it has shown, and a reveal can land on one behind the fold.
    var allRowsForDisplay: [AgentRow] { cachedAll }

    // MARK: - The tray's one notice

    /// Agents on this Mac whose hook is not wired, in roster order: the
    /// setup card's "Found …". Only agents whose vendor folder is here —
    /// exactly the ones "Connect" installs — and never one whose last install
    /// failed (the card says why instead: `setupFailureText`). Empty once the
    /// person removed the hooks on purpose, while an install runs, or when
    /// the last one could not write anything (Settings says why).
    var setupAgents: [AgentID] {
        if settings.hooksNudgeOff { return [] }
        if case .failed = hooksStatus { return [] }
        if hooksStatus.isWorking { return [] }
        let failed = hooksStatus.failures
        return AgentID.priority.filter {
            presentAgents.contains($0) && !hooksStatus.isInstalled(for: $0) && failed[$0] == nil
        }
    }

    /// Why the last install failed for some agents, in the existing failure
    /// copy; "" when none did or the person removed the hooks on purpose.
    var setupFailureText: String {
        if settings.hooksNudgeOff { return "" }
        let failed = hooksStatus.failures.filter { !hooksStatus.isInstalled(for: $0.key) }
        return failed.isEmpty ? "" : HooksSupport.Status.failureText(failed, lang: lang)
    }

    /// Packaged bundle version disagrees with the compiled semver — usually a
    /// stale `Pulse.app` next to a fresh build. Settings says so.
    var isVersionMismatch: Bool {
        // Deterministic tray fixtures run from a host bundle whose version is
        // unrelated to Pulse; real packaged launches keep stale-bundle
        // diagnosis first.
        if previewFixtureActive { return false }
        if case .mismatch = PulseVersion.channel { return true }
        return false
    }

    /// At most one notice, with one action (`TrayNoticeModel.pick`).
    var trayNotice: TrayNoticeModel? {
        TrayNoticeModel.pick(TrayNoticeModel.Input(
            lang: lang,
            notifyOnWaiting: settings.notifyOnWaiting,
            notifyAuthorized: notifyAuthorized,
            bannerFailed: waitingBannerFailed && cachedAll.contains(where: \.isBlocked),
            unconnected: setupAgents,
            installFailure: setupFailureText,
            justConnected: setupConnected.map { connected in AgentID.priority.filter(connected.contains) }
        ))
    }

    func performTrayNotice(_ action: TrayNoticeModel.Action) {
        switch action {
        case .connect: connectFromSetup()
        case .dismissSetup: if setupConnected != nil { setupConnected = nil }
        case .openHooksSettings: openSettings(focus: .waitingSignals)
        case .openNotificationSettings: openSystemNotificationSettings()
        case .enableNotifications: requestNotificationAuthorization()
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

    /// The reason in the person's language; only the system's own
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
}

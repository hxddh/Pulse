import Foundation
import AppKit

/// 4.0-γ file split — Hooks install, the update check, lifecycle.
/// Behavior-frozen: every member moved verbatim from StatusStore.swift;
/// the full test suite is the contract that nothing changed.
extension StatusStore {
    func installHooks() {
        hooksStatus = .unknown
        setHooksNudgeOff(false)
        // `Task` inherits this class's main-actor isolation, so the assignment
        // lands on main while the optional hook installer stays off it.
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                HooksSupport.install()
            }.value
            self?.hooksStatus = status
        }
    }

    func runHookSelfTest() {
        hookSelfTestResult = .running
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                HooksSupport.selfTest()
            }.value
            self?.hookSelfTestResult = result
        }
    }

    func uninstallHooks() {
        hooksStatus = .unknown
        // An uninstall is a decision: stop suggesting hooks until the user
        // installs them again.
        setHooksNudgeOff(true)
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                HooksSupport.uninstall()
            }.value
            self?.hooksStatus = status
        }
    }

    /// Persist the "don't suggest hooks" choice without a full rescan.
    private func setHooksNudgeOff(_ value: Bool) {
        guard hooksNudgeOff != value else { return }
        hooksNudgeOff = value
        persistSettingsOnly()
    }

    var hooksInstalled: Bool {
        switch hooksStatus {
        case .installedBoth, .installedClaude, .installedCodex: return true
        case .unknown, .missing, .failed: return false
        }
    }

    /// Notification permission lives in System Settings, not in Pulse.
    func openSystemNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Notification permission is requested only from an explicit Settings
    /// action. Launching Pulse or scanning an Agent must remain interruption-
    /// free, especially for unsigned builds whose identity can change.
    func requestNotificationAuthorization() {
        PulseNotify.requestAuthorizationAfterUserAction()
    }

    func checkForUpdatesNow() {
        UpdateCheck.shared.check(store: self, force: true)
    }

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

    var maintenanceNoticeText: String? {
        if isVersionMismatch { return tr(.versionStale) }
        // A Waiting row is already visible in the tray, but without a system
        // notification the user has no interruption when the panel is closed.
        // Make the missing permission explicit and give the notice a direct
        // action; never request permission implicitly from a background scan.
        if waitingNotificationNeedsSetup {
            return notifyAuthorized == false
                ? tr(.waitingNotifyDenied)
                : tr(.waitingNotifyNotConfigured)
        }
        // 21.0: Claude or Codex is running without hooks. Waiting still
        // works without them (`claude agents --json`, harvest), so this is
        // an offer, not an alarm — one line, installed in one click, using
        // the same Claude/Codex installer Settings has.
        if waitingBannerFailed, cachedAll.contains(where: \.waiting) { return tr(.waitingBannerFailed) }
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
        if waitingBannerFailed, cachedAll.contains(where: \.waiting) {
            openSystemNotificationSettings()
            return
        }
        if needsHooksNudge {
            installHooks()
            return
        }
        if needsWaitingSignalNudge {
            openSettings(focusWaitingSignals: true)
            return
        }
        if let url = updateAvailableURL {
            NSWorkspace.shared.open(url)
        } else {
            openSettings()
        }
    }

    /// A live Waiting row with the user's Waiting-notification preference on,
    /// but no usable macOS authorization. This is intentionally level-based:
    /// the in-tray prompt remains until the user fixes the route or turns the
    /// preference off, so an approval cannot be missed between scans.
    var waitingNotificationNeedsSetup: Bool {
        notifyOnWaiting && notifyAuthorized != true && cachedAll.contains(where: \.waiting)
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

    func openSupportHealth() {
        SupportCoverageWindowController.shared.show(store: self)
    }

    func quit() {
        attentionWatcher.stop()
        GlobalHotKey.uninstall()
        NSApp.terminate(nil)
    }
}

import Foundation
import AppKit

/// 4.0-γ file split — Hooks install, updates, recovery, lifecycle and termination markers.
/// Behavior-frozen: every member moved verbatim from StatusStore.swift;
/// the full test suite is the contract that nothing changed.
extension StatusStore {
    func installHooks() {
        hooksStatus = .unknown
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
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                HooksSupport.uninstall()
            }.value
            self?.hooksStatus = status
        }
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

    func downloadAndVerifyUpdate() {
        UpdateCheck.shared.downloadAndOpen(store: self)
    }

    func installVerifiedUpdate() {
        UpdateCheck.shared.installVerifiedUpdate(store: self)
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
        case .failed(let message): return "\(tr(.updateFailed)) · \(message)"
        }
    }

    var updateAvailableURL: URL? {
        if case .available(let release) = updateStatus, !release.pageURL.isEmpty {
            return URL(string: release.pageURL)
        }
        return nil
    }

    var updateCanVerifyDownload: Bool {
        if case .available(let release) = updateStatus {
            return release.canVerifyDownload
        }
        return false
    }

    /// In-place install is only honest on notarized stable builds.
    var updateCanInstallInPlace: Bool {
        PulseVersion.isGatekeeperReady
    }

    var updateDownloadStatusText: String? {
        switch updateDownloadStatus {
        case .idle: return nil
        case .downloading: return tr(.updateDownloading)
        case .verifying: return tr(.updateVerifying)
        case .ready:
            return updateCanInstallInPlace
                ? tr(.updateVerified)
                : tr(.updateVerifiedOpenOnly)
        case .installing: return tr(.updateInstalling)
        case .failed(let message): return "\(tr(.updateVerifyFailed)) · \(message)"
        }
    }

    var maintenanceNoticeText: String? {
        if recoveredAfterCrash { return recoveryNoticeText }
        if isVersionMismatch { return tr(.versionStale) }
        if installReport.hasOtherRunningCopy { return tr(.duplicateAppRunning) }
        // A Waiting row is already visible in the tray, but without a system
        // notification the user has no interruption when the panel is closed.
        // Make the missing permission explicit and give the notice a direct
        // action; never request permission implicitly from a background scan.
        if waitingNotificationNeedsSetup {
            return notifyAuthorized == false
                ? tr(.waitingNotifyDenied)
                : tr(.waitingNotifyNotConfigured)
        }
        // The tray is an observation surface, not a hook installer. Missing
        // Claude/Codex hooks remain visible in Support Health and Settings
        // (native install — no Python). Do not displace session facts.
        if needsWaitingSignalNudge { return tr(.waitingSignalNudge) }
        if case .available = updateStatus { return updateStatusText }
        return nil
    }

    private var recoveryNoticeText: String {
        switch recoveryExitKind {
        case .forceQuit: return tr(.recoveredAfterForceQuit)
        case .systemRestart: return tr(.recoveredAfterSystemRestart)
        case .crash, .unknown: return tr(.recoveredAfterCrash)
        case .clean, .updateReplace:
            // wasUnclean excludes these; never surface a crash lie here.
            return ""
        }
    }

    func dismissRecoveryNotice() {
        recoveredAfterCrash = false
        recoveryExitKind = .clean
        recoveryNoticeSurvivedFirstHealthyScan = false
    }

    func performMaintenanceNoticeAction() {
        if recoveredAfterCrash {
            dismissRecoveryNotice()
            openSettings()
            return
        }
        if waitingNotificationNeedsSetup {
            if notifyAuthorized == false {
                openSystemNotificationSettings()
            } else {
                openSettings()
            }
            return
        }
        // The tray notice is reserved for actionable non-hook maintenance or
        // an already-configured Waiting route. Hook setup stays in Settings.
        if needsWaitingSignalNudge {
            openSettings(
                focusWaitingSignals: true,
                focusWaitingAgent: firstLiveWaitingNoneAgent
            )
            return
        }
        if case .available = updateStatus, updateCanVerifyDownload {
            downloadAndVerifyUpdate()
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

    func refreshInstallTruth(force: Bool = false) {
        let now = Date()
        if !force,
           installTruthRefreshInFlight
                || (installTruthRefreshedAt.map { now.timeIntervalSince($0) < 30 } ?? false) {
            return
        }
        installTruthRefreshInFlight = true
        installTruthGeneration += 1
        let generation = installTruthGeneration
        Task { @MainActor [weak self] in
            let report = await Task.detached(priority: .utility) {
                InstallTruth.inspect()
            }.value
            guard let self, self.installTruthGeneration == generation else { return }
            self.installReport = report
            self.installTruthRefreshedAt = Date()
            self.installTruthRefreshInFlight = false
        }
    }

    func recycleDuplicateApps() {
        let candidates = installReport.removableDuplicates
        InstallTruth.recycle(candidates) { [weak self] _ in
            self?.refreshInstallTruth(force: true)
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

    /// `Permission · waited 4 分 · Pulse` for the resolved-wait list.
    func historyDetail(_ entry: ResolvedWait) -> String {
        var bits: [String] = []
        if !entry.kind.isEmpty { bits.append(localizedWaitKind(entry.kind)) }
        if entry.waitedSeconds >= 1 {
            bits.append(String(format: tr(.waitedFor), durationLabel(seconds: entry.waitedSeconds)))
        }
        if !entry.project.isEmpty { bits.append(entry.project) }
        bits.append(relative(entry.resolvedAt))
        return bits.joined(separator: " · ")
    }


    func openSupportHealth() {
        SupportCoverageWindowController.shared.show(store: self)
    }

    /// 3.0-β · the workbench's read surface: every session the store knows,
    /// not the tray's glance window. Deliberately the window's only special
    /// access so far — the first real seam, cut where use demanded it
    /// (plan-3.0's rule: seams follow use).
    var allRows: [AgentRow] { cachedAll }

    func openWorkbench() {
        WorkbenchWindowController.shared.show(store: self)
    }

    func openAgentDetail(_ row: AgentRow) {
        AgentDetailWindowController.shared.show(store: self, row: row)
    }

    func quit() {
        markCleanShutdown()
        attentionWatcher.stop()
        GlobalHotKey.uninstall()
        NSApp.terminate(nil)
    }

    func markCleanShutdown() {
        guard var recovery = launchRecovery else { return }
        recovery.markCleanShutdown()
        launchRecovery = recovery
    }

    func markIntendedUpdateReplace() {
        guard var recovery = launchRecovery else { return }
        recovery.markIntendedExit(.updateReplace)
        launchRecovery = recovery
    }

    func markIntendedForceQuit() {
        guard var recovery = launchRecovery else { return }
        recovery.markIntendedExit(.forceQuit)
        launchRecovery = recovery
    }

    /// Soft termination (SIGTERM / Activity Monitor "Quit") writes a force-quit
    /// intent so the next launch can distinguish it from a crash. True Force
    /// Quit (SIGKILL) cannot be intercepted and remains classified as crash.
    func installTerminationSignalMarker() {
        guard terminationSignalSource == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.markIntendedForceQuit()
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSignalSource = source
    }
}

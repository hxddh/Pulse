import Foundation
import UserNotifications
import AppKit

final class PulseNotifyDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let agent = info["agent"] as? String ?? ""
        let session = info["session"] as? String ?? ""
        let rowKey = info["rowKey"] as? String ?? ""
        let summaryRowKeys = info["rowKeys"] as? [String] ?? []
        DispatchQueue.main.async {
            AppServices.store.notifier.handleBannerClick(
                agent: agent,
                session: session,
                rowKey: rowKey,
                summaryRowKeys: summaryRowKeys
            )
        }
        completionHandler()
    }
}

enum PulseNotify {
    /// `UNUserNotificationCenter.current()` throws an AppKit exception when a
    /// SwiftPM debug executable is launched outside an `.app` bundle. That is
    /// a normal developer/visual-QA path, not a reason for Pulse to crash;
    /// packaged builds still use the real center.
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }
    nonisolated(unsafe) private static let delegate = PulseNotifyDelegate()

    static let focusActionID = "pulse.focus"
    static let waitingCategoryID = "pulse.waiting"

    /// The button on the waiting banner: go to the session. (23.0 removed
    /// "Later" with snooze.)
    ///
    /// Registered in the resolved language and re-registered when it changes —
    /// a category is keyed by id, so re-adding replaces the old titles.
    static func registerCategories(lang: ResolvedLanguage) {
        guard let center else { return }
        let focus = UNNotificationAction(
            identifier: focusActionID,
            title: L10n.t(.notifFocus, lang),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: waitingCategoryID,
            actions: [focus],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Reports whether the user actually granted permission. Dropping this
    /// result meant a denied prompt left both notification toggles reading
    /// "on" while nothing would ever fire.
    static func configure(onAuthorization: @escaping (Bool?) -> Void) {
        guard let center else {
            onAuthorization(false)
            return
        }
        center.delegate = delegate
        authorizationHandler = onAuthorization
        refreshAuthorization()
    }

    nonisolated(unsafe) private static var authorizationHandler: ((Bool?) -> Void)?

    /// Ask only after an explicit user action. Startup and background scans
    /// must never create a permission interruption on their own.
    static func requestAuthorizationAfterUserAction() {
        guard let center else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                refreshAuthorization()
                return
            }
            // Looked up again rather than captured: the center is not
            // Sendable, and this callback runs on the center's own queue.
            Self.center?.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                authorizationHandler?(granted)
            }
        }
    }

    /// Re-read the live setting — the user may have flipped it in System Settings.
    static func refreshAuthorization() {
        guard let center else { return }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                authorizationHandler?(true)
            case .denied:
                authorizationHandler?(false)
            case .notDetermined:
                authorizationHandler?(nil)
            @unknown default:
                authorizationHandler?(false)
            }
        }
    }

    /// One banner per row (`WaitLedger.bannerID`): a later ask on the same
    /// row replaces it.
    static func postWaiting(
        id: String,
        title: String,
        body: String,
        agent: String,
        session: String = "",
        rowKey: String = "",
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        post(
            id: id,
            title: title,
            body: body,
            agent: agent,
            session: session,
            rowKey: rowKey,
            completion: completion
        )
    }

    /// A single, actionable summary for a burst of approvals
    /// (`WaitLedger.summaryID`); it only reduces the interruption count.
    static func postWaitingSummary(
        id: String,
        title: String,
        body: String,
        agent: String,
        session: String,
        rowKeys: [String],
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        post(
            id: id,
            title: title,
            body: body,
            agent: agent,
            session: session,
            rowKey: rowKeys.first ?? "",
            rowKeys: rowKeys,
            completion: completion
        )
    }

    /// A banner whose wait was answered, dismissed or ended leaves
    /// Notification Center — delivered or still pending.
    static func withdraw(ids: [String]) {
        guard let center, !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private static func post(
        id: String,
        title: String,
        body: String,
        agent: String,
        session: String,
        rowKey: String,
        rowKeys: [String] = [],
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        // Delivery is asynchronous. The caller must not mark a wait as
        // notified until Notification Center accepts the request; otherwise
        // a transient add failure loses the only interruption until the
        // agent emits a brand-new Waiting edge.
        guard let center else {
            completion(false)
            return
        }
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = ContentSanitizer.redact(title)
        content.body = ContentSanitizer.redact(body)
        content.sound = .default
        // Keep all Waiting interruptions together in Notification Centre while
        // retaining one actionable request per session. A single scan can
        // surface several approvals; collapsing them into one notification
        // would hide which Agent needs the user's answer.
        if !rowKey.isEmpty || !agent.isEmpty {
            content.threadIdentifier = "pulse.waiting"
        }
        // A banner that names a session carries the Focus action.
        if !rowKey.isEmpty || !agent.isEmpty {
            content.categoryIdentifier = waitingCategoryID
        }
        var info: [String: Any] = [:]
        if !agent.isEmpty { info["agent"] = agent }
        if !session.isEmpty { info["session"] = session }
        if !rowKey.isEmpty { info["rowKey"] = rowKey }
        if !rowKeys.isEmpty { info["rowKeys"] = rowKeys }
        content.userInfo = info
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        // Called only after the hop to the main queue below.
        let deliver = Unchecked(completion)
        center.add(req) { error in
            if let error {
                // A notification request can still fail after authorization
                // (for example while the app's identity is being reinstalled).
                // Keep that fact in diagnostics instead of silently promising
                // an interruption that never arrived.
                DebugLog.write("notification add failed id=\(id) error=\(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                deliver.value(error == nil)
            }
        }
    }
}

enum SettingsPresenter {
    /// Prefer staying `.accessory` — flipping activation policy is the slow part.
    /// Called from UI actions only, i.e. on the main thread.
    static func prepareToOpen() {
        MainActor.assumeIsolated {
            NSApp?.activate(ignoringOtherApps: true)
        }
    }

    static func ensureKeyableIfNeeded() {
        MainActor.assumeIsolated {
            if NSApp?.activationPolicy() != .regular {
                NSApp?.setActivationPolicy(.regular)
                NSApp?.activate(ignoringOtherApps: true)
            }
        }
    }

    static func restoreAccessoryIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if SettingsWindowController.shared.isOpen { return }
            let settingsOpen = (NSApp?.windows ?? []).contains { win in
                win.isVisible && win.identifier?.rawValue == "pulse-settings"
            }
            if !settingsOpen, NSApp?.activationPolicy() != .accessory {
                NSApp?.setActivationPolicy(.accessory)
            }
        }
    }
}

import Foundation
import UserNotifications
import AppKit

final class PulseNotifyDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let options: UNNotificationPresentationOptions = notification.request.content.sound == nil
            ? [.banner]
            : [.banner, .sound]
        completionHandler(options)
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
        let kind = info["kind"] as? String ?? PulseNotify.BannerKind.waiting.rawValue
        let intent = BannerIntent.decide(
            actionID: response.actionIdentifier,
            dismissActionID: UNNotificationDismissActionIdentifier
        )
        DispatchQueue.main.async {
            let notifier = AppServices.store.notifier
            switch intent {
            case .go:
                notifier.handleBannerClick(agent: agent, session: session, rowKey: rowKey, kind: kind)
            case .ignore:
                notifier.handleBannerIgnore(rowKey: rowKey)
            case .nothing:
                break
            }
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

    enum BannerKind: String {
        case waiting
        case done
    }

    static let waitingCategoryID = "pulse.waiting"
    static let turnDoneCategoryID = "pulse.turnDone"

    /// The waiting banner's buttons: go to the session, or ignore the wait
    /// (the tray's ⌘D — Pulse's own `done`, never an answer to the agent;
    /// it does not bring Pulse forward). Turn-done banners carry Go only.
    ///
    /// Registered once, in the system's language.
    static func registerCategories(lang: ResolvedLanguage) {
        guard let center else { return }
        let focus = UNNotificationAction(
            identifier: BannerIntent.goActionID,
            title: L10n.t(.notifFocus, lang),
            options: [.foreground]
        )
        let ignore = UNNotificationAction(
            identifier: BannerIntent.ignoreActionID,
            title: L10n.t(.ignoreWait, lang),
            options: []
        )
        let waitingCategory = UNNotificationCategory(
            identifier: waitingCategoryID,
            actions: [focus, ignore],
            intentIdentifiers: [],
            options: []
        )
        let doneCategory = UNNotificationCategory(
            identifier: turnDoneCategoryID,
            actions: [focus],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([waitingCategory, doneCategory])
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

    /// Notification permission lives in System Settings, not in Pulse.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS lets Pulse send Time Sensitive banners: its notification
    /// settings say `timeSensitiveSetting == .enabled`, which happens only
    /// with the entitlement. Read with the authorization.
    private static let timeSensitiveAllowed = Guarded(false)

    /// Re-read the live setting — the user may have flipped it in System Settings.
    static func refreshAuthorization() {
        guard let center else { return }
        center.getNotificationSettings { settings in
            let timeSensitive = settings.timeSensitiveSetting == .enabled
            timeSensitiveAllowed.withValue { $0 = timeSensitive }
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

    /// A banner whose wait was answered, ignored or ended leaves
    /// Notification Center — delivered or still pending.
    static func withdraw(ids: [String]) {
        guard let center, !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// One banner per wait (`WaitLedger.bannerID`) or finished turn
    /// (`TurnWatch.bannerID`): a later ask on the same row replaces it.
    static func postWaiting(
        id: String,
        banner: WaitingBanner,
        agent: String,
        session: String = "",
        rowKey: String = "",
        kind: BannerKind = .waiting,
        sound: NotificationSound = .default,
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
        content.title = ContentSanitizer.redact(banner.title)
        if !banner.subtitle.isEmpty { content.subtitle = ContentSanitizer.redact(banner.subtitle) }
        content.body = ContentSanitizer.redact(banner.body)
        content.sound = sound == .default ? .default : nil
        // One thread per session: a second ask from the same session stacks
        // with its first, never with another agent's — a burst of
        // approvals still shows who needs an answer.
        content.threadIdentifier = banner.threadID
        // A wait that blocks an agent may break through a Focus — but only
        // where macOS says Pulse may (the Time Sensitive entitlement, which
        // only a Developer ID build can carry). Turn-done banners stay active.
        if kind == .waiting, timeSensitiveAllowed.snapshot {
            content.interruptionLevel = .timeSensitive
        }
        // Waiting banners carry Go + Ignore; turn-done banners carry Go only.
        if !rowKey.isEmpty || !agent.isEmpty {
            content.categoryIdentifier = kind == .waiting ? waitingCategoryID : turnDoneCategoryID
        }
        var info: [String: Any] = ["kind": kind.rawValue]
        if !agent.isEmpty { info["agent"] = agent }
        if !session.isEmpty { info["session"] = session }
        if !rowKey.isEmpty { info["rowKey"] = rowKey }
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

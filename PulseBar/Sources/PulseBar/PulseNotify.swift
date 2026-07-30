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
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            // "Later" from the banner is the same snooze as the row's button.
            // The banner is where you actually are when the interruption lands
            // — being able to defer without opening anything is the point.
            if action == PulseNotify.snoozeActionID {
                AppServices.store.snooze(rowKey: rowKey)
                return
            }
            if !agent.isEmpty || !rowKey.isEmpty {
                AppServices.store.focusAgent(idRaw: agent, session: session, rowKey: rowKey)
            } else {
                AppServices.store.focusFirstWaiting()
            }
        }
        completionHandler()
    }
}

enum PulseNotify {
    private static let center = UNUserNotificationCenter.current()
    private static let delegate = PulseNotifyDelegate()
    private static var requested = false

    static let focusActionID = "pulse.focus"
    static let snoozeActionID = "pulse.snooze"
    static let waitingCategoryID = "pulse.waiting"

    /// Buttons on the waiting banner.
    ///
    /// Until now a banner could only be clicked as a whole, which meant the
    /// only thing you could do from it was drop what you were doing. Both real
    /// answers now live where the interruption actually arrives.
    ///
    /// Registered in the resolved language and re-registered when it changes —
    /// a category is keyed by id, so re-adding replaces the old titles.
    static func registerCategories(lang: ResolvedLanguage) {
        let focus = UNNotificationAction(
            identifier: focusActionID,
            title: L10n.t(.notifFocus, lang),
            options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: snoozeActionID,
            title: L10n.t(.snooze, lang),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: waitingCategoryID,
            actions: [focus, snooze],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Reports whether the user actually granted permission. Dropping this
    /// result meant a denied prompt left both notification toggles reading
    /// "on" while nothing would ever fire.
    static func configure(onAuthorization: @escaping (Bool) -> Void) {
        center.delegate = delegate
        authorizationHandler = onAuthorization
        requestAuthorizationIfNeeded()
        refreshAuthorization()
    }

    private static var authorizationHandler: ((Bool) -> Void)?

    static func requestAuthorizationIfNeeded() {
        guard !requested else { return }
        requested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            authorizationHandler?(granted)
        }
    }

    /// Re-read the live setting — the user may have flipped it in System Settings.
    static func refreshAuthorization() {
        center.getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            authorizationHandler?(ok)
        }
    }

    static func postIdle(title: String, body: String) {
        post(id: "pulse-idle", title: title, body: body, agent: "", session: "", rowKey: "")
    }

    static func postWaiting(
        title: String,
        body: String,
        agent: String,
        session: String = "",
        rowKey: String = ""
    ) {
        let id: String = {
            if !rowKey.isEmpty {
                let safe = rowKey
                    .replacingOccurrences(of: "|", with: "-")
                    .replacingOccurrences(of: "/", with: "-")
                return "pulse-waiting-\(safe)"
            }
            if !session.isEmpty { return "pulse-waiting-\(agent)-\(session)" }
            if !agent.isEmpty { return "pulse-waiting-\(agent)" }
            return "pulse-waiting"
        }()
        post(id: id, title: title, body: body, agent: agent, session: session, rowKey: rowKey)
    }

    private static func post(
        id: String,
        title: String,
        body: String,
        agent: String,
        session: String,
        rowKey: String
    ) {
        requestAuthorizationIfNeeded()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = ContentSanitizer.redact(title)
        content.body = ContentSanitizer.redact(body)
        content.sound = .default
        // Only waiting banners carry actions; "everything went idle" has
        // nothing to focus and nothing to defer.
        if !rowKey.isEmpty || !agent.isEmpty {
            content.categoryIdentifier = waitingCategoryID
        }
        var info: [String: String] = [:]
        if !agent.isEmpty { info["agent"] = agent }
        if !session.isEmpty { info["session"] = session }
        if !rowKey.isEmpty { info["rowKey"] = rowKey }
        content.userInfo = info
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }
}

enum SettingsPresenter {
    /// Prefer staying `.accessory` — flipping activation policy is the slow part.
    static func prepareToOpen() {
        NSApp.activate(ignoringOtherApps: true)
    }

    static func ensureKeyableIfNeeded() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func restoreAccessoryIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if SettingsWindowController.shared.isOpen { return }
            let settingsOpen = NSApp.windows.contains { win in
                win.isVisible && win.identifier?.rawValue == "pulse-settings"
            }
            if !settingsOpen, NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

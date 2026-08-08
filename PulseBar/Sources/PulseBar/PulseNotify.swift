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
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            // "Later" from the banner is the same snooze as the row's button.
            // The banner is where you actually are when the interruption lands
            // — being able to defer without opening anything is the point.
            if action == PulseNotify.snoozeActionID {
                AppServices.store.snooze(rowKey: rowKey)
                return
            }
            // Prefer the concrete rowKey (summary posts it as rowKeys.first too).
            // Never open the tray without an identity when one was carried.
            if !rowKey.isEmpty {
                AppServices.store.focusAgent(idRaw: agent, session: session, rowKey: rowKey)
            } else if !summaryRowKeys.isEmpty {
                AppServices.store.focusAgent(idRaw: agent, session: session, rowKey: summaryRowKeys[0])
            } else if !agent.isEmpty {
                AppServices.store.focusAgent(idRaw: agent, session: session, rowKey: "")
            } else {
                AppServices.store.focusFirstWaiting()
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
    private static let delegate = PulseNotifyDelegate()

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
        guard let center else { return }
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
    static func configure(onAuthorization: @escaping (Bool?) -> Void) {
        guard let center else {
            onAuthorization(false)
            return
        }
        center.delegate = delegate
        authorizationHandler = onAuthorization
        refreshAuthorization()
    }

    private static var authorizationHandler: ((Bool?) -> Void)?

    /// Ask only after an explicit user action. Startup and background scans
    /// must never create a permission interruption on their own.
    static func requestAuthorizationAfterUserAction() {
        guard let center else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                refreshAuthorization()
                return
            }
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
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

    static func postIdle(title: String, body: String) {
        post(id: "pulse-idle", title: title, body: body, agent: "", session: "", rowKey: "")
    }

    static func postWaiting(
        title: String,
        body: String,
        agent: String,
        session: String = "",
        rowKey: String = "",
        eventID: String = "",
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        let id: String = {
            if !eventID.isEmpty {
                let safe = eventID
                    .replacingOccurrences(of: "|", with: "-")
                    .replacingOccurrences(of: "/", with: "-")
                return "pulse-waiting-event-\(safe)"
            }
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
        post(
            id: id,
            title: title,
            body: body,
            agent: agent,
            session: session,
            rowKey: rowKey,
            eventID: eventID,
            completion: completion
        )
    }

    /// A single, actionable summary for a burst of approvals. Each event ID
    /// remains in the ledger; the summary only reduces interruption count.
    static func postWaitingSummary(
        title: String,
        body: String,
        agent: String,
        session: String,
        rowKeys: [String],
        eventIDs: [String],
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        let seed = (eventIDs + rowKeys).joined(separator: "|")
        let safe = String(seed.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined().prefix(96))
        post(
            id: "pulse-waiting-summary-\(safe)",
            title: title,
            body: body,
            agent: agent,
            session: session,
            rowKey: rowKeys.first ?? "",
            eventID: eventIDs.joined(separator: ","),
            rowKeys: rowKeys,
            completion: completion
        )
    }

    private static func post(
        id: String,
        title: String,
        body: String,
        agent: String,
        session: String,
        rowKey: String,
        eventID: String = "",
        rowKeys: [String] = [],
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        // Delivery is asynchronous. The caller owns the durable ledger and
        // must not mark an event as notified until Notification Center accepts
        // the request; otherwise a transient add failure loses the only
        // interruption until the agent emits a brand-new Waiting edge.
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
        // Only waiting banners carry actions; "everything went idle" has
        // nothing to focus and nothing to defer.
        if !rowKey.isEmpty || !agent.isEmpty {
            content.categoryIdentifier = waitingCategoryID
        }
        var info: [String: Any] = [:]
        if !agent.isEmpty { info["agent"] = agent }
        if !session.isEmpty { info["session"] = session }
        if !rowKey.isEmpty { info["rowKey"] = rowKey }
        if !eventID.isEmpty { info["eventID"] = eventID }
        if !rowKeys.isEmpty { info["rowKeys"] = rowKeys }
        content.userInfo = info
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(req) { error in
            if let error {
                // A notification request can still fail after authorization
                // (for example while the app's identity is being reinstalled).
                // Keep that fact in diagnostics instead of silently promising
                // an interruption that never arrived.
                DebugLog.write("notification add failed id=\(id) error=\(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                completion(error == nil)
            }
        }
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

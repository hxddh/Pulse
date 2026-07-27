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
        DispatchQueue.main.async {
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

    static func configure() {
        center.delegate = delegate
        requestAuthorizationIfNeeded()
    }

    static func requestAuthorizationIfNeeded() {
        guard !requested else { return }
        requested = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        postIdle(title: title, body: body)
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
        content.title = title
        content.body = body
        content.sound = .default
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

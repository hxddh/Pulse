import AppKit
import Foundation

/// Watches the machine conditions that let Pulse stop working so hard:
/// display asleep, screen locked, Low Power Mode.
@MainActor
final class PowerMonitor {
    private(set) var state = ProbeSchedule.Power.current
    private var onChange: (() -> Void)?
    /// Keep each token with the center that issued it — `DistributedNotificationCenter`
    /// tokens must be removed from that center, not from `.default`.
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func start(onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange
        state = ProbeSchedule.Power.current

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.displayAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.displayAsleep = false }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }

        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) {
            $0.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    func stop() {
        for entry in observers {
            entry.center.removeObserver(entry.token)
        }
        observers.removeAll()
        onChange = nil
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ apply: @escaping (inout ProbeSchedule.Power) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mutate(apply)
            }
        }
        observers.append((center, token))
    }

    private func mutate(_ apply: (inout ProbeSchedule.Power) -> Void) {
        var next = state
        apply(&next)
        guard next != state else { return }
        state = next
        DebugLog.write(
            "power asleep=\(next.displayAsleep) locked=\(next.screenLocked) lowPower=\(next.lowPowerMode)"
        )
        onChange?()
    }
}

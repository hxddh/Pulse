import AppKit
import CoreServices

/// Whether Pulse may send Apple Events to a terminal — asked without a
/// prompt (`AEDeterminePermissionToAutomateTarget`, askUserIfNeeded false),
/// for Settings to say. Off the main thread: macOS may take a moment.
enum AutomationCheck {
    /// The terminals whose tab search uses AppleScript.
    static let terminals: [String] = [LandingPlan.terminalBundleID, LandingPlan.iTermBundleID]

    static func state(of bundleID: String) -> AutomationState {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return .notRunning }
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBufferPointer { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &target)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        let answer = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        switch answer {
        case noErr: return .allowed
        case -1743: return .denied        // errAEEventNotPermitted
        case -1744: return .notAsked      // errAEEventWouldRequireUserConsent
        case -600: return .notRunning     // procNotFound
        default: return .unknown
        }
    }

    /// Every terminal's state, keyed by bundle id.
    static func all() -> [String: AutomationState] {
        Dictionary(uniqueKeysWithValues: terminals.map { ($0, state(of: $0)) })
    }
}

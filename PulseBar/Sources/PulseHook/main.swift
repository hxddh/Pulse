import CoreGraphics
import Darwin
import Foundation
import PulseKit

/// Lightweight native hook receiver (`Pulse.app/Contents/MacOS/pulse-hook`).
///
/// Links only `PulseKit`, Foundation, and CoreGraphics — zero AppKit, SwiftUI,
/// Carbon, or UserNotifications — so every vendor hook event executes in a few
/// milliseconds with minimal memory footprint. Always exits 0 (except `--ping`
/// failure) so a vendor hook never blocks its agent.
enum PulseHookEntry {
    static func main() -> Int32 {
        var arguments = ProcessInfo.processInfo.arguments
        if !arguments.contains("--hook") {
            let program = arguments.first ?? "pulse-hook"
            arguments = [program, "--hook"] + arguments.dropFirst()
        }
        var stdinText = ""
        if isatty(STDIN_FILENO) == 0, !PulseHookReceiver.payloadInArguments(arguments) {
            stdinText = PulseHookReceiver.readStdin()
        }
        return PulseHookReceiver.run(
            arguments: arguments,
            stdin: stdinText,
            front: { promptIsFrontmost() }
        )
    }

    /// Frontmost GUI application PID via CoreGraphics on-screen normal windows
    /// (`kCGWindowLayer == 0`), requiring neither AppKit initialization nor
    /// Screen Recording permission (`kCGWindowOwnerPID` is always public).
    private static func promptIsFrontmost() -> Bool? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        var frontPID: Int32?
        var windowOwners = Set<Int32>()
        for window in list {
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
            guard alpha > 0 else { continue }
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 1 else {
                continue
            }
            windowOwners.insert(pid)
            if frontPID == nil { frontPID = pid }
        }
        guard let frontmost = frontPID else { return nil }
        return PromptVisibility.isAncestor(
            frontmost,
            of: getpid(),
            parentOf: PromptVisibility.parentPID(of:),
            isApp: { pid in windowOwners.contains(pid) || isAppBundleProcess(pid) }
        )
    }

    private static func isAppBundleProcess(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.contains(".app/Contents/MacOS/")
    }
}

exit(PulseHookEntry.main())

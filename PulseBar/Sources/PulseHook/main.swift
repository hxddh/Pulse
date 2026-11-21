import AppKit
import Darwin
import Foundation
import PulseKit

/// Lightweight native hook receiver (`Pulse.app/Contents/MacOS/pulse-hook`).
///
/// Links only `PulseKit`, Foundation, and AppKit (for LaunchServices' exact
/// `NSWorkspace.shared.frontmostApplication` without starting `NSApplication`
/// or touching SwiftUI/Carbon/UserNotifications) so every vendor hook event
/// runs in milliseconds with exact frontmost-app accuracy — immune to floating
/// overlays, Picture-in-Picture windows, or secondary-display layer-0 windows.
/// Always exits 0 (except `--ping` failure) so a vendor hook never blocks its
/// agent.
enum PulseHookEntry {
    static func main() -> Int32 {
        var arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--status") {
            let format: StatusCLI.Format = arguments.contains("--json")
                ? .json
                : arguments.contains("--tmux") ? .tmux : .plain
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let state = StatusCLI.loadState(nowMs: nowMs)
            let output = StatusCLI.render(state, format: format, nowMs: nowMs)
            if !output.isEmpty {
                FileHandle.standardOutput.write(Data((output + "\n").utf8))
            }
            return 0
        }
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

    /// Exact keyboard-focused application check via `NSWorkspace` (never
    /// starts `NSApplication`, never fooled by floating overlays).
    private static func promptIsFrontmost() -> Bool? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmost > 0 else {
            return nil
        }
        return PromptVisibility.isAncestor(
            frontmost,
            of: getpid(),
            parentOf: PromptVisibility.parentPID(of:),
            isApp: { pid in NSRunningApplication(processIdentifier: pid) != nil }
        )
    }
}

exit(PulseHookEntry.main())

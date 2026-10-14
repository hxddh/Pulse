import AppKit
import Darwin
import Foundation

/// The AppKit half of `PromptVisibility`: the frontmost application and
/// whether a pid is a registered application. The hook asks once per open
/// event (`PulseBarMain`, `--hook`); NSWorkspace answers without starting
/// NSApplication.
extension PromptVisibility {
    /// The frontmost application's pid, or nil when this process cannot ask.
    ///
    /// A hook invocation is a short-lived child of the agent, not a GUI app.
    /// It usually can ask; when it cannot, nil is the honest answer.
    static var frontmostPID: Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Will the vendor's prompt appear in front of whoever is at this Mac?
    ///
    /// `nil` means it could not be established — and **not knowing is never
    /// treated as proof of anything**: the `front` column is left unknown.
    static func promptIsFrontmost(
        selfPID: Int32 = getpid(),
        frontmost: Int32? = frontmostPID,
        parentOf: (Int32) -> Int32? = parentPID(of:),
        isApp: (Int32) -> Bool = isApplication(pid:)
    ) -> Bool? {
        guard let frontmost, frontmost > 0 else { return nil }
        return isAncestor(frontmost, of: selfPID, parentOf: parentOf, isApp: isApp)
    }

    /// Is `pid` a registered application (a terminal, an IDE) rather than a
    /// shell, an agent or a multiplexer server?
    static func isApplication(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid) != nil
    }
}

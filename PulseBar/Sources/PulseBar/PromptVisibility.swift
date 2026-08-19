import AppKit
import Darwin
import Foundation

/// Is the window the vendor is about to prompt in actually in front of the user?
///
/// Respond's original gate asked a cruder question — *is anyone touching this
/// Mac* — and treated "yes" as "the vendor's prompt is already in front of
/// them, Pulse has nothing better to offer". That reasoning is exactly
/// inverted in the product's own headline scene: someone in a meeting, or
/// writing a document, is very much touching this Mac while six terminal
/// windows sit behind a full-screen app. The prompt is *not* in front of them,
/// and hunting for the right window is the cost Pulse exists to remove.
///
/// The precise question is answerable without new permissions: the hook is a
/// child of the agent, which is a child of the terminal or IDE, so the
/// frontmost application is either **on this process's parent chain** or it is
/// not. No app list, no window-server poking, no Accessibility — Warp, iTerm,
/// Terminal, VS Code and Cursor all fall out of the same walk.
enum PromptVisibility {
    /// A parent chain longer than this is not a chain, it is a bug. Real ones
    /// are three or four deep (app → shell → agent → hook).
    static let maxDepth = 16

    /// Is `candidate` on `pid`'s parent chain?
    ///
    /// `nil` means **unknown** — an unreadable link, a cycle, or a chain too
    /// long to be real. Unknown is a distinct answer from "no" here, because
    /// the caller must not treat "we could not tell" as proof the user is
    /// looking elsewhere.
    ///
    /// Pure: the parent lookup is injected, so the walk can be pinned to
    /// fixtures without a process table.
    static func isAncestor(
        _ candidate: Int32,
        of pid: Int32,
        parentOf: (Int32) -> Int32?
    ) -> Bool? {
        guard candidate > 0, pid > 0 else { return nil }
        if candidate == pid { return true }
        var seen: Set<Int32> = [pid]
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentOf(current) else { return nil }
            // launchd is pid 1 and its own parent is 0 or 1; either way the
            // walk is over and the candidate was not on it.
            if parent <= 1 { return false }
            if parent == candidate { return true }
            // A pid that is its own ancestor cannot be walked. Say so rather
            // than spin or invent an answer.
            if seen.contains(parent) { return nil }
            seen.insert(parent)
            current = parent
        }
        return nil
    }

    /// One link of the real chain, from `sysctl` — no fork, no `ps`.
    static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let ok = mib.withUnsafeMutableBufferPointer { buffer -> Bool in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0) == 0
        }
        guard ok, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The frontmost application's pid, or nil when this process cannot ask.
    ///
    /// A hook invocation is a short-lived child of the agent, not a GUI app.
    /// It usually can ask; when it cannot, nil is the honest answer and the
    /// caller falls back to the older, coarser rule.
    static var frontmostPID: Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Will the vendor's prompt appear in front of whoever is at this Mac?
    ///
    /// `nil` means it could not be established — and **not knowing is never
    /// treated as proof of anything**: `RespondHold` falls back to letting the
    /// request straight through, because freezing an agent in front of a
    /// present user is a cost paid for nothing.
    static func promptIsFrontmost(
        selfPID: Int32 = getpid(),
        frontmost: Int32? = frontmostPID,
        parentOf: (Int32) -> Int32? = parentPID(of:)
    ) -> Bool? {
        guard let frontmost, frontmost > 0 else { return nil }
        return isAncestor(frontmost, of: selfPID, parentOf: parentOf)
    }
}

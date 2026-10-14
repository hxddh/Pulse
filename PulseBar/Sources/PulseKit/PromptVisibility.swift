import Darwin
import Foundation

/// Is the window the vendor is about to prompt in actually in front of the user?
///
/// The hook receiver asks this once per blocked event and records the answer
/// in attention column 8 (`front`): a prompt already on screen needs no
/// banner.
///
/// The precise question is answerable without new permissions: the hook is a
/// child of the agent, which is a child of the terminal or IDE, so the
/// frontmost application is either **on this process's parent chain** or it is
/// not. No app list, no window-server poking, no Accessibility — Warp, iTerm,
/// Terminal, VS Code and Cursor all fall out of the same walk.
///
/// The walk and the parent lookup are here; the two questions only AppKit can
/// answer — which app is frontmost, and whether a pid is an application — are
/// `PulseApp`'s (`PromptVisibility.promptIsFrontmost`), so the kernel stays
/// Foundation only.
package enum PromptVisibility {
    /// A parent chain longer than this is not a chain, it is a bug. Real ones
    /// are three or four deep (app → shell → agent → hook).
    package static let maxDepth = 16

    /// Is `candidate` on `pid`'s parent chain?
    ///
    /// `nil` means **unknown** — an unreadable link, a cycle, or a chain too
    /// long to be real. Unknown is a distinct answer from "no" here, because
    /// the caller must not treat "we could not tell" as proof the user is
    /// looking elsewhere.
    ///
    /// Pure: the parent lookup is injected, so the walk can be pinned to
    /// fixtures without a process table.
    ///
    /// A walk that reaches launchd is only a real "no" when it passed through
    /// an application on the way (`isApp`). A detached chain — the agent runs
    /// under a tmux or screen server, which is re-parented to launchd — never
    /// meets the terminal the user is actually reading it in, so reaching
    /// launchd there proves nothing and the answer is unknown.
    package static func isAncestor(
        _ candidate: Int32,
        of pid: Int32,
        parentOf: (Int32) -> Int32?,
        isApp: (Int32) -> Bool = { _ in true }
    ) -> Bool? {
        guard candidate > 0, pid > 0 else { return nil }
        if candidate == pid { return true }
        var seen: Set<Int32> = [pid]
        var current = pid
        var passedAnApp = false
        for _ in 0..<maxDepth {
            guard let parent = parentOf(current) else { return nil }
            // launchd is pid 1 and its own parent is 0 or 1; either way the
            // walk is over and the candidate was not on it.
            if parent <= 1 { return passedAnApp ? false : nil }
            if parent == candidate { return true }
            // A pid that is its own ancestor cannot be walked. Say so rather
            // than spin or invent an answer.
            if seen.contains(parent) { return nil }
            seen.insert(parent)
            if isApp(parent) { passedAnApp = true }
            current = parent
        }
        return nil
    }

    /// One link of the real chain, from `sysctl` — no fork, no `ps`.
    package static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let ok = mib.withUnsafeMutableBufferPointer { buffer -> Bool in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0) == 0
        }
        guard ok, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

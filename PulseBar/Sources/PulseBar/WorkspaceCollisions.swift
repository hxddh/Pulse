import Foundation

// 12.3: the one WorkspaceEffect rule that reads app rows stays in the app;
// the rest of WorkspaceEffect lives in PulseManaged.
extension WorkspaceEffect {
    /// Which live rows share a working copy.
    ///
    /// The fact no single agent can see: each one knows only itself, so two
    /// agents editing the same checkout is invisible from inside either. It
    /// is plainly visible from here, and it is the one thing on this axis
    /// that no other tool could report.
    ///
    /// Remote rows never take part — their path describes another machine's
    /// disk, and a collision there would be pure invention.
    static func collisionCounts(_ rows: [AgentRow]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in rows where !row.isRemote && row.liveProcess && !row.workspaceRoot.isEmpty {
            counts[row.workspaceRoot, default: 0] += 1
        }
        return counts.filter { $0.value >= 2 }
    }
}

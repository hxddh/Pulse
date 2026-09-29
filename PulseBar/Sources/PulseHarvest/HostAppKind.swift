import Foundation
import PulseCore

/// Host IDE / editor that owns an agent process (the process table's parent
/// walk, `AgentProcesses`).
///
/// Its bundle ids are what `LandingPlan` opens the session's folder in and
/// activates, on an explicit user click — never a scan-time enumeration of
/// every running application.
package enum HostAppKind: String, Equatable, Hashable, CaseIterable, Sendable {
    case cursor
    case vsCode
    case windsurf
    case zed
    case trae
    case antigravity
    case zcode

    package var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vsCode: return "VS Code"
        case .windsurf: return "Windsurf"
        case .zed: return "Zed"
        case .trae: return "Trae"
        case .antigravity: return "Antigravity"
        case .zcode: return "ZCode"
        }
    }

    /// Path fragments seen in a parent's executable path or argv.
    package var pathNeedles: [String] {
        switch self {
        case .cursor: return ["Cursor.app/"]
        case .vsCode: return [
            "Visual Studio Code.app/",
            "Code.app/Contents/MacOS/Electron",
            "Code - Insiders.app/",
        ]
        case .windsurf: return ["Windsurf.app/"]
        case .zed: return ["Zed.app/"]
        case .trae: return ["Trae.app/"]
        case .antigravity: return ["Antigravity.app/"]
        case .zcode: return ["ZCode.app/"]
        }
    }

    package var bundleIDs: [String] {
        switch self {
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        case .vsCode: return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .windsurf: return ["com.exafunction.windsurf"]
        case .zed: return ["dev.zed.Zed"]
        case .trae: return ["com.bytedance.trae"]
        case .antigravity: return ["com.antigravity.app"]
        // Electron ADE — path/open -a is primary; bundle id is best-effort.
        case .zcode: return ["ai.z.zcode", "com.zhipuai.zcode"]
        }
    }
}

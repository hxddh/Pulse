import Foundation

/// An app that hosts an agent process without a terminal of its own — an
/// editor, or an agent's own desktop app — found on the process's parent
/// chain (the process table's walk, `AgentProcesses`, and the hook's own,
/// `HookLanding.host`).
///
/// Its bundle ids are what `LandingPlan` opens the session's folder in
/// (an editor) or activates, on an explicit user click — never a scan-time
/// enumeration of every running application.
///
/// Bundle ids are each app's `CFBundleIdentifier` as the Homebrew cask
/// quits it (`uninstall quit:`) or its preferences file names it.
package enum HostAppKind: String, Equatable, Hashable, CaseIterable, Sendable {
    case cursor
    case vsCode
    case windsurf
    case zed
    case trae
    case antigravity
    case zcode
    /// OpenAI's desktop app: Codex.app, since renamed ChatGPT.app (the same
    /// `com.openai.codex`), which runs `codex app-server`.
    case codexApp
    /// Claude's desktop app, which runs Claude Code sessions itself.
    case claudeApp
    /// OpenCode's desktop client, which runs the OpenCode server.
    case openCodeApp
    /// The GitHub Copilot desktop app, which runs the Copilot harness.
    case copilotApp

    package var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vsCode: return "VS Code"
        case .windsurf: return "Windsurf"
        case .zed: return "Zed"
        case .trae: return "Trae"
        case .antigravity: return "Antigravity"
        case .zcode: return "ZCode"
        case .codexApp: return "Codex"
        case .claudeApp: return "Claude"
        case .openCodeApp: return "OpenCode"
        case .copilotApp: return "GitHub Copilot"
        }
    }

    /// An editor is told to open the session's folder (`open -b`); an
    /// agent's own app is only brought forward — it has no folder to open.
    package var opensFolders: Bool {
        switch self {
        case .cursor, .vsCode, .windsurf, .zed, .trae, .antigravity, .zcode: return true
        case .codexApp, .claudeApp, .openCodeApp, .copilotApp: return false
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
        case .trae: return ["Trae.app/", "Trae CN.app/"]
        // The agent manager and the IDE are two apps.
        case .antigravity: return ["Antigravity.app/", "Antigravity IDE.app/"]
        case .zcode: return ["ZCode.app/"]
        case .codexApp: return ["Codex.app/", "ChatGPT.app/"]
        case .claudeApp: return ["Claude.app/"]
        case .openCodeApp: return ["OpenCode.app/"]
        case .copilotApp: return ["GitHub Copilot.app/"]
        }
    }

    package var bundleIDs: [String] {
        switch self {
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        case .vsCode: return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .windsurf: return ["com.exafunction.windsurf"]
        case .zed: return ["dev.zed.Zed"]
        case .trae: return ["com.trae.app", "cn.trae.app", "com.bytedance.trae"]
        case .antigravity: return ["com.google.antigravity", "com.google.antigravity-ide"]
        // Electron ADE — path/open -a is primary; bundle id is best-effort.
        case .zcode: return ["ai.z.zcode", "com.zhipuai.zcode"]
        // ChatGPT.app kept Codex.app's id; the older ChatGPT app is
        // `com.openai.chat`.
        case .codexApp: return ["com.openai.codex", "com.openai.chat"]
        case .claudeApp: return ["com.anthropic.claudefordesktop"]
        case .openCodeApp: return ["ai.opencode.desktop"]
        case .copilotApp: return ["com.github.githubapp"]
        }
    }

    /// The host whose bundle id this is.
    package init?(bundleID: String) {
        guard !bundleID.isEmpty,
              let kind = Self.allCases.first(where: { $0.bundleIDs.contains(bundleID) })
        else { return nil }
        self = kind
    }

    /// The host whose bundle a path (an executable, or a whole command
    /// line) runs from.
    package init?(path: String) {
        guard let kind = Self.allCases.first(where: { kind in kind.pathNeedles.contains { path.contains($0) } })
        else { return nil }
        self = kind
    }
}

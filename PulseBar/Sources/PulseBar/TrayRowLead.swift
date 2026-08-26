import Foundation

/// 7.0-γ — the collapsed row's lead, chosen by value (scene BL).
///
/// The verdict this version answers: "弹窗有效信息太少". The old hero was a
/// static task title — identity, not news. The most valuable single line a
/// row can carry, in order: what the agent is doing RIGHT NOW is already the
/// story line's job, so the hero's job is **what the agent last said** —
/// fresh words beat a title the user has read twenty times. The title is not
/// lost: it lives in the expanded card and the workbench.
///
/// Pure and exhaustively pinned by tests; `AgentRowButton.heroTitle` only
/// maps the chosen source to its string. Waiting and process-only rows keep
/// every rule they had — this ordering change is for live session rows only.
enum TrayRowLead {

    enum Source: Equatable {
        // Waiting rows: unchanged from 2.x — the task (or project) is what
        // the user must recognize to answer.
        case waitTask
        case waitProject
        case needsYou
        // Process-only rows: unchanged status phrases.
        case processTerminal
        case processApp
        // Live session rows, by value:
        /// The agent's latest words, fresh under the self-report window.
        case freshWords
        case task
        case toolTitle
        case project
        case terminalSession
        case appSession
    }

    static func source(
        waiting: Bool,
        isProcessOnly: Bool,
        canFocusTerminal: Bool,
        hasTask: Bool,
        hasProject: Bool,
        freshWords: Bool,
        hasToolTitle: Bool
    ) -> Source {
        if waiting {
            if hasTask { return .waitTask }
            if hasProject { return .waitProject }
            return .needsYou
        }
        if isProcessOnly {
            return canFocusTerminal ? .processTerminal : .processApp
        }
        // 7.0: value first. Fresh words outrank the static title.
        if freshWords { return .freshWords }
        if hasTask { return .task }
        if hasToolTitle { return .toolTitle }
        if hasProject { return .project }
        return canFocusTerminal ? .terminalSession : .appSession
    }
}

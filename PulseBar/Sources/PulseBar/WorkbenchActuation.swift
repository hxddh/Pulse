import AppKit

/// 4.0-β — delivery, not copying (scenes BE/BF). 3.0's "answer" handed the
/// user a command to paste; the judgment invariant never demanded that. What
/// it demands is that **the text is the user's and the decision to send is
/// the user's click** — the finger work in between was always Pulse's to do.
///
/// Two verbs, one grant:
///
/// - **Send** (scene BE): the user's written reply is typed into the exact
///   terminal tab that owns the session, then Return. Typing goes to
///   whatever is focused, so the precision gate is absolute: only a row
///   whose focus tier is `.tty` — a tab Pulse can select by its tty device —
///   may take a typed delivery. App-level focus (Warp, an IDE) cannot
///   guarantee the keystrokes land in the right place, and a reply typed
///   into the wrong window is the failure this gate exists for. Those rows
///   keep the clipboard path.
/// - **Dispatch** (scene BF): a new session started in a chosen repository
///   root — `cd <root> && claude '<task>'` in a fresh Terminal window.
///
/// Both live behind `allowWorkbenchActuation`, off by default; the switch is
/// the consent and turning it off stops everything instantly. Every exit is
/// visible. Real-machine verification: `scripts/qa_workbench_actuation.sh`.
enum WorkbenchActuation {

    enum DeliveryOutcome: Equatable {
        case delivered
        /// The reply was empty after collapsing — nothing to send.
        case refused
        /// No Terminal/iTerm tab answered to that tty. Nothing was typed.
        case noTab
        /// The tab was selected but the keystroke script failed (most likely
        /// the Automation/Accessibility grant for System Events).
        case typeFailed
    }

    static let maxReplyChars = 2_000

    // MARK: - Pure pieces (pinned by tests)

    /// One line out, always: a terminal submits on every newline, so an
    /// embedded newline would send a half-written reply. Collapsed, not
    /// rejected — and bounded, because keystroke delivery is per-character.
    static func collapsedReply(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxReplyChars else { return collapsed }
        return String(collapsed.prefix(maxReplyChars))
    }

    /// AppleScript string literal: backslashes first, then quotes.
    static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    /// The dispatch command, built with the same POSIX quoting the resume
    /// command uses. Nil when the root fails the shape gate — a relative or
    /// trivial path never reaches a shell. Empty task starts a bare session.
    static func dispatchCommand(root: String, task: String) -> String? {
        guard TerminalFocus.isAbsoluteWorkspacePath(root) else { return nil }
        var command = "cd \(WorkbenchAnswer.shellQuoted(root)) && claude"
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            command += " " + WorkbenchAnswer.shellQuoted(trimmed)
        }
        return command
    }

    // MARK: - The two verbs

    /// Select the exact tab, then type. Never types without the selection
    /// having succeeded — order is the safety property here.
    static func deliver(reply: String, tty: String) -> DeliveryOutcome {
        let text = collapsedReply(reply)
        guard !text.isEmpty else { return .refused }
        guard TerminalFocus.focusTTY(tty) else { return .noTab }
        let script = """
        tell application "System Events"
          keystroke \(appleScriptQuoted(text))
          key code 36
        end tell
        return true
        """
        return TerminalFocus.osascriptBool(script) ? .delivered : .typeFailed
    }

    /// A fresh Terminal window in the chosen root. The directory's existence
    /// was checked by the caller against the live filesystem; this only
    /// refuses shapes that should never reach a shell.
    static func dispatch(root: String, task: String) -> Bool {
        guard let command = dispatchCommand(root: root, task: task) else { return false }
        let script = """
        tell application "Terminal"
          activate
          do script \(appleScriptQuoted(command))
        end tell
        return true
        """
        return TerminalFocus.osascriptBool(script)
    }
}

extension StatusStore {
    /// The precision gate, readable from the view: an exact tab identity and
    /// the actuation grant, nothing less.
    func workbenchCanType(_ row: AgentRow) -> Bool {
        guard allowWorkbenchActuation, !row.isRemote else { return false }
        if case .tty = row.focusTier { return true }
        return false
    }

    /// Send the user's reply into the session. Every exit lands on the row.
    func sendReply(_ row: AgentRow, text: String) {
        guard workbenchCanType(row) else {
            noteRowAction(row.rowKey, tr(.workbenchSendRefused))
            return
        }
        let outcome = WorkbenchActuation.deliver(reply: text, tty: row.tty)
        DebugLog.write("workbench deliver key=\(row.rowKey) outcome=\(outcome)")
        switch outcome {
        case .delivered: noteRowAction(row.rowKey, tr(.workbenchSent))
        case .refused: noteRowAction(row.rowKey, tr(.workbenchSendRefused))
        case .noTab: noteRowAction(row.rowKey, tr(.workbenchSendNoTab))
        case .typeFailed: noteRowAction(row.rowKey, tr(.workbenchSendFailed))
        }
    }

    /// Repository roots the fleet is actually working in — the honest picker
    /// for dispatch. Disk-confirmed local roots only, newest rows first,
    /// deduplicated.
    var workbenchDispatchRoots: [String] {
        var seen = Set<String>()
        var roots: [String] = []
        // Managed rows excluded: their root is a Pulse-created worktree, and
        // a worktree of a worktree is nesting nobody asked for.
        for row in allRows where !row.isRemote && !row.isManaged && !row.workspaceRoot.isEmpty {
            if seen.insert(row.workspaceRoot).inserted {
                roots.append(row.workspaceRoot)
            }
        }
        return roots
    }

    /// Start a new session. Returns whether the terminal accepted the
    /// command — the session itself will appear as a row once the collector
    /// sees it, and Pulse does not pretend otherwise.
    func dispatchSession(root: String, task: String) -> Bool {
        guard allowWorkbenchActuation else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir),
              isDir.boolValue
        else { return false }
        let accepted = WorkbenchActuation.dispatch(root: root, task: task)
        DebugLog.write("workbench dispatch root=\(root.hashValue) accepted=\(accepted)")
        return accepted
    }
}

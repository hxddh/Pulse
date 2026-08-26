import AppKit

/// 3.0 — the answer verb (scenes BB/BC). The workbench stops being a viewer
/// here: a waiting row can be answered where it is read.
///
/// Two channels, and they never blur:
///
/// - **Respond** (scene AR/AU): a full permission request is attached, so the
///   existing verdict machinery — HMAC, single-use, `canOfferAllow`, fail-open
///   — carries the answer. Nothing new is invented; the workbench merely
///   embeds the same card Details shows.
/// - **Resume**: a question or idle prompt on a local Claude session. The
///   conservative first version promised in `docs/plan-3.0.md`: Pulse builds
///   the exact `claude --resume <session>` command, puts it on the clipboard,
///   and brings the terminal forward. **Pulse never runs it.** Pasting and
///   pressing Enter stays in the user's hands — that keystroke is the
///   judgment the invariant refuses to transfer, and it doubles as the
///   real-machine verification `--resume` has not had yet.
enum WorkbenchAnswer {
    /// What the workbench may honestly offer a waiting row right now.
    enum Channel: Equatable {
        /// A digest-verified full request is attached — the Respond card.
        case respond
        /// A local resumable session — build the command, hand it over.
        case resume
        /// Waiting, but no channel this version can offer beyond the
        /// existing actions (focus / dismiss / snooze). Never pretend.
        case focusOnly
    }

    /// Agents whose `--resume <session-id>` semantics this version trusts
    /// enough to prefill. One entry on purpose: other CLIs' resume flags are
    /// unverified guesses, and a wrong command in the user's terminal is
    /// worse than no button.
    static let resumableAgents: Set<AgentID> = [.claude]

    /// Pure so tests can pin the routing without seeding a snapshot.
    static func channel(
        agent: AgentID,
        isRemote: Bool,
        waiting: Bool,
        waitKind: String,
        sessionID: String,
        hasRespondRequest: Bool
    ) -> Channel? {
        guard waiting else { return nil }
        // A full request always wins: it is the only channel with a receipt.
        if hasRespondRequest { return .respond }
        // A remote session's terminal is on another machine; a prefilled
        // command here would resume nothing.
        guard !isRemote else { return .focusOnly }
        // A permission wait without an attached request means the vendor's
        // own prompt is already in front of the user — the verb there is
        // focus, not a second answer box racing the real one.
        guard waitKind != "Permission" else { return .focusOnly }
        guard resumableAgents.contains(agent), validSessionID(sessionID) else {
            return .focusOnly
        }
        return .resume
    }

    /// Shape gate before a session id may enter a command line. Vendor ids
    /// are UUIDs; anything outside this alphabet is either corruption or an
    /// attempt to ride the command, and both get the same answer.
    static func validSessionID(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 128 else { return false }
        return raw.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == ".")
        }
    }

    /// The exact command the user will run — built here, executed nowhere.
    /// A non-empty reply rides along as a single-quoted argument; empty means
    /// the user prefers to type in the terminal, and the command just resumes.
    static func resumeCommand(sessionID: String, answer: String) -> String? {
        guard validSessionID(sessionID) else { return nil }
        let reply = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        var command = "claude --resume \(sessionID)"
        if !reply.isEmpty {
            command += " " + shellQuoted(reply)
        }
        return command
    }

    /// POSIX single-quoting: inside `'…'` every metacharacter is literal, and
    /// the one character that is not — the quote itself — becomes `'\''`.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension StatusStore {
    /// The routing above, fed from a live row.
    func workbenchAnswerChannel(_ row: AgentRow) -> WorkbenchAnswer.Channel? {
        WorkbenchAnswer.channel(
            agent: row.agent,
            isRemote: row.isRemote,
            waiting: row.waiting,
            waitKind: row.waitKind,
            sessionID: row.sessionID,
            hasRespondRequest: respondRequest(for: row) != nil
        )
    }

    /// Copy the resume command and bring the terminal forward. Every exit is
    /// visible on the row (the Respond lesson: a button that silently does
    /// nothing is indistinguishable from a broken one).
    func copyResumeCommand(_ row: AgentRow, answer: String) {
        guard let command = WorkbenchAnswer.resumeCommand(
            sessionID: row.sessionID, answer: answer
        ) else {
            noteRowAction(row.rowKey, tr(.workbenchAnswerRefused))
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        let focused = row.canFocusTerminal ? TerminalFocus.focus(row: row) : false
        DebugLog.write("workbench resume copied key=\(row.rowKey) focused=\(focused)")
        noteRowAction(row.rowKey, tr(.workbenchAnswerCopied))
    }
}

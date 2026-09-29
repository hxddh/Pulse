import AppKit

/// 24.0 · runs a `LandingPlan` on an explicit click. The plan decided what
/// to try (pure, `LandingPlan.make`); this only does it, in order, and says
/// how precisely it landed. Nothing here enumerates running apps.
enum TerminalFocus {
    /// Try each step; the first that succeeds sets the outcome.
    @discardableResult
    static func land(_ plan: LandingPlan) -> LandingOutcome {
        for step in plan.steps where run(step) {
            return step.precision == .exact ? .exact : .appOnly
        }
        return .failed
    }

    static func run(_ step: LandingStep) -> Bool {
        switch step {
        case .tmuxPane(let pane, let socket, let hostBundleIDs):
            return focusTmuxPane(pane, socket: socket, hostBundleIDs: hostBundleIDs)
        case .iTermSession(let uniqueID):
            return isRunning(LandingPlan.iTermBundleID)
                && osascriptBool(iTermSessionScript(uniqueID: uniqueID), timeout: focusScriptTimeout)
        case .ttyTab(let tty):
            return focusTTY(tty)
        case .openFolder(let bundleIDs, let path):
            return openFolder(path, bundleIDs: bundleIDs)
        case .activateApp(let bundleIDs):
            return activateRunning(bundleIDs)
        case .activateOwner(let pid):
            return activateOwner(of: pid)
        }
    }

    // MARK: - tmux

    static let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    /// Select the pane, then bring forward the app hosting a client that
    /// shows its session. The pane selected with no app in front is not a
    /// landing: the person still sees whatever was there.
    private static func focusTmuxPane(_ pane: String, socket: String, hostBundleIDs: [String]) -> Bool {
        guard let tmux = tmuxPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let selected = ProcessIO.run(
                  executable: tmux,
                  arguments: LandingPlan.tmuxArguments(pane: pane, socket: socket),
                  timeout: 2,
                  outputLimit: 16 * 1024
              ),
              !selected.timedOut, selected.status == 0
        else { return false }
        let session = String(decoding: selected.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var listArgs: [String] = socket.isEmpty ? [] : ["-S", socket]
        listArgs += ["list-clients", "-F", "#{session_id} #{client_pid}"]
        if !session.isEmpty,
           let clients = ProcessIO.run(executable: tmux, arguments: listArgs, timeout: 2, outputLimit: 16 * 1024),
           !clients.timedOut, clients.status == 0 {
            let lines = String(decoding: clients.stdout, as: UTF8.self).split(separator: "\n")
            for line in lines {
                let fields = line.split(separator: " ")
                guard fields.count == 2, fields[0] == session, let pid = Int32(fields[1]) else { continue }
                if activateOwner(of: pid) { return true }
            }
        }
        return activateRunning(hostBundleIDs)
    }

    // MARK: - Apps

    /// A running app, by bundle id. A terminal that is not running cannot
    /// hold the session, so nothing is launched.
    private static func activateRunning(_ bundleIDs: [String]) -> Bool {
        for bid in bundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
               app.activate() {
                return true
            }
        }
        return false
    }

    /// The first regular app on the process's parent chain.
    private static func activateOwner(of pid: Int32) -> Bool {
        var current = pid
        var seen: Set<Int32> = []
        for _ in 0..<HookLanding.maxDepth {
            guard current > 1, !seen.contains(current) else { return false }
            seen.insert(current)
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular {
                return app.activate()
            }
            guard let parent = PromptVisibility.parentPID(of: current) else { return false }
            current = parent
        }
        return false
    }

    /// `open -b <bundle> <folder>` — no Automation TCC; lands on the folder in
    /// that editor. Focus runs on the main thread from a click, so this call
    /// needs a deadline: a host app slow to launch, or stuck behind its own
    /// dialog, would otherwise freeze the menu bar.
    private static func openFolder(_ path: String, bundleIDs: [String]) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        for bid in bundleIDs {
            guard let result = ProcessIO.run(
                executable: "/usr/bin/open",
                arguments: ["-b", bid, path],
                timeout: 5
            ) else { continue }
            if !result.timedOut, result.status == 0 { return true }
        }
        return false
    }

    /// Terminal / iTerm tab select — only called after Automation opt-in + click.
    ///
    /// Only a terminal that is already running is asked: `tell application`
    /// launches an app that is not, so a click meant for iTerm used to open
    /// Terminal.app (and the other way round) just to search it for a tab it
    /// could not have. Each script activates its app only on a match.
    static func focusTTY(_ raw: String) -> Bool {
        let tty = LandingHandle.normalizeTTY(raw)
        guard !tty.isEmpty else { return false }
        if isRunning(LandingPlan.terminalBundleID), focusTerminalAppTTY(tty) { return true }
        if isRunning(LandingPlan.iTermBundleID), focusITermTTY(tty) { return true }
        return false
    }

    /// A tab search that has not answered in this long will not; the click
    /// reports "not reached" instead of freezing the menu bar.
    static let focusScriptTimeout: TimeInterval = 5

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func focusTerminalAppTTY(_ tty: String) -> Bool {
        osascriptBool(terminalTabScript(tty: tty), timeout: focusScriptTimeout)
    }

    private static func focusITermTTY(_ tty: String) -> Bool {
        osascriptBool(iTermTabScript(tty: tty), timeout: focusScriptTimeout)
    }

    /// The Terminal.app tab search. Internal so a test can hold the rule
    /// that `activate` runs only on a match.
    static func terminalTabScript(tty: String) -> String {
        let escaped = tty.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                set ttyName to (tty of t as text)
                if ttyName contains "\(escaped)" then
                  set selected of t to true
                  set frontmost of w to true
                  activate
                  return true
                end if
              end try
            end repeat
          end repeat
        end tell
        return false
        """
    }

    /// The iTerm tab search; same rule.
    static func iTermTabScript(tty: String) -> String {
        let escaped = tty.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "iTerm"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  set ttyName to (tty of s as text)
                  if ttyName contains "\(escaped)" then
                    select w
                    select t
                    activate
                    return true
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        return false
        """
    }

    /// iTerm2's session by `unique id` (the part of `ITERM_SESSION_ID` after
    /// the colon) — only called after Automation opt-in + click, only when
    /// iTerm is running; activates only on a match.
    static func iTermSessionScript(uniqueID: String) -> String {
        let escaped = uniqueID.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "iTerm"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  if (unique id of s as text) is "\(escaped)" then
                    select w
                    select t
                    select s
                    activate
                    return true
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        return false
        """
    }

    /// Internal since 4.0-β for the same reason as `focusTTY`.
    ///
    /// Bounded: `ProcessIO.run` drains both pipes and kills the child at the
    /// deadline, so a scripted app that never answers cannot hang the caller.
    /// The default is generous for callers that type text; the tab search
    /// passes `focusScriptTimeout`.
    static func osascriptBool(_ source: String, timeout: TimeInterval = 30) -> Bool {
        guard let result = ProcessIO.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", source],
            timeout: timeout,
            outputLimit: 64 * 1024
        ), !result.timedOut, result.status == 0 else { return false }
        let text = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return text.contains("true")
    }
}

/// Reveal the app-owned panel directly.
///
/// This intentionally has no Accessibility or Apple Events fallback. The
/// shortcut and notification actions call the panel controller owned by this
/// process, so they cannot trigger an Automation permission prompt.
///
/// Prefer `StatusStore.requestTrayReveal(rowKey:)` when a concrete Waiting row
/// should be selected after open (Go-Look Closure).
enum TrayReveal {
    static func show() {
        Task { @MainActor in
            StatusPanelController.shared?.show()
        }
    }

    /// 23.0: the global shortcut — open closes, closed opens with the most
    /// urgent row selected.
    static func toggle() {
        Task { @MainActor in
            StatusPanelController.shared?.toggleFromHotkey()
        }
    }
}

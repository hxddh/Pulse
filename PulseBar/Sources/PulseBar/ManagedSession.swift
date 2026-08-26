import Foundation

// 5.0-β — the managed runtime's pure core (docs/plan-5.0.md, scene BG).
//
// A managed session is a turn loop over the vendor's own headless interface:
// `claude -p <prompt> --output-format stream-json --verbose`, continued with
// `--resume <session-id>`. Pure pipes — no PTY, no AppleScript, no TCC.
// Everything in this file is deterministic and fixture-testable: the argv a
// turn runs, the NDJSON line reassembly, and the state machine that turns
// stream events into session facts. The process handling lives in
// `ManagedSessionRunner`; nothing here touches a process.
//
// Epistemically these facts are FIRST-PARTY: Pulse spawned the process and
// owns its stream, so there is no "not measured" discount and no sanitizer-
// vs-source ambiguity — but transcript text is still model output, so every
// rendered string passes the same `ContentSanitizer` discipline (via
// `TranscriptReader.entries(from:)`, which already parses these exact
// message shapes).
enum ManagedSession {

    /// Where a session stands. `idle` means the turn finished and the next
    /// word is the user's — deliberately NOT a tray Waiting (the plan keeps
    /// the attention protocol as Waiting's only source; a managed reply
    /// prompt lives in the workbench).
    enum Status: Equatable {
        case idle
        case running
        case failed(String)
        case cancelled
        /// 6.0-α: dispatched, waiting for a fleet slot. The first prompt is
        /// held by the fleet and sent when a slot frees.
        case queued
        /// 6.0-α: the app quit (or died) while a turn was running. Neither a
        /// failure nor a completion — the honest name for "we don't know how
        /// that turn ended". The conversation survives; a reply resumes.
        case interrupted
    }

    static let maxTitleLength = 160
    static let maxResultLength = 500
    static let maxEntries = 1_000

    /// The whole session as a value: the runner mutates it via `apply`,
    /// views render it, tests drive it line by line.
    struct Model: Equatable {
        let id: String
        var title: String
        var root: String
        var isWorktree: Bool
        var startedMs: Int64

        var claudeSessionID = ""
        var modelName = ""
        var status: Status = .idle
        var entries: [TranscriptReader.Entry] = []
        var entriesCapped = false
        var currentTool = ""
        var turns = 0
        var errorResults = 0
        var totalCostUSD: Double = 0
        var tokensIn = 0
        var tokensOut = 0
        var lastEventMs: Int64 = 0
        var lastResultText = ""
        var lastErrorText = ""
        /// Stream lines that parsed as JSON but matched no known event type.
        /// Counted, never guessed at — the TranscriptReader rule.
        var unknownEvents = 0
        /// Lines that were not JSON objects at all.
        var unparsedLines = 0
        /// 6.0-α · the first prompt, held while the session waits for a
        /// fleet slot. Cleared when the turn actually starts; persisted so a
        /// queued session survives a restart with its task intact.
        var pendingPrompt = ""
        /// 6.0-γ · the run-check command this session uses (persisted).
        var runCommand = ""
        /// 6.0-γ · same-task attempt group id (empty = standalone).
        var attemptGroup = ""
        /// 6.0-γ · what the last finished turn left on disk (+insertions,
        /// −deletions); nil until a turn has been measured.
        var lastTurnEffect: (insertions: Int, deletions: Int)?

        static func == (lhs: Model, rhs: Model) -> Bool {
            State(model: lhs) == State(model: rhs)
                && lhs.unknownEvents == rhs.unknownEvents
                && lhs.unparsedLines == rhs.unparsedLines
                && lhs.currentTool == rhs.currentTool
                && lhs.lastTurnEffect?.insertions == rhs.lastTurnEffect?.insertions
                && lhs.lastTurnEffect?.deletions == rhs.lastTurnEffect?.deletions
        }

        init(id: String, task: String, root: String, isWorktree: Bool, nowMs: Int64) {
            self.id = id
            let firstLine = task.split(separator: "\n").first.map(String.init) ?? task
            let cleaned = ContentSanitizer.redact(firstLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.title = cleaned.count > ManagedSession.maxTitleLength
                ? String(cleaned.prefix(ManagedSession.maxTitleLength)) + "…"
                : cleaned
            self.root = root
            self.isWorktree = isWorktree
            self.startedMs = nowMs
        }

        /// One stream line, already split by `LineBuffer`.
        mutating func apply(line: Data, nowMs: Int64) {
            lastEventMs = nowMs
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                unparsedLines += 1
                return
            }
            apply(event: object, nowMs: nowMs)
        }

        mutating func apply(event object: [String: Any], nowMs: Int64) {
            let type = (object["type"] as? String) ?? ""
            if let sid = object["session_id"] as? String, !sid.isEmpty,
               claudeSessionID.isEmpty {
                claudeSessionID = sid
            }
            switch type {
            case "system":
                if let model = object["model"] as? String, !model.isEmpty {
                    modelName = model
                }
            case "assistant", "user":
                // The exact shapes TranscriptReader already parses, sanitizes
                // and bounds — one parser for observed files and the managed
                // stream, so the two can never drift apart.
                let new = TranscriptReader.entries(from: object)
                appendEntries(new)
                for entry in new where entry.kind == .tool {
                    if !entry.toolName.isEmpty { currentTool = entry.toolName }
                    if entry.isError, !entry.text.isEmpty { lastErrorText = entry.text }
                }
            case "result":
                turns += 1
                currentTool = ""
                if let cost = object["total_cost_usd"] as? Double { totalCostUSD += cost }
                if let usage = object["usage"] as? [String: Any] {
                    if let n = usage["input_tokens"] as? Int { tokensIn += n }
                    if let n = usage["output_tokens"] as? Int { tokensOut += n }
                }
                let text = bound((object["result"] as? String) ?? "", ManagedSession.maxResultLength)
                if !text.isEmpty { lastResultText = ContentSanitizer.redact(text) }
                let isError = (object["is_error"] as? Bool) ?? false
                if isError {
                    errorResults += 1
                    let subtype = (object["subtype"] as? String) ?? "error"
                    lastErrorText = lastResultText.isEmpty ? subtype : lastResultText
                    status = .failed(subtype)
                } else {
                    status = .idle
                }
            default:
                unknownEvents += 1
            }
        }

        private mutating func appendEntries(_ new: [TranscriptReader.Entry]) {
            guard !new.isEmpty else { return }
            entries.append(contentsOf: new)
            if entries.count > ManagedSession.maxEntries {
                entries.removeFirst(entries.count - ManagedSession.maxEntries)
                entriesCapped = true
            }
        }

        /// The agent's latest words, for the row.
        var lastAgentText: String {
            entries.last(where: { $0.kind == .agent })?.text ?? ""
        }

        private func bound(_ text: String, _ limit: Int) -> String {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > limit ? String(t.prefix(limit)) + "…" : t
        }
    }

    // MARK: - The command a turn runs

    /// Argv, never a shell string: the prompt travels as one argument and no
    /// quoting layer exists to escape from. A resume id passes the same
    /// shape gate the 3.0 resume command used; a bad one refuses the turn
    /// rather than improvising a fresh session under the user's reply.
    static func arguments(
        prompt: String,
        resumeSessionID: String?,
        permissionConfigPath: String? = nil
    ) -> [String]? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var args = ["-p", trimmed, "--output-format", "stream-json", "--verbose"]
        if let sid = resumeSessionID, !sid.isEmpty {
            guard WorkbenchAnswer.validSessionID(sid) else { return nil }
            args += ["--resume", sid]
        }
        // 6.0-β: the permission channel — the CLI asks Pulse's own MCP
        // server instead of silently denying un-allow-listed tools.
        if let configPath = permissionConfigPath {
            args += ["--mcp-config", configPath,
                     "--permission-prompt-tool", "mcp__pulse__approve"]
        }
        return args
    }

    /// Where the `claude` CLI lives on this machine, if anywhere. Checked at
    /// dispatch time so the answer is current, surfaced honestly when absent.
    static func claudeExecutable(
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
        ]
        return candidates.first(where: fileExists)
    }

    // MARK: - Persistence (6.0-α)

    /// The on-disk shape of a session. A DTO rather than making `Model`
    /// itself Codable: the status enum flattens to kind+detail here, and the
    /// file format stays decoupled from in-memory evolution.
    struct State: Codable, Equatable {
        var id: String
        var title: String
        var root: String
        var isWorktree: Bool
        var startedMs: Int64
        var claudeSessionID: String
        var modelName: String
        var statusKind: String
        var statusDetail: String
        var entries: [TranscriptReader.Entry]
        var entriesCapped: Bool
        var turns: Int
        var errorResults: Int
        var totalCostUSD: Double
        var tokensIn: Int
        var tokensOut: Int
        var lastEventMs: Int64
        var lastResultText: String
        var lastErrorText: String
        var pendingPrompt: String = ""
        /// 6.0-γ · the per-session run-check command, remembered.
        var runCommand: String = ""
        /// 6.0-γ · same-task attempt group (empty = standalone).
        var attemptGroup: String = ""

        init(model: Model) {
            id = model.id
            title = model.title
            root = model.root
            isWorktree = model.isWorktree
            startedMs = model.startedMs
            claudeSessionID = model.claudeSessionID
            modelName = model.modelName
            switch model.status {
            case .idle: statusKind = "idle"; statusDetail = ""
            case .running: statusKind = "running"; statusDetail = ""
            case .failed(let reason): statusKind = "failed"; statusDetail = reason
            case .cancelled: statusKind = "cancelled"; statusDetail = ""
            case .queued: statusKind = "queued"; statusDetail = ""
            case .interrupted: statusKind = "interrupted"; statusDetail = ""
            }
            entries = model.entries
            entriesCapped = model.entriesCapped
            turns = model.turns
            errorResults = model.errorResults
            totalCostUSD = model.totalCostUSD
            tokensIn = model.tokensIn
            tokensOut = model.tokensOut
            lastEventMs = model.lastEventMs
            lastResultText = model.lastResultText
            lastErrorText = model.lastErrorText
            pendingPrompt = model.pendingPrompt
            runCommand = model.runCommand
            attemptGroup = model.attemptGroup
        }

        /// Reattach. A state persisted mid-turn ("running") comes back as
        /// `interrupted` — we were not there to see how that turn ended, and
        /// saying anything else would be inventing an outcome. A queued
        /// session comes back queued (the fleet re-pumps it).
        func model() -> Model {
            var m = Model(id: id, task: title, root: root, isWorktree: isWorktree, nowMs: startedMs)
            m.title = title
            m.claudeSessionID = claudeSessionID
            m.modelName = modelName
            switch statusKind {
            case "running": m.status = .interrupted
            case "failed": m.status = .failed(statusDetail)
            case "cancelled": m.status = .cancelled
            case "queued": m.status = .queued
            case "interrupted": m.status = .interrupted
            default: m.status = .idle
            }
            m.entries = entries
            m.entriesCapped = entriesCapped
            m.turns = turns
            m.errorResults = errorResults
            m.totalCostUSD = totalCostUSD
            m.tokensIn = tokensIn
            m.tokensOut = tokensOut
            m.lastEventMs = lastEventMs
            m.lastResultText = lastResultText
            m.lastErrorText = lastErrorText
            m.pendingPrompt = pendingPrompt
            m.runCommand = runCommand
            m.attemptGroup = attemptGroup
            return m
        }
    }

    /// `~/Library/Application Support/Pulse/managed` — overridable for tests.
    static var stateDirectoryOverride: URL?
    static func stateDirectory() -> URL {
        if let stateDirectoryOverride { return stateDirectoryOverride }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Pulse/managed", isDirectory: true)
    }

    static func stateURL(id: String) -> URL {
        stateDirectory().appendingPathComponent(id + ".json")
    }

    /// 0600 via PrivateFile — the conversation is the user's own words.
    @discardableResult
    static func persist(_ model: Model) -> Bool {
        try? FileManager.default.createDirectory(
            at: stateDirectory(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(State(model: model)) else { return false }
        return PrivateFile.write(data, to: stateURL(id: model.id))
    }

    static func loadAll() -> [Model] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: stateDirectory().path
        ) else { return [] }
        var models: [Model] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: stateDirectory().appendingPathComponent(name)),
                  let state = try? JSONDecoder().decode(State.self, from: data),
                  // Filename decides identity — the spool rule, here too.
                  name == state.id + ".json"
            else { continue }
            models.append(state.model())
        }
        return models.sorted { $0.startedMs < $1.startedMs }
    }

    static func removeState(id: String) {
        try? FileManager.default.removeItem(at: stateURL(id: id))
    }

    // MARK: - NDJSON reassembly

    /// A pipe hands over chunks, not lines; a JSON event split across two
    /// chunks must not be counted as two broken ones. Carries the unfinished
    /// tail until its newline arrives.
    struct LineBuffer {
        private var carry = Data()

        mutating func lines(from chunk: Data) -> [Data] {
            carry.append(chunk)
            var out: [Data] = []
            while let newline = carry.firstIndex(of: 0x0A) {
                let line = carry.subdata(in: carry.startIndex..<newline)
                carry.removeSubrange(carry.startIndex...newline)
                if !line.isEmpty { out.append(line) }
            }
            return out
        }

        /// End of stream: whatever is left is a whole line if non-empty.
        mutating func flush() -> Data? {
            defer { carry = Data() }
            return carry.isEmpty ? nil : carry
        }
    }
}

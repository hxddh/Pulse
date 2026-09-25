import Foundation
import PulseCore

// 5.0-β — the managed runtime's pure core (docs/plan-5.0.md, scene BG).
//
// A managed session is the vendor-neutral value model above `ManagedRuntime`:
// runtime events become durable session facts here; process topology and wire
// decoding live behind the runtime session boundary.
//
// Epistemically these facts are FIRST-PARTY: Pulse spawned the process and
// owns its stream, so there is no "not measured" discount and no sanitizer-
// vs-source ambiguity — but transcript text is still model output, so every
// rendered string passes the same `ContentSanitizer` discipline (via
// `TranscriptReader.entries(from:)`, which already parses these exact
// message shapes).
package enum ManagedSession {

    /// Where a session stands. `idle` means the turn finished and the next
    /// word is the user's — deliberately NOT a tray Waiting (the plan keeps
    /// the attention protocol as Waiting's only source; a managed reply
    /// prompt lives in the workbench).
    package enum Status: Equatable {
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

    package static let maxTitleLength = 160
    package static let maxResultLength = 500
    package static let maxEntries = 1_000
    package static let maxAcceptanceEvidence = 20

    /// The whole session as a value: the runner mutates it via `apply`,
    /// views render it, tests drive it line by line.
    package struct Model: Equatable {
        package let id: String
        package var title: String
        package var root: String
        package var isWorktree: Bool
        package var startedMs: Int64

        package var runtimeID = "claude"
        package var continuationID = ""
        package var modelName = ""
        package var status: Status = .idle
        package var entries: [TranscriptReader.Entry] = []
        package var entriesCapped = false
        package var currentTool = ""
        package var turns = 0
        package var errorResults = 0
        package var totalCostUSD: Double = 0
        package var tokensIn = 0
        package var tokensOut = 0
        package var lastEventMs: Int64 = 0
        package var lastResultText = ""
        package var lastErrorText = ""
        /// Stream lines that parsed as JSON but matched no known event type.
        /// Counted, never guessed at — the TranscriptReader rule.
        package var unknownEvents = 0
        /// Lines that were not JSON objects at all.
        package var unparsedLines = 0
        /// 6.0-α · the first prompt, held while the session waits for a
        /// fleet slot. Cleared when the turn actually starts; persisted so a
        /// queued session survives a restart with its task intact.
        package var pendingPrompt = ""
        /// 6.0-γ · the run-check command this session uses (persisted).
        package var runCommand = ""
        /// Outcome-β · durable facts from user-triggered acceptance checks.
        package var acceptanceEvidence: [AcceptanceEvidence] = []
        /// 11.0.4 · a check in flight, persisted so a restart can say it was
        /// interrupted instead of forgetting it ran.
        package var runningCheck: RunningCheck?
        /// 6.0-γ · same-task attempt group id (empty = standalone).
        package var attemptGroup = ""
        /// 6.0-γ · what the last finished turn left on disk (+insertions,
        /// −deletions); nil until a turn has been measured.
        package var lastTurnEffect: (insertions: Int, deletions: Int)?

        package static func == (lhs: Model, rhs: Model) -> Bool {
            State(model: lhs) == State(model: rhs)
                && lhs.unknownEvents == rhs.unknownEvents
                && lhs.unparsedLines == rhs.unparsedLines
                && lhs.currentTool == rhs.currentTool
                && lhs.lastTurnEffect?.insertions == rhs.lastTurnEffect?.insertions
                && lhs.lastTurnEffect?.deletions == rhs.lastTurnEffect?.deletions
        }

        package init(id: String, task: String, root: String, isWorktree: Bool, nowMs: Int64) {
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

        package mutating func apply(event: ManagedRuntimeEvent, nowMs: Int64) {
            lastEventMs = nowMs
            switch event {
            case .continuation(let id):
                if continuationID.isEmpty { continuationID = id }
            case .model(let name):
                if !name.isEmpty { modelName = name }
            case .entries(let new):
                appendEntries(new)
                for entry in new where entry.kind == .tool {
                    if !entry.toolName.isEmpty { currentTool = entry.toolName }
                    if entry.isError, !entry.text.isEmpty { lastErrorText = entry.text }
                }
            case .result(let result):
                turns += 1
                currentTool = ""
                if let cost = result.costUSD { totalCostUSD += cost }
                if let n = result.tokensIn { tokensIn += n }
                if let n = result.tokensOut { tokensOut += n }
                let text = bound(result.text, ManagedSession.maxResultLength)
                if !text.isEmpty { lastResultText = ContentSanitizer.redact(text) }
                if let detail = result.errorDetail {
                    errorResults += 1
                    lastErrorText = lastResultText.isEmpty ? detail : lastResultText
                    status = .failed(detail)
                } else {
                    status = .idle
                }
            case .unknown:
                unknownEvents += 1
            case .unparsed:
                unparsedLines += 1
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
        package var lastAgentText: String {
            entries.last(where: { $0.kind == .agent })?.text ?? ""
        }

        private func bound(_ text: String, _ limit: Int) -> String {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > limit ? String(t.prefix(limit)) + "…" : t
        }
    }

    // MARK: - Persistence (6.0-α)

    /// The on-disk shape of a session. A DTO rather than making `Model`
    /// itself Codable: the status enum flattens to kind+detail here, and the
    /// file format stays decoupled from in-memory evolution.
    package struct State: Codable, Equatable {
        package static let currentSchemaVersion = 3

        package var schemaVersion: Int
        package var id: String
        package var title: String
        package var root: String
        package var isWorktree: Bool
        package var startedMs: Int64
        package var runtimeID: String
        package var continuationID: String
        package var modelName: String
        package var statusKind: String
        package var statusDetail: String
        package var entries: [TranscriptReader.Entry]
        package var entriesCapped: Bool
        package var turns: Int
        package var errorResults: Int
        package var totalCostUSD: Double
        package var tokensIn: Int
        package var tokensOut: Int
        package var lastEventMs: Int64
        package var lastResultText: String
        package var lastErrorText: String
        package var pendingPrompt: String = ""
        /// 6.0-γ · the per-session run-check command, remembered.
        package var runCommand: String = ""
        package var acceptanceEvidence: [AcceptanceEvidence] = []
        package var runningCheck: RunningCheck?
        /// 6.0-γ · same-task attempt group (empty = standalone).
        package var attemptGroup: String = ""

        package init(model: Model) {
            schemaVersion = Self.currentSchemaVersion
            id = model.id
            title = model.title
            root = model.root
            isWorktree = model.isWorktree
            startedMs = model.startedMs
            runtimeID = model.runtimeID
            continuationID = model.continuationID
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
            acceptanceEvidence = Array(model.acceptanceEvidence.suffix(ManagedSession.maxAcceptanceEvidence))
            runningCheck = model.runningCheck
            attemptGroup = model.attemptGroup
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, id, title, root, isWorktree, startedMs
            case runtimeID, continuationID, claudeSessionID
            case modelName, statusKind, statusDetail, entries, entriesCapped
            case turns, errorResults, totalCostUSD, tokensIn, tokensOut
            case lastEventMs, lastResultText, lastErrorText, pendingPrompt
            case runCommand, acceptanceEvidence, runningCheck, attemptGroup
        }

        package init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion, in: values,
                    debugDescription: "unsupported managed state schema \(schemaVersion)"
                )
            }
            id = try values.decode(String.self, forKey: .id)
            title = try values.decode(String.self, forKey: .title)
            root = try values.decode(String.self, forKey: .root)
            isWorktree = try values.decode(Bool.self, forKey: .isWorktree)
            startedMs = try values.decode(Int64.self, forKey: .startedMs)
            runtimeID = try values.decodeIfPresent(String.self, forKey: .runtimeID) ?? "claude"
            continuationID = try values.decodeIfPresent(String.self, forKey: .continuationID)
                ?? values.decodeIfPresent(String.self, forKey: .claudeSessionID)
                ?? ""
            modelName = try values.decode(String.self, forKey: .modelName)
            statusKind = try values.decode(String.self, forKey: .statusKind)
            statusDetail = try values.decode(String.self, forKey: .statusDetail)
            entries = try values.decode([TranscriptReader.Entry].self, forKey: .entries)
            entriesCapped = try values.decode(Bool.self, forKey: .entriesCapped)
            turns = try values.decode(Int.self, forKey: .turns)
            errorResults = try values.decode(Int.self, forKey: .errorResults)
            totalCostUSD = try values.decode(Double.self, forKey: .totalCostUSD)
            tokensIn = try values.decode(Int.self, forKey: .tokensIn)
            tokensOut = try values.decode(Int.self, forKey: .tokensOut)
            lastEventMs = try values.decode(Int64.self, forKey: .lastEventMs)
            lastResultText = try values.decode(String.self, forKey: .lastResultText)
            lastErrorText = try values.decode(String.self, forKey: .lastErrorText)
            pendingPrompt = try values.decodeIfPresent(String.self, forKey: .pendingPrompt) ?? ""
            runCommand = try values.decodeIfPresent(String.self, forKey: .runCommand) ?? ""
            let decodedEvidence = try values.decodeIfPresent(
                [AcceptanceEvidence].self, forKey: .acceptanceEvidence
            ) ?? []
            acceptanceEvidence = Array(decodedEvidence.suffix(ManagedSession.maxAcceptanceEvidence))
            runningCheck = try values.decodeIfPresent(RunningCheck.self, forKey: .runningCheck)
            attemptGroup = try values.decodeIfPresent(String.self, forKey: .attemptGroup) ?? ""
        }

        package func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(schemaVersion, forKey: .schemaVersion)
            try values.encode(id, forKey: .id)
            try values.encode(title, forKey: .title)
            try values.encode(root, forKey: .root)
            try values.encode(isWorktree, forKey: .isWorktree)
            try values.encode(startedMs, forKey: .startedMs)
            try values.encode(runtimeID, forKey: .runtimeID)
            try values.encode(continuationID, forKey: .continuationID)
            try values.encode(modelName, forKey: .modelName)
            try values.encode(statusKind, forKey: .statusKind)
            try values.encode(statusDetail, forKey: .statusDetail)
            try values.encode(entries, forKey: .entries)
            try values.encode(entriesCapped, forKey: .entriesCapped)
            try values.encode(turns, forKey: .turns)
            try values.encode(errorResults, forKey: .errorResults)
            try values.encode(totalCostUSD, forKey: .totalCostUSD)
            try values.encode(tokensIn, forKey: .tokensIn)
            try values.encode(tokensOut, forKey: .tokensOut)
            try values.encode(lastEventMs, forKey: .lastEventMs)
            try values.encode(lastResultText, forKey: .lastResultText)
            try values.encode(lastErrorText, forKey: .lastErrorText)
            try values.encode(pendingPrompt, forKey: .pendingPrompt)
            try values.encode(runCommand, forKey: .runCommand)
            try values.encode(acceptanceEvidence, forKey: .acceptanceEvidence)
            try values.encodeIfPresent(runningCheck, forKey: .runningCheck)
            try values.encode(attemptGroup, forKey: .attemptGroup)
        }

        /// Reattach. A state persisted mid-turn ("running") comes back as
        /// `interrupted` — we were not there to see how that turn ended, and
        /// saying anything else would be inventing an outcome. A queued
        /// session comes back queued (the fleet re-pumps it).
        package func model() -> Model {
            var m = Model(id: id, task: title, root: root, isWorktree: isWorktree, nowMs: startedMs)
            m.title = title
            m.runtimeID = runtimeID
            m.continuationID = continuationID
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
            m.acceptanceEvidence = acceptanceEvidence
            // We were not there to see how it ended; say exactly that.
            if let runningCheck {
                m.acceptanceEvidence.append(runningCheck.interruptedEvidence())
                if m.acceptanceEvidence.count > ManagedSession.maxAcceptanceEvidence {
                    m.acceptanceEvidence.removeFirst(
                        m.acceptanceEvidence.count - ManagedSession.maxAcceptanceEvidence
                    )
                }
            }
            m.attemptGroup = attemptGroup
            return m
        }
    }

    /// `~/Library/Application Support/Pulse/managed` — overridable for tests.
    package static var stateDirectoryOverride: URL?
    package static func stateDirectory() -> URL {
        if let stateDirectoryOverride { return stateDirectoryOverride }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Pulse/managed", isDirectory: true)
    }

    package static func stateURL(id: String) -> URL {
        stateDirectory().appendingPathComponent(id + ".json")
    }

    /// 0600 via PrivateFile — the conversation is the user's own words.
    @discardableResult
    package static func persist(_ model: Model) -> Bool {
        try? FileManager.default.createDirectory(
            at: stateDirectory(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(State(model: model)) else { return false }
        return PrivateFile.write(data, to: stateURL(id: model.id))
    }

    package static func loadAll() -> [Model] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: stateDirectory().path
        ) else { return [] }
        var models: [Model] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = stateDirectory().appendingPathComponent(name)
            let state: State
            do {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            } catch {
                DebugLog.write("managed state refused file=\(name) reason=decode")
                continue
            }
            // Filename decides identity — the spool rule, here too.
            guard name == state.id + ".json" else {
                DebugLog.write("managed state refused file=\(name) reason=identity")
                continue
            }
            // A state from a runtime this build cannot drive is not a
            // Claude state merely because this binary cannot name it.
            guard ManagedRuntimeRegistry.knownIDs.contains(state.runtimeID) else {
                DebugLog.write("managed state refused file=\(name) reason=runtime")
                continue
            }
            models.append(state.model())
        }
        return models.sorted { $0.startedMs < $1.startedMs }
    }

    package static func removeState(id: String) {
        try? FileManager.default.removeItem(at: stateURL(id: id))
    }

    // MARK: - NDJSON reassembly

    /// A pipe hands over chunks, not lines; a JSON event split across two
    /// chunks must not be counted as two broken ones. Carries the unfinished
    /// tail until its newline arrives.
    package struct LineBuffer {
        private var carry = Data()

        package mutating func lines(from chunk: Data) -> [Data] {
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
        package mutating func flush() -> Data? {
            defer { carry = Data() }
            return carry.isEmpty ? nil : carry
        }
    }
}

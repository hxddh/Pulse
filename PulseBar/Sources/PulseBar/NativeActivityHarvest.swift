import Foundation
import SQLite3

/// Swift-native local activity collector.
///
/// The tray must continue to work on a clean macOS machine. Earlier versions
/// forked `activity_scan.py` for every harvest and therefore made a Python
/// installation a runtime prerequisite. This collector deliberately uses only
/// Foundation and the agent-owned files already visible to Pulse: it walks a
/// bounded set of vendor roots, decodes JSON/JSONL metadata, and emits the
/// same useful facts as the old wire (goal, workspace, activity, lifecycle,
/// model, progress, resources and an explicit pending signal).
///
/// Vendor schemas are not stable enough to pretend that one generic decoder is
/// a perfect transcript reader. A row is marked `.session` only when it comes
/// from a transcript/session-shaped file; otherwise it is honestly `.cache`.
/// The opt-in legacy Python collector remains available for a user who needs a
/// vendor-specific parser, but it is never required for detection or launch.
enum NativeActivityHarvest {
    struct Result {
        var rows: [ActivityHarvest.Row]
        var health: [ActivityHarvest.CollectorHealth]
        var complete: Bool
    }

    private struct Descriptor {
        var id: AgentID
        var roots: [URL]
        var commands: [String]
    }

    private struct Fact {
        var task = ""
        var project = ""
        var cwd = ""
        var sessionID = ""
        var tool = ""
        var skill = ""
        var phase = ""
        var outcome = ""
        var model = ""
        var mode = ""
        var tokensIn = 0
        var tokensOut = 0
        var errors = 0
        var files = 0
        var contextPercent = 0
        var progressDone = 0
        var progressTotal = 0
        var subRunning = 0
        var subTotal = 0
        var explicitPending = false
        var score = 0
        var context = ""
        var sourcePath = ""
        var structured = false
        var activityMs: Int64 = 0
        var startedMs: Int64 = 0
        var records = 0

        var identity: String {
            if !sessionID.isEmpty { return "session:\(sessionID)" }
            if sourcePath.lowercased().contains("/.gemini/tmp/")
                && sourcePath.lowercased().contains("/chats/") {
                // A Gemini chat file contains many message records. Keep one
                // row per chat, not one row per message-id (the latter made a
                // single session occupy most of the tray).
                return "file:\(sourcePath)"
            }
            if !cwd.isEmpty || !task.isEmpty { return "facts:\(cwd)|\(task)" }
            return "file:\(sourcePath)"
        }

        var hasUsefulSignal: Bool {
            // A title by itself is frequently a plugin name, a template, or a
            // cached document headline. Require an identity/workspace/session
            // context before it crosses into the tray. This is the native
            // equivalent of the legacy collector's `useful_cache_task` gate.
            let identityEvidence = !sessionID.isEmpty || !cwd.isEmpty
                || NativeActivityHarvest.contextLooksSession(context)
                || NativeActivityHarvest.isSessionPath(URL(fileURLWithPath: sourcePath))
            guard identityEvidence else { return false }
            return !task.isEmpty || !cwd.isEmpty || !sessionID.isEmpty || !tool.isEmpty
                || !skill.isEmpty || !phase.isEmpty || !outcome.isEmpty
                || !model.isEmpty || tokensIn > 0 || tokensOut > 0
                || errors > 0 || files > 0 || contextPercent > 0
                || progressDone > 0 || progressTotal > 0 || subTotal > 0
        }

        /// A fact may have a stable identity without containing anything a
        /// person can act on (for example an empty Composer draft). Keep that
        /// identity for merge diagnostics, but do not let it consume the
        /// per-Agent session budget or displace a later task with real facts.
        var hasDisplaySignal: Bool {
            !task.isEmpty || !cwd.isEmpty || !skill.isEmpty || !tool.isEmpty
                || !phase.isEmpty || !outcome.isEmpty || !model.isEmpty
                || tokensIn > 0 || tokensOut > 0 || errors > 0 || files > 0
                || contextPercent > 0 || progressTotal > 0 || subTotal > 0
        }
    }

    private final class ErrorBox {
        var value = false
    }

    private final class ScanBudget {
        private(set) var bytesRemaining = 48_000_000
        let deadline: Date

        init(deadline: Date) { self.deadline = deadline }

        var exhausted: Bool { Date() >= deadline || bytesRemaining <= 0 }

        func reserve(_ bytes: Int) -> Bool {
            guard bytes > 0, !exhausted, bytes <= bytesRemaining else { return false }
            bytesRemaining -= bytes
            return true
        }
    }

    private static let maxFilesPerAgent = 384
    /// Parse up to the product-wide session budget, then keep typed facts for
    /// the searchable index. The two limits are intentionally distinct:
    /// truncating before normalization can hide the newest usable row.
    /// 0.50 raises retain to 500 so search/pagination can cover large histories
    /// while the tray glance stays at SnapshotBuilder.maxVisibleRows.
    private static let maxFactsPerAgent = 512
    private static let maxRowsPerAgent = 500
    private static let maxDepth = 8
    private static let maxFileBytes = 4 * 1024 * 1024
    /// A menu-bar refresh must not spend its whole cadence on one vendor's
    /// ever-growing cache. The deadline is intentionally per adapter; every
    /// Agent still receives a health line even when one root is pathological.
    // A 180 ms cap made large but valid rollout stores (Codex, Pi, Gemini)
    // report `failed` on every refresh before their first useful record was
    // reached. Keep the adapter isolated, but give one bounded SQLite/text
    // pass enough time to return its authoritative newest session.
    private static let maxAgentSeconds = 0.75
    /// Codex compacted context is one large JSONL record. Its wider bounded
    /// tail window needs a little more CPU than ordinary vendor transcripts,
    /// without weakening the global six-second cutoff or fixture overrides.
    private static let codexAgentSeconds = 1.2
    private static let maxObjectNodes = 2_000
    /// Transcript-backed stores can contain months of append-only history. The
    /// row freshness policy already hides these records from the tray; avoid
    /// spending the bounded adapter slice parsing them when a newer file is
    /// available. SQLite adapters are intentionally excluded because their
    /// internal `updated_at` columns are more authoritative than file mtime.
    private static let transcriptFreshFileWindowMs: Int64 = 72 * 60 * 60 * 1000
    private static let sessionNeedles = [
        "session", "thread", "conversation", "chat", "history", "rollout",
        "transcript", "composer", "task", "projects",
    ]
    private static let ignoredDirectoryNames: Set<String> = [
        "node_modules", "crashpad", "gpuCache", "cachedData", "cache",
        "caches", "logs", "thumbnails",
    ]

    static func scan(
        allowAppData: Bool = false,
        appDataAgents: Set<AgentID> = [],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        agentDeadlineSeconds: TimeInterval? = nil,
        totalDeadlineSeconds: TimeInterval? = nil,
        agentFilter: Set<AgentID>? = nil
    ) -> Result {
        let fm = FileManager.default
        let allDescriptors = descriptors(home: home)
        let descriptors: [Descriptor]
        if let agentFilter {
            let allowed = Set(agentFilter.map(\.surfaceID))
            descriptors = allDescriptors.filter { allowed.contains($0.id.surfaceID) }
        } else {
            descriptors = allDescriptors
        }
        let budget = ScanBudget(
            deadline: Date().addingTimeInterval(totalDeadlineSeconds ?? 5.8)
        )
        let perAgentSeconds = agentDeadlineSeconds ?? maxAgentSeconds
        var rows: [ActivityHarvest.Row] = []
        var health: [ActivityHarvest.CollectorHealth] = []

        for (descriptorIndex, descriptor) in descriptors.enumerated() {
            if budget.exhausted {
                // Emit an explicit boundary for adapters the global cutoff
                // never reached. Do not misreport them as `no_sessions`.
                health.append(contentsOf: descriptors[descriptorIndex...].map {
                    .unscanned($0.id)
                })
                break
            }
            let started = Date()
            var sourcePresent = false
            var facts: [Fact] = []
            var visitError = false
            var agentTimedOut = false
            let permitted = allowAppData || appDataAgents.contains(where: {
                accessAlias($0, matches: descriptor.id)
            })
            let adapterSeconds = agentDeadlineSeconds
                ?? (descriptor.id == .codex ? codexAgentSeconds : perAgentSeconds)
            let deadline = Date().addingTimeInterval(adapterSeconds)

            for root in descriptor.roots {
                // Do not call fileExists/isDirectory on protected locations
                // without a grant. Even a harmless-looking probe can be
                // classified by TCC as a cross-application data request.
                if isProtected(root, home: home), !permitted { continue }
                guard fm.fileExists(atPath: root.path) else { continue }
                sourcePresent = true
                let timedOut = collect(
                    root: root,
                    id: descriptor.id,
                    home: home,
                    into: &facts,
                    error: &visitError,
                    deadline: deadline,
                    budget: budget
                )
                agentTimedOut = agentTimedOut || timedOut
                if facts.count >= maxFactsPerAgent { break }
                if agentTimedOut || Date() >= deadline || budget.exhausted { break }
            }

            if !sourcePresent {
                sourcePresent = descriptor.commands.contains { executableExists($0) }
            }
            // SQLite + JSONL (Pi) and split transcript fragments share a
            // session id. Merge before row shaping so a later real prompt is
            // not dropped by makeRows' first-wins de-dupe. Drop empty Pi
            // SQLite rows only after merge, so a matching UUID still keeps
            // sqlite files/tokens on the JSONL title.
            var mergedFacts = merge(facts)
            if descriptor.id == .pi {
                dropEmptyPiSqliteDuplicates(&mergedFacts)
            }
            let agentRows = makeRows(from: mergedFacts, id: descriptor.id, home: home)
            rows.append(contentsOf: agentRows)
            let state: ActivityHarvest.CollectorState
            if agentTimedOut {
                // Keep rows found before the cutoff, but make the retryable
                // partial adapter visible in Support Health.
                state = .failed
            } else if visitError {
                // One source inside a vendor root can be locked/corrupt while
                // a sibling source still produced useful rows. Keep those
                // rows, but classify the adapter as partial so the previous
                // snapshot is not treated as a clean replacement.
                state = .failed
            } else if !agentRows.isEmpty {
                state = .observed
            } else if sourcePresent {
                state = .noSessions
            } else {
                state = .sourceAbsent
            }
            let duration = max(0, Int(Date().timeIntervalSince(started) * 1000))
            health.append(.init(
                id: descriptor.id,
                state: state,
                durationMs: duration,
                rowCount: agentRows.count,
                sourcePresent: sourcePresent,
                errorKind: agentTimedOut
                    ? "native_timeout"
                    : (visitError ? "native_read_failed" : "")
            ))
            if budget.exhausted, descriptorIndex + 1 < descriptors.count {
                health.append(contentsOf: descriptors[(descriptorIndex + 1)...].map {
                    .unscanned($0.id)
                })
                break
            }
        }

        // Legacy parity (activity_scan.cascade_block): Windsurf shell rows only
        // when Cascade produced none — shared ~/.windsurf roots must not double
        // the same pending session as two red lamps (0.95 Extinguish Honesty).
        if agentFilter == nil || agentFilter!.contains(.cascade) {
            if rows.contains(where: { $0.id == .cascade }) {
                rows.removeAll { $0.id == .windsurf }
                for index in health.indices where health[index].id == .windsurf {
                    if health[index].state == .observed || health[index].rowCount > 0 {
                        health[index].state = .noSessions
                        health[index].rowCount = 0
                    }
                }
            }
        }

        return Result(
            rows: rows,
            health: health,
            complete: ActivityHarvest.isCompleteHealth(health)
        )
    }

    // MARK: - Agent roots

    private static func descriptors(home: URL) -> [Descriptor] {
        func h(_ path: String) -> URL { home.appendingPathComponent(path) }
        func d(_ id: AgentID, _ paths: [String], _ commands: [String] = []) -> Descriptor {
            Descriptor(id: id, roots: paths.map(h), commands: commands)
        }
        // `cursorAgent` is intentionally a transport alias of Cursor and has
        // no second health row. The remaining descriptors cover every public
        // AgentID surface, including agents whose only local source is a cache.
        return [
            d(.claude, [".claude/projects", ".claude/tasks"], ["claude"]),
            d(.codex, [".codex/sessions", ".codex/rollouts"], ["codex"]),
            d(.cursor, [
                "Library/Application Support/Cursor/User/globalStorage",
                "Library/Application Support/Cursor/User/workspaceStorage",
                // A few Cursor builds keep a compact session summary directly
                // under User rather than in globalStorage. It is still a
                // protected store, so this root is visited only after the
                // user's explicit Cursor app-data opt-in.
                "Library/Application Support/Cursor/User",
            ], ["Cursor"]),
            d(.grok, [".grok/sessions"], ["grok"]),
            // Pi's JSONL transcripts are the richest source; context-mode's
            // per-session SQLite adds cwd/tool/resource facts when the agent
            // has no transcript hook installed.
            // Keep the two session-shaped Pi stores explicit. Walking the
            // entire ~/.pi tree also traverses its bundled npm/runtime cache
            // (11k+ files on a typical install), consumes the global budget,
            // and can hide the actual session DBs behind a native timeout.
            // JSONL under agent/sessions is the /resume title source. Walking
            // context-mode SQLite first spent the adapter deadline on empty
            // session_meta rows and never opened the transcripts.
            d(.pi, [".pi/agent/sessions", ".pi/context-mode/sessions"], ["pi"]),
            d(.amp, [".local/share/amp", ".amp"], ["amp"]),
            d(.aider, [".aider"], ["aider"]),
            d(.gemini, [".gemini/tmp"], ["gemini"]),
            d(.copilot, [".copilot", ".config/copilot"], ["copilot"]),
            d(.opencode, [".local/share/opencode"], ["opencode"]),
            d(.goose, [".config/goose", ".local/share/goose", "Library/Application Support/Goose"], ["goose"]),
            d(.openhands, [".openhands", ".openhands-state"], ["openhands"]),
            d(.cline, [
                "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev",
                "Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev",
                "Library/Application Support/Windsurf/User/globalStorage/saoudrizwan.claude-dev",
                "Library/Application Support/Trae/User/globalStorage/saoudrizwan.claude-dev",
            ]),
            d(.roo, [
                "Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline",
                "Library/Application Support/Cursor/User/globalStorage/rooveterinaryinc.roo-cline",
                "Library/Application Support/Windsurf/User/globalStorage/rooveterinaryinc.roo-cline",
                "Library/Application Support/Trae/User/globalStorage/rooveterinaryinc.roo-cline",
            ]),
            d(.continue_, [".continue"]),
            d(.amazonQ, [
                ".aws/amazonq", ".aws/amazon-q", ".aws/q",
                ".local/share/amazon-q",
                "Library/Application Support/Amazon Q",
                "Library/Application Support/amazon-q",
                "Library/Application Support/AmazonQ",
            ]),
            d(.cascade, [
                ".codeium", ".windsurf",
                "Library/Application Support/Windsurf",
                "Library/Application Support/Codeium",
            ]),
            d(.windsurf, [".windsurf", "Library/Application Support/Windsurf"]),
            d(.augment, [".augment", ".auggie"]),
            d(.zedAgent, [
                ".zed", ".config/zed",
                "Library/Application Support/Zed",
            ]),
            d(.trae, [".trae", "Library/Application Support/Trae"]),
            d(.warpAgent, [
                ".warp",
                "Library/Application Support/dev.warp.Warp-Stable",
                "Library/Application Support/dev.warp.Warp",
                "Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable",
                "Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp",
            ]),
            d(.devin, [".devin", ".cognition"], ["devin"]),
            d(.kiro, [".kiro", "Library/Application Support/Kiro"], ["kiro"]),
            d(.junie, [".junie", "Library/Application Support/JetBrains/Junie"], ["junie"]),
            d(.kilo, [
                "Library/Application Support/Code/User/globalStorage/kilocode.kilo-code",
                "Library/Application Support/Cursor/User/globalStorage/kilocode.kilo-code",
            ]),
            d(.replit, [".replit", ".config/replit"]),
            d(.droid, [".factory"], ["droid"]),
            d(.commandCode, [".commandcode"], ["cmd", "command-code"]),
            d(.antigravity, [
                "Library/Application Support/Antigravity/User/globalStorage",
                "Library/Application Support/Antigravity/User/workspaceStorage",
                "Library/Application Support/Antigravity IDE/User/globalStorage",
                "Library/Application Support/Antigravity IDE/User/workspaceStorage",
            ], ["agy", "antigravity"]),
            d(.kimi, [".kimi-code"], ["kimi"]),
            d(.zcode, [
                ".zcode",
                "Library/Application Support/ZCode",
            ], ["zcode", "ZCode"]),
        ]
    }

    private static func accessAlias(_ selected: AgentID, matches id: AgentID) -> Bool {
        if selected.surfaceID == id.surfaceID { return true }
        if (selected == .cascade || selected == .windsurf)
            && (id == .cascade || id == .windsurf) { return true }
        if (selected == .cursor || selected == .cursorAgent) && id == .cursor { return true }
        return false
    }

    private static func isProtected(_ url: URL, home: URL) -> Bool {
        let root = home.standardizedFileURL.path.hasSuffix("/")
            ? home.standardizedFileURL.path
            : home.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(root + "Library/") else { return false }
        let relative = String(url.standardizedFileURL.path.dropFirst((root + "Library/").count))
        return ["Application Support/", "Group Containers/", "Containers/", "Logs/"]
            .contains(where: { relative.hasPrefix($0) })
    }

    private static func executableExists(_ name: String) -> Bool {
        let fm = FileManager.default
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        return path.contains { fm.isExecutableFile(atPath: "\($0)/\(name)") }
    }

    private static func shouldSkipStaleTranscript(id: AgentID, mtime: Int64) -> Bool {
        guard mtime > 0 else { return false }
        switch id {
        case .pi:
            // Pi JSONL is the session title source. Idle files older than
            // 72h are still the live `~/.pi/agent/sessions` tree; skipping
            // them left SQLite rows with cwd and no task (blank tray hero).
            return false
        case .claude, .codex, .gemini, .amp, .aider, .copilot,
             .goose, .openhands, .continue_, .droid, .commandCode, .kimi:
            let age = Int64(Date().timeIntervalSince1970 * 1000) - mtime
            return age > transcriptFreshFileWindowMs
        default:
            return false
        }
    }

    private static func allowsBoundedLargeTranscript(_ id: AgentID) -> Bool {
        switch id {
        case .claude, .codex, .gemini, .pi, .amp, .aider, .copilot,
             .goose, .openhands, .continue_, .droid, .commandCode, .kimi:
            return true
        default:
            return false
        }
    }

    // MARK: - Bounded file walk

    private static func collect(
        root: URL,
        id: AgentID,
        home: URL,
        into facts: inout [Fact],
        error: inout Bool,
        deadline: Date,
        budget: ScanBudget
    ) -> Bool {
        let fm = FileManager.default
        let rootDepth = root.pathComponents.count
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey,
        ]
        let errorBox = ErrorBox()
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in errorBox.value = true; return true }
        ) else { return Date() >= deadline || budget.exhausted }

        var visited = 0
        var deferredPiSqlite: [URL] = []
        var piTranscripts: [(url: URL, values: URLResourceValues, ext: String)] = []
        while let item = enumerator.nextObject() as? URL {
            if Date() >= deadline || budget.exhausted { break }
            visited += 1
            if visited > maxFilesPerAgent * 4 { break }
            let depth = max(0, item.pathComponents.count - rootDepth)
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let name = item.lastPathComponent
            if ignoredDirectoryNames.contains(name) {
                if id == .grok && name.lowercased() == "logs" {
                    // Grok's authoritative session stream is intentionally
                    // kept under ~/.grok/logs/unified.jsonl.
                } else {
                enumerator.skipDescendants()
                continue
                }
            }
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else {
                error = true
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }

            let ext = item.pathExtension.lowercased()
            if id == .cursor, ["vscdb", "sqlite", "db"].contains(ext) {
                collectCursorDatabase(
                    item,
                    into: &facts,
                    budget: budget,
                    error: &error
                )
                if facts.count >= maxFactsPerAgent { break }
                continue
            }
            if [.opencode, .warpAgent, .pi, .grok].contains(id), ["sqlite", "db"].contains(ext) {
                if id == .pi {
                    // JSONL carries /resume titles. A sibling sessions.db
                    // (or any non-session_meta file) must not run first or
                    // mark the adapter failed before those transcripts.
                    deferredPiSqlite.append(item)
                    continue
                }
                collectVendorDatabase(
                    item,
                    id: id,
                    home: home,
                    into: &facts,
                    budget: budget,
                    error: &error
                )
                if facts.count >= maxFactsPerAgent { break }
                continue
            }
            if id == .grok {
                // The SQLite session index above is authoritative. The same
                // session tree also contains terminal transcripts, locks and
                // system prompts; treating those as independent sessions is
                // exactly how noisy `<user_query>` rows leaked into the tray.
                continue
            }
            if id == .pi,
               !item.path.lowercased().contains("/.pi/agent/sessions/") {
                // context-mode DBs were handled above; stats/config/cache
                // JSON under ~/.pi is not a user task transcript.
                continue
            }
            // Gemini's tmp root also contains a full checkout copy. Source
            // files are not session evidence; only chats/logs are eligible.
            if id == .gemini {
                let lowerPath = item.path.lowercased()
                let isChat = lowerPath.contains("/chats/")
                if !isChat { continue }
            }
            guard ["json", "jsonl", "ndjson", "txt", "md", "log"].contains(ext) else { continue }
            if id == .pi {
                // Stat only during the walk. Reading every historical JSONL at
                // 8 MB exhausted the 48 MB budget (and the 0.75s adapter)
                // before the live /resume file. Newest mtime first, cheap
                // head+tail, then SQLite.
                piTranscripts.append((item, values, ext))
                continue
            }
            ingestTranscriptFile(
                item,
                values: values,
                ext: ext,
                id: id,
                home: home,
                into: &facts,
                error: &error,
                budget: budget
            )
            if facts.count >= maxFactsPerAgent { break }
        }
        if id == .pi {
            let ranked = piTranscripts.sorted { lhs, rhs in
                let a = lhs.values.contentModificationDate ?? .distantPast
                let b = rhs.values.contentModificationDate ?? .distantPast
                if a != b { return a > b }
                return lhs.url.path > rhs.url.path
            }
            for item in ranked {
                if Date() >= deadline || budget.exhausted { break }
                if facts.count >= maxFactsPerAgent { break }
                ingestTranscriptFile(
                    item.url,
                    values: item.values,
                    ext: item.ext,
                    id: id,
                    home: home,
                    into: &facts,
                    error: &error,
                    budget: budget
                )
            }
            for db in deferredPiSqlite {
                if Date() >= deadline || budget.exhausted { break }
                if facts.count >= maxFactsPerAgent { break }
                collectVendorDatabase(
                    db,
                    id: id,
                    home: home,
                    into: &facts,
                    budget: budget,
                    error: &error
                )
            }
        }
        error = error || errorBox.value
        return Date() >= deadline || budget.exhausted
    }

    private static func ingestTranscriptFile(
        _ item: URL,
        values: URLResourceValues,
        ext: String,
        id: AgentID,
        home: URL,
        into facts: inout [Fact],
        error: inout Bool,
        budget: ScanBudget
    ) {
        let size = values.fileSize ?? 0
        let sizeLimit = id == .grok
            ? 16 * 1024 * 1024
            : (allowsBoundedLargeTranscript(id) ? 512 * 1024 * 1024 : maxFileBytes)
        guard size > 0, size <= sizeLimit else { return }

        let mtime = values.contentModificationDate.map {
            Int64($0.timeIntervalSince1970 * 1000)
        } ?? 0
        if shouldSkipStaleTranscript(id: id, mtime: mtime) { return }

        // Pi /resume titles live in the session header / first user message
        // (head) and optional /name + compaction (usually near the tail).
        // 8 MB per historical file exhausted the 48 MB budget; match the
        // legacy harvest window: 96 KB head + 400 KB tail.
        let windowCap = id == .codex ? 8_000_000 : (id == .pi ? 496_000 : 1_000_000)
        let headLimit = id == .pi ? 96_000 : 64_000
        guard let text = readWindow(
            item, size: size, budget: budget, cap: windowCap, headLimit: headLimit
        ), !text.isEmpty else { return }
        let structured = isSessionPath(item)
            || (id == .grok && item.path.lowercased().contains("/.grok/logs/"))
        let birth = values.creationDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        var parsed = parseFacts(text, structured: structured, path: item.path)
        if parsed.isEmpty, ext == "json",
           let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) == nil {
            error = true
        }
        if parsed.isEmpty,
           !(id == .pi && piLooksOfficial(text)),
           let fallback = textFacts(text, structured: structured, path: item.path) {
            parsed = [fallback]
        }
        if [.amp, .claude, .commandCode, .gemini, .aider, .copilot,
            .goose, .openhands, .continue_, .droid, .kimi].contains(id) {
            parsed.removeAll { isContinuationPrompt($0.task) }
        }
        guard !parsed.isEmpty else { return }
        let records = ext == "jsonl" || ext == "ndjson"
            ? text.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
            : 0
        for index in parsed.indices {
            parsed[index].sourcePath = item.path
            if parsed[index].activityMs <= 0 {
                parsed[index].activityMs = mtime
            }
            parsed[index].startedMs = birth > 0 && birth <= mtime + 1000 ? birth : 0
            parsed[index].records = records
            parsed[index].structured = structured
            if id.waitingSource == .none, parsed[index].skill == "pending" {
                parsed[index].skill = ""
                parsed[index].explicitPending = false
            }
            if id == .amp, item.path.lowercased().hasSuffix("history.jsonl") {
                parsed[index].records = 0
            }
            if id == .gemini, structured {
                parsed[index].sessionID = sessionIDFromPath(item)
            }
            if parsed[index].cwd.isEmpty, id == .gemini,
               let projectRoot = geminiProjectRoot(for: item) {
                parsed[index].cwd = projectRoot
                parsed[index].project = parsed[index].project.isEmpty
                    ? lastPathComponent(projectRoot)
                    : parsed[index].project
            }
            if parsed[index].sessionID.isEmpty, structured {
                parsed[index].sessionID = sessionIDFromPath(item)
            }
            if id == .claude {
                let encoded = item.deletingLastPathComponent().lastPathComponent
                let decoded = decodeClaudeProjectDir(encoded)
                if !decoded.isEmpty,
                   parsed[index].cwd.isEmpty || looksLikeFilePathCwd(parsed[index].cwd) {
                    parsed[index].cwd = decoded
                    if parsed[index].project.isEmpty {
                        parsed[index].project = lastPathComponent(decoded)
                    }
                }
            }
        }
        if id == .claude {
            let counts = claudeSubagentCounts(for: item)
            if counts.total > 0 {
                for index in parsed.indices {
                    parsed[index].subRunning = max(parsed[index].subRunning, counts.running)
                    parsed[index].subTotal = max(parsed[index].subTotal, counts.total)
                }
            }
        }
        parsed = merge(parsed)
        let remaining = max(0, maxFactsPerAgent - facts.count)
        if remaining > 0 {
            facts.append(contentsOf: parsed.filter { $0.hasUsefulSignal && $0.hasDisplaySignal }.prefix(remaining))
        }
    }

    private static func geminiProjectRoot(for url: URL) -> String? {
        // ~/.gemini/tmp/<project>/chats/<session>.jsonl → <project>/.project_root
        let marker = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".project_root")
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let path = normalizedPath(text)
        return path.isEmpty ? nil : path
    }

    private static func isContinuationPrompt(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        return ["continue", "继续", "继续分析", "继续评估", "ok", "okay", "好的", "可以", "goon", "next"]
            .contains(normalized)
    }

    // MARK: - Native SQLite adapters

    /// OpenCode, Warp Agent and Pi store their authoritative session metadata
    /// in SQLite. Falling back to a generic file walk makes those agents look
    /// absent even while they have many sessions. These readers only prepare
    /// read-only statements, cap rows, and share the same global byte budget.
    private static func collectVendorDatabase(
        _ url: URL,
        id: AgentID,
        home: URL,
        into facts: inout [Fact],
        budget: ScanBudget,
        error: inout Bool
    ) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, budget.reserve(min(size, maxFileBytes)) else { return }
        var database: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard status == SQLITE_OK, let database else {
            // Pi JSONL is the title source. A sibling that is not SQLite
            // must not fail the adapter (that froze lastGoodHarvest empty).
            if id != .pi { error = true }
            if database != nil { sqlite3_close(database) }
            return
        }
        defer { sqlite3_close(database) }
        switch id {
        case .opencode:
            collectOpenCodeDatabase(database, url: url, into: &facts, error: &error)
        case .warpAgent:
            collectWarpDatabase(database, url: url, into: &facts, error: &error)
        case .pi:
            collectPiDatabase(database, url: url, home: home, into: &facts, error: &error)
            // A non-session_meta sibling must not fail the JSONL adapter.
            return
        case .grok:
            collectGrokDatabase(database, url: url, home: home, into: &facts, error: &error)
        default:
            break
        }
        // A locked, corrupt, or non-SQLite file can successfully open and only
        // fail on the first prepared statement/step. Do not turn that into a
        // healthy zero-session result: the caller must retain the previous
        // adapter rows and expose a retryable Support Health state.
        if sqliteReadFailed(database) { error = true }
    }

    private static func collectGrokDatabase(
        _ database: OpaquePointer,
        url: URL,
        home: URL,
        into facts: inout [Fact],
        error: inout Bool
    ) {
        let sql = "SELECT session_id, cwd, updated_at, title, content FROM session_docs ORDER BY updated_at DESC LIMIT \(maxRowsPerAgent)"
        guard let statement = sqlitePrepare(database, sql) else {
            error = true
            return
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let sid = sqliteString(statement, column: 0)
            let cwd = normalizedPath(sqliteString(statement, column: 1))
            let title = sqliteString(statement, column: 3)
            let content = sqliteString(statement, column: 4)
            let displayTitle = title.isEmpty ? grokTitle(from: content) : title
            let homePath = home.standardizedFileURL.path
            // The index creates a placeholder document as soon as a session is
            // opened. A home-only placeholder has no observable task and must
            // not become a blank tray row.
            guard !sid.isEmpty,
                  !displayTitle.isEmpty || !content.isEmpty || (cwd != homePath && !cwd.isEmpty)
            else { continue }
            var values: [String: Any] = [
                "sessionId": sid,
                "title": displayTitle,
                "cwd": cwd,
                "agentMode": "Grok",
                "records": content.split(whereSeparator: \.isNewline).count,
            ]
            var fact = fact(from: values, context: "grok.session_search", structured: true, path: url.path)
            fact.sessionID = sid
            fact.records = content.split(whereSeparator: \.isNewline).count
            fact.activityMs = normalizeTimestamp(sqlite3_column_int64(statement, 2))
            if fact.activityMs == 0 { fact.activityMs = fileMTime(url) }
            // 0.95: never infer Waiting from free-text transcript content.
            let lower = content.lowercased()
            if lower.contains("tool") || lower.contains("command") { fact.phase = "running" }
            if fact.hasUsefulSignal { facts.append(fact) }
            if facts.count >= maxFactsPerAgent { break }
            values.removeAll(keepingCapacity: false)
        }
    }

    private static func grokTitle(from content: String) -> String {
        for line in content.split(whereSeparator: \.isNewline) {
            let value = clean(String(line), limit: 160)
            guard !value.isEmpty else { continue }
            let lower = value.lowercased()
            if lower.hasPrefix("<system") || lower.hasPrefix("<user_query")
                || lower.hasPrefix("<assistant") || lower.hasPrefix("```") { continue }
            return value
        }
        return ""
    }

    private static func collectOpenCodeDatabase(
        _ database: OpaquePointer,
        url: URL,
        into facts: inout [Fact],
        error: inout Bool
    ) {
        let sql = """
        SELECT id, title, directory, agent, model, tokens_input, tokens_output,
               time_created, time_updated, summary_files
        FROM session
        WHERE IFNULL(time_archived, 0) = 0
        ORDER BY time_updated DESC
        LIMIT \(maxRowsPerAgent)
        """
        guard let statement = sqlitePrepare(database, sql) else {
            error = true
            return
        }
        defer { sqlite3_finalize(statement) }

        // 0.95: never smear a project-level permission-ruleset update onto every
        // session. Waiting comes only from this session's tool parts.
        while sqlite3_step(statement) == SQLITE_ROW {
            let sid = sqliteString(statement, column: 0)
            guard !sid.isEmpty else { continue }
            let title = sqliteString(statement, column: 1)
            let cwd = normalizedPath(sqliteString(statement, column: 2))
            let agent = sqliteString(statement, column: 3)
            let model = modelIdentifier(sqliteString(statement, column: 4))
            let tin = sqlite3_column_int64(statement, 5)
            let tout = sqlite3_column_int64(statement, 6)
            let created = sqlite3_column_int64(statement, 7)
            let updated = sqlite3_column_int64(statement, 8)
            let files = sqlite3_column_int64(statement, 9)
            guard !title.isEmpty || !cwd.isEmpty || tin > 0 || tout > 0 else { continue }

            var values: [String: Any] = [
                "sessionId": sid,
                "title": title,
                "cwd": cwd,
                "agentMode": agent,
                "model": model,
                "inputTokens": tin,
                "outputTokens": tout,
                "filesChanged": files,
            ]
            var fact = fact(from: values, context: "opencode.session", structured: true, path: url.path)
            fact.sessionID = sid
            fact.activityMs = normalizeTimestamp(updated) > 0
                ? normalizeTimestamp(updated)
                : fileMTime(url)
            fact.startedMs = normalizeTimestamp(created)
            fact.records = openCodePartCount(database, sessionID: sid)
            enrichOpenCodeParts(database, sessionID: sid, fact: &fact)
            if fact.hasUsefulSignal { facts.append(fact) }
            if facts.count >= maxFactsPerAgent { break }
            values.removeAll(keepingCapacity: false)
        }
    }

    private static func openCodePartCount(_ database: OpaquePointer, sessionID: String) -> Int {
        let sql = "SELECT COUNT(*) FROM part WHERE session_id = ?"
        guard let statement = sqlitePrepare(database, sql) else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqliteBind(statement, index: 1, text: sessionID), sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return max(0, Int(sqlite3_column_int64(statement, 0)))
    }

    private static func enrichOpenCodeParts(_ database: OpaquePointer, sessionID: String, fact: inout Fact) {
        let sql = "SELECT data FROM part WHERE session_id = ? ORDER BY time_updated DESC LIMIT 80"
        guard let statement = sqlitePrepare(database, sql), sqliteBind(statement, index: 1, text: sessionID) else { return }
        defer { sqlite3_finalize(statement) }
        // Newest tool status wins — do not OR historical pending across the
        // whole transcript (0.95 Extinguish Honesty).
        var decidedPending = false
        while sqlite3_step(statement) == SQLITE_ROW {
            let raw = sqliteString(statement, column: 0)
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any]
            else { continue }
            let type = firstString(dict, keys: ["type"]).lowercased()
            if type == "tool", fact.tool.isEmpty {
                fact.tool = clean(firstString(dict, keys: ["tool", "name"]), limit: 64)
            }
            if type == "tool", let state = dict["state"] as? [String: Any], !decidedPending {
                let status = firstString(state, keys: ["status"]).lowercased()
                let tool = firstString(dict, keys: ["tool", "name"]).lowercased()
                if status == "running" || status == "pending" || status == "waiting" {
                    fact.phase = "working"
                }
                if status == "pending" || status == "waiting" {
                    // Ask/permission-like tools, or an explicit pending state on
                    // an edit/bash that OpenCode blocked on the user.
                    let askLike = ["permission", "ask", "question", "confirm"].contains {
                        tool == $0 || tool.contains($0)
                    }
                    if askLike || status == "pending" {
                        fact.explicitPending = true
                        fact.skill = "pending"
                    }
                    decidedPending = true
                } else if status.contains("complete") || status == "error" || status == "rejected" {
                    fact.outcome = status.contains("complete") ? "completed" : fact.outcome
                    decidedPending = true
                }
            }
            if type == "step-finish" || type == "step_finish" {
                fact.phase = fact.phase.isEmpty ? "turn_complete" : fact.phase
                let reason = firstString(dict, keys: ["reason"]).lowercased()
                if ["stop", "complete", "completed"].contains(reason) { fact.outcome = "completed" }
            }
        }
    }

    private struct WarpQuery {
        var timestamp: Int64 = 0
        var cwd = ""
        var status = ""
        var model = ""
        var input = ""
    }

    private static func collectWarpDatabase(
        _ database: OpaquePointer,
        url: URL,
        into facts: inout [Fact],
        error: inout Bool
    ) {
        var queries: [String: WarpQuery] = [:]
        var queryCounts: [String: Int] = [:]
        if let statement = sqlitePrepare(database, "SELECT conversation_id, start_ts, working_directory, output_status, model_id, input FROM ai_queries ORDER BY start_ts DESC LIMIT 512") {
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqliteString(statement, column: 0)
                guard !id.isEmpty else { continue }
                queryCounts[id, default: 0] += 1
                if queries[id] == nil {
                    queries[id] = WarpQuery(
                        timestamp: normalizeTimestamp(sqliteString(statement, column: 1)),
                        cwd: normalizedPath(sqliteString(statement, column: 2)),
                        status: sqliteString(statement, column: 3),
                        model: sqliteString(statement, column: 4),
                        input: sqliteString(statement, column: 5)
                    )
                }
            }
        }
        var taskCounts: [String: Int] = [:]
        if let statement = sqlitePrepare(database, "SELECT conversation_id, COUNT(*) FROM agent_tasks GROUP BY conversation_id") {
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                taskCounts[sqliteString(statement, column: 0)] = max(0, Int(sqlite3_column_int64(statement, 1)))
            }
        }
        guard let statement = sqlitePrepare(database, "SELECT conversation_id, last_modified_at, summary, conversation_data FROM agent_conversations ORDER BY last_modified_at DESC LIMIT \(maxRowsPerAgent)") else {
            error = true
            return
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let sid = sqliteString(statement, column: 0)
            guard !sid.isEmpty else { continue }
            let modified = normalizeTimestamp(sqliteString(statement, column: 1))
            let summary = jsonObject(sqliteString(statement, column: 2)) ?? [:]
            let conversation = jsonObject(sqliteString(statement, column: 3)) ?? [:]
            let query = queries[sid]
            let title = firstString(summary, keys: ["title", "initial_query"])
            let cwd = normalizedPath(firstString(summary, keys: ["initial_working_directory"]))
                .isEmpty ? (query?.cwd ?? "") : normalizedPath(firstString(summary, keys: ["initial_working_directory"]))
            let queryText = jsonFirstText(query?.input ?? "")
            var values: [String: Any] = [
                "sessionId": sid,
                "title": title.isEmpty ? queryText : title,
                "cwd": cwd,
                "model": query?.model ?? "",
                "agentMode": "Warp Agent",
                "progressTotal": taskCounts[sid] ?? 0,
                "records": queryCounts[sid] ?? 0,
            ]
            var fact = fact(from: values, context: "warp.agent_conversation", structured: true, path: url.path)
            fact.sessionID = sid
            fact.records = queryCounts[sid] ?? 0
            fact.activityMs = query?.timestamp ?? modified
            if fact.activityMs == 0 { fact.activityMs = fileMTime(url) }
            let status = (query?.status ?? "").lowercased()
            if status.contains("progress") || status.contains("running") { fact.phase = "working" }
            if status.contains("complete") || status.contains("success") || status.contains("done") {
                fact.phase = "turn_complete"; fact.outcome = "completed"
            } else if status.contains("fail") || status.contains("error") {
                fact.phase = "turn_complete"; fact.outcome = "failed"
            } else if status.contains("cancel") || status.contains("abort") {
                fact.phase = "turn_complete"; fact.outcome = "cancelled"
            }
            // Warp is waitingSource.none — never stamp skill=pending from status.
            if fact.tool.isEmpty { fact.tool = jsonFirstTool(query?.input ?? "") }
            let usage = firstValue(conversation, keys: ["context_window_usage"])
            if let usage { fact.contextPercent = contextPercent(usage) }
            if fact.hasUsefulSignal { facts.append(fact) }
            if facts.count >= maxFactsPerAgent { break }
            values.removeAll(keepingCapacity: false)
        }
    }

    private static func collectPiDatabase(
        _ database: OpaquePointer,
        url: URL,
        home: URL,
        into facts: inout [Fact],
        error: inout Bool
    ) {
        let sql = "SELECT session_id, project_dir, started_at, last_event_at, event_count FROM session_meta ORDER BY COALESCE(last_event_at, started_at) DESC LIMIT \(maxRowsPerAgent)"
        guard let statement = sqlitePrepare(database, sql) else {
            // ~/.pi trees contain JSONL plus incidental .db files. Missing
            // session_meta is not a harvest failure — JSONL still has titles.
            return
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let sid = sqliteString(statement, column: 0)
            guard !sid.isEmpty else { continue }
            let cwd = normalizedPath(sqliteString(statement, column: 1))
            let started = normalizeTimestamp(sqliteString(statement, column: 2))
            let updated = normalizeTimestamp(sqliteString(statement, column: 3))
            let records = max(0, Int(sqlite3_column_int64(statement, 4)))
            let homePath = home.standardizedFileURL.path
            guard records > 0 || (!cwd.isEmpty && cwd != homePath) else { continue }
            var values: [String: Any] = [
                "sessionId": sid,
                "cwd": cwd,
                "agentMode": "Pi",
                "progressTotal": records,
            ]
            var fact = fact(from: values, context: "pi.context_mode.session", structured: true, path: url.path)
            fact.sessionID = sid
            fact.startedMs = started
            fact.activityMs = updated > 0 ? updated : (started > 0 ? started : fileMTime(url))
            fact.records = records
            enrichPiEvents(database, sessionID: sid, fact: &fact)
            if fact.hasUsefulSignal { facts.append(fact) }
            if facts.count >= maxFactsPerAgent { break }
            values.removeAll(keepingCapacity: false)
        }
    }

    private static func enrichPiEvents(_ database: OpaquePointer, sessionID: String, fact: inout Fact) {
        let sql = "SELECT type, category, data, project_dir, created_at, bytes_returned FROM session_events WHERE session_id = ? ORDER BY id DESC LIMIT 128"
        guard let statement = sqlitePrepare(database, sql), sqliteBind(statement, index: 1, text: sessionID) else { return }
        defer { sqlite3_finalize(statement) }
        var foundMeaningfulPrompt = false
        var decidedSessionInfo = false
        while sqlite3_step(statement) == SQLITE_ROW {
            let type = sqliteString(statement, column: 0).lowercased()
            let category = sqliteString(statement, column: 1)
            let data = sqliteString(statement, column: 2)
            // Newest events first. Keep the latest meaningful user prompt;
            // never promote file_read paths into the tray hero (those used
            // to become "Read Foo.swift" and then block a shorter JSONL title).
            if let prompt = piEventPrompt(type: type, data: data), !prompt.isEmpty {
                if meaningfulPiPrompt(prompt) {
                    if !foundMeaningfulPrompt {
                        fact.task = prompt
                        foundMeaningfulPrompt = true
                    }
                } else if !foundMeaningfulPrompt, fact.task.isEmpty || isChromeTask(fact.task) {
                    fact.task = prompt
                }
            }
            if !decidedSessionInfo, type == "session_info" {
                decidedSessionInfo = true
                let raw = firstString(jsonObject(data) ?? [:], keys: ["name", "title"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty {
                    // /name cleared — do not adopt an older session_info later.
                    if !foundMeaningfulPrompt { fact.task = "" }
                } else {
                    let name = cleanPiSessionTitle(raw)
                    if !name.isEmpty, !isChromeTask(name), !foundMeaningfulPrompt {
                        fact.task = name
                        foundMeaningfulPrompt = meaningfulPiPrompt(name)
                    }
                }
            }
            if type == "tool_call" && fact.tool.isEmpty {
                if let object = jsonObject(data) { fact.tool = clean(firstString(object, keys: ["tool", "name"]), limit: 64) }
                if fact.tool.isEmpty { fact.tool = clean(category, limit: 64) }
                fact.phase = fact.phase.isEmpty ? "working" : fact.phase
            }
            if type.contains("error") { fact.errors += 1 }
            if type == "file_read" { fact.files += 1; if fact.phase.isEmpty { fact.phase = "reading" } }
            if type.contains("sandbox") { fact.phase = "running" }
            // 0.95: never stamp pending from free-text event payloads.
            if type == "agent_usage" {
                let (tin, tout) = tokenPair(data)
                fact.tokensIn = max(fact.tokensIn, tin)
                fact.tokensOut = max(fact.tokensOut, tout)
            }
            // Prefer structured event JSON when present — agent_usage often
            // carries model + usageMetadata that the legacy tokens_in regex
            // never saw (0.82 Tray Fleet Substance).
            if let object = jsonObject(data) {
                if fact.model.isEmpty {
                    fact.model = clean(firstString(object, keys: [
                        "model", "modelId", "model_id", "modelName", "model_name",
                        "currentModel", "current_model",
                    ]), limit: 64)
                    if fact.model.isEmpty,
                       let details = object["modelDetails"] as? [String: Any]
                        ?? object["model_details"] as? [String: Any] {
                        fact.model = clean(firstString(details, keys: [
                            "modelName", "model_name", "model", "modelId", "model_id", "name",
                        ]), limit: 64)
                    }
                }
                applyTokenUsage(&fact, object)
                applyTokenUsage(&fact, object["usage"] as? [String: Any])
                applyTokenUsage(&fact, object["usageMetadata"] as? [String: Any])
                applyTokenUsage(&fact, object["usage_metadata"] as? [String: Any])
            }
            if fact.activityMs == 0 {
                fact.activityMs = normalizeTimestamp(sqliteString(statement, column: 4))
            }
            if fact.cwd.isEmpty { fact.cwd = normalizedPath(sqliteString(statement, column: 3)) }
            if Int(sqlite3_column_int64(statement, 5)) > 0 { fact.records = max(fact.records, recordsFromBytes(sqlite3_column_int64(statement, 5))) }
        }
    }

    private static func recordsFromBytes(_ bytes: Int64) -> Int { bytes > 0 ? 1 : 0 }

    private static func tokenPair(_ text: String) -> (Int, Int) {
        let input = regexInt(text, pattern: #"tokens_in\s*:\s*(\d+)"#)
        let output = regexInt(text, pattern: #"tokens_out\s*:\s*(\d+)"#)
        return (input, output)
    }

    private static func regexInt(_ text: String, pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return 0 }
        return Int(text[range]) ?? 0
    }

    private static func sqlitePrepare(_ database: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    private static func sqliteBind(_ statement: OpaquePointer, index: Int32, text: String) -> Bool {
        sqlite3_bind_text(
            statement,
            index,
            text,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        ) == SQLITE_OK
    }

    private static func modelIdentifier(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if let object = jsonObject(raw) {
            return firstString(object, keys: ["id", "model", "modelID", "model_id"])
        }
        return raw
    }

    private static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return value as? [String: Any]
    }

    private static func jsonFirstText(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return "" }
        return jsonFirstString(value, keys: ["text", "query", "prompt", "initial_query"])
    }

    private static func jsonFirstTool(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return "" }
        return jsonFirstString(value, keys: ["tool", "tool_name", "name"])
    }

    private static func jsonFirstString(_ value: Any, keys: [String]) -> String {
        if let dict = value as? [String: Any] {
            let text = firstString(dict, keys: keys)
            if !text.isEmpty { return text }
            for child in dict.values {
                if let found = jsonFirstStringOptional(child, keys: keys), !found.isEmpty { return found }
            }
        } else if let array = value as? [Any] {
            for child in array.reversed() {
                if let found = jsonFirstStringOptional(child, keys: keys), !found.isEmpty { return found }
            }
        }
        return ""
    }

    private static func jsonFirstStringOptional(_ value: Any, keys: [String]) -> String? {
        let found = jsonFirstString(value, keys: keys)
        return found.isEmpty ? nil : found
    }

    private static func isSessionPath(_ url: URL) -> Bool {
        let parts = url.pathComponents.map { $0.lowercased() }
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let namedTranscript = ["rollout", "session", "conversation", "thread", "transcript", "history"]
            .contains(where: { stem == $0 || stem.hasPrefix($0 + "-") || stem.hasPrefix($0 + "_") })
        // `sessions` / `threads` directories must count — exact needle equality
        // missed Pi's `.../sessions/*.jsonl` and Goose `session.json`.
        let partHit = parts.contains(where: { part in
            sessionNeedles.contains(where: { needle in
                part == needle || part.hasPrefix(needle)
            })
        })
        return partHit
            || parts.contains(where: { $0.contains("rollout") || $0.contains("transcript") })
            || (["jsonl", "ndjson", "json"].contains(ext) && namedTranscript)
    }

    private static func sessionIDFromPath(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let cleaned = stem.replacingOccurrences(of: "rollout-", with: "")
        guard cleaned.count >= 6,
              !["history", "sessions", "conversation", "messages"].contains(cleaned.lowercased())
        else { return "" }
        return String(cleaned.prefix(80))
    }

    private static func readWindow(
        _ url: URL,
        size: Int,
        budget: ScanBudget,
        cap: Int,
        headLimit: Int = 64_000
    ) -> String? {
        // The newest event is at the tail of the append-only transcripts. The
        // caller gives Codex a wider window because its compacted context is a
        // single large JSONL record; Pi keeps the session header and first
        // user prompt at the head and /name + compaction at the tail. Every
        // window remains bounded by the process-wide 48 MB budget.
        let headSize = max(64_000, headLimit)
        let window = max(headSize, cap)
        do {
            if size <= window {
                guard budget.reserve(size) else { return nil }
                return String(decoding: try Data(contentsOf: url, options: [.mappedIfSafe]), as: UTF8.self)
            }
            guard budget.reserve(window) else { return nil }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let tailSize = window - headSize
            var head = try handle.read(upToCount: headSize) ?? Data()
            // A Pi user turn can be one JSONL record larger than the head
            // slice. Split records fail JSON parse and the tray hero goes
            // blank. Extend to the next newline so the first prompt survives.
            if head.last != 0x0A {
                var extra = 0
                while extra < 2_000_000 {
                    guard budget.reserve(64_000) else { break }
                    guard let chunk = try handle.read(upToCount: 64_000), !chunk.isEmpty else { break }
                    head.append(chunk)
                    extra += chunk.count
                    if chunk.contains(0x0A) { break }
                }
            }
            if let lastNL = head.lastIndex(of: 0x0A) {
                head = Data(head[head.startIndex...lastNL])
            }
            handle.seek(toFileOffset: UInt64(max(0, size - tailSize)))
            var tail = try handle.read(upToCount: tailSize) ?? Data()
            if let firstNL = tail.firstIndex(of: 0x0A), firstNL > tail.startIndex {
                tail = Data(tail[tail.index(after: firstNL)...])
            }
            // The tail can begin in the middle of a multi-byte character (or
            // a JSONL record). Lossy UTF-8 decoding keeps the following
            // complete lines available instead of turning one large rollout
            // into an empty adapter result.
            return String(decoding: head + Data("\n".utf8) + tail, as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// Cursor keeps its composer headers in SQLite rather than JSON files.
    /// Foundation has no high-level SQLite API, but macOS ships the SQLite3
    /// C module; using its read-only interface keeps this adapter native and
    /// avoids reviving the Python dependency just for Cursor.
    private static func collectCursorDatabase(
        _ url: URL,
        into facts: inout [Fact],
        budget: ScanBudget,
        error: inout Bool
    ) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // SQLite is queried by indexed metadata rather than copied into
        // memory. Reserve the same bounded budget as a large text window but
        // do not discard a real Cursor database merely because its cache grew.
        guard size > 0, budget.reserve(min(size, maxFileBytes)) else { return }
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            error = true
            if database != nil { sqlite3_close(database) }
            return
        }
        defer { sqlite3_close(database) }

        let composerSQL = """
        SELECT composerId, workspaceId, lastUpdatedAt, value
        FROM composerHeaders
        WHERE IFNULL(isArchived, 0) = 0 AND IFNULL(isSubagent, 0) = 0
        ORDER BY lastUpdatedAt DESC
        LIMIT \(maxRowsPerAgent)
        """
        // Cursor versions do not all ship the cloud-agent ItemTable. Treat
        // each table as an optional capability: a missing table must not turn
        // valid Composer data into a collector failure. Lock/corrupt errors
        // still surface through sqliteReadFailed below.
        if let statement = sqlitePrepare(database, composerSQL) {
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let sessionID = sqliteString(statement, column: 0)
                guard !sessionID.isEmpty, sessionID != "empty-state-draft" else { continue }
                let workspaceID = sqliteString(statement, column: 1)
                let updated = sqlite3_column_int64(statement, 2)
                let value = sqliteString(statement, column: 3)
                // Composer headers are compact metadata objects without a
                // session-shaped filename. Give the parser an explicit
                // session context so usage/pending/file fields survive the
                // conservative identity gate instead of falling back to a
                // title-only Fact.
                var parsed = parseFacts(
                    value,
                    structured: true,
                    path: url.path + "/composer"
                )
                if parsed.isEmpty { parsed = [Fact()] }
                for index in parsed.indices {
                    parsed[index].sessionID = sessionID
                    if parsed[index].task.isEmpty, let object = jsonObject(value) {
                        // Cursor's composer header calls the user-visible title
                        // `name`, unlike the transcript adapters' `title`.
                        parsed[index].task = clean(firstString(object, keys: ["name", "subtitle", "title"]), limit: 160)
                    }
                    parsed[index].cwd = parsed[index].cwd.isEmpty
                        ? cursorWorkspacePath(databaseURL: url, workspaceID: workspaceID)
                        : parsed[index].cwd
                    parsed[index].project = parsed[index].project.isEmpty
                        ? lastPathComponent(parsed[index].cwd)
                        : parsed[index].project
                    parsed[index].activityMs = updated > 0 ? updated : fileMTime(url)
                    parsed[index].sourcePath = url.path
                    parsed[index].structured = true
                    // Do not invent mode=local — readableMode strips it and the
                    // observation line goes blank (0.81). Prefer vendor keys.
                    if parsed[index].mode.isEmpty, let object = jsonObject(value) {
                        parsed[index].mode = firstString(object, keys: [
                            "unifiedMode", "unified_mode", "composerMode", "composer_mode",
                            "agentMode", "agent_mode", "mode", "role",
                        ])
                    }
                    // Composer headers nest the display model under modelDetails
                    // more often than a top-level model key (0.82).
                    if parsed[index].model.isEmpty, let object = jsonObject(value) {
                        parsed[index].model = firstString(object, keys: [
                            "model", "modelId", "model_id", "modelName", "model_name",
                            "currentModel", "current_model",
                        ])
                        if parsed[index].model.isEmpty,
                           let details = object["modelDetails"] as? [String: Any]
                            ?? object["model_details"] as? [String: Any] {
                            parsed[index].model = firstString(details, keys: [
                                "modelName", "model_name", "model", "modelId", "model_id", "name",
                            ])
                        }
                    }
                }
                let remaining = max(0, maxFactsPerAgent - facts.count)
                if remaining > 0 {
                    facts.append(contentsOf: parsed.filter { $0.hasUsefulSignal && $0.hasDisplaySignal }.prefix(remaining))
                }
                if facts.count >= maxFactsPerAgent { break }
            }
        } else if sqliteReadFailed(database) {
            error = true
        }

        // Cloud Agent rows are stored as JSON arrays in ItemTable. They have a
        // stable id/title/status even when no local composer transcript exists.
        let cloudSQL = "SELECT value FROM ItemTable WHERE key LIKE 'cloudAgentRepository.agents.%'"
        if let cloudStatement = sqlitePrepare(database, cloudSQL) {
            defer { sqlite3_finalize(cloudStatement) }
            while sqlite3_step(cloudStatement) == SQLITE_ROW {
                let value = sqliteString(cloudStatement, column: 0)
                guard let data = value.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let list = object as? [Any]
                else { continue }
                for item in list {
                    guard let meta = item as? [String: Any] else { continue }
                    let sid = firstString(meta, keys: ["bcId", "id"])
                    guard !sid.isEmpty else { continue }
                    var fact = fact(from: meta, context: "cloudAgentRepository", structured: true, path: url.path)
                    fact.sessionID = sid
                    fact.project = fact.project.isEmpty
                        ? lastPathComponent(firstString(meta, keys: ["repoUrl", "repository"]))
                        : fact.project
                    let status = firstNumber(meta, keys: ["status"])
                    if fact.phase.isEmpty { fact.phase = status == 1 ? "running" : status == 2 ? "completed" : "" }
                    fact.mode = fact.mode.isEmpty ? "cloud" : fact.mode
                    fact.activityMs = normalizeTimestamp(firstValue(meta, keys: ["updatedAt", "updated_at"]))
                    if fact.activityMs == 0 { fact.activityMs = fileMTime(url) }
                    guard fact.hasUsefulSignal && fact.hasDisplaySignal else { continue }
                    if facts.count < maxFactsPerAgent { facts.append(fact) }
                    if facts.count >= maxFactsPerAgent { break }
                }
                if facts.count >= maxFactsPerAgent { break }
            }
        } else if sqliteReadFailed(database) {
            error = true
        }
        if sqliteReadFailed(database) { error = true }
    }

    private static func sqliteReadFailed(_ database: OpaquePointer) -> Bool {
        switch sqlite3_errcode(database) {
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_CORRUPT, SQLITE_NOTADB:
            return true
        default:
            return false
        }
    }

    private static func sqliteString(_ statement: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private static func cursorWorkspacePath(databaseURL: URL, workspaceID: String) -> String {
        guard !workspaceID.isEmpty else { return "" }
        let user = databaseURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = user
            .appendingPathComponent("workspaceStorage")
            .appendingPathComponent(workspaceID)
            .appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: workspace),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = object["folder"] as? String
        else { return "" }
        return normalizedPath(folder)
    }

    private static func normalizeTimestamp(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            if raw > 10_000_000_000 { return Int64(raw) }
            return Int64(raw * 1000)
        }
        let text = stringValue(value)
        if let raw = Double(text), raw.isFinite, raw > 0 {
            return raw > 10_000_000_000 ? Int64(raw) : Int64(raw * 1000)
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return Int64(date.timeIntervalSince1970 * 1000) }
        let formats = ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"]
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            parser.dateFormat = format
            if let date = parser.date(from: text) { return Int64(date.timeIntervalSince1970 * 1000) }
        }
        return 0
    }

    private static func fileMTime(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate
        else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    // MARK: - Conservative metadata extraction

    private static func parseFacts(_ text: String, structured: Bool, path: String) -> [Fact] {
        if path.lowercased().contains("/.codex/") && path.lowercased().hasSuffix(".jsonl") {
            let codex = parseCodexFacts(text, path: path)
            if !codex.isEmpty { return codex }
        }
        let lowerPath = path.lowercased()
        if lowerPath.contains("/.pi/"),
           lowerPath.hasSuffix(".jsonl") || lowerPath.hasSuffix(".ndjson") {
            let pi = parsePiFacts(text, path: path)
            if !pi.isEmpty { return pi }
            // Official envelopes without a parseable user prompt must not
            // fall through to the generic walker — that produced cwd-only
            // rows whose tray hero was the project folder name.
            if piLooksOfficial(text) { return [] }
        }
        var objects: [(Any, String)] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
           let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            objects.append((object, ""))
        } else {
            for line in text.split(whereSeparator: \.isNewline).suffix(256) {
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (value.hasPrefix("{") || value.hasPrefix("[")),
                      let data = value.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                else { continue }
                objects.append((object, ""))
            }
        }

        var result: [Fact] = []
        var visited = 0
        for (object, context) in objects {
            walk(object, context: context, structured: structured, path: path, into: &result, visited: &visited)
            if result.count >= maxFactsPerAgent { break }
        }
        var merged = merge(result).filter(\.hasDisplaySignal)
        if usesTranscriptUserPrompt(path),
           let prompt = latestTranscriptUserPrompt(text),
           meaningfulPiPrompt(prompt) {
            if merged.isEmpty {
                var seed = Fact()
                seed.structured = structured
                seed.sourcePath = path
                seed.task = prompt
                merged = [seed]
            } else {
                for index in merged.indices { merged[index].task = prompt }
            }
        }
        return merged
    }

    /// Claude / Command Code / Continue / Droid / Gemini chats keep one goal
    /// per file. Generic JSONL only walks the last 256 lines, so a long
    /// tool-result tail blanks the hero — same class as the Pi 0.96.1 bug.
    private static func usesTranscriptUserPrompt(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/amp/") { return false }
        if lower.contains("/.claude/") { return true }
        if lower.contains("/.commandcode/") { return true }
        if lower.contains("/.continue/") { return true }
        if lower.contains("/.factory/") { return true }
        if lower.contains("/.gemini/") && lower.contains("/chats/") { return true }
        return false
    }

    private static func latestTranscriptUserPrompt(_ text: String) -> String? {
        var candidates: [String] = []
        var attempts = 0
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.hasPrefix("{"), raw.contains("\"user\"") else { continue }
            attempts += 1
            if attempts > 4096 { break }
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let title = cleanPiSessionTitle(transcriptUserPrompt(from: object))
            if !title.isEmpty { candidates.append(title) }
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.first(where: { meaningfulPiPrompt($0) }) ?? candidates[0]
    }

    private static func transcriptUserPrompt(from dict: [String: Any]) -> String {
        if let nested = dict["message"] as? [String: Any],
           firstString(nested, keys: ["role", "type", "kind"]).lowercased() == "user" {
            let text = userMessageText(nested["content"] ?? nested["text"])
            if !text.isEmpty { return text }
        }
        if isUserRecord(dict) {
            return userMessageText(firstValue(dict, keys: ["content", "text", "message"]))
        }
        return ""
    }

    /// Visible user text only — skip tool_result / tool_call envelopes.
    /// Command Code (and Claude) store tool results as role=user records.
    private static func userMessageText(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { item -> String? in
                if let text = item as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                guard let dict = item as? [String: Any] else { return nil }
                if isToolEnvelope(dict) { return nil }
                let text = firstString(dict, keys: ["text"])
                if !text.isEmpty { return text }
                if ["input_text", "output_text", "text"].contains(
                    firstString(dict, keys: ["type"]).lowercased().replacingOccurrences(of: "-", with: "_")
                ) {
                    let nested = firstString(dict, keys: ["content"])
                    return nested.isEmpty ? nil : nested
                }
                return nil
            }
            return parts.joined(separator: " ")
        }
        if let dict = value as? [String: Any] {
            if isToolEnvelope(dict) { return "" }
            let text = firstString(dict, keys: ["text"])
            if !text.isEmpty { return text }
            return userMessageText(dict["content"])
        }
        return ""
    }

    private static func isToolEnvelope(_ dict: [String: Any]) -> Bool {
        let kind = firstString(dict, keys: ["type"]).lowercased().replacingOccurrences(of: "-", with: "_")
        let tools: Set<String> = [
            "tool_result", "tool_call_output", "custom_tool_call_output",
            "function_call_output", "function_response", "mcp_tool_call_end",
            "tool_use", "tool_call", "function_call", "custom_tool_call",
            "mcp_tool_call", "functioncall",
        ]
        return tools.contains(kind)
    }

    private static func isToolShapedRecord(_ dict: [String: Any]) -> Bool {
        if isToolEnvelope(dict) { return true }
        let kind = firstString(dict, keys: ["type"]).lowercased().replacingOccurrences(of: "-", with: "_")
        return kind == "file_read" || kind == "tool_use" || kind == "tool_call"
    }

    private static func cwdKeys(for dict: [String: Any]) -> [String] {
        var keys = [
            "cwd", "workingDirectory", "workdir", "workDir", "workspacePath", "workspace_path",
            "projectPath", "project_path", "directory", "worktree", "repoPath",
            "workspace",
        ]
        // `path` is a Cline/Cascade workspace alias on session objects, and a
        // file argument on tool_use. Only the former is a cwd.
        if !isToolShapedRecord(dict) {
            keys.append("path")
        }
        return keys
    }

    private static func parseCodexFacts(_ text: String, path: String) -> [Fact] {
        var f = Fact()
        f.structured = true
        f.sourcePath = path
        var latestTimestamp: Int64 = 0
        let lines = text.split(whereSeparator: \.isNewline)
        // The head of a Codex rollout contains a very large tool registry.
        // Inspect only the tail event stream plus the compact session header;
        // walking the registry first used to return `mode=auto` as if it were
        // the user's task and starved the actual prompt.
        let candidates = Array(lines.prefix(8)) + Array(lines.suffix(2048))
        for line in candidates {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            latestTimestamp = max(latestTimestamp, normalizeTimestamp(object["timestamp"]))
            let type = firstString(object, keys: ["type"]).lowercased()
            // Older/local Codex rollout fixtures (and a few compatibility
            // exports) put session facts at the top level instead of inside a
            // typed payload. Merge those fields before handling the richer
            // event envelope so cwd/title/tool/token evidence is not lost.
            if type.isEmpty {
                var generic = fact(from: object, context: "codex.rollout", structured: true, path: path)
                // Untyped Codex head/compat lines often carry registry or plan
                // step `title` values. Keep cwd/tool/tokens; only accept task
                // from real prompt keys so tool-arg titles never become the hero.
                let prompt = firstString(object, keys: [
                    "task", "goal", "prompt", "query", "user_message", "userMessage",
                    "lastMessage", "last_message", "subject",
                ])
                if prompt.isEmpty { generic.task = "" }
                if generic.hasUsefulSignal { merge(&f, generic) }
            }
            let payload = object["payload"] as? [String: Any] ?? [:]
            let payloadType = firstString(payload, keys: ["type"]).lowercased()
            if payloadType == "session_meta" || type == "session_meta" {
                f.sessionID = firstString(payload, keys: ["session_id", "sessionId"])
                f.cwd = normalizedPath(firstString(payload, keys: ["cwd", "workdir", "workingDirectory"]))
                f.startedMs = latestTimestamp
            }
            if type == "compacted",
               let replacementHistory = payload["replacement_history"] as? [Any] {
                // Codex stores a rolling context window as one compacted JSON
                // record. It contains the latest user turn even when that
                // turn is no longer among the final 2,048 event lines.
                for item in replacementHistory {
                    guard let message = item as? [String: Any],
                          firstString(message, keys: ["role"]).lowercased() == "user"
                    else { continue }
                    let prompt = cleanCodexUserRequest(codexUserText(message["content"]))
                    if !prompt.isEmpty, meaningfulPiPrompt(prompt) || f.task.isEmpty {
                        f.task = prompt
                    }
                }
            }
            if type == "event_msg" {
                switch payloadType {
                case "user_message":
                    let prompt = firstString(payload, keys: ["message", "text", "content"])
                    let cleaned = cleanCodexUserRequest(prompt)
                    if !cleaned.isEmpty, meaningfulPiPrompt(cleaned) || f.task.isEmpty {
                        f.task = cleaned
                    }
                    f.phase = f.phase.isEmpty ? "working" : f.phase
                case "task_started", "turn_started":
                    f.phase = f.phase.isEmpty ? "working" : f.phase
                case "task_complete", "turn_complete":
                    f.phase = "turn_complete"
                    f.outcome = "completed"
                case "token_count":
                    if let info = payload["info"] as? [String: Any] {
                        // Prefer the latest turn (`last_token_usage`); fall back
                        // to cumulative totals. Matching activity_scan.codex_last_usage.
                        let usage = (info["last_token_usage"] as? [String: Any])
                            ?? (info["total_token_usage"] as? [String: Any])
                        if let usage {
                            f.tokensIn = max(f.tokensIn, firstNumber(usage, keys: [
                                "input_tokens", "inputTokens", "prompt_tokens",
                            ]))
                            f.tokensOut = max(f.tokensOut, firstNumber(usage, keys: [
                                "output_tokens", "outputTokens", "completion_tokens",
                            ]))
                        }
                    }
                default:
                    break
                }
            }
            if type == "response_item" {
                let responseType = payloadType
                if responseType == "message", firstString(payload, keys: ["role"]).lowercased() == "user" {
                    let prompt = cleanCodexUserRequest(codexUserText(payload["content"]))
                    // Continuations ("continue", "可以") stay only when the
                    // rollout has no preceding goal.
                    if !prompt.isEmpty,
                       meaningfulPiPrompt(prompt) || f.task.isEmpty {
                        f.task = prompt
                    }
                } else if responseType == "function_call" {
                    let name = firstString(payload, keys: ["name", "toolName"])
                    if !name.isEmpty { f.tool = name }
                    // Never promote tool-call argument titles into `task`.
                    // Those are plan steps / MCP labels, not the user's goal —
                    // they used to become the tray hero (e.g. update_plan titles).
                } else if responseType == "message",
                          firstString(payload, keys: ["role"]).lowercased() == "assistant" {
                    let phase = firstString(payload, keys: ["phase", "status"])
                    if !phase.isEmpty { f.phase = semanticPhase(phase) }
                }
            }
            if f.sessionID.isEmpty, contextLooksSession(path) {
                let sid = firstString(payload, keys: ["session_id", "sessionId", "thread_id"])
                if !sid.isEmpty { f.sessionID = sid }
            }
            f.records += 1
        }
        if f.sessionID.isEmpty { f.sessionID = sessionIDFromPath(URL(fileURLWithPath: path)) }
        f.activityMs = latestTimestamp > 0 ? latestTimestamp : fileMTime(URL(fileURLWithPath: path))
        if f.project.isEmpty, !f.cwd.isEmpty { f.project = lastPathComponent(f.cwd) }
        f.task = clean(f.task, limit: 160)
        f.cwd = clean(f.cwd, limit: 240)
        f.sessionID = clean(f.sessionID, limit: 80)
        f.tool = clean(f.tool, limit: 64)
        f.phase = clean(f.phase, limit: 64)
        return f.hasUsefulSignal ? [f] : []
    }

    private static func piLineMightCarryTitle(_ raw: String) -> Bool {
        // Only the line prefix — megabyte tool records must stay O(1).
        let prefix = raw.prefix(384)
        return prefix.contains("session_info")
            || prefix.contains("retainedTail")
            || prefix.contains("\"role\":\"user\"")
            || prefix.contains("\"role\": \"user\"")
            || prefix.contains("\"type\":\"session\"")
            || prefix.contains("\"type\": \"session\"")
            || prefix.contains("\"type\":\"compaction\"")
            || prefix.contains("\"type\": \"compaction\"")
    }

    private static func piLooksOfficial(_ text: String) -> Bool {
        for line in text.split(whereSeparator: \.isNewline).prefix(8) {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.hasPrefix("{") else { continue }
            let prefix = raw.prefix(384)
            if prefix.contains("\"type\":\"session\"")
                || prefix.contains("\"type\": \"session\"")
                || prefix.contains("\"type\":\"message\"")
                || prefix.contains("\"type\": \"message\"")
                || prefix.contains("\"type\":\"session_info\"")
                || prefix.contains("\"type\": \"session_info\"") {
                return true
            }
        }
        return false
    }

    /// Official Pi JSONL (`https://pi.dev/docs/latest/session-format`):
    /// `~/.pi/agent/sessions/--<cwd-with-slashes-as-dashes>--/<timestamp>_<uuid>.jsonl`
    /// with a `type:session` header, `message.content` as string *or* text
    /// blocks, optional `session_info.name`, and compaction `retainedTail`.
    /// Compatibility fixtures with a top-level `title` still fall through.
    private static func parsePiFacts(_ text: String, path: String) -> [Fact] {
        var headerID = ""
        var headerCwd = ""
        var sessionNames: [String] = []
        var userTitles: [String] = []
        var compactionUsers: [String] = []
        var compactionSummaries: [String] = []
        var latestTimestamp: Int64 = 0
        var f = Fact()
        f.structured = true
        f.sourcePath = path

        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.hasPrefix("{") else { continue }
            // Tool-result bodies can be megabytes. JSON-parsing them blew the
            // adapter deadline and left the /resume title unread.
            if raw.count > 8_192, !piLineMightCarryTitle(raw) { continue }
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let recordType = firstString(object, keys: ["type"]).lowercased()
            let stamped = normalizeTimestamp(firstValue(object, keys: [
                "timestamp", "created_at", "createdAt", "updated_at", "updatedAt",
            ]))
            if stamped > 0 { latestTimestamp = max(latestTimestamp, stamped) }

            if recordType == "session" {
                let sid = firstString(object, keys: ["id", "sessionId", "session_id"])
                if sid.count >= 8 { headerID = sid }
                let cwd = normalizedPath(firstString(object, keys: ["cwd"]))
                if !cwd.isEmpty { headerCwd = cwd }
            }
            if recordType == "session_info" {
                // Official getSessionName: latest `name`, empty/null clears.
                // Do not fall through to `title` when `name` is present and empty.
                if object["name"] != nil {
                    let raw = (object["name"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    sessionNames = raw.isEmpty ? [""] : [cleanPiSessionTitle(raw)]
                } else {
                    let title = firstString(object, keys: ["title"])
                    sessionNames = title.isEmpty ? [""] : [cleanPiSessionTitle(title)]
                }
            }
            if recordType == "compaction" {
                let summary = cleanPiSessionTitle(firstString(object, keys: ["summary"]))
                if !summary.isEmpty { compactionSummaries.append(summary) }
                if let tail = object["retainedTail"] as? [Any] {
                    for item in tail {
                        guard let message = item as? [String: Any] else { continue }
                        let role = firstString(message, keys: ["role", "type"]).lowercased()
                        if role == "user" || role == "human" {
                            let title = cleanPiSessionTitle(piContentText(message["content"]))
                            if !title.isEmpty { compactionUsers.append(title) }
                        }
                    }
                }
            }

            let userTitle = cleanPiSessionTitle(piUserText(from: object))
            if !userTitle.isEmpty { userTitles.append(userTitle) }

            var generic = fact(from: object, context: "pi.session", structured: true, path: path)
            generic.task = ""
            if recordType != "session" { generic.sessionID = "" }
            if ["tool_use", "tool_call", "function_call", "custom_tool_call", "file_read"]
                .contains(recordType) {
                // Cline-style `path` is a file, not a workspace. Adopting it
                // as cwd made long Pi transcripts look like they lived in
                // `/tmp/file-0.swift`.
                generic.cwd = ""
                generic.project = ""
            }
            if generic.hasUsefulSignal { merge(&f, generic) }
            f.records += 1
        }

        // Pi /resume shows the latest session_info.name (empty clears),
        // else the first user message. Latest turn is only a fallback when
        // the opening prompt was chrome or an env wrapper we stripped.
        let named = sessionNames.last.flatMap { name -> String? in
            if name.isEmpty { return nil }
            let cleaned = cleanPiSessionTitle(name)
            if cleaned.isEmpty || isChromeTask(cleaned) { return nil }
            return cleaned
        }
        let task = named
            ?? firstMeaningfulPiTitle(userTitles)
            ?? latestMeaningfulPiTitle(userTitles)
            ?? latestMeaningfulPiTitle(compactionUsers)
            ?? latestMeaningfulPiTitle(compactionSummaries)
            ?? ""
        if task.isEmpty, sessionNames.filter({ !$0.isEmpty }).isEmpty, userTitles.isEmpty,
           compactionUsers.isEmpty, compactionSummaries.isEmpty {
            return []
        }

        f.task = task
        if !headerID.isEmpty { f.sessionID = headerID }
        if f.sessionID.isEmpty { f.sessionID = piSessionID(from: URL(fileURLWithPath: path)) }
        if !headerCwd.isEmpty { f.cwd = headerCwd }
        if f.cwd.isEmpty { f.cwd = piCwdFromPath(path) }
        if f.project.isEmpty, !f.cwd.isEmpty { f.project = lastPathComponent(f.cwd) }
        f.activityMs = latestTimestamp > 0 ? latestTimestamp : fileMTime(URL(fileURLWithPath: path))
        f.task = clean(f.task, limit: 160)
        f.cwd = clean(f.cwd, limit: 240)
        f.sessionID = clean(f.sessionID, limit: 80)
        f.tool = clean(f.tool, limit: 64)
        f.phase = clean(f.phase, limit: 64)
        f.model = clean(f.model, limit: 64)
        return f.hasUsefulSignal ? [f] : []
    }

    private static func firstMeaningfulPiTitle(_ titles: [String]) -> String? {
        for title in titles {
            let cleaned = cleanPiSessionTitle(title)
            if cleaned.isEmpty || isChromeTask(cleaned) { continue }
            if meaningfulPiPrompt(cleaned) { return cleaned }
        }
        for title in titles {
            let cleaned = cleanPiSessionTitle(title)
            if !cleaned.isEmpty, !isChromeTask(cleaned) { return cleaned }
        }
        return nil
    }

    private static func latestMeaningfulPiTitle(_ titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        for title in titles.reversed() {
            let cleaned = cleanPiSessionTitle(title)
            if cleaned.isEmpty || isChromeTask(cleaned) { continue }
            if meaningfulPiPrompt(cleaned) { return cleaned }
        }
        for title in titles.reversed() {
            let cleaned = cleanPiSessionTitle(title)
            if !cleaned.isEmpty, !isChromeTask(cleaned) { return cleaned }
        }
        return nil
    }

    private static func piUserText(from dict: [String: Any]) -> String {
        let envelope = dict["message"] as? [String: Any]
        let role = firstString(envelope ?? dict, keys: ["role", "type", "kind"]).lowercased()
        if role == "user" || role == "human"
            || role.contains("user_message") || role.contains("user-prompt") {
            let content = envelope?["content"] ?? firstValue(dict, keys: ["content", "text", "message"])
            return piContentText(content)
        }
        if firstString(dict, keys: ["type"]).lowercased() == "message", let envelope {
            if firstString(envelope, keys: ["role", "type"]).lowercased() == "user" {
                return piContentText(envelope["content"])
            }
        }
        return ""
    }

    private static func piContentText(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { item -> String? in
                if let text = item as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                guard let dict = item as? [String: Any] else { return nil }
                let text = firstString(dict, keys: ["text"])
                return text.isEmpty ? nil : text
            }
            return parts.joined(separator: " ")
        }
        if let dict = value as? [String: Any] {
            return piContentText(dict["content"] ?? dict["text"])
        }
        return ""
    }

    private static func piEventPrompt(type: String, data: String) -> String? {
        if type == "file_read" { return nil }
        if let object = jsonObject(data) {
            let fromEnvelope = cleanPiSessionTitle(piUserText(from: object))
            if !fromEnvelope.isEmpty { return fromEnvelope }
            if ["intent", "user", "message", "prompt"].contains(type) {
                let nested = cleanPiSessionTitle(piContentText(
                    firstValue(object, keys: ["text", "content", "prompt", "query", "data"])
                ))
                if !nested.isEmpty { return nested }
            }
            return nil
        }
        guard ["intent", "user", "message", "prompt"].contains(type) else { return nil }
        let title = cleanPiSessionTitle(data)
        return title.isEmpty ? nil : title
    }

    private static func cleanPiSessionTitle(_ value: String) -> String {
        let stripped = stripPiContextWrappers(value)
        let title = clean(stripped, limit: 160)
        if title.count < 3 { return "" }
        let low = title.lowercased()
        if low.hasPrefix("<environment_context")
            || low.hasPrefix("<recommended_plugins")
            || low.hasPrefix("<app-context")
            || low.hasPrefix("<system-reminder") {
            return ""
        }
        return title
    }

    /// Keep the real prompt when Pi (or a wrapper) prepends env/plugin XML.
    /// Rejecting the whole string because it *starts* with those tags blanked
    /// every official user turn that carries context + goal in one `content`.
    private static func stripPiContextWrappers(_ raw: String) -> String {
        if let query = piTaggedInner(raw, name: "user_query"), query.count >= 3 {
            return query
        }
        var text = raw
        for tag in [
            "environment_context", "recommended_plugins", "app-context",
            "system-reminder", "git_status", "git-status",
        ] {
            text = piRemoveTaggedBlocks(text, name: tag)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func piTaggedInner(_ text: String, name: String) -> String? {
        let open = "<\(name)"
        let close = "</\(name)>"
        guard let start = text.range(of: open, options: .caseInsensitive),
              let gt = text.range(of: ">", range: start.upperBound..<text.endIndex),
              let end = text.range(of: close, options: .caseInsensitive, range: gt.upperBound..<text.endIndex)
        else { return nil }
        let inner = text[gt.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : String(inner)
    }

    private static func piRemoveTaggedBlocks(_ text: String, name: String) -> String {
        var s = text
        let open = "<\(name)"
        let close = "</\(name)>"
        while let start = s.range(of: open, options: .caseInsensitive) {
            if let gt = s.range(of: ">", range: start.upperBound..<s.endIndex),
               let end = s.range(of: close, options: .caseInsensitive, range: gt.upperBound..<s.endIndex) {
                s.removeSubrange(start.lowerBound..<end.upperBound)
                continue
            }
            // Truncated / unclosed env dump: drop from the open tag to the
            // end so `cwd:` lines cannot become the tray hero.
            s.removeSubrange(start.lowerBound..<s.endIndex)
            break
        }
        return s
    }

    private static func meaningfulPiPrompt(_ value: String) -> Bool {
        let title = cleanPiSessionTitle(value)
        if title.isEmpty { return false }
        let compact = title
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "？", with: "")
        let continuations: Set<String> = [
            "continue", "goon", "proceed", "resume", "keepgoing",
            "继续", "继续分析", "继续修复", "继续处理", "继续推进",
            "progress", "status", "statusupdate", "howisitgoing", "whatsprogress",
            "进展如何", "进度如何", "状态如何", "现在怎么样",
            "release", "publish", "ship", "发布", "合入发布",
        ]
        return !continuations.contains(compact)
    }

    private static func piSessionID(from url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        // Official files are `<ISO-timestamp>_<uuid>.jsonl`. The header `id`
        // is the UUID; using the whole stem blocked SQLite merge.
        if let idx = stem.lastIndex(of: "_") {
            let rest = String(stem[stem.index(after: idx)...])
            if rest.count >= 8 { return String(rest.prefix(80)) }
        }
        let generic: Set<String> = [
            "session", "sessions", "events", "event", "messages",
            "conversation", "history", "transcript", "log",
        ]
        if stem.count >= 6, !generic.contains(stem.lowercased()) {
            return String(stem.prefix(80))
        }
        let parent = url.deletingLastPathComponent().lastPathComponent
        if parent.hasPrefix("--"), parent.hasSuffix("--") { return "" }
        if parent.count >= 6, !["sessions", "agent", "pi"].contains(parent.lowercased()) {
            return String(parent.prefix(80))
        }
        return sessionIDFromPath(url)
    }

    /// `--Users-me-Pulse--` → `/Users/me/Pulse` (Pi encodes `/` as `-`).
    private static func piCwdFromPath(_ path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        guard parent.hasPrefix("--"), parent.hasSuffix("--"), parent.count > 4 else { return "" }
        var encoded = parent
        encoded.removeFirst(2)
        encoded.removeLast(2)
        guard !encoded.isEmpty else { return "" }
        return normalizedPath("/" + encoded.replacingOccurrences(of: "-", with: "/"))
    }

    /// Empty SQLite Pi rows (cwd + file_read, no prompt) must not occupy the
    /// tray when JSONL already has the session title — often under a different
    /// identity (`timestamp_uuid` vs header UUID) before 0.97.
    private static func dropEmptyPiSqliteDuplicates(_ facts: inout [Fact]) {
        let titledJSONL = facts.filter { fact in
            let path = fact.sourcePath.lowercased()
            guard path.hasSuffix(".jsonl") || path.hasSuffix(".ndjson") else { return false }
            let task = cleanPiSessionTitle(fact.task)
            return !task.isEmpty && !isChromeTask(task)
                && !AgentRow.looksLikeFilenameOnlyTitle(task)
        }
        guard !titledJSONL.isEmpty else { return }
        let ids = Set(titledJSONL.map(\.sessionID).filter { !$0.isEmpty })
        let cwds = Set(titledJSONL.map(\.cwd).filter { !$0.isEmpty })
        facts.removeAll { fact in
            let path = fact.sourcePath.lowercased()
            guard path.hasSuffix(".sqlite") || path.hasSuffix(".db") else { return false }
            let empty = fact.task.isEmpty || isChromeTask(fact.task)
                || AgentRow.looksLikeFilenameOnlyTitle(fact.task)
            guard empty else { return false }
            if !fact.sessionID.isEmpty, ids.contains(fact.sessionID) { return true }
            if !fact.cwd.isEmpty, cwds.contains(fact.cwd) { return true }
            return false
        }
    }

    private static func codexUserText(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let array = value as? [Any] {
            for item in array {
                if let dict = item as? [String: Any],
                   firstString(dict, keys: ["type"]).lowercased() == "input_text" {
                    let text = firstString(dict, keys: ["text"])
                    if !text.isEmpty { return text }
                }
                let nested = codexUserText(item)
                if !nested.isEmpty { return nested }
            }
        }
        if let dict = value as? [String: Any] {
            return firstString(dict, keys: ["text", "content", "message"])
        }
        return ""
    }

    private static func cleanCodexUserRequest(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        if let regex = try? NSRegularExpression(pattern: #"##\s+My request for Codex:\s*"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            text = String(text[range.upperBound...])
        }
        if let regex = try? NSRegularExpression(pattern: #"<image\b[^>]*>[\s\S]*?</image>"#, options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        if let regex = try? NSRegularExpression(pattern: #"<image\b[^>]*/?>"#, options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        if let regex = try? NSRegularExpression(pattern: #"\[Image\s*#[^\]]*\]\([^)]*\)"#, options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        return cleanPiSessionTitle(text)
    }

    private static func walk(
        _ object: Any,
        context: String,
        structured: Bool,
        path: String,
        into result: inout [Fact],
        visited: inout Int
    ) {
        visited += 1
        guard visited <= maxObjectNodes else { return }
        if let array = object as? [Any] {
            for child in array.prefix(512) {
                walk(child, context: context, structured: structured, path: path, into: &result, visited: &visited)
            }
            return
        }
        guard let dict = object as? [String: Any] else { return }
        let fact = fact(from: dict, context: context, structured: structured, path: path)
        if fact.hasUsefulSignal {
            result.append(fact)
        }
        for (key, child) in dict {
            guard child is [String: Any] || child is [Any] else { continue }
            let childContext = context.isEmpty ? key : "\(context).\(key)"
            walk(child, context: childContext, structured: structured, path: path, into: &result, visited: &visited)
            if result.count >= maxFactsPerAgent { return }
        }
    }

    private static func fact(
        from dict: [String: Any],
        context: String,
        structured: Bool,
        path: String
    ) -> Fact {
        var f = Fact()
        f.context = context
        f.structured = structured
        f.sourcePath = path
        f.task = firstString(dict, keys: [
            "task", "goal", "prompt", "query", "user_message", "userMessage",
            "lastMessage", "last_message", "subject",
            // Vendor chrome last — often "Agent session" / plan-step titles.
            "title", "summary", "description", "lastPrompt",
            "aiTitle", "customTitle", "subtitle",
        ])
        if (f.task.isEmpty || isChromeTask(f.task)), !isToolShapedRecord(dict) {
            let named = firstString(dict, keys: ["name"])
            if !named.isEmpty { f.task = named }
        }
        if f.task.isEmpty, isUserRecord(dict) {
            f.task = userMessageText(firstValue(dict, keys: ["content", "message", "text"]))
        }
        // Pi (and kin) wrap the user turn as `{type:"message", message:{role:"user"}}`.
        // Top-level type is "message", so isUserRecord misses it.
        if f.task.isEmpty || isChromeTask(f.task),
           let nested = dict["message"] as? [String: Any],
           firstString(nested, keys: ["role", "type", "kind"]).lowercased() == "user" {
            let prompt = userMessageText(nested["content"] ?? firstValue(nested, keys: ["text", "message"]))
            if !prompt.isEmpty { f.task = prompt }
        }
        // Cache / IDE JSON often nests the real goal under messages[] while the
        // parent title is chrome ("Cascade session"). Prefer the latest user
        // turn when the headline is empty or chrome-only — never invent text.
        if f.task.isEmpty || isChromeTask(f.task),
           let messages = dict["messages"] as? [Any] {
            for item in messages.reversed() {
                guard let msg = item as? [String: Any], isUserRecord(msg) else { continue }
                let prompt = userMessageText(firstValue(msg, keys: ["content", "message", "text", "prompt"]))
                if !prompt.isEmpty {
                    f.task = prompt
                    break
                }
            }
        }
        // Amp's modern history.jsonl deliberately keeps each user prompt as
        // `{text, cwd}` without a role/type marker. This is still a safe,
        // session-shaped source (and is the only useful source on installs
        // without hooks), so recover the prompt instead of rendering a blank
        // “Amp session” row.
        if f.task.isEmpty,
           path.lowercased().contains("/amp/"),
           path.lowercased().hasSuffix("history.jsonl"),
           !normalizedPath(firstString(dict, keys: ["cwd", "workdir", "workingDirectory"])).isEmpty {
            f.task = textValue(firstValue(dict, keys: ["text", "content", "prompt", "query"]))
        }
        f.cwd = normalizedPath(firstString(dict, keys: cwdKeys(for: dict)))
        if looksLikeFilePathCwd(f.cwd) { f.cwd = "" }
        f.project = firstString(dict, keys: ["project", "projectName", "project_name", "repository", "repoName"])
        f.sessionID = firstString(dict, keys: [
            "sessionId", "session_id", "threadId", "thread_id", "conversationId",
            "conversation_id", "rolloutId", "rollout_id", "taskId", "task_id",
        ])
        if f.sessionID.isEmpty,
           contextLooksSession(context),
           !path.lowercased().contains("/.gemini/tmp/") {
            let rawID = firstString(dict, keys: ["uuid", "id"])
            if rawID.count >= 8 { f.sessionID = rawID }
        }
        f.tool = firstString(dict, keys: [
            "currentTool", "current_tool", "lastTool", "last_tool", "lastAction",
            "last_action", "toolName", "tool_name", "tool",
        ])
        // Claude / Anthropic transcripts emit `{type:"tool_use", name:"Bash"}`
        // rather than a lastTool field. Same-dict name only — never the next
        // sibling's name (see activity_scan.last_tool_name_strict).
        if f.tool.isEmpty {
            let recordType = firstString(dict, keys: ["type"]).lowercased()
            if ["tool_use", "tool_call", "function_call", "custom_tool_call"].contains(recordType) {
                f.tool = firstString(dict, keys: ["name", "toolName", "tool_name"])
            }
        }
        // Gemini / Google-style functionCall objects (0.82).
        if f.tool.isEmpty {
            if let fc = dict["functionCall"] as? [String: Any]
                ?? dict["function_call"] as? [String: Any] {
                f.tool = firstString(fc, keys: ["name", "toolName", "tool_name"])
            }
        }
        f.skill = firstString(dict, keys: ["skill", "skillName", "skill_name"])
        let phaseRaw = firstString(dict, keys: ["phase", "stage", "currentPhase", "current_phase", "status", "state"])
        f.phase = semanticPhase(phaseRaw)
        f.outcome = firstString(dict, keys: ["outcome", "result", "completion", "finalStatus", "final_status"])
        f.model = firstString(dict, keys: [
            "model", "modelId", "model_id", "modelName", "model_name",
            "currentModel", "current_model", "current_model_id",
        ])
        if f.model.isEmpty, let details = dict["modelDetails"] as? [String: Any]
            ?? dict["model_details"] as? [String: Any] {
            f.model = firstString(details, keys: [
                "modelName", "model_name", "model", "modelId", "model_id", "name",
            ])
        }
        f.mode = firstString(dict, keys: [
            "unifiedMode", "unified_mode", "composerMode", "composer_mode",
            "agentMode", "agent_mode", "mode", "role",
        ])
        f.tokensIn = firstNumber(dict, keys: [
            "inputTokens", "input_tokens", "promptTokens", "prompt_tokens",
            "inputTokenCount", "input_token_count", "promptTokenCount",
        ])
        f.tokensOut = firstNumber(dict, keys: [
            "outputTokens", "output_tokens", "completionTokens", "completion_tokens",
            "outputTokenCount", "output_token_count", "completionTokenCount",
            "candidatesTokenCount", "candidates_token_count",
        ])
        // Claude / Anthropic: model + usage live under `message`, not the
        // envelope. Dig once so tray observation is not empty when walk order
        // would otherwise drop a child-only fragment (0.81).
        if let message = dict["message"] as? [String: Any] {
            if f.model.isEmpty {
                f.model = firstString(message, keys: [
                    "model", "modelId", "model_id", "modelName", "currentModel", "current_model",
                ])
            }
            applyTokenUsage(&f, message["usage"] as? [String: Any])
            if f.tool.isEmpty, let content = message["content"] as? [Any] {
                for item in content.reversed() {
                    guard let block = item as? [String: Any] else { continue }
                    let blockType = firstString(block, keys: ["type"]).lowercased()
                    if ["tool_use", "tool_call", "function_call", "custom_tool_call"].contains(blockType) {
                        let name = firstString(block, keys: ["name", "toolName", "tool_name"])
                        if !name.isEmpty { f.tool = name; break }
                    }
                }
            }
        }
        applyTokenUsage(&f, dict["usage"] as? [String: Any])
        applyTokenUsage(&f, dict["usageMetadata"] as? [String: Any])
        applyTokenUsage(&f, dict["usage_metadata"] as? [String: Any])
        if let response = dict["response"] as? [String: Any] {
            applyTokenUsage(&f, response["usage"] as? [String: Any])
            applyTokenUsage(&f, response["usageMetadata"] as? [String: Any])
        }
        f.errors = firstNumber(dict, keys: ["errorCount", "errors", "toolFailureCount", "tool_failures"])
        f.files = firstNumber(dict, keys: [
            "filesChanged", "filesChangedCount", "totalFilesTouched",
            "filesTouched", "fileCount",
        ])
        f.contextPercent = contextPercent(firstValue(dict, keys: [
            "contextWindowUsage", "contextUsagePercent", "contextPercent", "context_percent",
        ]))
        f.progressDone = firstNumber(dict, keys: ["completedTasks", "completed", "doneCount", "progressDone"])
        f.progressTotal = firstNumber(dict, keys: ["totalTasks", "total", "taskCount", "progressTotal"])
        f.subRunning = firstNumber(dict, keys: ["subagentsRunning", "subRunning", "activeSubagents"])
        f.subTotal = firstNumber(dict, keys: ["subagentsTotal", "subTotal", "totalSubagents"])
        let pendingFlagKeys = [
            "needsApproval", "needs_approval", "awaitingInput", "awaiting_input",
            "requiresAction", "requires_action", "pending",
            "hasBlockingPendingActions", "hasPendingPlan",
            // Explicit waiting-for-user flags (bool / yes / pending / waiting).
            // Do not include askResponse — in Cline that field means the user
            // already answered; see vendorAskFieldPending.
            "isWaitingForResponse", "is_waiting_for_response",
            "waitingForResponse", "waiting_for_response",
            "isAwaitingUserResponse", "is_awaiting_user_response",
            "userResponseNeeded", "user_response_needed",
            "didAskFollowupQuestion", "did_ask_followup_question",
            // 0.94 Waiting Proof — additional explicit vendor flags only.
            "requiresUserAction", "requires_user_action",
            "awaitingConfirmation", "awaiting_confirmation",
            "isBlockedOnUser", "is_blocked_on_user",
            "blockedOnUser", "blocked_on_user",
        ]
        // 0.95: any true flag wins — firstValue was nondeterministic across aliases.
        let flagPending = anyTruthy(dict, keys: pendingFlagKeys)
        let answeredAsk = vendorAskAlreadyAnswered(dict)
        let terminalOutcome = isTerminalSessionState(phaseRaw) || isTerminalSessionState(f.outcome)
            || isTerminalSessionState(firstString(dict, keys: ["status", "state", "lifecycle"]))
        let askToolPending = isVendorAskTool(f.tool) && !answeredAsk && !terminalOutcome
        f.explicitPending = !answeredAsk && !terminalOutcome && (
            flagPending
                || pendingPhase(phaseRaw)
                || pendingPhase(f.outcome)
                || askToolPending
                || vendorAskFieldPending(dict)
        )
        if f.explicitPending { f.skill = "pending" }
        let stamped = normalizeTimestamp(firstValue(dict, keys: [
            "lastUpdatedAt", "last_updated_at", "updatedAt", "updated_at",
            "time_updated", "timestamp", "modifiedAt", "modified_at",
        ]))
        if stamped > 0 { f.activityMs = stamped }

        if f.project.isEmpty, !f.cwd.isEmpty { f.project = lastPathComponent(f.cwd) }
        f.task = clean(f.task, limit: 160)
        f.project = clean(f.project, limit: 64)
        f.cwd = clean(f.cwd, limit: 240)
        f.sessionID = clean(f.sessionID, limit: 80)
        f.tool = clean(f.tool, limit: 64)
        f.skill = clean(f.skill, limit: 64)
        f.model = clean(f.model, limit: 64)
        f.mode = clean(f.mode, limit: 64)
        f.phase = clean(f.phase, limit: 64)
        f.outcome = clean(f.outcome, limit: 64)
        f.score = [
            !f.task.isEmpty, !f.cwd.isEmpty, !f.sessionID.isEmpty,
            !f.tool.isEmpty, !f.phase.isEmpty, !f.model.isEmpty,
            f.tokensIn > 0 || f.tokensOut > 0, f.progressTotal > 0,
        ].filter { $0 }.count
        return f
    }

    private static func textFacts(_ text: String, structured: Bool, path: String) -> Fact? {
        var f = Fact()
        f.structured = structured
        f.sourcePath = path
        f.task = regexValue(text, patterns: [
            #"(?i)\"(?:task|title|summary|subject|prompt)\"\s*:\s*\"([^\"]{1,240})\""#,
        ])
        f.cwd = normalizedPath(regexValue(text, patterns: [
            #"(?i)\"(?:cwd|workdir|workingDirectory|workspacePath)\"\s*:\s*\"([^\"]+)\""#,
        ]))
        f.sessionID = regexValue(text, patterns: [
            #"(?i)\"(?:sessionId|session_id|threadId|conversationId|rolloutId)\"\s*:\s*\"([^\"]{6,100})\""#,
        ])
        f.model = regexValue(text, patterns: [#"(?i)\"(?:model|modelId)\"\s*:\s*\"([^\"]+)\""#])
        f.tool = regexValue(text, patterns: [#"(?i)\"(?:lastTool|lastAction|toolName)\"\s*:\s*\"([^\"]+)\""#])
        f.phase = semanticPhase(regexValue(text, patterns: [#"(?i)\"(?:phase|stage|status|state)\"\s*:\s*\"([^\"]+)\""#]))
        f.outcome = regexValue(text, patterns: [#"(?i)\"(?:outcome|result|finalStatus)\"\s*:\s*\"([^\"]+)\""#])
        if pendingPhase(f.phase) || pendingPhase(f.outcome) { f.skill = "pending" }
        if f.project.isEmpty, !f.cwd.isEmpty { f.project = lastPathComponent(f.cwd) }
        f.task = clean(f.task, limit: 160)
        f.cwd = clean(f.cwd, limit: 240)
        f.project = clean(f.project, limit: 64)
        f.sessionID = clean(f.sessionID, limit: 80)
        f.model = clean(f.model, limit: 64)
        f.tool = clean(f.tool, limit: 64)
        f.phase = clean(f.phase, limit: 64)
        f.outcome = clean(f.outcome, limit: 64)
        return f.hasUsefulSignal ? f : nil
    }

    private static func merge(_ input: [Fact]) -> [Fact] {
        var byID: [String: Fact] = [:]
        for item in input {
            guard item.hasUsefulSignal else { continue }
            let key = item.identity
            if var current = byID[key] {
                merge(&current, item)
                byID[key] = current
            } else {
                byID[key] = item
            }
        }
        return byID.values.sorted {
            if $0.activityMs != $1.activityMs { return $0.activityMs > $1.activityMs }
            return $0.score > $1.score
        }
    }

    private static func merge(_ target: inout Fact, _ source: Fact) {
        if piJSONLResumeTitle(target.sourcePath, target.task), isPiSqlitePath(source.sourcePath) {
            // JSONL is the /resume title. SQLite's latest turn must not
            // replace it just because it is longer.
        } else if piJSONLResumeTitle(source.sourcePath, source.task), isPiSqlitePath(target.sourcePath) {
            target.task = source.task
        } else {
            preferTask(&target.task, source.task)
        }
        func prefer(_ old: inout String, _ new: String) { if old.isEmpty, !new.isEmpty { old = new } }
        prefer(&target.project, source.project)
        if looksLikeFilePathCwd(target.cwd), !source.cwd.isEmpty, !looksLikeFilePathCwd(source.cwd) {
            target.cwd = source.cwd
        } else {
            prefer(&target.cwd, source.cwd)
        }
        prefer(&target.sessionID, source.sessionID)
        // Last non-empty tool / model wins — Claude assistant envelopes arrive
        // after the user prompt; prefer-first left rows without telemetry.
        if !source.tool.isEmpty { target.tool = source.tool }
        // 0.95: pending follows the newest fragment by activityMs — never OR
        // an older ask onto a newer answered/cleared turn.
        if source.activityMs > target.activityMs {
            target.explicitPending = source.explicitPending
            if source.explicitPending || source.skill == "pending" {
                target.skill = "pending"
            } else if target.skill == "pending" {
                target.skill = source.skill
            } else {
                prefer(&target.skill, source.skill)
            }
        } else if source.activityMs == target.activityMs {
            target.explicitPending = target.explicitPending || source.explicitPending
            if target.explicitPending {
                target.skill = "pending"
            } else {
                prefer(&target.skill, source.skill)
            }
        } else if target.skill.isEmpty, source.skill != "pending", !source.explicitPending {
            prefer(&target.skill, source.skill)
        }
        prefer(&target.phase, source.phase); prefer(&target.outcome, source.outcome)
        if !source.model.isEmpty { target.model = source.model }
        if !source.mode.isEmpty { target.mode = source.mode }
        // Latest turn usage wins (Claude assistant envelopes; matches Codex
        // last_token_usage semantics). Never sum every turn into the tray.
        if source.tokensIn > 0 { target.tokensIn = source.tokensIn }
        if source.tokensOut > 0 { target.tokensOut = source.tokensOut }
        target.errors = max(target.errors, source.errors); target.files = max(target.files, source.files)
        target.contextPercent = max(target.contextPercent, source.contextPercent)
        target.progressDone = max(target.progressDone, source.progressDone)
        target.progressTotal = max(target.progressTotal, source.progressTotal)
        target.subRunning = max(target.subRunning, source.subRunning)
        target.subTotal = max(target.subTotal, source.subTotal)
        // explicitPending already resolved above by activityMs order — do not OR.
        target.score = max(target.score, source.score)
        target.activityMs = max(target.activityMs, source.activityMs)
        target.startedMs = target.startedMs == 0 ? source.startedMs : min(target.startedMs, source.startedMs == 0 ? target.startedMs : source.startedMs)
        target.records = max(target.records, source.records)
        target.structured = target.structured || source.structured
    }

    /// Prefer a real user goal over chrome titles when merging fragments.
    private static func preferTask(_ old: inout String, _ new: String) {
        if new.isEmpty { return }
        if old.isEmpty { old = new; return }
        let oldChrome = isChromeTask(old)
        let newChrome = isChromeTask(new)
        if oldChrome, !newChrome { old = new; return }
        if newChrome { return }
        if AgentRow.looksLikeFilenameOnlyTitle(new) { return }
        if AgentRow.looksLikeFilenameOnlyTitle(old) { old = new; return }
        // Tool-result dumps are long; a later short user goal must still win.
        if old.count > 200, new.count + 8 < old.count, meaningfulPiPrompt(new) {
            old = new
            return
        }
        if new.count >= old.count + 8 { old = new }
    }

    private static func isPiSqlitePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.contains("/.pi/") else { return false }
        return lower.hasSuffix(".sqlite") || lower.hasSuffix(".db")
    }

    private static func piJSONLResumeTitle(_ path: String, _ task: String) -> Bool {
        let lower = path.lowercased()
        guard lower.contains("/.pi/"),
              lower.hasSuffix(".jsonl") || lower.hasSuffix(".ndjson")
        else { return false }
        let cleaned = cleanPiSessionTitle(task)
        return !cleaned.isEmpty && !isChromeTask(cleaned)
            && !AgentRow.looksLikeFilenameOnlyTitle(cleaned)
    }

    private static func isChromeTask(_ value: String) -> Bool {
        let t = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let chrome: Set<String> = [
            "new session", "new chat", "untitled", "agent session", "chat",
            "amp session", "pi session", "grok session", "cursor session",
            "opencode session", "gemini session", "goose session",
            "copilot session", "continue session", "warp session",
            "windsurf session", "cline session", "roo session",
            "cascade session", "aider session", "droid session", "kimi session",
        ]
        if chrome.contains(t) { return true }
        // Exact vendor placeholders only. `hasSuffix(" session")` dropped
        // real Pi `/name` titles like "Auth session".
        return false
    }

    /// Cline/Roo/Cascade (+ kin) ask tool ids — exact tokens only, never free-text inference.
    private static func isVendorAskTool(_ tool: String) -> Bool {
        let normalized = tool.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let markers: Set<String> = [
            "ask_followup_question", "askfollowupquestion",
            "waiting_for_response", "waitingforresponse",
            "ask_user", "askuser",
            "ask_clarifying_question", "askclarifyingquestion",
            "request_user_input", "requestuserinput",
            // 0.94 Waiting Proof — additional exact vendor ask tools.
            "ask_question", "askquestion",
            "ask_user_question", "askuserquestion",
            "confirm_with_user", "confirmwithuser",
            "get_user_input", "getuserinput",
            "request_approval", "requestapproval",
        ]
        return markers.contains(normalized)
    }

    /// Cline (and kin) stamp an `ask` field while blocked on the user.
    /// When `askResponse` is already present, the user answered — not pending.
    private static func vendorAskAlreadyAnswered(_ dict: [String: Any]) -> Bool {
        guard let raw = firstValue(dict, keys: ["askResponse", "ask_response"]) else { return false }
        if let flag = raw as? Bool { return flag }
        let text = stringValue(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
    }

    private static func isTerminalSessionState(_ value: String) -> Bool {
        let normalized = value.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let terminals: Set<String> = [
            "completed", "complete", "done", "finished", "cancelled", "canceled",
            "error", "failed", "rejected", "aborted", "stopped",
        ]
        if terminals.contains(normalized) { return true }
        let tokens = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        return tokens.contains(where: { terminals.contains($0) })
            && !tokens.contains(where: {
                ["pending", "waiting", "awaiting", "approval", "blocked"].contains($0)
            })
    }

    private static func vendorAskFieldPending(_ dict: [String: Any]) -> Bool {
        let ask = firstString(dict, keys: ["ask", "askType", "ask_type"])
        guard !ask.isEmpty else { return false }
        if vendorAskAlreadyAnswered(dict) { return false }
        let normalized = ask.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let waitingAsks: Set<String> = [
            "followup", "command", "command_output", "completion_result",
            "tool", "use_mcp_server", "browser_action_launch",
            "resume_task", "resume_completed_task", "plan_mode_response",
            "clarifying_question", "user_input", "permission",
            "auto_approval_max_req_reached", "mistake_limit_reached",
            "new_task",
            // 0.94 — additional Cline-family ask enums (exact tokens).
            "yolo_mode_toggled", "api_req_failed",
        ]
        return waitingAsks.contains(normalized) || pendingPhase(ask)
    }

    /// Best-effort: `-Users-me-code-Pulse` → `/Users/me/code/Pulse` (Claude projects dir).
    private static func decodeClaudeProjectDir(_ name: String) -> String {
        let s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("-"), !s.contains("/") else { return "" }
        let parts = s.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return "" }
        let head = parts[0].lowercased()
        guard head == "users" || head == "home" else { return "" }
        return "/" + parts.joined(separator: "/")
    }

    /// Tool `input.path` is a file, not a workspace. Adopting it as cwd made
    /// Claude (and kin) rows look like they lived in `/tmp/file-0.swift`.
    private static func looksLikeFilePathCwd(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return AgentRow.looksLikeFilenameOnlyTitle(lastPathComponent(path))
    }

    /// Layout: `~/.claude/projects/<proj>/<sessionId>/subagents/agent-*.jsonl`
    /// Running ≈ mtime within 2 minutes (matches activity_scan.claude_subagent_counts).
    private static func claudeSubagentCounts(for sessionFile: URL) -> (running: Int, total: Int) {
        let subDir = sessionFile
            .deletingLastPathComponent()
            .appendingPathComponent(sessionFile.deletingPathExtension().lastPathComponent, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: subDir.path) else { return (0, 0) }
        guard let files = try? fm.contentsOfDirectory(
            at: subDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        let now = Date().timeIntervalSince1970
        var running = 0
        var total = 0
        for file in files {
            let name = file.lastPathComponent.lowercased()
            guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { continue }
            total += 1
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?
                .timeIntervalSince1970 ?? 0
            if mtime > 0, now - mtime <= 120 { running += 1 }
        }
        return (running, total)
    }

    private static func makeRows(from facts: [Fact], id: AgentID, home: URL) -> [ActivityHarvest.Row] {
        var seen = Set<String>()
        return facts.prefix(maxRowsPerAgent).compactMap { fact in
            guard fact.activityMs > 0 else { return nil }
            let task = clean(fact.task, limit: 160)
            let rawCwd = clean(fact.cwd, limit: 240)
            let homePath = home.standardizedFileURL.path
            let cwd = rawCwd == homePath ? "" : rawCwd
            let project = clean(fact.project.isEmpty ? lastPathComponent(cwd) : fact.project, limit: 64)
            let hasDisplaySignal = fact.hasDisplaySignal
            // A stable session id is identity, not content. Do not show blank
            // placeholders from Grok/OpenCode/Codex stores merely because the
            // vendor created an empty session record.
            guard hasDisplaySignal else { return nil }
            let normalizedTask = task.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let placeholder = [
                "new session", "new chat", "untitled", "agent session", "chat",
                "amp session", "pi session", "grok session", "cursor session",
                "opencode session", "gemini session", "goose session",
                "copilot session", "continue session", "warp session",
                "windsurf session", "cline session", "roo session",
            ].contains(normalizedTask)
            if placeholder, cwd.isEmpty, fact.tool.isEmpty, fact.phase.isEmpty,
               fact.outcome.isEmpty, fact.model.isEmpty, fact.tokensIn == 0,
               fact.tokensOut == 0, fact.errors == 0, fact.files == 0,
               fact.contextPercent == 0, fact.progressTotal == 0 {
                return nil
            }
            var sid = clean(fact.sessionID, limit: 80)
            if sid.isEmpty, fact.structured { sid = sessionIDFromPath(URL(fileURLWithPath: fact.sourcePath)) }
            let key = sid.isEmpty ? "\(task)|\(cwd)|\(fact.sourcePath)" : sid
            guard seen.insert(key).inserted else { return nil }
            // Fleet honesty: bestEffortCache adapters never advertise session
            // evidence, even when a path needle or SQLite row looked "structured".
            let sessionEvidence = fact.structured && id.harvestSource == .structuredSession
            var skill = ContentSanitizer.redact(fact.skill)
            if id.waitingSource == .none, skill == "pending" {
                skill = ""
            }
            return ActivityHarvest.Row(
                id: id,
                task: ContentSanitizer.redact(task),
                project: ContentSanitizer.redact(project),
                cwd: ContentSanitizer.redact(cwd),
                skill: skill,
                tokensIn: max(0, fact.tokensIn),
                tokensOut: max(0, fact.tokensOut),
                tool: ContentSanitizer.redact(fact.tool),
                harvestMs: fact.activityMs,
                subRunning: max(0, fact.subRunning),
                subTotal: max(0, fact.subTotal),
                sessionID: ContentSanitizer.redact(sid),
                records: max(0, fact.records),
                startedMs: max(0, fact.startedMs),
                evidence: sessionEvidence ? .session : .cache,
                phase: ContentSanitizer.redact(fact.phase),
                outcome: ContentSanitizer.redact(fact.outcome),
                model: ContentSanitizer.redact(fact.model),
                mode: ContentSanitizer.redact(fact.mode),
                errors: max(0, fact.errors),
                files: max(0, fact.files),
                contextPercent: max(0, min(100, fact.contextPercent)),
                progressDone: max(0, fact.progressDone),
                progressTotal: max(0, fact.progressTotal)
            )
        }
    }

    // MARK: - Small value helpers

    private static func applyTokenUsage(_ fact: inout Fact, _ usage: [String: Any]?) {
        guard let usage else { return }
        fact.tokensIn = max(fact.tokensIn, firstNumber(usage, keys: [
            "inputTokens", "input_tokens", "promptTokens", "prompt_tokens",
            "inputTokenCount", "input_token_count", "promptTokenCount",
        ]))
        fact.tokensOut = max(fact.tokensOut, firstNumber(usage, keys: [
            "outputTokens", "output_tokens", "completionTokens", "completion_tokens",
            "outputTokenCount", "output_token_count", "completionTokenCount",
            "candidatesTokenCount", "candidates_token_count",
        ]))
    }

    private static func normalizedKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func firstValue(_ dict: [String: Any], keys: [String]) -> Any? {
        let wanted = Set(keys.map(normalizedKey))
        for (key, value) in dict where wanted.contains(normalizedKey(key)) { return value }
        return nil
    }

    /// True if any recognized alias is a truthy pending flag (deterministic OR).
    private static func anyTruthy(_ dict: [String: Any], keys: [String]) -> Bool {
        let wanted = Set(keys.map(normalizedKey))
        for (key, value) in dict where wanted.contains(normalizedKey(key)) {
            if boolValue(value) { return true }
        }
        return false
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String {
        for key in keys {
            guard let value = firstValue(dict, keys: [key]) else { continue }
            guard let raw = value as? String else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func isUserRecord(_ dict: [String: Any]) -> Bool {
        let kind = firstString(dict, keys: ["role", "type", "kind"]).lowercased()
        guard !kind.isEmpty else { return false }
        return kind == "user" || kind == "human"
            || kind.contains("user_message") || kind.contains("user-prompt")
            || kind.contains("human_message")
    }

    private static func textValue(_ value: Any?, depth: Int = 0) -> String {
        guard depth < 4 else { return "" }
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let array = value as? [Any] {
            return array.prefix(16).compactMap { textValue($0, depth: depth + 1) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        if let dict = value as? [String: Any] {
            for key in ["text", "content", "message", "value"] {
                if let nested = firstValue(dict, keys: [key]) {
                    let text = textValue(nested, depth: depth + 1)
                    if !text.isEmpty { return text }
                }
            }
        }
        return ""
    }

    private static func firstNumber(_ dict: [String: Any], keys: [String]) -> Int {
        guard let value = firstValue(dict, keys: keys) else { return 0 }
        if let number = value as? NSNumber { return max(0, min(Int.max, number.intValue)) }
        return Int(stringValue(value).split(separator: ".").first ?? "") ?? 0
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        let text = stringValue(value).lowercased()
        return ["1", "true", "yes", "pending", "waiting"].contains(text)
    }

    private static func normalizedPath(_ value: String) -> String {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("file://") { path = String(path.dropFirst(7)).removingPercentEncoding ?? path }
        return path.hasPrefix("/") ? path : ""
    }

    private static func contextPercent(_ value: Any?) -> Int {
        let raw = stringValue(value).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")
        guard var number = Double(raw), number.isFinite, number > 0 else { return 0 }
        if number <= 1 { number *= 100 }
        return max(1, min(100, Int(number.rounded())))
    }

    private static func contextLooksSession(_ context: String) -> Bool {
        let lower = context.lowercased()
        return sessionNeedles.contains(where: { lower.contains($0) })
    }

    /// Whole-token / phrase markers only — never substring-match inside words
    /// like `depending` (historical Goose false Waiting footgun).
    private static func pendingPhase(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let phrases = [
            "needs user", "awaiting user", "awaiting approval",
            "waiting for user", "waiting for approval", "ask user",
            "user approval", "blocking pending", "has blocking",
            "waiting for response", "awaiting response",
        ]
        if phrases.contains(where: { normalized.contains($0) }) { return true }
        let tokens = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        // Bare "ask" is too broad (matches unrelated status words). Keep
        // askuser / permission / pending / waiting / approval / awaiting.
        let markers: Set<String> = [
            "pending", "waiting", "approval", "awaiting",
            "askuser", "permission", "confirm", "confirmation",
            "blocked",
        ]
        return tokens.contains(where: { markers.contains($0) })
    }

    private static func semanticPhase(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        let lower = value.lowercased()
        // Vendor lifecycle enums → stable working (0.82). Never treat Goose
        // `depending` as Waiting — that was a historical false-red footgun.
        if ["in_progress", "inprogress", "active", "busy", "thinking", "depending"]
            .contains(where: { lower == $0 || lower.replacingOccurrences(of: "_", with: "") == $0.replacingOccurrences(of: "_", with: "") }) {
            return "working"
        }
        if lower.contains("plan") { return "planning" }
        if lower.contains("read") || lower.contains("inspect") { return "reading" }
        if lower.contains("research") || lower.contains("search") { return "researching" }
        if lower.contains("test") || lower.contains("verify") { return "testing" }
        if lower.contains("build") || lower.contains("compile") { return "building" }
        if lower.contains("publish") || lower.contains("deploy") || lower.contains("release") { return "publishing" }
        if lower.contains("edit") || lower.contains("code") || lower.contains("patch") { return "editing" }
        if lower.contains("run") || lower.contains("execut") || lower.contains("command") { return "running" }
        return String(value.prefix(64))
    }

    private static func clean(_ value: String, limit: Int) -> String {
        let compact = value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(compact.prefix(limit))
    }

    private static func lastPathComponent(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        guard !leaf.isEmpty, leaf != "/", leaf.count <= 64 else { return "" }
        if leaf.range(of: #"^[0-9a-fA-F]{16,}$"#, options: .regularExpression) != nil { return "" }
        return leaf
    }

    private static func regexValue(_ text: String, patterns: [String]) -> String {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text)
            else { continue }
            let value = String(text[valueRange])
            if !value.isEmpty { return value }
        }
        return ""
    }
}

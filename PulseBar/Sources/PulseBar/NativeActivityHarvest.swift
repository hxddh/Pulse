import Foundation
import SQLite3

/// Swift-native local activity collector.
///
/// The tray must continue to work on a clean macOS machine. Earlier versions
/// forked a Python collector for every harvest and therefore made a Python
/// installation a runtime prerequisite. That second implementation was deleted
/// in 0.99; this is the only collector. It deliberately uses only
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
        /// Where the next scan should start so a budget cutoff rotates through
        /// the fleet instead of starving the same tail adapters forever.
        var nextCursor: Int = 0
    }

    struct Descriptor {
        var id: AgentID
        var roots: [URL]
        var commands: [String]
    }

    /// What kind of record a hero title came from.
    ///
    /// Until 0.98 `preferTask` ended in `new.count >= old.count + 8` — the
    /// longer string wins — with six special cases layered on top to stop tool
    /// dumps, filenames and vendor chrome from beating a short real goal.
    /// 0.96.1, 0.97.0, 0.97.1 and 0.97.2 each added one more special case and
    /// each shipped with the tray hero still wrong. Length is not evidence.
    /// A merge now compares *what kind of record* produced the title, and only
    /// falls back to first-seen when two fragments are the same kind.
    enum TaskOrigin: Int, Comparable {
        /// No title.
        case none = 0
        /// Vendor placeholder ("New chat") or a bare filename — never a goal.
        /// Assigned at compare time, never stored.
        case chrome = 1
        /// Free text recovered from an otherwise unstructured file.
        case fallbackText = 2
        /// A vendor cache headline (`title` / `summary` / `description`).
        case cacheTitle = 3
        /// A label attached to a tool call or plan step.
        case toolTitle = 4
        /// A visible user turn — the actual goal.
        case userPrompt = 5
        /// A name the user gave this session (Pi `/name`, Cursor composer).
        case sessionName = 6

        static func < (lhs: TaskOrigin, rhs: TaskOrigin) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Fact {
        /// 1.2: facts the session digest produced by reading the whole file.
        /// A window can never see them, so they arrive here already computed
        /// and are only ever copied — never re-derived from the window text.
        var loopTool = ""
        var loopCount = 0
        var sessionErrors = 0
        var toolSummary = ""
        /// 2.1: the rest of the digest's facts, carried under the same rule.
        /// None of these is ever recomputed from the window text — the window
        /// is the two ends of the file and could only contradict them.
        var sessionTokensIn = 0
        var sessionTokensOut = 0
        var recentTools: [String] = []
        var digestProgressPercent = 0
        var digestCaughtUp = false
        var bytesPerMinute = 0
        var sessionStartedMs: Int64 = 0

        var task = ""
        /// Where `task` came from. Drives merge; never rendered.
        var taskOrigin = TaskOrigin.none
        /// True when the source file was larger than its read window, so any
        /// count derived from the text is a floor rather than a total.
        var windowTruncated = false
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
        /// 2.8 · the agent's own plan and words, self-report tier. See
        /// `ActivityHarvest.Row` for what each means and why they exist.
        var planStep = ""
        var planSteps: [ActivityHarvest.PlanStep] = []
        var lastWord = ""
        var lastErrorText = ""
        var subRunning = 0
        var subTotal = 0
        var explicitPending = false
        /// `cwd` was decoded from a `-`-encoded directory name that the
        /// filesystem could not confirm. See `resolveDashEncodedPath`.
        var cwdBestEffort = false
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

    final class ErrorBox {
        var value = false
    }

    final class ScanBudget {
        private(set) var bytesRemaining: Int
        let deadline: Date

        init(deadline: Date, bytes: Int = 48_000_000) {
            self.deadline = deadline
            bytesRemaining = bytes
        }

        var exhausted: Bool { Date() >= deadline || bytesRemaining <= 0 }

        // Explain counters for the adapter currently running. Every byte a
        // collector reads already passes through `reserve`, so the budget is
        // the one place that can count the pass honestly without threading a
        // box through every adapter. `scan()` resets them per descriptor.
        private(set) var agentFilesRead = 0
        private(set) var agentBytesRead = 0
        private(set) var agentTruncated = false
        /// The budget refused a whole-file read for this adapter. "Low but
        /// not empty" is the dangerous state: `exhausted` stays false, so
        /// without this flag the adapter would classify as `no_sessions` —
        /// and mergePartialRows treats that as a trusted empty and clears the
        /// previous good rows.
        private(set) var agentBudgetDenied = false

        func reserve(_ bytes: Int) -> Bool {
            guard bytes > 0, !exhausted, bytes <= bytesRemaining else { return false }
            bytesRemaining -= bytes
            agentBytesRead += bytes
            return true
        }

        func noteFileRead() { agentFilesRead += 1 }
        func noteTruncated() { agentTruncated = true }
        func noteBudgetDenied() { agentBudgetDenied = true }

        func resetAgentCounters() {
            agentFilesRead = 0
            agentBytesRead = 0
            agentTruncated = false
            agentBudgetDenied = false
        }
    }

    static let maxFilesPerAgent = 384
    /// Parse up to the product-wide session budget, then keep typed facts for
    /// the searchable index. The two limits are intentionally distinct:
    /// truncating before normalization can hide the newest usable row.
    /// 0.50 raises retain to 500 so search/pagination can cover large histories
    /// while the tray glance stays at SnapshotBuilder.maxVisibleRows.
    static let maxFactsPerAgent = 512
    static let maxRowsPerAgent = 500
    static let maxDepth = 8
    static let maxFileBytes = 4 * 1024 * 1024
    /// A menu-bar refresh must not spend its whole cadence on one vendor's
    /// ever-growing cache. The deadline is intentionally per adapter; every
    /// Agent still receives a health line even when one root is pathological.
    // A 180 ms cap made large but valid rollout stores (Codex, Pi, Gemini)
    // report `failed` on every refresh before their first useful record was
    // reached. Keep the adapter isolated, but give one bounded SQLite/text
    // pass enough time to return its authoritative newest session.
    static let maxAgentSeconds = 0.75
    // Codex's longer adapter deadline and wider window (one compacted JSONL
    // record) are its `HarvestWalk` in AgentCatalog.
    static let maxObjectNodes = 2_000
    /// Transcript-backed stores can contain months of append-only history. The
    /// row freshness policy already hides these records from the tray; avoid
    /// spending the bounded adapter slice parsing them when a newer file is
    /// available. SQLite adapters are intentionally excluded because their
    /// internal `updated_at` columns are more authoritative than file mtime.
    static let transcriptFreshFileWindowMs: Int64 = 72 * 60 * 60 * 1000
    static let sessionNeedles = [
        "session", "thread", "conversation", "chat", "history", "rollout",
        "transcript", "composer", "task", "projects",
    ]
    static let ignoredDirectoryNames: Set<String> = [
        "node_modules", "crashpad", "gpuCache", "cachedData", "cache",
        "caches", "logs", "thumbnails",
    ]

    static func scan(
        allowAppData: Bool = false,
        appDataAgents: Set<AgentID> = [],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        agentDeadlineSeconds: TimeInterval? = nil,
        totalDeadlineSeconds: TimeInterval? = nil,
        agentFilter: Set<AgentID>? = nil,
        startCursor: Int = 0,
        totalBudgetBytes: Int? = nil
    ) -> Result {
        let fm = FileManager.default
        // One pass, one set of answers about the disk.
        dashPathCache.removeAll()
        let allDescriptors = descriptors(home: home)
        let filtered: [Descriptor]
        if let agentFilter {
            let allowed = Set(agentFilter.map(\.surfaceID))
            filtered = allDescriptors.filter { allowed.contains($0.id.surfaceID) }
        } else {
            filtered = allDescriptors
        }
        // Adapter order used to be the literal order of `descriptors()`, so
        // whenever the global byte/time budget ran out it ran out at the same
        // place every scan. The agents at the tail of the list — droid,
        // Command Code, Antigravity, Kimi, ZCode — were reported `unscanned`
        // on every single refresh and never got a turn, while the supervisor
        // treats `unscanned` as "not this adapter's fault" and therefore never
        // compensated. Starting each scan where the previous one gave up makes
        // the starvation rotate instead of being permanent.
        //
        // The cursor is a position in the full, stable descriptor list — not
        // in `filtered`. 11.0.3 kept an index into the supervisor-filtered
        // list, so whenever the deferred set changed between scans the saved
        // index named a different adapter and the rotation skipped one.
        let stableIndex: [String: Int] = Dictionary(
            allDescriptors.enumerated().map { ($0.element.id.rawValue, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let offset = Self.rotationOffset(
            filteredStableIndices: filtered.map { stableIndex[$0.id.rawValue] ?? 0 },
            cursor: allDescriptors.isEmpty ? 0 : ((startCursor % allDescriptors.count) + allDescriptors.count) % allDescriptors.count
        )
        let descriptors = Array(filtered[offset...] + filtered[..<offset])
        let budget = ScanBudget(
            deadline: Date().addingTimeInterval(totalDeadlineSeconds ?? 5.8),
            bytes: totalBudgetBytes ?? 48_000_000
        )
        var firstUnreachedIndex: Int?
        let perAgentSeconds = agentDeadlineSeconds ?? maxAgentSeconds
        var rows: [ActivityHarvest.Row] = []
        var health: [ActivityHarvest.CollectorHealth] = []

        for (descriptorIndex, descriptor) in descriptors.enumerated() {
            if budget.exhausted {
                // Emit an explicit boundary for adapters the global cutoff
                // never reached. Do not misreport them as `no_sessions`.
                firstUnreachedIndex = firstUnreachedIndex ?? descriptorIndex
                health.append(contentsOf: descriptors[descriptorIndex...].map {
                    .unscanned($0.id)
                })
                break
            }
            budget.resetAgentCounters()
            let started = Date()
            var sourcePresent = false
            var facts: [Fact] = []
            var visitError = false
            var agentTimedOut = false
            let permitted = allowAppData || appDataAgents.contains(where: {
                accessAlias($0, matches: descriptor.id)
            })
            let adapterSeconds = agentDeadlineSeconds
                ?? descriptor.id.spec.walk.deadlineSeconds ?? perAgentSeconds
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
                sourcePresent = descriptor.commands.contains {
                    executableExists($0, home: home)
                }
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
            } else if agentRows.isEmpty, budget.agentBudgetDenied {
                // The byte budget refused a read before this adapter saw its
                // files. "Nothing observed" is then a statement about
                // resources, not about sessions — reporting `no_sessions`
                // here let mergePartialRows treat it as a trusted empty and
                // clear the previous good rows.
                state = .failed
            } else if !agentRows.isEmpty {
                state = .observed
            } else if sourcePresent {
                state = .noSessions
            } else {
                state = .sourceAbsent
            }
            let duration = max(0, Int(Date().timeIntervalSince(started) * 1000))
            let explain = explainResult(
                filesRead: budget.agentFilesRead,
                bytesRead: budget.agentBytesRead,
                truncated: budget.agentTruncated,
                factsParsed: facts.count,
                facts: mergedFacts,
                rows: agentRows,
                sourcePresent: sourcePresent,
                timedOut: agentTimedOut
            )
            health.append(.init(
                id: descriptor.id,
                state: state,
                durationMs: duration,
                rowCount: agentRows.count,
                sourcePresent: sourcePresent,
                errorKind: agentTimedOut
                    ? "native_timeout"
                    : (visitError ? "native_read_failed" : ""),
                explain: explain,
                factClasses: ActivityHarvest.factClasses(of: agentRows)
            ))
            if budget.exhausted, descriptorIndex + 1 < descriptors.count {
                firstUnreachedIndex = firstUnreachedIndex ?? (descriptorIndex + 1)
                health.append(contentsOf: descriptors[(descriptorIndex + 1)...].map {
                    .unscanned($0.id)
                })
                break
            }
        }

        // Windsurf shell rows only when Cascade produced none — shared
        // ~/.windsurf roots must not double the same pending session as two
        // red lamps (0.95 Extinguish Honesty).
        //
        // This copy exists so the health lines agree with the rows this pass
        // reports; it is no longer the rule. The rule is
        // `ActivityHarvest.dedupeSharedRoots`, applied where the tray's rows
        // are actually assembled — a cursor rotation, a tripped collector or
        // a scoped rescan all deliver one of the pair without the other, and
        // this block, which can only see one scan, is blind to every one of
        // them. It also no longer skips itself when the scan is scoped: a
        // filter that happens to exclude Cascade was never a reason to let a
        // duplicate through.
        if rows.contains(where: { $0.id == .cascade }) {
            rows.removeAll { $0.id == .windsurf }
            for index in health.indices where health[index].id == .windsurf {
                if health[index].state == .observed || health[index].rowCount > 0 {
                    health[index].state = .noSessions
                    health[index].rowCount = 0
                    // 2.9 Codex review on #78: the yield was measured before
                    // this cleanup, so without clearing it Support Health
                    // could report "no sessions" and a list of measured
                    // facts about the same adapter in the same breath.
                    health[index].factClasses = []
                }
            }
        }

        // Resume at the first adapter this pass could not reach, so the next
        // scan spends its budget on them first. A complete pass rewinds to the
        // start, keeping the flagship agents at the head in the common case.
        let nextCursor = firstUnreachedIndex.map {
            stableIndex[descriptors[$0].id.rawValue] ?? 0
        } ?? 0
        // One write per scan, after every adapter has folded what it read. A
        // fixture home folds but does not persist: a test must not leave its
        // temporary paths in the user's digest file.
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        HarvestDigests.flush(
            persist: SessionDigestStore.pathOverride != nil
                || home.standardizedFileURL == realHome
        )
        return Result(
            rows: rows,
            health: health,
            complete: ActivityHarvest.isCompleteHealth(health),
            nextCursor: nextCursor
        )
    }

    /// Where in `filtered` a pass starts: the first adapter at or after the
    /// cursor's position in the stable list, wrapping to the head.
    static func rotationOffset(filteredStableIndices: [Int], cursor: Int) -> Int {
        filteredStableIndices.firstIndex { $0 >= cursor } ?? 0
    }

    /// The collector's account of one bounded pass.
    ///
    /// `observed` with an empty hero used to be indistinguishable from
    /// `observed` with a good one: nothing in the app, the support report or a
    /// bug report said which layer lost the title. Four consecutive releases
    /// each guessed at a vendor format, shipped, and found the tray still
    /// blank. Counts and tags only — no titles, no prompt text, no paths.
    static func explainResult(
        filesRead: Int,
        bytesRead: Int,
        truncated: Bool,
        factsParsed: Int,
        facts: [Fact],
        rows: [ActivityHarvest.Row],
        sourcePresent: Bool,
        timedOut: Bool
    ) -> ActivityHarvest.CollectorExplain {
        let hero = facts.first { !$0.task.isEmpty }
        let emptyReason: String
        if rows.contains(where: { !$0.task.isEmpty }) {
            emptyReason = ""
        } else if !sourcePresent {
            emptyReason = "no_source"
        } else if timedOut {
            emptyReason = "deadline"
        } else if filesRead == 0 {
            emptyReason = "no_readable_file"
        } else if factsParsed == 0 {
            emptyReason = "no_parsable_record"
        } else if rows.isEmpty {
            emptyReason = "facts_without_display_signal"
        } else {
            emptyReason = "no_user_goal_in_records"
        }
        return ActivityHarvest.CollectorExplain(
            filesRead: filesRead,
            bytesRead: bytesRead,
            truncated: truncated,
            factsParsed: factsParsed,
            heroOrigin: hero.map { originLabel(effectiveOrigin($0.task, $0.taskOrigin)) } ?? "",
            emptyReason: emptyReason
        )
    }

    static func originLabel(_ origin: TaskOrigin) -> String {
        switch origin {
        case .none: return ""
        case .chrome: return "chrome"
        case .fallbackText: return "fallback_text"
        case .cacheTitle: return "cache_title"
        case .toolTitle: return "tool_title"
        case .userPrompt: return "user_prompt"
        case .sessionName: return "session_name"
        }
    }

    // MARK: - Shape export

    /// A privacy-safe description of the *shape* of an agent's newest session
    /// records: key names and value kinds, never values.
    ///
    /// Every hero regression from 0.96.1 to 0.97.2 came down to the same
    /// missing input — nobody could see what the vendor actually wrote on the
    /// machine where the tray was blank, so each fix was authored against a
    /// format someone had inferred. A user can run this, read every line, and
    /// decide to paste it into an issue; it emits no titles, no prompts, no
    /// paths and no values, so what they are sharing is legible before they
    /// share it.
    static func shapeReport(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        agents: [AgentID] = AgentID.allCases,
        allowAppData: Bool = false,
        appDataAgents: Set<AgentID> = [],
        maxRecordsPerAgent: Int = 6
    ) -> String {
        var lines = ["Pulse harvest shape report", "keys and value kinds only — no values"]
        let fm = FileManager.default
        let wanted = Set(agents.map(\.surfaceID))
        for descriptor in descriptors(home: home) where wanted.contains(descriptor.id.surfaceID) {
            let permitted = allowAppData || appDataAgents.contains {
                accessAlias($0, matches: descriptor.id)
            }
            var newest: (url: URL, mtime: Date)?
            for root in descriptor.roots {
                if isProtected(root, home: home), !permitted { continue }
                guard fm.fileExists(atPath: root.path) else { continue }
                guard let walker = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsPackageDescendants]
                ) else { continue }
                var visited = 0
                while let item = walker.nextObject() as? URL, visited < maxFilesPerAgent {
                    visited += 1
                    guard ["json", "jsonl", "ndjson"].contains(item.pathExtension.lowercased()),
                          let values = try? item.resourceValues(
                            forKeys: [.contentModificationDateKey, .isRegularFileKey]
                          ),
                          values.isRegularFile == true,
                          let mtime = values.contentModificationDate
                    else { continue }
                    if let current = newest, mtime <= current.mtime { continue }
                    newest = (item, mtime)
                }
            }
            guard let candidate = newest, let text = boundedTail(of: candidate.url) else {
                lines.append("\(descriptor.id.rawValue): no readable json/jsonl source")
                continue
            }
            lines.append("\(descriptor.id.rawValue): .\(candidate.url.pathExtension.lowercased())")
            var emitted = 0
            for raw in text.split(whereSeparator: \.isNewline).suffix(64).reversed() {
                guard emitted < maxRecordsPerAgent else { break }
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.hasPrefix("{"), value.count < 200_000,
                      let data = value.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                lines.append("  " + shapeLine(object))
                emitted += 1
            }
            if emitted == 0 { lines.append("  no parsable json record in the last 64 lines") }
        }
        return lines.joined(separator: "\n")
    }

    /// Last 256 KB of a file. The shape report is a user-triggered diagnostic,
    /// not a scan, but it must still not pull a multi-gigabyte transcript into
    /// memory to describe its keys.
    static func boundedTail(of url: URL, limit: Int = 256_000) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return nil }
        if size <= limit {
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        handle.seek(toFileOffset: UInt64(size - limit))
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func shapeLine(_ object: [String: Any], depth: Int = 0) -> String {
        // Key names are vendor schema, not user content, but bound them anyway
        // — a vendor is free to key an object by something the user typed.
        let parts = object
            .sorted { $0.key < $1.key }
            .prefix(24)
            .map { pair -> String in
                let safeKey = pair.key.count > 40
                    ? String(pair.key.prefix(40)) + "…"
                    : pair.key
                return "\(safeKey):\(shapeKind(pair.value, depth: depth))"
            }
        return "{" + parts.joined(separator: " ") + "}"
    }

    static func shapeKind(_ value: Any, depth: Int) -> String {
        if value is NSNull { return "null" }
        if let nested = value as? [String: Any] {
            return depth >= 2 ? "object" : shapeLine(nested, depth: depth + 1)
        }
        if let array = value as? [Any] {
            guard let first = array.first else { return "array(0)" }
            return "array(\(array.count))<\(shapeKind(first, depth: depth + 1))>"
        }
        if value is String { return "string" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() ? "bool" : "number"
        }
        return "unknown"
    }

    // MARK: - Agent roots

    static func descriptors(home: URL) -> [Descriptor] {
        func h(_ path: String) -> URL { home.appendingPathComponent(path) }
        func d(_ id: AgentID, _ paths: [String], _ commands: [String] = []) -> Descriptor {
            Descriptor(id: id, roots: paths.map(h), commands: commands)
        }
        // `cursorAgent` is intentionally a transport alias of Cursor and has
        // no roots of its own, so no second health row. The roots, commands
        // and their rationale live in `AgentCatalog`.
        return AgentCatalog.all
            .filter { !$0.harvestRoots.isEmpty }
            .map { d($0.id, $0.harvestRoots, $0.harvestCommands) }
    }

    static func accessAlias(_ selected: AgentID, matches id: AgentID) -> Bool {
        if selected.surfaceID == id.surfaceID { return true }
        if (selected == .cascade || selected == .windsurf)
            && (id == .cascade || id == .windsurf) { return true }
        if (selected == .cursor || selected == .cursorAgent) && id == .cursor { return true }
        return false
    }

    static func isProtected(_ url: URL, home: URL) -> Bool {
        let root = home.standardizedFileURL.path.hasSuffix("/")
            ? home.standardizedFileURL.path
            : home.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(root + "Library/") else { return false }
        let relative = String(url.standardizedFileURL.path.dropFirst((root + "Library/").count))
        return ["Application Support/", "Group Containers/", "Containers/", "Logs/"]
            .contains(where: { relative.hasPrefix($0) })
    }

    static func executableExists(
        _ name: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let fm = FileManager.default
        return commandSearchPaths(home: home, environment: environment).contains {
            fm.isExecutableFile(atPath: "\($0)/\(name)")
        }
    }

    /// Where an agent CLI may be installed.
    ///
    /// This deliberately does not trust `$PATH` alone. A menu-bar app launched
    /// by Finder, Spotlight or launchd inherits the launchd path —
    /// `/usr/bin:/bin:/usr/sbin:/sbin` — so every Homebrew, npm-global, bun and
    /// `~/.local/bin` CLI is invisible to it, while the same binary launched
    /// from a shell finds them all. The consequence was not cosmetic: an agent
    /// that is installed but has not written a session yet reported
    /// `source_absent` ("not installed") instead of `no_sessions` ("installed,
    /// nothing running") — exactly the "did not see" / "is not running"
    /// confusion the support window exists to prevent.
    ///
    /// Existence checks only; Pulse never executes anything it finds here.
    static func commandSearchPaths(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ raw: String) {
            var path = raw.trimmingCharacters(in: .whitespaces)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty, path.hasPrefix("/"), seen.insert(path).inserted else { return }
            result.append(path)
        }
        for entry in (environment["PATH"] ?? "").split(separator: ":") {
            add(String(entry))
        }
        for fixed in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            add(fixed)
        }
        let homePath = home.standardizedFileURL.path
        for relative in [
            ".local/bin", ".bun/bin", ".cargo/bin", ".volta/bin",
            ".npm-global/bin", ".npm/bin", ".yarn/bin", ".deno/bin",
        ] {
            add("\(homePath)/\(relative)")
        }
        return result
    }

    static func shouldSkipStaleTranscript(id: AgentID, mtime: Int64) -> Bool {
        guard mtime > 0 else { return false }
        // Pi's idle JSONL is still the title source (`TranscriptPolicy`):
        // skipping it left SQLite rows with cwd and no task.
        guard id.spec.transcripts.skipsStaleFiles else { return false }
        let age = Int64(Date().timeIntervalSince1970 * 1000) - mtime
        return age > transcriptFreshFileWindowMs
    }

    static func allowsBoundedLargeTranscript(_ id: AgentID) -> Bool {
        id.spec.transcripts.allowsBoundedLargeFiles
    }

    // MARK: - Bounded file walk

    static func collect(
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
        let walk = id.spec.walk
        var deferredDatabases: [URL] = []
        // Stat during the walk, read afterwards, newest first.
        //
        // The enumerator hands files back in filesystem order, which is not
        // time order and is not stable. With the `visited` cap above in place
        // that made "was the session you are actually running scanned?" a
        // question about where the directory happened to put its entries —
        // and a heavy Claude or Codex user crosses that cap within a couple
        // of months, at which point the live session can sit permanently on
        // the wrong side of it. Pi hit this first and was fixed alone in
        // 0.97; nothing about the reasoning was Pi-specific, so it is the
        // default here. Collecting candidates first is what keeps the stat
        // cost from becoming a read cost: the walk opens nothing, the ranked
        // list is cut to `maxFilesPerAgent`, and only those files are read.
        var transcripts: [(url: URL, values: URLResourceValues, ext: String)] = []
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
            // An agent may keep a directory the walk skips for everyone else
            // (Grok's authoritative stream lives under ~/.grok/logs).
            if ignoredDirectoryNames.contains(name),
               !walk.keptDirectoryNames.contains(name.lowercased()) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else {
                error = true
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }

            let ext = item.pathExtension.lowercased()
            if let adapter = walk.database, adapter.extensions.contains(ext) {
                if adapter.runsAfterTranscripts {
                    // JSONL carries /resume titles. A sibling sessions.db
                    // (or any non-session_meta file) must not run first or
                    // mark the adapter failed before those transcripts.
                    deferredDatabases.append(item)
                    continue
                }
                collectDatabase(
                    item,
                    adapter: adapter,
                    home: home,
                    into: &facts,
                    budget: budget,
                    error: &error
                )
                if facts.count >= maxFactsPerAgent { break }
                continue
            }
            // Which files are session evidence at all: Grok's database is
            // authoritative and the rest of its tree is terminal transcripts,
            // locks and prompts; Pi's and Gemini's roots also hold caches and
            // a full checkout copy.
            guard walk.transcripts.admits(item.path.lowercased()) else { continue }
            guard ["json", "jsonl", "ndjson", "txt", "md", "log"].contains(ext) else { continue }
            transcripts.append((item, values, ext))
        }
        // Newest mtime first, then a stable path tiebreak so two files
        // written in the same millisecond do not swap places between scans.
        // The cap is per root, as Pi's already was — an adapter with two
        // roots may read more files than one with a single root, and that is
        // deliberate: each root gets its own newest-first slice rather than
        // the first root starving the second.
        let ranked = transcripts.sorted { lhs, rhs in
            let a = lhs.values.contentModificationDate ?? .distantPast
            let b = rhs.values.contentModificationDate ?? .distantPast
            if a != b { return a > b }
            return lhs.url.path > rhs.url.path
        }
        for item in ranked.prefix(maxFilesPerAgent) {
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
        if let adapter = walk.database {
            for db in deferredDatabases {
                if Date() >= deadline || budget.exhausted { break }
                if facts.count >= maxFactsPerAgent { break }
                collectDatabase(
                    db,
                    adapter: adapter,
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

    static func ingestTranscriptFile(
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
        let walk = id.spec.walk
        let sizeLimit = walk.maxFileBytes
            ?? (allowsBoundedLargeTranscript(id) ? 512 * 1024 * 1024 : maxFileBytes)
        guard size > 0, size <= sizeLimit else { return }

        let mtime = values.contentModificationDate.map {
            Int64($0.timeIntervalSince1970 * 1000)
        } ?? 0
        if shouldSkipStaleTranscript(id: id, mtime: mtime) { return }

        // Pi /resume titles live in the session header / first user message
        // (head) and optional /name + compaction (usually near the tail).
        // 8 MB per historical file exhausted the 48 MB budget; match the
        // legacy harvest window: 96 KB head + 400 KB tail.
        let windowCap = walk.windowBytes
        let headLimit = walk.headBytes
        guard let window = readWindow(
            item, size: size, budget: budget, cap: windowCap, headLimit: headLimit
        ), !window.text.isEmpty else { return }
        let text = window.text
        let structured = isSessionPath(item)
            || walk.structuredPathFragment.map { item.path.lowercased().contains($0) } == true
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
        if walk.dropsContinuationPrompts {
            parsed.removeAll { isContinuationPrompt($0.task) }
        }
        guard !parsed.isEmpty else { return }
        // Counting newlines in a head+tail window is not the file's record
        // count, and EXPERIENCE forbids estimating one ("数量不估算"). A
        // truncated read reports unknown rather than a silent undercount that
        // the tray then renders as an exact "N records".
        var digestFacts: SessionDigest?
        var records = (ext == "jsonl" || ext == "ndjson") && !window.truncated
            ? text.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
            : 0
        // 1.1: the window above is the two ends of the file. The digest is the
        // rest — folded once, as it goes past, and kept between scans. When it
        // has reached the end of the file its count is the file's count, so a
        // long transcript stops reporting unknown for the rest of its life.
        // Until then nothing is claimed: an in-progress catch-up leaves the
        // window's answer exactly as it was.
        if ext == "jsonl" || ext == "ndjson" {
            let digest = HarvestDigests.advance(url: item, size: size)
            if let digest {
                // `records` keeps that gate, and 2.1 keeps it for `records`
                // alone: a partial fold is a floor, never a total.
                if digest.caughtUp, digest.records > 0 { records = digest.records }
                // 2.1: everything else is qualitative and was never a total.
                // "It has called Bash eleven times and hit four errors" does
                // not become false because there are more records still to
                // read; it becomes *incomplete*, which the row states outright
                // through `digestProgressPercent` / `digestCaughtUp`. Holding
                // these back until catch-up meant a long, busy session — the
                // one a person most needs to see — showed nothing at all.
                digestFacts = digest
            }
        }
        for index in parsed.indices {
            parsed[index].sourcePath = item.path
            if parsed[index].activityMs <= 0 {
                parsed[index].activityMs = mtime
            }
            parsed[index].startedMs = birth > 0 && birth <= mtime + 1000 ? birth : 0
            parsed[index].records = records
            if let digestFacts {
                if let loop = digestFacts.repeatedTool {
                    parsed[index].loopTool = loop.name
                    parsed[index].loopCount = loop.count
                }
                parsed[index].sessionErrors = digestFacts.errors
                parsed[index].toolSummary = SessionDigestSummary.line(digestFacts.toolCounts)
                // Carried, never re-derived. `recentTools` is already bounded
                // and identifier-shaped by the fold; nothing here is parsed
                // out of the window a second time.
                parsed[index].recentTools = digestFacts.recentTools
                parsed[index].sessionTokensIn = digestFacts.tokensIn
                parsed[index].sessionTokensOut = digestFacts.tokensOut
                parsed[index].digestProgressPercent = digestFacts.progressPercent
                parsed[index].digestCaughtUp = digestFacts.caughtUp
                parsed[index].bytesPerMinute = digestFacts.bytesPerMinute
                parsed[index].sessionStartedMs = digestFacts.firstFoldedMs
            }
            parsed[index].windowTruncated = window.truncated
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
                if !decoded.path.isEmpty,
                   parsed[index].cwd.isEmpty || looksLikeFilePathCwd(parsed[index].cwd) {
                    parsed[index].cwd = decoded.path
                    parsed[index].cwdBestEffort = !decoded.verified
                    if parsed[index].project.isEmpty {
                        parsed[index].project = lastPathComponent(decoded.path)
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

    static func geminiProjectRoot(for url: URL) -> String? {
        // ~/.gemini/tmp/<project>/chats/<session>.jsonl → <project>/.project_root
        let marker = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".project_root")
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let path = normalizedPath(text)
        return path.isEmpty ? nil : path
    }

    static func isContinuationPrompt(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        return ["continue", "继续", "继续分析", "继续评估", "ok", "okay", "好的", "可以", "goon", "next"]
            .contains(normalized)
    }
}

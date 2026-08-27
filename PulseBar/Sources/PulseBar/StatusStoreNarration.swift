import AppKit
import Foundation

/// How a row says what it is doing.
///
/// Split out of `StatusStore` in 2.5 — not a rewrite, a move. The store had
/// grown to 5019 lines across thirteen jobs, and this was the largest one
/// with the fewest ties to the rest: it reads a row plus the resolved
/// language and returns a string. Nothing here touches the scan, the ledger,
/// notification delivery or settings.
///
/// It stays an `extension StatusStore`, so every call site is unchanged and
/// the split cannot alter behaviour. `EXPERIENCE.md` §4 is the specification
/// for everything in this file: the story line owns "what is it doing", the
/// signal line owns motion, the observation line ranks facts by what each one
/// carries, and a fact with nothing to say does not appear.
@MainActor
extension StatusStore {
    /// User-facing last action for the detail inspector. The raw identifier is
    /// still available under Diagnostics; the primary fact uses the same
    /// phase vocabulary as the tray so `exec`, `apply_patch`, and vendor
    /// aliases do not appear as unexplained implementation jargon.
    func detailLastAction(_ row: AgentRow) -> String {
        guard !row.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return tr(.noActivityYet)
        }
        return readableAction(row.tool)
    }

    /// First-class workflow phase for the inspector. If an adapter emitted a
    /// vendor-specific phase we still show a safe, human-readable value rather
    /// than leaving the most important operational fact blank.
    func detailPhase(_ row: AgentRow) -> String {
        if let phase = readablePhase(row.phase, waiting: row.waiting) { return phase }
        let raw = row.phase.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw.replacingOccurrences(of: "_", with: " ").capitalized }
        if row.waiting {
            let kind = row.waitKind.trimmingCharacters(in: .whitespacesAndNewlines)
            if !kind.isEmpty { return localizedWaitKind(kind) }
            return tr(.needsYou)
        }
        if row.isStalled { return tr(.stalled) }
        if row.liveProcess { return tr(.phaseWorking) }
        if !row.outcome.isEmpty { return row.outcome }
        return "—"
    }

    func lastActivityLabel(_ row: AgentRow) -> String {
        guard row.harvestMs > 0 || row.activityChangedMs > 0 else { return "" }
        let secs = row.lastActivitySeconds
        // "54s ago" reads as precision the number does not have — the panel
        // rescans every few seconds and nobody acts on the difference between
        // 40 and 54 seconds. Below a minute it is simply recent.
        if secs < 60 { return tr(.durNow) }
        return String(format: tr(.agoFormat), durationLabel(seconds: secs))
    }

    /// Second line of a row: where it is and how long since it moved.
    ///
    /// 0.92 Row Clarity — story owns “what is this session doing?” (phase /
    /// tool gist / Changed). Context yields last-action when story already
    /// carries it, so the secondary line stays where · age.
    ///
    /// Only for live rows: on a finished session the last tool it touched is
    /// history, not status, and would read as though it were still going.
    func rowContextLine(_ row: AgentRow, omitPath: Bool = false) -> String {
        if row.isProcessOnly {
            var bits: [String] = []
            let path = row.displayPath
            if !path.isEmpty, !omitPath { bits.append(path) }
            // Process-only is still useful liveness evidence. Explain how the
            // row was found. Hero already states the activity-feed gap — do not
            // repeat "activity unavailable" on the secondary line.
            if let evidence = row.processEvidence {
                bits.append(
                    evidence == .pathSignature
                        ? tr(.supportDetectedPath)
                        : tr(.supportDetectedExecutable)
                )
            }
            return bits.joined(separator: " · ")
        }
        var bits: [String] = []
        let path = row.displayPath
        if !path.isEmpty, !omitPath { bits.append(path) }
        // 8.1: the last-action slot moved to the work line, the tool's one
        // home outside the story — the secondary line keeps where and when.
        let ago = lastActivityLabel(row)
        if !ago.isEmpty { bits.append(String(format: tr(.lastActive), ago)) }
        let age = row.sessionAgeSeconds(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        // EXPERIENCE 次行右端: "始于…" when known. Cap at 24h so ancient store
        // timestamps do not pretend to be runtime state (0.80 Tray Legibility).
        if age >= 60, age <= 24 * 60 * 60 {
            bits.append(String(
                format: tr(.sessionAge),
                DurationFormat.label(seconds: age, lang: lang)
            ))
        }
        if row.liveProcess, row.agent.waitingSource == .none {
            bits.append(tr(.supportWaitingNone))
        }
        // Heading ate the path and nothing else made the line → restore it
        // rather than render nothing (0.81 Tray Substance). A line that has
        // real facts keeps honoring the heading's dedup.
        if omitPath, !path.isEmpty, bits.isEmpty {
            bits.insert(path, at: 0)
        }
        // Empty secondary is honest. Agent name already sits on the identity
        // line — repeating it here is EXPERIENCE-forbidden empty chrome.
        return bits.joined(separator: " · ")
    }

    /// Explicit lifecycle state only. A historical last tool is deliberately
    /// excluded: it belongs in `rowContextLine` as "Last action", never under
    /// a "Now" label.
    func rowNowLine(_ row: AgentRow) -> String {
        guard !row.waiting else { return "" }
        if let failure = readableFailure(row.outcome) {
            return String(format: tr(.outcomeActivity), failure)
        }
        if row.isRecentOnly {
            if row.isCompletedPhase {
                return String(format: tr(.outcomeActivity), tr(.phaseTurnComplete))
            }
            // A collector can expose a concrete phase without a matching
            // local process. Show it only while the row is genuinely fresh;
            // otherwise an old "reading" event would look like work happening
            // now after the session has gone quiet.
            guard row.lastActivitySeconds <= 30 * 60,
                  let phase = readablePhase(row.phase, waiting: row.waiting) else { return "" }
            return String(format: tr(.nowActivity), phase)
        }
        guard let phase = readablePhase(row.phase, waiting: row.waiting) else { return "" }
        return String(format: tr(.nowActivity), phase)
    }

    func rowActivityChange(_ row: AgentRow) -> String {
        guard !row.waiting, let change = row.activityChange else { return "" }
        let detail: String
        switch change {
        case .errors(let count):
            detail = String(format: tr(.newErrors), count)
        case .files(let count):
            detail = String(format: tr(.newFiles), count)
        case .progress(let done, let total):
            detail = String(format: tr(.progressAdvanced), done, total)
        case .modelCall:
            detail = tr(.modelCallChanged)
        case .toolChanged:
            detail = tr(.toolChanged)
        case .phaseChanged:
            detail = tr(.phaseChanged)
        case .taskChanged:
            detail = tr(.taskChanged)
        case .completed:
            detail = tr(.phaseTurnComplete)
        case .failed:
            detail = tr(.outcomeFailed)
        case .cancelled:
            detail = tr(.outcomeCancelled)
        }
        return String(format: tr(.activityChanged), detail)
    }

    /// EXPERIENCE 行叙事（0.91 / 0.92）— one scannable sentence answering
    /// “what is this session doing / why is it on the tray”.
    /// Composes existing fields only; never invents Waiting or fake Now.
    /// 0.92: story owns phase / tool gist / Changed; Waiting yields kind·duration
    /// to the chip; Limited opaque story carries age · strongest · nextStep once.
    func rowStoryLine(_ row: AgentRow) -> String {
        // A remote row's story is the only honest thing there is to say about
        // it: when we last heard, and whether we have stopped hearing. It
        // takes precedence over every local template, none of which it can
        // support with evidence.
        if row.isRemote, let line = remoteStatusLine(row) { return line }
        // 1.2: an agent calling the same tool back to back is busy without
        // being any closer to done. The lamp cannot say that — it is running
        // and its clock is moving — and a window could never see it, because
        // the repetition is spread through the part of the transcript that was
        // never read. It outranks the ordinary story: "what it is doing" is
        // less useful than "it has been doing this five times".
        if row.isLooping, !row.waiting {
            return String(format: tr(.loopingTool), row.loopTool, row.loopCount)
        }
        if row.waiting {
            // Chip owns kind · duration; wait detail owns the message (0.92).
            // Story only surfaces the signal source when there is no message.
            let msg = row.waitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty { return "" }
            if let signal = row.waitSignal {
                return signal == .hooks ? tr(.signalHooks) : tr(.signalPending)
            }
            return ""
        }

        if row.isProcessOnly || (row.quality.isLimited && row.usefulTask == nil && row.tool.isEmpty) {
            return opaqueObservationStory(row)
        }

        var bits: [String] = []
        // 2.9: a fresh activity event is the only fact on the row that has
        // earned the present tense — the hook said this tool started seconds
        // ago and nothing has ended it. Past the window it says nothing and
        // the polled story below takes back over.
        if row.liveActionFresh, !row.liveTool.isEmpty {
            var action = row.liveTool
            let target = row.liveTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty {
                // A path shows as its leaf — rows stay scannable, Details
                // keeps the full target.
                let leaf = target.hasPrefix("/")
                    ? URL(fileURLWithPath: target).lastPathComponent
                    : target
                action += " · " + String(leaf.prefix(60))
            }
            bits.append(String(format: tr(.nowActivity), action))
        }
        // 2.8: the agent's own current step is the strongest "what is it
        // doing" a row can carry — it names the work, not the state. It is
        // self-report of *now*, so it ages exactly like phase does: past 30
        // minutes of transcript silence it would be a stale plan wearing
        // fresh clothes. It informs, and must never imply Waiting.
        let planStep = row.planStep.trimmingCharacters(in: .whitespacesAndNewlines)
        if !planStep.isEmpty, row.selfReportFresh {
            bits.append(String(format: tr(.currentStepFact), planStep))
        }
        // Prefer explicit lifecycle — never promote last tool under a Now label.
        if let phase = readablePhase(row.phase, waiting: row.waiting), !row.isRecentOnly || row.lastActivitySeconds <= 30 * 60 {
            bits.append(phase)
        } else if row.isStalled {
            // "Stalled" is about the activity clock, which only moves when
            // the transcript does. A session compiling or running a test
            // suite writes nothing for minutes while its process is pinned —
            // 2.2 can finally tell that apart, so say the true thing rather
            // than the one the clock alone implied. Not a lamp change: this
            // is still not healthy-green, it is a stall with an explanation.
            bits.append(row.isComputing ? tr(.stalledButComputing) : tr(.stalled))
        } else if row.liveProcess, !row.isRecentOnly,
                  row.hasWorkspaceEffect, row.workspaceUntouched,
                  // A clean tree right after a commit is not "nothing landed"
                  // — it is everything landing. Agents that commit as they go
                  // were being accused of idling at their most productive
                  // moment (G-1).
                  !row.workspaceHeadMovedRecently,
                  row.isComputing || row.bytesPerMinute > 0 {
            // Busy — burning CPU, or filling a transcript — and the working
            // copy is exactly as it was. Every earlier signal would call this
            // healthy; only the disk can say it has produced nothing yet.
            // **Not a lamp change**: it is running, and running is what the
            // lamp says.
            bits.append(tr(.movingNothingLanded))
        }

        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let heroIsToolOnly = row.usefulTask == nil && row.hasLiveToolFallback
        if bits.isEmpty, !tool.isEmpty, usefulAction(tool), !heroIsToolOnly {
            // Quiet live: last action is history, not Now (0.91 / 0.82 honesty).
            bits.append(String(format: tr(.lastAction), readableAction(tool)))
        } else if !bits.isEmpty, !tool.isEmpty, usefulAction(tool), !heroIsToolOnly {
            // Phase known — append humanized tool as companion, not as Now.
            let action = readableAction(tool)
            if !action.isEmpty, !bits.contains(action) {
                bits.append(action)
            }
        }

        if let change = row.activityChange {
            let compact = rowSignalChange(row)
            if !compact.isEmpty, !bits.contains(compact) {
                bits.append(compact)
            } else if change == .toolChanged || change == .phaseChanged || change == .taskChanged {
                let full = rowActivityChange(row)
                if !full.isEmpty { bits.append(full) }
            }
        }

        if bits.isEmpty {
            if row.agent.waitingSource == .none, row.liveProcess {
                return tr(.supportWaitingNoneDetail)
            }
            // 0.96: observation line owns model/tokens — do not duplicate.
            return ""
        }

        return bits.prefix(3).joined(separator: " · ")
    }

    /// Cache / process Limited story — evidence age · strongest fact · nextStep.
    /// Still Limited; never invents Now or Waiting; never upgrades to session.
    private func opaqueObservationStory(_ row: AgentRow) -> String {
        var bits: [String] = []
        if row.isProcessOnly, row.processStartedMs > 0 {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let age = max(0, Double(nowMs - row.processStartedMs) / 1000.0)
            bits.append(String(
                format: tr(.processAge),
                DurationFormat.label(seconds: age, lang: lang)
            ))
        } else {
            let ago = lastActivityLabel(row)
            if !ago.isEmpty {
                bits.append(String(format: tr(.lastActive), ago))
            } else if row.quality.freshnessMs > 0 {
                let ageSec = max(
                    0,
                    Double(Int64(Date().timeIntervalSince1970 * 1000) - row.quality.freshnessMs) / 1000.0
                )
                if ageSec >= 0 {
                    bits.append(String(
                        format: tr(.lastActive),
                        ageSec < 60 ? tr(.durNow) : durationLabel(seconds: ageSec)
                    ))
                }
            }
        }

        let model = readableModel(row.model)
        if !model.isEmpty {
            bits.append(String(format: tr(.modelFact), model))
        } else {
            let tokens = tokenPair(input: row.tokensIn, output: row.tokensOut)
            if !tokens.isEmpty {
                bits.append(tokens)
            } else if let evidence = row.processEvidence {
                bits.append(
                    evidence == .pathSignature
                        ? tr(.supportDetectedPath)
                        : tr(.supportDetectedExecutable)
                )
            } else if row.isProcessOnly {
                bits.append(tr(.limitedData))
            }
        }

        if let gap = row.quality.missing.first {
            let next = observationGapNextStep(gap)
            if !bits.contains(next) { bits.append(next) }
        } else if row.isProcessOnly {
            let next = tr(.qualityNextOpenAgent)
            if !bits.contains(next) { bits.append(next) }
        }

        let joined = bits.prefix(3).joined(separator: " · ")
        return joined.isEmpty ? observationQualitySummary(row) : joined
    }

    /// True when `rowStoryLine` will carry last-action / tool gist for this row.
    func storyOwnsLastAction(_ row: AgentRow) -> Bool {
        guard !row.waiting else { return false }
        if row.isProcessOnly || (row.quality.isLimited && row.usefulTask == nil && row.tool.isEmpty) {
            return false
        }
        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let heroIsToolOnly = row.usefulTask == nil && row.hasLiveToolFallback
        guard !tool.isEmpty, usefulAction(tool), !heroIsToolOnly else { return false }
        return true
    }

    /// True when story already narrates lifecycle phase (signal yields Now).
    func storyOwnsNow(_ row: AgentRow) -> Bool {
        guard !row.waiting else { return false }
        if row.isProcessOnly || (row.quality.isLimited && row.usefulTask == nil && row.tool.isEmpty) {
            return false
        }
        // 2.9: a fresh activity event puts the true present tense in the
        // story — the signal line yielding is what stops the same "now"
        // being said twice.
        if row.liveActionFresh, !row.liveTool.isEmpty { return true }
        if row.isStalled { return true }
        if let _ = readablePhase(row.phase, waiting: row.waiting), !row.isRecentOnly || row.lastActivitySeconds <= 30 * 60 {
            return true
        }
        return false
    }

    /// True when story already carries the Changed compact (signal yields).
    func storyOwnsChange(_ row: AgentRow) -> Bool {
        guard !row.waiting, row.activityChange != nil else { return false }
        if row.isProcessOnly || (row.quality.isLimited && row.usefulTask == nil && row.tool.isEmpty) {
            return false
        }
        return true
    }

    /// Limited quality summary rides on story — identity tag stays short (0.92).
    func rowSourceLabel(_ row: AgentRow) -> String? {
        switch row.observationSource {
        case .session: return nil
        case .cache:
            return tr(.cacheEvidence)
        case .process:
            return tr(.limitedData)
        case .remote:
            // Name the machine. "Remote host" alone tells the user the one
            // thing they already guessed and withholds the one they need.
            return row.host.isEmpty ? tr(.remoteEvidence) : "\(tr(.remoteEvidence)) · \(row.host)"
        }
    }

    /// The line a remote row gets instead of "last activity".
    ///
    /// A local row's clock comes from the process table and the session file.
    /// A remote row has neither: all Pulse can honestly report is when it last
    /// heard anything, and — once that goes quiet — that it has stopped.
    func remoteStatusLine(_ row: AgentRow, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String? {
        guard row.isRemote else { return nil }
        var parts: [String] = []
        if row.lastHeardMs > 0 {
            let age = durationLabel(seconds: Double(max(0, nowMs - row.lastHeardMs)) / 1000.0)
            parts.append(String(format: tr(.remoteLastHeard), age))
        }
        if row.lostContact { parts.append(tr(.remoteLostContact)) }
        if row.clockSuspect { parts.append(tr(.remoteClockSuspect)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The single strongest progress fact for this row.
    ///
    /// `EXPERIENCE.md` used to send tokens, sub-agent progress and skill to a
    /// hover overlay, on a rule written when a row was cramming ten facts into
    /// two lines. That rule over-corrected: rows ended up carrying two facts,
    /// both of them static — a session title fixed for the session's life, and
    /// a path. Everything that moves while work happens was one hover and one
    /// action-menu click away, so the panel was only observable on demand.
    ///
    /// These ride on the right of the context line, in the space that line was
    /// already wasting, so density costs no height.
    func rowMetrics(_ row: AgentRow) -> String {
        // Nothing at all on a waiting row.
        //
        // 0.28.0's notes said "waiting rows do not carry these", and only
        // tokens were actually suppressed — age, records and sub-agent
        // progress all still appeared beside the one thing that needs an
        // answer. The rule is the right one; it just was not implemented.
        guard !row.waiting else { return "" }
        if row.isProcessOnly, row.processStartedMs > 0 {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let age = max(0, Double(nowMs - row.processStartedMs) / 1000.0)
            var process = String(
                format: tr(.processAge),
                DurationFormat.label(seconds: age, lang: lang)
            )
            if row.processCount > 1 {
                process += " · " + String(format: tr(.processCount), row.processCount)
            }
            return process
        }
        // A single-priority metric made the row look empty for most adapters:
        // progress hid tokens, files hid context, and a model call hid the
        // only failure. Keep one line, but carry the two strongest independent
        // signals so every supported agent has a useful default glance.
        var facts: [String] = []
        let change = row.activityChange
        if row.errors > 0, !isErrorChange(change) {
            facts.append(row.errors == 1
                ? tr(.errorFactOne)
                : String(format: tr(.errorsFact), row.errors))
        }
        if let outcome = readableFailure(row.outcome), !isFailureChange(change) { facts.append(outcome) }
        if row.progressTotal > 0, !isProgressChange(change) {
            facts.append(String(format: tr(.progressFact), row.progressDone, row.progressTotal))
        } else if row.progressDone > 0, !isProgressChange(change) {
            facts.append(String(format: tr(.turnsFact), row.progressDone))
        }
        if row.subTotal > 0 {
            facts.append(row.subRunning > 0
                ? String(format: tr(.subagentsActive), row.subRunning, row.subTotal)
                : String(format: tr(.subagentsObserved), row.subTotal))
        }
        if row.files > 0, !isFilesChange(change) { facts.append(String(format: tr(.filesFact), row.files)) }
        if row.contextPercent > 0 { facts.append(String(format: tr(.contextFact), row.contextPercent)) }
        let tokens = tokenPair(
            input: row.tokensIn,
            output: row.tokensOut,
            scope: [.claude, .codex].contains(row.agent) ? .latestCall : .reported
        )
        if !tokens.isEmpty { facts.append(tokens) }
        if row.records > 0 { facts.append("\(row.records)\(tr(.recordsSuffix))") }
        return facts.prefix(2).joined(separator: " · ")
    }

    /// One bounded **motion** line: Now / Changed / stalled age / multi-process.
    /// Model, tokens, and durable progress live on `rowObservationLine` so the
    /// default tray can show both without a single truncated scan line (0.80).
    /// 0.92: yields Now / Changed when `rowStoryLine` already carries them.
    func rowSignalLine(_ row: AgentRow) -> String {
        guard !row.waiting else { return "" }
        let lifecycle = storyOwnsNow(row)
            ? ""
            : rowNowLine(row).trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = storyOwnsChange(row)
            ? ""
            : rowSignalChange(row).trimmingCharacters(in: .whitespacesAndNewlines)
        var bits: [String] = []
        if !lifecycle.isEmpty { bits.append(lifecycle) }
        if !changed.isEmpty { bits.append(changed) }
        // The one fact no single agent can see: somebody else is editing this
        // very working copy. Each agent knows only itself, so this is
        // invisible from inside either of them — and it is quietly destroying
        // one of their two sets of changes.
        if row.workspacePeers > 0 {
            bits.append(String(format: tr(.workspaceShared), row.workspacePeers))
        }
        // A process-only row has no observation line, so the fault has nowhere
        // else to go and this line carries it. Everywhere else the observation
        // line owns it — one owner, because two owners with different
        // conditions is how the count went missing.
        if row.isProcessOnly, !isErrorChange(row.activityChange) {
            let fault = faultFact(row)
            if !fault.isEmpty { bits.append(fault) }
        }
        if row.isStalled {
            let metric = stalledRowMetric(row).trimmingCharacters(in: .whitespacesAndNewlines)
            if !metric.isEmpty, !bits.contains(metric) { bits.append(metric) }
        }
        // Process-only age · nextStep live on opaque story (0.92) — signal yields.
        if row.liveProcess, !row.isProcessOnly, row.processCount > 1 {
            bits.append(String(format: tr(.processCount), row.processCount))
        }
        // EXPERIENCE: motion line disappears when empty — never invent chrome.
        return bits.prefix(3).joined(separator: " · ")
    }

    /// Compact counterpart to the full change sentence used by accessibility
    /// and diagnostics. The default row has a single-line width budget, so a
    /// terse phase/count label keeps the numeric evidence at the end visible.
    private func rowSignalChange(_ row: AgentRow) -> String {
        guard !row.waiting, let change = row.activityChange else { return "" }
        switch change {
        case .errors(let count):
            return String(format: tr(.signalErrors), count)
        case .files(let count):
            return String(format: tr(.signalFiles), count)
        case .progress(let done, let total):
            return String(format: tr(.signalProgress), done, total)
        case .modelCall:
            return tr(.signalModel)
        case .toolChanged:
            return tr(.signalTool)
        case .phaseChanged:
            return tr(.signalPhase)
        case .taskChanged:
            return tr(.signalTask)
        case .completed:
            return tr(.signalCompleted)
        case .failed:
            return tr(.signalFailed)
        case .cancelled:
            return tr(.signalCancelled)
        }
    }

    /// The one metric a **stalled** row is allowed to carry on the signal
    /// line: how long it has been still, or — for a row that is only a
    /// process — how old that process is.
    ///
    /// Named for the whole signal line when it was written, which is how it
    /// grew a full fact ranking that its one caller could never reach.
    private func stalledRowMetric(_ row: AgentRow) -> String {
        guard !row.waiting else { return "" }
        if row.isProcessOnly, row.processStartedMs > 0 {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let age = max(0, Double(nowMs - row.processStartedMs) / 1000.0)
            var process = String(
                format: tr(.processAge),
                DurationFormat.label(seconds: age, lang: lang)
            )
            if row.processCount > 1 {
                process += " · " + String(format: tr(.processCount), row.processCount)
            }
            return process
        }
        if row.isStalled {
            let seconds = row.lastActivitySeconds
            if seconds > 0 {
                return String(format: tr(.stalledFor), durationLabel(seconds: seconds))
            }
            return tr(.noActivityYet)
        }
        // Nothing follows. Its only caller asks for this string exactly when
        // `row.isStalled`, so every branch past that point was unreachable —
        // and it was a second, drifting copy of `rowObservationLine`'s fact
        // ranking (errors → outcome → progress → subagents → files → context
        // → tokens) that no screen could ever show. Two rankings, one of them
        // dead, is how the two lines disagree about what matters.
        return ""
    }

    /// The fault fact, at the best scope available, or "" when there is none.
    ///
    /// `sessionErrors` counts the whole session and `errors` counts the read
    /// window: the same fact over different spans, so only one is ever
    /// emitted. The choice used to be made independently at each call site,
    /// and the signal line's urgent companion only ever knew about `errors` —
    /// so a session carrying seven errors, none of them inside the current
    /// window, showed no fault at all for as long as anything else was
    /// moving. Faults are the top tier precisely because they must not be
    /// crowded out by motion.
    func faultFact(_ row: AgentRow) -> String {
        if row.sessionErrors > 0 {
            return String(format: tr(.sessionErrors), row.sessionErrors)
        }
        guard row.errors > 0 else { return "" }
        return row.errors == 1
            ? tr(.errorFactOne)
            : String(format: tr(.errorsFact), row.errors)
    }

    private func isErrorChange(_ change: AgentActivityChange?) -> Bool {
        if case .errors = change { return true }
        return false
    }

    private func isFilesChange(_ change: AgentActivityChange?) -> Bool {
        if case .files = change { return true }
        return false
    }

    private func isProgressChange(_ change: AgentActivityChange?) -> Bool {
        if case .progress = change { return true }
        return false
    }

    private func isFailureChange(_ change: AgentActivityChange?) -> Bool {
        if case .failed = change { return true }
        return false
    }

    /// How many facts the observation line may carry right now.
    ///
    /// **This is a line-height guard, not a ration.** The old rule was a flat
    /// "at most four", and the tray view already clamps this text to one line
    /// when the panel is crowded and two lines when it is not — so the bound
    /// here exists only to keep the string inside that clamp. It does not
    /// decide which facts deserve to exist; `rowObservationLine` does, by
    /// asking what each one carries.
    ///
    /// Crowding uses the same threshold as folding (`TrayFold.crowdedFrom`),
    /// because it is the same judgement: screen is scarce, converge.
    private var observationFactBudget: Int {
        snapshot.rows.count >= TrayFold.crowdedFrom ? 4 : 6
    }

    /// EXPERIENCE 观测行 — the default tray surface.
    ///
    /// **Facts are chosen by what they carry, not by a fixed count.**
    ///
    /// The previous rule was "at most four", and the four a row got were
    /// whichever four the code reached first — which, because the code walked
    /// the struct in declaration order, meant model and mode almost always
    /// took the first two. Both are true for the entire life of a session and
    /// neither ever moves. A row could be full and still fail to answer the
    /// only question anyone opens the tray for: *is this thing getting
    /// anywhere?* The four-fact number itself was a rebound from the opposite
    /// accident — ten facts crammed into two lines — and a number that came
    /// out of an accident is not a number to defend.
    ///
    /// So the ordering is by **motion**, not by struct layout:
    ///
    /// 1. **Faults** — an error changes what you do next. It outranks every
    ///    measure of throughput, because throughput on a broken run is noise.
    /// 2. **Advance** — progress and sub-agents in flight: the nearest thing
    ///    the data has to "closer to done".
    /// 3. **Motion** — transcript growth and the latest call's tokens: moving
    ///    or parked, which no cumulative counter can answer.
    /// 4. **Reach** — files touched, context consumed. Real, but they creep.
    /// 5. **Standing facts** — model, mode, workflow skill. They orient; they
    ///    never advance, so they compete last rather than first.
    /// 6. **Volume, then caveats** — total records, and the "still reading"
    ///    note, which earns space only when there are counts to qualify.
    ///
    /// A fact whose value is zero, unknown, or already spoken by a neighbouring
    /// line never enters the list at all — `EXPERIENCE.md`: a position that
    /// carries no information either gets real information or gets deleted.
    ///
    /// Two things stay forbidden and are enforced below rather than trusted:
    /// the same quantity restated in a second scope (session tokens *and*
    /// latest-call tokens side by side is ambiguity, not density — so the
    /// cumulative total stays in Details, where a label disambiguates it, and
    /// where it also stays clear of the no-cost-HUD invariant), and any flat
    /// enumeration where every candidate is emitted regardless of what it
    /// says.
    func rowObservationLine(_ row: AgentRow) -> String {
        guard !row.waiting, !row.isProcessOnly else { return "" }
        let tiers = observationTiers(row, workRich: !workSlots(row).isEmpty)
        return (tiers.outcome + tiers.motion + tiers.volume)
            .prefix(observationFactBudget)
            .joined(separator: " · ")
    }

    /// 8.1 (scene BN, the verdict's second coming): the work line — how the
    /// session works, **built directly from the fields, present whenever the
    /// fields are**.
    ///
    /// 8.0 routed these facts through the observation budget and showed only
    /// the overflow; on real rows the budget rarely overflowed and the line
    /// stayed empty — the conditional maze survived with a new entrance. The
    /// contract is now unconditional: tool→target, tokens (whole-session
    /// register first, latest call as fallback), workflow skill, model, mode
    /// and context render here whenever they were measured. The observation
    /// line no longer carries any of them — one fact, one line, statically.
    /// The only yielded slot is the tool, and only to a line that *actually
    /// says it this beat* (the story's output, not its ownership claim — the
    /// claim survived the story's own three-fact cut and the tool vanished
    /// from every line at once).
    func rowWorkLine(_ row: AgentRow) -> String {
        guard !row.waiting, !row.isProcessOnly else { return "" }
        return workSlots(row).joined(separator: " · ")
    }

    /// The value-ordered work slots. Internal so the tests can pin the
    /// guarantee fact-by-fact.
    func workSlots(_ row: AgentRow) -> [String] {
        let session = evidenceSessionTokens(row)
        let latest = tokenPair(input: row.tokensIn, output: row.tokensOut)
        let tokens = session.isEmpty ? latest : session
        let skill = readableSkill(row.skill)
        let model = readableModel(row.model)
        let mode = readableMode(row.mode)
        return RowValueEngine.line([
            workToolSlot(row),
            tokens.isEmpty ? nil : tokens,
            skill.isEmpty ? nil : skill,
            model.isEmpty ? nil : String(format: tr(.modelFact), model),
            mode.isEmpty ? nil : mode,
            row.contextPercent > 0
                ? String(format: tr(.contextFact), row.contextPercent) : nil
        ], limit: 6)
    }

    /// The last tool with its target when the activity spool recorded one —
    /// suppressed only where another line says it THIS beat: the story's
    /// seconds-fresh present tense, the hero's tool fallback, or the story's
    /// actual rendered output (never its static ownership claim).
    private func workToolSlot(_ row: AgentRow) -> String? {
        guard !row.liveActionFresh else { return nil }
        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { return nil }
        let readable = readableAction(tool)
        guard !readable.isEmpty else { return nil }
        if row.usefulTask == nil, row.hasLiveToolFallback { return nil }
        if rowStoryLine(row).contains(readable) { return nil }
        var slot = readable
        let target = row.liveTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if row.liveTool == tool, !target.isEmpty {
            let leaf = target.hasPrefix("/")
                ? URL(fileURLWithPath: target).lastPathComponent
                : target
            slot += " · " + String(leaf.prefix(60))
        }
        return slot
    }

    /// 10.0 (scene BS) — the collapsed row's ONE meta line.
    ///
    /// Seven stacked near-identical grey lines were each individually right
    /// and jointly unreadable — the eye cannot rank five 10.5pt grey lines.
    /// Composition replaces accretion: three slots by value — what the
    /// session is doing NOW, its strongest OUTCOME, its WAY of working —
    /// with the project as filler when slots stayed empty. The five line
    /// accessors survive intact and render on the expanded card (the
    /// understanding surface); collapsed shows only this line. Waiting rows
    /// return "" — the accent question line is their meta line; process-only
    /// rows keep their detection sentence.
    func rowMetaLine(_ row: AgentRow) -> String {
        guard !row.waiting else { return "" }
        if row.isProcessOnly { return rowContextLine(row) }
        var segments: [String] = []
        if let now = metaNowFact(row) { segments.append(now) }
        if let outcome = observationTiers(row, workRich: true).outcome.first {
            segments.append(outcome)
        }
        if let way = workSlots(row).first { segments.append(way) }
        if segments.count < 2 {
            let short = AgentRow.shortProject(row.project)
            if !short.isEmpty, row.usefulTask != nil { segments.append(short) }
        }
        return segments.prefix(3).joined(separator: " · ")
    }

    /// The meta line's now-slot — a deliberate mirror of the story line's
    /// top tier (looping > seconds-fresh action > current plan step > phase).
    /// The story remains the verbose narrative on the expanded card; this is
    /// its one-slot summary, under the same honesty gates.
    private func metaNowFact(_ row: AgentRow) -> String? {
        if row.isLooping {
            return String(format: tr(.loopingTool), row.loopTool, row.loopCount)
        }
        if row.liveActionFresh, !row.liveTool.isEmpty {
            var action = row.liveTool
            let target = row.liveTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty {
                let leaf = target.hasPrefix("/")
                    ? URL(fileURLWithPath: target).lastPathComponent
                    : target
                action += " · " + String(leaf.prefix(60))
            }
            return String(format: tr(.nowActivity), action)
        }
        let planStep = row.planStep.trimmingCharacters(in: .whitespacesAndNewlines)
        if !planStep.isEmpty, row.selfReportFresh {
            return String(format: tr(.currentStepFact), planStep)
        }
        if let phase = readablePhase(row.phase, waiting: false),
           !row.isRecentOnly || row.lastActivitySeconds <= 30 * 60 {
            return phase
        }
        return nil
    }

    /// 8.0 — the work-style detail for the expanded card: how this session
    /// works, every collected fact labelled. The raw skill name appears here
    /// (the collapsed line keeps the recognisable-workflow mapping); the tool
    /// timeline and session tokens are the digest's own, recomputing nothing.
    func workDetailFacts(_ row: AgentRow) -> [String] {
        guard !row.isProcessOnly else { return [] }
        var facts: [String] = []
        let timeline = evidenceTimeline(row)
        if !timeline.isEmpty { facts.append(timeline) }
        let skill = row.skill.trimmingCharacters(in: .whitespacesAndNewlines)
        if !skill.isEmpty, skill.lowercased() != "pending" {
            facts.append(String(format: tr(.skillFact), skill))
        }
        if row.subTotal > 0 {
            facts.append(row.subRunning > 0
                ? String(format: tr(.subagentsActive), row.subRunning, row.subTotal)
                : String(format: tr(.subagentsObserved), row.subTotal))
        }
        // 10.0: model/tokens/context left this block — the panorama's work
        // line beside it owns them; one fact, one place, per surface.
        return facts
    }

    private struct ObservationTiers {
        var outcome: [String] = []
        var motion: [String] = []
        var volume: [String] = []
    }

    /// The outcome-and-motion tiers of the observation line. 8.1: the work
    /// facts (tokens, context, model, mode, skill) left this selection for
    /// the work line, which renders them unconditionally — this line keeps
    /// what the work line cannot say: faults, what landed, liveness.
    /// `workRich` says whether the work line has content this beat — record
    /// counts stay last-resort filler and never crowd a row that already
    /// carries real facts on either line.
    private func observationTiers(_ row: AgentRow, workRich: Bool) -> ObservationTiers {
        let change = row.activityChange

        // 1 · Faults. This line owns the fault total, and it is the only line
        // that ranks faults above everything else.
        //
        // It used to stand aside whenever the row carried *any* change, on
        // the theory that the signal line would say it instead. The signal
        // line could not: its companion was nested inside a change block that
        // `storyOwnsChange` empties for every row with a real title, which is
        // most of them. So on an ordinary moving session the error count
        // appeared on no line at all — the top tier, missing exactly while
        // the session was active. The only genuine duplication is an error
        // *change*, where the delta is the news and the total repeats it.
        var faults: [String] = []
        if !isErrorChange(change) {
            let fault = faultFact(row)
            if !fault.isEmpty { faults.append(fault) }
        }

        // 2 · Advance.
        var advance: [String] = []
        // What actually landed. This outranks every other advance fact
        // because it is the only one that is not the agent's own account of
        // itself: a transcript can talk for an hour with nothing on disk, and
        // until 2.6 that looked exactly like progress. Unknown says nothing —
        // `hasWorkspaceEffect` is false for a path that was never confirmed,
        // a directory that is not a working copy, and a repository too slow
        // to ask.
        if row.hasWorkspaceEffect, row.changedPaths > 0 {
            advance.append(String(format: tr(.effectFiles), row.changedPaths))
            if row.insertions > 0 || row.deletions > 0 {
                advance.append(String(format: tr(.effectLines), row.insertions, row.deletions))
            }
        }
        if row.subTotal > 0 {
            advance.append(row.subRunning > 0
                ? String(format: tr(.subagentsActive), row.subRunning, row.subTotal)
                : String(format: tr(.subagentsObserved), row.subTotal))
        }
        if row.progressTotal > 0, !isProgressChange(change) {
            advance.append(String(format: tr(.progressFact), row.progressDone, row.progressTotal))
        } else if row.progressDone > 0, !isProgressChange(change) {
            advance.append(String(format: tr(.turnsFact), row.progressDone))
        }
        // 8.0: a managed session's first-party outcome facts — cost·turns and
        // what the last turn left on disk. Measured by Pulse's own stream and
        // plumbing; absent facts stay absent.
        if let managed = managedRunner(for: row)?.model {
            if managed.totalCostUSD > 0 {
                advance.append(String(format: tr(.managedCost), managed.totalCostUSD, managed.turns))
            }
            if let effect = managed.lastTurnEffect {
                advance.append(String(format: tr(.managedTurnEffect), effect.insertions, effect.deletions))
            }
        }

        // 3 · Motion.
        var motion: [String] = []
        // CPU leads the tier, ahead of growth: while a compile or a test run
        // is under way the transcript produces nothing, so this is the only
        // fact left that can tell thinking from stopped. Same liveness guard —
        // a finished process cannot be busy — and unknown (-1) says nothing
        // rather than claiming idleness it never measured.
        if row.liveProcess, !row.isRecentOnly, row.isComputing {
            motion.append(String(format: tr(.cpuFact), Int(row.cpuPercent.rounded())))
        }
        // Growth outranks token size: it is the only fact here that separates
        // "working" from "sitting there". Live and not stalled only — a rate
        // on a finished session is history dressed as motion.
        if row.liveProcess, !row.isStalled, !row.isRecentOnly, row.bytesPerMinute > 0 {
            let size = AgentRow.compactBytes(row.bytesPerMinute)
            if !size.isEmpty {
                motion.append(String(format: tr(.evidenceRateFact), size))
            }
        }
        // 8.1: tokens, context, model, mode and skill left this selection —
        // the work line renders them unconditionally. Files-touched stays:
        // it is reach into the working copy, an outcome-class fact.
        if row.files > 0, !isFilesChange(change) {
            motion.append(String(format: tr(.filesFact), row.files))
        }

        // Volume, then caveats.
        var volume: [String] = []
        // Records answer "how much has happened", never "is it advancing", so
        // they stay last-resort filler behind anything of the progress class
        // (0.80 — never crowd the facts that move), on either line.
        let hasProgressClass = !faults.isEmpty || !advance.isEmpty
        if !hasProgressClass, !workRich, row.records > 0 {
            volume.append(String(row.records) + tr(.recordsSuffix))
        }
        // The read-progress caveat is a qualifier, not a fact: it is only
        // information when there is a count on this line for it to qualify.
        if !faults.isEmpty || !advance.isEmpty || !volume.isEmpty {
            let caveat = evidenceReadCompact(row)
            if !caveat.isEmpty { volume.append(caveat) }
        }

        return ObservationTiers(
            outcome: faults + advance,
            motion: motion,
            volume: volume
        )
    }

    /// The most recent tool a live row recorded — not necessarily one still
    /// executing.
    ///
    /// The wire column is `last_tool`, and the harvest reads it from whatever
    /// the transcript wrote most recently, which includes a `tool_result`.
    /// Calling it "running" would claim a process state nothing here observes,
    /// and the row already has a badge for actual state.
    ///
    /// `sessionDetail` promotes `tool` to the hero when there is no task, so
    /// showing it again here would be the same word twice on two lines.
    /// Humanized live-tool hero when harvest has no real session title.
    /// Returns nil for empty tools; always humanizes (Bash → Running command).
    func heroToolTitle(_ row: AgentRow) -> String? {
        guard row.usefulTask == nil, row.hasLiveToolFallback else { return nil }
        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { return nil }
        return readableAction(tool)
    }

    func liveTool(_ row: AgentRow) -> String? {
        guard row.liveProcess || row.subRunning > 0, !row.waiting else { return nil }
        let tool = row.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty, row.usefulTask != nil else { return nil }
        return tool
    }

    /// Any tool that humanizes to a non-empty label earns the context-line
    /// last-action slot. A keyword whitelist previously dropped LS/Task/Agent
    /// and left running Claude rows without a middle fact (0.81).
    private func usefulAction(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !readableAction(trimmed).isEmpty
    }

    func readablePhase(_ raw: String, waiting: Bool = false) -> String? {
        let low = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if low.isEmpty { return nil }
        if low.contains("permission") {
            return waiting ? tr(.phaseWaitingPermission) : tr(.phaseWorking)
        }
        if low.contains("turn_complete") || low == "completed" || low == "complete" {
            return tr(.phaseTurnComplete)
        }
        if low.contains("stream") || low.contains("respond") || low.contains("generat") {
            return tr(.phaseResponding)
        }
        if low.contains("test") || low.contains("verify") || low.contains("check") {
            return tr(.phaseTesting)
        }
        if low.contains("build") { return tr(.phaseBuilding) }
        if low.contains("publish") || low.contains("release") || low.contains("push") {
            return tr(.phasePublishing)
        }
        if low.contains("plan") { return tr(.phasePlanning) }
        if low.contains("search") || low.contains("research") { return tr(.actionResearch) }
        if low.contains("read") { return tr(.actionReading) }
        if low.contains("edit") || low.contains("write") { return tr(.actionEditing) }
        if low == "working" || low == "running" || low.contains("execut")
            || low == "in_progress" || low == "inprogress"
            || low == "active" || low == "busy" || low == "thinking"
            || low == "depending" {
            return tr(.phaseWorking)
        }
        // Unknown vendor phases remain hidden rather than leaking raw
        // implementation labels into the default row.
        return nil
    }

    func readableMode(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.caseInsensitiveCompare("local") == .orderedSame { return "" }
        value = value
            .replacingOccurrences(of: "grok-", with: "", options: [.caseInsensitive, .anchored])
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return value.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    func readableModel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: " ")
    }

    private func readableSkill(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.lowercased() != "pending" else { return "" }
        // Package names and registry namespaces are implementation detail. A
        // skill earns default-row space only when its explicit invocation maps
        // to a user-recognisable workflow role; everything else stays in
        // diagnostics so `product-design:audit` never becomes a mysterious
        // "Skill audit" badge.
        let low = value.lowercased()
        if low.contains("plan") || low.contains("todo") {
            return tr(.actionPlanning)
        }
        if low.contains("research") || low.contains("browser") || low.contains("web") {
            return tr(.actionResearch)
        }
        if low.contains("test") || low.contains("verify") || low.contains("check") {
            return tr(.phaseTesting)
        }
        if low.contains("build") || low.contains("compile") || low.contains("package") {
            return tr(.phaseBuilding)
        }
        if low.contains("edit") || low.contains("patch") || low.contains("write") {
            return tr(.actionEditing)
        }
        if low.contains("publish") || low.contains("release") || low.contains("deploy") {
            return tr(.phasePublishing)
        }
        if low.contains("image") || low.contains("screenshot") {
            return tr(.actionImage)
        }
        // An unknown skill can still be the only capability evidence for a
        // vendor adapter. Keep the namespace/path and implementation noise
        // out of the row, but expose a safe leaf such as "Workflow Audit" or
        // "Workflow Agents SDK" rather than silently losing the signal.
        let ignored = Set(["skill", "skills", "default", "unknown", "none", "server", "tool"])
        let label = safeIdentifier(value)
        guard !label.isEmpty, !ignored.contains(label.lowercased()) else { return "" }
        return String(format: tr(.skillFact), label)
    }

    private func readableFailure(_ raw: String) -> String? {
        let low = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if low.contains("fail") || low.contains("error") { return tr(.outcomeFailed) }
        if low.contains("cancel") || low.contains("abort") { return tr(.outcomeCancelled) }
        return nil
    }

    /// Translate implementation-level tool identifiers into an action a
    /// person can scan. This is intentionally phrased as the *last* action:
    /// harvest observes an event, not whether that action is still executing.
    func readableAction(_ raw: String) -> String {
        let tool = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = tool.lowercased()
        if low.contains("plan") || low.contains("todo") { return tr(.actionPlanning) }
        if low.contains("patch") || low.contains("edit") || low.contains("write") {
            return tr(.actionEditing)
        }
        if low.contains("image") || low.contains("screenshot") {
            return tr(.actionImage)
        }
        if low.contains("search") || low.contains("web") || low.contains("browser") {
            return tr(.actionResearch)
        }
        if low.contains("read") || low.contains("glob") || low.contains("grep") {
            return tr(.actionReading)
        }
        if low.contains("test") || low.contains("verify") || low.contains("check") {
            return tr(.phaseTesting)
        }
        if low.contains("build") || low.contains("compile") || low.contains("package") {
            return tr(.phaseBuilding)
        }
        if low.contains("publish") || low.contains("release") || low.contains("deploy") {
            return tr(.phasePublishing)
        }
        if low == "exec" || low.contains("command") || low == "bash" || low == "shell"
            || low.contains("batch_execute") {
            return tr(.actionCommand)
        }
        if low == "js" || low.contains("automation") || low.contains("computer") {
            return tr(.actionAutomation)
        }
        return safeIdentifier(tool)
    }

    /// Turn an unrecognised vendor identifier into a bounded, safe label.
    /// Namespaces and paths are implementation detail; the leaf still carries
    /// useful capability information, while filtering prevents raw URLs,
    /// private paths, or arbitrary punctuation from entering the default UI.
    private func safeIdentifier(_ raw: String, maxLength: Int = 32) -> String {
        let leaf = raw
            .split(whereSeparator: { $0 == ":" || $0 == "/" || $0 == "\\" || $0 == "." })
            .last
            .map(String.init) ?? raw
        let normalized = leaf
            .replacingOccurrences(of: "__", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let filtered = String(normalized.map { character in
            character.isLetter || character.isNumber || character.isWhitespace ? character : " "
        })
        let words = filtered.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return "" }
        let title = words.map { word -> String in
            guard let first = word.first else { return "" }
            return String(first).uppercased() + word.dropFirst()
        }.joined(separator: " ")
        guard !title.isEmpty else { return "" }
        return String(title.prefix(maxLength))
    }

    /// Human wait age in the resolved language (`2 分` / `2m`).
    func waitDurationLabel(_ row: AgentRow) -> String {
        guard row.waitSinceMs > 0 else { return "" }
        return durationLabel(seconds: row.waitAgeSeconds)
    }

    func durationLabel(seconds ago: Double) -> String {
        DurationFormat.label(seconds: ago, lang: lang)
    }

    /// Rebuild wait detail under the badge: message-first (0.92).
    /// Kind · duration live on the chip; story may carry signal when no message.
    /// Returns nil when there is nothing beyond the badge label.
    func localizedWaitDetail(_ row: AgentRow) -> String? {
        guard row.waiting else { return nil }
        let msg = row.waitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !msg.isEmpty {
            if let sig = row.waitSignal {
                let src = sig == .hooks ? tr(.signalHooks) : tr(.signalPending)
                return "↳ \(msg) · \(src)"
            }
            return "↳ \(msg)"
        }
        // No message — signal may already sit on the story line; do not repeat.
        return nil
    }

    /// Full wait line (kind + detail) — used by glance / a11y.
    func localizedWaitLine(_ row: AgentRow) -> String {
        guard row.waiting else { return "" }
        let kind = row.waitKind.isEmpty ? tr(.needsYou) : localizedWaitKind(row.waitKind)
        if let detail = localizedWaitDetail(row) {
            // detail already has ↳ — splice kind after arrow when present
            let rest = String(detail.dropFirst(2)) // drop "↳ "
            return "↳ \(kind) · \(rest)"
        }
        return "↳ \(kind)"
    }

    func focusActionTitle(_ row: AgentRow) -> String {
        switch row.focusTier {
        case .tty: return tr(.focusTTY)
        case .warp: return tr(.focusWarp)
        case .hostWorkspace(let kind):
            return String(format: tr(.focusHostWorkspace), kind.displayName)
        case .hostApp(let kind):
            return String(format: tr(.focusHostApp), kind.displayName)
        case .none:
            // No handle — never advertise "Focus terminal" for cwd-only rows.
            return tr(.focusOpenTray)
        }
    }

    func primaryActionTitle(_ row: AgentRow) -> String {
        if row.canFocusTerminal { return focusActionTitle(row) }
        return tr(.moreActions)
    }
}

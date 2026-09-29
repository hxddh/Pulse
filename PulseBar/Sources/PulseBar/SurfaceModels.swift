import Foundation

// 15.0 · Witness — the Workbench's judgement surfaces as values.
//
// Until 14.0 the Mission card and the working-copy card read `StatusStore`
// directly — 13 lookups per cell — so the only way to see them was to run the
// whole app against real sessions, and nobody had. Here each surface is a
// pure function from plain inputs to an `Equatable` value; the SwiftUI view
// renders the value and sends intents, and the store maps intents to verbs.
// That is what lets a fixture render every state in CI (`SurfaceCapture`) and
// lets a test assert the product's rules on the value itself: dispatch order
// is the only order, and nothing but a current pass reads as passed.

/// How a check cell reads. `passed` is reserved for a current pass on
/// unchanged code — the one tone a surface may never hand out otherwise.
enum CheckTone: Equatable, Sendable {
    case neutral
    case warn
    case passed
}

struct CheckCell: Equatable, Sendable {
    var text: String
    var tone: CheckTone
}

enum SurfaceLabels {
    /// One wording for a check cell, shared by every surface.
    static func check(_ standing: Mission.CheckStanding, lang: ResolvedLanguage) -> CheckCell {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch standing {
        case .notInContract: return CheckCell(text: t(.missionCheckNotInContract), tone: .neutral)
        case .notRun: return CheckCell(text: t(.missionCheckNotRun), tone: .neutral)
        case .running: return CheckCell(text: t(.missionCheckRunning), tone: .neutral)
        case .evidence(let judged, let evidence):
            switch judged {
            case .passing: return CheckCell(text: t(.missionCheckPassed), tone: .passed)
            case .stale: return CheckCell(text: t(.managedRunCheckStale), tone: .warn)
            case .measuring: return CheckCell(text: t(.managedRunCheckMeasuring), tone: .neutral)
            case .unverified: return CheckCell(text: t(.managedRunCheckUnverified), tone: .warn)
            case .notPassing: return CheckCell(text: notPassing(evidence, lang: lang), tone: .warn)
            }
        }
    }

    /// The single run-check result of a managed session (6.0): the same
    /// judgement, worded with the exit code.
    static func evidence(_ evidence: AcceptanceEvidence, standing: EvidenceStanding, lang: ResolvedLanguage) -> CheckCell {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch standing {
        case .measuring: return CheckCell(text: t(.managedRunCheckMeasuring), tone: .neutral)
        case .unverified: return CheckCell(text: t(.managedRunCheckUnverified), tone: .warn)
        case .stale: return CheckCell(text: t(.managedRunCheckStale), tone: .warn)
        case .passing:
            return CheckCell(text: String(format: t(.managedRunCheckExit), evidence.exitCode ?? 0), tone: .passed)
        case .notPassing:
            if evidence.outcome == .passed || evidence.outcome == .failed {
                return CheckCell(text: String(format: t(.managedRunCheckExit), evidence.exitCode ?? -1), tone: .warn)
            }
            return CheckCell(text: notPassing(evidence, lang: lang), tone: .warn)
        }
    }

    private static func notPassing(_ evidence: AcceptanceEvidence, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch evidence.outcome {
        case .timedOut: return t(.managedRunCheckTimeout)
        case .couldNotRun: return t(.managedRunCheckUnverified)
        case .invalidatedDuringRun: return t(.managedRunCheckChanged)
        case .interrupted: return t(.managedRunCheckInterrupted)
        case .passed, .failed:
            return String(format: t(.missionCheckFailed), Int(evidence.exitCode ?? -1))
        }
    }

    static func status(_ status: ManagedSession.Status, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch status {
        case .idle: return t(.managedIdle)
        case .running: return t(.managedRunning)
        case .queued: return t(.managedQueuedNote)
        case .interrupted: return t(.managedInterrupted)
        case .cancelled: return t(.managedCancelled)
        case .failed(let reason): return String(format: t(.managedFailed), reason)
        }
    }

    static func lifecycle(_ lifecycle: Mission.Lifecycle, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch lifecycle {
        case .draft: return t(.missionLifecycleDraft)
        case .running: return t(.missionLifecycleRunning)
        case .ready: return t(.missionLifecycleReady)
        case .archived: return t(.missionLifecycleArchived)
        }
    }
}

// MARK: - The Mission board

/// A Mission's Candidates side by side. Columns are Candidates in dispatch
/// order, then external Candidates in join order — never any other order.
struct MissionBoard: Equatable {
    struct Column: Equatable, Identifiable {
        var id: String
        /// "Candidate 2" — its ordinal in dispatch/join order.
        var title: String
        var isCurrent: Bool
        var chosen: Bool
        /// Set for a working copy joined from outside Pulse; it can leave.
        var externalID: String?
        var externalNote: String
        var revisionNote: String
        /// Where "view" goes in the Workbench; nil when nothing to open.
        var selectionKey: String?
        var session: String
        var changes: String
        var answer: String
        var problems: String
        /// One per `MissionBoard.checks`, same order.
        var cells: [CheckCell]
    }

    var lang: ResolvedLanguage
    var missionID: String
    var lifecycle: String
    var revision: String
    var goal: String
    var constraints: String
    var legacyNote: String?
    var noChecksWarning: String?
    var checks: [String]
    var columns: [Column]
    var canRunChecks: Bool
    var busy: Bool

    /// Everything the board is built from, as plain values and lookups.
    struct Input {
        var mission: Mission.Model
        /// Dispatch order, as the fleet holds them.
        var candidates: [ManagedSession.Model]
        var runningCandidateIDs: Set<String> = []
        var currentCandidateID: String
        var lifecycle: Mission.Lifecycle
        var lang: ResolvedLanguage
        /// The observed row working in a root right now, if any.
        var observed: (String) -> AgentRow? = { _ in nil }
        var evidence: (String) -> [AcceptanceEvidence] = { _ in [] }
        var running: (String) -> RunningCheck? = { _ in nil }
        var busy: (String) -> Bool = { _ in false }
        /// Whether a piece of evidence still holds for the code in a root now.
        var judge: (AcceptanceEvidence, String) -> EvidenceStanding = { _, _ in .measuring }
    }

    static func make(_ input: Input) -> MissionBoard {
        let mission = input.mission
        let lang = input.lang
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }

        struct Source {
            var id: String
            var model: ManagedSession.Model?
            var external: Mission.External?
            var root: String
            var revision: Int
        }
        let sources: [Source] =
            input.candidates.map {
                Source(id: $0.id, model: $0, external: nil, root: $0.root, revision: $0.contractRevision)
            } + mission.externals.map {
                Source(id: $0.id, model: nil, external: $0, root: $0.root, revision: $0.revision)
            }

        let columns = sources.enumerated().map { index, source -> Column in
            let row = source.model == nil ? input.observed(source.root) : nil
            let evidence = input.evidence(source.root)
            let running = input.running(source.root)
            let cells = mission.contract.checks.map { check in
                SurfaceLabels.check(
                    Mission.standing(
                        of: check, revision: source.revision, evidence: evidence,
                        running: running, mission: mission
                    ) { input.judge($0, source.root) },
                    lang: lang
                )
            }
            let selectionKey: String? = source.id == input.currentCandidateID ? nil
                : source.model != nil ? "managed|" + source.id
                : row?.rowKey
            return Column(
                id: source.id,
                title: String(format: t(.missionCandidate), index + 1),
                isCurrent: source.id == input.currentCandidateID,
                chosen: mission.chosenCandidateID == source.id,
                externalID: source.external?.id,
                externalNote: source.external.map { String(format: t(.missionExternal), $0.label) } ?? "",
                revisionNote: source.revision != mission.contract.revision && source.revision > 0
                    ? String(format: t(.missionOlderRevision), source.revision) : "",
                selectionKey: selectionKey,
                session: sessionFact(source.model, row: row, lang: lang),
                changes: changesFact(source.model, row: row),
                answer: answerFact(source.model, row: row),
                problems: problemsFact(source.model, row: row),
                cells: cells
            )
        }

        let busy = sources.contains { input.busy($0.root) }
        let turnRunning = input.candidates.contains { input.runningCandidateIDs.contains($0.id) }
        return MissionBoard(
            lang: lang,
            missionID: mission.id,
            lifecycle: SurfaceLabels.lifecycle(input.lifecycle, lang: lang),
            revision: String(format: t(.missionRevision), mission.contract.revision),
            goal: mission.contract.goal,
            constraints: mission.contract.constraints,
            legacyNote: mission.legacy ? t(.missionLegacyNote) : nil,
            noChecksWarning: mission.contract.checks.isEmpty ? t(.missionNoChecks) : nil,
            checks: mission.contract.checks.map(\.command),
            columns: columns,
            canRunChecks: !mission.contract.checks.isEmpty && !busy && !turnRunning && !columns.isEmpty,
            busy: busy
        )
    }

    private static func sessionFact(_ model: ManagedSession.Model?, row: AgentRow?, lang: ResolvedLanguage) -> String {
        if let model {
            var parts = [model.runtimeID]
            if !model.modelName.isEmpty { parts.append(model.modelName) }
            parts.append(SurfaceLabels.status(model.status, lang: lang))
            return parts.joined(separator: " · ")
        }
        guard let row else { return L10n.t(.missionExternalGone, lang) }
        var parts = [row.agent.displayName]
        if !row.model.isEmpty { parts.append(row.model) }
        parts.append(row.waiting ? L10n.t(.needsYou, lang)
                     : row.liveProcess ? L10n.t(.managedRunning, lang) : L10n.t(.managedIdle, lang))
        return parts.joined(separator: " · ")
    }

    private static func changesFact(_ model: ManagedSession.Model?, row: AgentRow?) -> String {
        if let model {
            guard let effect = model.lastTurnEffect else { return "—" }
            return "+\(effect.insertions) −\(effect.deletions)"
        }
        guard let row, row.hasWorkspaceEffect, row.insertions >= 0, row.deletions >= 0 else { return "—" }
        return "+\(row.insertions) −\(row.deletions)"
    }

    private static func answerFact(_ model: ManagedSession.Model?, row: AgentRow?) -> String {
        if let model { return model.lastResultText.isEmpty ? "—" : model.lastResultText }
        let word = row?.lastWord ?? ""
        return word.isEmpty ? "—" : word
    }

    private static func problemsFact(_ model: ManagedSession.Model?, row: AgentRow?) -> String {
        if let model { return "\(model.errorResults) · \(model.unknownEvents)" }
        guard let row else { return "—" }
        return "\(row.errors) · —"
    }
}

enum MissionIntent: Equatable {
    case select(key: String)
    case choose(candidateID: String)
    case leave(externalID: String)
    case runChecks
    case stopChecks
}

// MARK: - The working-copy card

/// The user's own ruler for a directory Pulse did not create (14.0).
struct ProofCardModel: Equatable {
    struct Line: Equatable, Identifiable {
        var id: String
        var command: String
        var cell: CheckCell
    }

    struct Joined: Equatable {
        var missionID: String
        var title: String
        var externalID: String?
    }

    struct Choice: Equatable, Identifiable {
        var id: String
        var title: String
    }

    var lang: ResolvedLanguage
    /// The saved checks, one command per line — what the editor starts from.
    var savedChecksText: String
    var lines: [Line]
    var canRun: Bool
    var busy: Bool
    var joined: Joined?
    var joinable: [Choice]

    struct Input {
        var root: String
        var checks: [Mission.Check]
        var evidence: [AcceptanceEvidence] = []
        var running: RunningCheck? = nil
        var busy = false
        /// Every Mission, oldest first, as the fleet holds them.
        var missions: [Mission.Model] = []
        var lang: ResolvedLanguage
        var judge: (AcceptanceEvidence) -> EvidenceStanding = { _ in .measuring }
    }

    static func make(_ input: Input) -> ProofCardModel {
        let lines = input.checks.map { check in
            Line(
                id: check.id,
                command: check.command,
                cell: SurfaceLabels.check(
                    Mission.checkStanding(of: check, evidence: input.evidence, running: input.running, judge: input.judge),
                    lang: input.lang
                )
            )
        }
        let joinedMission = input.root.isEmpty ? nil : input.missions.first { mission in
            mission.externals.contains { $0.root == input.root }
        }
        return ProofCardModel(
            lang: input.lang,
            savedChecksText: input.checks.map(\.command).joined(separator: "\n"),
            lines: lines,
            canRun: !input.checks.isEmpty && !input.busy,
            busy: input.busy,
            joined: joinedMission.map { mission in
                Joined(
                    missionID: mission.id,
                    title: mission.title,
                    externalID: mission.externals.first { $0.root == input.root }?.id
                )
            },
            joinable: joinedMission != nil ? [] : input.missions
                .filter { !$0.archived }
                .reversed()
                .map { Choice(id: $0.id, title: $0.title) }
        )
    }
}

enum ProofIntent: Equatable {
    case save(text: String)
    case run
    case stop
    case join(missionID: String)
    case leave(missionID: String, externalID: String)
    case refresh
}

// MARK: - 17.0 · Why

/// Why a row is in its state, and what the hooks said to put it there.
struct WhyCardModel: Equatable {
    var lang: ResolvedLanguage
    /// The one sentence; nil when the state needs no explaining.
    var why: String?
    /// Newest first, at most `maxLines`.
    var lines: [String]
    /// Events kept for this session (what an export would copy).
    var eventCount: Int

    static let maxLines = 12

    var isEmpty: Bool { why == nil && lines.isEmpty }

    static func make(row: AgentRow, history: [AttentionHistory.Event], narrator: RowNarrator) -> WhyCardModel {
        WhyCardModel(
            lang: narrator.lang,
            why: narrator.whyLine(row),
            lines: history.suffix(maxLines).reversed().map(narrator.historyLine),
            eventCount: history.count
        )
    }
}

enum WhyIntent: Equatable {
    case export
}

import Foundation

/// 19.0 · the cards that open under a tray row, as values.
///
/// 17.0 made the row's face a value and left the cards beneath it — the
/// managed permission ask, Respond's full request, the managed reply box,
/// the expanded inspector, the digest — reading the store. They are where
/// the user acts, so they are where a stale or wrong render costs most, and
/// until now none of them could be drawn without a running app and a real
/// fleet. Each is now a pure function of the row, the narrator and the few
/// facts only the store knows (the matched request, the fleet's asks, the
/// runner's status and last entries), passed in as plain values; the views
/// render these and send `Action`s back.
///
/// The product rules stay in the model, where tests can reach them: Allow
/// exists only beside the full request (`canOfferAllow`), a truncated ask
/// withdraws it, and a Respond verdict carries the id and digest of the
/// request that was on screen.
struct RowCardModel: Equatable {
    enum Action: Equatable {
        case permission(id: String, allow: Bool)
        /// The request as rendered — a verdict is only ever about what the
        /// user was looking at.
        case respondDeny(requestID: String, digest: String)
        case respondAllow(requestID: String, digest: String)
        case managedCancel
        case managedSend(String)
        case dismiss, snooze, unsnooze, openWorkbench
    }

    /// A managed session's permission ask (scene BJ).
    struct Permission: Equatable, Identifiable {
        var id: String
        var heading: String
        var input: String
        /// Set when the input was cut: Allow is withdrawn and this says why.
        var truncatedNote: String?
        var canOfferAllow: Bool
        var hint: String
        var deny: String
        var allow: String
    }

    /// Respond's full request (scenes AR/AU/BB).
    struct Respond: Equatable {
        var heading: String
        var fullRequest: String
        var requestID: String
        var digest: String
        /// Once a verdict is written, the receipt replaces the buttons.
        var fateNote: String?
        var canOfferAllow: Bool
        var deny: String
        var allow: String
    }

    /// The managed session's turn, and whether the reply box shows.
    struct Reply: Equatable {
        enum Turn: Equatable {
            /// Running: the label (with the tool when known) and a stop button.
            case running(String)
            case queued(String)
            /// The app quit mid-turn: said so, and the box stays open.
            case interrupted(String)
            /// Idle, failed or cancelled: the box.
            case open
        }
        var turn: Turn
        var placeholder: String
        var send: String
        var cancel: String

        var showsField: Bool {
            switch turn {
            case .open, .interrupted: return true
            case .running, .queued: return false
            }
        }
    }

    struct Plan: Equatable {
        struct Step: Equatable {
            var mark: String
            var text: String
            var current: Bool
            var done: Bool
        }
        var progress: String?
        var steps: [Step]
        /// Steps beyond the four the compact face shows.
        var overflow: Int
    }

    /// One line of a managed conversation's last moves.
    struct Entry: Equatable {
        enum Tone: Equatable { case user, agent, tool, error }
        var label: String
        var text: String
        var tone: Tone
        var monospaced: Bool
    }

    /// 11.0-α (scene BV) — the digest tier: information in place.
    struct Brief: Equatable {
        var fullWords: String?
        var planStep: String?
        var effect: String?

        var isEmpty: Bool { fullWords == nil && planStep == nil && effect == nil }
    }

    var lang: ResolvedLanguage
    var rowKey: String

    // Understand
    var task: String?
    var lastWord: String?
    var errorText: String?
    var plan: Plan?
    var workFacts: [String]
    var panorama: [String]
    var entries: [Entry]
    var brief: Brief

    // Act
    var permissions: [Permission]
    var respond: Respond?
    /// Nil for an observed row: only a managed session has a reply box.
    var reply: Reply?
    /// 11.0-α: a dead turn (interrupted / failed) is a needs-you state — the
    /// recovery box rides the in-list cards like an ask does.
    var needsRecovery: Bool
    var waitActions: [WaitAction]
    var openWorkbench: String

    struct WaitAction: Equatable {
        var action: Action
        var title: String
    }

    /// Anything in the in-list "needs you now" card.
    var hasAsks: Bool { !permissions.isEmpty || respond != nil || needsRecovery }

    /// Store-only facts, as values.
    struct Input {
        var row: AgentRow
        var narrator: RowNarrator
        var permissions: [ManagedPermission.Request] = []
        /// The matched full request, when the row is waiting on one.
        var inbound: RespondSpool.InboundRequest? = nil
        var fateNote: String? = nil
        var managedStatus: ManagedSession.Status? = nil
        var managedEntries: [TranscriptReader.Entry] = []
    }

    static let heroClipThreshold = 96
    static let compactPlanSteps = 4
    static let ambientEntries = 5

    static func make(_ input: Input) -> RowCardModel {
        let row = input.row
        let n = input.narrator
        func t(_ key: L10n.Key) -> String { n.tr(key) }

        var waitActions: [WaitAction] = []
        if row.waiting {
            waitActions.append(WaitAction(action: .dismiss, title: t(.dismissWait)))
            waitActions.append(row.isSnoozed
                ? WaitAction(action: .unsnooze, title: t(.snoozed))
                : WaitAction(action: .snooze, title: t(.snooze)))
        }

        return RowCardModel(
            lang: n.lang,
            rowKey: row.rowKey,
            task: row.usefulTask,
            lastWord: row.selfReportFresh && !row.lastWord.isEmpty ? row.lastWord : nil,
            errorText: row.lastErrorText.isEmpty ? nil : row.lastErrorText,
            plan: row.selfReportFresh && !row.planSteps.isEmpty ? plan(row, narrator: n) : nil,
            workFacts: n.workDetailFacts(row),
            panorama: [
                n.rowStoryLine(row),
                n.rowSignalLine(row),
                n.rowObservationLine(row),
                n.rowWorkLine(row),
                n.rowContextLine(row),
            ].filter { !$0.isEmpty },
            entries: row.isManaged
                ? input.managedEntries.suffix(ambientEntries).map { entry(row.agent.displayName, $0, narrator: n) }
                : [],
            brief: brief(row, narrator: n),
            permissions: input.permissions.map { permission($0, narrator: n) },
            respond: row.waiting ? input.inbound.map { respond($0, row: row, fateNote: input.fateNote, narrator: n) } : nil,
            reply: row.isManaged ? input.managedStatus.map { reply($0, row: row, narrator: n) } : nil,
            needsRecovery: {
                switch input.managedStatus {
                case .interrupted, .failed: return true
                default: return false
                }
            }(),
            waitActions: waitActions,
            openWorkbench: t(.trayOpenInWorkbench)
        )
    }

    static func permission(_ request: ManagedPermission.Request, narrator n: RowNarrator) -> Permission {
        Permission(
            id: request.id,
            heading: "\(n.tr(.managedPermissionHeading)) · \(request.toolName)",
            input: request.inputJSON,
            truncatedNote: request.truncated ? n.tr(.managedPermissionTruncated) : nil,
            canOfferAllow: request.canOfferAllow,
            hint: n.tr(.managedPermissionHint),
            deny: n.tr(.respondDeny),
            allow: n.tr(.respondAllow)
        )
    }

    static func respond(
        _ inbound: RespondSpool.InboundRequest,
        row: AgentRow,
        fateNote: String?,
        narrator n: RowNarrator
    ) -> Respond {
        Respond(
            heading: "\(n.tr(.respondFullRequest)) · \(inbound.toolName.isEmpty ? row.agent.displayName : inbound.toolName)",
            fullRequest: inbound.request.fullRequest,
            requestID: inbound.request.id,
            digest: inbound.request.digest,
            fateNote: fateNote,
            canOfferAllow: inbound.request.canOfferAllow,
            deny: n.tr(.respondDeny),
            allow: n.tr(.respondAllow)
        )
    }

    static func reply(_ status: ManagedSession.Status, row: AgentRow, narrator n: RowNarrator) -> Reply {
        let turn: Reply.Turn
        switch status {
        case .running:
            let running = n.tr(.managedRunning)
            turn = .running(row.tool.isEmpty ? running : running + " · " + row.tool)
        case .queued:
            turn = .queued(n.tr(.managedQueuedNote))
        case .interrupted:
            turn = .interrupted(n.tr(.managedInterrupted))
        case .idle, .failed, .cancelled:
            turn = .open
        }
        return Reply(
            turn: turn,
            placeholder: n.tr(.managedReplyPlaceholder),
            send: n.tr(.managedSend),
            cancel: n.tr(.managedCancel)
        )
    }

    static func plan(_ row: AgentRow, narrator n: RowNarrator) -> Plan {
        Plan(
            progress: row.progressTotal > 0
                ? String(format: n.tr(.progressFact), row.progressDone, row.progressTotal)
                : nil,
            steps: row.planSteps.prefix(compactPlanSteps).map { step in
                Plan.Step(
                    mark: step.state == .done ? "✓" : step.state == .current ? "▸" : "·",
                    text: step.text,
                    current: step.state == .current,
                    done: step.state == .done
                )
            },
            overflow: max(0, row.planSteps.count - compactPlanSteps)
        )
    }

    static func entry(_ agentName: String, _ entry: TranscriptReader.Entry, narrator n: RowNarrator) -> Entry {
        switch entry.kind {
        case .user:
            return Entry(label: n.tr(.workbenchTranscriptUser), text: entry.text.isEmpty ? "—" : entry.text, tone: .user, monospaced: false)
        case .agent:
            return Entry(label: agentName, text: entry.text.isEmpty ? "—" : entry.text, tone: .agent, monospaced: false)
        case .tool:
            let label: String
            if entry.isError {
                label = "↳ " + n.tr(.detailLastError)
            } else {
                // 6.0-γ: a result visibly hangs off its call.
                label = entry.toolName.isEmpty ? "↳ " + n.tr(.workbenchTranscriptResult) : entry.toolName
            }
            return Entry(label: label, text: entry.text.isEmpty ? "—" : entry.text, tone: entry.isError ? .error : .tool, monospaced: true)
        }
    }

    /// Mirrors the hero's clip: below it the hero already shows the whole
    /// sentence and repeating it would be the same fact twice.
    static func brief(_ row: AgentRow, narrator n: RowNarrator) -> Brief {
        let step = row.planStep.trimmingCharacters(in: .whitespacesAndNewlines)
        return Brief(
            fullWords: row.selfReportFresh && row.lastWord.count > heroClipThreshold ? row.lastWord : nil,
            planStep: row.selfReportFresh && !step.isEmpty && !n.rowMetaOwnsPlanStep(row) ? row.planStep : nil,
            effect: row.hasWorkspaceEffect && row.changedPaths > 0 && row.insertions >= 0 && row.deletions >= 0
                ? "+\(row.insertions) −\(row.deletions)"
                : nil
        )
    }
}

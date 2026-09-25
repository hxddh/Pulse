import Foundation

/// Store-side forwarders for `RowNarrator` (12.3).
///
/// The narration itself is a pure value now; the store only supplies what it
/// used to read implicitly — resolved language, the current instant, whether
/// the tray is crowded, and the managed fleet's outcome facts.
@MainActor
extension StatusStore {
    var narrator: RowNarrator {
        var managed: [String: ManagedSession.Model] = [:]
        for runner in managedSessions.runners where managed[runner.model.id] == nil {
            managed[runner.model.id] = runner.model
        }
        return RowNarrator(
            lang: lang,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            crowded: snapshot.rows.count >= TrayFold.crowdedFrom,
            managedModels: managed
        )
    }

    func detailLastAction(_ row: AgentRow) -> String { narrator.detailLastAction(row) }
    func detailPhase(_ row: AgentRow) -> String { narrator.detailPhase(row) }
    func lastActivityLabel(_ row: AgentRow) -> String { narrator.lastActivityLabel(row) }
    func rowContextLine(_ row: AgentRow, omitPath: Bool = false) -> String { narrator.rowContextLine(row, omitPath: omitPath) }
    func rowNowLine(_ row: AgentRow) -> String { narrator.rowNowLine(row) }
    func rowActivityChange(_ row: AgentRow) -> String { narrator.rowActivityChange(row) }
    func rowStoryLine(_ row: AgentRow) -> String { narrator.rowStoryLine(row) }
    func storyOwnsLastAction(_ row: AgentRow) -> Bool { narrator.storyOwnsLastAction(row) }
    func storyOwnsNow(_ row: AgentRow) -> Bool { narrator.storyOwnsNow(row) }
    func storyOwnsChange(_ row: AgentRow) -> Bool { narrator.storyOwnsChange(row) }
    func rowSourceLabel(_ row: AgentRow) -> String? { narrator.rowSourceLabel(row) }
    func remoteStatusLine(_ row: AgentRow, nowMs overrideMs: Int64? = nil) -> String? { narrator.remoteStatusLine(row, nowMs: overrideMs) }
    func rowMetrics(_ row: AgentRow) -> String { narrator.rowMetrics(row) }
    func rowSignalLine(_ row: AgentRow) -> String { narrator.rowSignalLine(row) }
    func faultFact(_ row: AgentRow) -> String { narrator.faultFact(row) }
    func rowObservationLine(_ row: AgentRow) -> String { narrator.rowObservationLine(row) }
    func rowWorkLine(_ row: AgentRow) -> String { narrator.rowWorkLine(row) }
    func workSlots(_ row: AgentRow) -> [String] { narrator.workSlots(row) }
    func rowMetaLine(_ row: AgentRow) -> String { narrator.rowMetaLine(row) }
    func rowMetaOwnsPlanStep(_ row: AgentRow) -> Bool { narrator.rowMetaOwnsPlanStep(row) }
    func workDetailFacts(_ row: AgentRow) -> [String] { narrator.workDetailFacts(row) }
    func heroToolTitle(_ row: AgentRow) -> String? { narrator.heroToolTitle(row) }
    func liveTool(_ row: AgentRow) -> String? { narrator.liveTool(row) }
    func readablePhase(_ raw: String, waiting: Bool = false) -> String? { narrator.readablePhase(raw, waiting: waiting) }
    func readableMode(_ raw: String) -> String { narrator.readableMode(raw) }
    func readableModel(_ raw: String) -> String { narrator.readableModel(raw) }
    func readableAction(_ raw: String) -> String { narrator.readableAction(raw) }
    func waitDurationLabel(_ row: AgentRow) -> String { narrator.waitDurationLabel(row) }
    func durationLabel(seconds ago: Double) -> String { narrator.durationLabel(seconds: ago) }
    func localizedWaitDetail(_ row: AgentRow) -> String? { narrator.localizedWaitDetail(row) }
    func localizedWaitLine(_ row: AgentRow) -> String { narrator.localizedWaitLine(row) }
    func focusActionTitle(_ row: AgentRow) -> String { narrator.focusActionTitle(row) }
    func primaryActionTitle(_ row: AgentRow) -> String { narrator.primaryActionTitle(row) }
    func evidenceTimeline(_ row: AgentRow) -> String { narrator.evidenceTimeline(row) }
    func tokenPair(input rawIn: Int, output rawOut: Int, scope: TokenScope = .compact) -> String { narrator.tokenPair(input: rawIn, output: rawOut, scope: scope) }
    func evidenceSessionTokens(_ row: AgentRow) -> String { narrator.evidenceSessionTokens(row) }
    func evidenceRate(_ row: AgentRow) -> String { narrator.evidenceRate(row) }
    func evidenceCPU(_ row: AgentRow) -> String { narrator.evidenceCPU(row) }
    func evidenceCPUNote(_ row: AgentRow) -> String { narrator.evidenceCPUNote(row) }
    func evidenceMemory(_ row: AgentRow) -> String? { narrator.evidenceMemory(row) }
    func evidenceRateNote(_ row: AgentRow) -> String { narrator.evidenceRateNote(row) }
    func evidenceSessionLength(_ row: AgentRow, nowMs overrideMs: Int64? = nil) -> String { narrator.evidenceSessionLength(row, nowMs: overrideMs) }
    func evidenceReadState(_ row: AgentRow) -> String { narrator.evidenceReadState(row) }
    func evidenceCountsArePartial(_ row: AgentRow) -> Bool { narrator.evidenceCountsArePartial(row) }
    func evidenceReadCompact(_ row: AgentRow) -> String { narrator.evidenceReadCompact(row) }
    func hasSessionEvidence(_ row: AgentRow) -> Bool { narrator.hasSessionEvidence(row) }
    func observationQualitySummary(_ row: AgentRow) -> String { narrator.observationQualitySummary(row) }
    func observationGapReason(_ gap: ObservationGap) -> String { narrator.observationGapReason(gap) }
    func observationGapNextStep(_ gap: ObservationGap) -> String { narrator.observationGapNextStep(gap) }
    func localizedWaitKind(_ kind: String) -> String { narrator.localizedWaitKind(kind) }
}

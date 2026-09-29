import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 23.0 · One Explain — the headline, the why and the source for a row, and
/// the row face and detail page built on them. Ported from the truth tests
/// of `RowNarrator.whyLine`, `TrayRowLead` and the Why card.
@Suite("Explain")
struct ExplainTests {
    let now: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private func session(_ agent: AgentID = .claude, task: String = "Refactor the settings panes") -> AgentRow {
        var row = AgentRow(rowKey: RowIdentity.session(agent: agent, sessionID: "s1"), agent: agent)
        row.sessionID = "s1"
        row.task = task
        row.project = "pulse"
        row.cwd = "/Users/me/pulse"
        row.source = .session
        row.liveProcess = true
        row.state = .running
        row.harvestMs = now - minute
        return row
    }

    private func blocked(_ signal: WaitSignalKind, kind: String = "Permission", inFront: Bool = false) -> AgentRow {
        var row = session()
        row.state = .blocked(RowWait(kind: kind, ask: "Bash: npm test", sinceMs: now - 4 * minute, signal: signal, inFront: inFront))
        return row
    }

    private func why(_ row: AgentRow, _ lang: ResolvedLanguage = .en, stallMinutes: Int = 0) -> String {
        Explain.make(row, lang: lang, nowMs: now, stallMinutes: stallMinutes).why
    }

    // MARK: - Why: which evidence, and since when

    @Test func aHookWaitNamesItsEvidenceAndItsAge() {
        let text = why(blocked(.hooks))
        #expect(text.contains("Claude"))
        #expect(text.contains(L10n.t(.explainKindPermission, .en)))
        #expect(text.contains(Explain.ago(now - 4 * minute, nowMs: now, lang: .en)))
        #expect(!text.hasSuffix(L10n.t(.explainHookFront, .en)))
    }

    @Test func aWaitRaisedInFrontSaysWhyThereWasNoBanner() {
        let text = why(blocked(.hooks, inFront: true))
        #expect(text.hasSuffix(L10n.t(.explainHookFront, .en)))
    }

    @Test func aPendingWaitNamesTheSessionFile() {
        let text = why(blocked(.pending, kind: "Input"))
        #expect(text.contains("Claude"))
        #expect(text.contains(L10n.t(.explainKindInput, .en)))
    }

    @Test func aVendorWaitSaysClaudeReportedIt() {
        let text = why(blocked(.vendor))
        #expect(text.hasPrefix("Claude itself"))
    }

    @Test func yourTurnSaysHowToClearItWithoutNowAgo() {
        var row = session(.codex)
        row.state = .yourTurn(sinceMs: now - 2_000)
        let text = why(row, .zh)
        #expect(text.contains("Codex"))
        #expect(!text.contains("刚刚前"), "never 'just now ago'")
    }

    @Test func aProcessOnlyRowSaysItIsOnlyAProcess() {
        var row = AgentRow(rowKey: RowIdentity.process(agent: .cursor, pid: 7), agent: .cursor)
        row.liveProcess = true
        row.state = .processOnly
        #expect(why(row) == L10n.t(.explainProcessOnly, .en))
        #expect(Explain.make(row, lang: .en, nowMs: now).source == L10n.t(.sourceProcess, .en))
    }

    @Test func aStalledRowNamesTheSilenceAndTheRuleItBroke() {
        var row = session()
        row.harvestMs = now - 23 * minute
        row.isStalled = true
        let withRule = why(row, stallMinutes: 20)
        #expect(withRule.contains(DurationFormat.label(seconds: 23 * 60, lang: .en)))
        #expect(withRule.contains("20"))
        let noRule = why(row)
        #expect(noRule == String(format: L10n.t(.explainStalledNoRule, .en), DurationFormat.label(seconds: 23 * 60, lang: .en)))
    }

    @Test func aStalledRowWithNoClockSaysSoRatherThanGuess() {
        var row = session()
        row.harvestMs = 0
        row.isStalled = true
        #expect(why(row) == L10n.t(.explainStalledUnknown, .en))
    }

    @Test func aRunningRowSaysWhereItsClockCameFrom() {
        let text = why(session())
        #expect(text.hasPrefix(L10n.t(.sourceSession, .en)))
        var noClock = session()
        noClock.harvestMs = 0
        #expect(why(noClock) == L10n.t(.explainRunningNoClock, .en))
    }

    @Test func errorsExplainTheOrangeLamp() {
        var row = session()
        row.errors = 3
        #expect(why(row) == String(format: L10n.t(.explainErrors, .en), 3))
        let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        #expect(face.lamp == .error)
        #expect(face.whyInline)
    }

    @Test func aRecentRowSaysThereIsNoProcess() {
        var row = session()
        row.liveProcess = false
        row.state = .recent
        #expect(why(row).hasPrefix("No live process"))
    }

    @Test func theSameRowAndInstantAlwaysSayTheSameThing() {
        let row = blocked(.hooks)
        #expect(Explain.make(row, lang: .en, nowMs: now) == Explain.make(row, lang: .en, nowMs: now))
    }

    @Test func thePinnedClockIsTheOneTheSentenceMeasuresFrom() {
        let row = blocked(.hooks)
        let early = Explain.make(row, lang: .en, nowMs: now).why
        let later = Explain.make(row, lang: .en, nowMs: now + 60 * minute).why
        #expect(early != later)
    }

    @Test func languageIsAnInput() {
        let row = blocked(.hooks)
        #expect(why(row, .en) != why(row, .zh))
    }

    // MARK: - Headline: the tray hero

    @Test func theTaskLeadsEvenWhenWordsAreFresh() {
        var row = session()
        row.lastWord = "All tests pass."
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == "Refactor the settings panes")
    }

    @Test func freshWordsLeadOnlyWithoutATask() {
        var row = session(task: "")
        row.lastWord = "All tests pass."
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == "All tests pass.")
        row.harvestMs = now - 45 * minute
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == "pulse", "stale words fall back to the project")
    }

    @Test func aSessionWithNothingToSayNamesItsHandle() {
        var row = session(task: "")
        row.project = ""
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == L10n.t(.appSession, .en))
        row.focusTier = .tty
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == L10n.t(.terminalSession, .en))
    }

    @Test func aWaitLeadsWithWhatThePersonMustRecognise() {
        var row = blocked(.hooks)
        row.lastWord = "Fresh words never displace the question."
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == "Refactor the settings panes")
        row.task = ""
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == "pulse")
        row.project = ""
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == L10n.t(.needsYou, .en))
    }

    @Test func aProcessOnlyRowSaysWhatLittleIsTrue() {
        var row = AgentRow(rowKey: RowIdentity.process(agent: .amp, pid: 9), agent: .amp)
        row.task = "never shown"
        row.state = .processOnly
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == L10n.t(.appDetectedNoDetails, .en))
        row.focusTier = .tty
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == L10n.t(.terminalDetectedNoDetails, .en))
    }

    @Test func aBlockedRowCarriesItsAsk() {
        let explain = Explain.make(blocked(.hooks), lang: .en, nowMs: now)
        #expect(explain.ask == "Bash: npm test")
        #expect(explain.state == L10n.waitKind("Permission", .en))
    }

    // MARK: - The lamp explanation

    @Test func aRedLampNamesWhoIsWaitingAndHow() {
        let waiting = blocked(.hooks)
        var other = session(.codex)
        other.rowKey = "codex|b"
        let explanation = LampExplanation.make(
            rows: [waiting, other], glance: .waiting, staleHidden: 3, lang: .en, nowMs: now
        )
        #expect(explanation.rule == .blocked)
        let keys = explanation.drivers.map { $0.rowKey }
        #expect(keys == [waiting.rowKey])
        let lines = explanation.lines(.en)
        #expect(lines.first == L10n.t(.lampRuleBlocked, .en))
        #expect(lines.count == 3)
        #expect(lines[1] == "Claude · pulse — " + why(waiting))
        #expect(lines.last?.contains("3") == true, "what was left out is said")
    }

    @Test func anOrangeLampWithoutAStallIsAProcessOnlySession() {
        var process = AgentRow(rowKey: RowIdentity.process(agent: .cursor, pid: 3), agent: .cursor)
        process.liveProcess = true
        process.state = .processOnly
        let explanation = LampExplanation.make(rows: [process], glance: .stalled, staleHidden: 0, lang: .zh, nowMs: now)
        #expect(explanation.rule == .thinRunning)
        #expect(explanation.drivers.first?.agent == .cursor)
        #expect(explanation.drivers.first?.reason == L10n.t(.explainProcessOnly, .zh))
    }

    @Test func aStalledLampSaysWhichSessionWentQuiet() {
        var stalled = session()
        stalled.harvestMs = now - 30 * minute
        stalled.isStalled = true
        let explanation = LampExplanation.make(rows: [stalled], glance: .stalled, staleHidden: 0, lang: .en, nowMs: now, stallMinutes: 20)
        #expect(explanation.rule == .stalled)
        #expect(explanation.drivers.first?.reason.contains("20") == true)
    }

    @Test func aGreyLampWithATurnSaysWhoseTurn() {
        var turn = session(.codex)
        turn.state = .yourTurn(sinceMs: now - minute)
        let explanation = LampExplanation.make(rows: [turn], glance: .idle, staleHidden: 0, lang: .en, nowMs: now)
        #expect(explanation.rule == .yourTurn)
        #expect(explanation.drivers.count == 1)
    }

    // MARK: - The row face

    @Test func aPermissionRowShoutsAndOffersItsActions() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowPermission(), lang: .en)
        #expect(model.lamp == .waiting)
        #expect(model.chip?.kind == .waiting)
        #expect(model.accent != .none)
        // 21.0: at most two visible verbs — answer it, or put it down.
        let strip = model.strip.map { $0.action }
        #expect(strip == [.focus, .dismiss])
        #expect(model.stripAlwaysVisible)
        let menu = model.menu.map { $0.action }
        #expect(menu == [.details, .focus, .dismiss, .mute], "every verb is in the menu once")
        #expect(model.waitDetail == "Bash: npm run build")
    }

    @Test func yourTurnIsQuiet() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowTurn(), lang: .zh)
        #expect(model.lamp != .waiting)
        #expect(model.chip == TrayRowModel.Chip(kind: .recent, label: "轮到你"))
        #expect(model.accent == .none, "no gutter: the gutter is for blocked")
        #expect(!model.stripAlwaysVisible)
        #expect(model.accessibilityLabel.contains("轮到你"))
    }

    @Test func aProcessOnlyRowPointsAtSupportHealth() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowProcessOnly(), lang: .en)
        #expect(model.lamp == .process)
        #expect(model.strip.isEmpty, "only a wait shows verbs without a click")
        let hasHealth = model.menu.contains { $0.action == .supportHealth }
        #expect(hasHealth)
        #expect(model.whyInline, "an orange row explains itself")
        #expect(model.accessibilityHint == L10n.t(.processOnlyHint, .en))
        #expect(!model.canPrimary)
    }

    @Test func everyFixtureSpeaksBothLanguages() {
        for lang in [ResolvedLanguage.en, .zh] {
            for fixture in SurfaceFixtures.all(lang: lang) {
                if case .row(let model, _, _) = fixture.value {
                    #expect(!model.hero.isEmpty, "\(fixture.name)")
                    #expect(!model.why.isEmpty, "\(fixture.name)")
                    #expect(model.lang == lang)
                }
            }
        }
    }

    // MARK: - The detail page

    @Test func theDetailPageSaysTheSameWhyAsTheRow() {
        let row = SurfaceFixtures.rowPermission()
        let face = SurfaceFixtures.rowModel(row, lang: .en)
        let detail = DetailModel.make(row: row, face: face, lang: .en, nowMs: SurfaceFixtures.nowMs)
        #expect(detail.why == face.why)
        #expect(detail.ask == "Bash: npm run build")
        #expect(detail.canDismiss)
        let labels = detail.facts.map { $0.label }
        #expect(labels.contains(L10n.t(.detailModel, .en)))
        #expect(labels.contains(L10n.t(.detailSource, .en)))
    }

    @Test func theDetailPlanCountsItsOwnSteps() {
        let fixture = SurfaceFixtures.detailTurn(lang: .en)
        let plan = fixture.plan
        #expect(plan?.steps.count == 3)
        #expect(plan?.progress == String(format: L10n.t(.progressFact, .en), 3, 3))
        #expect(fixture.lastWord != nil)
        #expect(!fixture.canDismiss)
    }

    @Test func staleWordsAndPlansAreNotQuotedAsNow() {
        var row = session()
        row.harvestMs = now - 45 * minute
        row.lastWord = "old"
        row.planSteps = [ActivityHarvest.PlanStep(text: "old step", state: .current)]
        let detail = DetailModel.make(
            row: row, face: TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now)), lang: .en, nowMs: now
        )
        #expect(detail.lastWord == nil)
        #expect(detail.plan == nil)
    }
}

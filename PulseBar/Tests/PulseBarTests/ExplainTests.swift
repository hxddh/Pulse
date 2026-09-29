import Foundation
import Testing
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Explain: the one explanation of a row and of the lamp.

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

    private func why(_ row: AgentRow, _ lang: ResolvedLanguage = .en) -> String {
        Explain.make(row, lang: lang, nowMs: now).why
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

    /// 23.0: the stall rule is not a setting, so the sentence names the
    /// silence and nothing the person could not have set.
    @Test func aStalledRowNamesTheSilence() {
        var row = session()
        row.harvestMs = now - 23 * minute
        row.isStalled = true
        let quiet = DurationFormat.label(seconds: 23 * 60, lang: .en)
        let expected = String(format: L10n.t(.explainStalled, .en), quiet)
        #expect(why(row) == expected)
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
        #expect(face.lamp == LampFace(shape: .ring, tone: .attention))
        #expect(face.secondLine?.kind == .warning)
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
        var row = AgentRow(rowKey: RowIdentity.process(agent: .codex, pid: 9), agent: .codex)
        row.task = "never shown"
        row.state = .processOnly
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == L10n.t(.appDetectedNoDetails, .en))
        row.focusTier = .tty
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == L10n.t(.terminalDetectedNoDetails, .en))
    }

    @Test func aBlockedRowCarriesItsAsk() {
        let explain = Explain.make(blocked(.hooks), lang: .en, nowMs: now)
        #expect(explain.ask == "Bash: npm test")
        #expect(explain.state == L10n.t(.needsYou, .en), "one word per concept")
    }

    // MARK: - The lamp explanation

    @Test func aRedLampSaysOneLine() {
        let waiting = blocked(.hooks)
        var other = session(.codex)
        other.rowKey = "codex|b"
        let explanation = LampExplanation.make(rows: [waiting, other], glance: .waiting)
        #expect(explanation.rule == .blocked)
        let sentence = explanation.sentence(.en)
        #expect(sentence == L10n.t(.lampRuleBlocked, .en))
        #expect(!sentence.contains("\n"))
    }

    @Test func aProcessOnlySessionIsAGreyRuleNotAnOrangeOne() {
        var process = AgentRow(rowKey: RowIdentity.process(agent: .cursor, pid: 3), agent: .cursor)
        process.liveProcess = true
        process.state = .processOnly
        let explanation = LampExplanation.make(rows: [process], glance: .idle)
        #expect(explanation.rule == .processOnly)
        #expect(explanation.sentence(.zh) == L10n.t(.lampRuleProcessOnly, .zh))
    }

    @Test func aStalledLampNamesNoThreshold() {
        var stalled = session()
        stalled.harvestMs = now - 30 * minute
        stalled.isStalled = true
        let explanation = LampExplanation.make(rows: [stalled], glance: .stalled)
        #expect(explanation.rule == .stalled)
        let sentence = explanation.sentence(.en)
        #expect(!sentence.contains("20"))
    }

    @Test func aGreyLampWithATurnSaysWhoseTurn() {
        var turn = session(.codex)
        turn.state = .yourTurn(sinceMs: now - minute)
        var process = AgentRow(rowKey: RowIdentity.process(agent: .codex, pid: 4), agent: .codex)
        process.state = .processOnly
        let explanation = LampExplanation.make(rows: [process, turn], glance: .idle)
        #expect(explanation.rule == .yourTurn, "a finished turn outranks a bare process")
    }

    // MARK: - The lamp's shape and tone, per state

    @Test func everyStateHasItsShapeAndTone() {
        var blockedRow = session()
        blockedRow.state = .blocked(RowWait(kind: "Permission", signal: .hooks))
        let running = session()
        var stalled = session()
        stalled.isStalled = true
        var failing = session()
        failing.errors = 2
        var turn = session()
        turn.state = .yourTurn(sinceMs: now)
        var recent = session()
        recent.state = .recent
        var process = AgentRow(rowKey: RowIdentity.process(agent: .codex, pid: 5), agent: .codex)
        process.state = .processOnly

        #expect(LampFace.row(blockedRow) == LampFace(shape: .filled, tone: .waiting))
        #expect(LampFace.row(running) == LampFace(shape: .ring, tone: .running))
        #expect(LampFace.row(stalled) == LampFace(shape: .ring, tone: .attention))
        #expect(LampFace.row(failing) == LampFace(shape: .ring, tone: .attention))
        #expect(LampFace.row(turn) == LampFace(shape: .hollow, tone: .idle))
        #expect(LampFace.row(recent) == LampFace(shape: .hollow, tone: .idle))
        #expect(LampFace.row(process) == LampFace(shape: .dotted, tone: .idle), "a process is never orange")
    }

    @Test func theMenuBarLampUsesTheSameShapes() {
        #expect(LampFace.glance(.waiting) == LampFace(shape: .filled, tone: .waiting))
        #expect(LampFace.glance(.running) == LampFace(shape: .ring, tone: .running))
        #expect(LampFace.glance(.stalled) == LampFace(shape: .ring, tone: .attention))
        #expect(LampFace.glance(.idle) == LampFace(shape: .hollow, tone: .idle))
        #expect(LampFace.glance(.idle, processOnly: true) == LampFace(shape: .dotted, tone: .idle))
    }

    // MARK: - The row face

    @Test func aPermissionRowShowsItsAskOnce() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowPermission(), lang: .en)
        #expect(model.lamp == LampFace(shape: .filled, tone: .waiting))
        #expect(model.secondLine == TrayRowModel.SecondLine(kind: .ask, text: "Bash: npm run build"))
        let menu = model.menu.map { $0.action }
        #expect(menu == [.focus, .details, .dismiss, .mute], "every verb is in the menu once")
        // The only time on a waiting row is how long it has waited.
        let waited = Explain.waitDuration(SurfaceFixtures.rowPermission(), nowMs: SurfaceFixtures.nowMs, lang: .en)
        #expect(model.age == waited)
    }

    @Test func yourTurnIsQuietAndSaysSo() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowTurn(), lang: .zh)
        #expect(model.lamp == LampFace(shape: .hollow, tone: .idle))
        #expect(model.turnLabel == "轮到你")
        #expect(model.secondLine == nil)
        #expect(model.accessibilityLabel.contains("轮到你"))
    }

    @Test func aProcessOnlyRowPointsAtDiagnostics() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowProcessOnly(), lang: .en)
        #expect(model.lamp == LampFace(shape: .dotted, tone: .idle))
        #expect(model.secondLine == nil, "grey is not a warning")
        let hasDiagnostics = model.menu.contains { $0.action == .diagnostics }
        #expect(hasDiagnostics)
        #expect(!model.canFocus)
    }

    @Test func aMutedRowSaysSoAndOffersUnmute() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowRunning(), lang: .en, muted: true)
        #expect(model.muted)
        let titles = model.menu.map { $0.title }
        #expect(titles.contains(L10n.t(.unmute, .en)))
    }

    @Test func theProjectIsNotRepeatedWhenItIsTheHeadline() {
        var row = SurfaceFixtures.rowPermission()
        row.task = ""
        let model = SurfaceFixtures.rowModel(row, lang: .en)
        #expect(model.headline == "app")
        #expect(model.project == "")
    }

    @Test func aWaitWithoutWordsNamesItsKind() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowPending(), lang: .en)
        #expect(model.secondLine == TrayRowModel.SecondLine(kind: .ask, text: L10n.waitKind("Permission", .en)))
    }

    @Test func everyFixtureSpeaksBothLanguages() {
        for lang in [ResolvedLanguage.en, .zh] {
            for fixture in SurfaceFixtures.all(lang: lang) {
                if case .row(let model, _) = fixture.value {
                    #expect(!model.headline.isEmpty, "\(fixture.name)")
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
        let detail = DetailModel.make(row: row, lang: .en, nowMs: SurfaceFixtures.nowMs)
        #expect(detail.why == face.why)
        #expect(detail.lamp == face.lamp)
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
        #expect(fixture.lastMessage != nil)
        #expect(!fixture.canDismiss)
    }

    @Test func staleWordsAndPlansAreNotQuotedAsNow() {
        var row = session()
        row.harvestMs = now - 45 * minute
        row.lastWord = "old"
        row.planSteps = [ActivityHarvest.PlanStep(text: "old step", state: .current)]
        let detail = DetailModel.make(row: row, lang: .en, nowMs: now)
        #expect(detail.lastMessage == nil)
        #expect(detail.plan == nil)
    }

    /// No placeholder rows: a fact Pulse does not have is not listed, and
    /// raw values are words.
    @Test func theDetailListsOnlyWhatItKnows() {
        var row = session()
        row.model = ""
        row.cwd = ""
        row.project = ""
        row.startedMs = 0
        let detail = DetailModel.make(row: row, lang: .en, nowMs: now)
        let labels = detail.facts.map { $0.label }
        #expect(labels == [L10n.t(.detailSource, .en)])
        let values = detail.facts.map { $0.value } + detail.diagnostics.map { $0.value }
        #expect(!values.contains("—"))
        #expect(!values.contains("session"), "an enum's raw value is not a word")
    }
}

/// 2.3 — the defects a fresh audit at the 2.2 baseline turned up.
///
/// Each of these is a place where the code said something it had not
/// measured, dropped work it had been asked to do, or let a click reach
/// nothing without saying so.
final class ExplainErrorTests: XCTestCase {
    private func liveRow() -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Fix the auth module"
        row.liveProcess = true
        row.state = .running
        row.harvestMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.source = .session
        return row
    }

    // MARK: D-2 · a fault is not crowded out

    /// 23.0: D-1 (token pairs) went with the facts; D-2 is one rule now —
    /// a row that reported errors explains its orange lamp with them.
    func testARowThatReportedErrorsSaysSo() {
        var row = liveRow()
        row.errors = 7
        let why = Explain.make(row, lang: .en, nowMs: row.harvestMs).why
        XCTAssertTrue(why.contains("7"), why)
    }

    func testNoErrorsIsNoFault() {
        let why = Explain.make(liveRow(), lang: .en, nowMs: liveRow().harvestMs).why
        XCTAssertFalse(why.contains("error"), why)
    }
}

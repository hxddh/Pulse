import Foundation
import Testing
import XCTest
@testable import PulseApp
@testable import PulseQA
@testable import PulseCore
@testable import PulseHarvest

// Explain: the one explanation of a row and of the lamp.

/// One Explain — the headline, the why and the source for a row, and
/// the row face and detail page built on them. Ported from the truth tests
/// of `RowNarrator.whyLine`, `TrayRowLead` and the Why card.
@Suite("Explain")
struct ExplainTests {
    let now: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private func session(_ agent: AgentID = .claude, task: String = "Refactor the settings panes") -> AgentRow {
        var row = AgentRow(rowKey: RowIdentity.session(agent: agent, session: "s1"), agent: agent)
        row.sessionID = "s1"
        row.task = task
        row.project = "pulse"
        row.cwd = "/Users/me/pulse"
        row.source = .hooks
        row.liveProcess = true
        row.state = .running
        row.lastEventMs = now - minute
        return row
    }

    private func blocked(kind: String = "Permission", inFront: Bool = false) -> AgentRow {
        var row = session()
        row.state = .blocked(RowWait(kind: kind, ask: "Bash: npm test", sinceMs: now - 4 * minute, inFront: inFront))
        return row
    }

    private func why(_ row: AgentRow, _ lang: ResolvedLanguage = .en) -> String {
        Explain.make(row, lang: lang, nowMs: now).why
    }

    // MARK: - Why: which evidence, and since when

    @Test func aHookWaitNamesItsEvidenceAndItsAge() {
        let text = why(blocked())
        #expect(text.contains("Claude"))
        #expect(text.contains(L10n.t(.explainKindPermission, .en)))
        #expect(text.contains(Explain.ago(now - 4 * minute, nowMs: now, lang: .en)))
        #expect(!text.hasSuffix(L10n.t(.explainAskedFront, .en)))
    }

    @Test func aWaitRaisedInFrontSaysWhyThereWasNoBanner() {
        let text = why(blocked(inFront: true))
        #expect(text.hasSuffix(L10n.t(.explainAskedFront, .en)))
    }

    /// The why is plain words — who asked what, and when.
    @Test func aWaitIsSaidInPlainWords() {
        #expect(why(blocked()) == "Claude asked for permission · 4m ago")
        #expect(why(blocked(), .zh) == "Claude 请求权限 · 4 分钟前")
        var process = AgentRow(rowKey: RowIdentity.process(agent: .cursor, pid: 7), agent: .cursor)
        process.state = .processOnly
        #expect(why(process) == "Started before Pulse — details after its next step")
        #expect(why(process, .zh) == "在 Pulse 之前启动——下一步之后显示详情")
        for lang in [ResolvedLanguage.en, .zh] {
            for key in L10n.Key.allCases where "\(key)".hasPrefix("explain") {
                let text = L10n.t(key, lang).lowercased()
                #expect(!text.contains("hook"), "\(key): \(text)")
            }
        }
    }

    @Test func aQuestionSaysInput() {
        let text = why(blocked(kind: "Input"))
        #expect(text.contains("Claude"))
        #expect(text.contains(L10n.t(.explainKindInput, .en)))
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

    /// The stall rule is not a setting, so the sentence names the
    /// silence and nothing the person could not have set.
    @Test func aStalledRowNamesTheSilence() {
        var row = session()
        row.lastEventMs = now - 23 * minute
        row.isStalled = true
        let quiet = DurationFormat.label(seconds: 23 * 60, lang: .en, spoken: true)
        let expected = String(format: L10n.t(.explainStalled, .en), quiet)
        #expect(why(row) == expected)
    }

    /// A stalled row's why names its last step: "Nothing new for 23m — last
    /// step: Bash · swift test".
    @Test func aStalledRowNamesItsLastStep() {
        var row = session()
        row.lastEventMs = now - 23 * minute
        row.isStalled = true
        row.lastStep = SessionBook.Step(tool: "Bash", target: "swift test", ms: now - 23 * minute)
        #expect(why(row) == "Nothing new for 23m — last step: Bash · swift test")
        #expect(why(row, .zh) == "已经 23 分钟 没有新动静——上一步：Bash · swift test")
        let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        #expect(face.secondLine == TrayRowModel.SecondLine(kind: .warning, text: why(row)))
    }

    /// A running row's quiet second line is its last step, worded as a
    /// past step; its time slot is this turn's duration.
    @Test func aRunningRowShowsItsLastStepAndItsTurn() {
        var row = session()
        row.turnStartMs = now - 14 * minute
        row.lastStep = SessionBook.Step(tool: "Bash", target: "swift test", ms: now - 12 * minute)
        row.recentSteps = [row.lastStep].compactMap { $0 }
        let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        #expect(face.secondLine == TrayRowModel.SecondLine(kind: .step, text: "Bash · swift test · 12m ago"))
        #expect(face.age == "14m")
        #expect(face.accessibilityLabel.contains("Bash · swift test"))
        let zh = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .zh, nowMs: now))
        #expect(zh.secondLine?.text == "Bash · swift test · 12 分钟前")
        #expect(zh.age == "14 分")
        // Under a minute the turn says so, and the step says "now".
        row.turnStartMs = now - 20_000
        row.lastStep = SessionBook.Step(tool: "Read", target: "", ms: now - 10_000)
        let young = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        #expect(young.age == "<1m")
        #expect(young.secondLine?.text == "Read · now")
    }

    /// No step, no second line: a Cursor or OpenCode row stays one line,
    /// and a row whose turn start is unknown shows when it last moved.
    @Test func aRowWithoutStepsStaysOneLine() {
        let face = TrayRowModel.make(TrayRowModel.Input(row: session(.cursor), lang: .en, nowMs: now))
        #expect(face.secondLine == nil)
        #expect(face.age == String(format: L10n.t(.agoFormat, .en), "1m"))
    }

    /// Step words say what was reported, never that it is still going.
    @Test func noStepWordingSaysRunning() {
        var row = session()
        row.isStalled = true
        row.lastStep = SessionBook.Step(tool: "Edit", target: "a.swift", ms: now - 30 * minute)
        row.recentSteps = [row.lastStep].compactMap { $0 }
        row.turnStartMs = now - 40 * minute
        for lang in [ResolvedLanguage.en, .zh] {
            var texts = [why(row, lang), Explain.stepLine(row.recentSteps[0], nowMs: now, lang: lang)]
            texts += [L10n.t(.stepStalled, lang), L10n.t(.stepHeading, lang), L10n.t(.stepThisTurn, lang)]
            let detail = DetailModel.make(row: row, lang: lang, nowMs: now)
            texts += detail.steps.flatMap { [$0.label, $0.value] }
            for text in texts {
                #expect(!text.lowercased().contains("running"), "\(text)")
                #expect(!text.contains("正在"), "\(text)")
            }
        }
    }

    /// The detail page lists up to five steps, newest first, and this
    /// turn's duration as a fact.
    @Test func theDetailListsRecentStepsAndThisTurn() {
        let detail = SurfaceFixtures.detailSteps(lang: .en)
        #expect(detail.steps.count == SessionBook.maxSteps)
        #expect(detail.steps.first?.value == "Bash · swift test")
        #expect(detail.steps.last?.value == "Read · Sources/Upload/Queue.swift")
        let turn = detail.facts.first { $0.label == L10n.t(.stepThisTurn, .en) }
        #expect(turn?.value == "14m")
    }

    @Test func aStalledRowWithNoClockSaysSoRatherThanGuess() {
        var row = session()
        row.lastEventMs = 0
        row.isStalled = true
        #expect(why(row) == L10n.t(.explainStalledUnknown, .en))
    }

    @Test func aRunningRowSaysItIsWorking() {
        let text = why(session())
        #expect(text.hasPrefix("Claude is working"), "\(text)")
        var noClock = session()
        noClock.lastEventMs = 0
        #expect(why(noClock) == L10n.t(.explainRunningNoClock, .en))
    }

    /// Orange is only a stall — a turn's error is a fact in the detail page,
    /// not a lamp.
    @Test func anErrorIsNotAnOrangeLamp() {
        var row = session()
        row.lastErrorText = "npm ERR! missing script: test"
        let face = TrayRowModel.make(TrayRowModel.Input(row: row, lang: .en, nowMs: now))
        #expect(face.lamp == LampFace(shape: .ring, tone: .running))
    }

    /// A recent row says which rule made it recent.
    @Test func aRecentRowSaysWhichRuleMadeItRecent() {
        var row = session()
        row.liveProcess = false
        row.state = .recent
        row.recentReason = .ended
        row.stateSinceMs = now - 5 * minute
        #expect(why(row).hasPrefix("The session ended"))
        row.recentReason = .atPrompt
        #expect(why(row).hasPrefix("At its prompt"))
        row.recentReason = .quiet
        #expect(why(row).contains("no process to watch"))
    }

    @Test func theSameRowAndInstantAlwaysSayTheSameThing() {
        let row = blocked()
        #expect(Explain.make(row, lang: .en, nowMs: now) == Explain.make(row, lang: .en, nowMs: now))
    }

    @Test func thePinnedClockIsTheOneTheSentenceMeasuresFrom() {
        let row = blocked()
        let early = Explain.make(row, lang: .en, nowMs: now).why
        let later = Explain.make(row, lang: .en, nowMs: now + 60 * minute).why
        #expect(early != later)
    }

    @Test func languageIsAnInput() {
        let row = blocked()
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
        row.lastEventMs = now - 45 * minute
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == "pulse", "stale words fall back to the project")
    }

    @Test func aSessionWithNothingToSayNamesItsHandle() {
        var row = session(task: "")
        row.project = ""
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == L10n.t(.appSession, .en))
        row.landingPlan = LandingPlan(steps: [.ttyTab(tty: "ttys003")])
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == L10n.t(.terminalSession, .en))
    }

    @Test func aWaitLeadsWithWhatThePersonMustRecognise() {
        var row = blocked()
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
        row.landingPlan = LandingPlan(steps: [.ttyTab(tty: "ttys003")])
        #expect(Explain.make(row, lang: .en, nowMs: now).headline == L10n.t(.terminalDetectedNoDetails, .en))
    }

    @Test func aBlockedRowCarriesItsAsk() {
        let explain = Explain.make(blocked(), lang: .en, nowMs: now)
        #expect(explain.ask == "Bash: npm test")
        #expect(explain.state == L10n.t(.needsYou, .en), "one word per concept")
    }

    // MARK: - The lamp explanation

    @Test func aRedLampSaysOneLine() {
        let waiting = blocked()
        var other = session(.codex)
        other.rowKey = "codex|b"
        let rule = Explain.lampRule(rows: [waiting, other], glance: .waiting)
        #expect(rule == .blocked)
        let sentence = Explain.lampSentence(rule, lang: .en)
        #expect(sentence == L10n.t(.lampRuleBlocked, .en))
        #expect(!sentence.contains("\n"))
    }

    @Test func aProcessOnlySessionIsAGreyRuleNotAnOrangeOne() {
        var process = AgentRow(rowKey: RowIdentity.process(agent: .cursor, pid: 3), agent: .cursor)
        process.liveProcess = true
        process.state = .processOnly
        let rule = Explain.lampRule(rows: [process], glance: .idle)
        #expect(rule == .processOnly)
        #expect(Explain.lampSentence(rule, lang: .zh) == L10n.t(.lampRuleProcessOnly, .zh))
    }

    @Test func aStalledLampNamesNoThreshold() {
        var stalled = session()
        stalled.lastEventMs = now - 30 * minute
        stalled.isStalled = true
        let rule = Explain.lampRule(rows: [stalled], glance: .stalled)
        #expect(rule == .stalled)
        let sentence = Explain.lampSentence(rule, lang: .en)
        #expect(!sentence.contains("20"))
    }

    @Test func aGreyLampWithATurnSaysWhoseTurn() {
        var turn = session(.codex)
        turn.state = .yourTurn(sinceMs: now - minute)
        var process = AgentRow(rowKey: RowIdentity.process(agent: .codex, pid: 4), agent: .codex)
        process.state = .processOnly
        let rule = Explain.lampRule(rows: [process, turn], glance: .idle)
        #expect(rule == .yourTurn, "a finished turn outranks a bare process")
    }

    // MARK: - The lamp's shape and tone, per state

    @Test func everyStateHasItsShapeAndTone() {
        var blockedRow = session()
        blockedRow.state = .blocked(RowWait(kind: "Permission"))
        let running = session()
        var stalled = session()
        stalled.isStalled = true
        var turn = session()
        turn.state = .yourTurn(sinceMs: now)
        var recent = session()
        recent.state = .recent
        var process = AgentRow(rowKey: RowIdentity.process(agent: .codex, pid: 5), agent: .codex)
        process.state = .processOnly

        #expect(LampFace.row(blockedRow) == LampFace(shape: .filled, tone: .waiting))
        #expect(LampFace.row(running) == LampFace(shape: .ring, tone: .running))
        #expect(LampFace.row(stalled) == LampFace(shape: .ring, tone: .attention))
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

    @Test func aProcessOnlyRowIsQuietGrey() {
        let model = SurfaceFixtures.rowModel(SurfaceFixtures.rowProcessOnly(), lang: .en)
        #expect(model.lamp == LampFace(shape: .dotted, tone: .idle))
        #expect(model.secondLine == nil, "grey is not a warning")
        let actions = model.menu.map { $0.action }
        #expect(actions == [.details, .mute], "details and mute; nothing to dismiss, nowhere to go")
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
        var row = SurfaceFixtures.rowPermission()
        row.state = .blocked(RowWait(kind: "Permission", sinceMs: SurfaceFixtures.nowMs - 2 * 60_000))
        let model = SurfaceFixtures.rowModel(row, lang: .en)
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

    /// The detail page's times say the day when it is not today.
    @Test func theClockSaysTheDayWhenItIsNotToday() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let hour: Int64 = 60 * minute
        let day: Int64 = 24 * hour
        // 2027-01-15 08:00 UTC, a Friday.
        #expect(LogClock.label(ms: now - 3 * hour, nowMs: now, lang: .en, timeZone: utc) == "05:00")
        #expect(LogClock.label(ms: now - 9 * hour, nowMs: now, lang: .en, timeZone: utc) == "Thu 23:00")
        #expect(LogClock.label(ms: now - 2 * day, nowMs: now, lang: .en, timeZone: utc) == "Wed 08:00")
        #expect(LogClock.label(ms: now - 2 * day, nowMs: now, lang: .zh, timeZone: utc) == "周三 08:00")
        #expect(LogClock.label(ms: now - 10 * day, nowMs: now, lang: .en, timeZone: utc) == "1/5 08:00")
        #expect(LogClock.label(ms: now - 10 * day, nowMs: now, lang: .zh, timeZone: utc) == "1/5 08:00")
    }

    @Test func theDetailPageSaysTheSameWhyAsTheRow() {
        let row = SurfaceFixtures.rowPermission()
        let face = SurfaceFixtures.rowModel(row, lang: .en)
        let detail = DetailModel.make(row: row, lang: .en, nowMs: SurfaceFixtures.nowMs)
        #expect(detail.why == face.why)
        #expect(detail.lamp == face.lamp)
        #expect(detail.ask == "Bash: npm run build")
        #expect(detail.canDismiss)
        let labels = detail.facts.map { $0.label }
        #expect(labels.contains(L10n.t(.detailSource, .en)))
        #expect(!labels.contains("Model"), "the model is never shown")
    }

    @Test func theTurnDetailQuotesTheLastMessage() {
        let fixture = SurfaceFixtures.detailTurn(lang: .en)
        #expect(fixture.lastMessage != nil)
        #expect(!fixture.canDismiss)
    }

    @Test func staleWordsAreNotQuotedAsNow() {
        var row = session()
        row.lastEventMs = now - 45 * minute
        row.lastWord = "old"
        let detail = DetailModel.make(row: row, lang: .en, nowMs: now)
        #expect(detail.lastMessage == nil)
    }

    /// No placeholder rows: a fact Pulse does not have is not listed, and
    /// raw values are words.
    @Test func theDetailListsOnlyWhatItKnows() {
        var row = session()
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

/// The defects a fresh audit turned up.
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
        row.lastEventMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.source = .hooks
        return row
    }

    // MARK: D-2 · a fault is not crowded out

    /// A turn's last error is shown on the detail page, where
    /// it can be read in full — not guessed into a count.
    func testALastErrorIsTheDetailPagesError() {
        var row = liveRow()
        row.lastErrorText = "npm ERR! missing script: test"
        XCTAssertEqual(DetailModel.make(row: row, lang: .en, nowMs: row.lastEventMs).error, "npm ERR! missing script: test")
        XCTAssertNil(DetailModel.make(row: liveRow(), lang: .en, nowMs: row.lastEventMs).error)
    }

    func testNoErrorsIsNoFault() {
        let why = Explain.make(liveRow(), lang: .en, nowMs: liveRow().lastEventMs).why
        XCTAssertFalse(why.contains("error"), why)
    }
}

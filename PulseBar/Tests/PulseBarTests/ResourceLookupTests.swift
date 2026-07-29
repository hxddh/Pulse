import XCTest
@testable import PulseBar

/// Resource loading must never be able to kill the app.
///
/// Every release from 0.21 to 0.23.0 shipped a DMG that crashed on launch:
/// `package.sh` built a malformed resource bundle, `Bundle(url:)` returned nil,
/// and the compiler-generated `Bundle.module` accessor called `fatalError()`
/// while drawing the menu bar icon. `swift test` was green the whole time,
/// because tests never load the packaged bundle.
///
/// These do not prove the DMG is correct — only `scripts/package_check.py`,
/// which reads the built .app, can do that. What they pin is the part that
/// belongs in the app: a resource that cannot be found degrades instead of
/// trapping.
final class ResourceLookupTests: XCTestCase {

    func testResolvingTheBundleDoesNotTrap() {
        // The assertion is that this line returns at all. Under `swift test`
        // the bundle may or may not be present; either answer is acceptable,
        // a crash is not.
        _ = PulseResources.bundle
    }

    func testMissingResourceReturnsNilRatherThanTrapping() {
        XCTAssertNil(PulseResources.url(forResource: "definitely-not-here", withExtension: "png"))
        XCTAssertNil(
            PulseResources.url(
                forResource: "definitely-not-here",
                withExtension: "png",
                subdirectory: "AgentIcons"
            )
        )
    }

    func testLookupIsStableAcrossCalls() {
        // `bundle` is a `static let`; a second call must not re-run resolution
        // and must not trap on the way through.
        let first = PulseResources.bundle?.bundleURL
        let second = PulseResources.bundle?.bundleURL
        XCTAssertEqual(first, second)
    }
}

/// Every brand source uses different transparent padding. The row should align
/// the visible mark, not the arbitrary file canvas.
final class AgentIconAlignmentTests: XCTestCase {
    func testEveryAgentIconHasAConsistentOpticalBox() {
        for agent in AgentID.allCases {
            guard let bounds = AgentIcon.alphaBounds(in: AgentIcon.image(for: agent)) else {
                return XCTFail("\(agent.displayName) icon rendered blank")
            }
            XCTAssertGreaterThanOrEqual(max(bounds.width, bounds.height), 49, agent.displayName)
            XCTAssertLessThanOrEqual(max(bounds.width, bounds.height), 54, agent.displayName)
            XCTAssertEqual(bounds.midX, 32, accuracy: 1.5, agent.displayName)
            XCTAssertEqual(bounds.midY, 32, accuracy: 1.5, agent.displayName)
        }
    }
}

/// Duration wording moved off `StatusStore` so `SnapshotBuilder` — which is
/// pure and has no store — could put the elapsed wait in the menu bar.
final class DurationFormatTests: XCTestCase {
    func testUnitsCrossOverAtTheRightPlaces() {
        XCTAssertEqual(DurationFormat.label(seconds: 2, lang: .en), "now")
        XCTAssertEqual(DurationFormat.label(seconds: 42, lang: .en), "42s")
        XCTAssertEqual(DurationFormat.label(seconds: 600, lang: .en), "10m")
        XCTAssertEqual(DurationFormat.label(seconds: 7200, lang: .en), "2h")
    }

    func testChineseDiffersFromEnglish() {
        XCTAssertNotEqual(
            DurationFormat.label(seconds: 600, lang: .zh),
            DurationFormat.label(seconds: 600, lang: .en)
        )
    }
}

/// Ten minutes is where a wait stops being ordinary. It is the only place in
/// the row where "longer" becomes "louder".
final class WaitUrgencyTests: XCTestCase {
    private func waitingRow(ageSeconds: Double) -> AgentRow {
        var row = AgentRow(rowKey: "k", agent: .claude)
        row.waiting = true
        row.waitSinceMs = Int64((Date().timeIntervalSince1970 - ageSeconds) * 1000)
        return row
    }

    func testShortWaitIsNotUrgent() {
        XCTAssertFalse(waitingRow(ageSeconds: 60).isUrgentWait)
    }

    func testLongWaitIsUrgent() {
        XCTAssertTrue(waitingRow(ageSeconds: 1200).isUrgentWait)
    }

    func testNonWaitingRowIsNeverUrgent() {
        var row = waitingRow(ageSeconds: 9999)
        row.waiting = false
        XCTAssertFalse(row.isUrgentWait)
    }

    func testUnknownStartIsNotUrgent() {
        var row = waitingRow(ageSeconds: 1200)
        row.waitSinceMs = 0
        XCTAssertFalse(row.isUrgentWait, "no timestamp must not read as an old wait")
    }
}


/// Screenshots of 0.24.0 showed one fact stated three and four times over.
final class RowRedundancyTests: XCTestCase {
    private func row(agent: AgentID, task: String = "", project: String = "") -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: agent)
        r.task = task
        r.project = project
        r.processCount = 1
        r.liveProcess = true
        return r
    }

    /// `Cursor · Cursor` — the dedupe compared the project to the hero only.
    func testProjectThatRestatesTheAgentIsDropped() {
        let r = row(agent: .cursor, task: "Pulse installation guide", project: "Cursor")
        XCTAssertEqual(AgentRow.shortProject(r.project), "Cursor")
        XCTAssertEqual(r.agent.displayName, "Cursor")
    }

    /// A bare process row said "Process detected", "process", and "Amp".
    func testProcessOnlyRowHasNoSessionTitleToShow() {
        let r = row(agent: .amp)
        XCTAssertTrue(r.isProcessOnly, "no task means the hero falls back to the agent name")
        XCTAssertNil(r.usefulTask)
    }

    func testEveryAgentDropsItsOwnGenericSessionPlaceholder() {
        for agent in AgentID.allCases {
            var r = row(agent: agent, task: "\(agent.displayName) session")
            r.sessionID = "real-id"
            XCTAssertNil(r.usefulTask, "\(agent.displayName) placeholder escaped as a task")
        }
    }
}


/// The two facts a row could never state, both collected from the start.
final class RowContextTests: XCTestCase {
    private func row(cwd: String = "", project: String = "", harvestMs: Int64 = 0) -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.cwd = cwd
        r.project = project
        r.harvestMs = harvestMs
        return r
    }

    /// Home itself is not a location worth naming; anything under it is.
    func testPathsUnderHomeUseTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(row(cwd: home).displayPath, "", "home is not a project")
        XCTAssertEqual(row(cwd: home + "/code").displayPath, "~/code")
    }

    /// The middle of a deep path carries no identity; the tail does.
    func testDeepPathsKeepTheirTail() {
        let p = row(cwd: "/a/b/c/d/e/Pulse").displayPath
        XCTAssertTrue(p.hasSuffix("e/Pulse"), p)
        XCTAssertTrue(p.contains("…"), p)
    }

    func testShallowPathsAreLeftAlone() {
        XCTAssertEqual(row(cwd: "/tmp/alpha").displayPath, "/tmp/alpha")
    }

    func testNoLocationYieldsNoPathRatherThanAPlaceholder() {
        XCTAssertEqual(row().displayPath, "")
    }

    func testProjectIsUsedWhenThereIsNoCwd() {
        XCTAssertEqual(row(project: "Pulse").displayPath, "Pulse")
    }

    func testUnknownActivityIsZeroNotEpoch() {
        XCTAssertEqual(row().lastActivitySeconds, 0)
    }

    func testActivityAgeCountsFromTheHarvestStamp() {
        let tenMinutesAgo = Int64((Date().timeIntervalSince1970 - 600) * 1000)
        XCTAssertEqual(row(harvestMs: tenMinutesAgo).lastActivitySeconds, 600, accuracy: 5)
    }
}

/// Each of these is a defect visible in a 0.25.0 screenshot.
final class ScreenshotRegressionTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private func row(cwd: String = "", project: String = "", harvestMs: Int64 = 0, live: Bool = false) -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.cwd = cwd
        r.project = project
        r.harvestMs = harvestMs
        r.liveProcess = live
        r.processCount = live ? 1 : 0
        return r
    }

    /// The panel grouped two sessions under "~" and a third under
    /// "users-rustjia" — the same directory, twice, and a header claiming
    /// three projects where there were two.
    func testHomeIsNotAProject() {
        XCTAssertEqual(row(cwd: home).displayPath, "")
        XCTAssertEqual(row(project: "~").displayPath, "")
    }

    func testEncodedHomeCollapsesToTheSamePlaceAsHome() {
        let user = (home as NSString).lastPathComponent
        XCTAssertTrue(AgentRow.isHomeLike("users-\(user)", home: home))
        XCTAssertTrue(AgentRow.isHomeLike(user, home: home))
        XCTAssertEqual(row(project: "users-\(user)").displayPath, "")
    }

    func testARealProjectIsStillAProject() {
        XCTAssertEqual(row(cwd: home + "/Documents/Cursor").displayPath, "~/Documents/Cursor")
        XCTAssertFalse(AgentRow.isHomeLike("/tmp/alpha", home: home))
    }

    /// "New Session" was shown as a row title.
    func testPlaceholderTitlesAreNotTitles() {
        for junk in ["New Session", "Untitled", "New Chat", "Agent session"] {
            var r = row()
            r.task = junk
            XCTAssertNil(r.usefulTask, "\(junk) is a placeholder, not a task")
        }
    }

    /// Live for twenty minutes with nothing happening looked like health.
    ///
    /// Evaluated against the scan's clock, so these pass an explicit `nowMs`
    /// rather than depending on when the suite happens to run.
    private let now: Int64 = 1_700_000_000_000

    private func stalled(agoSeconds: Double, waiting: Bool = false, live: Bool = true) -> Bool {
        AgentRow.stalled(
            harvestMs: now - Int64(agoSeconds * 1000),
            nowMs: now,
            waiting: waiting,
            live: live
        )
    }

    func testLongSilenceWhileLiveIsStalled() {
        XCTAssertTrue(stalled(agoSeconds: 25 * 60))
    }

    func testRecentActivityIsNotStalled() {
        XCTAssertFalse(stalled(agoSeconds: 60))
    }

    func testAStalledRowMustBeLive() {
        XCTAssertFalse(stalled(agoSeconds: 25 * 60, live: false), "a finished session is not stalled")
    }

    func testAWaitingRowIsNotAlsoStalled() {
        XCTAssertFalse(stalled(agoSeconds: 25 * 60, waiting: true), "Waiting already says why it is idle")
    }

    func testUnknownActivityIsNotStalled() {
        XCTAssertFalse(
            AgentRow.stalled(harvestMs: 0, nowMs: now, waiting: false, live: true),
            "no timestamp is not evidence of silence"
        )
    }

    /// A stalled row is one the user should react to, so it keeps its badge.
    func testStalledRowsAreBadged() {
        var r = row(live: true)
        r.isStalled = true
        XCTAssertTrue(r.needsStatusChip)
    }
}

/// Folding Recent: the panel's largest space win, and the one that can most
/// easily hide something the user came for.
final class TrayFoldTests: XCTestCase {
    private func row(_ agent: AgentID) -> AgentRow {
        AgentRow(rowKey: "k-\(agent.rawValue)", agent: agent)
    }

    func testRecentFoldsWhenItIsNotTheWholeList() {
        XCTAssertTrue(TrayFold.foldable(section: .recent, groupCount: 2, rowCount: 3, totalRows: 6))
    }

    func testFoldableGroupsStartExpandedAndOnlyManualChoiceCollapsesThem() {
        XCTAssertFalse(TrayFold.isCollapsed("project:vps", manuallyFolded: []))
        XCTAssertTrue(
            TrayFold.isCollapsed("project:vps", manuallyFolded: ["project:vps"])
        )
    }

    /// A 0.27 screenshot: three sessions, two folded, one row on screen.
    /// Folding costs a click and hides content; it only pays when the screen
    /// is the scarce thing, and at three rows it is not.
    func testNothingFoldsWhileThePanelHasRoom() {
        XCTAssertFalse(TrayFold.foldable(section: .recent, groupCount: 2, rowCount: 2, totalRows: 3))
        XCTAssertFalse(
            TrayFold.foldableProject(hasWaiting: false, groupCount: 2, rowCount: 2, totalRows: 3)
        )
    }

    /// Folding the only group leaves a panel that says nothing.
    func testRecentDoesNotFoldWhenItIsAllThereIs() {
        XCTAssertFalse(TrayFold.foldable(section: .recent, groupCount: 1, rowCount: 5, totalRows: 9))
    }

    /// One row under a heading is already one line; folding it saves nothing
    /// and costs a click.
    func testASingleRowIsNotWorthFolding() {
        XCTAssertFalse(TrayFold.foldable(section: .recent, groupCount: 3, rowCount: 1, totalRows: 9))
    }

    /// Needs-you and Running are why the panel is open. They never fold.
    func testActionableSectionsNeverFold() {
        for section in [TraySection.needsYou, .running, .stalled] {
            XCTAssertFalse(
                TrayFold.foldable(section: section, groupCount: 3, rowCount: 4, totalRows: 9),
                "\(section) must stay open"
            )
        }
    }

    func testFoldedHeadingStillSaysWhoIsInThere() {
        let s = TrayFold.summary([row(.claude), row(.cursor)])
        XCTAssertTrue(s.contains("Claude"), s)
        XCTAssertTrue(s.contains("Cursor"), s)
    }

    /// Three sessions of one agent is one name, not three.
    func testRepeatedAgentsAreNamedOnce() {
        XCTAssertEqual(TrayFold.summary([row(.claude), row(.claude), row(.claude)]), "Claude")
    }

    /// A folded heading is one line; the summary must not be what breaks that.
    func testLongRostersCountTheRestInsteadOfListingThem() {
        let rows = [row(.claude), row(.cursor), row(.amp), row(.aider), row(.goose)]
        let s = TrayFold.summary(rows)
        XCTAssertTrue(s.hasSuffix("+2"), s)
        XCTAssertFalse(s.contains("Goose"), s)
    }

    func testEmptyGroupHasNoSummary() {
        XCTAssertEqual(TrayFold.summary([]), "")
    }

    /// The heading read "No project 2 Pi · Amp" — two names and a 2.
    func testTheCountGoesWhenTheNamesAlreadyGiveIt() {
        XCTAssertTrue(TrayFold.summaryNamesEveryRow([row(.pi), row(.amp)]))
    }

    /// Three sessions of one agent summarise to one name, so the count is
    /// still the only thing saying how many.
    func testTheCountStaysWhenNamesCollapse() {
        XCTAssertFalse(TrayFold.summaryNamesEveryRow([row(.claude), row(.claude), row(.claude)]))
    }

    /// Past the summary's own limit the names are already truncated.
    func testTheCountStaysWhenTheSummaryIsTruncated() {
        let rows = [row(.claude), row(.cursor), row(.amp), row(.aider)]
        XCTAssertFalse(TrayFold.summaryNamesEveryRow(rows))
    }
}

/// Snooze is the answer a wait never had: not now, not never, later.
///
/// The rules that matter are about what snoozing does *not* do — it must not
/// remove the row, and it must not swallow the reminder permanently.
final class SnoozeTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    private func waitingRow(key: String = "k") -> AgentRow {
        var r = AgentRow(rowKey: key, agent: .claude)
        r.waiting = true
        r.waitSinceMs = now - 60_000
        r.processCount = 1
        return r
    }

    func testASnoozedRowIsStillAWaitingRow() {
        var r = waitingRow()
        r.snoozeRemainingSeconds = 300
        XCTAssertTrue(r.isSnoozed)
        XCTAssertTrue(r.waiting, "snoozing suppresses the interruption, not the fact")
        XCTAssertEqual(r.section, .needsYou, "the row keeps its place in the list")
        XCTAssertTrue(r.needsStatusChip)
    }

    func testOnlyWaitingRowsCanBeSnoozed() {
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.snoozeRemainingSeconds = 300
        XCTAssertFalse(r.isSnoozed, "a running row has no interruption to defer")
    }

    func testAnExpiredSnoozeIsNoSnooze() {
        var r = waitingRow()
        r.snoozeRemainingSeconds = 0
        XCTAssertFalse(r.isSnoozed)
    }
}

/// The stall threshold used to be compiled in at twenty minutes.
final class StallThresholdTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    private func stalled(agoSeconds: Double, threshold: Double) -> Bool {
        AgentRow.stalled(
            harvestMs: now - Int64(agoSeconds * 1000),
            nowMs: now,
            waiting: false,
            live: true,
            threshold: threshold
        )
    }

    func testAShorterThresholdCatchesAShorterSilence() {
        XCTAssertTrue(stalled(agoSeconds: 6 * 60, threshold: 5 * 60))
        XCTAssertFalse(stalled(agoSeconds: 6 * 60, threshold: 20 * 60))
    }

    /// "Never" must read as never stalled, not as always stalled.
    func testZeroDisablesRatherThanTripping() {
        XCTAssertFalse(stalled(agoSeconds: 10 * 60 * 60, threshold: 0))
        XCTAssertFalse(stalled(agoSeconds: 10 * 60 * 60, threshold: -1))
    }

    func testTheDefaultIsUnchanged() {
        XCTAssertEqual(AgentRow.stalledSeconds, 20 * 60)
        XCTAssertTrue(stalled(agoSeconds: 21 * 60, threshold: AgentRow.stalledSeconds))
    }
}

/// Project grouping was the one mode where nothing ever folded.
final class ProjectFoldTests: XCTestCase {
    func testAQuietProjectFolds() {
        XCTAssertTrue(
            TrayFold.foldableProject(hasWaiting: false, groupCount: 3, rowCount: 2, totalRows: 6)
        )
    }

    func testAProjectHoldingAWaitNeverFolds() {
        XCTAssertFalse(
            TrayFold.foldableProject(hasWaiting: true, groupCount: 3, rowCount: 4, totalRows: 9),
            "folding away the thing that needs you defeats the product"
        )
    }

    /// Same two guards Recent already had.
    func testTheOnlyProjectIsNotFolded() {
        XCTAssertFalse(
            TrayFold.foldableProject(hasWaiting: false, groupCount: 1, rowCount: 5, totalRows: 9)
        )
    }

    func testASingleRowProjectIsNotFolded() {
        XCTAssertFalse(
            TrayFold.foldableProject(hasWaiting: false, groupCount: 4, rowCount: 1, totalRows: 9)
        )
    }
}

/// A running row said the same two things at minute one and minute forty.
///
/// `tool` is the only live fact the harvest collects, and it only ever
/// appeared behind a hover or an expand.
final class LiveToolTests: XCTestCase {
    @MainActor
    private func store() -> StatusStore { StatusStore() }

    private func row(tool: String, task: String, live: Bool, waiting: Bool = false) -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.tool = tool
        r.task = task
        r.liveProcess = live
        r.processCount = live ? 1 : 0
        r.waiting = waiting
        return r
    }

    @MainActor
    func testALiveRowShowsWhatItIsRunning() {
        XCTAssertEqual(store().liveTool(row(tool: "Bash", task: "Fix the parser", live: true)), "Bash")
    }

    /// On a finished session the last tool is history, not status.
    @MainActor
    func testAFinishedRowDoesNotClaimToBeRunningATool() {
        XCTAssertNil(store().liveTool(row(tool: "Bash", task: "Fix the parser", live: false)))
    }

    /// Waiting rows already spend their third line on the actual question.
    @MainActor
    func testAWaitingRowKeepsItsQuestionInstead() {
        XCTAssertNil(store().liveTool(row(tool: "Bash", task: "x", live: true, waiting: true)))
    }

    /// With no task the tool is promoted to the title, so repeating it on the
    /// line below would be the same word twice.
    @MainActor
    func testTheToolIsNotSaidTwiceWhenItIsAlreadyTheTitle() {
        let r = row(tool: "Bash", task: "", live: true)
        XCTAssertEqual(r.sessionDetail, "Bash", "the tool is the hero here")
        XCTAssertNil(store().liveTool(r))
    }
}

/// The row keeps useful session evidence visible without a disclosure. Last
/// activity and the latest tool are covered above.
final class RowMetricsTests: XCTestCase {
    @MainActor
    private func store() -> StatusStore { StatusStore() }

    private func row(
        inTok: Int = 0, outTok: Int = 0, subRunning: Int = 0, subTotal: Int = 0,
        waiting: Bool = false, records: Int = 0, startedAgo: Double = 0
    ) -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.tokensIn = inTok
        r.tokensOut = outTok
        r.subRunning = subRunning
        r.subTotal = subTotal
        r.waiting = waiting
        r.records = records
        if startedAgo > 0 {
            r.startedMs = Int64((Date().timeIntervalSince1970 - startedAgo) * 1000)
        }
        return r
    }

    @MainActor
    func testTokenSnapshotIsVisibleByDefault() {
        let line = store().rowMetrics(row(inTok: 12_000, outTok: 3_000))
        XCTAssertTrue(line.contains("Latest model call"), line)
        XCTAssertTrue(line.contains("12k input"), line)
        XCTAssertTrue(line.contains("3.0k output"), line)
    }

    @MainActor
    func testSubagentProgressIsVisibleByDefault() {
        XCTAssertTrue(store().rowMetrics(row(subRunning: 2, subTotal: 5)).contains("2"))
    }

    @MainActor
    func testProcessOnlyRowReportsHonestProcessAge() {
        var r = AgentRow(rowKey: "amp", agent: .amp)
        r.liveProcess = true
        r.processStartedMs = Int64((Date().timeIntervalSince1970 - 3_600) * 1000)
        let line = store().rowMetrics(r)
        XCTAssertTrue(line.contains("Process started"), line)
        XCTAssertTrue(line.contains("1h"), line)
    }

    @MainActor
    func testRecordCountIsVisibleByDefault() {
        XCTAssertTrue(store().rowMetrics(row(records: 34)).contains("34"))
    }

    /// On a waiting row the question is the point; numbers beside it are noise
    /// competing with the one thing that needs an answer.
    ///
    /// 0.28.0 asserted this with a row that carried *only* tokens, and tokens
    /// were the only metric actually suppressed — age, records and sub-agent
    /// progress went on appearing. A test that can only see the one case that
    /// works is how the gap survived a release, so this row carries all four.
    @MainActor
    func testAWaitingRowSpendsItsSpaceOnTheQuestion() {
        let loaded = row(
            inTok: 12_000, outTok: 3_000, subRunning: 2, subTotal: 5,
            waiting: true, records: 34, startedAgo: 3 * 3600
        )
        XCTAssertEqual(store().rowMetrics(loaded), "", "a waiting row carries no metrics at all")
        XCTAssertEqual(store().rowObservationLine(loaded), "", "a waiting row carries no telemetry line")
    }

    /// The same row, not waiting, keeps stable model context separate from one
    /// strongest progress fact. Session age shares the context line instead of
    /// creating another row.
    @MainActor
    func testTheSameRowNotWaitingPrioritisesOneProgressFact() {
        var loaded = row(
            inTok: 12_000, outTok: 3_000, subRunning: 2, subTotal: 5,
            records: 34, startedAgo: 3 * 3600
        )
        loaded.task = "Refactor observability"
        let metrics = store().rowMetrics(loaded)
        let observation = store().rowObservationLine(loaded)
        let context = store().rowContextLine(loaded)
        XCTAssertTrue(metrics.contains("2 of 5"), metrics)
        XCTAssertEqual(observation, "")
        XCTAssertTrue(context.contains("3h"), context)
        XCTAssertFalse(metrics.contains("12k"), metrics)
        XCTAssertFalse(metrics.contains("34"), metrics)
    }

    /// Nothing to say means no text, not a placeholder.
    @MainActor
    func testARowWithNoNumbersShowsNothing() {
        XCTAssertEqual(store().rowMetrics(row()), "")
        XCTAssertEqual(store().rowObservationLine(row()), "")
    }

    func testTokenLineIsSuppressedWhileWaiting() {
        XCTAssertNil(row(inTok: 5_000, waiting: true).tokenLine)
        XCTAssertNotNil(row(inTok: 5_000).tokenLine)
    }

    func testIdentityDoesNotRepeatAgentOrUseAnUnlabelledMultiplier() {
        var r = AgentRow(rowKey: "cursor", agent: .cursor)
        r.project = "Cursor"
        r.processCount = 2
        XCTAssertEqual(r.titleLine, "Cursor")
        XCTAssertFalse(r.titleLine.contains("×"))
    }

    @MainActor
    func testRawToolIdentifierReadsAsALastAction() {
        var r = row()
        r.task = "Improve observability"
        r.tool = "update_plan"
        r.liveProcess = true
        let line = store().rowContextLine(r)
        XCTAssertTrue(line.contains("Last action: Planning"), line)
        XCTAssertFalse(line.contains("update_plan"), line)
    }

    @MainActor
    func testGenericCommandIsNotPromotedAsObservability() {
        var r = row()
        r.task = "Improve observability"
        r.tool = "run_terminal_command"
        r.liveProcess = true
        let line = store().rowContextLine(r)
        XCTAssertFalse(line.contains("Last action"), line)
        XCTAssertFalse(line.localizedCaseInsensitiveContains("command"), line)
    }

    @MainActor
    func testStructuredPhaseBeatsRawToolAndRichFactsStayVisible() {
        var r = row()
        r.task = "Fix multipart upload"
        r.tool = "run_terminal_command"
        r.phase = "turn_complete"
        r.model = "grok-4.5"
        r.mode = "grok-build-plan"
        r.errors = 1
        r.contextPercent = 27
        r.liveProcess = true

        let context = store().rowContextLine(r)
        XCTAssertFalse(context.localizedCaseInsensitiveContains("command"), context)
        let lifecycle = store().rowNowLine(r)
        XCTAssertTrue(lifecycle.contains("Outcome"), lifecycle)
        XCTAssertTrue(lifecycle.contains("Turn complete"), lifecycle)
        XCTAssertFalse(lifecycle.contains("Now"), lifecycle)

        let observation = store().rowObservationLine(r)
        XCTAssertTrue(observation.contains("Build Plan"), observation)
        XCTAssertTrue(observation.contains("Model grok 4.5"), observation)
        XCTAssertTrue(store().rowMetrics(r).contains("1 failure"))

        r.errors = 0
        XCTAssertTrue(store().rowMetrics(r).contains("Context 27%"))
    }

    @MainActor
    func testProcessOnlyAppStatesTheVisibilityLimit() {
        var r = row()
        r.liveProcess = true
        r.processCount = 3
        let line = store().rowContextLine(r)
        XCTAssertTrue(line.localizedCaseInsensitiveContains("activity feed unavailable"), line)
        XCTAssertFalse(line.contains("3"), line)
        XCTAssertFalse(line.localizedCaseInsensitiveContains("process"), line)
        XCTAssertFalse(line.localizedCaseInsensitiveContains("agent app running"), line)
    }

    @MainActor
    func testProcessOnlyTerminalStatesItsActionableEvidence() {
        var r = row()
        r.liveProcess = true
        r.processCount = 1
        r.focusTier = .warp
        let line = store().rowContextLine(r)
        XCTAssertTrue(line.localizedCaseInsensitiveContains("activity feed unavailable"), line)
        XCTAssertFalse(line.localizedCaseInsensitiveContains("terminal session running"), line)
    }
}

/// The two facts every file-backed agent can answer, and none were answering.
///
/// Measured before building this: of 32 harvesters, 5 produced tokens and 5
/// produced a tool name. Twenty-six produced nothing that changes while work
/// happens, so their rows could only ever say a title and a path — both fixed
/// for the session's whole life.
final class SessionAgeTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    private func row(startedAgo: Double) -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.startedMs = now - Int64(startedAgo * 1000)
        return r
    }

    func testASessionKnowsHowLongItHasBeenGoing() {
        XCTAssertEqual(row(startedAgo: 3 * 3600).sessionAgeSeconds(nowMs: now), 10_800, accuracy: 1)
    }

    /// Distinct from "last moved": a session can be three hours old and have
    /// touched something a minute ago. The panel only ever had the minute.
    ///
    /// The two facts read different clocks — `lastActivitySeconds` is a
    /// computed property against `Date()`, `sessionAgeSeconds` takes the scan's
    /// injected `nowMs` — so the row has to be built against both. The first
    /// version of this test stamped `harvestMs` from the fixed 2023 constant
    /// and asserted it was a minute old, which against the wall clock is three
    /// years. Same shape as the 0.25 `isStalled` bug: a fixed test clock next
    /// to a function that reaches for the real one.
    func testAgeIsNotLastActivity() {
        let wallNow = Int64(Date().timeIntervalSince1970 * 1000)
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.harvestMs = wallNow - 60_000
        r.startedMs = wallNow - Int64(3 * 3600 * 1000)
        XCTAssertEqual(r.lastActivitySeconds, 60, accuracy: 5)
        XCTAssertEqual(r.sessionAgeSeconds(nowMs: wallNow), 10_800, accuracy: 5)
        XCTAssertGreaterThan(
            r.sessionAgeSeconds(nowMs: wallNow),
            r.lastActivitySeconds,
            "a long session that just moved must still read as long"
        )
    }

    /// No start stamp is unknown, and unknown is 0 — never a guess.
    func testUnknownStartIsZero() {
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.startedMs = 0
        XCTAssertEqual(r.sessionAgeSeconds(nowMs: now), 0)
    }

    /// A clock that disagrees with the file system must not produce a negative
    /// age that formats as a time in the future.
    func testAStartInTheFutureIsNotNegativeAge() {
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.startedMs = now + 60_000
        XCTAssertEqual(r.sessionAgeSeconds(nowMs: now), 0)
    }

    func testRecordsDefaultToUnknown() {
        XCTAssertEqual(AgentRow(rowKey: "k", agent: .claude).records, 0)
    }
}

/// The wire format grew two columns; an older bundled script must still parse.
final class HarvestWireFormatTests: XCTestCase {
    private func line(_ cols: [String]) -> String { cols.joined(separator: "\t") }

    func testTheNewColumnsAreRead() {
        let rows = ActivityHarvest.parse(line([
            "claude", "Fix the parser", "12000", "3000", "Bash", "", "Pulse", "/tmp/p",
            "1700000000000", "0", "0", "sess-1", "34", "1699999000000",
        ]) + "\n")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.records, 34)
        XCTAssertEqual(rows.first?.startedMs, 1_699_999_000_000)
    }

    /// A DMG whose bundled script predates 0.28 emits twelve columns. That has
    /// to keep working and read as "unknown", not as a parse failure.
    func testATwelveColumnLineStillParses() {
        let rows = ActivityHarvest.parse(line([
            "claude", "Fix the parser", "12000", "3000", "Bash", "", "Pulse", "/tmp/p",
            "1700000000000", "0", "0", "sess-1",
        ]) + "\n")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.task, "Fix the parser")
        XCTAssertEqual(rows.first?.records, 0)
        XCTAssertEqual(rows.first?.startedMs, 0)
    }

    func testGarbageInTheNewColumnsIsUnknownNotACrash() {
        let rows = ActivityHarvest.parse(line([
            "claude", "t", "0", "0", "", "", "", "", "0", "0", "0", "s", "abc", "xyz",
        ]) + "\n")
        XCTAssertEqual(rows.first?.records, 0)
        XCTAssertEqual(rows.first?.startedMs, 0)
    }
}

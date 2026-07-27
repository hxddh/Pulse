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
        XCTAssertTrue(TrayFold.foldable(section: .recent, groupCount: 2, rowCount: 3))
    }

    /// Folding the only group leaves a panel that says nothing.
    func testRecentDoesNotFoldWhenItIsAllThereIs() {
        XCTAssertFalse(TrayFold.foldable(section: .recent, groupCount: 1, rowCount: 5))
    }

    /// One row under a heading is already one line; folding it saves nothing
    /// and costs a click.
    func testASingleRowIsNotWorthFolding() {
        XCTAssertFalse(TrayFold.foldable(section: .recent, groupCount: 3, rowCount: 1))
    }

    /// Needs-you and Running are why the panel is open. They never fold.
    func testActionableSectionsNeverFold() {
        for section in [TraySection.needsYou, .running] {
            XCTAssertFalse(
                TrayFold.foldable(section: section, groupCount: 3, rowCount: 4),
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
        XCTAssertTrue(TrayFold.foldableProject(hasWaiting: false, groupCount: 3, rowCount: 2))
    }

    func testAProjectHoldingAWaitNeverFolds() {
        XCTAssertFalse(
            TrayFold.foldableProject(hasWaiting: true, groupCount: 3, rowCount: 4),
            "folding away the thing that needs you defeats the product"
        )
    }

    /// Same two guards Recent already had.
    func testTheOnlyProjectIsNotFolded() {
        XCTAssertFalse(TrayFold.foldableProject(hasWaiting: false, groupCount: 1, rowCount: 5))
    }

    func testASingleRowProjectIsNotFolded() {
        XCTAssertFalse(TrayFold.foldableProject(hasWaiting: false, groupCount: 4, rowCount: 1))
    }
}

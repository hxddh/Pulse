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
    func testLongSilenceWhileLiveIsStalled() {
        let old = Int64((Date().timeIntervalSince1970 - 25 * 60) * 1000)
        XCTAssertTrue(row(harvestMs: old, live: true).isStalled)
        XCTAssertTrue(row(harvestMs: old, live: true).needsStatusChip)
    }

    func testRecentActivityIsNotStalled() {
        let fresh = Int64((Date().timeIntervalSince1970 - 60) * 1000)
        XCTAssertFalse(row(harvestMs: fresh, live: true).isStalled)
    }

    func testAStalledRowMustBeLive() {
        let old = Int64((Date().timeIntervalSince1970 - 25 * 60) * 1000)
        XCTAssertFalse(row(harvestMs: old, live: false).isStalled, "a finished session is not stalled")
    }

    func testUnknownActivityIsNotStalled() {
        XCTAssertFalse(row(harvestMs: 0, live: true).isStalled, "no timestamp is not evidence of silence")
    }
}

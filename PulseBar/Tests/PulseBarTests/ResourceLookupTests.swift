import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

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

/// Screenshots of 0.24.0 showed one fact stated three and four times over.
final class RowRedundancyTests: XCTestCase {
    private func row(agent: AgentID, task: String = "", project: String = "") -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: agent)
        r.task = task
        r.project = project
        r.liveProcess = true
        r.state = .running
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
        var r = row(agent: .amp)
        r.state = .processOnly
        XCTAssertNil(r.usefulTask)
        // Hero must not fall back to the agent product name (already on identity).
        let hero = Explain.make(r, lang: .en, nowMs: 1_700_000_000_000).headline
        XCTAssertNotEqual(hero, r.agent.displayName)
    }

    func testEveryAgentDropsItsOwnGenericSessionPlaceholder() {
        for agent in AgentID.allCases {
            var r = row(agent: agent, task: "\(agent.displayName) session")
            r.sessionID = "real-id"
            XCTAssertNil(r.usefulTask, "\(agent.displayName) placeholder escaped as a task")
        }
    }

    func testEveryAgentDropsItsOwnBareDisplayName() {
        for agent in AgentID.allCases {
            var r = row(agent: agent, task: agent.displayName)
            r.sessionID = "real-id"
            XCTAssertNil(r.usefulTask, "\(agent.displayName) alone is identity, not a goal")
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
        XCTAssertEqual(row().lastActivitySeconds(at: 1_700_000_000_000), 0)
    }

    func testActivityAgeCountsFromTheHarvestStamp() {
        let now: Int64 = 1_700_000_000_000
        XCTAssertEqual(row(harvestMs: now - 600_000).lastActivitySeconds(at: now), 600, accuracy: 0.001)
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
        r.state = live ? .running : .recent
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

    private func stalled(agoSeconds: Double) -> Bool {
        AgentRow.stalled(lastActivityMs: now - Int64(agoSeconds * 1000), nowMs: now)
    }

    func testLongSilenceWhileLiveIsStalled() {
        XCTAssertTrue(stalled(agoSeconds: 25 * 60))
    }

    func testRecentActivityIsNotStalled() {
        XCTAssertFalse(stalled(agoSeconds: 60))
    }

    func testUnknownActivityIsNotStalled() {
        XCTAssertFalse(
            AgentRow.stalled(lastActivityMs: 0, nowMs: now),
            "no timestamp is not evidence of silence"
        )
    }

    /// A stalled row is one the user should react to: an orange ring, and
    /// its why on a second line (23.0 — no badge).
    func testStalledRowsSayWhy() {
        var r = row(harvestMs: now - 25 * 60 * 1000, live: true)
        r.isStalled = true
        let face = TrayRowModel.make(TrayRowModel.Input(row: r, lang: .en, nowMs: now))
        XCTAssertEqual(face.lamp, LampFace(shape: .ring, tone: .attention))
        XCTAssertEqual(face.secondLine?.kind, .warning)
        XCTAssertEqual(face.secondLine?.text, face.why)
    }
}

/// The stall threshold used to be compiled in at twenty minutes.
final class StallThresholdTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    private func stalled(agoSeconds: Double, threshold: Double) -> Bool {
        AgentRow.stalled(lastActivityMs: now - Int64(agoSeconds * 1000), nowMs: now, threshold: threshold)
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

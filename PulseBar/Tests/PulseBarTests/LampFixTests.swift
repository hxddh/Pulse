import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 22.x · Lamp fixes — each pins one defect with the pure function that
/// decides it.
@Suite("Lamp fixes")
struct LampFixTests {

    // MARK: - Background update checks keep a known answer

    private static let release = UpdateCheck.ReleaseInfo(
        version: "99.0.0",
        pageURL: "https://example.invalid/r"
    )

    @Test func aBackgroundFailureKeepsAnAvailableUpdate() {
        let previous = UpdateCheck.Status.available(Self.release)
        let next = UpdateCheck.resolve(previous: previous, result: .failed(.network("offline")), manual: false)
        #expect(next == previous)
    }

    @Test func aBackgroundFailureKeepsUpToDate() {
        let next = UpdateCheck.resolve(previous: .current, result: .failed(.http(503)), manual: false)
        #expect(next == .current)
    }

    @Test func aManualFailureIsShown() {
        let next = UpdateCheck.resolve(previous: .current, result: .failed(.http(503)), manual: true)
        #expect(next == .failed(.http(503)))
    }

    @Test func aBackgroundAnswerStillReplacesTheStatus() {
        let next = UpdateCheck.resolve(previous: .current, result: .available(Self.release), manual: false)
        #expect(next == .available(Self.release))
    }

    // MARK: - "Don't suggest hooks" persists

    @Test func hooksNudgeOffRoundTrips() throws {
        var settings = PulseSettings()
        settings.hooksNudgeOff = true
        let data = try JSONEncoder().encode(settings)
        let reparsed = try JSONDecoder().decode(PulseSettings.self, from: data)
        #expect(reparsed.hooksNudgeOff)
        let absent = try JSONDecoder().decode(PulseSettings.self, from: Data("{}".utf8))
        #expect(!absent.hooksNudgeOff)
    }

    @MainActor
    @Test func anUninstalledChoiceSilencesTheHooksNudge() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.notifyAuthorized = true
        #expect(store.needsHooksNudge)
        store.settings.hooksNudgeOff = true
        #expect(!store.needsHooksNudge)
    }

    // MARK: - Codex hooks.json counts as installed

    @Test func codexHooksJSONAloneCountsAsInstalled() {
        let hooks = #"{"hooks":{"Stop":[{"hooks":[{"command":"/x/pulse-hook --agent codex"}]}]}}"#
        #expect(HooksSupport.codexHooked(configTOML: nil, hooksJSON: hooks))
        #expect(HooksSupport.codexHooked(configTOML: "notify = [\"/x/pulse-hook\"]", hooksJSON: nil))
        #expect(!HooksSupport.codexHooked(configTOML: "model = \"o3\"", hooksJSON: "{}"))
    }

    // MARK: - The health line reads the last scan, not the last publish

    @Test func lastReadPrefersTheNewerScan() {
        let published = Date(timeIntervalSince1970: 1_000)
        let scanned = Date(timeIntervalSince1970: 1_050)
        #expect(StatusStore.lastReadDate(lastScanAt: scanned, snapshotUpdatedAt: published) == scanned)
        #expect(StatusStore.lastReadDate(lastScanAt: nil, snapshotUpdatedAt: published) == published)
        #expect(StatusStore.lastReadDate(lastScanAt: nil, snapshotUpdatedAt: .distantPast) == nil)
        #expect(StatusStore.lastReadDate(lastScanAt: scanned, snapshotUpdatedAt: .distantPast) == scanned)
    }
}

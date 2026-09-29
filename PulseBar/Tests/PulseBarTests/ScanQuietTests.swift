import Foundation
import Observation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 12.4 Surface — a scan that found the same world wakes no surface.
///
/// 19.0: the store is `@Observable`. A view is invalidated by the properties
/// its body read, and Observation announces every assignment, equal or not.
/// This is the counter wall: track every observed property of the store,
/// apply the same scan twice, and nothing may fire. When it fails, it names
/// the property that did.
@Suite("Scan quiet", .serialized)
@MainActor
struct ScanQuietTests {
    /// Written only from the main actor: Observation calls `onChange`
    /// synchronously on the writing thread, and every write here is a
    /// main-actor store write.
    final class Fired: @unchecked Sendable {
        var names: [String] = []
    }

    /// Every property of `StatusStore` a view can be invalidated by. A new
    /// observed property belongs here; `everyObservedPropertyIsListed` fails
    /// until it is.
    static var observed: [(String, PartialKeyPath<StatusStore>)] {
        [
            ("allowAppData", \StatusStore.allowAppData),
            ("allowTerminalAutomation", \StatusStore.allowTerminalAutomation),
            ("appDataAgents", \StatusStore.appDataAgents),
            ("cachedAll", \StatusStore.cachedAll),
            ("collectorScanIncomplete", \StatusStore.collectorScanIncomplete),
            ("didCopyDiagnostics", \StatusStore.didCopyDiagnostics),
            ("didCopyDoctorReport", \StatusStore.didCopyDoctorReport),
            ("doctorReport", \StatusStore.doctorReport),
            ("didCopyShapeReport", \StatusStore.didCopyShapeReport),
            ("hookSelfTestResult", \StatusStore.hookSelfTestResult),
            ("hooksNudgeOff", \StatusStore.hooksNudgeOff),
            ("hooksStatus", \StatusStore.hooksStatus),
            ("hotkey", \StatusStore.hotkey),
            ("hotkeyRegistered", \StatusStore.hotkeyRegistered),
            ("isCopyingShapeReport", \StatusStore.isCopyingShapeReport),
            ("isRefreshing", \StatusStore.isRefreshing),
            ("isRunningDoctor", \StatusStore.isRunningDoctor),
            ("language", \StatusStore.language),
            ("launchAtLogin", \StatusStore.launchAtLogin),
            ("loginItemApplied", \StatusStore.loginItemApplied),
            ("logRevision", \StatusStore.logRevision),
            ("mutedAgents", \StatusStore.mutedAgents),
            ("notifyAuthorized", \StatusStore.notifyAuthorized),
            ("notifyOnIdle", \StatusStore.notifyOnIdle),
            ("notifyOnWaiting", \StatusStore.notifyOnWaiting),
            ("pendingRevealRowKey", \StatusStore.pendingRevealRowKey),
            ("previewFixtureActive", \StatusStore.previewFixtureActive),
            ("previewWaitingEventTimes", \StatusStore.previewWaitingEventTimes),
            ("rowActionNotices", \StatusStore.rowActionNotices),
            ("settingsExpandAppDataScopes", \StatusStore.settingsExpandAppDataScopes),
            ("settingsFocusAppDataAgent", \StatusStore.settingsFocusAppDataAgent),
            ("settingsFocusWaitingSignals", \StatusStore.settingsFocusWaitingSignals),
            ("settingsFocusToken", \StatusStore.settingsFocusToken),
            ("showAllAgents", \StatusStore.showAllAgents),
            ("snapshot", \StatusStore.snapshot),
            ("snapshotAgents", \StatusStore.snapshotAgents),
            ("traySessionToken", \StatusStore.traySessionToken),
            ("updateCheckEnabled", \StatusStore.updateCheckEnabled),
            ("updateStatus", \StatusStore.updateStatus),
            ("waitingBannerFailed", \StatusStore.waitingBannerFailed),
        ]
    }

    private func quietStore() -> StatusStore {
        // This test drives the scans itself.
        StatusStore()
    }

    private func scan(_ store: StatusStore, ticket: UInt64) {
        store.applyScan(procs: [], harvest: .skipped, processSignature: "", attention: [], ticket: ticket)
    }

    private func watch(_ store: StatusStore, _ properties: [(String, PartialKeyPath<StatusStore>)]) -> Fired {
        let fired = Fired()
        for (name, keyPath) in properties {
            withObservationTracking {
                _ = store[keyPath: keyPath]
            } onChange: {
                fired.names.append(name)
            }
        }
        return fired
    }

    @Test func aSecondIdenticalScanAnnouncesNothing() {
        let store = quietStore()
        scan(store, ticket: 1)
        let fired = watch(store, Self.observed)

        scan(store, ticket: 2)
        scan(store, ticket: 3)

        #expect(fired.names == [], "observed properties written by an unchanged scan: \(fired.names)")
    }

    /// 23.0: a wait that crossed while macOS had not yet allowed Pulse to
    /// notify is owed a banner once. The ledger used to be rewritten on every
    /// scan after that for as long as authorization stayed unresolved; the
    /// session log changes (and `logRevision` moves) only when the wait did.
    @Test func anOwedBannerWhileUnauthorizedIsRecordedOnce() {
        let store = quietStore()
        store.notifyAuthorized = nil
        scan(store, ticket: 1)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let raised = AttentionReader.Entry(
            id: .claude, kind: "Permission", message: "Bash: npm test",
            tsMs: nowMs - 1_000, session: "s-owed", cwd: "/w/app"
        )
        store.applyScan(procs: [], harvest: .skipped, processSignature: "", attention: [raised], ticket: 2)
        let owed = store.sessionLog.queuedKeys
        #expect(owed.count == 1, "the edge is owed its banner")
        let fired = watch(store, [("logRevision", \StatusStore.logRevision)])
        store.applyScan(procs: [], harvest: .skipped, processSignature: "", attention: [raised], ticket: 3)
        store.applyScan(procs: [], harvest: .skipped, processSignature: "", attention: [raised], ticket: 4)
        #expect(fired.names == [], "the same owed wait is not news")
    }

    @Test func aChangedWorldIsStillAnnounced() {
        let store = quietStore()
        scan(store, ticket: 1)
        let fired = watch(store, Self.observed)
        var next = store.snapshot
        next.header = "1 running"
        store.snapshot = next
        #expect(fired.names == ["snapshot"], "only what changed, and nothing else: \(fired.names)")
    }

    /// The generated source of `@Observable` lists the tracked properties;
    /// this reads the class's own stored properties and fails on one that is
    /// observed but missing from `observed`, so the wall above cannot go
    /// quietly partial.
    @Test func everyObservedPropertyIsListed() throws {
        let listed = Set(Self.observed.map(\.0))
        let stored = Mirror(reflecting: quietStore()).children.compactMap(\.label)
        // `@Observable` stores a tracked property as `_name`; an ignored one
        // keeps its own name.
        let tracked = Set(stored.filter { $0.hasPrefix("_") && $0 != "_$observationRegistrar" }.map { String($0.dropFirst()) })
        #expect(tracked.subtracting(listed).sorted() == [], "observed but not in the quiet wall")
        #expect(listed.subtracting(tracked).sorted() == [], "listed but no longer observed")
    }

    // MARK: - Settings (formerly StoreObservation)

    /// Settings reads `snapshotAgents`, not `snapshot`: a scan that only
    /// moved a row does not redraw the form; a new agent does.
    @Test func settingsIsNotWokenByAScanThatOnlyMovedARow() {
        let store = quietStore()
        var snap = PulseSnapshot()
        snap.rows = [AgentRow(rowKey: "claude|s1", agent: .claude)]
        store.snapshot = snap
        let fired = watch(store, [("snapshotAgents", \StatusStore.snapshotAgents), ("notifyOnIdle", \StatusStore.notifyOnIdle)])

        snap.rows[0].task = "moved"
        store.snapshot = snap
        #expect(fired.names == [])

        snap.rows.append(AgentRow(rowKey: "codex|s2", agent: .codex))
        store.snapshot = snap
        #expect(fired.names == ["snapshotAgents"])
    }

    // MARK: - The status item

    @Test func theStatusItemLoopFollowsTheSnapshotOnly() async {
        let store = quietStore()
        let loop = ObservationLoop(track: { _ = store.snapshot }, onChange: {})
        defer { loop.cancel() }

        store.notifyOnIdle.toggle()
        store.showAllAgents.toggle()
        for _ in 0..<10 { await Task.yield() }
        #expect(loop.deliveries == 0, "a settings write does not touch the lamp")

        var next = store.snapshot
        next.header = "2 running"
        store.snapshot = next
        next.header = "3 running"
        store.snapshot = next
        for _ in 0..<10 where loop.deliveries == 0 { await Task.yield() }
        #expect(loop.deliveries == 1, "a burst in one turn is one delivery")

        next.header = "4 running"
        store.snapshot = next
        for _ in 0..<10 where loop.deliveries == 1 { await Task.yield() }
        #expect(loop.deliveries == 2, "and the loop re-arms")
    }

    // MARK: - The publish decision (unchanged since 12.4)

    @Test func aChangedWorldStillPublishes() {
        var current = PulseSnapshot()
        current.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var next = current
        next.updatedAt = current.updatedAt.addingTimeInterval(2)
        #expect(!PulseSnapshot.needsPublish(next: next, current: current), "same world, two seconds later")

        next.header = "1 running"
        #expect(PulseSnapshot.needsPublish(next: next, current: current), "content moved")
    }

    @Test func theFirstScanAlwaysLands() {
        var next = PulseSnapshot()
        next.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PulseSnapshot.needsPublish(next: next, current: PulseSnapshot()))
    }

    @Test func relativeTimeLabelsStillMove() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var current = PulseSnapshot()
        current.updatedAt = t0
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.waiting = true
        row.waitSinceMs = Int64(t0.timeIntervalSince1970 * 1000) - 20_000
        current.rows = [row]

        var next = current
        next.updatedAt = t0.addingTimeInterval(2)
        #expect(PulseSnapshot.needsPublish(next: next, current: current), "a 20 s wait is drawn in seconds — it moves every scan")

        current.rows[0].waitSinceMs = Int64(t0.timeIntervalSince1970 * 1000) - 600_000
        next.rows = current.rows
        #expect(!PulseSnapshot.needsPublish(next: next, current: current), "a ten-minute wait holds for a minute")
        next.updatedAt = t0.addingTimeInterval(61)
        #expect(PulseSnapshot.needsPublish(next: next, current: current), "and moves once the minute turns")
    }
}

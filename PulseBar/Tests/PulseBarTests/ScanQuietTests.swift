import Combine
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseManaged
@testable import PulseRespond

/// 12.4 Surface — a scan that found the same world wakes no surface.
///
/// The tray, the Workbench, the session cards and the detail window all
/// observe the store; `@Published` announces every assignment, equal or not.
/// This is the counter wall: apply a scan, apply the same scan again, and the
/// second one must not announce anything. When it fails, it names the
/// property that did.
@MainActor
final class ScanQuietTests: XCTestCase {
    private var bag: Set<AnyCancellable> = []
    private var fired: [String] = []

    override func tearDown() {
        bag.removeAll()
        fired.removeAll()
        super.tearDown()
    }

    private func watch<P: Publisher>(_ publisher: P, _ name: String) where P.Failure == Never {
        publisher.dropFirst().sink { [weak self] _ in self?.fired.append(name) }.store(in: &bag)
    }

    private func quietStore() -> StatusStore {
        let store = StatusStore()
        // No probe timer: this test drives the scans itself.
        store.autoProbe = false
        return store
    }

    private func scan(_ store: StatusStore, ticket: UInt64) {
        store.applyScan(procs: [], harvest: .skipped, processSignature: "", attention: [], ticket: ticket)
    }

    func testASecondIdenticalScanAnnouncesNothing() {
        let store = quietStore()
        scan(store, ticket: 1)

        var announcements = 0
        store.objectWillChange.sink { _ in announcements += 1 }.store(in: &bag)
        watch(store.$allowAppData, "allowAppData")
        watch(store.$allowTerminalAutomation, "allowTerminalAutomation")
        watch(store.$allowWorkbenchActuation, "allowWorkbenchActuation")
        watch(store.$appDataAgents, "appDataAgents")
        watch(store.$autoProbe, "autoProbe")
        watch(store.$broadcastFleet, "broadcastFleet")
        watch(store.$collectorScanIncomplete, "collectorScanIncomplete")
        watch(store.$didCopyAttentionRaise, "didCopyAttentionRaise")
        watch(store.$didCopyDiagnostics, "didCopyDiagnostics")
        watch(store.$didCopyShapeReport, "didCopyShapeReport")
        watch(store.$hookSelfTestResult, "hookSelfTestResult")
        watch(store.$hooksStatus, "hooksStatus")
        watch(store.$hotkey, "hotkey")
        watch(store.$hotkeyEnabled, "hotkeyEnabled")
        watch(store.$hotkeyRegistered, "hotkeyRegistered")
        watch(store.$installReport, "installReport")
        watch(store.$isCopyingShapeReport, "isCopyingShapeReport")
        watch(store.$isRefreshing, "isRefreshing")
        watch(store.$language, "language")
        watch(store.$launchAtLogin, "launchAtLogin")
        watch(store.$loginItemApplied, "loginItemApplied")
        watch(store.$lookContinuityItems, "lookContinuityItems")
        watch(store.$lookContinuityNotice, "lookContinuityNotice")
        watch(store.$lookMovedRowKeys, "lookMovedRowKeys")
        watch(store.$lookMovedWhileAway, "lookMovedWhileAway")
        watch(store.$lookNewWaitsWhileAway, "lookNewWaitsWhileAway")
        watch(store.$measureWorkspaceEffect, "measureWorkspaceEffect")
        watch(store.$missedWhileAway, "missedWhileAway")
        watch(store.$mutedAgents, "mutedAgents")
        watch(store.$notifyAuthorized, "notifyAuthorized")
        watch(store.$notifyOnIdle, "notifyOnIdle")
        watch(store.$notifyOnWaiting, "notifyOnWaiting")
        watch(store.$playSoundOnWaiting, "playSoundOnWaiting")
        watch(store.$pulseHookLauncherReady, "pulseHookLauncherReady")
        watch(store.$quietEndMinute, "quietEndMinute")
        watch(store.$quietHoursEnabled, "quietHoursEnabled")
        watch(store.$quietStartMinute, "quietStartMinute")
        watch(store.$recoveredAfterCrash, "recoveredAfterCrash")
        watch(store.$recoveryExitKind, "recoveryExitKind")
        watch(store.$respondDecided, "respondDecided")
        watch(store.$respondInboundByRowKey, "respondInboundByRowKey")
        watch(store.$respondLocalEnabled, "respondLocalEnabled")
        watch(store.$respondVerdictSentRowKeys, "respondVerdictSentRowKeys")
        watch(store.$rowActionNotices, "rowActionNotices")
        watch(store.$settingsExpandAppDataScopes, "settingsExpandAppDataScopes")
        watch(store.$settingsFocusAppDataAgent, "settingsFocusAppDataAgent")
        watch(store.$settingsFocusWaitingAgent, "settingsFocusWaitingAgent")
        watch(store.$settingsFocusWaitingSignals, "settingsFocusWaitingSignals")
        watch(store.$showAllAgents, "showAllAgents")
        watch(store.$snapshot, "snapshot")
        watch(store.$snoozeMinutes, "snoozeMinutes")
        watch(store.$stallMinutes, "stallMinutes")
        watch(store.$trayGrouping, "trayGrouping")
        watch(store.$traySessionToken, "traySessionToken")
        watch(store.$updateCheckEnabled, "updateCheckEnabled")
        watch(store.$updateDownloadStatus, "updateDownloadStatus")
        watch(store.$updateStatus, "updateStatus")
        watch(store.$waitHistory, "waitHistory")
        watch(store.$workbenchSelectKey, "workbenchSelectKey")

        scan(store, ticket: 2)
        scan(store, ticket: 3)

        XCTAssertEqual(fired, [], "published by an unchanged scan: \(fired)")
        XCTAssertEqual(announcements, 0, "surfaces observing the store were woken by an unchanged scan")
    }

    func testAChangedWorldStillPublishes() {
        var current = PulseSnapshot()
        current.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var next = current
        next.updatedAt = current.updatedAt.addingTimeInterval(2)
        XCTAssertFalse(PulseSnapshot.needsPublish(next: next, current: current), "same world, two seconds later")

        next.header = "1 running"
        XCTAssertTrue(PulseSnapshot.needsPublish(next: next, current: current), "content moved")
    }

    func testTheFirstScanAlwaysLands() {
        var next = PulseSnapshot()
        next.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(PulseSnapshot.needsPublish(next: next, current: PulseSnapshot()))
    }

    func testRelativeTimeLabelsStillMove() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var current = PulseSnapshot()
        current.updatedAt = t0
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.waiting = true
        row.waitSinceMs = Int64(t0.timeIntervalSince1970 * 1000) - 20_000
        current.rows = [row]

        var next = current
        next.updatedAt = t0.addingTimeInterval(2)
        XCTAssertTrue(
            PulseSnapshot.needsPublish(next: next, current: current),
            "a 20 s wait is drawn in seconds — it moves every scan"
        )

        current.rows[0].waitSinceMs = Int64(t0.timeIntervalSince1970 * 1000) - 600_000
        next.rows = current.rows
        XCTAssertFalse(PulseSnapshot.needsPublish(next: next, current: current), "a ten-minute wait holds for a minute")
        next.updatedAt = t0.addingTimeInterval(61)
        XCTAssertTrue(PulseSnapshot.needsPublish(next: next, current: current), "and moves once the minute turns")
    }
}

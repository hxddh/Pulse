import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseRespond

/// 22.0 · Lamp — what the subtraction leaves behind on a user's disk, and
/// what it must never touch.
@Suite("Legacy cleanup")
struct LegacyCleanupTests {
    private func sandbox() throws -> (pulse: URL, respond: URL) {
        let pulse = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-cleanup-\(UUID().uuidString)", isDirectory: true)
        let respond = pulse.appendingPathComponent("respond.d", isDirectory: true)
        try FileManager.default.createDirectory(at: respond, withIntermediateDirectories: true)
        return (pulse, respond)
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
    }

    @Test func removesWhatTheDeletedFeaturesWroteAndNothingElse() throws {
        let (pulse, respond) = try sandbox()
        defer { try? FileManager.default.removeItem(at: pulse) }
        let gone = [
            pulse.appendingPathComponent("evidence/abc.json"),
            pulse.appendingPathComponent("managed/permissions/requests/r.json"),
            pulse.appendingPathComponent("missions/m.json"),
            pulse.appendingPathComponent("fleet.d/devbox.json"),
            respond.appendingPathComponent("requests.d/devbox/r.json"),
            respond.appendingPathComponent("verdicts.d/devbox/r.json"),
            respond.appendingPathComponent("secrets/devbox.key"),
        ]
        let kept = [
            pulse.appendingPathComponent("respond-local.key"),
            pulse.appendingPathComponent("attention.tsv"),
            pulse.appendingPathComponent("attention-history.json"),
            pulse.appendingPathComponent("attention.d/devbox.tsv"),
            pulse.appendingPathComponent("settings.txt"),
            pulse.appendingPathComponent("worktrees/app/task/file.swift"),
            respond.appendingPathComponent("requests/r.json"),
            respond.appendingPathComponent("verdicts/r.json"),
        ]
        for url in gone + kept { try touch(url) }

        let removed = LegacyCleanup.run(pulseDirectory: pulse, respondRoot: respond)

        #expect(removed.count == 7)
        for url in gone { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.path)") }
        for url in kept { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.path)") }
    }

    @Test func runsOnce() throws {
        let (pulse, respond) = try sandbox()
        defer { try? FileManager.default.removeItem(at: pulse) }
        LegacyCleanup.run(pulseDirectory: pulse, respondRoot: respond)
        let late = pulse.appendingPathComponent("evidence/late.json")
        try touch(late)
        #expect(LegacyCleanup.run(pulseDirectory: pulse, respondRoot: respond).isEmpty)
        #expect(FileManager.default.fileExists(atPath: late.path), "the marker makes the sweep a one-off")
    }

    @Test func anOldSettingsFileStillParses() {
        let old = """
            auto=1
            terminalAutomation=1
            workbenchActuation=1
            workspaceEffect=0
            fleetBroadcast=1
            stallMin=25
            """
        let parsed = PulseSettings.parse(old)
        #expect(parsed.allowTerminalAutomation)
        #expect(parsed.stallMinutes == 25)
        let written = parsed.serialized()
        #expect(!written.contains("workbenchActuation"))
        #expect(!written.contains("workspaceEffect"))
        #expect(!written.contains("fleetBroadcast"))
    }
}

import XCTest
@testable import PulseBar

/// The 0.5.0-vs-0.21.0 drift that shipped for months was invisible because
/// nothing ever compared the two.
final class PulseVersionTests: XCTestCase {
    func testSemverIsWellFormed() {
        let parts = PulseVersion.semver.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "semver must be MAJOR.MINOR.PATCH")
        for part in parts {
            XCTAssertNotNil(Int(part), "non-numeric component in \(PulseVersion.semver)")
        }
    }

    func testUnpackagedBuildReportsDevNotAFakeRelease() {
        // Tests run without an app bundle, so this exercises the honest path.
        guard PulseVersion.bundleVersion == nil else { return }
        XCTAssertTrue(PulseVersion.short.hasSuffix("-dev"))
        XCTAssertEqual(PulseVersion.commit, "dev")
        XCTAssertTrue(PulseVersion.buildLine.isEmpty)
        XCTAssertEqual(PulseVersion.fingerprint, "Pulse \(PulseVersion.short)")
    }

    func testUpdateComparisonIsNumericNotLexicographic() {
        // "0.9.0" > "0.21.0" as strings — the exact bug this guards.
        XCTAssertTrue(UpdateCheck.isNewer("0.21.0", than: "0.9.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.9.0", than: "0.21.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertFalse(UpdateCheck.isNewer("0.21.1", than: "0.21.1"))
        XCTAssertTrue(UpdateCheck.isNewer("0.21.2", than: "0.21.1"))
    }

    func testUpdateTagNormalization() {
        XCTAssertEqual(UpdateCheck.normalize("v0.22.0"), "0.22.0")
        XCTAssertEqual(UpdateCheck.normalize(" 0.22.0 "), "0.22.0")
        XCTAssertEqual(UpdateCheck.normalize("V1.0.0"), "1.0.0")
    }

    func testPreReleaseSuffixDoesNotBeatRelease() {
        XCTAssertFalse(UpdateCheck.isNewer("0.21.1-beta.1", than: "0.21.1"))
    }

    func testInterpretRejectsGarbage() {
        let status = UpdateCheck.interpret(data: Data("not json".utf8), response: nil, error: nil)
        XCTAssertEqual(status, .failed("bad response"))
    }

    func testInterpretFindsNewerRelease() {
        let sha = String(repeating: "a", count: 64)
        let json = """
        {
          "tag_name":"v99.0.0",
          "html_url":"https://example.com/r",
          "body":"SHA-256: \(sha)",
          "assets":[{
            "name":"pulse-99.0.0.dmg",
            "browser_download_url":"https://example.com/pulse.dmg",
            "size":765
          }]
        }
        """
        let status = UpdateCheck.interpret(data: Data(json.utf8), response: nil, error: nil)
        XCTAssertEqual(
            status,
            .available(.init(
                version: "99.0.0",
                pageURL: "https://example.com/r",
                assetURL: "https://example.com/pulse.dmg",
                assetName: "pulse-99.0.0.dmg",
                assetBytes: 765,
                sha256: sha
            ))
        )
    }

    func testUpdateInstallerDestinationNeverOverwritesExistingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = directory.appendingPathComponent("pulse-0.48.0.dmg")
        FileManager.default.createFile(atPath: base.path, contents: Data("existing".utf8))
        let first = UpdateCheck.nonDestructiveDestination(base: base)
        XCTAssertEqual(first.lastPathComponent, "pulse-0.48.0 (1).dmg")
        FileManager.default.createFile(atPath: first.path, contents: Data("existing-1".utf8))
        let second = UpdateCheck.nonDestructiveDestination(base: base)
        XCTAssertEqual(second.lastPathComponent, "pulse-0.48.0 (2).dmg")
        XCTAssertEqual(try Data(contentsOf: base), Data("existing".utf8))
    }

    func testDuplicateCleanupNeverRemovesRunningOrNewerCopy() {
        let current = InstallTruth.Copy(
            url: URL(fileURLWithPath: "/Applications/Pulse.app"),
            version: "0.36.0",
            commit: "abc",
            isRunning: true,
            isCurrent: true
        )
        let old = InstallTruth.Copy(
            url: URL(fileURLWithPath: "/Applications/Pulse old.app"),
            version: "0.35.1",
            commit: "old",
            isRunning: false,
            isCurrent: false
        )
        let newer = InstallTruth.Copy(
            url: URL(fileURLWithPath: "/Applications/Pulse preview.app"),
            version: "0.37.0",
            commit: "new",
            isRunning: false,
            isCurrent: false
        )
        let runningOld = InstallTruth.Copy(
            url: URL(fileURLWithPath: "/Applications/Pulse running.app"),
            version: "0.34.0",
            commit: "run",
            isRunning: true,
            isCurrent: false
        )
        let report = InstallTruth.Report(
            runningURL: current.url,
            copies: [current, old, newer, runningOld],
            inspectedAt: Date()
        )
        XCTAssertEqual(report.removableDuplicates.map(\.version), ["0.35.1"])
        XCTAssertTrue(report.hasOtherRunningCopy)
    }

    func testHookStatusIsPerAgentNotGlobal() {
        XCTAssertTrue(HooksSupport.Status.installedBoth.isInstalled(for: .claude))
        XCTAssertTrue(HooksSupport.Status.installedBoth.isInstalled(for: .codex))
        XCTAssertTrue(HooksSupport.Status.installedClaude.isInstalled(for: .claude))
        XCTAssertFalse(HooksSupport.Status.installedClaude.isInstalled(for: .codex))
        XCTAssertFalse(HooksSupport.Status.missing.isInstalled(for: .claude))
    }
}

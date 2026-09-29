import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

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
        XCTAssertEqual(status, .failed(.badResponse))
    }

    func testInterpretFindsNewerRelease() {
        let json = """
        {
          "tag_name":"v99.0.0",
          "html_url":"https://example.com/r"
        }
        """
        let status = UpdateCheck.interpret(data: Data(json.utf8), response: nil, error: nil)
        XCTAssertEqual(
            status,
            .available(.init(version: "99.0.0", pageURL: "https://example.com/r"))
        )
    }

    func testInterpretReleasesListSkipsPrereleaseOnStableChannel() {
        let sha = String(repeating: "b", count: 64)
        let json = """
        [
          {
            "tag_name":"v99.1.0",
            "prerelease":true,
            "html_url":"https://example.com/pre",
            "body":"SHA-256: \(sha)",
            "assets":[{
              "name":"pulse-99.1.0.dmg",
              "browser_download_url":"https://example.com/pre.dmg",
              "size":100
            }]
          },
          {
            "tag_name":"v99.0.0",
            "prerelease":false,
            "html_url":"https://example.com/r",
            "body":"SHA-256: \(sha)",
            "assets":[{
              "name":"pulse-99.0.0.dmg",
              "browser_download_url":"https://example.com/pulse.dmg",
              "size":200
            }]
          }
        ]
        """
        let stable = UpdateCheck.interpret(
            data: Data(json.utf8),
            response: nil,
            error: nil,
            preferPrerelease: false
        )
        if case let .available(info) = stable {
            XCTAssertEqual(info.version, "99.0.0")
        } else {
            XCTFail("stable channel should pick the non-prerelease entry, got \(stable)")
        }

        let preview = UpdateCheck.interpret(
            data: Data(json.utf8),
            response: nil,
            error: nil,
            preferPrerelease: true
        )
        if case let .available(info) = preview {
            XCTAssertEqual(info.version, "99.1.0")
        } else {
            XCTFail("preview channel should accept the newest prerelease, got \(preview)")
        }
    }

    func testUnpackagedChannelDoesNotPreferPrerelease() {
        guard PulseVersion.bundleVersion == nil else { return }
        XCTAssertEqual(PulseVersion.distributionChannel, "dev")
        XCTAssertFalse(PulseVersion.prefersPrereleaseUpdates)
        XCTAssertFalse(PulseVersion.isNotarized)
        XCTAssertFalse(PulseVersion.isGatekeeperReady)
    }

    @MainActor
    func testUpdateCurrentCopyIsChannelRelative() {
        let store = StatusStore()
        store.language = .en
        store.updateStatus = .current
        // Copy follows the running build's channel — not a fixed string.
        // XCTest on CI often sees Bundle.main version keys, so channel may be
        // preview rather than unpackaged dev; assert the mapping, not the host.
        let expected: L10n.Key
        if PulseVersion.prefersPrereleaseUpdates {
            expected = .updateCurrentPrerelease
        } else if PulseVersion.distributionChannel == "stable" {
            expected = .updateCurrentStable
        } else {
            expected = .updateCurrent
        }
        XCTAssertEqual(store.updateStatusText, store.tr(expected))
        XCTAssertNotEqual(store.tr(.updateCurrentPrerelease), store.tr(.updateCurrentStable))
        XCTAssertNotEqual(store.tr(.updateCurrent), store.tr(.updateCurrentPrerelease))
        XCTAssertTrue(store.tr(.updateCurrentStable).localizedCaseInsensitiveContains("prerelease"))
    }

    func testHookStatusIsPerAgentNotGlobal() {
        XCTAssertTrue(HooksSupport.Status.installedBoth.isInstalled(for: .claude))
        XCTAssertTrue(HooksSupport.Status.installedBoth.isInstalled(for: .codex))
        XCTAssertTrue(HooksSupport.Status.installedClaude.isInstalled(for: .claude))
        XCTAssertFalse(HooksSupport.Status.installedClaude.isInstalled(for: .codex))
        XCTAssertFalse(HooksSupport.Status.missing.isInstalled(for: .claude))
    }
}

import CryptoKit
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseRespond

/// First coverage for UpdateInstaller. The mount-point parser earned it: the
/// old implementation matched a whole-line `/Volumes/` prefix against output
/// whose lines start with `/dev/disk…`, so the in-app download-and-verify
/// flow failed at "mount point" on every machine, and no test could say so.
final class UpdateInstallerTests: XCTestCase {

    func testMountPointIsTheTabSeparatedThirdColumn() {
        let output = """
        /dev/disk4\tGUID_partition_scheme\t
        /dev/disk4s1\tApple_HFS\t/Volumes/Pulse 1.2.0
        """
        XCTAssertEqual(
            UpdateInstaller.mountPoint(fromAttachOutput: output),
            "/Volumes/Pulse 1.2.0",
            "volume names keep their spaces; the mount point is a column, not a line"
        )
    }

    func testMountPointSurvivesSpacePaddedOutput() {
        let output = "/dev/disk5s1   Apple_APFS   /Volumes/Pulse"
        XCTAssertEqual(UpdateInstaller.mountPoint(fromAttachOutput: output), "/Volumes/Pulse")
    }

    func testNoMountPointReturnsNilInsteadOfGuessing() {
        XCTAssertNil(UpdateInstaller.mountPoint(fromAttachOutput: "/dev/disk4\tGUID_partition_scheme\t"))
        XCTAssertNil(UpdateInstaller.mountPoint(fromAttachOutput: ""))
    }

    // MARK: - F-4 (12.3): who signed it, and is it still the image we checked

    func testTeamIdentifierIsReadFromCodesignOutput() {
        let signed = """
        Executable=/Applications/Pulse.app/Contents/MacOS/PulseBar
        Identifier=com.pulse.app
        Authority=Developer ID Application: Someone (ABCDE12345)
        TeamIdentifier=ABCDE12345
        """
        XCTAssertEqual(UpdateInstaller.teamIdentifier(fromCodesignOutput: signed), "ABCDE12345")
        XCTAssertNil(UpdateInstaller.teamIdentifier(fromCodesignOutput: "Signature=adhoc\nTeamIdentifier=not set"))
        XCTAssertNil(UpdateInstaller.teamIdentifier(fromCodesignOutput: ""))
    }

    func testOnlyTheSameRealTeamMayReplaceTheApp() {
        XCTAssertNoThrow(try UpdateInstaller.requireSameTeam(candidate: "ABCDE12345", current: "ABCDE12345"))
        XCTAssertThrowsError(try UpdateInstaller.requireSameTeam(candidate: "ZZZZZ99999", current: "ABCDE12345"))
        XCTAssertThrowsError(try UpdateInstaller.requireSameTeam(candidate: nil, current: "ABCDE12345"))
        // An ad-hoc install has no team to match, so nothing replaces it in place.
        XCTAssertThrowsError(try UpdateInstaller.requireSameTeam(candidate: "ABCDE12345", current: nil))
        XCTAssertThrowsError(try UpdateInstaller.requireSameTeam(candidate: nil, current: nil))
    }

    func testTheImageIsReHashedAndAMissingDigestIsARefusal() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-f4-\(UUID().uuidString).dmg")
        let bytes = Data("pulse".utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try UpdateInstaller.verifyDigest(of: url, expected: actual))
        XCTAssertNoThrow(try UpdateInstaller.verifyDigest(of: url, expected: actual.uppercased()))
        XCTAssertThrowsError(try UpdateInstaller.verifyDigest(of: url, expected: String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try UpdateInstaller.verifyDigest(of: url, expected: ""))
        XCTAssertThrowsError(try UpdateInstaller.verifyDigest(of: url, expected: "not-a-digest"))
    }
}

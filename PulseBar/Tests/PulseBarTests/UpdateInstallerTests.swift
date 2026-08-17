import XCTest
@testable import PulseBar

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
}

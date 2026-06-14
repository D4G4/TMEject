import XCTest
@testable import TMEject

final class FullDiskAccessProberClassificationTests: XCTestCase {

    func testFDAStderrClassifiedDenied() {
        let raw = TMUtilRawResult(
            stdout: "",
            // Real stderr captured during the Step-12.6 audit on macOS 26.3.1.
            stderr: "tmutil: latestbackup requires Full Disk Access privileges.\nTo allow this operation, select Full Disk Access in the Privacy\n",
            exitCode: 80
        )
        XCTAssertEqual(LiveFullDiskAccessProber.classify(raw), .denied)
    }

    func testValidSnapshotPathClassifiedGranted() {
        let raw = TMUtilRawResult(
            stdout: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-12-100000\n",
            stderr: "",
            exitCode: 0
        )
        XCTAssertEqual(LiveFullDiskAccessProber.classify(raw), .granted)
    }

    func testEmptyStdoutExit0ClassifiedGranted() {
        // tmutil returns 0 with empty stdout when there are no snapshots yet. We HAD permission
        // to ask — the absence of a snapshot is not an FDA issue.
        let raw = TMUtilRawResult(stdout: "", stderr: "", exitCode: 0)
        XCTAssertEqual(LiveFullDiskAccessProber.classify(raw), .granted)
    }

    func testFailedToMountClassifiedGranted() {
        // Drive not plugged in: backupd returns an error, but it's not a permission issue.
        let raw = TMUtilRawResult(
            stdout: "",
            stderr: "Failed to mount backup destination, error: Error Domain=com.apple.backupd.ErrorDomain Code=18 \"Failed to mount destination.\"",
            exitCode: 1
        )
        XCTAssertEqual(LiveFullDiskAccessProber.classify(raw), .granted)
    }

    func testProbeLaunchFailureClassifiedUnknown() {
        // tmutil binary missing — we have no signal at all.
        let raw = TMUtilRawResult(stdout: "", stderr: "launch failed", exitCode: -1)
        XCTAssertEqual(LiveFullDiskAccessProber.classify(raw), .unknown)
    }
}

final class LiveFullDiskAccessProberIntegrationTests: XCTestCase {

    func testLiveProberRoundTripsThroughFakeClient() async {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueLatestBackupRaw(TMUtilRawResult(
            stdout: "",
            stderr: "tmutil: latestbackup requires Full Disk Access privileges.",
            exitCode: 80
        ))
        let prober = LiveFullDiskAccessProber(tmutil: tmutil)
        let state = await prober.currentState()
        XCTAssertEqual(state, .denied)
        let count = await tmutil.latestBackupRawCallCount
        XCTAssertEqual(count, 1)
    }
}

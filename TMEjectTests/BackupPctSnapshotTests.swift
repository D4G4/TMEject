import XCTest
@testable import TMEject

/// Asserts that the PollingObserver's bonus `onStatus` channel feeds `backupPct` correctly
/// on the same `StatusPlist` shape the live parser produces. This is the regression test
/// for the "popover stuck at 0% during a real backup" bug (commit
/// `fix(observation): plumb backupPct from PollingObserver to popover`).
///
/// We don't drive the observer task itself — `runOnce` is exercised in
/// PollingObserverTests. Here we focus on the coordinator-side wiring: `handleStatusSnapshot`
/// reads `status.percent` (already in 0…100 from the parser) and writes `backupPct`.
@MainActor
final class BackupPctSnapshotTests: XCTestCase {

    private func makeCoordinator() -> AppCoordinator {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return AppCoordinator(
            tmutil: FakeTMUtilClient(),
            ejector: Ejector(unmount: FakeUnmountBridge(), lsof: FakeLsofProbe(),
                             clock: FakeClock(),
                             schedule: EjectorRetrySchedule(backoffsSeconds: [0])),
            resolver: DestinationResolver(bridge: FakeDiskArbitrationBridge(volumes: []),
                                          fileExists: AlwaysExistsFileProbe()),
            defaults: defaults,
            locker: FakeScreenLocker(),
            confirmDialog: FakeConfirmDialog(),
            clock: FakeClock(),
            notifier: FakeSystemNotifier(),
            toastPresenter: nil,
            loginItem: FakeLoginItemManager(),
            fdaProber: FakeFullDiskAccessProber(.granted)
        )
    }

    /// Realistic Tahoe live-backup status — parser produces `percent: 78.0` (already
    /// normalized to 0…100). Coordinator must surface that value verbatim, NOT × 100.
    /// Before the fix, `handleStatusSnapshot` re-scaled the (then-0..1) value and dropped
    /// nested `Progress.Percent`, so backupPct stayed at 0.
    func testRunningBackupAt78PercentReaches78() async {
        let coord = makeCoordinator()
        XCTAssertEqual(coord.backupPct, 0)
        coord.deliverStatusSnapshotFromTest(
            StatusPlist(running: true, backupPhase: "Copying",
                        rawTotalBytes: 4_836_543_210, percent: 78)
        )
        XCTAssertEqual(coord.backupPct, 78, accuracy: 0.001)
    }

    /// End-to-end through the parser: feed a Tahoe-shape plist with the live progress in
    /// the nested `Progress.Percent` (0..1) and assert the coordinator surfaces 78.
    /// This is the actual real-world failure mode — top-level Percent stays at 0 / -1 while
    /// the real value lives nested.
    func testTahoeNestedProgressFlowsAllTheWayToCoordinator() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Running</key><true/>
            <key>BackupPhase</key><string>Copying</string>
            <key>Percent</key><real>0</real>
            <key>Progress</key>
            <dict><key>Percent</key><real>0.78</real></dict>
        </dict>
        </plist>
        """
        let status = try StatusPlist.parse(plistData: Data(xml.utf8))
        let coord = makeCoordinator()
        coord.deliverStatusSnapshotFromTest(status)
        XCTAssertEqual(coord.backupPct, 78, accuracy: 0.001)
    }

    /// When tmutil reports Running=false, backupPct must reset to 0 (so the popover doesn't
    /// linger at "Backing up · 78%" while idle).
    func testRunningFalseResetsBackupPctToZero() async {
        let coord = makeCoordinator()
        coord.deliverStatusSnapshotFromTest(
            StatusPlist(running: true, backupPhase: "Copying", percent: 78)
        )
        XCTAssertEqual(coord.backupPct, 78, accuracy: 0.001)
        coord.deliverStatusSnapshotFromTest(StatusPlist(running: false))
        XCTAssertEqual(coord.backupPct, 0)
    }

    /// Defensive: if the parser hands us `percent: nil` while running (a poll mid-backup that
    /// happened to land before Progress was populated), we MUST NOT snap to 0 — that would
    /// produce a flicker. Last-known value wins.
    func testRunningTrueWithNilPercentKeepsLastKnownValue() async {
        let coord = makeCoordinator()
        coord.deliverStatusSnapshotFromTest(
            StatusPlist(running: true, backupPhase: "Copying", percent: 42)
        )
        XCTAssertEqual(coord.backupPct, 42, accuracy: 0.001)
        coord.deliverStatusSnapshotFromTest(
            StatusPlist(running: true, backupPhase: "Copying", percent: nil)
        )
        XCTAssertEqual(coord.backupPct, 42, accuracy: 0.001, "nil mid-backup → keep last")
    }
}

import XCTest
@testable import TMEject

/// Step 12.7 fixup Blocker #1 — `signalBackupCompleted` must actually trigger the auto-eject
/// flow when auto-eject is on + FDA granted + cooldown clear. Previously the handler was a
/// Step-6 stub that just logged, so every successful backup left the drive mounted.
///
/// We can't observe `.ejectRequested(.auto)` via the deliver chain easily without mocking
/// destinationInfo / DA — instead we assert observable side-effects:
/// - auto-eject OFF → no state change away from .idle, no eject toast text
/// - FDA denied → state stays .idle
/// - FDA granted + auto-eject ON → state moves to .ejecting (the ejectRequested fires)
@MainActor
final class SignalBackupCompletedTests: XCTestCase {

    private let backupUUID = UUID(uuidString: "0852943E-8EC2-4386-8C31-ECE56488E8B4")!

    private func makeCoordinator(
        autoEjectOn: Bool,
        fdaState: FDAState,
        notifier: FakeSystemNotifier = FakeSystemNotifier(),
        unmount: FakeUnmountBridge = FakeUnmountBridge(),
        tmutil: FakeTMUtilClient = FakeTMUtilClient(),
        toastPresenter: FakeToastPresenter? = nil
    ) -> AppCoordinator {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(autoEjectOn, forKey: SettingsKey.autoEjectEnabled)
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (URL(fileURLWithPath: "/Volumes/Backup"),
             VolumeDADescription(volumeUUID: backupUUID, bsdName: "disk4s2", volumeName: "Backup"))
        ])
        return AppCoordinator(
            tmutil: tmutil,
            ejector: Ejector(unmount: unmount, lsof: FakeLsofProbe(),
                             clock: FakeClock(),
                             schedule: EjectorRetrySchedule(backoffsSeconds: [0])),
            resolver: DestinationResolver(bridge: bridge, fileExists: AlwaysExistsFileProbe()),
            defaults: defaults,
            locker: FakeScreenLocker(),
            confirmDialog: FakeConfirmDialog(),
            clock: FakeClock(),
            notifier: notifier,
            toastPresenter: toastPresenter,
            loginItem: FakeLoginItemManager(),
            fdaProber: FakeFullDiskAccessProber(fdaState)
        )
    }

    func testAutoEjectOnFDAGranted_FiresAutoEject() async {
        let unmount = FakeUnmountBridge()
        await unmount.enqueue(.success)
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueDestinationInfo(.success([
            DestinationInfo(id: backupUUID, name: "Backup", kind: "Local", lastDestination: true,
                            mountPoint: URL(fileURLWithPath: "/Volumes/Backup"))
        ]))
        let coord = makeCoordinator(autoEjectOn: true, fdaState: .granted,
                                     unmount: unmount, tmutil: tmutil)
        coord.refreshFDAState(force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        await coord.deliverFromTest(.confirmingEntered(latestBackupPath: nil, entryProbeFailed: false))
        await coord.deliverFromTest(.confirmingExited(
            newLatestBackupPath: URL(fileURLWithPath: "/snap/new"),
            exitProbeFailed: false
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Successful eject → state machine returns to .idle.
        XCTAssertEqual(coord.state, .idle)
        XCTAssertNotNil(coord.lastBackupCompletedAt)
        let unmountCount = await unmount.callCount
        XCTAssertGreaterThanOrEqual(unmountCount, 1, "Auto-eject should have invoked the unmount bridge")
    }

    func testAutoEjectOff_LeavesDriveMounted() async {
        let unmount = FakeUnmountBridge()
        let coord = makeCoordinator(autoEjectOn: false, fdaState: .granted, unmount: unmount)
        coord.refreshFDAState(force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        await coord.deliverFromTest(.confirmingEntered(latestBackupPath: nil, entryProbeFailed: false))
        await coord.deliverFromTest(.confirmingExited(
            newLatestBackupPath: URL(fileURLWithPath: "/snap/new"),
            exitProbeFailed: false
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(coord.state, .idle)
        let unmountCount = await unmount.callCount
        XCTAssertEqual(unmountCount, 0, "Auto-eject OFF should NOT invoke the unmount bridge")
    }

    func testAutoEjectOnFDADenied_DoesNotEject() async {
        let unmount = FakeUnmountBridge()
        let coord = makeCoordinator(autoEjectOn: true, fdaState: .denied, unmount: unmount)
        coord.refreshFDAState(force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        await coord.deliverFromTest(.confirmingEntered(latestBackupPath: nil, entryProbeFailed: false))
        await coord.deliverFromTest(.confirmingExited(
            newLatestBackupPath: URL(fileURLWithPath: "/snap/new"),
            exitProbeFailed: false
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(coord.state, .idle)
        let unmountCount = await unmount.callCount
        XCTAssertEqual(unmountCount, 0, "FDA-denied should block the eject before unmount is called")
    }
}

@MainActor
final class FDANotificationOnboardingGateTests: XCTestCase {

    private func makeCoordinator(
        hasCompletedOnboarding: Bool,
        fdaState: FDAState,
        notifier: FakeSystemNotifier
    ) -> AppCoordinator {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(hasCompletedOnboarding, forKey: SettingsKey.hasCompletedOnboarding)
        return AppCoordinator(
            tmutil: FakeTMUtilClient(),
            ejector: Ejector(unmount: FakeUnmountBridge(), lsof: FakeLsofProbe(),
                             clock: FakeClock(),
                             schedule: EjectorRetrySchedule(backoffsSeconds: [0])),
            resolver: DestinationResolver(bridge: FakeDiskArbitrationBridge(volumes: [])),
            defaults: defaults,
            locker: FakeScreenLocker(),
            confirmDialog: FakeConfirmDialog(),
            clock: FakeClock(),
            notifier: notifier,
            toastPresenter: nil,
            loginItem: FakeLoginItemManager(),
            fdaProber: FakeFullDiskAccessProber(fdaState)
        )
    }

    func testFDANotificationSuppressedDuringOnboarding() async {
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.authorized)
        let coord = makeCoordinator(hasCompletedOnboarding: false, fdaState: .denied, notifier: notifier)
        coord.refreshFDAState(force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        coord.setAutoEjectEnabled(true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let delivered = await notifier.delivered
        let fdaNotif = delivered.first(where: { $0.title.contains("Full Disk Access") })
        XCTAssertNil(fdaNotif,
                     "FDA system notification must NOT fire before onboarding is complete")
    }

    func testFDANotificationFiresAfterOnboardingComplete() async {
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.authorized)
        let coord = makeCoordinator(hasCompletedOnboarding: true, fdaState: .denied, notifier: notifier)
        coord.refreshFDAState(force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        coord.setAutoEjectEnabled(true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let delivered = await notifier.delivered
        let fdaNotif = delivered.first(where: { $0.title.contains("Full Disk Access") })
        XCTAssertNotNil(fdaNotif,
                        "FDA notification should fire once onboarding is done")
    }
}

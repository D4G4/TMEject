import XCTest
@testable import TMEject

final class FakeSystemNotifierTests: XCTestCase {
    // Sanity checks on the fake itself — the live notifier's auth flow can't be
    // unit-tested without a real UNUserNotificationCenter; the fake mirrors its
    // contract so coordinator tests cover the integration.

    func testRequestGrantsWhenNotDetermined() async {
        let notifier = FakeSystemNotifier()
        let granted = await notifier.requestAuthorizationIfNeeded()
        XCTAssertTrue(granted)
        let state = await notifier.currentAuthState()
        XCTAssertEqual(state, .authorized)
    }

    func testRequestRespectsDenial_NoPrompt() async {
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.denied)
        let granted = await notifier.requestAuthorizationIfNeeded()
        XCTAssertFalse(granted)
    }

    func testDeliverSwallowedWhenDenied() async {
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.denied)
        await notifier.deliver(title: "x", body: "y", category: .generic)
        let count = await notifier.delivered.count
        XCTAssertEqual(count, 0)
    }

    func testDeliverDeliveredWhenAuthorized() async {
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.authorized)
        await notifier.deliver(title: "Drive ejected", body: "ok", category: .generic)
        let delivered = await notifier.delivered
        XCTAssertEqual(delivered, [FakeSystemNotifier.DeliveredNotification(
            title: "Drive ejected", body: "ok", category: .generic
        )])
    }
}

@MainActor
final class CoordinatorNotificationIntegrationTests: XCTestCase {

    private let backupUUID = UUID(uuidString: "0852943E-8EC2-4386-8C31-ECE56488E8B4")!

    private func makeCoordinator(
        toasts: Bool,
        notifier: FakeSystemNotifier,
        presenter: FakeToastPresenter,
        unmount: FakeUnmountBridge,
        destinationInfoEnqueue: Bool = true
    ) async -> (AppCoordinator, FakeTMUtilClient) {
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (URL(fileURLWithPath: "/Volumes/Backup"),
             VolumeDADescription(volumeUUID: backupUUID, bsdName: "disk4s2", volumeName: "Backup"))
        ])
        let resolver = DestinationResolver(bridge: bridge, fileExists: AlwaysExistsFileProbe())
        let ejector = Ejector(unmount: unmount, lsof: FakeLsofProbe(),
                              clock: FakeClock(),
                              schedule: EjectorRetrySchedule(backoffsSeconds: [0]))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(toasts, forKey: "co.dls.tmeject.toastsEnabled")
        let tmutil = FakeTMUtilClient()
        if destinationInfoEnqueue {
            await tmutil.enqueueDestinationInfo(.success([
                DestinationInfo(id: backupUUID, name: "Backup", kind: "Local", lastDestination: true,
                                mountPoint: URL(fileURLWithPath: "/Volumes/Backup"))
            ]))
        }
        let coord = AppCoordinator(
            tmutil: tmutil, ejector: ejector, resolver: resolver,
            defaults: defaults,
            locker: FakeScreenLocker(),
            confirmDialog: FakeConfirmDialog(),
            clock: FakeClock(),
            notifier: notifier,
            toastPresenter: presenter
        )
        return (coord, tmutil)
    }

    func testToastsEnabledByDefault_FreshDefaults() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertNil(defaults.object(forKey: "co.dls.tmeject.toastsEnabled"))
        let coord = AppCoordinator(
            tmutil: FakeTMUtilClient(),
            ejector: Ejector(unmount: FakeUnmountBridge(), lsof: FakeLsofProbe(),
                             clock: FakeClock(), schedule: EjectorRetrySchedule(backoffsSeconds: [0])),
            resolver: DestinationResolver(bridge: FakeDiskArbitrationBridge(volumes: [])),
            defaults: defaults,
            locker: FakeScreenLocker(),
            confirmDialog: FakeConfirmDialog(),
            clock: FakeClock(),
            notifier: FakeSystemNotifier(),
            toastPresenter: nil
        )
        XCTAssertTrue(coord.toastsEnabled)
        XCTAssertNotNil(defaults.object(forKey: "co.dls.tmeject.toastsEnabled"))
    }

    func testShowToastDispatchesToPresenterWhenEnabled() async {
        let presenter = FakeToastPresenter()
        let notifier = FakeSystemNotifier()
        let (coord, _) = await makeCoordinator(toasts: true, notifier: notifier,
                                                presenter: presenter, unmount: FakeUnmountBridge())
        await coord.deliverForTesting(.backupBegan(baselineLatestBackupPath: nil, baselineProbeFailed: false))
        try? await Task.sleep(nanoseconds: 20_000_000)
        // Title enriched to "Backing up…" per the design pass (was the raw "Backup started"
        // before). Subtitle varies by auto-eject state; assert via title + kind only.
        XCTAssertEqual(presenter.presented.count, 1)
        XCTAssertEqual(presenter.presented.first?.message, "Backing up…")
        XCTAssertEqual(presenter.presented.first?.kind, .busy)
    }

    func testToastSuppressedWhenDisabled() async {
        let presenter = FakeToastPresenter()
        let notifier = FakeSystemNotifier()
        let (coord, _) = await makeCoordinator(toasts: false, notifier: notifier,
                                                presenter: presenter, unmount: FakeUnmountBridge())
        await coord.deliverForTesting(.backupBegan(baselineLatestBackupPath: nil, baselineProbeFailed: false))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertNotNil(coord.lastToast,
                        "lastToast still set for menu bar surface even when overlay suppressed")
    }

    func testEjectSuccess_NotifiesSystemEjectedCategory() async {
        let presenter = FakeToastPresenter()
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.authorized)
        let hang = FakeUnmountBridge()
        await hang.setHangForever()
        let (coord, _) = await makeCoordinator(toasts: true, notifier: notifier,
                                                presenter: presenter, unmount: hang)
        let task = Task { await coord.deliverForTesting(.ejectRequested(lock: false, source: .manual)) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(coord.state, .ejecting)
        await coord.deliverForTesting(.ejectAttemptCompleted(success: true, errorSummary: nil))
        let delivered = await notifier.delivered
        let successNotif = delivered.first(where: { $0.title == "Drive ejected" })
        XCTAssertNotNil(successNotif)
        XCTAssertEqual(successNotif?.category, .generic)
        task.cancel()
    }

    func testEjectFailure_NotifiesEjectFailurePersistentCategory() async {
        let presenter = FakeToastPresenter()
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.authorized)
        let hang = FakeUnmountBridge()
        await hang.setHangForever()
        let (coord, _) = await makeCoordinator(toasts: true, notifier: notifier,
                                                presenter: presenter, unmount: hang)
        let task = Task { await coord.deliverForTesting(.ejectRequested(lock: false, source: .manual)) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(coord.state, .ejecting)
        await coord.deliverForTesting(.ejectAttemptCompleted(success: false, errorSummary: "busy: Spotlight"))
        let delivered = await notifier.delivered
        let failureNotif = delivered.first(where: { $0.title == "Eject failed" })
        XCTAssertNotNil(failureNotif, "should fire a system notification with title \"Eject failed\"")
        XCTAssertEqual(failureNotif?.category, .ejectFailurePersistent)
        task.cancel()
    }

    func testRequestNotificationAuthIfNeeded_DelegatesToNotifier() async {
        let notifier = FakeSystemNotifier()
        let (coord, _) = await makeCoordinator(toasts: true, notifier: notifier,
                                                presenter: FakeToastPresenter(),
                                                unmount: FakeUnmountBridge())
        let granted = await coord.requestNotificationAuthIfNeeded()
        XCTAssertTrue(granted)
        let count = await notifier.authRequestCount
        XCTAssertEqual(count, 1)
    }
}

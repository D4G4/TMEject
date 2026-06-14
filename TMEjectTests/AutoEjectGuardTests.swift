import XCTest
@testable import TMEject

@MainActor
final class AutoEjectGuardTests: XCTestCase {

    private func makeCoordinator(
        fdaState: FDAState,
        notifier: FakeSystemNotifier,
        defaults: UserDefaults? = nil
    ) -> AppCoordinator {
        let prober = FakeFullDiskAccessProber(fdaState)
        return AppCoordinator(
            tmutil: FakeTMUtilClient(),
            ejector: Ejector(unmount: FakeUnmountBridge(), lsof: FakeLsofProbe(),
                             clock: FakeClock(),
                             schedule: EjectorRetrySchedule(backoffsSeconds: [0])),
            resolver: DestinationResolver(bridge: FakeDiskArbitrationBridge(volumes: [])),
            defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!,
            locker: FakeScreenLocker(),
            confirmDialog: FakeConfirmDialog(),
            clock: FakeClock(),
            notifier: notifier,
            toastPresenter: nil,
            loginItem: FakeLoginItemManager(),
            fdaProber: prober
        )
    }

    func testTogglingAutoEjectOnWhileFDADenied_SetsLastError() async {
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.authorized)
        let coord = makeCoordinator(fdaState: .denied, notifier: notifier)
        coord.refreshFDAState(force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coord.fdaState, .denied)

        coord.setAutoEjectEnabled(true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(coord.lastError, "Auto-eject pending — Full Disk Access required")
    }

    func testTogglingAutoEjectOffClearsFDAErrorSurface() async {
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.authorized)
        let coord = makeCoordinator(fdaState: .denied, notifier: notifier)
        coord.refreshFDAState(force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        coord.setAutoEjectEnabled(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(coord.lastError)

        coord.setAutoEjectEnabled(false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(coord.lastError)
    }

    func testTogglingAutoEjectOnWhileFDAGranted_NoLastErrorNoNotification() async {
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.authorized)
        let coord = makeCoordinator(fdaState: .granted, notifier: notifier)
        coord.refreshFDAState(force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        coord.setAutoEjectEnabled(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(coord.lastError)
        let delivered = await notifier.delivered
        let fdaNotif = delivered.first(where: { $0.title.contains("Full Disk Access") })
        XCTAssertNil(fdaNotif, "no notification when FDA is fine")
    }

    func testIsAutoEjectFunctional_GreenOnlyWhenBothConditionsHold() async {
        let notifier = FakeSystemNotifier()
        let coord = makeCoordinator(fdaState: .denied, notifier: notifier)
        coord.refreshFDAState(force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Auto-eject OFF → functional is true (no requirement violated).
        XCTAssertTrue(coord.isAutoEjectFunctional)
        coord.setAutoEjectEnabled(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Auto-eject ON + FDA denied → not functional.
        XCTAssertFalse(coord.isAutoEjectFunctional)
    }

    func testFDADeniedNotification_RateLimited() async {
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.authorized)
        let coord = makeCoordinator(fdaState: .denied, notifier: notifier)
        coord.refreshFDAState(force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        coord.setAutoEjectEnabled(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Trigger another evaluation by toggling FDA back and forth via probe.
        coord.refreshFDAState(force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        coord.refreshFDAState(force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let delivered = await notifier.delivered
        let fdaNotifs = delivered.filter { $0.title == "TMEject needs Full Disk Access" }
        XCTAssertEqual(fdaNotifs.count, 1,
                       "rate-limited — only one FDA notification per 24h window even if the gate evaluates many times")
    }
}

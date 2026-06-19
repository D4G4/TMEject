import XCTest
@testable import TMEject

@MainActor
final class LoginItemTests: XCTestCase {

    private func makeCoordinator(
        loginItem: FakeLoginItemManager,
        defaults: UserDefaults
    ) -> AppCoordinator {
        // Seed the launchAtLogin key so the coordinator's init doesn't fire its
        // first-install auto-register (added in v0.1.2 — see AppCoordinator.init
        // comment). These tests exercise the explicit setLaunchAtLogin API, not
        // the first-install path; pretending the key was previously written keeps
        // registerCount honest.
        if defaults.object(forKey: SettingsKey.launchAtLogin) == nil {
            defaults.set(false, forKey: SettingsKey.launchAtLogin)
        }
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
            notifier: FakeSystemNotifier(),
            toastPresenter: nil,
            loginItem: loginItem
        )
    }

    func testInitMirrorsCurrentLoginItemStatusInAppStorage() {
        let item = FakeLoginItemManager()
        item.setStatus(.enabled)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let coord = makeCoordinator(loginItem: item, defaults: defaults)
        XCTAssertEqual(coord.loginItemStatus, .enabled)
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.launchAtLogin))
    }

    func testSetLaunchAtLogin_RegistersAndUpdatesAppStorage() throws {
        let item = FakeLoginItemManager()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let coord = makeCoordinator(loginItem: item, defaults: defaults)

        try coord.setLaunchAtLogin(true)
        XCTAssertEqual(item.registerCount, 1)
        XCTAssertEqual(coord.loginItemStatus, .enabled)
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.launchAtLogin))
    }

    func testSetLaunchAtLoginFalse_Unregisters() throws {
        let item = FakeLoginItemManager()
        item.setStatus(.enabled)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let coord = makeCoordinator(loginItem: item, defaults: defaults)
        try coord.setLaunchAtLogin(false)
        XCTAssertEqual(item.unregisterCount, 1)
        XCTAssertEqual(coord.loginItemStatus, .notRegistered)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.launchAtLogin))
    }

    func testRefreshLoginItemStatus_PicksUpExternalChanges() {
        let item = FakeLoginItemManager()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let coord = makeCoordinator(loginItem: item, defaults: defaults)
        // Simulate the user flipping the Login Items pane outside the app.
        item.setStatus(.requiresApproval)
        coord.refreshLoginItemStatus()
        XCTAssertEqual(coord.loginItemStatus, .requiresApproval)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.launchAtLogin),
                       ".requiresApproval is NOT .enabled — mirror should be false")
    }

    func testRegisterFailure_PropagatesAndKeepsStateConsistent() {
        let item = FakeLoginItemManager()
        item.registerError = NSError(domain: "test", code: 42)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let coord = makeCoordinator(loginItem: item, defaults: defaults)
        XCTAssertThrowsError(try coord.setLaunchAtLogin(true))
        XCTAssertEqual(item.registerCount, 1)
        XCTAssertEqual(coord.loginItemStatus, .notRegistered,
                       "register threw — status should reflect the failure, not lie that we're enabled")
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.launchAtLogin))
    }
}

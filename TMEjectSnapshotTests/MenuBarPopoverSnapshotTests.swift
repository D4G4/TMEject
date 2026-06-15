import XCTest
import SwiftUI
@testable import TMEject

/// Popover B in each of 5 states × 2 themes × 2 surface modes.
@MainActor
final class MenuBarPopoverSnapshotTests: SnapshotTestCase {

    private func render(stateName: String,
                        apply: (AppCoordinator) -> Void,
                        theme: ColorScheme, translucent: Bool) {
        let coord = SnapshotFixtures.makeCoordinator()
        apply(coord)
        let view = MenuBarPopoverView(coordinator: coord, openPreferences: {})
        let name = SnapshotName.surface("popover", variant: stateName,
                                         theme: theme, translucent: translucent)
        // Popover is 300pt wide; pad height for tallest state (failed + Why? expansion).
        assertSnapshot(of: view, named: name,
                        width: 320, height: 360,
                        colorScheme: theme, translucent: translucent)
    }

    // MARK: - Idle

    func testIdleLightOpaque() {
        render(stateName: "idle", apply: idleState,
                theme: .light, translucent: false)
    }
    func testIdleDarkOpaque() {
        render(stateName: "idle", apply: idleState,
                theme: .dark, translucent: false)
    }
    func testIdleLightTranslucent() {
        render(stateName: "idle", apply: idleState,
                theme: .light, translucent: true)
    }
    func testIdleDarkTranslucent() {
        render(stateName: "idle", apply: idleState,
                theme: .dark, translucent: true)
    }

    // MARK: - Backing up (45%)

    func testBackingUpLightOpaque() {
        render(stateName: "backingUp", apply: backingUpState,
                theme: .light, translucent: false)
    }
    func testBackingUpDarkOpaque() {
        render(stateName: "backingUp", apply: backingUpState,
                theme: .dark, translucent: false)
    }

    // MARK: - Confirming

    func testConfirmingLightOpaque() {
        render(stateName: "confirming", apply: confirmingState,
                theme: .light, translucent: false)
    }
    func testConfirmingDarkOpaque() {
        render(stateName: "confirming", apply: confirmingState,
                theme: .dark, translucent: false)
    }

    // MARK: - Ejecting

    func testEjectingLightOpaque() {
        render(stateName: "ejecting", apply: ejectingState,
                theme: .light, translucent: false)
    }
    func testEjectingDarkOpaque() {
        render(stateName: "ejecting", apply: ejectingState,
                theme: .dark, translucent: false)
    }

    // MARK: - Failed

    func testFailedLightOpaque() {
        render(stateName: "failed", apply: failedState,
                theme: .light, translucent: false)
    }
    func testFailedDarkOpaque() {
        render(stateName: "failed", apply: failedState,
                theme: .dark, translucent: false)
    }

    // MARK: - State applicators

    private func idleState(_ c: AppCoordinator) {
        c.applySnapshotState(state: .idle,
                              drivePresent: true,
                              driveName: "Backup Drive",
                              fdaState: .granted)
    }
    private func backingUpState(_ c: AppCoordinator) {
        c.applySnapshotState(state: .backingUp,
                              backupPct: 45,
                              drivePresent: true,
                              driveName: "Backup Drive",
                              fdaState: .granted)
    }
    private func confirmingState(_ c: AppCoordinator) {
        c.applySnapshotState(state: .confirming,
                              drivePresent: true,
                              driveName: "Backup Drive",
                              fdaState: .granted)
    }
    private func ejectingState(_ c: AppCoordinator) {
        c.applySnapshotState(state: .ejecting,
                              ejectPct: 60,
                              ejectAttempt: 2,
                              drivePresent: true,
                              driveName: "Backup Drive",
                              fdaState: .granted)
    }
    private func failedState(_ c: AppCoordinator) {
        c.applySnapshotState(state: .idleEjectFailed,
                              drivePresent: true,
                              driveName: "Backup Drive",
                              lastError: "held by mds_stores (pid 412)",
                              fdaState: .granted)
    }
}

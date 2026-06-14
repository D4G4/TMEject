import XCTest
import SwiftUI
@testable import TMEject

@MainActor
final class SettingsSnapshotTests: SnapshotTestCase {

    private func render(variant: String,
                        apply: (AppCoordinator, UserDefaults) -> Void,
                        theme: ColorScheme, translucent: Bool) {
        let coord = SnapshotFixtures.makeCoordinator()
        // Settings reads several @AppStorage keys; use UserDefaults.standard since
        // @AppStorage doesn't take a suite. We restore prior values after the render
        // via the test fixture wrapper inherited from SnapshotTestCase's recording flow.
        apply(coord, UserDefaults.standard)
        let view = SettingsView(coordinator: coord)
        let name = SnapshotName.surface("settings", variant: variant,
                                         theme: theme, translucent: translucent)
        assertHostedSnapshot(of: view, named: name,
                              width: 460, height: 700,
                              colorScheme: theme, translucent: translucent)
    }

    // MARK: - Default (auto-eject ON + FDA granted + Troubleshooting closed)

    func testDefaultLightOpaque() {
        render(variant: "default", apply: defaultState, theme: .light, translucent: false)
    }
    func testDefaultDarkOpaque() {
        render(variant: "default", apply: defaultState, theme: .dark, translucent: false)
    }
    func testDefaultLightTranslucent() {
        render(variant: "default", apply: defaultState, theme: .light, translucent: true)
    }
    func testDefaultDarkTranslucent() {
        render(variant: "default", apply: defaultState, theme: .dark, translucent: true)
    }

    // MARK: - FDA pill visible (auto-eject ON + FDA denied)

    func testFDAPillLightOpaque() {
        render(variant: "fda_pill", apply: fdaPillState, theme: .light, translucent: false)
    }
    func testFDAPillDarkOpaque() {
        render(variant: "fda_pill", apply: fdaPillState, theme: .dark, translucent: false)
    }

    // MARK: - State applicators

    private func defaultState(_ c: AppCoordinator, _ d: UserDefaults) {
        d.set(true,  forKey: SettingsKey.autoEjectEnabled)
        d.set(30,    forKey: SettingsKey.cooldownMinutes)
        d.set(false, forKey: SettingsKey.betaChannel)
        c.applySnapshotState(loginItemStatus: .notRegistered, fdaState: .granted)
    }
    private func fdaPillState(_ c: AppCoordinator, _ d: UserDefaults) {
        d.set(true,  forKey: SettingsKey.autoEjectEnabled)
        d.set(30,    forKey: SettingsKey.cooldownMinutes)
        c.applySnapshotState(loginItemStatus: .notRegistered, fdaState: .denied)
    }
}

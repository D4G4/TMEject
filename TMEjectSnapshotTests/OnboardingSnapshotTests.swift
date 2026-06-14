import XCTest
import SwiftUI
@testable import TMEject

@MainActor
final class OnboardingSnapshotTests: SnapshotTestCase {

    private func render(variant: String? = nil,
                        fdaState: FDAState = .granted,
                        theme: ColorScheme,
                        translucent: Bool) {
        let coord = SnapshotFixtures.makeCoordinator()
        coord.applySnapshotState(state: .idle, fdaState: fdaState)
        // Onboarding's auto-eject toggle reads @AppStorage(autoEjectEnabled) — keep it ON so
        // the FDA pill conditional is exercised when fdaState != .granted.
        UserDefaults.standard.set(true, forKey: SettingsKey.autoEjectEnabled)
        let view = OnboardingView(coordinator: coord, onComplete: {})
        let name = SnapshotName.surface("onboarding_modal", variant: variant,
                                         theme: theme, translucent: translucent)
        // ScrollView-free, but the modal contains Form-like layout — use hosted snapshot.
        assertHostedSnapshot(of: view, named: name,
                              width: 440, height: 460,
                              colorScheme: theme, translucent: translucent)
    }

    // Default: FDA granted, no pill.
    func testLightOpaque()      { render(theme: .light, translucent: false) }
    func testDarkOpaque()       { render(theme: .dark,  translucent: false) }
    func testLightTranslucent() { render(theme: .light, translucent: true) }
    func testDarkTranslucent()  { render(theme: .dark,  translucent: true) }

    // Step 12.7 High #2 — FDA denied → pill renders between lede and toggle.
    func testFDADeniedLight() {
        render(variant: "fda_denied", fdaState: .denied, theme: .light, translucent: false)
    }
    func testFDADeniedDark() {
        render(variant: "fda_denied", fdaState: .denied, theme: .dark, translucent: false)
    }
}

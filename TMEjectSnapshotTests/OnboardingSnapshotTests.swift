import XCTest
import SwiftUI
@testable import TMEject

@MainActor
final class OnboardingSnapshotTests: SnapshotTestCase {

    private func render(theme: ColorScheme, translucent: Bool) {
        let coord = SnapshotFixtures.makeCoordinator()
        coord.applySnapshotState(state: .idle, fdaState: .granted)
        let view = OnboardingView(coordinator: coord, onComplete: {})
        let name = SnapshotName.surface("onboarding_modal", theme: theme, translucent: translucent)
        // ScrollView-free, but the modal contains Form-like layout — use hosted snapshot.
        assertHostedSnapshot(of: view, named: name,
                              width: 440, height: 460,
                              colorScheme: theme, translucent: translucent)
    }

    func testLightOpaque()      { render(theme: .light, translucent: false) }
    func testDarkOpaque()       { render(theme: .dark,  translucent: false) }
    func testLightTranslucent() { render(theme: .light, translucent: true) }
    func testDarkTranslucent()  { render(theme: .dark,  translucent: true) }
}

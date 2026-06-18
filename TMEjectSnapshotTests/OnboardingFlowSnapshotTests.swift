import XCTest
import SwiftUI
@testable import TMEject

/// Snapshot coverage for the three-step first-install flow. One reference per
/// (step × theme × translucency) = 12. References get recorded on first run via the
/// `SNAPSHOT_RECORD=1` path; subsequent runs compare pixel-by-pixel with the 0.5%
/// perceptual tolerance the rest of the suite uses.
@MainActor
final class OnboardingFlowSnapshotTests: SnapshotTestCase {

    // MARK: - Step 1: Intro

    private func renderIntro(theme: ColorScheme, translucent: Bool) {
        let view = OnboardingIntroStep(onPrimary: {})
            .frame(width: 480, height: 540)
            .surfaceBackground(.window)
        let name = SnapshotName.surface("onboarding_flow_intro",
                                         theme: theme, translucent: translucent)
        assertHostedSnapshot(of: view, named: name,
                              width: 480, height: 540,
                              colorScheme: theme, translucent: translucent)
    }

    func testIntroLightOpaque()      { renderIntro(theme: .light, translucent: false) }
    func testIntroDarkOpaque()       { renderIntro(theme: .dark,  translucent: false) }
    func testIntroLightTranslucent() { renderIntro(theme: .light, translucent: true) }
    func testIntroDarkTranslucent()  { renderIntro(theme: .dark,  translucent: true) }

    // MARK: - Step 2: Full Disk Access

    private func renderFDA(theme: ColorScheme, translucent: Bool) {
        let view = OnboardingFDAStep(
            isWorking: false,
            errorMessage: nil,
            onOpenSettings: {},
            onConfirmGranted: {},
            onSkip: {}
        )
        .frame(width: 480, height: 540)
        .surfaceBackground(.window)
        let name = SnapshotName.surface("onboarding_flow_fda",
                                         theme: theme, translucent: translucent)
        assertHostedSnapshot(of: view, named: name,
                              width: 480, height: 540,
                              colorScheme: theme, translucent: translucent)
    }

    func testFDALightOpaque()      { renderFDA(theme: .light, translucent: false) }
    func testFDADarkOpaque()       { renderFDA(theme: .dark,  translucent: false) }
    func testFDALightTranslucent() { renderFDA(theme: .light, translucent: true) }
    func testFDADarkTranslucent()  { renderFDA(theme: .dark,  translucent: true) }

    // Error-state variant — verifies the inline orange error block layout doesn't shift
    // the CTAs off-screen when a long string lands.
    func testFDAErrorLightOpaque() {
        let view = OnboardingFDAStep(
            isWorking: false,
            errorMessage: "Full Disk Access still isn't granted. In System Settings → " +
                "Privacy & Security → Full Disk Access, toggle TMEject on, then tap " +
                "“I've granted it” again.",
            onOpenSettings: {},
            onConfirmGranted: {},
            onSkip: {}
        )
        .frame(width: 480, height: 540)
        .surfaceBackground(.window)
        let name = SnapshotName.surface("onboarding_flow_fda", variant: "error",
                                         theme: .light, translucent: false)
        assertHostedSnapshot(of: view, named: name,
                              width: 480, height: 540,
                              colorScheme: .light, translucent: false)
    }

    // MARK: - Step 3: Notifications

    private func renderNotifications(theme: ColorScheme, translucent: Bool) {
        let view = OnboardingNotificationsStep(
            isWorking: false,
            onAllow: {},
            onSkip: {}
        )
        .frame(width: 480, height: 540)
        .surfaceBackground(.window)
        let name = SnapshotName.surface("onboarding_flow_notifications",
                                         theme: theme, translucent: translucent)
        assertHostedSnapshot(of: view, named: name,
                              width: 480, height: 540,
                              colorScheme: theme, translucent: translucent)
    }

    func testNotificationsLightOpaque()      { renderNotifications(theme: .light, translucent: false) }
    func testNotificationsDarkOpaque()       { renderNotifications(theme: .dark,  translucent: false) }
    func testNotificationsLightTranslucent() { renderNotifications(theme: .light, translucent: true) }
    func testNotificationsDarkTranslucent()  { renderNotifications(theme: .dark,  translucent: true) }
}

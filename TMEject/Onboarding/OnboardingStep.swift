import Foundation

/// First-install onboarding pages, in flow order.
///
/// **Notifications BEFORE FullDiskAccess** is deliberate: granting FDA terminates
/// the TMEject process (macOS behaviour, not ours), so any step shown AFTER the
/// FDA step would never reach the user. Notification permission has to be asked
/// before we deep-link to the FDA pane.
///
/// We promise "very few notifications" in the onboarding copy and keep that
/// promise: only eject failures + FDA-required reminders + foreign-drive eject
/// failures actually fire system notifications. Successes are silent (the drive
/// being ejected IS the success).
enum OnboardingStep: Int, CaseIterable, Sendable, Equatable {
    case intro = 0
    case notifications = 1
    case fullDiskAccess = 2

    var pageIndex: Int { rawValue }

    /// Total number of pages — drives the dot indicator at the top of the flow.
    static let pageCount: Int = OnboardingStep.allCases.count
}

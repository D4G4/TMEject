import Foundation

/// The three-step first-install flow. Mutually exclusive from — and presented BEFORE —
/// the Launch HUD. The HUD is a per-launch locator; this flow runs only on first install
/// (or when the user explicitly resets onboarding from Settings → Troubleshooting).
///
/// Why a flow at all (vs. the pre-v0.2 HUD-only path): the previous boot path silently
/// flipped `hasCompletedOnboarding = true` and only showed the locator. A fresh install
/// got zero intro, no permission asks — most importantly, **Full Disk Access was never
/// requested**. Auto-eject defaults ON (see `docs/architecture.md` → "Defaults rationale"),
/// so without FDA the app was silently broken: the snapshot-path delta success rule can't
/// run without `tmutil latestbackup`, which needs FDA.
enum OnboardingStep: Int, CaseIterable, Sendable, Equatable {
    case intro = 0
    case fullDiskAccess = 1

    // Removed: case notifications. Granting FDA terminates the app (macOS
    // behaviour, not ours), and on relaunch the user never reaches a third
    // step. In-app toasts cover the visible notification needs already; system
    // notifications via UNUserNotificationCenter are not worth the lost step.

    var pageIndex: Int { rawValue }

    /// Total number of pages — drives the dot indicator at the top of the flow.
    static let pageCount: Int = OnboardingStep.allCases.count
}

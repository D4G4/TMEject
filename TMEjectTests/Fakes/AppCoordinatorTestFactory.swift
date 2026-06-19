import Foundation
@testable import TMEject

/// Test seam that hands back a coordinator wired with the standard fake deps —
/// fake tmutil/ejector/locker/login-item/clock — while letting individual tests
/// override only the bits they care about (FDA prober, notifier, UserDefaults).
///
/// Introduced because `OnboardingFlowTests` (and any future onboarding-adjacent
/// test) only cares about FDA + notifier behaviour; spelling out the full Fake
/// soup each time obscures intent.
extension AppCoordinator {
    @MainActor
    static func makeForTests(
        defaults: UserDefaults,
        fdaProber: FullDiskAccessProbing,
        notifier: SystemNotifier,
        loginItem: LoginItemManaging = FakeLoginItemManager()
    ) -> AppCoordinator {
        AppCoordinator(
            tmutil: FakeTMUtilClient(),
            ejector: Ejector(unmount: FakeUnmountBridge(),
                              lsof: FakeLsofProbe(),
                              clock: FakeClock(),
                              schedule: EjectorRetrySchedule(backoffsSeconds: [0])),
            resolver: DestinationResolver(bridge: FakeDiskArbitrationBridge(volumes: []),
                                           fileExists: AlwaysExistsFileProbe()),
            defaults: defaults,
            locker: FakeScreenLocker(),
            confirmDialog: FakeConfirmDialog(),
            clock: FakeClock(),
            notifier: notifier,
            toastPresenter: nil,
            loginItem: loginItem,
            fdaProber: fdaProber
        )
    }
}

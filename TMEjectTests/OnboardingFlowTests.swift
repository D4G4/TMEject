import XCTest
@testable import TMEject

/// Logic coverage for `OnboardingFlowModel`. The view is exercised by
/// `OnboardingFlowSnapshotTests` — this file drives the model the way the SwiftUI buttons
/// would, with injected fakes for FDA + notifications.
///
/// What's covered:
///   - Intro "Get started" advances to FDA.
///   - FDA "I've granted it" while denied → stays on FDA + sets error.
///   - FDA "I've granted it" while granted → clears error + advances to notifications.
///   - FDA "Skip for now" → advances without re-probing.
///   - Notifications "Allow" → flips hasCompletedOnboarding=true + calls onFinish.
///   - Notifications "Skip" → flips hasCompletedOnboarding=true + calls onFinish.
///   - hasCompletedOnboarding starts false and is ONLY set on completion (not on advance).
@MainActor
final class OnboardingFlowTests: XCTestCase {

    // MARK: - Harness

    private func makeCoordinator(fdaProber: FakeFullDiskAccessProber) -> AppCoordinator {
        AppCoordinator(
            tmutil: FakeTMUtilClient(),
            ejector: Ejector(unmount: FakeUnmountBridge(), lsof: FakeLsofProbe(),
                             clock: FakeClock(),
                             schedule: EjectorRetrySchedule(backoffsSeconds: [0])),
            resolver: DestinationResolver(bridge: FakeDiskArbitrationBridge(volumes: [])),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            locker: FakeScreenLocker(),
            confirmDialog: FakeConfirmDialog(),
            clock: FakeClock(),
            notifier: FakeSystemNotifier(),
            toastPresenter: nil,
            loginItem: FakeLoginItemManager(),
            fdaProber: fdaProber
        )
    }

    private func makeModel(
        prober: FakeFullDiskAccessProber,
        notifier: FakeSystemNotifier,
        defaults: UserDefaults,
        finished: @escaping () -> Void = {}
    ) -> OnboardingFlowModel {
        OnboardingFlowModel(
            coordinator: makeCoordinator(fdaProber: prober),
            fdaProber: prober,
            notifier: notifier,
            defaults: defaults,
            openURL: { _ in },
            onFinish: { finished() }
        )
    }

    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "onboarding-flow-tests-\(UUID().uuidString)")!
        d.set(false, forKey: SettingsKey.hasCompletedOnboarding)
        return d
    }

    // MARK: - Intro

    func testIntroAdvancesToFDA() {
        let defaults = freshDefaults()
        let model = makeModel(prober: FakeFullDiskAccessProber(.granted),
                              notifier: FakeSystemNotifier(),
                              defaults: defaults)
        XCTAssertEqual(model.step, .intro)
        model.tapGetStarted()
        XCTAssertEqual(model.step, .fullDiskAccess)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.hasCompletedOnboarding))
    }

    // MARK: - FDA — denied → granted progression

    func testFDADeniedThenGrantedAdvancesOnSecondTap() async {
        let prober = FakeFullDiskAccessProber(.denied)
        await prober.enqueue(.granted)  // second probe call returns .granted
        let defaults = freshDefaults()
        let model = makeModel(prober: prober,
                              notifier: FakeSystemNotifier(),
                              defaults: defaults)

        model.tapGetStarted()
        XCTAssertEqual(model.step, .fullDiskAccess)

        // First tap — prober returns .denied → stays + sets error.
        await model.tapIveGrantedFDA()
        XCTAssertEqual(model.step, .fullDiskAccess)
        XCTAssertNotNil(model.fdaError, "denied probe should surface an inline error")

        // User flips the toggle, taps again — prober returns .granted → advances.
        await model.tapIveGrantedFDA()
        XCTAssertEqual(model.step, .notifications)
        XCTAssertNil(model.fdaError, "granted probe should clear the error")
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.hasCompletedOnboarding),
                        "advancing to Step 3 must not yet complete onboarding")
    }

    func testFDAUnknownStateStays() async {
        let prober = FakeFullDiskAccessProber(.unknown)
        let model = makeModel(prober: prober,
                              notifier: FakeSystemNotifier(),
                              defaults: freshDefaults())
        model.tapGetStarted()
        await model.tapIveGrantedFDA()
        XCTAssertEqual(model.step, .fullDiskAccess,
                        ".unknown should be treated as not-yet-granted")
        XCTAssertNotNil(model.fdaError)
    }

    func testFDASkipAdvancesWithoutProbing() async {
        let prober = FakeFullDiskAccessProber(.denied)
        let model = makeModel(prober: prober,
                              notifier: FakeSystemNotifier(),
                              defaults: freshDefaults())
        model.tapGetStarted()
        XCTAssertEqual(model.step, .fullDiskAccess)
        model.tapSkipFDA()
        XCTAssertEqual(model.step, .notifications)
        let probeCount = await prober.probeCount
        // Coordinator construction triggers one probe at init via the default flow; we
        // assert the SKIP path didn't call the prober FROM the model itself by checking
        // the count didn't grow on the skip tap. Coordinator probes happen only via
        // refreshFDAState — which we don't call on skip.
        XCTAssertEqual(probeCount, 0, "Skip must not invoke the prober")
    }

    // MARK: - Completion — flips hasCompletedOnboarding

    func testAllowNotificationsCompletes() async {
        let defaults = freshDefaults()
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.notDetermined)
        var finishCount = 0
        let model = makeModel(prober: FakeFullDiskAccessProber(.granted),
                              notifier: notifier,
                              defaults: defaults,
                              finished: { finishCount += 1 })
        model.tapGetStarted()
        await model.tapIveGrantedFDA()
        XCTAssertEqual(model.step, .notifications)

        await model.tapAllowNotifications()
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.hasCompletedOnboarding))
        XCTAssertEqual(finishCount, 1)
        let requestCount = await notifier.authRequestCount
        XCTAssertEqual(requestCount, 1, "Allow must invoke the notification request")
    }

    func testSkipNotificationsCompletes() async {
        let defaults = freshDefaults()
        let notifier = FakeSystemNotifier()
        var finishCount = 0
        let model = makeModel(prober: FakeFullDiskAccessProber(.granted),
                              notifier: notifier,
                              defaults: defaults,
                              finished: { finishCount += 1 })
        model.tapGetStarted()
        await model.tapIveGrantedFDA()
        XCTAssertEqual(model.step, .notifications)

        model.tapSkipNotifications()
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.hasCompletedOnboarding),
                      "Skip from Step 3 must still flip hasCompletedOnboarding=true")
        XCTAssertEqual(finishCount, 1)
        let requestCount = await notifier.authRequestCount
        XCTAssertEqual(requestCount, 0, "Skip must NOT invoke the notification request")
    }

    // MARK: - Notification grant outcome does not gate completion

    func testNotificationsDeniedStillCompletes() async {
        let defaults = freshDefaults()
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.notDetermined)
        await notifier.setGrant(false)  // user taps "Don't Allow" in the system prompt
        var finishCount = 0
        let model = makeModel(prober: FakeFullDiskAccessProber(.granted),
                              notifier: notifier,
                              defaults: defaults,
                              finished: { finishCount += 1 })
        model.tapGetStarted()
        await model.tapIveGrantedFDA()
        await model.tapAllowNotifications()
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.hasCompletedOnboarding),
                      "Notification denial must NOT block completion")
        XCTAssertEqual(finishCount, 1)
    }
}

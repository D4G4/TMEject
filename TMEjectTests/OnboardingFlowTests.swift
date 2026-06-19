import XCTest
@testable import TMEject

@MainActor
final class OnboardingFlowTests: XCTestCase {

    // MARK: - Helpers

    private func freshDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "tmeject.onboarding-tests.\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().keys.first ?? "")
        return suite
    }

    private func makeModel(
        prober: FakeFullDiskAccessProber,
        notifier: FakeSystemNotifier,
        defaults: UserDefaults,
        finished: @escaping @MainActor () -> Void = {}
    ) -> OnboardingFlowModel {
        let coordinator = AppCoordinator.makeForTests(defaults: defaults,
                                                       fdaProber: prober,
                                                       notifier: notifier)
        return OnboardingFlowModel(coordinator: coordinator,
                                    fdaProber: prober,
                                    notifier: notifier,
                                    defaults: defaults,
                                    onFinish: finished)
    }

    // MARK: - Step progression — Intro → Notifications → FDA

    func testGetStartedAdvancesToNotifications() {
        let model = makeModel(prober: FakeFullDiskAccessProber(.denied),
                              notifier: FakeSystemNotifier(),
                              defaults: freshDefaults())
        XCTAssertEqual(model.step, .intro)
        model.tapGetStarted()
        XCTAssertEqual(model.step, .notifications)
    }

    func testAllowNotificationsAdvancesToFDA() async {
        let notifier = FakeSystemNotifier()
        await notifier.setAuthState(.notDetermined)
        let model = makeModel(prober: FakeFullDiskAccessProber(.denied),
                              notifier: notifier,
                              defaults: freshDefaults())
        model.tapGetStarted()
        await model.tapAllowNotifications()
        XCTAssertEqual(model.step, .fullDiskAccess)
        let requestCount = await notifier.authRequestCount
        XCTAssertEqual(requestCount, 1, "Allow must invoke the notification request")
    }

    func testSkipNotificationsAdvancesToFDAWithoutRequesting() async {
        let notifier = FakeSystemNotifier()
        let model = makeModel(prober: FakeFullDiskAccessProber(.denied),
                              notifier: notifier,
                              defaults: freshDefaults())
        model.tapGetStarted()
        model.tapSkipNotifications()
        XCTAssertEqual(model.step, .fullDiskAccess)
        let requestCount = await notifier.authRequestCount
        XCTAssertEqual(requestCount, 0, "Skip must NOT invoke the notification request")
    }

    // MARK: - FDA — denied loops, granted completes, skip completes

    func testFDADeniedStaysWithError() async {
        let prober = FakeFullDiskAccessProber(.denied)
        let defaults = freshDefaults()
        let model = makeModel(prober: prober,
                              notifier: FakeSystemNotifier(),
                              defaults: defaults)
        model.tapGetStarted()
        model.tapSkipNotifications()  // get to FDA quickly
        await model.tapIveGrantedFDA()
        XCTAssertEqual(model.step, .fullDiskAccess)
        XCTAssertNotNil(model.fdaError, "denied probe should surface an inline error")
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.hasCompletedOnboarding))
    }

    func testFDADeniedThenGrantedCompletes() async {
        let prober = FakeFullDiskAccessProber(.denied)
        let defaults = freshDefaults()
        var finishCount = 0
        let model = makeModel(prober: prober,
                              notifier: FakeSystemNotifier(),
                              defaults: defaults,
                              finished: { finishCount += 1 })

        model.tapGetStarted()
        model.tapSkipNotifications()  // get to FDA quickly
        XCTAssertEqual(model.step, .fullDiskAccess)

        // Queue: [.denied (initial), .granted]
        await prober.enqueue(.granted)

        await model.tapIveGrantedFDA()
        XCTAssertEqual(model.step, .fullDiskAccess)
        XCTAssertNotNil(model.fdaError)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.hasCompletedOnboarding))

        // User flips the toggle, taps again — prober returns .granted → completes.
        await model.tapIveGrantedFDA()
        XCTAssertNil(model.fdaError, "granted probe should clear the error")
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.hasCompletedOnboarding),
                      "granted FDA must complete onboarding")
        XCTAssertEqual(finishCount, 1)
    }

    func testFDAUnknownStateStays() async {
        let prober = FakeFullDiskAccessProber(.unknown)
        let defaults = freshDefaults()
        let model = makeModel(prober: prober,
                              notifier: FakeSystemNotifier(),
                              defaults: defaults)
        model.tapGetStarted()
        model.tapSkipNotifications()
        await model.tapIveGrantedFDA()
        XCTAssertEqual(model.step, .fullDiskAccess,
                       ".unknown should be treated as not-yet-granted")
        XCTAssertNotNil(model.fdaError)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.hasCompletedOnboarding))
    }

    func testFDASkipCompletes() {
        let defaults = freshDefaults()
        var finishCount = 0
        let model = makeModel(prober: FakeFullDiskAccessProber(.denied),
                              notifier: FakeSystemNotifier(),
                              defaults: defaults,
                              finished: { finishCount += 1 })
        model.tapGetStarted()
        model.tapSkipNotifications()
        XCTAssertEqual(model.step, .fullDiskAccess)
        model.tapSkipFDA()
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.hasCompletedOnboarding),
                      "Skip from FDA must flip hasCompletedOnboarding=true")
        XCTAssertEqual(finishCount, 1)
    }
}

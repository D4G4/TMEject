#if DEBUG
import Foundation
import SwiftUI

// MARK: - Preview-only fakes
//
// SwiftUI previews compile into the production target — the test-target fakes
// (TMEjectTests/Fakes/*.swift) aren't reachable from a #Preview block. These
// minimal stand-ins exist so previews can spin up an `AppCoordinator` /
// `OnboardingFlowModel` without touching Live system services
// (`SMAppService.register`, `UNUserNotificationCenter`, tmutil's actual binary).
//
// DEBUG-gated so they're stripped from release builds.

/// No-op login item manager. Returns whatever status the preview supplies; never
/// touches `SMAppService`.
struct PreviewLoginItemManager: LoginItemManaging {
    let status: LoginItemStatus
    init(_ status: LoginItemStatus = .enabled) { self.status = status }
    func currentStatus() -> LoginItemStatus { status }
    func register() throws {}
    func unregister() throws {}
}

/// No-op notifier — `requestAuthorizationIfNeeded` honours the configured grant
/// outcome but never talks to UN.
actor PreviewSystemNotifier: SystemNotifier {
    private var authState: NotificationAuthState
    private let grantOnRequest: Bool

    init(authState: NotificationAuthState = .notDetermined,
         grantOnRequest: Bool = true) {
        self.authState = authState
        self.grantOnRequest = grantOnRequest
    }

    func currentAuthState() async -> NotificationAuthState { authState }
    func requestAuthorizationIfNeeded() async -> Bool {
        if authState == .notDetermined {
            authState = grantOnRequest ? .authorized : .denied
        }
        return authState == .authorized || authState == .provisional || authState == .ephemeral
    }
    func deliver(title: String, body: String, category: NotificationCategory) async {}
}

/// FDA prober that returns the supplied state for every probe.
actor PreviewFullDiskAccessProber: FullDiskAccessProbing {
    private let state: FDAState
    init(_ state: FDAState = .granted) { self.state = state }
    func currentState() async -> FDAState { state }
}

// MARK: - AppCoordinator factory

extension AppCoordinator {
    /// Build an `AppCoordinator` wired up for SwiftUI previews. All Live deps that
    /// would otherwise reach for the system (login item registration, UN auth, FDA
    /// probe via tmutil) are replaced with inert preview-only fakes; UserDefaults
    /// gets a fresh in-memory suite so the preview can't poison the real prefs.
    @MainActor
    static func preview(
        state: AppState = .idle,
        backupPct: Double = 0,
        ejectPct: Double = 0,
        ejectAttempt: Int = 0,
        drivePresent: Bool = true,
        driveName: String? = "Backup Drive",
        lastError: String? = nil,
        ritualConfirmPct: Double? = nil,
        loginItemStatus: LoginItemStatus = .enabled,
        fdaState: FDAState = .granted,
        autoEjectEnabled: Bool = true,
        translucentSurfaces: Bool = false,
        hasCompletedOnboarding: Bool = true
    ) -> AppCoordinator {
        let defaults = UserDefaults(suiteName: "preview.\(UUID().uuidString)")!
        defaults.set(autoEjectEnabled, forKey: SettingsKey.autoEjectEnabled)
        defaults.set(translucentSurfaces, forKey: SettingsKey.translucentSurfaces)
        defaults.set(hasCompletedOnboarding, forKey: SettingsKey.hasCompletedOnboarding)
        defaults.set(true, forKey: SettingsKey.toastsEnabled)
        defaults.set(30, forKey: SettingsKey.cooldownMinutes)
        let coord = AppCoordinator(
            defaults: defaults,
            notifier: PreviewSystemNotifier(),
            loginItem: PreviewLoginItemManager(loginItemStatus),
            fdaProber: PreviewFullDiskAccessProber(fdaState)
        )
        coord.applySnapshotState(
            state: state,
            backupPct: backupPct,
            ejectPct: ejectPct,
            ejectAttempt: ejectAttempt,
            drivePresent: drivePresent,
            driveName: driveName,
            lastError: lastError,
            ritualConfirmPct: ritualConfirmPct,
            loginItemStatus: loginItemStatus,
            fdaState: fdaState
        )
        return coord
    }
}

// MARK: - OnboardingFlowModel factory

extension OnboardingFlowModel {
    /// Build an `OnboardingFlowModel` wired up for SwiftUI previews. Defaults to a
    /// denied → granted FDA prober so the "I've granted it" tap can flow through;
    /// `openURL` and `onFinish` are inert no-ops.
    @MainActor
    static func preview(
        fdaState: FDAState = .denied,
        notifierGrants: Bool = true
    ) -> OnboardingFlowModel {
        let coord = AppCoordinator.preview(fdaState: fdaState)
        return OnboardingFlowModel(
            coordinator: coord,
            fdaProber: PreviewFullDiskAccessProber(fdaState),
            notifier: PreviewSystemNotifier(grantOnRequest: notifierGrants),
            openURL: { _ in },
            onFinish: {}
        )
    }
}
#endif

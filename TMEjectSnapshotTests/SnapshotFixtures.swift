import Foundation
@testable import TMEject

/// Shared fixture builder for snapshot tests. Each surface picks the @Published values it
/// wants via `apply` — eliminates per-test boilerplate.
@MainActor
enum SnapshotFixtures {
    static func makeCoordinator() -> AppCoordinator {
        // A unique UserDefaults suite per coord prevents cross-test bleed.
        let suite = UserDefaults(suiteName: "snapshot-\(UUID().uuidString)")!
        return AppCoordinator(
            tmutil: NullTMUtil(),
            ejector: Ejector(unmount: NullUnmount(), lsof: NullLsof(),
                             clock: ZeroClock(),
                             schedule: EjectorRetrySchedule(backoffsSeconds: [0])),
            resolver: DestinationResolver(bridge: NullBridge()),
            defaults: suite,
            locker: NullLocker(),
            confirmDialog: NullConfirm(),
            clock: ZeroClock(),
            notifier: NullNotifier(),
            toastPresenter: nil,
            loginItem: NullLoginItem(),
            fdaProber: NullFDAProber()
        )
    }
}

// MARK: - Null fakes
// These never get exercised in snapshot tests — the coordinator is built only so its
// @Published values can be set via applySnapshotState. We don't need any real fake behavior.

private struct NullTMUtil: TMUtilClient {
    func status() async throws -> StatusPlist { StatusPlist(running: false) }
    func destinationInfo() async throws -> [DestinationInfo] { [] }
    func latestBackup() async throws -> URL? { nil }
    func stopBackup() async throws {}
    func latestBackupRaw() async -> TMUtilRawResult { TMUtilRawResult(stdout: "", stderr: "", exitCode: 0) }
}
private struct NullUnmount: UnmountBridge {
    func unmountVolume(at url: URL) async -> DAUnmountResult { .success }
}
private struct NullLsof: LsofProbe {
    func holdersOf(volumePath: String) async -> [LsofHolder] { [] }
}
private struct NullBridge: DiskArbitrationBridge {
    func mountedVolumeURLs() -> [URL] { [] }
    func description(forVolumeAt url: URL) -> VolumeDADescription? { nil }
}
private struct NullLocker: ScreenLocker {
    func lockScreen() async -> Result<Void, ScreenLockError> { .success(()) }
}
private struct NullConfirm: ConfirmDialog {
    func confirmStopAndEject() async -> Bool { false }
}
private struct NullNotifier: SystemNotifier {
    func currentAuthState() async -> NotificationAuthState { .notDetermined }
    func requestAuthorizationIfNeeded() async -> Bool { false }
    func deliver(title: String, body: String, category: NotificationCategory) async {}
}
private struct NullLoginItem: LoginItemManaging {
    func currentStatus() -> LoginItemStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}
private struct NullFDAProber: FullDiskAccessProbing {
    func currentState() async -> FDAState { .granted }
}
private struct ZeroClock: MonotonicClock {
    func now() -> TimeInterval { 0 }
    func sleep(seconds: TimeInterval) async throws {}
}

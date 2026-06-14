import XCTest
@testable import TMEject

// These tests cover the coordinator-level "Eject & Lock" orchestration. Lower layers
// (Ejector retries, DA unmount, state machine guard) are covered in their own suites.

@MainActor
final class EjectAndLockTests: XCTestCase {

    private let backupUUID = UUID(uuidString: "0852943E-8EC2-4386-8C31-ECE56488E8B4")!

    private func makeCoordinator(
        tmutil: FakeTMUtilClient,
        confirm: FakeConfirmDialog,
        locker: FakeScreenLocker,
        clock: FakeClock,
        unmount: FakeUnmountBridge
    ) -> AppCoordinator {
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (URL(fileURLWithPath: "/Volumes/Backup"),
             VolumeDADescription(volumeUUID: backupUUID, bsdName: "disk4s2", volumeName: "Backup"))
        ])
        let resolver = DestinationResolver(bridge: bridge)
        let ejector = Ejector(
            unmount: unmount,
            lsof: FakeLsofProbe(),
            clock: clock,
            schedule: EjectorRetrySchedule(backoffsSeconds: [0])
        )
        return AppCoordinator(
            tmutil: tmutil,
            ejector: ejector,
            resolver: resolver,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            locker: locker,
            confirmDialog: confirm,
            clock: clock
        )
    }

    // The .ejecting guard at the coordinator level — even if the menu's disabled flag is
    // bypassed (e.g. by hotkey), runEjectAndLock must not prompt or lock when state is .ejecting.
    func testEjectAndLockIgnoredInEjecting() async {
        let tmutil = FakeTMUtilClient()
        let confirm = FakeConfirmDialog()
        let locker = FakeScreenLocker()
        // Use an unmount bridge that never returns — keeps the ejector spinning so state
        // stays .ejecting for the duration of the test.
        let unmount = FakeUnmountBridge()
        await unmount.setHangForever()
        let clock = FakeClock()
        let coord = makeCoordinator(tmutil: tmutil, confirm: confirm,
                                    locker: locker, clock: clock,
                                    unmount: unmount)
        await tmutil.enqueueDestinationInfo(.success([
            DestinationInfo(id: backupUUID, name: "Backup", kind: "Local", lastDestination: true)
        ]))
        // Drive into .ejecting via direct event delivery on a background Task — the call
        // would otherwise hang inside the unmount bridge's 5s sleep.
        let task = Task { await coord.deliverForTesting(.ejectRequested(lock: false, source: .manual)) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coord.state, .ejecting)
        coord.requestEjectAndLock()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let presented = await confirm.presentCount
        let locked = await locker.lockCount
        XCTAssertEqual(presented, 0, "must not even prompt in .ejecting")
        XCTAssertEqual(locked, 0)
        task.cancel()
    }

    func testEjectAndLockFromIdle_LocksOnSuccess() async {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueDestinationInfo(.success([
            DestinationInfo(id: backupUUID, name: "Backup", kind: "Local", lastDestination: true)
        ]))
        let unmount = FakeUnmountBridge()
        await unmount.enqueue(.success)
        let confirm = FakeConfirmDialog()
        let locker = FakeScreenLocker()
        let coord = makeCoordinator(tmutil: tmutil, confirm: confirm,
                                    locker: locker, clock: FakeClock(),
                                    unmount: unmount)
        coord.requestEjectAndLock()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let locked = await locker.lockCount
        let prompts = await confirm.presentCount
        XCTAssertEqual(prompts, 0, "no confirmation needed when not backing up")
        XCTAssertEqual(locked, 1, "screen should lock after successful eject")
        XCTAssertEqual(coord.state, .idle)
    }

    func testEjectAndLockFromBackingUp_PromptCancelled_NoStopNoEjectNoLock() async {
        let tmutil = FakeTMUtilClient()
        let confirm = FakeConfirmDialog()
        await confirm.setAnswer(false)
        let locker = FakeScreenLocker()
        let unmount = FakeUnmountBridge()
        let coord = makeCoordinator(tmutil: tmutil, confirm: confirm,
                                    locker: locker, clock: FakeClock(),
                                    unmount: unmount)
        await coord.deliverForTesting(.backupBegan(baselineLatestBackupPath: nil, baselineProbeFailed: false))
        XCTAssertEqual(coord.state, .backingUp)
        coord.requestEjectAndLock()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let stops = await tmutil.stopBackupCallCount
        let unmounts = await unmount.callCount
        let locks = await locker.lockCount
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(unmounts, 0)
        XCTAssertEqual(locks, 0)
        XCTAssertEqual(coord.state, .backingUp)
    }

    func testEjectAndLockFromBackingUp_PromptConfirmed_StopsThenEjectsThenLocks() async {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueDestinationInfo(.success([
            DestinationInfo(id: backupUUID, name: "Backup", kind: "Local", lastDestination: true)
        ]))
        // waitForBackupToStop polls; first call says still running, second says stopped.
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying")))
        await tmutil.enqueueStatus(.success(StatusPlist(running: false, backupPhase: nil)))
        let confirm = FakeConfirmDialog()
        await confirm.setAnswer(true)
        let locker = FakeScreenLocker()
        let unmount = FakeUnmountBridge()
        await unmount.enqueue(.success)
        let clock = FakeClock()
        let coord = makeCoordinator(tmutil: tmutil, confirm: confirm,
                                    locker: locker, clock: clock,
                                    unmount: unmount)
        await coord.deliverForTesting(.backupBegan(baselineLatestBackupPath: nil, baselineProbeFailed: false))
        // FakeClock.sleep is near-instant (1ms) so waitForBackupToStop loops quickly.
        coord.requestEjectAndLock()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let stops = await tmutil.stopBackupCallCount
        let unmounts = await unmount.callCount
        let locks = await locker.lockCount
        XCTAssertEqual(stops, 1, "tmutil stopbackup should run exactly once")
        XCTAssertGreaterThanOrEqual(unmounts, 1)
        XCTAssertEqual(locks, 1, "lock fires after eject succeeds")
        XCTAssertEqual(coord.state, .idle)
    }

    func testEjectAndLock_StopBackupFails_LastErrorSetNoLock() async {
        let tmutil = FakeTMUtilClient()
        await tmutil.setStopBackupError(TMUtilError.nonZeroExit(code: 1, stderr: "no auth"))
        let confirm = FakeConfirmDialog()
        await confirm.setAnswer(true)
        let locker = FakeScreenLocker()
        let unmount = FakeUnmountBridge()
        let coord = makeCoordinator(tmutil: tmutil, confirm: confirm,
                                    locker: locker, clock: FakeClock(),
                                    unmount: unmount)
        await coord.deliverForTesting(.backupBegan(baselineLatestBackupPath: nil, baselineProbeFailed: false))
        coord.requestEjectAndLock()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let locks = await locker.lockCount
        let unmounts = await unmount.callCount
        XCTAssertEqual(locks, 0, "lock must not fire when stopbackup failed")
        XCTAssertEqual(unmounts, 0)
        XCTAssertNotNil(coord.lastError)
        XCTAssertTrue(coord.lastError?.contains("stopbackup failed") == true)
    }

    func testEjectAndLock_EjectBusyAllRetries_LockNotFired() async {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueDestinationInfo(.success([
            DestinationInfo(id: backupUUID, name: "Backup", kind: "Local", lastDestination: true)
        ]))
        let unmount = FakeUnmountBridge()
        await unmount.enqueue(.busy(message: "busy"))
        let confirm = FakeConfirmDialog()
        let locker = FakeScreenLocker()
        let coord = makeCoordinator(tmutil: tmutil, confirm: confirm,
                                    locker: locker, clock: FakeClock(),
                                    unmount: unmount)
        coord.requestEjectAndLock()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let locks = await locker.lockCount
        XCTAssertEqual(locks, 0, "no lock on failed eject")
        XCTAssertEqual(coord.state, .idleEjectFailed)
    }

    func testEjectAndLockAllowance_DisabledOnlyInEjecting() async {
        // Coordinator's allowance is a pure function of state: enabled in every state
        // except .ejecting. Verify against the static probe StateMachine has for the menu.
        let tmutil = FakeTMUtilClient()
        // Use a busy bridge so .ejecting state is held for the assertion window.
        let unmount = FakeUnmountBridge()
        await unmount.enqueue(.busy(message: "held"))
        await tmutil.enqueueDestinationInfo(.success([
            DestinationInfo(id: backupUUID, name: "Backup", kind: "Local", lastDestination: true)
        ]))

        let coord = makeCoordinator(tmutil: tmutil, confirm: FakeConfirmDialog(),
                                    locker: FakeScreenLocker(), clock: FakeClock(),
                                    unmount: unmount)
        XCTAssertTrue(coord.isEjectAndLockAllowed)              // .idle
        await coord.deliverForTesting(.backupBegan(baselineLatestBackupPath: nil, baselineProbeFailed: false))
        XCTAssertTrue(coord.isEjectAndLockAllowed)              // .backingUp — enabled (with prompt)
        await coord.deliverForTesting(.confirmingEntered(latestBackupPath: nil, entryProbeFailed: false))
        XCTAssertTrue(coord.isEjectAndLockAllowed)              // .confirming — enabled (with prompt)

        let hungBridge = FakeUnmountBridge()
        await hungBridge.setHangForever()
        await tmutil.enqueueDestinationInfo(.success([
            DestinationInfo(id: backupUUID, name: "Backup", kind: "Local", lastDestination: true)
        ]))
        let coord2 = makeCoordinator(tmutil: tmutil, confirm: FakeConfirmDialog(),
                                     locker: FakeScreenLocker(), clock: FakeClock(),
                                     unmount: hungBridge)
        let task = Task { await coord2.deliverForTesting(.ejectRequested(lock: false, source: .manual)) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coord2.state, .ejecting)
        XCTAssertFalse(coord2.isEjectAndLockAllowed)            // .ejecting — disabled
        task.cancel()
    }
}

// Test seam: expose the private deliver(_:) so tests can drive the state machine without
// having to fake the full observer chain.
@MainActor
extension AppCoordinator {
    func deliverForTesting(_ event: AppEvent) async {
        await self.deliverFromTest(event)
    }
}

import XCTest
@testable import TMEject

final class BackupPhaseTests: XCTestCase {
    func testEmptyAndNilArePreCopy() {
        XCTAssertEqual(BackupPhaseKind.classify(nil), .preCopy)
        XCTAssertEqual(BackupPhaseKind.classify(""), .preCopy)
    }

    func testKnownPreCopyPhases() {
        for s in ["Starting", "FindingChanges", "FindingChangesInLocalSnapshot",
                  "PreparingSourceVolumes", "Preparing", "MountingBackupVol", "ThinningPreBackup"] {
            XCTAssertEqual(BackupPhaseKind.classify(s), .preCopy, "for \(s)")
        }
    }

    func testCopying() {
        XCTAssertEqual(BackupPhaseKind.classify("Copying"), .copying)
    }

    func testConfirmingSet() {
        for s in ["Finishing", "ThinningPostBackup", "Confirming"] {
            XCTAssertTrue(BackupPhaseKind.classify(s).isConfirming, "for \(s)")
        }
    }

    func testUnknownPhaseDoesNotCountAsConfirming() {
        let kind = BackupPhaseKind.classify("FutureMacOSPhaseName")
        if case .unknown(let raw) = kind {
            XCTAssertEqual(raw, "FutureMacOSPhaseName")
        } else {
            XCTFail("expected .unknown, got \(kind)")
        }
        XCTAssertFalse(kind.isConfirming)
    }
}

final class PollingObserverTests: XCTestCase {

    actor EventBox {
        var events: [AppEvent] = []
        func append(_ e: AppEvent) { events.append(e) }
        func snapshot() -> [AppEvent] { events }
    }

    private func makeObserver(
        tmutil: FakeTMUtilClient,
        clock: FakeClock,
        box: EventBox
    ) -> PollingObserver {
        PollingObserver(tmutil: tmutil, clock: clock, emit: { event in
            await box.append(event)
        })
    }

    func testIdlePollEmitsNothing() async throws {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: false)))
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: FakeClock(), box: box)
        await observer.runOnce()
        let events = await box.snapshot()
        XCTAssertTrue(events.isEmpty, "idle poll emits nothing, got \(events)")
    }

    func testIdleToBackingUpEmitsBackupBegan() async throws {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying", rawTotalBytes: 1000)))
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: FakeClock(), box: box)
        await observer.runOnce()
        let events = await box.snapshot()
        XCTAssertEqual(events, [.backupBegan])
    }

    func testEnteringConfirmingFromCopyingEmitsConfirmingEnteredWithSnapshot() async throws {
        let snap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-11-100000")
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying", rawTotalBytes: 1000)))
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing", rawTotalBytes: 2000)))
        await tmutil.enqueueLatestBackup(.success(snap))
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: FakeClock(), box: box)
        await observer.runOnce()
        await observer.runOnce()
        let events = await box.snapshot()
        XCTAssertEqual(events, [
            .backupBegan,
            .confirmingEntered(latestBackupPath: snap, entryProbeFailed: false)
        ])
    }

    // H2: tmutil latestbackup throws at confirming-entry → observer must mark probe failed,
    // not silently swallow it as nil.
    func testEnteringConfirmingPropagatesLatestbackupFailure() async throws {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        await tmutil.enqueueLatestBackup(.failure(TMUtilError.latestBackupUnavailable(stderr: "no mount")))
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: FakeClock(), box: box)
        await observer.runOnce()
        let events = await box.snapshot()
        XCTAssertEqual(events, [.confirmingEntered(latestBackupPath: nil, entryProbeFailed: true)])
    }

    func testExitConfirmingEmitsConfirmingExitedWithNewSnapshot() async throws {
        let oldSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-11-100000")
        let newSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-11-110000")
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        await tmutil.enqueueLatestBackup(.success(oldSnap))
        await tmutil.enqueueStatus(.success(StatusPlist(running: false, backupPhase: nil)))
        await tmutil.enqueueLatestBackup(.success(newSnap))
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: FakeClock(), box: box)
        await observer.runOnce()
        await observer.runOnce()
        let events = await box.snapshot()
        XCTAssertEqual(events, [
            .confirmingEntered(latestBackupPath: oldSnap, entryProbeFailed: false),
            .confirmingExited(newLatestBackupPath: newSnap, exitProbeFailed: false)
        ])
    }

    func testExitConfirmingPropagatesExitProbeFailure() async throws {
        let oldSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-11-100000")
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        await tmutil.enqueueLatestBackup(.success(oldSnap))
        await tmutil.enqueueStatus(.success(StatusPlist(running: false, backupPhase: nil)))
        await tmutil.enqueueLatestBackup(.failure(TMUtilError.latestBackupUnavailable(stderr: "vanished")))
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: FakeClock(), box: box)
        await observer.runOnce()
        await observer.runOnce()
        let events = await box.snapshot()
        XCTAssertEqual(events, [
            .confirmingEntered(latestBackupPath: oldSnap, entryProbeFailed: false),
            .confirmingExited(newLatestBackupPath: nil, exitProbeFailed: true)
        ])
    }

    func testBackingUpToStopped_NotInConfirming_EmitsBackupStopped() async throws {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying", rawTotalBytes: 1000)))
        await tmutil.enqueueStatus(.success(StatusPlist(running: false, backupPhase: nil)))
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: FakeClock(), box: box)
        await observer.runOnce()
        await observer.runOnce()
        let events = await box.snapshot()
        XCTAssertEqual(events, [.backupBegan, .backupStopped])
    }

    // M5: stall detector is inactive until setStallTracking(active: true) is called.
    func testStallDetectionInactiveByDefault() async throws {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying", rawTotalBytes: 1000)))
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying", rawTotalBytes: 1000)))
        let clock = FakeClock()
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: clock, box: box)
        await observer.runOnce()           // backupBegan
        await clock.tick(11 * 60)
        await observer.runOnce()           // no stall — tracking never activated
        let events = await box.snapshot()
        XCTAssertEqual(events, [.backupBegan])
    }

    func testStallDetectionFiresAfter10MinWhenActive() async throws {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying", rawTotalBytes: 1000)))
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying", rawTotalBytes: 1000)))
        let clock = FakeClock()
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: clock, box: box)
        await observer.setStallTracking(active: true)
        await observer.runOnce()           // backupBegan, baseline byte count + timestamp
        await clock.tick(11 * 60)
        await observer.runOnce()           // bytes unchanged 11min → stall
        let events = await box.snapshot()
        XCTAssertEqual(events, [.backupBegan, .stallDetected])
    }

    // M5: confirming hard cap inactive until setConfirmingTracking(active: true) is called.
    func testConfirmingCapInactiveByDefault() async throws {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        await tmutil.enqueueLatestBackup(.success(nil))
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        let clock = FakeClock()
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: clock, box: box)
        await observer.runOnce()              // confirmingEntered emitted, but cap not active
        await clock.tick(5 * 60 * 60)
        await observer.runOnce()
        let events = await box.snapshot()
        XCTAssertEqual(events, [.confirmingEntered(latestBackupPath: nil, entryProbeFailed: false)])
    }

    func testConfirmingCapFiresAfter4hWhenActive() async throws {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        await tmutil.enqueueLatestBackup(.success(nil))
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        let clock = FakeClock()
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: clock, box: box)
        await observer.setConfirmingTracking(active: true)   // started at t=0
        await observer.runOnce()
        await clock.tick(2 * 60 * 60)
        await observer.runOnce()
        await clock.tick(2 * 60 * 60 + 60)
        await observer.runOnce()
        let events = await box.snapshot()
        XCTAssertEqual(events, [
            .confirmingEntered(latestBackupPath: nil, entryProbeFailed: false),
            .confirmingTimedOut
        ])
    }

    func testUnknownPhaseDoesNotEmitConfirmingEntered() async throws {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying")))
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "FutureMacOSPhase")))
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: FakeClock(), box: box)
        await observer.runOnce()
        await observer.runOnce()
        let events = await box.snapshot()
        XCTAssertEqual(events, [.backupBegan])
    }
}

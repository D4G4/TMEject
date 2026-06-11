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

    // Collect events emitted by the observer for assertions.
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
        await observer.runOnce()  // running, copying → backupBegan
        await observer.runOnce()  // → confirmingEntered
        let events = await box.snapshot()
        XCTAssertEqual(events, [.backupBegan, .confirmingEntered(latestBackupPath: snap)])
    }

    func testTMEjectLaunchedMidConfirmingEmitsConfirmingEnteredOnFirstPoll() async throws {
        let snap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-11-100000")
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        await tmutil.enqueueLatestBackup(.success(snap))
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: FakeClock(), box: box)
        await observer.runOnce()
        let events = await box.snapshot()
        // No baseline silence: a confirming-phase backup at launch is reacted to, not missed.
        XCTAssertEqual(events, [.confirmingEntered(latestBackupPath: snap)])
    }

    func testExitConfirmingEmitsConfirmingExitedWithNewSnapshot() async throws {
        let oldSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-11-100000")
        let newSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-11-110000")
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        await tmutil.enqueueLatestBackup(.success(oldSnap))     // entry capture
        await tmutil.enqueueStatus(.success(StatusPlist(running: false, backupPhase: nil)))
        await tmutil.enqueueLatestBackup(.success(newSnap))     // exit capture
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: FakeClock(), box: box)
        await observer.runOnce()  // → confirmingEntered(oldSnap)
        await observer.runOnce()  // → confirmingExited(newSnap)
        let events = await box.snapshot()
        XCTAssertEqual(events, [
            .confirmingEntered(latestBackupPath: oldSnap),
            .confirmingExited(newLatestBackupPath: newSnap)
        ])
    }

    func testBackingUpToStopped_NotInConfirming_EmitsBackupStopped() async throws {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying", rawTotalBytes: 1000)))
        await tmutil.enqueueStatus(.success(StatusPlist(running: false, backupPhase: nil)))
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: FakeClock(), box: box)
        await observer.runOnce()  // backupBegan
        await observer.runOnce()  // running=false, never reached confirming → backupStopped
        let events = await box.snapshot()
        XCTAssertEqual(events, [.backupBegan, .backupStopped])
    }

    func testStallDetectionAfter10MinUnchanged() async throws {
        let tmutil = FakeTMUtilClient()
        // Two polls with totalBytes pinned at 1000; clock advances 11 min between them → stall.
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying", rawTotalBytes: 1000)))
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying", rawTotalBytes: 1000)))
        let clock = FakeClock()
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: clock, box: box)
        await observer.runOnce()                    // backupBegan, totalBytesUnchangedSince=0
        await clock.tick(11 * 60)
        await observer.runOnce()                    // 11min elapsed, bytes unchanged → stallDetected
        let events = await box.snapshot()
        XCTAssertEqual(events, [.backupBegan, .stallDetected])
    }

    func testConfirmingHardCapAfter4h() async throws {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        await tmutil.enqueueLatestBackup(.success(nil))         // confirmingEntered snapshot
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Finishing")))
        let clock = FakeClock()
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: clock, box: box)
        await observer.runOnce()  // confirmingEntered, hard-cap starts at t=0
        await clock.tick(2 * 60 * 60)
        await observer.runOnce()  // 2h — no event
        await clock.tick(2 * 60 * 60 + 60)
        await observer.runOnce()  // > 4h → timeout
        let events = await box.snapshot()
        XCTAssertEqual(events, [
            .confirmingEntered(latestBackupPath: nil),
            .confirmingTimedOut
        ])
    }

    func testUnknownPhaseDoesNotEmitConfirmingEntered() async throws {
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "Copying")))
        await tmutil.enqueueStatus(.success(StatusPlist(running: true, backupPhase: "FutureMacOSPhase")))
        let box = EventBox()
        let observer = makeObserver(tmutil: tmutil, clock: FakeClock(), box: box)
        await observer.runOnce()  // backupBegan
        await observer.runOnce()  // phase changes to unknown — must not emit confirmingEntered
        let events = await box.snapshot()
        XCTAssertEqual(events, [.backupBegan])
    }
}

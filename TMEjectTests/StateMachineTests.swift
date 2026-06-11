import XCTest
@testable import TMEject

final class StateMachineTests: XCTestCase {

    // MARK: - Helpers

    private func sm(_ state: AppState, preConfirm: URL? = nil) -> StateMachine {
        StateMachine(state: state, preConfirmLatestBackup: preConfirm)
    }

    private func accept(_ outcome: GuardOutcome) -> [AppCommand]? {
        if case .accepted(let cs) = outcome { return cs } else { return nil }
    }

    private func ignored(_ outcome: GuardOutcome) -> Bool {
        if case .ignored = outcome { return true } else { return false }
    }

    // MARK: - Guard table (one cell per row at minimum)

    func testWakeSignalAcceptedInIdleAndFailed_IgnoredElsewhere() {
        for s in [AppState.idle, .idleEjectFailed] {
            var m = sm(s)
            XCTAssertEqual(accept(m.handle(.wakeSignal)), [.requestPoll])
            XCTAssertEqual(m.state, s)
        }
        for s in [AppState.backingUp, .confirming, .ejecting] {
            var m = sm(s)
            XCTAssertTrue(ignored(m.handle(.wakeSignal)), "wakeSignal should be ignored in \(s)")
            XCTAssertEqual(m.state, s)
        }
    }

    func testBackupBeganMovesIdleToBackingUp() {
        var m = sm(.idle)
        let cmds = accept(m.handle(.backupBegan))
        XCTAssertEqual(m.state, .backingUp)
        XCTAssertEqual(cmds, [
            .setLastError(nil),
            .startStallTimer,
            .showToast(level: .info, message: "Backup started")
        ])
    }

    func testBackupBeganIgnoredInBackingUpConfirmingEjecting() {
        for s in [AppState.backingUp, .confirming, .ejecting] {
            var m = sm(s)
            XCTAssertTrue(ignored(m.handle(.backupBegan)))
            XCTAssertEqual(m.state, s)
        }
    }

    func testConfirmingEnteredRecordsPathAndTransitions() {
        let snap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        for from in [AppState.idle, .idleEjectFailed, .backingUp] {
            var m = sm(from)
            let cmds = accept(m.handle(.confirmingEntered(latestBackupPath: snap)))
            XCTAssertEqual(m.state, .confirming, "from \(from)")
            XCTAssertEqual(m.preConfirmLatestBackup, snap, "from \(from)")
            XCTAssertEqual(cmds, [
                .recordPreConfirmLatestBackup(snap),
                .stopStallTimer,
                .startConfirmingTimer
            ])
        }
    }

    func testConfirmingExitedAdvancedPathCountsAsSuccess() {
        let oldSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        let newSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-110000")
        var m = sm(.confirming, preConfirm: oldSnap)
        let cmds = accept(m.handle(.confirmingExited(newLatestBackupPath: newSnap))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.preConfirmLatestBackup)
        XCTAssertTrue(cmds.contains(.stopConfirmingTimer))
        XCTAssertTrue(cmds.contains(.clearPreConfirmLatestBackup))
        XCTAssertTrue(cmds.contains(.attemptAutoEjectIfAllowed))
        XCTAssertTrue(cmds.contains(where: { if case .notify(let t, _) = $0 { return t == "Backup complete" }; return false }))
    }

    func testConfirmingExitedSamePathCountsAsCancellation() {
        let snap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        var m = sm(.confirming, preConfirm: snap)
        let cmds = accept(m.handle(.confirmingExited(newLatestBackupPath: snap))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(cmds.contains(.attemptAutoEjectIfAllowed))
        XCTAssertTrue(cmds.contains(where: { if case .showToast(_, let msg) = $0 { return msg.contains("without a new snapshot") }; return false }))
    }

    func testConfirmingExitedFirstEverBackupCountsAsSuccess() {
        let newSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        var m = sm(.confirming, preConfirm: nil)
        let cmds = accept(m.handle(.confirmingExited(newLatestBackupPath: newSnap))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(cmds.contains(.attemptAutoEjectIfAllowed))
    }

    func testConfirmingExitedIgnoredOutsideConfirming() {
        for s in [AppState.idle, .idleEjectFailed, .backingUp, .ejecting] {
            var m = sm(s)
            XCTAssertTrue(ignored(m.handle(.confirmingExited(newLatestBackupPath: nil))), "from \(s)")
            XCTAssertEqual(m.state, s)
        }
    }

    func testBackupStoppedReturnsBackingUpToIdle() {
        var m = sm(.backingUp)
        let cmds = accept(m.handle(.backupStopped)) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(cmds.contains(.stopStallTimer))
        XCTAssertTrue(cmds.contains(where: { if case .showToast(_, let msg) = $0 { return msg == "Backup stopped" }; return false }))
    }

    func testBackupStoppedIgnoredInConfirmingAndEjecting() {
        for s in [AppState.confirming, .ejecting] {
            var m = sm(s)
            XCTAssertTrue(ignored(m.handle(.backupStopped)), "from \(s)")
            XCTAssertEqual(m.state, s)
        }
    }

    func testStallDetectedFromBackingUpResetsToIdleAndSetsError() {
        var m = sm(.backingUp)
        let cmds = accept(m.handle(.stallDetected)) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(cmds.contains(where: { if case .setLastError(let s) = $0 { return s?.contains("Stall") == true }; return false }))
    }

    func testStallDetectedIgnoredOutsideBackingUp() {
        for s in [AppState.idle, .idleEjectFailed, .confirming, .ejecting] {
            var m = sm(s)
            XCTAssertTrue(ignored(m.handle(.stallDetected)), "from \(s)")
        }
    }

    func testConfirmingTimeoutFromConfirmingResetsToIdle() {
        var m = sm(.confirming, preConfirm: URL(fileURLWithPath: "/snap"))
        let cmds = accept(m.handle(.confirmingTimedOut)) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.preConfirmLatestBackup)
        XCTAssertTrue(cmds.contains(.stopConfirmingTimer))
        XCTAssertTrue(cmds.contains(where: { if case .setLastError(let s) = $0 { return s?.contains("4h") == true }; return false }))
    }

    func testManualEjectAllowedOnlyInIdleAndFailed() {
        for s in [AppState.idle, .idleEjectFailed] {
            var m = sm(s)
            let cmds = accept(m.handle(.manualEjectRequested(lock: false))) ?? []
            XCTAssertEqual(m.state, .ejecting, "from \(s)")
            XCTAssertTrue(cmds.contains(.beginEject(lock: false)))
        }
        for s in [AppState.backingUp, .confirming, .ejecting] {
            var m = sm(s)
            XCTAssertTrue(ignored(m.handle(.manualEjectRequested(lock: false))), "from \(s)")
            XCTAssertEqual(m.state, s)
        }
    }

    func testManualEjectLockFlagPropagates() {
        var m = sm(.idle)
        let cmds = accept(m.handle(.manualEjectRequested(lock: true))) ?? []
        XCTAssertTrue(cmds.contains(.beginEject(lock: true)))
    }

    func testEjectSuccessReturnsToIdle() {
        var m = sm(.ejecting)
        let cmds = accept(m.handle(.ejectAttemptCompleted(success: true, errorSummary: nil))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(cmds.contains(.setLastError(nil)))
        XCTAssertTrue(cmds.contains(where: { if case .notify(let t, _) = $0 { return t == "Drive ejected" }; return false }))
    }

    func testEjectFailureGoesToIdleEjectFailedAndSetsLastError() {
        var m = sm(.ejecting)
        let cmds = accept(m.handle(.ejectAttemptCompleted(success: false, errorSummary: "busy: Spotlight"))) ?? []
        XCTAssertEqual(m.state, .idleEjectFailed)
        XCTAssertTrue(cmds.contains(.setLastError("busy: Spotlight")))
    }

    func testEjectCompletedIgnoredOutsideEjecting() {
        for s in [AppState.idle, .idleEjectFailed, .backingUp, .confirming] {
            var m = sm(s)
            XCTAssertTrue(ignored(m.handle(.ejectAttemptCompleted(success: true, errorSummary: nil))), "from \(s)")
        }
    }

    func testAppWillTerminateWarnsOnlyInEjecting() {
        for s in [AppState.idle, .idleEjectFailed, .backingUp, .confirming] {
            var m = sm(s)
            XCTAssertEqual(accept(m.handle(.appWillTerminate)), [], "from \(s)")
        }
        var ejecting = sm(.ejecting)
        XCTAssertEqual(accept(ejecting.handle(.appWillTerminate)), [.showQuitDuringEjectWarning])
    }

    // MARK: - Probe helpers used by the menu

    func testIsManualEjectAllowed_matchesGuardTable() {
        XCTAssertTrue(StateMachine.isManualEjectAllowed(in: .idle))
        XCTAssertTrue(StateMachine.isManualEjectAllowed(in: .idleEjectFailed))
        XCTAssertFalse(StateMachine.isManualEjectAllowed(in: .backingUp))
        XCTAssertFalse(StateMachine.isManualEjectAllowed(in: .confirming))
        XCTAssertFalse(StateMachine.isManualEjectAllowed(in: .ejecting))
    }

    func testIsAutoEjectToggleAllowed_isAlwaysTrue() {
        for s in [AppState.idle, .idleEjectFailed, .backingUp, .confirming, .ejecting] {
            XCTAssertTrue(StateMachine.isAutoEjectToggleAllowed(in: s), "for \(s)")
        }
    }

    // MARK: - Whole flows

    func testHappyPath_idleToEjectedViaSnapshotAdvance() {
        var m = sm(.idle)
        XCTAssertEqual(accept(m.handle(.backupBegan))?.first, .setLastError(nil))
        XCTAssertEqual(m.state, .backingUp)

        let oldSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        _ = m.handle(.confirmingEntered(latestBackupPath: oldSnap))
        XCTAssertEqual(m.state, .confirming)

        let newSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-110000")
        let exitCmds = accept(m.handle(.confirmingExited(newLatestBackupPath: newSnap))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(exitCmds.contains(.attemptAutoEjectIfAllowed))

        // Coordinator decides auto-eject is allowed → drives manualEjectRequested(false).
        _ = m.handle(.manualEjectRequested(lock: false))
        XCTAssertEqual(m.state, .ejecting)
        _ = m.handle(.ejectAttemptCompleted(success: true, errorSummary: nil))
        XCTAssertEqual(m.state, .idle)
    }

    func testCancellationPath_backingUpThenBackupStopped_doesNotAutoEject() {
        var m = sm(.idle)
        _ = m.handle(.backupBegan)
        let cmds = accept(m.handle(.backupStopped)) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(cmds.contains(.attemptAutoEjectIfAllowed))
    }

    func testCancellationPath_confirmingThenSameSnapshot_doesNotAutoEject() {
        let snap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        var m = sm(.backingUp)
        _ = m.handle(.confirmingEntered(latestBackupPath: snap))
        let cmds = accept(m.handle(.confirmingExited(newLatestBackupPath: snap))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(cmds.contains(.attemptAutoEjectIfAllowed))
    }

    func testStallPath_backingUp_stallDetected_returnsToIdleWithoutEject() {
        var m = sm(.idle)
        _ = m.handle(.backupBegan)
        let cmds = accept(m.handle(.stallDetected)) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(cmds.contains(.attemptAutoEjectIfAllowed))
        XCTAssertFalse(cmds.contains(.beginEject(lock: false)))
    }

    func testEjectFailurePath_ejectingToIdleEjectFailed_thenManualRetry() {
        var m = sm(.ejecting)
        _ = m.handle(.ejectAttemptCompleted(success: false, errorSummary: "busy: lsof says mdworker holds /Volumes/Backup"))
        XCTAssertEqual(m.state, .idleEjectFailed)

        _ = m.handle(.manualEjectRequested(lock: false))
        XCTAssertEqual(m.state, .ejecting)
        _ = m.handle(.ejectAttemptCompleted(success: true, errorSummary: nil))
        XCTAssertEqual(m.state, .idle)
    }
}

import XCTest
@testable import TMEject

final class StateMachineTests: XCTestCase {

    // MARK: - Helpers

    private func sm(
        _ state: AppState,
        preConfirm: URL? = nil,
        preConfirmFailed: Bool = false
    ) -> StateMachine {
        StateMachine(state: state, preBackupLatestBackup: preConfirm, preBackupProbeFailed: preConfirmFailed)
    }

    private func accept(_ outcome: GuardOutcome) -> [AppCommand]? {
        if case .accepted(let cs) = outcome { return cs } else { return nil }
    }

    private func ignored(_ outcome: GuardOutcome) -> Bool {
        if case .ignored = outcome { return true } else { return false }
    }

    // MARK: - Guard table

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
        let cmds = accept(m.handle(.backupBegan(baselineLatestBackupPath: nil, baselineProbeFailed: false)))
        XCTAssertEqual(m.state, .backingUp)
        // Step 12.7+13 fixup: backupBegan emits .recordPreBackupLatestBackup with whatever
        // baseline the observer captured (nil here). State machine stashes baseline + flag.
        XCTAssertEqual(cmds, [
            .recordPreBackupLatestBackup(nil),
            .setLastError(nil),
            .startStallTimer,
            .showToast(level: .info, message: "Backup started")
        ])
        XCTAssertNil(m.preBackupLatestBackup)
        XCTAssertFalse(m.preBackupProbeFailed)
    }

    func testBackupBeganCapturesNonNilBaseline_TahoeFix() {
        let priorSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        var m = sm(.idle)
        let cmds = accept(m.handle(.backupBegan(baselineLatestBackupPath: priorSnap,
                                                  baselineProbeFailed: false))) ?? []
        XCTAssertEqual(m.preBackupLatestBackup, priorSnap,
                       "Tahoe fix: baseline captured at backupBegan, not at confirmingEntered")
        XCTAssertTrue(cmds.contains(.recordPreBackupLatestBackup(priorSnap)))
    }

    func testBackupBeganCarriesProbeFailureFlag() {
        var m = sm(.idle)
        _ = m.handle(.backupBegan(baselineLatestBackupPath: nil, baselineProbeFailed: true))
        XCTAssertTrue(m.preBackupProbeFailed,
                       "FDA-denied baseline probe must propagate so confirmingExited refuses success")
    }

    func testBackupBeganMovesIdleEjectFailedToBackingUp_CoverageGap() {
        var m = sm(.idleEjectFailed)
        let cmds = accept(m.handle(.backupBegan(baselineLatestBackupPath: nil, baselineProbeFailed: false))) ?? []
        XCTAssertEqual(m.state, .backingUp)
        XCTAssertTrue(cmds.contains(.setLastError(nil)),
                      "starting a new backup clears the stale eject error")
    }

    func testBackupBeganIgnoredInBackingUpConfirmingEjecting() {
        for s in [AppState.backingUp, .confirming, .ejecting] {
            var m = sm(s)
            XCTAssertTrue(ignored(m.handle(.backupBegan(baselineLatestBackupPath: nil, baselineProbeFailed: false))))
            XCTAssertEqual(m.state, s)
        }
    }

    // Step 12.7+13 fixup: confirmingEntered no longer overwrites the baseline (that was
    // captured at backupBegan). It just transitions + restarts the timers.
    func testConfirmingEnteredTransitionsAndStartsConfirmingTimer() {
        let priorBaseline = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        // Seed a baseline as if backupBegan had captured one.
        var m = sm(.backingUp, preConfirm: priorBaseline)
        // confirmingEntered with a DIFFERENT path — the state machine must NOT overwrite.
        let confirmingPath = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-145122")
        let cmds = accept(m.handle(.confirmingEntered(latestBackupPath: confirmingPath, entryProbeFailed: false)))
        XCTAssertEqual(m.state, .confirming)
        XCTAssertEqual(m.preBackupLatestBackup, priorBaseline,
                       "Tahoe fix: confirmingEntered must NOT touch the baseline captured at backupBegan")
        XCTAssertFalse(m.preBackupProbeFailed)
        XCTAssertEqual(cmds, [.stopStallTimer, .startConfirmingTimer])
    }

    func testConfirmingEnteredORsInProbeFailedFlag() {
        let priorBaseline = URL(fileURLWithPath: "/snap/baseline")
        var m = sm(.backingUp, preConfirm: priorBaseline)
        _ = m.handle(.confirmingEntered(latestBackupPath: nil, entryProbeFailed: true))
        XCTAssertEqual(m.state, .confirming)
        XCTAssertEqual(m.preBackupLatestBackup, priorBaseline,
                       "baseline survives the entry-probe failure")
        XCTAssertTrue(m.preBackupProbeFailed,
                      "FDA grant breaking mid-backup must block success on exit")
    }

    // Tahoe race: backupBegan captures baseline X. By the time confirmingEntered fires,
    // backupd has already committed the new snapshot Y. Entry sees Y (NEW). Exit also sees
    // Y. With the OLD (Step-5) rule (compare entry vs exit), this looked like cancellation.
    // With the new rule (compare baseline at backupBegan vs exit), Y != X → success.
    func testTahoeSnapshotRace_SnapshotCommitsBeforeConfirmingEntered_StillCountsAsSuccess() {
        let baselineSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-13-100000")
        let newSnap      = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-14-145122")
        // backupBegan stashes baseline.
        var m = sm(.idle)
        _ = m.handle(.backupBegan(baselineLatestBackupPath: baselineSnap, baselineProbeFailed: false))
        XCTAssertEqual(m.state, .backingUp)
        // Tahoe quirk: by confirmingEntered the new snapshot has already landed.
        _ = m.handle(.confirmingEntered(latestBackupPath: newSnap, entryProbeFailed: false))
        XCTAssertEqual(m.state, .confirming)
        XCTAssertEqual(m.preBackupLatestBackup, baselineSnap,
                       "the new snapshot URL leaking into entry-probe must not poison the baseline")
        // confirmingExited sees the same newSnap (snapshot is now stable).
        let cmds = accept(m.handle(.confirmingExited(newLatestBackupPath: newSnap, exitProbeFailed: false))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(cmds.contains(.signalBackupCompleted),
                      "snapshot URL advanced (baselineSnap → newSnap) — must count as success on Tahoe")
    }

    func testConfirmingExitedAdvancedPathCountsAsSuccess() {
        let oldSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        let newSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-110000")
        var m = sm(.confirming, preConfirm: oldSnap)
        let cmds = accept(m.handle(.confirmingExited(newLatestBackupPath: newSnap, exitProbeFailed: false))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.preBackupLatestBackup)
        XCTAssertFalse(m.preBackupProbeFailed)
        XCTAssertTrue(cmds.contains(.stopConfirmingTimer))
        XCTAssertTrue(cmds.contains(.clearPreBackupLatestBackup))
        XCTAssertTrue(cmds.contains(.signalBackupCompleted))
        XCTAssertTrue(cmds.contains(where: { if case .notify(let t, _) = $0 { return t == "Backup complete" }; return false }))
    }

    func testConfirmingExitedSamePathCountsAsCancellation() {
        let snap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        var m = sm(.confirming, preConfirm: snap)
        let cmds = accept(m.handle(.confirmingExited(newLatestBackupPath: snap, exitProbeFailed: false))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(cmds.contains(.signalBackupCompleted))
        XCTAssertTrue(cmds.contains(where: { if case .showToast(_, let msg) = $0 { return msg.contains("without a new snapshot") }; return false }))
    }

    func testConfirmingExitedFirstEverBackupCountsAsSuccess() {
        let newSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        var m = sm(.confirming, preConfirm: nil)
        let cmds = accept(m.handle(.confirmingExited(newLatestBackupPath: newSnap, exitProbeFailed: false))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(cmds.contains(.signalBackupCompleted))
    }

    // H2 coverage gap: entry-probe failed → MUST NOT signal completion even if exit path
    // is non-nil. This prevents the false-success auto-eject race.
    func testConfirmingExitedRefusesSuccessWhenEntryProbeFailed() {
        let exitSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        var m = sm(.confirming, preConfirm: nil, preConfirmFailed: true)
        let cmds = accept(m.handle(.confirmingExited(newLatestBackupPath: exitSnap, exitProbeFailed: false))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(cmds.contains(.signalBackupCompleted),
                       "must not claim success when entry probe failed — no reliable baseline")
        XCTAssertTrue(cmds.contains(where: { if case .showToast(_, let msg) = $0 { return msg.contains("probe failed") }; return false }))
    }

    func testConfirmingExitedRefusesSuccessWhenExitProbeFailed() {
        let snap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        var m = sm(.confirming, preConfirm: snap)
        let cmds = accept(m.handle(.confirmingExited(newLatestBackupPath: nil, exitProbeFailed: true))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(cmds.contains(.signalBackupCompleted))
    }

    // H2 coverage gap: prior == nil AND new == nil is unambiguous cancellation.
    func testConfirmingExitedPriorNilNewNilIsCancellation() {
        var m = sm(.confirming, preConfirm: nil)
        let cmds = accept(m.handle(.confirmingExited(newLatestBackupPath: nil, exitProbeFailed: false))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(cmds.contains(.signalBackupCompleted))
    }

    func testConfirmingExitedIgnoredOutsideConfirming() {
        for s in [AppState.idle, .idleEjectFailed, .backingUp, .ejecting] {
            var m = sm(s)
            XCTAssertTrue(ignored(m.handle(.confirmingExited(newLatestBackupPath: nil, exitProbeFailed: false))),
                          "from \(s)")
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
        XCTAssertNil(m.preBackupLatestBackup)
        XCTAssertFalse(m.preBackupProbeFailed)
        XCTAssertTrue(cmds.contains(.stopConfirmingTimer))
        XCTAssertTrue(cmds.contains(where: { if case .setLastError(let s) = $0 { return s?.contains("4h") == true }; return false }))
    }

    func testEjectRequestedAllowedOnlyInIdleAndFailed() {
        for s in [AppState.idle, .idleEjectFailed] {
            var m = sm(s)
            let cmds = accept(m.handle(.ejectRequested(lock: false, source: .manual))) ?? []
            XCTAssertEqual(m.state, .ejecting, "from \(s)")
            XCTAssertTrue(cmds.contains(.beginEject(lock: false)))
        }
        for s in [AppState.backingUp, .confirming, .ejecting] {
            var m = sm(s)
            XCTAssertTrue(ignored(m.handle(.ejectRequested(lock: false, source: .manual))), "from \(s)")
            XCTAssertEqual(m.state, s)
        }
    }

    func testEjectRequestedLockFlagPropagates() {
        var m = sm(.idle)
        let cmds = accept(m.handle(.ejectRequested(lock: true, source: .manual))) ?? []
        XCTAssertTrue(cmds.contains(.beginEject(lock: true)))
    }

    func testEjectRequestedSourceAutoStillTransitionsAndEjects() {
        var m = sm(.idle)
        let cmds = accept(m.handle(.ejectRequested(lock: false, source: .auto))) ?? []
        XCTAssertEqual(m.state, .ejecting)
        XCTAssertTrue(cmds.contains(.beginEject(lock: false)))
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

    // MARK: - M3 restore

    func testRestoreConfirmingFromRelaunchSetsState() {
        let snap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-11-100000")
        var m = sm(.idle)
        m.restoreInFlightFromRelaunch(intoState: .confirming, baselineLatestBackupPath: snap, baselineProbeFailed: false)
        XCTAssertEqual(m.state, .confirming)
        XCTAssertEqual(m.preBackupLatestBackup, snap)
        XCTAssertFalse(m.preBackupProbeFailed)
    }

    func testRestoreConfirmingFromRelaunchOnlyAppliesFromIdle() {
        var m = sm(.backingUp)
        m.restoreInFlightFromRelaunch(intoState: .confirming, baselineLatestBackupPath: URL(fileURLWithPath: "/x"), baselineProbeFailed: false)
        XCTAssertEqual(m.state, .backingUp, "must not bulldoze a live state")
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
        // backupBegan carries the baseline snapshot — the OLD one, captured before backupd
        // wrote the new one.
        let oldSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-100000")
        let beganCmds = accept(m.handle(.backupBegan(baselineLatestBackupPath: oldSnap,
                                                       baselineProbeFailed: false))) ?? []
        XCTAssertTrue(beganCmds.contains(.setLastError(nil)))
        XCTAssertEqual(m.state, .backingUp)
        XCTAssertEqual(m.preBackupLatestBackup, oldSnap)

        _ = m.handle(.confirmingEntered(latestBackupPath: oldSnap, entryProbeFailed: false))
        XCTAssertEqual(m.state, .confirming)

        let newSnap = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac/2026-06-10-110000")
        let exitCmds = accept(m.handle(.confirmingExited(newLatestBackupPath: newSnap, exitProbeFailed: false))) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(exitCmds.contains(.signalBackupCompleted))

        _ = m.handle(.ejectRequested(lock: false, source: .auto))
        XCTAssertEqual(m.state, .ejecting)
        _ = m.handle(.ejectAttemptCompleted(success: true, errorSummary: nil))
        XCTAssertEqual(m.state, .idle)
    }

    func testCancellationPath_backingUpThenBackupStopped_doesNotSignalCompletion() {
        var m = sm(.idle)
        _ = m.handle(.backupBegan(baselineLatestBackupPath: nil, baselineProbeFailed: false))
        let cmds = accept(m.handle(.backupStopped)) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(cmds.contains(.signalBackupCompleted))
    }

    func testStallPath_backingUp_stallDetected_returnsToIdleWithoutEject() {
        var m = sm(.idle)
        _ = m.handle(.backupBegan(baselineLatestBackupPath: nil, baselineProbeFailed: false))
        let cmds = accept(m.handle(.stallDetected)) ?? []
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(cmds.contains(.signalBackupCompleted))
        XCTAssertFalse(cmds.contains(.beginEject(lock: false)))
    }

    func testEjectFailurePath_ejectingToIdleEjectFailed_thenManualRetry() {
        var m = sm(.ejecting)
        _ = m.handle(.ejectAttemptCompleted(success: false, errorSummary: "busy: lsof says mdworker holds /Volumes/Backup"))
        XCTAssertEqual(m.state, .idleEjectFailed)

        _ = m.handle(.ejectRequested(lock: false, source: .manual))
        XCTAssertEqual(m.state, .ejecting)
        _ = m.handle(.ejectAttemptCompleted(success: true, errorSummary: nil))
        XCTAssertEqual(m.state, .idle)
    }
}

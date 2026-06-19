import Foundation

struct StateMachine: Sendable {
    private(set) var state: AppState

    /// Snapshot path captured at backupBegan — the BASELINE we compare against at
    /// confirmingExited to detect success. Step 12.7+13 fixup: was captured at
    /// confirmingEntered, but on macOS 26.3.1 the new snapshot URL is committed BEFORE
    /// TMEject's first confirming-phase poll. Moving the capture to backupBegan ensures
    /// the baseline is the PRIOR snapshot.
    private(set) var preBackupLatestBackup: URL?

    /// OR-accumulated probe-failure flag — set if EITHER the baseline probe at backupBegan
    /// OR the entry probe at confirmingEntered failed. A probe failure means FDA was denied
    /// during that poll; we can't trust either side of the snapshot-delta comparison, so the
    /// state machine refuses to claim success on exit. Closes the H2 false-success race.
    private(set) var preBackupProbeFailed: Bool

    init(
        state: AppState = .idle,
        preBackupLatestBackup: URL? = nil,
        preBackupProbeFailed: Bool = false
    ) {
        self.state = state
        self.preBackupLatestBackup = preBackupLatestBackup
        self.preBackupProbeFailed = preBackupProbeFailed
    }

    /// Locked Architecture Decision #10: "Eject now" / "Eject & Lock" are disabled in
    /// `confirming` and `ejecting`. Auto-eject toggle is always allowed.
    static func isManualEjectAllowed(in state: AppState) -> Bool {
        switch state {
        case .idle, .idleEjectFailed: return true
        case .backingUp, .confirming, .ejecting: return false
        }
    }

    static func isAutoEjectToggleAllowed(in _: AppState) -> Bool { true }

    /// Restore a backup-in-progress position discovered at coordinator launch. Used by M3
    /// to recover from a TMEject relaunch that happened while backupd was running so the
    /// snapshot-advance comparison still has a baseline. The caller (coordinator) is
    /// responsible for figuring out whether to restore to .backingUp or .confirming based
    /// on the current `tmutil status` phase.
    mutating func restoreInFlightFromRelaunch(
        intoState restoredState: AppState,
        baselineLatestBackupPath: URL?,
        baselineProbeFailed: Bool
    ) {
        guard state == .idle else { return }
        guard restoredState == .backingUp || restoredState == .confirming else { return }
        state = restoredState
        preBackupLatestBackup = baselineLatestBackupPath
        preBackupProbeFailed = baselineProbeFailed
    }

    mutating func handle(_ event: AppEvent) -> GuardOutcome {
        switch (state, event) {

        // MARK: wakeSignal
        case (.idle, .wakeSignal),
             (.idleEjectFailed, .wakeSignal):
            return .accepted([.requestPoll])
        case (.backingUp, .wakeSignal),
             (.confirming, .wakeSignal),
             (.ejecting, .wakeSignal):
            return .ignored(reason: "wakeSignal ignored in \(state) — already supervising")

        // MARK: backupBegan
        case (.idle, .backupBegan(let baseline, let baselineFailed)),
             (.idleEjectFailed, .backupBegan(let baseline, let baselineFailed)):
            preBackupLatestBackup = baseline
            preBackupProbeFailed = baselineFailed
            state = .backingUp
            return .accepted([
                .recordPreBackupLatestBackup(baseline),
                .setLastError(nil),
                .startStallTimer,
                .showToast(level: .info, message: "Backup started")
            ])
        case (.backingUp, .backupBegan),
             (.confirming, .backupBegan),
             (.ejecting, .backupBegan):
            return .ignored(reason: "backupBegan ignored in \(state)")

        // MARK: confirmingEntered
        // No longer overwrites preBackupLatestBackup — that was captured at backupBegan.
        // We DO OR in entryProbeFailed so a mid-backup FDA grant revocation still blocks
        // success claims at exit.
        case (.idle, .confirmingEntered(_, let probeFailed)),
             (.idleEjectFailed, .confirmingEntered(_, let probeFailed)),
             (.backingUp, .confirmingEntered(_, let probeFailed)):
            if probeFailed { preBackupProbeFailed = true }
            state = .confirming
            return .accepted([
                .stopStallTimer,
                .startConfirmingTimer
            ])
        case (.confirming, .confirmingEntered),
             (.ejecting, .confirmingEntered):
            return .ignored(reason: "confirmingEntered ignored in \(state)")

        // MARK: confirmingExited — the Tahoe fix compares baseline (at backupBegan) vs new.
        case (.confirming, .confirmingExited(let newPath, let exitProbeFailed)):
            let baseline = preBackupLatestBackup
            let anyProbeFailed = preBackupProbeFailed
            preBackupLatestBackup = nil
            preBackupProbeFailed = false
            state = .idle
            var commands: [AppCommand] = [
                .stopConfirmingTimer,
                .clearPreBackupLatestBackup
            ]
            // Locked Decision #3 (Tahoe-corrected): the snapshot URL must advance between
            // backupBegan and confirmingExited for it to count as success. If any probe
            // failed along the way we have no reliable comparison, so we refuse.
            let succeeded: Bool = {
                if anyProbeFailed || exitProbeFailed { return false }
                guard let new = newPath else { return false }
                guard let old = baseline else { return true }   // had no snapshot before; now we do
                return new != old
            }()
            if succeeded {
                commands.append(.notify(title: "Backup complete", body: "Time Machine finished successfully."))
                commands.append(.showToast(level: .success, message: "Backup complete"))
                commands.append(.signalBackupCompleted)
            } else if anyProbeFailed || exitProbeFailed {
                commands.append(.showToast(level: .warning, message: "Backup ended (snapshot probe failed — not auto-ejecting)"))
            } else {
                commands.append(.showToast(level: .info, message: "Backup ended without a new snapshot"))
            }
            return .accepted(commands)
        case (.idle, .confirmingExited),
             (.idleEjectFailed, .confirmingExited),
             (.backingUp, .confirmingExited),
             (.ejecting, .confirmingExited):
            return .ignored(reason: "confirmingExited ignored in \(state)")

        // MARK: backupStopped
        case (.backingUp, .backupStopped),
             (.idle, .backupStopped),
             (.idleEjectFailed, .backupStopped):
            let wasRunning = state == .backingUp
            // Cancellation — drop baseline so the next backup starts fresh.
            preBackupLatestBackup = nil
            preBackupProbeFailed = false
            state = .idle
            var commands: [AppCommand] = [.stopStallTimer, .clearPreBackupLatestBackup]
            if wasRunning {
                commands.append(.showToast(level: .info, message: "Backup stopped"))
            }
            return .accepted(commands)
        case (.confirming, .backupStopped):
            return .ignored(reason: "backupStopped ignored in confirming — exit signaled via confirmingExited")
        case (.ejecting, .backupStopped):
            return .ignored(reason: "backupStopped ignored in ejecting")

        // MARK: stallDetected
        case (.backingUp, .stallDetected):
            preBackupLatestBackup = nil
            preBackupProbeFailed = false
            state = .idle
            return .accepted([
                .stopStallTimer,
                .clearPreBackupLatestBackup,
                .showToast(level: .warning, message: "Backup stalled — totalBytes unchanged for 10 min"),
                .setLastError("Stall: _raw_totalBytes unchanged for 10 min in backingUp")
            ])
        case (.idle, .stallDetected),
             (.idleEjectFailed, .stallDetected),
             (.confirming, .stallDetected),
             (.ejecting, .stallDetected):
            return .ignored(reason: "stallDetected ignored in \(state)")

        // MARK: confirmingTimedOut
        case (.confirming, .confirmingTimedOut):
            preBackupLatestBackup = nil
            preBackupProbeFailed = false
            state = .idle
            return .accepted([
                .stopConfirmingTimer,
                .clearPreBackupLatestBackup,
                .showToast(level: .warning, message: "Confirming phase exceeded 4h — returning to idle"),
                .setLastError("Confirming-phase 4h cap exceeded")
            ])
        case (.idle, .confirmingTimedOut),
             (.idleEjectFailed, .confirmingTimedOut),
             (.backingUp, .confirmingTimedOut),
             (.ejecting, .confirmingTimedOut):
            return .ignored(reason: "confirmingTimedOut ignored in \(state)")

        // MARK: ejectRequested
        case (.idle, .ejectRequested(let lock, _)),
             (.idleEjectFailed, .ejectRequested(let lock, _)):
            state = .ejecting
            return .accepted([.setLastError(nil), .beginEject(lock: lock)])
        case (.backingUp, .ejectRequested),
             (.confirming, .ejectRequested),
             (.ejecting, .ejectRequested):
            return .ignored(reason: "ejectRequested disabled in \(state) per guard table")

        // MARK: ejectAttemptCompleted
        case (.ejecting, .ejectAttemptCompleted(let success, let errorSummary)):
            if success {
                state = .idle
                return .accepted([
                    .setLastError(nil),
                    // No system notification on eject success — toast covers it
                    // and the drive being unmounted is itself the signal.
                    .showToast(level: .success, message: "Drive ejected")
                ])
            } else {
                state = .idleEjectFailed
                let summary = errorSummary ?? "Unknown eject failure"
                return .accepted([
                    .setLastError(summary),
                    // System notification stays here — eject failure is the
                    // canonical "user needs to know" event even when the screen
                    // is locked / they walked away.
                    .notify(title: "Eject failed", body: summary),
                    .showToast(level: .error, message: "Eject failed: \(summary)")
                ])
            }
        case (.idle, .ejectAttemptCompleted),
             (.idleEjectFailed, .ejectAttemptCompleted),
             (.backingUp, .ejectAttemptCompleted),
             (.confirming, .ejectAttemptCompleted):
            return .ignored(reason: "ejectAttemptCompleted ignored in \(state)")

        // MARK: appWillTerminate
        case (.ejecting, .appWillTerminate):
            return .accepted([.showQuitDuringEjectWarning])
        case (.idle, .appWillTerminate),
             (.idleEjectFailed, .appWillTerminate),
             (.backingUp, .appWillTerminate),
             (.confirming, .appWillTerminate):
            return .accepted([])
        }
    }
}

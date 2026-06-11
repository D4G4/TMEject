import Foundation

struct StateMachine: Sendable {
    private(set) var state: AppState
    private(set) var preConfirmLatestBackup: URL?
    /// True when the snapshot probe at confirming-entry (or restore-from-relaunch with no path)
    /// failed — we have no reliable baseline so the exit must NOT claim success even if the new
    /// probe returns a non-nil path. Closes the H2 false-success race.
    private(set) var preConfirmProbeFailed: Bool

    init(
        state: AppState = .idle,
        preConfirmLatestBackup: URL? = nil,
        preConfirmProbeFailed: Bool = false
    ) {
        self.state = state
        self.preConfirmLatestBackup = preConfirmLatestBackup
        self.preConfirmProbeFailed = preConfirmProbeFailed
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

    /// Restore a confirming-phase position discovered at coordinator launch.
    /// Used by M3 to recover from a TMEject relaunch that happened mid-confirming so the
    /// snapshot-advance comparison still has a baseline.
    mutating func restoreConfirmingFromRelaunch(latestBackupPath: URL?, entryProbeFailed: Bool) {
        guard state == .idle else { return }
        state = .confirming
        preConfirmLatestBackup = latestBackupPath
        preConfirmProbeFailed = entryProbeFailed
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
        case (.idle, .backupBegan),
             (.idleEjectFailed, .backupBegan):
            state = .backingUp
            return .accepted([
                .setLastError(nil),
                .startStallTimer,
                .showToast(level: .info, message: "Backup started")
            ])
        case (.backingUp, .backupBegan),
             (.confirming, .backupBegan),
             (.ejecting, .backupBegan):
            return .ignored(reason: "backupBegan ignored in \(state)")

        // MARK: confirmingEntered
        case (.idle, .confirmingEntered(let path, let probeFailed)),
             (.idleEjectFailed, .confirmingEntered(let path, let probeFailed)),
             (.backingUp, .confirmingEntered(let path, let probeFailed)):
            preConfirmLatestBackup = path
            preConfirmProbeFailed = probeFailed
            state = .confirming
            return .accepted([
                .recordPreConfirmLatestBackup(path),
                .stopStallTimer,
                .startConfirmingTimer
            ])
        case (.confirming, .confirmingEntered),
             (.ejecting, .confirmingEntered):
            return .ignored(reason: "confirmingEntered ignored in \(state)")

        // MARK: confirmingExited
        case (.confirming, .confirmingExited(let newPath, let exitProbeFailed)):
            let prior = preConfirmLatestBackup
            let entryProbeFailed = preConfirmProbeFailed
            preConfirmLatestBackup = nil
            preConfirmProbeFailed = false
            state = .idle
            var commands: [AppCommand] = [
                .stopConfirmingTimer,
                .clearPreConfirmLatestBackup
            ]
            // Locked Decision #3: snapshot-path advance is the ONLY authoritative success signal.
            // If either probe failed we don't know whether the path advanced, so we must NOT
            // claim success — otherwise a cancelled-but-existing-snapshot trip can auto-eject.
            let succeeded: Bool = {
                if entryProbeFailed || exitProbeFailed { return false }
                guard let new = newPath else { return false }
                guard let old = prior else { return true }   // had no snapshot before; now we do
                return new != old
            }()
            if succeeded {
                commands.append(.notify(title: "Backup complete", body: "Time Machine finished successfully."))
                commands.append(.showToast(level: .success, message: "Backup complete"))
                commands.append(.signalBackupCompleted)
            } else if entryProbeFailed || exitProbeFailed {
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
            state = .idle
            var commands: [AppCommand] = [.stopStallTimer]
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
            state = .idle
            return .accepted([
                .stopStallTimer,
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
            preConfirmLatestBackup = nil
            preConfirmProbeFailed = false
            state = .idle
            return .accepted([
                .stopConfirmingTimer,
                .clearPreConfirmLatestBackup,
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
                    .notify(title: "Drive ejected", body: "Time Machine drive ejected safely."),
                    .showToast(level: .success, message: "Drive ejected")
                ])
            } else {
                state = .idleEjectFailed
                let summary = errorSummary ?? "Unknown eject failure"
                return .accepted([
                    .setLastError(summary),
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

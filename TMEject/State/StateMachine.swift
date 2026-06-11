import Foundation

struct StateMachine: Sendable {
    private(set) var state: AppState
    private(set) var preConfirmLatestBackup: URL?

    init(state: AppState = .idle, preConfirmLatestBackup: URL? = nil) {
        self.state = state
        self.preConfirmLatestBackup = preConfirmLatestBackup
    }

    /// Allowed-action probe for the menu UI.
    /// Per locked Architecture Decision #10: "Eject now" / "Eject & Lock" are disabled in
    /// `confirming` and `ejecting`. Auto-eject toggle is always allowed.
    static func isManualEjectAllowed(in state: AppState) -> Bool {
        switch state {
        case .idle, .idleEjectFailed: return true
        case .backingUp, .confirming, .ejecting: return false
        }
    }

    static func isAutoEjectToggleAllowed(in _: AppState) -> Bool { true }

    /// Single pure transition function. Returns the commands the coordinator should run,
    /// or `.ignored(reason:)` if the event is disallowed in this state.
    /// Mutates `self.state` only on `.accepted`.
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
            transition(to: .backingUp)
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
        case (.idle, .confirmingEntered(let path)),
             (.idleEjectFailed, .confirmingEntered(let path)),
             (.backingUp, .confirmingEntered(let path)):
            preConfirmLatestBackup = path
            transition(to: .confirming)
            return .accepted([
                .recordPreConfirmLatestBackup(path),
                .stopStallTimer,
                .startConfirmingTimer
            ])
        case (.confirming, .confirmingEntered),
             (.ejecting, .confirmingEntered):
            return .ignored(reason: "confirmingEntered ignored in \(state)")

        // MARK: confirmingExited
        case (.confirming, .confirmingExited(let newPath)):
            let prior = preConfirmLatestBackup
            preConfirmLatestBackup = nil
            transition(to: .idle)
            var commands: [AppCommand] = [
                .stopConfirmingTimer,
                .clearPreConfirmLatestBackup
            ]
            // Success iff the snapshot path advanced.
            // Per locked Architecture Decision #3: BackupPhase does not distinguish success
            // from cancellation; both end with Running=0 and no phase. Snapshot path
            // advance is the authoritative signal.
            let succeeded: Bool = {
                guard let new = newPath else { return false }
                guard let old = prior else { return true }   // had nothing before, now have a snapshot
                return new != old
            }()
            if succeeded {
                commands.append(.notify(title: "Backup complete", body: "Time Machine finished successfully."))
                commands.append(.showToast(level: .success, message: "Backup complete"))
                commands.append(.attemptAutoEjectIfAllowed)
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
            // backingUp → idle (cancelled before confirming).
            // idle / idleEjectFailed → no-op transition but still clear stall timer just in case.
            let wasRunning = state == .backingUp
            transition(to: .idle)
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
            transition(to: .idle)
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
            transition(to: .idle)
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

        // MARK: manualEjectRequested
        case (.idle, .manualEjectRequested(let lock)),
             (.idleEjectFailed, .manualEjectRequested(let lock)):
            transition(to: .ejecting)
            return .accepted([.setLastError(nil), .beginEject(lock: lock)])
        case (.backingUp, .manualEjectRequested),
             (.confirming, .manualEjectRequested),
             (.ejecting, .manualEjectRequested):
            return .ignored(reason: "manual eject disabled in \(state) per guard table")

        // MARK: ejectAttemptCompleted
        case (.ejecting, .ejectAttemptCompleted(let success, let errorSummary)):
            if success {
                transition(to: .idle)
                return .accepted([
                    .setLastError(nil),
                    .notify(title: "Drive ejected", body: "Time Machine drive ejected safely."),
                    .showToast(level: .success, message: "Drive ejected")
                ])
            } else {
                transition(to: .idleEjectFailed)
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

    private mutating func transition(to newState: AppState) {
        TMEjectLog.state.info("State: \(state) → \(newState)")
        state = newState
    }
}

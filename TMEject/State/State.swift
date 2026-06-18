import Foundation

enum AppState: String, Equatable, Sendable, CustomStringConvertible {
    case idle
    case backingUp
    case confirming
    case ejecting
    case idleEjectFailed

    var description: String { rawValue }
}

enum EjectSource: String, Sendable, Equatable {
    case manual
    case auto
    /// Foreign Time Machine drive — a TM-role volume that's NOT in this Mac's
    /// `tmutil destinationinfo` list. Triggered by `DiskAppearedObserver` + a 10s
    /// cancellable grace window. See `Observation/DiskAppearedObserver.swift`.
    case foreign
}

enum AppEvent: Sendable, Equatable {
    case wakeSignal
    /// Carries the pre-backup latestbackup baseline. Captured by the observer at the moment
    /// Running flips to true, BEFORE backupd has committed the new snapshot. Step 12.7+13
    /// fixup — locked Decision #3 originally captured at `confirmingEntered`, but the
    /// snapshot URL is committed BEFORE TMEject's first confirming-phase poll on Tahoe;
    /// capturing at backupBegan moves the baseline earlier so the delta is real.
    case backupBegan(baselineLatestBackupPath: URL?, baselineProbeFailed: Bool)
    /// `entryProbeFailed` no longer feeds the success/cancel decision (the baseline is
    /// captured at backupBegan now). It still propagates a "FDA grant broke mid-backup"
    /// signal — if entry probe fails, the state machine refuses to claim success on exit.
    case confirmingEntered(latestBackupPath: URL?, entryProbeFailed: Bool)
    case confirmingExited(newLatestBackupPath: URL?, exitProbeFailed: Bool)
    case backupStopped
    case stallDetected
    case confirmingTimedOut
    case ejectRequested(lock: Bool, source: EjectSource)
    case ejectAttemptCompleted(success: Bool, errorSummary: String?)
    case appWillTerminate
}

enum AppCommand: Sendable, Equatable {
    case requestPoll
    /// Persist the baseline latestbackup path to UserDefaults so a TMEject relaunch
    /// mid-backup can still compare against it. Step 12.7+13 fixup renamed
    /// `recordPreConfirmLatestBackup` → `recordPreBackupLatestBackup` and moved its
    /// trigger from `confirmingEntered` to `backupBegan`.
    case recordPreBackupLatestBackup(URL?)
    case clearPreBackupLatestBackup
    case beginEject(lock: Bool)
    /// Emitted on a successful confirmingExited. The coordinator (not the state machine)
    /// decides whether the user has auto-eject enabled and whether the cooldown allows it
    /// — if so the coordinator drives `.ejectRequested(source: .auto)`.
    case signalBackupCompleted
    case showToast(level: ToastLevel, message: String)
    case notify(title: String, body: String)
    case setLastError(String?)
    case startStallTimer
    case stopStallTimer
    case startConfirmingTimer
    case stopConfirmingTimer
    case showQuitDuringEjectWarning

    enum ToastLevel: String, Sendable, Equatable {
        case info, success, warning, error
    }
}

enum GuardOutcome: Equatable, Sendable {
    case accepted([AppCommand])
    case ignored(reason: String)
}

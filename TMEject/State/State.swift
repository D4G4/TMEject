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
}

enum AppEvent: Sendable, Equatable {
    case wakeSignal
    case backupBegan
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
    case recordPreConfirmLatestBackup(URL?)
    case clearPreConfirmLatestBackup
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

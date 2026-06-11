import Foundation

enum AppState: String, Equatable, Sendable, CustomStringConvertible {
    case idle
    case backingUp
    case confirming
    case ejecting
    case idleEjectFailed

    var description: String { rawValue }
}

enum AppEvent: Sendable, Equatable {
    case wakeSignal                              // DNC ping, FSEvent fire, or scheduled poll tick — caller will poll
    case backupBegan                             // observer: Running=true, phase outside the confirming set
    case confirmingEntered(latestBackupPath: URL?)
    case confirmingExited(newLatestBackupPath: URL?)
    case backupStopped                           // observer: Running=false outside confirming
    case stallDetected                           // 10min totalBytes unchanged in backingUp
    case confirmingTimedOut                      // 4h hard cap in confirming
    case manualEjectRequested(lock: Bool)
    case ejectAttemptCompleted(success: Bool, errorSummary: String?)
    case appWillTerminate
}

enum AppCommand: Sendable, Equatable {
    case requestPoll
    case recordPreConfirmLatestBackup(URL?)
    case clearPreConfirmLatestBackup
    case beginEject(lock: Bool)
    case attemptAutoEjectIfAllowed              // coordinator consults autoEjectEnabled + cooldown before calling beginEject
    case showToast(level: ToastLevel, message: String)
    case notify(title: String, body: String)
    case setLastError(String?)
    case startStallTimer
    case stopStallTimer
    case startConfirmingTimer
    case stopConfirmingTimer
    case showQuitDuringEjectWarning             // appWillTerminate while ejecting

    enum ToastLevel: String, Sendable, Equatable {
        case info, success, warning, error
    }
}

enum GuardOutcome: Equatable, Sendable {
    case accepted([AppCommand])
    case ignored(reason: String)
}

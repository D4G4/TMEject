import Foundation

enum BackupPhaseKind: Equatable, Sendable {
    case preCopy        // Starting, FindingChanges*, ThinningPreBackup, Preparing*, MountingBackupVol, etc.
    case copying        // Copying
    case confirming     // Finishing, ThinningPostBackup, Confirming — i.e. anything that comes AFTER copy
    case unknown(String)

    static func classify(_ phase: String?) -> BackupPhaseKind {
        guard let phase, !phase.isEmpty else { return .preCopy }
        // Hard-list the phases we've seen. Anything we don't recognise is unknown — treat as preCopy for
        // safety so a never-before-seen phase string doesn't trip a false success/cancellation transition.
        switch phase {
        case "Starting",
             "FindingChanges",
             "FindingChangesInLocalSnapshot",
             "PreparingSourceVolumes",
             "Preparing",
             "MountingBackupVol",
             "ThinningPreBackup":
            return .preCopy
        case "Copying":
            return .copying
        case "Finishing",
             "ThinningPostBackup",
             "Confirming":
            return .confirming
        default:
            return .unknown(phase)
        }
    }

    var isConfirming: Bool {
        if case .confirming = self { return true }
        return false
    }
}

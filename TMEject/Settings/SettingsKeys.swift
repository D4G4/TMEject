import Foundation

/// Canonical UserDefaults keys. Centralized so Settings UI, AppCoordinator, and tests
/// can't drift on string literals.
enum SettingsKey {
    static let autoEjectEnabled        = "com.tmeject.app.autoEjectEnabled"          // default false
    static let cooldownMinutes         = "com.tmeject.app.cooldownMinutes"           // default 30
    static let notifyOnBackupFailure   = "com.tmeject.app.notifyOnBackupFailure"     // default true
    static let toastsEnabled           = "com.tmeject.app.toastsEnabled"             // default true
    static let runLsofOnEjectFailure   = "com.tmeject.app.runLsofOnEjectFailure"     // default true
    static let hasCompletedOnboarding  = "com.tmeject.app.hasCompletedOnboarding"
    // hasSeenLaunchHUD removed — the HUD is shown every launch, not gated on a flag.
    static let betaChannel             = "com.tmeject.app.betaChannel"
    static let preBackupLatestBackup   = "com.tmeject.app.preBackupLatestBackupPath"
    static let launchAtLogin           = "com.tmeject.app.launchAtLogin"     // @AppStorage mirror
    static let forceOnboardingModal    = "com.tmeject.app.forceOnboardingModal"   // Set by Reset Onboarding
    static let translucentSurfaces     = "com.tmeject.app.translucentSurfaces"    // default false (opaque solid)
    /// Foreign TM-drive auto-eject. Default true — set at AppCoordinator init when
    /// no value is stored, mirroring `autoEjectEnabled`. See
    /// `Observation/DiskAppearedObserver.swift` for the detection path.
    static let ejectForeignTMDrives    = "com.tmeject.app.ejectForeignTMDrives"   // default true
}

enum CooldownOption: Int, CaseIterable, Identifiable {
    case zero = 0
    case fifteen = 15
    case thirty = 30
    case sixty = 60
    case oneTwenty = 120

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .zero:      return "None"
        case .fifteen:   return "15 minutes"
        case .thirty:    return "30 minutes (default)"
        case .sixty:     return "1 hour"
        case .oneTwenty: return "2 hours"
        }
    }
}

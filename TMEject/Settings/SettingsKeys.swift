import Foundation

/// Canonical UserDefaults keys. Centralized so Settings UI, AppCoordinator, and tests
/// can't drift on string literals.
enum SettingsKey {
    static let autoEjectEnabled        = "co.dls.tmeject.autoEjectEnabled"          // default false
    static let cooldownMinutes         = "co.dls.tmeject.cooldownMinutes"           // default 30
    static let notifyOnBackupFailure   = "co.dls.tmeject.notifyOnBackupFailure"     // default true
    static let toastsEnabled           = "co.dls.tmeject.toastsEnabled"             // default true
    static let runLsofOnEjectFailure   = "co.dls.tmeject.runLsofOnEjectFailure"     // default true
    static let hasCompletedOnboarding  = "co.dls.tmeject.hasCompletedOnboarding"
    static let hasSeenLaunchHUD        = "co.dls.tmeject.hasSeenLaunchHUD"
    static let betaChannel             = "co.dls.tmeject.betaChannel"
    static let preBackupLatestBackup   = "co.dls.tmeject.preBackupLatestBackupPath"
    static let launchAtLogin           = "co.dls.tmeject.launchAtLogin"     // @AppStorage mirror
    static let forceOnboardingModal    = "co.dls.tmeject.forceOnboardingModal"   // Set by Reset Onboarding
    static let translucentSurfaces     = "co.dls.tmeject.translucentSurfaces"    // default false (opaque solid)
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

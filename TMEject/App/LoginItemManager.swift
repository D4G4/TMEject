import Foundation
import ServiceManagement

enum LoginItemStatus: String, Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

protocol LoginItemManaging: Sendable {
    func currentStatus() -> LoginItemStatus
    func register() throws
    func unregister() throws
}

struct LiveLoginItemManager: LoginItemManaging {
    // SMAppService isn't Sendable; we hold the type only and re-fetch the singleton on each
    // call. The cost is negligible (Apple documents it as an O(1) lookup) and it keeps the
    // manager Sendable across actor hops.
    private var service: SMAppService { .mainApp }

    init() {}

    func currentStatus() -> LoginItemStatus {
        switch service.status {
        case .notRegistered:      return .notRegistered
        case .enabled:            return .enabled
        case .requiresApproval:   return .requiresApproval
        case .notFound:           return .notFound
        @unknown default:         return .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

enum LoginItemSettings {
    /// Apple's documented x-apple.systempreferences URL for the Login Items pane. Used when
    /// SMAppService.register returns .requiresApproval — the user needs to flip the toggle
    /// in System Settings before macOS will honor the registration.
    static let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
}

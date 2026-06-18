import Foundation
import UserNotifications

enum NotificationCategory: String, Sendable {
    case backupFailure        = "com.tmeject.app.backupFailure"
    case ejectFailurePersistent = "com.tmeject.app.ejectFailurePersistent"
    case generic              = "com.tmeject.app.generic"
}

enum NotificationAuthState: String, Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

protocol SystemNotifier: Sendable {
    func currentAuthState() async -> NotificationAuthState
    /// Returns true iff authorization was granted (existing or just-granted). Idempotent.
    func requestAuthorizationIfNeeded() async -> Bool
    /// No-op if the system has denied authorization — caller falls back to in-app toast.
    func deliver(title: String, body: String, category: NotificationCategory) async
}

actor LiveSystemNotifier: SystemNotifier {
    private let center: UNUserNotificationCenter
    private var hasRequested = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func currentAuthState() async -> NotificationAuthState {
        // UNNotificationSettings isn't Sendable; UNAuthorizationStatus (an
        // Int-backed enum) is. Project the status out of the settings on the
        // delegate's actor so the non-Sendable intermediate never crosses.
        let status = await center.notificationSettings().authorizationStatus
        return Self.map(status)
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let state = await currentAuthState()
        switch state {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            // Don't re-prompt — the user said no; we respect that and fall back to the
            // in-app toast + menu bar tint + lastError surface.
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                hasRequested = true
                TMEjectLog.ui.info("UNUserNotificationCenter authorization: granted=\(granted)")
                return granted
            } catch {
                TMEjectLog.ui.error("UNUserNotificationCenter authorization request failed: \(error)")
                return false
            }
        }
    }

    func deliver(title: String, body: String, category: NotificationCategory) async {
        let state = await currentAuthState()
        guard state == .authorized || state == .provisional || state == .ephemeral else {
            TMEjectLog.ui.debug("Skipping system notification — auth state is \(state.rawValue)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category.rawValue
        let request = UNNotificationRequest(
            identifier: "\(category.rawValue).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            TMEjectLog.ui.error("UNUserNotificationCenter.add failed: \(error)")
        }
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationAuthState {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        case .authorized:    return .authorized
        case .provisional:   return .provisional
        case .ephemeral:     return .ephemeral
        @unknown default:    return .denied
        }
    }
}

import Foundation
@testable import TMEject

actor FakeSystemNotifier: SystemNotifier {
    struct DeliveredNotification: Equatable {
        let title: String
        let body: String
        let category: NotificationCategory
    }

    private(set) var delivered: [DeliveredNotification] = []
    private(set) var authRequestCount = 0
    var authState: NotificationAuthState = .notDetermined
    var grantOnRequest: Bool = true

    func setAuthState(_ s: NotificationAuthState) { authState = s }
    func setGrant(_ g: Bool) { grantOnRequest = g }

    func currentAuthState() async -> NotificationAuthState { authState }

    func requestAuthorizationIfNeeded() async -> Bool {
        authRequestCount += 1
        switch authState {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            authState = grantOnRequest ? .authorized : .denied
            return grantOnRequest
        }
    }

    func deliver(title: String, body: String, category: NotificationCategory) async {
        guard authState == .authorized || authState == .provisional || authState == .ephemeral else {
            return
        }
        delivered.append(DeliveredNotification(title: title, body: body, category: category))
    }
}

@MainActor
final class FakeToastPresenter: ToastPresenter {
    struct Presented: Equatable {
        let level: AppCommand.ToastLevel
        let message: String
        let subtitle: String?
        let kind: AppCoordinator.ToastKind
        let actionLabel: String?
    }
    private(set) var presented: [Presented] = []
    func present(level: AppCommand.ToastLevel,
                 message: String,
                 subtitle: String?,
                 kind: AppCoordinator.ToastKind,
                 actionLabel: String?) {
        presented.append(Presented(level: level, message: message, subtitle: subtitle,
                                    kind: kind, actionLabel: actionLabel))
    }
}

import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let ejectAndLock = Self("ejectAndLock", default: .init(.e, modifiers: [.control, .option, .command]))
}

@MainActor
final class HotkeyMonitor {
    private weak var coordinator: AppCoordinator?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func register() {
        KeyboardShortcuts.onKeyUp(for: .ejectAndLock) { [weak self] in
            UIActionLogger.logAction("Hotkey: Eject & Lock")
            self?.coordinator?.requestEjectAndLock()
        }
        TMEjectLog.ui.info("Hotkey registered: ejectAndLock (default ⌃⌥⌘E)")
    }
}

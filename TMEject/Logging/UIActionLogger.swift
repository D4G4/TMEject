import Foundation

enum UIActionLogger {
    static func windowOpened(_ name: String) {
        TMEjectLog.ui.info("Window opened: \(name)")
    }

    static func windowClosed(_ name: String) {
        TMEjectLog.ui.info("Window closed: \(name)")
    }

    static func buttonTapped(_ name: String, context: String = "") {
        if context.isEmpty {
            TMEjectLog.ui.info("Button tapped: \(name)")
        } else {
            TMEjectLog.ui.info("Button tapped: \(name) [\(context)]")
        }
    }

    static func menuItemSelected(_ name: String, context: String = "") {
        if context.isEmpty {
            TMEjectLog.ui.info("Menu item: \(name)")
        } else {
            TMEjectLog.ui.info("Menu item: \(name) [\(context)]")
        }
    }

    static func tabSelected(_ name: String) {
        TMEjectLog.ui.info("Tab selected: \(name)")
    }

    static func settingChanged(_ name: String, value: String) {
        TMEjectLog.ui.info("Setting changed: \(name) = \(value)")
    }

    static func onboardingStep(_ step: String) {
        TMEjectLog.ui.info("Onboarding: \(step)")
    }

    static func logAction(_ action: String, context: String = "") {
        if context.isEmpty {
            TMEjectLog.ui.info("Action: \(action)")
        } else {
            TMEjectLog.ui.info("Action: \(action) [\(context)]")
        }
    }
}

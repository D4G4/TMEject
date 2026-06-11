import SwiftUI
import KeyboardShortcuts

@main
struct TMEjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        TMEjectLog.pruneOldLogs()
        TMEjectLog.app.info("TMEject launched")
    }

    var body: some Scene {
        MenuBarExtra("TMEject", systemImage: menuBarIconName(for: delegate.coordinator.state)) {
            MenuBarContentView(coordinator: delegate.coordinator)
        }
        .menuBarExtraStyle(.window)
    }

    private func menuBarIconName(for state: AppState) -> String {
        switch state {
        case .idle:             return "eject.fill"
        case .backingUp:        return "arrow.triangle.2.circlepath"
        case .confirming:       return "checkmark.circle"
        case .ejecting:         return "eject.circle.fill"
        case .idleEjectFailed:  return "exclamationmark.triangle.fill"
        }
    }
}

struct MenuBarContentView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline(for: coordinator.state))
                .font(.headline)

            if let err = coordinator.lastError {
                Text("Last error: \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Divider()

            Button("Eject now") {
                coordinator.requestManualEject(lock: false)
            }
            .disabled(!coordinator.isManualEjectAllowed)

            HStack(spacing: 4) {
                Button("Eject & Lock") {
                    coordinator.requestEjectAndLock()
                }
                .disabled(!coordinator.isEjectAndLockAllowed)
                Spacer()
                KeyboardShortcuts.Recorder(for: .ejectAndLock)
                    .frame(width: 90)
            }

            Divider()

            Button("Settings…") {
                UIActionLogger.menuItemSelected("Open Settings")
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.preferencesController.show()
                }
            }
            .keyboardShortcut(",", modifiers: [.command])

            Button("Reveal logs in Finder") {
                LogExporter.revealInFinder()
                UIActionLogger.menuItemSelected("Reveal logs")
            }

            Button("Quit TMEject") {
                UIActionLogger.menuItemSelected("Quit")
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
    }

    private func headline(for state: AppState) -> String {
        switch state {
        case .idle:             return "Idle"
        case .backingUp:        return "Backing up…"
        case .confirming:       return "Confirming…"
        case .ejecting:         return "Ejecting…"
        case .idleEjectFailed:  return "Eject failed (idle)"
        }
    }
}

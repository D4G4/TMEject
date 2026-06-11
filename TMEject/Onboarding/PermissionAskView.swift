import SwiftUI

struct PermissionAskView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var notificationGranted: Bool?
    @State private var requestInFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notifications & Shortcut")
                        .font(.title2).bold()
                    Text("Two quick setup items — both are optional.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("System notifications")
                    .font(.headline)
                Text("When a backup finishes or an eject fails, TMEject will post a system notification you'll see even when the menu bar is hidden.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(requestInFlight ? "Asking…" : "Allow notifications") {
                        requestInFlight = true
                        Task {
                            let granted = await coordinator.requestNotificationAuthIfNeeded()
                            await MainActor.run {
                                notificationGranted = granted
                                requestInFlight = false
                            }
                        }
                    }
                    .disabled(requestInFlight || notificationGranted == true)
                    if let granted = notificationGranted {
                        Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(granted ? .green : .red)
                        Text(granted ? "Granted" : "Denied — TMEject will fall back to its in-app toast and a tinted menu bar icon.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Eject & Lock shortcut")
                    .font(.headline)
                Text("Press the key combination below any time to stop the current backup (if any), eject the drive, and lock the screen — useful before walking away from your desk.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Default: ")
                        .foregroundStyle(.secondary)
                    HotkeyChip(text: "⌃ ⌥ ⌘ E")
                    Spacer()
                }
                Text("You can change it any time in Settings → General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(28)
    }
}

private struct HotkeyChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}

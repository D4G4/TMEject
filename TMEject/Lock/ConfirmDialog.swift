import AppKit

/// Abstracted so tests can pre-answer the confirmation without rendering NSAlert.
protocol ConfirmDialog: Sendable {
    func confirmStopAndEject() async -> Bool
}

struct LiveConfirmDialog: ConfirmDialog {
    @MainActor
    private func runAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "A backup is in progress."
        alert.informativeText = "Stop the backup, eject the drive, and lock the screen?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop, Eject & Lock")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func confirmStopAndEject() async -> Bool {
        await MainActor.run { runAlert() }
    }
}

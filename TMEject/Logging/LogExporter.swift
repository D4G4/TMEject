import AppKit

enum LogExporter {
    static func exportToClipboard() {
        let content = TMEjectLog.export()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    static func revealInFinder() {
        let url = TMEjectLog.currentSessionDayDirectoryURL ?? TMEjectLog.logDirectoryURL
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

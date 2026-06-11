import SwiftUI

@main
struct TMEjectApp: App {
    var body: some Scene {
        MenuBarExtra("TMEject", systemImage: "eject.fill") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Idle")
                .font(.headline)
            Divider()
            Button("Quit TMEject") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 220)
    }
}

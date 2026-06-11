import SwiftUI
import AppKit

struct AboutTab: View {
    @AppStorage(SettingsKey.betaChannel) private var betaChannel = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            if let appIcon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
            } else {
                Image(systemName: "eject.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .foregroundStyle(Color.accentColor)
            }
            Text("TMEject")
                .font(.title2)
                .bold()
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Auto-ejects your Time Machine drive after each successful backup.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .foregroundStyle(.secondary)

            Divider()

            Button("Check for Updates…") {
                UIActionLogger.buttonTapped("Check for Updates", context: "About")
                // Sparkle wiring lands in Step 14.
            }
            Toggle("Receive beta updates", isOn: $betaChannel)
                .onChange(of: betaChannel) { _, on in
                    UIActionLogger.settingChanged("betaChannel", value: "\(on)")
                }
                .padding(.horizontal, 80)

            Divider()

            HStack(spacing: 8) {
                Button("GitHub") {
                    UIActionLogger.buttonTapped("Open GitHub", context: "About")
                    if let url = URL(string: "https://github.com/dakshg/TMEject") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text("·")
                    .foregroundStyle(.secondary)
                Text("Built by Daksh Gargas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

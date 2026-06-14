import SwiftUI

struct OnboardingView: View {
    @ObservedObject var coordinator: AppCoordinator
    let onComplete: () -> Void

    @State private var page: Int = 0
    @AppStorage(SettingsKey.autoEjectEnabled) private var autoEjectEnabled = false
    @AppStorage(SettingsKey.cooldownMinutes)  private var cooldownMinutes = 30

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                pageDots
                Spacer()
                navigation
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
        }
        .frame(width: 640, height: 460)
        .onAppear { UIActionLogger.onboardingStep("page \(page + 1) appeared") }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case 0: WelcomePage(autoEjectEnabled: $autoEjectEnabled, cooldownMinutes: $cooldownMinutes)
        case 1: PermissionAskView(coordinator: coordinator)
        default: FDAOnboardingPage(coordinator: coordinator, onSkip: { onComplete() })
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    @ViewBuilder
    private var navigation: some View {
        HStack(spacing: 8) {
            if page > 0 {
                Button("Back") {
                    UIActionLogger.buttonTapped("Onboarding Back", context: "page \(page + 1)")
                    page -= 1
                }
            }
            if page < 2 {
                Button("Continue") {
                    UIActionLogger.buttonTapped("Onboarding Continue", context: "page \(page + 1)")
                    page += 1
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Finish") {
                    UIActionLogger.buttonTapped("Onboarding Finish", context: "page 3")
                    onComplete()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct WelcomePage: View {
    @Binding var autoEjectEnabled: Bool
    @Binding var cooldownMinutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "eject.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to TMEject")
                        .font(.title2).bold()
                    Text("Auto-eject your Time Machine drive after each backup.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("TMEject watches Time Machine. When a backup finishes successfully, it ejects the drive so you can safely unplug your monitor, dock, or external SSD.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Eject the drive after a successful backup", isOn: $autoEjectEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: autoEjectEnabled) { _, v in
                        UIActionLogger.settingChanged("autoEjectEnabled", value: "\(v)")
                    }
                Picker("Cooldown between auto-ejects", selection: $cooldownMinutes) {
                    ForEach(CooldownOption.allCases) { opt in Text(opt.label).tag(opt.rawValue) }
                }
                .disabled(!autoEjectEnabled)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Time Machine runs hourly by default. Auto-eject plus a tight cooldown can trap you — the drive ejects, the next backup can't reach it, and you have to physically reconnect. The 30-minute cooldown is the recommended balance.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Spacer()
        }
        .padding(28)
    }
}

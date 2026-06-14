import SwiftUI

/// Onboarding B — single-screen modal explainer. Default first-launch path is the lean
/// HUD only (no modal); this modal shows when the user explicitly chooses "Reset
/// onboarding" from Settings → Troubleshooting.
struct OnboardingView: View {
    @ObservedObject var coordinator: AppCoordinator
    let onComplete: () -> Void

    @AppStorage(SettingsKey.autoEjectEnabled) private var autoEjectEnabled = true

    var body: some View {
        VStack(spacing: 0) {
            heroSection
            pointsSection
            Divider().opacity(0.6)
            footerSection
        }
        .frame(width: 420)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: Spacing.hairline)
        )
        .onAppear { UIActionLogger.onboardingStep("modal appeared") }
    }

    private var heroSection: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.ritualSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.ritual.opacity(0.3), lineWidth: Spacing.hairline)
                    )
                    .frame(width: 64, height: 64)
                Image(systemName: "eject.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.ritual)
            }
            VStack(spacing: 6) {
                Text("Unplug without the warning")
                    .font(.system(size: 19, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("TMEject ejects your Time Machine drive the moment a backup finishes — so it’s always safe to pull the cable.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 320)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 34)
        .padding(.bottom, 22)
    }

    private var pointsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            point(icon: "externaldrive.fill", iconBg: Color.secondary.opacity(0.12),
                  iconFg: Color.secondary,
                  title: "It runs in the menu bar",
                  subtitle: "No Dock icon, no window. A small glyph shows what it’s doing.")
            point(icon: "lock.fill", iconBg: Color.ritualSoft, iconFg: Color.ritual,
                  title: "Eject & Lock, in one motion",
                  subtitle: "Press ⌃⌥⌘E when you stand up to leave.")
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 12)
    }

    private func point(icon: String, iconBg: Color, iconFg: Color,
                       title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(iconBg)
                    .frame(width: 22, height: 22)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconFg)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
            }
            Spacer(minLength: 0)
        }
    }

    private var footerSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Text("Turn on auto-eject after backups")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Toggle("", isOn: Binding(
                    get: { autoEjectEnabled },
                    set: { coordinator.setAutoEjectEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .scaleEffect(0.95)
            }
            Button("Start using TMEject") {
                UIActionLogger.buttonTapped("Onboarding Finish")
                onComplete()
            }
            .buttonStyle(PrimaryBlueButtonStyle())
            .frame(height: 36)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 30)
        .padding(.top, 16)
        .padding(.bottom, 22)
    }
}

import SwiftUI
import AppKit

// MARK: - Model

/// Drives the three-step onboarding flow. Held by `OnboardingFlowWindowController` and
/// passed into `OnboardingFlowView` as an `@ObservedObject`.
///
/// Dependencies are injected as protocols so `OnboardingFlowTests` can drive the model
/// with a fake FDA prober (denied → granted) and a fake notifier (granted/denied/no-op)
/// without touching the live system.
@MainActor
final class OnboardingFlowModel: ObservableObject {
    @Published private(set) var step: OnboardingStep = .intro
    /// Inline error rendered under Step 2's CTAs when "I've granted it" was tapped but the
    /// re-probe still returns `.denied` (or `.unknown`). Cleared on advance / re-tap.
    @Published private(set) var fdaError: String?
    /// True while an async re-probe / notification request is in flight, so the primary
    /// CTA can be disabled and show a progress indicator.
    @Published private(set) var isWorking: Bool = false

    private let coordinator: AppCoordinator
    private let fdaProber: FullDiskAccessProbing
    private let notifier: SystemNotifier
    private let defaults: UserDefaults
    private let openURL: @MainActor (URL) -> Void
    private let onFinish: @MainActor () -> Void

    init(coordinator: AppCoordinator,
         fdaProber: FullDiskAccessProbing,
         notifier: SystemNotifier,
         defaults: UserDefaults = .standard,
         openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
         onFinish: @escaping @MainActor () -> Void) {
        self.coordinator = coordinator
        self.fdaProber = fdaProber
        self.notifier = notifier
        self.defaults = defaults
        self.openURL = openURL
        self.onFinish = onFinish
    }

    // MARK: - Step 1

    func tapGetStarted() {
        UIActionLogger.buttonTapped("Get started", context: "Onboarding/Intro")
        advance(to: .notifications)
    }

    // MARK: - Step 2 — Notifications

    /// Ask for UN authorization. Result doesn't gate progression — denying is a
    /// legitimate choice; we just skip system notifications and the user still
    /// gets toasts + menu bar icon state.
    func tapAllowNotifications() async {
        UIActionLogger.buttonTapped("Allow", context: "Onboarding/Notifications")
        guard !isWorking else { return }
        isWorking = true
        _ = await notifier.requestAuthorizationIfNeeded()
        isWorking = false
        advance(to: .fullDiskAccess)
    }

    func tapSkipNotifications() {
        UIActionLogger.buttonTapped("Skip", context: "Onboarding/Notifications")
        advance(to: .fullDiskAccess)
    }

    // MARK: - Step 3 — Full Disk Access

    func tapOpenSystemSettingsForFDA() {
        UIActionLogger.buttonTapped("Open System Settings", context: "Onboarding/FDA")
        openURL(SystemSettingsLink.fullDiskAccess)
    }

    /// Re-probe FDA via the injected prober. If `.granted`, push the new state into the
    /// coordinator (so the popover pill / Settings status updates immediately) and
    /// advance. Otherwise surface an inline error and stay on this step.
    func tapIveGrantedFDA() async {
        UIActionLogger.buttonTapped("I've granted it", context: "Onboarding/FDA")
        guard !isWorking else { return }
        isWorking = true
        fdaError = nil
        let state = await fdaProber.currentState()
        isWorking = false
        if state == .granted {
            // Sync the coordinator's published value so the rest of the UI reflects
            // the grant without waiting for the next debounced auto-probe.
            coordinator.refreshFDAState(force: true)
            complete()
        } else {
            fdaError = "Full Disk Access still isn't granted. In System Settings → " +
                "Privacy & Security → Full Disk Access, toggle TMEject on, then tap " +
                "“I've granted it” again."
        }
    }

    func tapSkipFDA() {
        UIActionLogger.buttonTapped("Skip for now", context: "Onboarding/FDA")
        fdaError = nil
        complete()
    }

    // MARK: - Private

    private func advance(to next: OnboardingStep) {
        UIActionLogger.onboardingStep("advance \(step) → \(next)")
        withAnimation(.easeInOut(duration: 0.2)) {
            step = next
        }
    }

    private func complete() {
        UIActionLogger.onboardingStep("completed — hasCompletedOnboarding=true")
        defaults.set(true, forKey: SettingsKey.hasCompletedOnboarding)
        onFinish()
    }
}

// MARK: - View

/// Three-step first-install onboarding. Step indicator + paged content + a CTA region per
/// step. Each step view is small and self-contained; switching steps cross-fades for the
/// 200ms duration the spec calls out.
struct OnboardingFlowView: View {
    @ObservedObject var model: OnboardingFlowModel

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(currentIndex: model.step.pageIndex,
                          totalCount: OnboardingStep.pageCount)
                .padding(.top, 26)
                .padding(.bottom, 18)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 540)
        .surfaceBackground(.window)
        .onAppear { UIActionLogger.onboardingStep("flow window appeared @ \(model.step)") }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            switch model.step {
            case .intro:
                OnboardingIntroStep(onPrimary: { model.tapGetStarted() })
                    .transition(.opacity)
            case .notifications:
                OnboardingNotificationsStep(
                    isWorking: model.isWorking,
                    onAllow: { Task { await model.tapAllowNotifications() } },
                    onSkip: { model.tapSkipNotifications() }
                )
                .transition(.opacity)
            case .fullDiskAccess:
                OnboardingFDAStep(
                    isWorking: model.isWorking,
                    errorMessage: model.fdaError,
                    onOpenSettings: { model.tapOpenSystemSettingsForFDA() },
                    onConfirmGranted: { Task { await model.tapIveGrantedFDA() } },
                    onSkip: { model.tapSkipFDA() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.step)
    }
}

// MARK: - Step indicator

/// 3 dots, filled = visited (current or past). Matches the "quiet appliance" tone — no
/// labels, no fancy progress bar.
struct StepIndicator: View {
    let currentIndex: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalCount, id: \.self) { i in
                Circle()
                    .fill(i <= currentIndex ? Color.primary.opacity(0.85)
                                            : Color.primary.opacity(0.18))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(currentIndex + 1) of \(totalCount)")
    }
}

// MARK: - Step 1: Intro

struct OnboardingIntroStep: View {
    let onPrimary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            appIcon
                .padding(.bottom, 24)

            Text("Eject your Time Machine drive,\nthe moment a backup finishes.")
                .font(.system(size: 19, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)
                .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 16) {
                IntroBullet(icon: "externaldrive.badge.checkmark",
                            iconBg: Color.ritualSoft, iconFg: Color.ritual,
                            title: "Auto-eject after each backup",
                            caption: "Drive unmounts cleanly when Time Machine is done.")
                IntroBullet(icon: "lock.fill",
                            iconBg: Color.ritualSoft, iconFg: Color.ritual,
                            title: "One-keystroke “Eject & Lock”",
                            caption: "⌃⌥⌘E ejects the drive and locks the screen.")
                IntroBullet(icon: "shield.lefthalf.filled",
                            iconBg: Color.ritualSoft, iconFg: Color.ritual,
                            title: "Foreign-drive protection",
                            caption: "Time Machine drives from other Macs are ejected automatically.")
            }
            .padding(.horizontal, 40)

            Spacer(minLength: 0)

            primaryCTA
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
        }
    }

    private var appIcon: some View {
        Group {
            if let nsIcon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: nsIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // Pre-icon-wiring fallback — safe default.
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.ritualSoft)
                    Image(systemName: "eject.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Color.ritual)
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    private var primaryCTA: some View {
        Button(action: onPrimary) {
            Text("Get started")
        }
        .buttonStyle(OnboardingPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
    }
}

private struct IntroBullet: View {
    let icon: String
    let iconBg: Color
    let iconFg: Color
    let title: String
    let caption: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(iconBg)
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconFg)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Step 2: Full Disk Access

struct OnboardingFDAStep: View {
    let isWorking: Bool
    let errorMessage: String?
    let onOpenSettings: () -> Void
    let onConfirmGranted: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            stepIcon(systemName: "lock.fill", tint: Color.ritual)
                .padding(.bottom, 22)

            Text("Grant Full Disk Access")
                .font(.system(size: 19, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)

            Text("Required so TMEject can detect when a Time Machine backup actually " +
                 "finishes successfully. Without it, auto-eject won't fire.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 40)
                .padding(.bottom, 18)

            if let errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(errorMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 40)
                .padding(.bottom, 14)
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button(action: onOpenSettings) {
                    Text("Open System Settings")
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)

                Button(action: onConfirmGranted) {
                    HStack(spacing: 6) {
                        if isWorking { ProgressView().controlSize(.small).scaleEffect(0.8) }
                        Text(isWorking ? "Checking…" : "I've granted it")
                    }
                }
                .buttonStyle(OnboardingSecondaryButtonStyle())
                .disabled(isWorking)

                Button("Skip for now", action: onSkip)
                    .buttonStyle(OnboardingTertiaryLinkStyle())
                    .padding(.top, 2)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 28)
        }
        .animation(.easeInOut(duration: 0.15), value: errorMessage)
    }
}

// MARK: - Step 2: Notifications

/// Notifications opt-in. Copy explicitly promises "very few notifications" —
/// we honour that by only firing UN notifications on actual failures (eject
/// failed after retries, foreign-drive eject failed, FDA required nag).
/// Successes are silent — the drive being ejected IS the signal.
struct OnboardingNotificationsStep: View {
    let isWorking: Bool
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            stepIcon(systemName: "bell.fill", tint: Color.secondary)
                .padding(.bottom, 22)

            Text("Stay informed, quietly")
                .font(.system(size: 19, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)

            Text("TMEject sends very few notifications — only when something needs " +
                 "your attention (an eject failed, a permission is missing). " +
                 "You can change this anytime in System Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 40)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button(action: onAllow) {
                    HStack(spacing: 6) {
                        if isWorking { ProgressView().controlSize(.small).scaleEffect(0.8) }
                        Text(isWorking ? "Requesting…" : "Allow")
                    }
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(isWorking)
                .keyboardShortcut(.defaultAction)

                Button("Skip", action: onSkip)
                    .buttonStyle(OnboardingTertiaryLinkStyle())
                    .padding(.top, 2)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
    }
}

// MARK: - Shared step icon

/// 48pt rounded-square glyph used by Step 2 and Step 3. Tinted by the step.
@ViewBuilder
private func stepIcon(systemName: String, tint: Color) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(tint.opacity(0.25), lineWidth: Spacing.hairline)
            )
            .frame(width: 56, height: 56)
        Image(systemName: systemName)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(tint)
    }
}

// MARK: - Button styles (onboarding-local; deliberately distinct from popover styles)

/// Full-width prominent CTA — taller than `PrimaryBlueButtonStyle` because the onboarding
/// surface has more room than the popover.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Secondary CTA on the FDA step — neutral fill so it doesn't compete with the primary
/// "Open System Settings" button.
struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Tertiary "skip" link — small, low-emphasis, no background. Replaces the prior
/// `.plain` + manual color pattern so the three Skip links match.
struct OnboardingTertiaryLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

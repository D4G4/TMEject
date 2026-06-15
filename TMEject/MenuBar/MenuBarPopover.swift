import SwiftUI
import KeyboardShortcuts

/// Popover B — ceremonial big-glyph layout. Hero ring + drive name + a single ritual CTA.
struct MenuBarPopoverView: View {
    @ObservedObject var coordinator: AppCoordinator
    /// Opens the Preferences window. Injected from `TMEjectApp` so we don't have to launder
    /// the AppDelegate through `NSApp.delegate as? AppDelegate` — that downcast silently
    /// returns nil from inside the SwiftUI MenuBarExtra popover scope on macOS 26.x, which
    /// is why the gear button used to do nothing.
    let openPreferences: () -> Void
    @State private var whyExpanded = false
    /// Read-only mirror of the auto-eject setting — used by the FDA pill to decide whether
    /// to nag about Full Disk Access. The toggle itself lives in Settings now; the bottom
    /// row's right slot is the Quit button.
    @AppStorage(SettingsKey.autoEjectEnabled) private var autoEjectEnabled = true

    var body: some View {
        ZStack {
            popoverContent
            if coordinator.ritualConfirmPct != nil {
                ritualConfirmOverlay
                    .transition(.opacity)
            }
        }
        .frame(width: Spacing.popoverWidth)
        .surfaceBackground(.popover)
        .animation(.easeInOut(duration: 0.18), value: coordinator.state)
        .animation(.easeInOut(duration: 0.18), value: coordinator.ritualConfirmPct != nil)
        .onAppear {
            coordinator.refreshLoginItemStatus()
            coordinator.refreshFDAState()
            coordinator.refreshDrivePresence()
        }
    }

    // MARK: - Main popover

    private var popoverContent: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                heroSection
                gearButton
                    .padding(10)
            }
            buttonsSection
        }
    }

    private var gearButton: some View {
        Button {
            UIActionLogger.menuItemSelected("Open Settings")
            openPreferences()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    private var heroSection: some View {
        VStack(spacing: 0) {
            heroRing
                .padding(.top, 24)
                .padding(.bottom, 14)
            Text(driveTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(coordinator.drivePresent ? .primary : .secondary)
            Text(subLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
                .frame(minHeight: 16)
            if coordinator.state == .idleEjectFailed {
                whyDisclosure
                    .padding(.top, 8)
                    .padding(.horizontal, 22)
            }
            fdaPill
                .padding(.top, 10)
                .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
    }

    private var heroRing: some View {
        ZStack {
            // Inner colored fill circle (62×62, inset 5pt from the 72pt frame).
            Circle()
                .fill(heroFillColor)
                .padding(5)
                .overlay(
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: Spacing.hairline)
                        .padding(5)
                )
            if let pct = ringProgress {
                RingProgress(size: 72, stroke: 3, pct: pct, color: heroTint ?? .secondary)
            } else if ringIndeterminate {
                RingProgress(size: 72, stroke: 3, pct: nil, color: heroTint ?? .secondary)
            }
            heroGlyph
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(heroGlyphColor)
        }
        .frame(width: 72, height: 72)
    }

    @ViewBuilder
    private var heroGlyph: some View {
        switch coordinator.state {
        case .idleEjectFailed:  Image(systemName: "exclamationmark.triangle.fill")
        case .confirming:       Image(systemName: "checkmark")
        case .ejecting:         Image(systemName: "eject.fill")
        case .backingUp, .idle: Image(systemName: "externaldrive.fill")
        }
    }

    private var glyphSize: CGFloat {
        switch coordinator.state {
        case .idleEjectFailed:  return 23
        case .confirming:       return 26
        case .ejecting:         return 25
        case .backingUp, .idle: return 28
        }
    }

    private var heroTint: Color? {
        switch coordinator.state {
        case .idleEjectFailed:  return .orange
        case .confirming:       return .green
        case .backingUp, .ejecting: return .blue
        case .idle:             return nil
        }
    }

    private var heroFillColor: Color {
        if let tint = heroTint { return tint.opacity(0.13) }
        return Color.secondary.opacity(0.08)
    }

    private var heroGlyphColor: Color {
        if !coordinator.drivePresent { return .secondary.opacity(0.5) }
        return heroTint ?? .secondary
    }

    private var ringProgress: Double? {
        switch coordinator.state {
        case .ejecting: return max(8, coordinator.ejectPct)
        case .backingUp: return coordinator.backupPct
        default:        return nil
        }
    }

    private var ringIndeterminate: Bool {
        coordinator.state == .confirming
    }

    private var driveTitle: String {
        coordinator.drivePresent ? (coordinator.driveName ?? "Backup Drive") : "No backup drive"
    }

    private var subLine: String {
        switch coordinator.state {
        case .idle:
            if !coordinator.drivePresent { return "Connect a drive to enable eject" }
            if let last = coordinator.lastBackupCompletedAt {
                let f = DateFormatter()
                f.dateFormat = "h:mm a"
                return "Connected · backed up \(f.string(from: last))"
            }
            return "Connected"
        case .backingUp:        return "Backing up · \(Int(coordinator.backupPct.rounded()))%"
        case .confirming:       return "Backup complete — verifying"
        case .ejecting:         return "Ejecting safely · attempt \(coordinator.ejectAttempt)"
        case .idleEjectFailed:  return "Couldn’t eject — drive still in use"
        }
    }

    // MARK: - Buttons

    private var buttonsSection: some View {
        VStack(spacing: 9) {
            if coordinator.state == .idleEjectFailed {
                HStack(spacing: 8) {
                    Button("Try again") {
                        UIActionLogger.buttonTapped("Retry eject", context: "popover-failed")
                        coordinator.requestManualEject(lock: false)
                    }
                    .buttonStyle(PrimaryBlueButtonStyle())
                    .frame(maxWidth: .infinity)

                    Button("Force eject") {
                        UIActionLogger.buttonTapped("Force eject", context: "popover-failed")
                        coordinator.requestManualEject(lock: false)
                    }
                    .buttonStyle(NeutralButtonStyle())
                    .frame(maxWidth: .infinity)
                }
            } else {
                ritualButton
                HStack(alignment: .center) {
                    Button("Eject now") {
                        UIActionLogger.menuItemSelected("Eject now")
                        coordinator.requestManualEject(lock: false)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ejectNowDisabled ? Color.blue.opacity(0.45) : Color.blue)
                    .disabled(ejectNowDisabled)
                    Spacer()
                    quitButton
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, Spacing.popoverPaddingHorizontal)
        .padding(.bottom, Spacing.popoverPaddingVertical + 1)
        .padding(.top, 12)
    }

    private var ejectNowDisabled: Bool {
        !coordinator.drivePresent || coordinator.state == .ejecting
    }

    private var ritualButton: some View {
        Button {
            UIActionLogger.menuItemSelected("Eject & Lock (ritual)")
            coordinator.startEjectAndLockRitual()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Eject & Lock")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer().frame(width: 4)
                hotkeyKeycaps
            }
            .frame(maxWidth: .infinity)
            .frame(height: Spacing.ritualHeight)
            .background(Color.ritualSoft,
                        in: RoundedRectangle(cornerRadius: Spacing.ritualCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.ritualCorner)
                    .strokeBorder(Color.ritual.opacity(0.38), lineWidth: Spacing.hairline)
            )
            .foregroundStyle(Color.ritualStrong)
        }
        .buttonStyle(.plain)
        .disabled(!coordinator.drivePresent)
        .opacity(coordinator.drivePresent ? 1 : 0.45)
    }

    private var hotkeyKeycaps: some View {
        let combo = KeyboardShortcuts.getShortcut(for: .ejectAndLock)
        let keys = combo?.description ?? "⌃ ⌥ ⌘ E"
        return Text(keys)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .tracking(1)
    }

    /// Bottom-right action — terminates the app. Matches the "Eject now" treatment on the
    /// left (12pt medium plain text) so the row reads as a balanced pair. Auto-eject lives
    /// in Settings; the popover keeps only verbs that act on "right now."
    private var quitButton: some View {
        Button("Quit") {
            UIActionLogger.menuItemSelected("Quit")
            NSApp.terminate(nil)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Why? disclosure

    private var whyDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { whyExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: whyExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Why?")
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if whyExpanded {
                let text = coordinator.lastError ?? "held by mds_stores (pid 412)"
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.secondary.opacity(0.18), lineWidth: Spacing.hairline)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - FDA pill (popover variant)

    @ViewBuilder
    private var fdaPill: some View {
        let needsFDA = autoEjectEnabled && coordinator.fdaState != .granted
        if needsFDA {
            Button {
                UIActionLogger.buttonTapped("Open Full Disk Access", context: "popover-pill")
                NSWorkspace.shared.open(SystemSettingsLink.fullDiskAccess)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 11))
                    Text("Auto-eject paused · Grant Full Disk Access")
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.orange.opacity(0.55), lineWidth: Spacing.hairline)
                )
                .foregroundStyle(Color.orange)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Ritual confirm overlay

    private var ritualConfirmOverlay: some View {
        VStack(spacing: 12) {
            ZStack {
                RingProgress(size: 56, stroke: 3, pct: coordinator.ritualConfirmPct, color: .ritual)
                Image(systemName: "lock.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.ritual)
            }
            .frame(width: 56, height: 56)

            VStack(spacing: 3) {
                Text("Eject & lock")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(coordinator.driveName ?? "Backup Drive") will be ejected,\nthen your screen will lock.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            Button("Cancel") {
                coordinator.cancelEjectAndLockRitual()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Always solid — the overlay must fully cover the popover content underneath in BOTH
        // translucency modes (per Step 12.7 amendment §7).
        .background(Color.surfacePopover)
    }
}

// MARK: - Button styles

struct PrimaryBlueButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: Spacing.popoverRowHeight)
            .background(Color.blue, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct NeutralButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: Spacing.popoverRowHeight)
            .background(Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

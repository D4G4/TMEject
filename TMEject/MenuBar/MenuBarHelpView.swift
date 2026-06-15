import SwiftUI
import AppKit

/// Shown when the user taps "Can't find it" on the Launch HUD. Mirrors Blink's
/// `MenuBarHelpView` — explains visually how menu bar icons get hidden behind the notch
/// or overflow, lists honest recovery steps, and gives a guaranteed fallback entry point
/// ("Open TMEject Settings") so the app stays reachable even if the icon never reappears.
///
/// The original Step 11 implementation used an NSAlert with 4 lines of plain text. This
/// view replaces that with a proper window-style explanation matching the rest of the
/// design system.
struct MenuBarHelpView: View {
    let onOpenPreferences: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    NotchDiagram()
                        .frame(height: 92)
                        .frame(maxWidth: .infinity)
                    explanation
                    recoverySteps
                    fallback
                }
                .padding(28)
            }

            Divider()

            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Text("Got it")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.ritual)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where's the TMEject icon?")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("It's running — it just may be hidden in your menu bar.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why this happens")
                .font(.system(size: 14, weight: .semibold))
            Text("macOS lays out menu bar icons from the right edge, going left. On Macs with a notch — or when you have a lot of menu bar apps — the icons that don't fit get pushed under the notch and become invisible. TMEject's icon is there; you just can't see it.")
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recoverySteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How to bring it back")
                .font(.system(size: 14, weight: .semibold))
            step(number: 1, text: "Hold ⌘ (Command) and drag the TMEject icon to the right of the notch — if your menu bar has room there.")
            step(number: 2, text: "If the menu bar is full, quit a few other menu bar apps to free up space, or install a free menu bar manager like Ice (icemenubar.app) to reveal hidden icons.")
            step(number: 3, text: "If you use Bartender or iBar, open its preferences and make sure TMEject isn't in its hidden list.")
        }
    }

    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.ritual))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fallback: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("In the meantime")
                .font(.system(size: 14, weight: .semibold))
            Text("You can always open TMEject's settings from here, no menu bar icon required.")
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onOpenPreferences) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                    Text("Open TMEject Settings")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Stylized menu bar diagram showing icons being clipped behind the notch. Drawn entirely
/// in SwiftUI primitives — no asset dependency — so it always reads correctly across
/// macOS appearance changes. The TMEject icon sits just to the left of the notch at
/// 0.45 opacity to read as "swallowed."
private struct NotchDiagram: View {
    var body: some View {
        GeometryReader { geo in
            let barHeight: CGFloat = 38
            let notchWidth: CGFloat = 120
            let notchHeight: CGFloat = 26
            let iconSize: CGFloat = 22
            let centerX = geo.size.width / 2

            ZStack(alignment: .top) {
                // Menu bar strip.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(0.88))
                    .frame(height: barHeight)

                // System icons on the right (always visible).
                HStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Image(systemName: "magnifyingglass")
                    Text("9:41").font(.system(size: 12, weight: .medium))
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 14)
                .frame(height: barHeight)

                // TMEject icon being swallowed by the notch (just left of it).
                appIconChip
                    .frame(width: iconSize, height: iconSize)
                    .opacity(0.45)
                    .position(x: centerX - notchWidth / 2 - 4, y: barHeight / 2)

                // A faded neighbor further left, also clipped — sells the "overflow" idea.
                Image(systemName: "app.dashed")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.4))
                    .position(x: centerX - notchWidth / 2 - 34, y: barHeight / 2)

                // The notch itself, on top so it visually covers the icons under it.
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .fill(Color.black)
                    .frame(width: notchWidth, height: notchHeight)
                    .clipShape(.rect(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
                    .position(x: centerX, y: notchHeight / 2)
            }
        }
    }

    @ViewBuilder
    private var appIconChip: some View {
        if let nsIcon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: nsIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "eject.fill")
                .resizable()
                .scaledToFit()
                .padding(3)
                .foregroundStyle(Color.white.opacity(0.85))
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.ritual)
                )
        }
    }
}

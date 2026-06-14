import SwiftUI

/// Borderless HUD that surfaces "TMEject is running, here's where to look" on launch.
/// Mirrors Blink's `LaunchHUDView` pattern — two text elements (title + question), an
/// inline up-left arrow that pulses, and two action buttons.
///
/// The HUD doesn't depend on the menu bar icon being visible — it's its own window. The
/// user can dismiss either by clicking "I've found it" / "Can't find it" or by opening the
/// menu bar popover (the AppDelegate's `dismissLaunchHUDIfNeeded` runs from
/// `.onAppear` of the popover content).
struct LaunchHUDView: View {
    let onFound: () -> Void
    let onCantFind: () -> Void

    @State private var pulseArrow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                appIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text("TMEject is now active")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Can you see the eject icon in your menu bar?")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                // Points up-left — status items extend leftward from the right edge, so the
                // TMEject icon sits to the LEFT of the HUD's screen position.
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .offset(x: pulseArrow ? -3 : 0)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                               value: pulseArrow)
            }

            HStack(spacing: 8) {
                Button(action: onCantFind) {
                    Text("Can't find it")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onFound) {
                    Text("I've found it")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(NSColor.windowBackgroundColor))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 340)
        .surfaceBackground(.hud)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .onAppear { pulseArrow = true }
    }

    private var appIcon: some View {
        Group {
            if let nsIcon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: nsIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // Pre-app-icon-wiring fallback; safe default.
                Image(systemName: "eject.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .foregroundStyle(Color.ritual)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

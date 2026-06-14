import SwiftUI

struct LaunchHUDView: View {
    let onDismiss: () -> Void
    @State private var arrowOffset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Arrow points up-and-LEFT toward the menu bar icon. The HUD itself is anchored
            // top-right of the screen; the menu bar icon sits to the LEFT of the HUD's
            // position (menu bar items extend leftward from the system cluster). Anchoring
            // the arrow trailing — as the design CSS literal `right: 26px` suggested —
            // would point it at empty space. Leading + arrow.up.left is correct.
            ZStack {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.ritual)
                    .offset(y: arrowOffset)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26)
            .offset(y: -22)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    arrowOffset = -6
                }
            }

            Text("TMEject lives up here")
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, -4)

            Text("It watches your Time Machine backups and ejects the drive when they finish — once you turn that on.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .padding(.top, 5)

            HStack {
                Text("Click the eject icon to begin")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Got it") { onDismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.blue)
            }
            .padding(.top, 13)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 252)
        .surfaceBackground(.hud)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: Spacing.hairline)
        )
    }
}

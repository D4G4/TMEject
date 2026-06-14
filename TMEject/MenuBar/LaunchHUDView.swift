import SwiftUI

struct LaunchHUDView: View {
    let onDismiss: () -> Void
    @State private var arrowOffset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The arrow pulses up-and-down 1.6s, pointing at where the menu bar icon lives.
            ZStack {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.ritual)
                    .offset(y: arrowOffset)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 26)
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
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

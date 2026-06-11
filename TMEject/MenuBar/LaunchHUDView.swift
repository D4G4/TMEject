import SwiftUI

struct LaunchHUDView: View {
    let onFound: () -> Void
    let onCantFind: () -> Void

    @State private var arrowOffset: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if let appIcon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("TMEject is now active")
                        .font(.headline)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .offset(x: arrowOffset, y: -arrowOffset)
                }
                Text("Look for the ⏏︎ icon near the top of the screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("I've found it") { onFound() }
                        .keyboardShortcut(.defaultAction)
                    Button("Can't find it") { onCantFind() }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(width: 340, height: 124)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                arrowOffset = 4
            }
        }
    }
}

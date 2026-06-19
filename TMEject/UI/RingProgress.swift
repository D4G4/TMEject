import SwiftUI

/// Circular progress ring matching `icons.jsx::Ring`.
/// - `pct` nil → indeterminate, the arc rotates 360° every 0.9s.
/// - `pct` 0…100 → determinate, partial arc starting at -90° (top), clockwise.
struct RingProgress: View {
    let size: CGFloat
    let stroke: CGFloat
    let pct: Double?
    let color: Color
    var trackColor: Color = Color.secondary.opacity(0.3)

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: stroke)
            arc
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.3), value: pct ?? -1)
    }

    @ViewBuilder
    private var arc: some View {
        if let pct {
            let trim = max(0, min(1, pct / 100))
            Circle()
                .trim(from: 0, to: trim)
                .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        } else {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(rotation - 90))
                .onAppear {
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Determinate · 0/50/100") {
    HStack(spacing: 24) {
        RingProgress(size: 56, stroke: 4, pct: 0, color: .blue)
        RingProgress(size: 56, stroke: 4, pct: 50, color: .blue)
        RingProgress(size: 56, stroke: 4, pct: 100, color: .blue)
    }
    .padding(24)
    .background(Color.surfacePopover)
}

#Preview("Indeterminate · spinning") {
    RingProgress(size: 56, stroke: 4, pct: nil, color: .ritual)
        .padding(24)
        .background(Color.surfacePopover)
}
#endif

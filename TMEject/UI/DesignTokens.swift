import SwiftUI
import AppKit

/// Design tokens from the Claude Design pass (Step 12.7). System semantic colors are
/// preferred everywhere; the ritual teal is the ONLY custom color.
extension Color {
    /// Calm teal accent — the ritual moment color. Matches `oklch(0.62 0.085 195)` in light
    /// and `oklch(0.7 0.09 195)` in dark via sRGB approximation. The exact LCH conversion
    /// would need a CGColorSpace round-trip; sRGB is close enough for a UI accent and avoids
    /// the deployment-target wrinkle.
    static var ritual: Color {
        Color(.sRGB, red: 0.32, green: 0.58, blue: 0.58, opacity: 1)
    }

    /// Soft fill background for ritual surfaces (button background, onboarding glyph chip).
    /// 0.14 opacity matches the design's `--ritual-soft`.
    static var ritualSoft: Color {
        Color(.sRGB, red: 0.32, green: 0.58, blue: 0.58, opacity: 0.14)
    }

    /// Slightly darker ritual for label text on the soft fill — matches `--ritual-strong`.
    static var ritualStrong: Color {
        Color(.sRGB, red: 0.24, green: 0.50, blue: 0.50, opacity: 1)
    }

    // MARK: - Solid surfaces (Step 12.7 amendment)
    //
    // Light/dark trait-aware solid color tokens. The RGB values come from the Step 12.7
    // amendment translation table — picked to match the visual weight of the design CSS
    // materials (`--material-thick`, `--win-bg`, `--win-content`) under typical wallpapers
    // without actually being translucent.

    /// Popover / HUD / Toast background. Solid by default; SurfaceBackground swaps to
    /// `.regularMaterial` when the user opts in via Settings → General → Translucent windows.
    static let surfacePopover = Color(nsColor: NSColor(name: nil) { trait in
        Self.isDark(trait)
            ? NSColor(red: 0.188, green: 0.188, blue: 0.200, alpha: 1)  // #303033
            : NSColor(red: 0.980, green: 0.980, blue: 0.980, alpha: 1)  // #FAFAFA
    })

    /// Settings window background. Slightly cooler than `surfacePopover` to match macOS
    /// system Settings.
    static let surfaceWindow = Color(nsColor: NSColor(name: nil) { trait in
        Self.isDark(trait)
            ? NSColor(red: 0.149, green: 0.149, blue: 0.157, alpha: 1)  // #262628
            : NSColor(red: 0.925, green: 0.925, blue: 0.933, alpha: 1)  // #ECECEE
    })

    /// Settings group card background — a hair lighter than `surfaceWindow` so cards sit on
    /// the window with a soft tonal lift.
    static let surfaceCard = Color(nsColor: NSColor(name: nil) { trait in
        Self.isDark(trait)
            ? NSColor(red: 0.118, green: 0.118, blue: 0.125, alpha: 1)  // #1E1E20
            : NSColor(red: 0.988, green: 0.988, blue: 0.992, alpha: 1)  // #FCFCFD
    })

    /// The documented "is this trait dark mode" check; matches the canonical Apple pattern.
    private static func isDark(_ trait: NSAppearance) -> Bool {
        trait.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - SurfaceBackground modifier

enum SurfaceRole: Sendable {
    case popover
    case window
    case card
    case toast
    case hud
}

/// View modifier that paints the appropriate background for a surface role, choosing
/// between SwiftUI Material and the solid `Color.surface*` token based on the
/// `translucentSurfaces` user preference. @AppStorage propagation re-renders both modes
/// live; no window recreation needed.
struct SurfaceBackground: ViewModifier {
    @AppStorage(SettingsKey.translucentSurfaces) private var translucent: Bool = false
    let role: SurfaceRole

    func body(content: Content) -> some View {
        content.background(backgroundView)
    }

    @ViewBuilder
    private var backgroundView: some View {
        if translucent {
            switch role {
            case .popover, .toast, .hud:
                Rectangle().fill(.regularMaterial)
            case .window:
                Rectangle().fill(.thickMaterial)
            case .card:
                // The design's group card is a tonal lift on top of the window background.
                // Material on material wouldn't read right; in translucent mode the card
                // inherits the window's material via an opaque overlay at low strength.
                Color.surfaceCard.opacity(0.55)
            }
        } else {
            switch role {
            case .popover, .toast, .hud: Color.surfacePopover
            case .window:                Color.surfaceWindow
            case .card:                  Color.surfaceCard
            }
        }
    }
}

extension View {
    /// Paints the role's background (Material when translucentSurfaces=true, solid Color
    /// otherwise) behind the receiver. Call sites stay branch-free.
    func surfaceBackground(_ role: SurfaceRole) -> some View {
        modifier(SurfaceBackground(role: role))
    }
}

/// Layout constants from `spec.jsx`. Centralized so the popover, settings, HUD, and
/// onboarding agree on spacing without each surface re-inventing literals.
enum Spacing {
    static let popoverPaddingHorizontal: CGFloat = 14
    static let popoverPaddingVertical:   CGFloat = 13
    static let popoverCorner:            CGFloat = 13
    static let popoverWidth:             CGFloat = 300

    static let windowWidth:              CGFloat = 440
    static let windowCorner:             CGFloat = 11
    static let windowMaxHeight:          CGFloat = 560

    /// Popover compact row (e.g. Eject now + Auto-eject toggle line)
    static let popoverRowHeight:         CGFloat = 30
    /// Settings list row (per Apple's HIG for grouped lists)
    static let settingsRowHeight:        CGFloat = 44

    /// "Eject & Lock" ritual button height + corner — distinct from .btn since it's a
    /// ceremonial action.
    static let ritualHeight:             CGFloat = 38
    static let ritualCorner:             CGFloat = 9

    static let hairline:                 CGFloat = 0.5
}

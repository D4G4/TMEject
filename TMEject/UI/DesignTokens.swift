import SwiftUI

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

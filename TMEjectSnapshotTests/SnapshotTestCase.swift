import XCTest
import SwiftUI
import AppKit
@testable import TMEject

/// Snapshot testing — no dependencies. Mirrors Blink's `BlinkSnapshotTests/SnapshotTestCase`.
///
/// **Comparing** (default): if a reference PNG exists in `__Snapshots__/`, the test renders
/// the view, compares pixel-by-pixel with a 0.5% perceptual tolerance, and fails on
/// mismatch. The actual + reference PNGs are written to the
/// container's `__Failures__/` directory so you can `open` them side-by-side.
///
/// **Recording**: set `SNAPSHOT_RECORD=1` in the test process environment and re-run.
/// New references are written to the container's `TMEjectSnapshots/` directory; the
/// `scripts/promote-snapshots.sh` script copies them into the source tree
/// `TMEjectSnapshotTests/__Snapshots__/`. Run with:
///
///     SNAPSHOT_RECORD=1 xcodebuild -project TMEject.xcodeproj -scheme TMEject test \
///         -destination 'platform=macOS' -only-testing:TMEjectSnapshotTests
///     ./scripts/promote-snapshots.sh
class SnapshotTestCase: XCTestCase {

    private var sourceSnapshotDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__")
    }

    private var writableDir: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TMEjectSnapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var isRecordingMode: Bool {
        ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1"
    }

    /// Use ImageRenderer for views that don't depend on AppKit layout (most popover / HUD /
    /// toast surfaces). For ScrollView-based surfaces (Settings, Onboarding), prefer
    /// `assertHostedSnapshot` so AppKit gives the view a real layout pass.
    @MainActor func assertSnapshot<V: View>(
        of view: V,
        named name: String,
        width: CGFloat = 320,
        height: CGFloat = 300,
        colorScheme: ColorScheme = .light,
        translucent: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        withTranslucencyPreference(translucent) {
            let bgColor: Color = colorScheme == .dark ? Color(nsColor: NSColor(white: 0.12, alpha: 1)) : .white
            let wrapped = ZStack {
                bgColor
                view
            }
            .frame(width: width, height: height)
            .environment(\.colorScheme, colorScheme)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.sizeCategory, .large)

            let renderer = ImageRenderer(content: wrapped)
            renderer.scale = 2.0

            guard let cgImage = renderer.cgImage else {
                XCTFail("ImageRenderer returned nil for \(name)", file: file, line: line)
                return
            }

            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            guard let pngData = pngData(from: nsImage) else {
                XCTFail("Failed to create PNG data for \(name)", file: file, line: line)
                return
            }
            compareOrRecord(pngData: pngData, named: name, file: file, line: line)
        }
    }

    /// Use this for views containing `ScrollView`, `LazyVStack`, or any layout that needs a
    /// real AppKit container to lay out. ImageRenderer's deferred layer behavior emits a blank
    /// content area for these.
    @MainActor func assertHostedSnapshot<V: View>(
        of view: V,
        named name: String,
        width: CGFloat = 440,
        height: CGFloat = 700,
        colorScheme: ColorScheme = .light,
        translucent: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        withTranslucencyPreference(translucent) {
            let appearance: NSAppearance? = colorScheme == .dark
                ? NSAppearance(named: .darkAqua)
                : NSAppearance(named: .aqua)
            let bgColor: Color = colorScheme == .dark
                ? Color(nsColor: NSColor(white: 0.12, alpha: 1))
                : .white
            let wrapped = ZStack {
                bgColor
                view
            }
            .environment(\.colorScheme, colorScheme)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.sizeCategory, .large)

            let hosting = NSHostingView(rootView: wrapped)
            hosting.appearance = appearance
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

            let win = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.appearance = appearance
            win.contentView = hosting
            hosting.layoutSubtreeIfNeeded()

            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                XCTFail("NSHostingView produced no bitmap rep for \(name)", file: file, line: line)
                return
            }
            rep.size = hosting.bounds.size
            hosting.cacheDisplay(in: hosting.bounds, to: rep)

            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                XCTFail("Failed to create PNG data for \(name)", file: file, line: line)
                return
            }
            compareOrRecord(pngData: pngData, named: name, file: file, line: line)
        }
    }

    /// Sets the translucent-surfaces UserDefaults key for the duration of the render call.
    /// `@AppStorage` reads UserDefaults.standard, so this propagates to the SurfaceBackground
    /// modifier when the body is evaluated by ImageRenderer / NSHostingView.
    private func withTranslucencyPreference(_ translucent: Bool, _ body: () -> Void) {
        let prior = UserDefaults.standard.object(forKey: SettingsKey.translucentSurfaces)
        UserDefaults.standard.set(translucent, forKey: SettingsKey.translucentSurfaces)
        body()
        if let prior = prior {
            UserDefaults.standard.set(prior, forKey: SettingsKey.translucentSurfaces)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.translucentSurfaces)
        }
    }

    @MainActor private func compareOrRecord(
        pngData: Data,
        named name: String,
        file: StaticString,
        line: UInt
    ) {
        let refURL = sourceSnapshotDir.appendingPathComponent("\(name).png")

        if isRecordingMode {
            let recordURL = writableDir.appendingPathComponent("\(name).png")
            do {
                try pngData.write(to: recordURL)
                print("📸 Recorded (SNAPSHOT_RECORD=1): \(recordURL.path)")
            } catch {
                XCTFail("Failed to write snapshot \(name) to container: \(error)", file: file, line: line)
            }
            return
        }

        if !FileManager.default.fileExists(atPath: refURL.path) {
            let recordURL = writableDir.appendingPathComponent("\(name).png")
            do {
                try pngData.write(to: recordURL)
                print("📸 Recorded: \(recordURL.path)")
                print("   Copy to source: cp \"\(recordURL.path)\" \"\(refURL.path)\"")
            } catch {
                XCTFail("Failed to write snapshot \(name): \(error)", file: file, line: line)
            }
            return
        }

        guard let refData = try? Data(contentsOf: refURL) else {
            XCTFail("Failed to read reference snapshot for \(name)", file: file, line: line)
            return
        }

        let mismatchFraction = Self.pixelMismatchFraction(pngData, refData)
        let tolerance: Double = 0.005

        if mismatchFraction > tolerance {
            let failDir = writableDir.appendingPathComponent("__Failures__")
            try? FileManager.default.createDirectory(at: failDir, withIntermediateDirectories: true)
            let actualURL = failDir.appendingPathComponent("\(name)_actual.png")
            let refCopyURL = failDir.appendingPathComponent("\(name)_reference.png")
            try? pngData.write(to: actualURL)
            try? refData.write(to: refCopyURL)
            XCTFail(
                "Snapshot \"\(name)\" mismatch (\(String(format: "%.2f", mismatchFraction * 100))%).\n" +
                "  Actual:    \(actualURL.path)\n" +
                "  Reference: \(refCopyURL.path)\n" +
                "Run with SNAPSHOT_RECORD=1 + ./scripts/promote-snapshots.sh to update.",
                file: file, line: line
            )
        }
    }

    /// Fraction of pixels that differ *perceptibly*. ImageRenderer emits sub-LSB AA noise
    /// that varies run-to-run on soft shadows + gradients; exact-equality was 3–14% noisy.
    /// The 0.12 threshold is what Blink landed on after weeks of CI tuning.
    private static let perceptibleDelta = 0.12

    private static func pixelMismatchFraction(_ data1: Data, _ data2: Data) -> Double {
        guard let rep1 = NSBitmapImageRep(data: data1),
              let rep2 = NSBitmapImageRep(data: data2) else { return 1.0 }
        let w = min(rep1.pixelsWide, rep2.pixelsWide)
        let h = min(rep1.pixelsHigh, rep2.pixelsHigh)
        guard w > 0, h > 0 else { return 1.0 }
        if rep1.pixelsWide != rep2.pixelsWide || rep1.pixelsHigh != rep2.pixelsHigh {
            return 1.0
        }
        var mismatched = 0
        let total = w * h
        for y in 0..<h {
            for x in 0..<w {
                guard let c1 = rep1.colorAt(x: x, y: y),
                      let c2 = rep2.colorAt(x: x, y: y) else { continue }
                let delta = abs(c1.redComponent - c2.redComponent)
                    + abs(c1.greenComponent - c2.greenComponent)
                    + abs(c1.blueComponent - c2.blueComponent)
                if delta > perceptibleDelta { mismatched += 1 }
            }
        }
        return Double(mismatched) / Double(total)
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Compact name builder so each per-surface file doesn't reinvent the convention.
enum SnapshotName {
    static func surface(_ surface: String, variant: String? = nil,
                        theme: ColorScheme, translucent: Bool = false) -> String {
        let themeStr = theme == .dark ? "dark" : "light"
        let surfaceStr = translucent ? "translucent" : "opaque"
        if let variant {
            return "\(surface)_\(variant)_\(themeStr)_\(surfaceStr)"
        }
        return "\(surface)_\(themeStr)_\(surfaceStr)"
    }

    /// Variant for surfaces where translucency has no visual effect (template icons,
    /// always-opaque overlays). Skips the surface mode segment.
    static func plain(_ surface: String, variant: String? = nil, theme: ColorScheme) -> String {
        let themeStr = theme == .dark ? "dark" : "light"
        if let variant {
            return "\(surface)_\(variant)_\(themeStr)"
        }
        return "\(surface)_\(themeStr)"
    }
}

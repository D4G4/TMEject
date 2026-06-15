import XCTest
import SwiftUI
@testable import TMEject

/// Ritual confirm overlay at varying progress. Per Step 12.7 amendment §7 the overlay is
/// ALWAYS opaque regardless of the translucency preference, so we omit the surface mode.
@MainActor
final class RitualConfirmSnapshotTests: SnapshotTestCase {

    private func render(progress: Double, theme: ColorScheme) {
        let coord = SnapshotFixtures.makeCoordinator()
        coord.applySnapshotState(state: .idle,
                                  drivePresent: true,
                                  driveName: "Backup Drive",
                                  ritualConfirmPct: progress,
                                  fdaState: .granted)
        let view = MenuBarPopoverView(coordinator: coord, openPreferences: {})
        let progressLabel = "p\(Int(progress.rounded()))"
        let name = SnapshotName.plain("ritual_confirm", variant: progressLabel, theme: theme)
        assertSnapshot(of: view, named: name,
                        width: 320, height: 360, colorScheme: theme, translucent: false)
    }

    func testRitualEntryLight() { render(progress: 25, theme: .light) }
    func testRitualEntryDark()  { render(progress: 25, theme: .dark) }

    func testRitualMidLight() { render(progress: 60, theme: .light) }
    func testRitualMidDark()  { render(progress: 60, theme: .dark) }

    func testRitualFullLight() { render(progress: 100, theme: .light) }
    func testRitualFullDark()  { render(progress: 100, theme: .dark) }
}

import XCTest
import SwiftUI
@testable import TMEject

@MainActor
final class LaunchHUDSnapshotTests: SnapshotTestCase {

    private func render(theme: ColorScheme, translucent: Bool) {
        let view = LaunchHUDView(onDismiss: {})
        let name = SnapshotName.surface("launch_hud", theme: theme, translucent: translucent)
        assertSnapshot(of: view, named: name,
                        width: 290, height: 200, colorScheme: theme, translucent: translucent)
    }

    func testLightOpaque()      { render(theme: .light, translucent: false) }
    func testDarkOpaque()       { render(theme: .dark,  translucent: false) }
    func testLightTranslucent() { render(theme: .light, translucent: true) }
    func testDarkTranslucent()  { render(theme: .dark,  translucent: true) }
}

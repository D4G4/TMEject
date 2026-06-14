import XCTest
import SwiftUI
@testable import TMEject

/// MenuBarIcon — the status item template image. Translucency doesn't apply (template
/// image rendered by the system); just theme variants.
@MainActor
final class MenuBarIconSnapshotTests: SnapshotTestCase {

    private func render(state: AppState, ejectPct: Double = 0, theme: ColorScheme) {
        let view = MenuBarIconView(state: state, ejectPct: ejectPct)
            .frame(width: 44, height: 44)
        let name = SnapshotName.plain("menubar_icon", variant: "\(state.rawValue)", theme: theme)
        assertSnapshot(of: view, named: name, width: 44, height: 44, colorScheme: theme)
    }

    func testIdleLight() { render(state: .idle, theme: .light) }
    func testIdleDark()  { render(state: .idle, theme: .dark) }

    func testBackingUpLight() { render(state: .backingUp, theme: .light) }
    func testBackingUpDark()  { render(state: .backingUp, theme: .dark) }

    func testConfirmingLight() { render(state: .confirming, theme: .light) }
    func testConfirmingDark()  { render(state: .confirming, theme: .dark) }

    func testEjectingLight() { render(state: .ejecting, ejectPct: 45, theme: .light) }
    func testEjectingDark()  { render(state: .ejecting, ejectPct: 45, theme: .dark) }

    func testFailedLight() { render(state: .idleEjectFailed, theme: .light) }
    func testFailedDark()  { render(state: .idleEjectFailed, theme: .dark) }
}

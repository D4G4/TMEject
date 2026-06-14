import XCTest
@testable import TMEject

/// Step 12.7 amendment — `translucentSurfaces` defaults to `false` (opaque solid). The
/// SurfaceBackground modifier branches off this @AppStorage key, so the default must hold.
final class TranslucentSurfacesTests: XCTestCase {

    func testDefaultIsFalse_FreshDefaults() {
        let suite = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertNil(suite.object(forKey: SettingsKey.translucentSurfaces),
                     "key absent on fresh defaults")
        // UserDefaults.bool(forKey:) returns false for absent keys — that's the user-facing
        // default we rely on, not a stored value.
        XCTAssertFalse(suite.bool(forKey: SettingsKey.translucentSurfaces))
    }

    func testStoredFalseStaysFalse() {
        let suite = UserDefaults(suiteName: UUID().uuidString)!
        suite.set(false, forKey: SettingsKey.translucentSurfaces)
        XCTAssertFalse(suite.bool(forKey: SettingsKey.translucentSurfaces))
    }

    func testStoredTrueRoundTrips() {
        let suite = UserDefaults(suiteName: UUID().uuidString)!
        suite.set(true, forKey: SettingsKey.translucentSurfaces)
        XCTAssertTrue(suite.bool(forKey: SettingsKey.translucentSurfaces))
    }
}

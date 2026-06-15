import XCTest
@testable import TMEject

final class DestinationResolverTests: XCTestCase {

    private let backupURL = URL(fileURLWithPath: "/Volumes/Daksh's Time Machine")
    private let backupUUID = UUID(uuidString: "8968B69C-E835-472A-9EA7-F7F6CB22A13C")!

    // tmutil reports MountPoint → resolver returns it via DA.
    func testReturnsVolumeWhenMountPointExistsAndDAMatches() {
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (backupURL,
             VolumeDADescription(volumeUUID: backupUUID, bsdName: "disk14s2",
                                  volumeName: "Daksh's Time Machine"))
        ])
        let resolver = DestinationResolver(
            bridge: bridge,
            fileExists: FakeFileExistsProbe(existing: [backupURL])
        )
        let resolved = resolver.resolve(mountPoint: backupURL)
        XCTAssertEqual(resolved?.volumeURL, backupURL)
        XCTAssertEqual(resolved?.bsdName, "disk14s2")
        XCTAssertEqual(resolved?.volumeName, "Daksh's Time Machine")
        XCTAssertEqual(resolved?.volumeUUID, backupUUID)
    }

    // tmutil omitted MountPoint (drive not currently mounted, network destination, etc.).
    func testReturnsNilWhenMountPointAbsent() {
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (backupURL,
             VolumeDADescription(volumeUUID: backupUUID, bsdName: "disk14s2",
                                  volumeName: "Daksh's Time Machine"))
        ])
        let resolver = DestinationResolver(
            bridge: bridge,
            fileExists: AlwaysExistsFileProbe()
        )
        XCTAssertNil(resolver.resolve(mountPoint: nil))
    }

    // tmutil's MountPoint string survived but the drive was yanked between the tmutil read
    // and the resolver call. Don't fall back to name matching — surface the failure.
    func testReturnsNilWhenMountPointPathDoesNotExist() {
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (backupURL,
             VolumeDADescription(volumeUUID: backupUUID, bsdName: "disk14s2",
                                  volumeName: "Daksh's Time Machine"))
        ])
        let resolver = DestinationResolver(
            bridge: bridge,
            fileExists: FakeFileExistsProbe(existing: []) // nothing exists
        )
        XCTAssertNil(resolver.resolve(mountPoint: backupURL))
    }

    // Path exists but DA has nothing to say about it (very unusual — would indicate the
    // path isn't a real volume root, or a DA permission collapse).
    func testReturnsNilWhenDAReturnsNoDescription() {
        let bridge = FakeDiskArbitrationBridge(volumes: []) // no volumes known to DA
        let resolver = DestinationResolver(
            bridge: bridge,
            fileExists: FakeFileExistsProbe(existing: [backupURL])
        )
        XCTAssertNil(resolver.resolve(mountPoint: backupURL))
    }

    // DA returned a description but no BSD name → can't unmount → refuse to resolve.
    func testReturnsNilWhenDABSDNameMissing() {
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (backupURL,
             VolumeDADescription(volumeUUID: backupUUID, bsdName: nil,
                                  volumeName: "Daksh's Time Machine"))
        ])
        let resolver = DestinationResolver(
            bridge: bridge,
            fileExists: FakeFileExistsProbe(existing: [backupURL])
        )
        XCTAssertNil(resolver.resolve(mountPoint: backupURL))
    }

    // Volume UUID can legitimately be missing (some DA descriptions don't expose it) —
    // resolver shouldn't reject just because of that. BSD + path are what eject needs.
    func testReturnsResolvedEvenWhenDAVolumeUUIDMissing() {
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (backupURL,
             VolumeDADescription(volumeUUID: nil, bsdName: "disk14s2",
                                  volumeName: "Daksh's Time Machine"))
        ])
        let resolver = DestinationResolver(
            bridge: bridge,
            fileExists: FakeFileExistsProbe(existing: [backupURL])
        )
        let resolved = resolver.resolve(mountPoint: backupURL)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.bsdName, "disk14s2")
        XCTAssertNil(resolved?.volumeUUID)
    }
}

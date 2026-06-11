import XCTest
@testable import TMEject

final class DestinationResolverTests: XCTestCase {

    private let backupUUID = UUID(uuidString: "0852943E-8EC2-4386-8C31-ECE56488E8B4")!
    private let otherUUID  = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testReturnsNilWhenDestinationNotMounted() {
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (URL(fileURLWithPath: "/"),
             VolumeDADescription(volumeUUID: otherUUID, bsdName: "disk1s5", volumeName: "Macintosh HD"))
        ])
        let resolver = DestinationResolver(bridge: bridge)
        XCTAssertNil(resolver.resolve(destinationID: backupUUID))
    }

    func testReturnsMatchingVolumeByUUID() {
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (URL(fileURLWithPath: "/"),
             VolumeDADescription(volumeUUID: otherUUID, bsdName: "disk1s5", volumeName: "Macintosh HD")),
            (URL(fileURLWithPath: "/Volumes/Backup"),
             VolumeDADescription(volumeUUID: backupUUID, bsdName: "disk4s2", volumeName: "Backup"))
        ])
        let resolver = DestinationResolver(bridge: bridge)
        let resolved = resolver.resolve(destinationID: backupUUID)
        XCTAssertEqual(resolved?.volumeUUID, backupUUID)
        XCTAssertEqual(resolved?.bsdName, "disk4s2")
        XCTAssertEqual(resolved?.volumeURL, URL(fileURLWithPath: "/Volumes/Backup"))
        XCTAssertEqual(resolved?.volumeName, "Backup")
    }

    func testDoesNotMatchByNameWhenUUIDDiffers() {
        // Two drives named "Backup", different UUIDs: must NOT collide.
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (URL(fileURLWithPath: "/Volumes/Backup"),
             VolumeDADescription(volumeUUID: otherUUID, bsdName: "disk5s2", volumeName: "Backup")),
            (URL(fileURLWithPath: "/Volumes/Backup 1"),
             VolumeDADescription(volumeUUID: backupUUID, bsdName: "disk4s2", volumeName: "Backup"))
        ])
        let resolver = DestinationResolver(bridge: bridge)
        let resolved = resolver.resolve(destinationID: backupUUID)
        XCTAssertEqual(resolved?.bsdName, "disk4s2")
        XCTAssertEqual(resolved?.volumeURL.path, "/Volumes/Backup 1")
    }

    func testSkipsVolumesWithNoDescription() {
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (URL(fileURLWithPath: "/Volumes/Camera"), nil),
            (URL(fileURLWithPath: "/Volumes/Backup"),
             VolumeDADescription(volumeUUID: backupUUID, bsdName: "disk4s2", volumeName: "Backup"))
        ])
        let resolver = DestinationResolver(bridge: bridge)
        XCTAssertEqual(resolver.resolve(destinationID: backupUUID)?.bsdName, "disk4s2")
    }

    func testSkipsVolumesMissingBSDNameEvenIfUUIDMatches() {
        // Should not return a half-resolved destination — eject needs the BSD name.
        let bridge = FakeDiskArbitrationBridge(volumes: [
            (URL(fileURLWithPath: "/Volumes/Backup"),
             VolumeDADescription(volumeUUID: backupUUID, bsdName: nil, volumeName: "Backup"))
        ])
        let resolver = DestinationResolver(bridge: bridge)
        XCTAssertNil(resolver.resolve(destinationID: backupUUID))
    }
}

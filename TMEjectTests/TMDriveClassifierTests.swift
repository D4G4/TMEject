import XCTest
@testable import TMEject

final class TMDriveClassifierTests: XCTestCase {

    // MARK: - Strategy A: APFS role check

    func testIsTMDriveWhenAPFSRoleIsBackup() async {
        let role = FakeAPFSRoleQuery()
        await role.set(backup: ["disk7s2"], known: ["disk7s2", "disk1s1"])
        let files = FakeVolumeFileProbe()
        let classifier = TMDriveClassifier(roleQuery: role, fileProbe: files, clock: SystemClock())
        let c = await classifier.classify(bsdName: "disk7s2", mountPath: "/Volumes/TM")
        XCTAssertEqual(c, .isTMDrive)
    }

    func testNotTMDriveWhenAPFSRoleIsKnownButNotBackup() async {
        let role = FakeAPFSRoleQuery()
        await role.set(backup: [], known: ["disk7s2"])
        let files = FakeVolumeFileProbe()
        let classifier = TMDriveClassifier(roleQuery: role, fileProbe: files, clock: SystemClock())
        let c = await classifier.classify(bsdName: "disk7s2", mountPath: "/Volumes/Other")
        XCTAssertEqual(c, .notTMDrive)
    }

    // MARK: - Strategy B: filesystem markers (APFS where the disk isn't in the plist, or HFS+ legacy)

    func testFSMarkerIOCheckTriggersIsTMDriveEvenIfRoleListLacksBSD() async {
        let role = FakeAPFSRoleQuery()
        await role.set(backup: [], known: [])  // plist is empty
        let files = FakeVolumeFileProbe(
            existing: ["/Volumes/TM/.com.apple.TimeMachine.IOCheck"]
        )
        let classifier = TMDriveClassifier(roleQuery: role, fileProbe: files, clock: SystemClock())
        let c = await classifier.classify(bsdName: "disk9s2", mountPath: "/Volumes/TM")
        XCTAssertEqual(c, .isTMDrive)
    }

    func testFSMarkerBackupsDBTriggersIsTMDrive_HFSLegacy() async {
        let role = FakeAPFSRoleQuery()
        await role.set(backup: [], known: [])
        let files = FakeVolumeFileProbe(
            existing: ["/Volumes/OldTM/Backups.backupdb"]
        )
        let classifier = TMDriveClassifier(roleQuery: role, fileProbe: files, clock: SystemClock())
        let c = await classifier.classify(bsdName: "disk5s1", mountPath: "/Volumes/OldTM")
        XCTAssertEqual(c, .isTMDrive)
    }

    func testMobileBackupsMarkerIsNOTRecognized() async {
        // .MobileBackups is a SOURCE-side local-snapshots marker, not a TM
        // DESTINATION marker. The team-lead-locked classifier spec excludes it.
        let role = FakeAPFSRoleQuery()
        await role.set(backup: [], known: [])
        let files = FakeVolumeFileProbe(
            existing: ["/Volumes/Macintosh HD/.MobileBackups"]
        )
        let classifier = TMDriveClassifier(roleQuery: role, fileProbe: files, clock: SystemClock())
        let c = await classifier.classify(bsdName: "disk1s1", mountPath: "/Volumes/Macintosh HD")
        XCTAssertEqual(c, .unknown)
    }

    // MARK: - Fail-safe: classification unknown

    func testUnknownWhenAPFSPlistErroredAndNoFSMarkers() async {
        let role = FakeAPFSRoleQuery()
        await role.setFailure()
        let files = FakeVolumeFileProbe()  // nothing exists
        let classifier = TMDriveClassifier(roleQuery: role, fileProbe: files, clock: SystemClock())
        let c = await classifier.classify(bsdName: "disk9s2", mountPath: "/Volumes/Unknown")
        XCTAssertEqual(c, .unknown, "fail-safe: must NOT classify as TM drive when both strategies fail")
    }

    func testUnknownWhenBSDNotInPlistAndNoFSMarkers() async {
        // Plist parses fine but bsdName isn't in it (non-APFS drive) AND no FS
        // markers — we can't confirm not-TM either. Fail safe.
        let role = FakeAPFSRoleQuery()
        await role.set(backup: ["disk7s2"], known: ["disk7s2", "disk1s1"])
        let files = FakeVolumeFileProbe()
        let classifier = TMDriveClassifier(roleQuery: role, fileProbe: files, clock: SystemClock())
        let c = await classifier.classify(bsdName: "diskUnknown", mountPath: "/Volumes/Mystery")
        XCTAssertEqual(c, .unknown)
    }

    // MARK: - Cache invalidation

    func testInvalidateForcesRefetchOfRoleList() async {
        let role = FakeAPFSRoleQuery()
        await role.set(backup: ["disk7s2"], known: ["disk7s2"])
        let files = FakeVolumeFileProbe()
        let classifier = TMDriveClassifier(roleQuery: role, fileProbe: files, clock: SystemClock())

        _ = await classifier.classify(bsdName: "disk7s2", mountPath: "/Volumes/TM")
        var calls = await role.callCount
        XCTAssertEqual(calls, 1)
        // Same-cache TTL — second classify reuses prior snapshot.
        _ = await classifier.classify(bsdName: "disk7s2", mountPath: "/Volumes/TM")
        calls = await role.callCount
        XCTAssertEqual(calls, 1)
        // Invalidate → next classify re-queries.
        await classifier.invalidate()
        _ = await classifier.classify(bsdName: "disk7s2", mountPath: "/Volumes/TM")
        calls = await role.callCount
        XCTAssertEqual(calls, 2)
    }
}

// MARK: - Fakes

actor FakeAPFSRoleQuery: TMDriveClassifier.APFSRoleQuery {
    private var backup: Set<String> = []
    private var known: Set<String> = []
    private var failNext: Bool = false
    private(set) var callCount: Int = 0

    func set(backup: Set<String>, known: Set<String>) {
        self.backup = backup
        self.known = known
        self.failNext = false
    }

    func setFailure() {
        failNext = true
    }

    func currentSnapshot() async -> (backup: Set<String>, allKnown: Set<String>)? {
        callCount += 1
        if failNext { return nil }
        return (backup: backup, allKnown: known)
    }
}

struct FakeVolumeFileProbe: TMDriveClassifier.VolumeFileProbe {
    let existing: Set<String>
    init(existing: Set<String> = []) { self.existing = existing }
    func exists(atPath path: String) -> Bool { existing.contains(path) }
}

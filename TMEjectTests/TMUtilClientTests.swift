import XCTest
@testable import TMEject

final class StatusPlistTests: XCTestCase {

    func testParsesIdlePlist() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ClientID</key>
            <string>com.apple.backupd</string>
            <key>Percent</key>
            <real>-1</real>
            <key>Running</key>
            <false/>
        </dict>
        </plist>
        """
        let status = try StatusPlist.parse(plistData: Data(xml.utf8))
        XCTAssertFalse(status.running)
        // Idle sentinel -1 is normalized to nil — consumers expect "no value" semantics.
        XCTAssertNil(status.percent)
        XCTAssertNil(status.backupPhase)
        XCTAssertNil(status.rawTotalBytes)
        XCTAssertNil(status.destinationID)
    }

    func testParsesRunningBackupPlist_topLevelFraction() throws {
        // Legacy top-level Percent as a 0..1 fraction.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Running</key><true/>
            <key>BackupPhase</key><string>Copying</string>
            <key>Percent</key><real>0.42</real>
            <key>_raw_totalBytes</key><integer>123456789012</integer>
            <key>DestinationID</key><string>0852943E-8EC2-4386-8C31-ECE56488E8B4</string>
        </dict>
        </plist>
        """
        let status = try StatusPlist.parse(plistData: Data(xml.utf8))
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.backupPhase, "Copying")
        // Parser normalizes 0..1 fraction → 0..100 scale.
        XCTAssertEqual(status.percent ?? .nan, 42.0, accuracy: 1e-9)
        XCTAssertEqual(status.rawTotalBytes, 123_456_789_012)
        XCTAssertEqual(status.destinationID, UUID(uuidString: "0852943E-8EC2-4386-8C31-ECE56488E8B4"))
    }

    func testParsesRunningBackupPlist_nestedProgressFraction() throws {
        // Tahoe layout: top-level Percent stays at idle-ish value while the live progress
        // is in Progress.Percent. Parser must prefer the nested value.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Running</key><true/>
            <key>BackupPhase</key><string>Copying</string>
            <key>Percent</key><real>0</real>
            <key>Progress</key>
            <dict>
                <key>Percent</key><real>0.78</real>
                <key>TimeRemaining</key><integer>120</integer>
            </dict>
        </dict>
        </plist>
        """
        let status = try StatusPlist.parse(plistData: Data(xml.utf8))
        XCTAssertEqual(status.percent ?? .nan, 78.0, accuracy: 1e-9)
    }

    func testParsesRunningBackupPlist_nestedProgressPreferredOverTopLevel() throws {
        // When both are present, the nested Progress.Percent wins — it's the authoritative
        // value during active backup.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Running</key><true/>
            <key>Percent</key><real>0.10</real>
            <key>Progress</key>
            <dict>
                <key>Percent</key><real>0.78</real>
            </dict>
        </dict>
        </plist>
        """
        let status = try StatusPlist.parse(plistData: Data(xml.utf8))
        XCTAssertEqual(status.percent ?? .nan, 78.0, accuracy: 1e-9)
    }

    func testParsesRunningBackupPlist_alreadyScaledTopLevel() throws {
        // Defensive: if some macOS variant reports already-scaled 0..100, accept as-is.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Running</key><true/>
            <key>Percent</key><real>12.5</real>
        </dict>
        </plist>
        """
        let status = try StatusPlist.parse(plistData: Data(xml.utf8))
        XCTAssertEqual(status.percent ?? .nan, 12.5, accuracy: 1e-9)
    }

    func testNormalizePercent_scaleBoundaries() {
        XCTAssertNil(StatusPlist.normalizePercent(nil))
        XCTAssertNil(StatusPlist.normalizePercent(-1))
        XCTAssertNil(StatusPlist.normalizePercent(.nan))
        XCTAssertEqual(StatusPlist.normalizePercent(0) ?? .nan, 0)
        XCTAssertEqual(StatusPlist.normalizePercent(0.5) ?? .nan, 50)
        // 1.0 boundary: treated as fraction → 100 (documented in StatusPlist.swift).
        XCTAssertEqual(StatusPlist.normalizePercent(1.0) ?? .nan, 100)
        XCTAssertEqual(StatusPlist.normalizePercent(78) ?? .nan, 78)
        // Clamp anything pathologically > 100.
        XCTAssertEqual(StatusPlist.normalizePercent(250) ?? .nan, 100)
    }

    func testMissingKeysDefaultToNilOrFalse() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>ClientID</key><string>com.apple.backupd</string>
        </dict>
        </plist>
        """
        let status = try StatusPlist.parse(plistData: Data(xml.utf8))
        XCTAssertFalse(status.running)
        XCTAssertNil(status.percent)
        XCTAssertNil(status.backupPhase)
        XCTAssertNil(status.rawTotalBytes)
    }

    func testMalformedPlistThrows() {
        let garbage = Data("not a plist".utf8)
        XCTAssertThrowsError(try StatusPlist.parse(plistData: garbage)) { error in
            guard case TMUtilError.malformedPlist = error else {
                return XCTFail("expected .malformedPlist, got \(error)")
            }
        }
    }

    func testNonDictRootThrows() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <array>
            <string>nope</string>
        </array>
        </plist>
        """
        XCTAssertThrowsError(try StatusPlist.parse(plistData: Data(xml.utf8))) { error in
            guard case TMUtilError.malformedPlist = error else {
                return XCTFail("expected .malformedPlist for non-dict root, got \(error)")
            }
        }
    }
}

final class DestinationInfoTests: XCTestCase {

    func testParsesTahoeDestinationInfoUsingIDKey() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Destinations</key>
            <array>
                <dict>
                    <key>Kind</key><string>Local</string>
                    <key>ID</key><string>0852943E-8EC2-4386-8C31-ECE56488E8B4</string>
                    <key>Name</key><string>Daksh's Time Machine</string>
                    <key>LastDestination</key><integer>1</integer>
                    <key>MountPoint</key><string>/Volumes/Daksh's Time Machine</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let dests = try DestinationInfo.parseList(plistData: Data(xml.utf8))
        XCTAssertEqual(dests.count, 1)
        XCTAssertEqual(dests[0].id, UUID(uuidString: "0852943E-8EC2-4386-8C31-ECE56488E8B4"))
        XCTAssertEqual(dests[0].name, "Daksh's Time Machine")
        XCTAssertEqual(dests[0].kind, "Local")
        XCTAssertTrue(dests[0].lastDestination)
        XCTAssertEqual(dests[0].mountPoint,
                       URL(fileURLWithPath: "/Volumes/Daksh's Time Machine"))
    }

    // tmutil omits `MountPoint` when the destination isn't currently mounted (drive
    // unplugged, network destination not yet auto-mounted). Parser should yield nil rather
    // than synthesizing a path.
    func testParsesDestinationWithoutMountPoint() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Destinations</key>
            <array>
                <dict>
                    <key>ID</key><string>0852943E-8EC2-4386-8C31-ECE56488E8B4</string>
                    <key>Name</key><string>Daksh's Time Machine</string>
                    <key>Kind</key><string>Local</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let dests = try DestinationInfo.parseList(plistData: Data(xml.utf8))
        XCTAssertEqual(dests.count, 1)
        XCTAssertNil(dests[0].mountPoint, "absent MountPoint → nil, not '/'")
    }

    // Empty-string MountPoint (defensive — shouldn't happen but tmutil's plist isn't a
    // strict contract) must NOT parse as URL(fileURLWithPath: "") which would resolve to
    // the current working directory.
    func testEmptyMountPointStringIsTreatedAsAbsent() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Destinations</key>
            <array>
                <dict>
                    <key>ID</key><string>0852943E-8EC2-4386-8C31-ECE56488E8B4</string>
                    <key>Name</key><string>X</string>
                    <key>MountPoint</key><string></string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let dests = try DestinationInfo.parseList(plistData: Data(xml.utf8))
        XCTAssertEqual(dests.count, 1)
        XCTAssertNil(dests[0].mountPoint)
    }

    func testAcceptsLegacyDestinationIDKey() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Destinations</key>
            <array>
                <dict>
                    <key>DestinationID</key><string>11111111-2222-3333-4444-555555555555</string>
                    <key>Name</key><string>Old</string>
                    <key>Kind</key><string>Network</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let dests = try DestinationInfo.parseList(plistData: Data(xml.utf8))
        XCTAssertEqual(dests.count, 1)
        XCTAssertEqual(dests[0].id.uuidString, "11111111-2222-3333-4444-555555555555")
        XCTAssertFalse(dests[0].lastDestination)
    }

    func testNoDestinationsKeyReturnsEmpty() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict><key>Other</key><string>x</string></dict>
        </plist>
        """
        let dests = try DestinationInfo.parseList(plistData: Data(xml.utf8))
        XCTAssertTrue(dests.isEmpty)
    }

    func testEntryWithMissingIDIsSkipped() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Destinations</key>
            <array>
                <dict><key>Name</key><string>NoID</string></dict>
                <dict>
                    <key>ID</key><string>0852943E-8EC2-4386-8C31-ECE56488E8B4</string>
                    <key>Name</key><string>HasID</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let dests = try DestinationInfo.parseList(plistData: Data(xml.utf8))
        XCTAssertEqual(dests.count, 1)
        XCTAssertEqual(dests[0].name, "HasID")
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try DestinationInfo.parseList(plistData: Data("garbage".utf8))) { error in
            guard case TMUtilError.malformedPlist = error else {
                return XCTFail("expected .malformedPlist, got \(error)")
            }
        }
    }
}

final class LiveTMUtilClientIntegrationTests: XCTestCase {
    // Real-tmutil smoke tests. Skipped when /usr/bin/tmutil is absent.

    private func skipIfNoTmutil() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/tmutil") else {
            throw XCTSkip("/usr/bin/tmutil not present")
        }
    }

    func testStatusAgainstRealTmutilParses() async throws {
        try skipIfNoTmutil()
        let client = LiveTMUtilClient()
        let status = try await client.status()
        // We don't assert running state — just that parsing succeeded.
        _ = status.running
    }

    func testDestinationInfoAgainstRealTmutilParses() async throws {
        try skipIfNoTmutil()
        let client = LiveTMUtilClient()
        // No assertion about contents — some machines have zero configured destinations.
        _ = try await client.destinationInfo()
    }
}

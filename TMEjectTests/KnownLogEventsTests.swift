import XCTest
@testable import TMEject

final class KnownLogEventsTests: XCTestCase {

    private func summary(_ msg: String,
                          subsystem: String = "com.apple.TimeMachine",
                          category: String = "BackupEngine") -> LogEventSummary {
        LogEventSummary(rawDict: [
            "subsystem": subsystem,
            "category": category,
            "eventMessage": msg,
            "processImagePath": "/System/Library/CoreServices/TimeMachine/backupd"
        ])
    }

    // MARK: - Start signals

    func testWakeOnBackupDispatchingStart() {
        XCTAssertTrue(KnownLogEvents.isWakeWorthy(
            summary("Backup requested to last destination in rotation. specifiedOptions: TMBackupOptions(rawValue: 274)",
                     category: "BackupDispatching")))
    }

    func testWakeOnBackupJobAttempting() {
        XCTAssertTrue(KnownLogEvents.isWakeWorthy(
            summary("Attempting backup with mode \"manual backup\"", category: "BackupJob")))
    }

    func testWakeOnMountingDestination() {
        XCTAssertTrue(KnownLogEvents.isWakeWorthy(
            summary("Mounting destination 0852943E-8EC2-4386-8C31-ECE56488E8B4 for backing up",
                     category: "MountedDestinationManager")))
    }

    // MARK: - Completion signals

    func testWakeOnBackupEngineCompleting() {
        XCTAssertTrue(KnownLogEvents.isWakeWorthy(
            summary("Completing backup", category: "BackupEngine")))
    }

    func testWakeOnSuccessfullyCompleted() {
        XCTAssertTrue(KnownLogEvents.isWakeWorthy(
            summary("Successfully completed backing up 205.7 MB to '/Volumes/.timemachine/.../2026-06-14-145122.backup'",
                     category: "BackupEngine")))
    }

    // MARK: - Noise filtering

    func testIgnoresXPCConnectionNoise() {
        XCTAssertFalse(KnownLogEvents.isWakeWorthy(
            summary("com.apple.backupd.status.xpc: connection invalid", category: "General")))
    }

    func testIgnoresStructureErrors() {
        XCTAssertFalse(KnownLogEvents.isWakeWorthy(
            summary("TRY_ERROR_BLOCK throwing error: Error Domain=TMStructureErrorDomain Code=7", category: "DO_OR_BAIL")))
    }

    func testIgnoresLogLimits() {
        XCTAssertFalse(KnownLogEvents.isWakeWorthy(
            summary("Limiting logging for limit: aFewTimes key: \"map auto_home\"", category: "LogLimits")))
    }

    func testIgnoresUnrelatedSubsystem() {
        XCTAssertFalse(KnownLogEvents.isWakeWorthy(
            summary("Backup requested to last destination", subsystem: "com.apple.xpc")))
    }

    func testIgnoresUnknownMessage() {
        XCTAssertFalse(KnownLogEvents.isWakeWorthy(
            summary("Some completely unrelated TM log message we've never seen")))
    }

    // MARK: - Verification stamps

    func testVerificationStampsPresent() {
        XCTAssertEqual(KnownLogEvents.verifiedOn, "2026-06-14")
        XCTAssertEqual(KnownLogEvents.verifiedMacOS, "26.3.1 (Tahoe)")
    }
}

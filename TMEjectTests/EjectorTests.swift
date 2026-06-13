import XCTest
@testable import TMEject

final class LsofProbeParsingTests: XCTestCase {
    // The probe now consumes `lsof -Fpcn` field-mode output. Old human-format tests were
    // wrong (their input format wouldn't be what the live impl actually fetches).

    func testParsesFieldModeOutput() {
        let live = LiveLsofProbe()
        let sample = """
        p412
        cmds_stores
        n/Volumes/Backup
        n/Volumes/Backup/Backups.backupdb/Mac/2026-06-11-100000/index.bin
        p480
        cSpotlight
        n/Volumes/Backup/Library/Spotlight
        p412
        cmds_stores
        n/Volumes/Backup/something
        """
        let holders = live.parse(lsofOutput: sample)
        XCTAssertEqual(holders, [
            LsofHolder(command: "mds_stores", pid: 412),
            LsofHolder(command: "Spotlight", pid: 480)
        ])
    }

    func testEmptyLsofOutputReturnsEmpty() {
        XCTAssertTrue(LiveLsofProbe().parse(lsofOutput: "").isEmpty)
    }

    func testCommandsWithSpacesPreservedIntact() {
        // Field-mode is line-delimited per field — spaces inside the command name no longer
        // confuse the parser the way `+f`'s column-aligned output did.
        let sample = """
        p1234
        cGoogle Chrome Helper
        ftxt
        n/Volumes/Backup/Library/Chrome
        p5678
        ccom.apple.WebKit.WebContent
        p9999
        cbackupd
        """
        let holders = LiveLsofProbe().parse(lsofOutput: sample)
        XCTAssertEqual(holders, [
            LsofHolder(command: "Google Chrome Helper", pid: 1234),
            LsofHolder(command: "com.apple.WebKit.WebContent", pid: 5678),
            LsofHolder(command: "backupd", pid: 9999)
        ])
    }

    func testRecordWithoutCommandIsDropped() {
        // A `p` block that finishes without a `c` field shouldn't appear in the output —
        // we'd have no humanSummary line to report.
        let sample = """
        p100
        n/some/path
        p200
        cgoodcmd
        """
        let holders = LiveLsofProbe().parse(lsofOutput: sample)
        XCTAssertEqual(holders, [LsofHolder(command: "goodcmd", pid: 200)])
    }
}

final class EjectorTests: XCTestCase {

    private let prodSchedule = EjectorRetrySchedule.default
    private let testSchedule = EjectorRetrySchedule(backoffsSeconds: Array(repeating: 0, count: 8))

    func testProductionScheduleMatchesArchitectureDecision() {
        XCTAssertEqual(prodSchedule.backoffsSeconds, [0, 2, 5, 15, 30, 60, 120, 300])
        XCTAssertEqual(prodSchedule.totalAttempts, 8)
        XCTAssertEqual(prodSchedule.backoffsSeconds.dropFirst().reduce(0, +), 532)
    }

    func testSuccessOnFirstAttempt_NoLsof_NoRetry() async {
        let unmount = FakeUnmountBridge()
        await unmount.enqueue(.success)
        let lsof = FakeLsofProbe()
        let ejector = Ejector(unmount: unmount, lsof: lsof, clock: FakeClock(), schedule: testSchedule)
        let report = await ejector.eject(volumeURL: URL(fileURLWithPath: "/Volumes/Backup"))
        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.attempts.count, 1)
        let uc = await unmount.callCount
        let lc = await lsof.callCount
        XCTAssertEqual(uc, 1)
        XCTAssertEqual(lc, 0)
    }

    func testSuccessOnRetryAfterBusy_RunsLsofOnEachBusyAttempt() async {
        let unmount = FakeUnmountBridge()
        await unmount.enqueue([.busy(message: "busy1"), .busy(message: "busy2"), .success])
        let lsof = FakeLsofProbe()
        await lsof.enqueue([LsofHolder(command: "mds_stores", pid: 412)])
        await lsof.enqueue([LsofHolder(command: "mds_stores", pid: 412)])
        let ejector = Ejector(unmount: unmount, lsof: lsof, clock: FakeClock(), schedule: testSchedule)
        let report = await ejector.eject(volumeURL: URL(fileURLWithPath: "/Volumes/Backup"))
        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.attempts.count, 3)
        let lc = await lsof.callCount
        XCTAssertEqual(lc, 2)
        XCTAssertEqual(report.attempts[0].holders, [LsofHolder(command: "mds_stores", pid: 412)])
    }

    func testAllAttemptsBusy_ReportsFailureWithLastHolder() async {
        let unmount = FakeUnmountBridge()
        for _ in 0..<8 { await unmount.enqueue(.busy(message: "busy")) }
        let lsof = FakeLsofProbe()
        for i in 0..<8 {
            await lsof.enqueue([LsofHolder(command: "p\(i)", pid: 100 + i)])
        }
        let ejector = Ejector(unmount: unmount, lsof: lsof, clock: FakeClock(), schedule: testSchedule)
        let report = await ejector.eject(volumeURL: URL(fileURLWithPath: "/Volumes/Backup"))
        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.attempts.count, 8)
        let uc = await unmount.callCount
        let lc = await lsof.callCount
        XCTAssertEqual(uc, 8)
        XCTAssertEqual(lc, 8)
        XCTAssertTrue(report.lastError?.contains("busy after 8 attempts") == true)
        XCTAssertTrue(report.lastError?.contains("p7 (pid 107)") == true,
                      "lastError should surface the holder from the final attempt; got: \(report.lastError ?? "nil")")
    }

    func testNonBusyErrorTerminatesImmediately_NoRetry() async {
        let unmount = FakeUnmountBridge()
        await unmount.enqueue(.other(code: -123, message: "I/O error"))
        let lsof = FakeLsofProbe()
        let ejector = Ejector(unmount: unmount, lsof: lsof, clock: FakeClock(), schedule: testSchedule)
        let report = await ejector.eject(volumeURL: URL(fileURLWithPath: "/Volumes/Backup"))
        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.attempts.count, 1)
        let uc = await unmount.callCount
        let lc = await lsof.callCount
        XCTAssertEqual(uc, 1)
        XCTAssertEqual(lc, 0, "lsof must not run for non-busy errors")
        XCTAssertTrue(report.lastError?.contains("I/O error") == true)
    }

    // Step-12.5 review M4: callback fires after every attempt with attempt number + holders +
    // next-retry delay, so the coordinator can update lastError mid-9-min retry window.
    func testProgressCallbackFiresPerAttemptWithCorrectNextRetryDelay() async {
        let schedule = EjectorRetrySchedule(backoffsSeconds: [0, 2, 5, 15])
        let unmount = FakeUnmountBridge()
        await unmount.enqueue([.busy(message: "b1"), .busy(message: "b2"), .success])
        let lsof = FakeLsofProbe()
        await lsof.enqueue([LsofHolder(command: "mds_stores", pid: 412)])
        await lsof.enqueue([LsofHolder(command: "mdworker", pid: 500)])
        let ejector = Ejector(unmount: unmount, lsof: lsof, clock: FakeClock(), schedule: schedule)

        // Collect progress events from inside the @Sendable closure.
        actor Box { var items: [EjectAttempt] = []; func append(_ a: EjectAttempt) { items.append(a) } }
        let box = Box()

        let report = await ejector.eject(volumeURL: URL(fileURLWithPath: "/Volumes/Backup"),
                                          onAttempt: { attempt in
            await box.append(attempt)
        })
        XCTAssertTrue(report.succeeded)
        let items = await box.items
        XCTAssertEqual(items.count, 3, "callback fires after every attempt")
        XCTAssertEqual(items[0].attemptNumber, 1)
        XCTAssertEqual(items[0].totalAttempts, 4)
        XCTAssertEqual(items[0].holders, [LsofHolder(command: "mds_stores", pid: 412)])
        XCTAssertEqual(items[0].nextRetryDelay, 2)
        XCTAssertEqual(items[1].attemptNumber, 2)
        XCTAssertEqual(items[1].nextRetryDelay, 5,
                       "next-retry delay should be the NEXT slot's backoff, not the just-elapsed one")
        XCTAssertEqual(items[2].attemptNumber, 3)
        XCTAssertNil(items[2].nextRetryDelay,
                     "success → no next retry")
    }

    func testProgressCallback_FinalBusyAttempt_NextRetryDelayIsNil() async {
        let schedule = EjectorRetrySchedule(backoffsSeconds: [0, 0])
        let unmount = FakeUnmountBridge()
        await unmount.enqueue([.busy(message: "b1"), .busy(message: "b2")])
        let lsof = FakeLsofProbe()
        let ejector = Ejector(unmount: unmount, lsof: lsof, clock: FakeClock(), schedule: schedule)

        actor Box { var items: [EjectAttempt] = []; func append(_ a: EjectAttempt) { items.append(a) } }
        let box = Box()

        _ = await ejector.eject(volumeURL: URL(fileURLWithPath: "/Volumes/Backup"),
                                 onAttempt: { a in await box.append(a) })
        let items = await box.items
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].nextRetryDelay, 0, "schedule[1] = 0s")
        XCTAssertNil(items[1].nextRetryDelay, "no schedule[2] → no next retry")
    }
}

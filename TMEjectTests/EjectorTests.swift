import XCTest
@testable import TMEject

final class LsofProbeParsingTests: XCTestCase {

    func testParsesCommandAndPidFromLsofOutput() {
        let live = LiveLsofProbe()
        let sample = """
        COMMAND     PID USER   FD   TYPE DEVICE  SIZE/OFF NODE NAME
        mds_stores  412 root  cwd    DIR   1,17       640    2 /Volumes/Backup
        Spotlight   480 root   3r   REG   1,17      1024  100 /Volumes/Backup/Library/Spotlight
        mds_stores  412 root   4r   REG   1,17      4096  101 /Volumes/Backup/index.bin
        """
        let holders = live.parse(lsofOutput: sample)
        XCTAssertEqual(holders, [
            LsofHolder(command: "mds_stores", pid: 412),
            LsofHolder(command: "Spotlight", pid: 480)
        ])
    }

    func testEmptyLsofOutputReturnsEmpty() {
        let holders = LiveLsofProbe().parse(lsofOutput: "")
        XCTAssertTrue(holders.isEmpty)
    }

    func testJunkLinesAreSkipped() {
        let live = LiveLsofProbe()
        let sample = """
        COMMAND     PID USER
        garbage line without enough columns
        mdworker    222 root  cwd
        """
        let holders = live.parse(lsofOutput: sample)
        XCTAssertEqual(holders, [LsofHolder(command: "mdworker", pid: 222)])
    }
}

final class EjectorTests: XCTestCase {

    // 8-attempt schedule: first immediate then 7 backoffs (2, 5, 15, 30, 60, 120, 300)
    private let prodSchedule = EjectorRetrySchedule.default

    // Compressed schedule for tests — same shape, zero waits so the test runs instantly.
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
}

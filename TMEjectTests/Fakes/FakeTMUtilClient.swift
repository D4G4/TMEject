import Foundation
@testable import TMEject

actor FakeTMUtilClient: TMUtilClient {
    private var statusResponses: [Result<StatusPlist, Error>] = []
    private var destResponses: [Result<[DestinationInfo], Error>] = []
    private var latestBackupResponses: [Result<URL?, Error>] = []
    private var stopBackupError: Error?
    private var latestBackupRawResponses: [TMUtilRawResult] = []

    private(set) var statusCallCount = 0
    private(set) var destinationInfoCallCount = 0
    private(set) var latestBackupCallCount = 0
    private(set) var stopBackupCallCount = 0
    private(set) var latestBackupRawCallCount = 0

    func enqueueStatus(_ result: Result<StatusPlist, Error>) {
        statusResponses.append(result)
    }
    func enqueueDestinationInfo(_ result: Result<[DestinationInfo], Error>) {
        destResponses.append(result)
    }
    func enqueueLatestBackup(_ result: Result<URL?, Error>) {
        latestBackupResponses.append(result)
    }
    func setStopBackupError(_ error: Error?) {
        stopBackupError = error
    }

    func status() async throws -> StatusPlist {
        statusCallCount += 1
        guard !statusResponses.isEmpty else {
            return StatusPlist(running: false)
        }
        return try statusResponses.removeFirst().get()
    }

    func destinationInfo() async throws -> [DestinationInfo] {
        destinationInfoCallCount += 1
        guard !destResponses.isEmpty else { return [] }
        return try destResponses.removeFirst().get()
    }

    func latestBackup() async throws -> URL? {
        latestBackupCallCount += 1
        guard !latestBackupResponses.isEmpty else { return nil }
        return try latestBackupResponses.removeFirst().get()
    }

    func stopBackup() async throws {
        stopBackupCallCount += 1
        if let error = stopBackupError { throw error }
    }

    func enqueueLatestBackupRaw(_ result: TMUtilRawResult) {
        latestBackupRawResponses.append(result)
    }

    func latestBackupRaw() async -> TMUtilRawResult {
        latestBackupRawCallCount += 1
        guard !latestBackupRawResponses.isEmpty else {
            // Default to a "looks granted" result so existing tests that don't care about FDA
            // aren't forced to enqueue one.
            return TMUtilRawResult(stdout: "", stderr: "", exitCode: 0)
        }
        return latestBackupRawResponses.removeFirst()
    }
}

import Foundation

protocol MonotonicClock: Sendable {
    func now() -> TimeInterval
    func sleep(seconds: TimeInterval) async throws
}

struct SystemClock: MonotonicClock {
    func now() -> TimeInterval {
        // ProcessInfo.systemUptime is monotonic across wall-clock changes — important for stall
        // and confirming-cap timers that must not be reset by NTP corrections during a long backup.
        ProcessInfo.processInfo.systemUptime
    }

    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

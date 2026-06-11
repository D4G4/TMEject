import Foundation
@testable import TMEject

actor FakeClock: MonotonicClock {
    private var current: TimeInterval = 0

    func advance(by seconds: TimeInterval) {
        current += seconds
    }

    nonisolated func now() -> TimeInterval {
        // Synchronous nonisolated read so PollingObserver can call now() without awaiting.
        // We mirror the value in an atomic to satisfy Sendable; tests sequence advance() vs reads
        // through await on FakeClock, so the visible "current" matches the test timeline.
        _now.value
    }

    private let _now = AtomicTimeInterval()

    func setNow(_ value: TimeInterval) {
        current = value
        _now.value = value
    }

    init() {}

    func tick(_ delta: TimeInterval) {
        current += delta
        _now.value = current
    }

    func sleep(seconds: TimeInterval) async throws {
        // Tests never want PollingObserver to sleep for real — they drive it via runOnce().
        // A tiny sleep prevents tight spinning if the observer's run loop is started by accident.
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

private final class AtomicTimeInterval: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: TimeInterval = 0
    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

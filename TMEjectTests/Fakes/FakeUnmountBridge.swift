import Foundation
@testable import TMEject

actor FakeUnmountBridge: UnmountBridge {
    private var responses: [DAUnmountResult] = []
    private(set) var callCount = 0
    private var hangForever = false

    func enqueue(_ result: DAUnmountResult) {
        responses.append(result)
    }
    func enqueue(_ results: [DAUnmountResult]) {
        responses.append(contentsOf: results)
    }
    func setHangForever() {
        hangForever = true
    }

    func unmountVolume(at _: URL) async -> DAUnmountResult {
        callCount += 1
        if hangForever {
            // Tests that need to assert state == .ejecting while the ejector is mid-attempt
            // can park the unmount call here. A 5s suspension is more than enough for any
            // test scheduling window but doesn't risk stalling the suite if a cancel is lost.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return .other(code: -999, message: "hung-bridge fallback")
        }
        guard !responses.isEmpty else { return .success }
        return responses.removeFirst()
    }
}

actor FakeLsofProbe: LsofProbe {
    private var responses: [[LsofHolder]] = []
    private(set) var callCount = 0

    func enqueue(_ holders: [LsofHolder]) {
        responses.append(holders)
    }

    func holdersOf(volumePath: String) async -> [LsofHolder] {
        callCount += 1
        guard !responses.isEmpty else { return [] }
        return responses.removeFirst()
    }
}

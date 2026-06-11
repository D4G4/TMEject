import Foundation
@testable import TMEject

actor FakeUnmountBridge: UnmountBridge {
    private var responses: [DAUnmountResult] = []
    private(set) var callCount = 0

    func enqueue(_ result: DAUnmountResult) {
        responses.append(result)
    }
    func enqueue(_ results: [DAUnmountResult]) {
        responses.append(contentsOf: results)
    }

    func unmountVolume(at _: URL) async -> DAUnmountResult {
        callCount += 1
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

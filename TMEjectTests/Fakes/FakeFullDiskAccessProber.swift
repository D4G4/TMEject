import Foundation
@testable import TMEject

actor FakeFullDiskAccessProber: FullDiskAccessProbing {
    private var queue: [FDAState] = []
    private(set) var probeCount = 0

    init(_ initial: FDAState = .granted) {
        queue.append(initial)
    }

    func enqueue(_ state: FDAState) { queue.append(state) }

    func currentState() async -> FDAState {
        probeCount += 1
        if queue.count > 1 { return queue.removeFirst() }
        return queue.first ?? .unknown
    }
}

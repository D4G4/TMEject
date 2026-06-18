import XCTest
@testable import TMEject

final class ForeignDriveGracePeriodTests: XCTestCase {

    private func candidate(_ name: String) -> ForeignTMDriveCandidate {
        ForeignTMDriveCandidate(
            bsdName: "disk\(name)",
            volumeURL: URL(fileURLWithPath: "/Volumes/\(name)"),
            volumeName: name
        )
    }

    func testGraceExpiresFiresOnExpireCallback() async {
        let clock = FakeClock()
        let fired = Box<[ForeignTMDriveCandidate]>([])
        let grace = ForeignDriveGracePeriod(clock: clock) { c in
            await fired.append(c)
        }
        let c = candidate("Foreign")
        await grace.startGrace(for: c)
        // Wait briefly to let the fake clock's tiny sleep return.
        await Self.waitFor(timeout: 1.0) {
            let snap = await fired.snapshot()
            return snap.count == 1
        }
        let result = await fired.snapshot()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.bsdName, "diskForeign")
        let pending = await grace.inFlightCount
        XCTAssertEqual(pending, 0, "expired entry must be removed")
    }

    func testCancelBeforeExpiryPreventsCallback() async {
        let clock = FakeClock()
        let fired = Box<[ForeignTMDriveCandidate]>([])
        let grace = ForeignDriveGracePeriod(clock: clock) { c in
            await fired.append(c)
        }
        let c = candidate("Cancelled")
        await grace.startGrace(for: c)
        await grace.cancel(volumeURL: c.volumeURL, reason: .user)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let result = await fired.snapshot()
        XCTAssertTrue(result.isEmpty, "cancelled grace must not fire onExpire")
        let pending = await grace.inFlightCount
        XCTAssertEqual(pending, 0)
    }

    func testMultipleConcurrentGracesAllowed() async {
        let clock = FakeClock()
        let fired = Box<[ForeignTMDriveCandidate]>([])
        let grace = ForeignDriveGracePeriod(clock: clock) { c in
            await fired.append(c)
        }
        await grace.startGrace(for: candidate("A"))
        await grace.startGrace(for: candidate("B"))
        await grace.startGrace(for: candidate("C"))
        let pendingMid = await grace.inFlightCount
        XCTAssertEqual(pendingMid, 3)
        await Self.waitFor(timeout: 2.0) {
            let snap = await fired.snapshot()
            return snap.count == 3
        }
        let firedSnap = await fired.snapshot()
        let names = Set(firedSnap.map(\.volumeName))
        XCTAssertEqual(names, ["A", "B", "C"])
    }

    func testStartGraceIsIdempotentPerVolumeURL() async {
        let clock = FakeClock()
        let fired = Box<[ForeignTMDriveCandidate]>([])
        let grace = ForeignDriveGracePeriod(clock: clock) { c in
            await fired.append(c)
        }
        let c = candidate("Dup")
        await grace.startGrace(for: c)
        await grace.startGrace(for: c)
        await grace.startGrace(for: c)
        let pending = await grace.inFlightCount
        XCTAssertEqual(pending, 1, "second/third startGrace must be no-op")
    }

    func testCancelAllDropsEveryPending() async {
        let clock = FakeClock()
        let fired = Box<[ForeignTMDriveCandidate]>([])
        let grace = ForeignDriveGracePeriod(clock: clock) { c in
            await fired.append(c)
        }
        await grace.startGrace(for: candidate("A"))
        await grace.startGrace(for: candidate("B"))
        await grace.cancelAll(reason: .settingOff)
        let pending = await grace.inFlightCount
        XCTAssertEqual(pending, 0)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let firedSnap = await fired.snapshot()
        XCTAssertTrue(firedSnap.isEmpty)
    }

    func testReMountAfterCancelStartsFreshGrace() async {
        // No per-UUID memory of prior cancels — same drive coming back fires the
        // grace again (locked design decision #4).
        let clock = FakeClock()
        let fired = Box<[ForeignTMDriveCandidate]>([])
        let grace = ForeignDriveGracePeriod(clock: clock) { c in
            await fired.append(c)
        }
        let c = candidate("Roundtrip")
        await grace.startGrace(for: c)
        await grace.cancel(volumeURL: c.volumeURL, reason: .user)
        await grace.startGrace(for: c)
        await Self.waitFor(timeout: 1.0) {
            let snap = await fired.snapshot()
            return snap.count == 1
        }
        let firedSnap = await fired.snapshot()
        XCTAssertEqual(firedSnap.count, 1, "second mount must re-arm and fire")
    }

    // MARK: - Helpers

    /// Polls `predicate` every 10ms up to `timeout` seconds.
    static func waitFor(timeout: TimeInterval, _ predicate: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

actor Box<T: Sendable> {
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { value = newValue }
    func snapshot() -> T { value }
}

extension Box where T == [ForeignTMDriveCandidate] {
    func append(_ c: ForeignTMDriveCandidate) { value.append(c) }
}

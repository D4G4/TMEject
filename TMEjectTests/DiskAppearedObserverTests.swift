import XCTest
@testable import TMEject

final class DiskAppearedObserverTests: XCTestCase {

    // MARK: - Foreign vs own

    func testForeignTMDriveEmitsCandidate() async {
        let bridge = FakeDiskAppearedBridge()
        let role = FakeAPFSRoleQuery()
        await role.set(backup: ["disk9s2"], known: ["disk9s2"])
        let classifier = TMDriveClassifier(roleQuery: role,
                                            fileProbe: FakeVolumeFileProbe(),
                                            clock: SystemClock())
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueDestinationInfo(.success([]))   // no local destinations
        let candidates = CandidateSink()

        let observer = DiskAppearedObserver(
            bridge: bridge, classifier: classifier, tmutil: tmutil,
            onCandidate: { c in await candidates.append(c) },
            onDisappeared: { _ in }
        )
        await observer.start()
        await bridge.simulateAppeared(VolumeMountSnapshot(
            bsdName: "disk9s2",
            volumeURL: URL(fileURLWithPath: "/Volumes/OtherMacTM"),
            volumeName: "OtherMacTM"
        ))
        await ForeignDriveGracePeriodTests.waitFor(timeout: 1.0) {
            let snap = await candidates.snapshot()
            return snap.count == 1
        }
        let got = await candidates.snapshot()
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.bsdName, "disk9s2")
        XCTAssertEqual(got.first?.volumeName, "OtherMacTM")
    }

    func testThisMacsTMDriveIsNotForeign() async {
        let bridge = FakeDiskAppearedBridge()
        let role = FakeAPFSRoleQuery()
        await role.set(backup: ["disk7s2"], known: ["disk7s2"])
        let classifier = TMDriveClassifier(roleQuery: role,
                                            fileProbe: FakeVolumeFileProbe(),
                                            clock: SystemClock())
        let tmutil = FakeTMUtilClient()
        let localDest = DestinationInfo(
            id: UUID(),
            name: "Local TM",
            kind: "Local",
            lastDestination: true,
            mountPoint: URL(fileURLWithPath: "/Volumes/Local TM")
        )
        await tmutil.enqueueDestinationInfo(.success([localDest]))
        let candidates = CandidateSink()

        let observer = DiskAppearedObserver(
            bridge: bridge, classifier: classifier, tmutil: tmutil,
            onCandidate: { c in await candidates.append(c) },
            onDisappeared: { _ in }
        )
        await observer.start()
        await bridge.simulateAppeared(VolumeMountSnapshot(
            bsdName: "disk7s2",
            volumeURL: URL(fileURLWithPath: "/Volumes/Local TM"),
            volumeName: "Local TM"
        ))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let snap = await candidates.snapshot()
        XCTAssertTrue(snap.isEmpty,
                       "this Mac's own TM destination must not be flagged as foreign")
    }

    func testNonTMDriveDoesNothing() async {
        let bridge = FakeDiskAppearedBridge()
        let role = FakeAPFSRoleQuery()
        await role.set(backup: [], known: ["disk1s5"])   // bsd known, not Backup
        let classifier = TMDriveClassifier(roleQuery: role,
                                            fileProbe: FakeVolumeFileProbe(),
                                            clock: SystemClock())
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueDestinationInfo(.success([]))
        let candidates = CandidateSink()

        let observer = DiskAppearedObserver(
            bridge: bridge, classifier: classifier, tmutil: tmutil,
            onCandidate: { c in await candidates.append(c) },
            onDisappeared: { _ in }
        )
        await observer.start()
        await bridge.simulateAppeared(VolumeMountSnapshot(
            bsdName: "disk1s5",
            volumeURL: URL(fileURLWithPath: "/Volumes/Regular"),
            volumeName: "Regular USB"
        ))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let snap = await candidates.snapshot()
        XCTAssertTrue(snap.isEmpty)
    }

    func testTMUtilDestinationInfoFailureFailsSafe() async {
        // Can't tell if this is the local drive → DO NOT eject.
        let bridge = FakeDiskAppearedBridge()
        let role = FakeAPFSRoleQuery()
        await role.set(backup: ["disk9s2"], known: ["disk9s2"])
        let classifier = TMDriveClassifier(roleQuery: role,
                                            fileProbe: FakeVolumeFileProbe(),
                                            clock: SystemClock())
        let tmutil = FakeTMUtilClient()
        struct E: Error {}
        await tmutil.enqueueDestinationInfo(.failure(E()))
        let candidates = CandidateSink()

        let observer = DiskAppearedObserver(
            bridge: bridge, classifier: classifier, tmutil: tmutil,
            onCandidate: { c in await candidates.append(c) },
            onDisappeared: { _ in }
        )
        await observer.start()
        await bridge.simulateAppeared(VolumeMountSnapshot(
            bsdName: "disk9s2",
            volumeURL: URL(fileURLWithPath: "/Volumes/Maybe"),
            volumeName: "Maybe"
        ))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let snap = await candidates.snapshot()
        XCTAssertTrue(snap.isEmpty,
                       "destinationinfo failure must fail-safe; no candidate emitted")
    }

    func testDisappearedCallbackInvokedWithURLOfPriorCandidate() async {
        let bridge = FakeDiskAppearedBridge()
        let role = FakeAPFSRoleQuery()
        await role.set(backup: ["disk9s2"], known: ["disk9s2"])
        let classifier = TMDriveClassifier(roleQuery: role,
                                            fileProbe: FakeVolumeFileProbe(),
                                            clock: SystemClock())
        let tmutil = FakeTMUtilClient()
        await tmutil.enqueueDestinationInfo(.success([]))
        let candidates = CandidateSink()
        let disappeared = URLBox()

        let observer = DiskAppearedObserver(
            bridge: bridge, classifier: classifier, tmutil: tmutil,
            onCandidate: { c in await candidates.append(c) },
            onDisappeared: { url in await disappeared.set(url) }
        )
        await observer.start()
        await bridge.simulateAppeared(VolumeMountSnapshot(
            bsdName: "disk9s2",
            volumeURL: URL(fileURLWithPath: "/Volumes/Out"),
            volumeName: "Out"
        ))
        await ForeignDriveGracePeriodTests.waitFor(timeout: 1.0) {
            let snap = await candidates.snapshot()
            return snap.count == 1
        }
        await bridge.simulateDisappeared(bsdName: "disk9s2")
        await ForeignDriveGracePeriodTests.waitFor(timeout: 1.0) {
            let url = await disappeared.snapshot()
            return url != nil
        }
        let gotURL = await disappeared.snapshot()
        XCTAssertEqual(gotURL?.path, "/Volumes/Out")
    }
}

// MARK: - Fakes / sinks

actor FakeDiskAppearedBridge: DiskAppearedBridge {
    private var appearedSink: (@Sendable (VolumeMountSnapshot) async -> Void)?
    private var disappearedSink: (@Sendable (String) async -> Void)?

    nonisolated func start(
        onAppeared: @escaping @Sendable (VolumeMountSnapshot) async -> Void,
        onDisappeared: @escaping @Sendable (String) async -> Void
    ) {
        Task { await self.installSinks(onAppeared, onDisappeared) }
    }

    nonisolated func stop() {
        Task { await self.installSinks(nil, nil) }
    }

    private func installSinks(
        _ a: (@Sendable (VolumeMountSnapshot) async -> Void)?,
        _ d: (@Sendable (String) async -> Void)?
    ) {
        appearedSink = a
        disappearedSink = d
    }

    func simulateAppeared(_ snap: VolumeMountSnapshot) async {
        // Race with sink installation: poll briefly so callers that simulate
        // immediately after `observer.start()` don't drop the event.
        for _ in 0..<50 {
            if let sink = appearedSink { await sink(snap); return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func simulateDisappeared(bsdName: String) async {
        for _ in 0..<50 {
            if let sink = disappearedSink { await sink(bsdName); return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

actor CandidateSink {
    private var candidates: [ForeignTMDriveCandidate] = []
    func append(_ c: ForeignTMDriveCandidate) { candidates.append(c) }
    func snapshot() -> [ForeignTMDriveCandidate] { candidates }
}

actor URLBox {
    private var url: URL?
    func set(_ u: URL) { url = u }
    func snapshot() -> URL? { url }
}

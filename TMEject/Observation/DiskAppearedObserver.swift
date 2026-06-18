import Foundation
@preconcurrency import DiskArbitration

/// A foreign-TM-drive candidate surfaced by `DiskAppearedObserver`. The coordinator
/// runs the 10s grace window per candidate; see `ForeignDriveGracePeriod`.
struct ForeignTMDriveCandidate: Sendable, Equatable {
    let bsdName: String
    let volumeURL: URL
    let volumeName: String
}

/// Stable seam — wraps the part of `DA` we depend on. The live impl holds a
/// `DASession` on a background queue and forwards
/// `DADiskAppearedCallback`/`DADiskDisappearedCallback` into the actor. Tests pass a
/// fake bridge that synthesises mount events directly.
protocol DiskAppearedBridge: Sendable {
    /// Begin observing. `onAppeared` fires for every new mount (including the initial
    /// snapshot the runtime emits when matching starts — that's how we cover the
    /// "TMEject launched after the foreign drive was already there" case).
    /// `onDisappeared` fires on every unmount; the observer uses it to invalidate the
    /// role-list cache and to cancel any in-flight grace for that volume.
    ///
    /// Synchronous to keep Swift 6's region-isolation checker out of the `Unmanaged`
    /// pointer dance the live impl needs. Callers run it before `await`ing anything.
    func start(
        onAppeared: @escaping @Sendable (VolumeMountSnapshot) async -> Void,
        onDisappeared: @escaping @Sendable (String) async -> Void
    )
    func stop()
}

/// Minimal snapshot of a mount event — the fields any downstream consumer needs
/// without holding onto CF references.
struct VolumeMountSnapshot: Sendable, Equatable {
    let bsdName: String
    let volumeURL: URL
    let volumeName: String?
}

/// Foreign-TM-drive detector.
///
/// Wires `DiskAppearedBridge` to `TMDriveClassifier` and emits a
/// `ForeignTMDriveCandidate` for every mount that satisfies BOTH:
/// 1. Classifier says `.isTMDrive` — the volume is a Time Machine destination, AND
/// 2. The mount path isn't in the LOCAL `tmutil destinationinfo -X` `MountPoint`
///    set — this Mac doesn't own it.
///
/// Skipped (no candidate emitted) when:
/// - Classifier says `.notTMDrive` or `.unknown` (fail-safe — see classifier docs)
/// - Mount path matches a local destination's `MountPoint`
/// - `tmutil destinationinfo` shells out failing — caller can't compare safely,
///   so we surface a WARN log and skip rather than risk ejecting this Mac's own drive
///
/// On every mount/unmount event we invalidate the classifier's cache so the next
/// classify() reflects the new topology. A 30s heartbeat in the classifier itself
/// covers the no-mount-events-but-data-stale case.
actor DiskAppearedObserver {

    private let bridge: DiskAppearedBridge
    private let classifier: TMDriveClassifier
    private let tmutil: TMUtilClient
    private let onCandidate: @Sendable (ForeignTMDriveCandidate) async -> Void
    private let onDisappeared: @Sendable (URL) async -> Void
    private var started = false
    /// Tracks BSD → mount URL for every candidate we surfaced. The disappeared
    /// callback gives us only the BSD name; we look up the URL here so the
    /// coordinator's grace-period bookkeeping (which keys by volumeURL) can cancel
    /// the right pending eject if the drive is yanked mid-grace.
    private var bsdToCandidateURL: [String: URL] = [:]

    init(
        bridge: DiskAppearedBridge = LiveDiskAppearedBridge(),
        classifier: TMDriveClassifier = TMDriveClassifier(),
        tmutil: TMUtilClient,
        onCandidate: @escaping @Sendable (ForeignTMDriveCandidate) async -> Void,
        onDisappeared: @escaping @Sendable (URL) async -> Void
    ) {
        self.bridge = bridge
        self.classifier = classifier
        self.tmutil = tmutil
        self.onCandidate = onCandidate
        self.onDisappeared = onDisappeared
    }

    func start() async {
        guard !started else { return }
        started = true
        TMEjectLog.observer.info("DiskAppearedObserver starting")
        await classifier.warm()
        bridge.start(
            onAppeared: { [weak self] snap in
                guard let self else { return }
                await self.handleAppearedFromBridge(snap)
            },
            onDisappeared: { [weak self] bsdName in
                guard let self else { return }
                await self.handleDisappearedFromBridge(bsdName: bsdName)
            }
        )
    }

    private func handleAppearedFromBridge(_ snap: VolumeMountSnapshot) async {
        await classifier.invalidate()
        let candidate = await Self.classifyAndDecide(
            snap: snap, classifier: classifier, tmutil: tmutil
        )
        guard let candidate else { return }
        bsdToCandidateURL[candidate.bsdName] = candidate.volumeURL
        await onCandidate(candidate)
    }

    private func handleDisappearedFromBridge(bsdName: String) async {
        await classifier.invalidate()
        TMEjectLog.observer.debug("DiskAppearedObserver: disappeared bsd=\(bsdName)")
        guard let url = bsdToCandidateURL.removeValue(forKey: bsdName) else { return }
        await onDisappeared(url)
    }

    func stop() async {
        guard started else { return }
        started = false
        bridge.stop()
        TMEjectLog.observer.info("DiskAppearedObserver stopped")
    }

    // MARK: - Internal

    /// Pure classification + foreign-vs-own decision. Returns a candidate iff the
    /// volume is a TM drive AND it's NOT in this Mac's `tmutil destinationinfo`
    /// MountPoint set. All skip-paths log at INFO/ERROR per the locked logging spec.
    private static func classifyAndDecide(
        snap: VolumeMountSnapshot,
        classifier: TMDriveClassifier,
        tmutil: TMUtilClient
    ) async -> ForeignTMDriveCandidate? {
        TMEjectLog.observer.info(
            "DiskAppearedObserver: mount appeared bsd=\(snap.bsdName) "
                + "path=\(snap.volumeURL.path) name=\(snap.volumeName ?? "nil")"
        )

        let classification = await classifier.classify(
            bsdName: snap.bsdName, mountPath: snap.volumeURL.path
        )
        switch classification {
        case .notTMDrive:
            TMEjectLog.observer.debug(
                "DiskAppearedObserver: skip \(snap.bsdName) — not a TM drive"
            )
            return nil
        case .unknown:
            TMEjectLog.observer.error(
                "DiskAppearedObserver: skip \(snap.bsdName) — classification unknown (fail-safe)"
            )
            return nil
        case .isTMDrive:
            break
        }

        // Compare against THIS Mac's destinationinfo to decide foreign vs own.
        let localDestPaths: Set<String>
        do {
            let dests = try await tmutil.destinationInfo()
            localDestPaths = Set(dests.compactMap { $0.mountPoint?.path })
        } catch {
            // Fail safe: don't eject when we can't tell whose drive this is.
            TMEjectLog.observer.error(
                "DiskAppearedObserver: tmutil destinationinfo failed (\(error)) — "
                    + "cannot tell if \(snap.bsdName) is local; skipping (fail-safe)"
            )
            return nil
        }

        if localDestPaths.contains(snap.volumeURL.path) {
            TMEjectLog.observer.info(
                "DiskAppearedObserver: \(snap.bsdName) is THIS Mac's TM drive — not foreign"
            )
            return nil
        }

        let candidate = ForeignTMDriveCandidate(
            bsdName: snap.bsdName,
            volumeURL: snap.volumeURL,
            volumeName: snap.volumeName ?? snap.volumeURL.lastPathComponent
        )
        TMEjectLog.observer.info(
            "DiskAppearedObserver: FOREIGN TM drive detected bsd=\(candidate.bsdName) "
                + "name=\(candidate.volumeName) path=\(candidate.volumeURL.path) "
                + "localDestinations=[\(localDestPaths.sorted().joined(separator: ","))]"
        )
        return candidate
    }
}

// MARK: - Live DA bridge

/// Holds a `DASession` on a userInitiated dispatch queue and routes
/// `DADiskAppearedCallback`/`DADiskDisappearedCallback` events into Swift async
/// closures. The DA session must outlive the observer; we keep a strong reference.
final class LiveDiskAppearedBridge: DiskAppearedBridge, @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.tmeject.app.diskAppeared",
                                      qos: .userInitiated)
    private let session: DASession
    private let sinkLock = NSLock()
    /// nonisolated(unsafe) backing for the SinkBox — accessed only via `sinkLock`.
    nonisolated(unsafe) private var sink: SinkBox?

    init() {
        guard let s = DASessionCreate(kCFAllocatorDefault) else {
            fatalError("DASessionCreate returned nil")
        }
        self.session = s
    }

    func start(
        onAppeared: @escaping @Sendable (VolumeMountSnapshot) async -> Void,
        onDisappeared: @escaping @Sendable (String) async -> Void
    ) {
        // DA fires callbacks for every CURRENTLY mounted volume at registration
        // time — that handles the "TMEject launched after the foreign drive was
        // already mounted" case naturally. We pin a single SinkBox under the
        // session lifetime; the C callbacks consult it via Unmanaged.passUnretained.
        let box = SinkBox(onAppeared: onAppeared, onDisappeared: onDisappeared)
        sinkLock.lock(); sink = box; sinkLock.unlock()
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        LiveDiskAppearedBridge.registerCallbacks(session: session, ctx: ctx)
        DASessionSetDispatchQueue(session, queue)
        TMEjectLog.observer.info("LiveDiskAppearedBridge registered DA callbacks")
    }

    func stop() {
        DASessionSetDispatchQueue(session, nil)
        sinkLock.lock(); sink = nil; sinkLock.unlock()
        TMEjectLog.observer.info("LiveDiskAppearedBridge unregistered DA callbacks")
    }

    /// Pulled out as a static nonisolated function so Swift 6's region-isolation
    /// pass doesn't try to reason about the `Unmanaged` pointer alongside captured
    /// closures on the instance.
    private static func registerCallbacks(session: DASession, ctx: UnsafeMutableRawPointer) {
        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            guard let ctx else { return }
            let box = Unmanaged<SinkBox>.fromOpaque(ctx).takeUnretainedValue()
            let snap = LiveDiskAppearedBridge.snapshot(from: disk)
            guard let snap else { return }
            let cb = box.onAppeared
            Task { await cb(snap) }
        }, ctx)

        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            guard let ctx else { return }
            let box = Unmanaged<SinkBox>.fromOpaque(ctx).takeUnretainedValue()
            let bsd = DADiskGetBSDName(disk).map { String(cString: $0) } ?? ""
            guard !bsd.isEmpty else { return }
            let cb = box.onDisappeared
            Task { await cb(bsd) }
        }, ctx)
    }

    private static func snapshot(from disk: DADisk) -> VolumeMountSnapshot? {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        // Only act on volumes that are actually mountable AND mounted — DA fires for
        // non-volume media (whole disks, partitions without a filesystem) too.
        guard desc[kDADiskDescriptionVolumeMountableKey as String] as? Bool == true else {
            return nil
        }
        let pathURL: URL? = {
            if let cfURL = desc[kDADiskDescriptionVolumePathKey as String] {
                return (cfURL as? NSURL) as URL?
            }
            return nil
        }()
        guard let path = pathURL else { return nil }
        let bsd = (desc[kDADiskDescriptionMediaBSDNameKey as String] as? String)
            ?? (DADiskGetBSDName(disk).map { String(cString: $0) } ?? "")
        guard !bsd.isEmpty else { return nil }
        let name = desc[kDADiskDescriptionVolumeNameKey as String] as? String
        return VolumeMountSnapshot(bsdName: bsd, volumeURL: path, volumeName: name)
    }

    private final class SinkBox: @unchecked Sendable {
        let onAppeared: @Sendable (VolumeMountSnapshot) async -> Void
        let onDisappeared: @Sendable (String) async -> Void
        init(onAppeared: @escaping @Sendable (VolumeMountSnapshot) async -> Void,
             onDisappeared: @escaping @Sendable (String) async -> Void) {
            self.onAppeared = onAppeared
            self.onDisappeared = onDisappeared
        }
    }
}

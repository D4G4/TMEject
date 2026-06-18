import Foundation

/// Classifies a freshly-mounted volume as a Time Machine destination or not. Used by
/// `DiskAppearedObserver` after every mount to decide whether the foreign-TM-drive
/// path should engage.
///
/// **Strategy A — primary (APFS role check via diskutil).**
/// `/usr/sbin/diskutil apfs list -plist` emits a property list keyed by container, and
/// every APFS volume entry includes a `Roles` array. A Time Machine destination on
/// modern macOS has `Roles = ["Backup"]`. We parse the plist, build a set of all BSD
/// device identifiers whose role array contains `"Backup"`, and check the volume's
/// BSD name against it. The cache is invalidated on every mount/unmount event the
/// observer sees, plus a 30s heartbeat — mount events change the topology, so the
/// cache must be fresh exactly when we query it.
///
/// Why this and not `DADiskCopyDescription`: empirical probe on macOS Tahoe shows the
/// description dict has no APFS-roles field, and the public DiskArbitration framework
/// does NOT export `kDADiskDescriptionVolumeApfsRolesKey`. The `diskutil` shell-out
/// surfaces the same data without private SPI or Full Disk Access.
///
/// **Strategy B — fallback (filesystem markers).**
/// For HFS+ legacy TM destinations (which `diskutil apfs list` won't enumerate) or
/// race cases where the role check is inconclusive, look for:
/// - `.com.apple.TimeMachine.IOCheck/` at the volume root (APFS-era — always present
///   on configured destinations even before the first backup)
/// - `Backups.backupdb/` at the volume root (HFS+ legacy)
///
/// **Fail-safe.** If A errored AND B found nothing, we return `.unknown` rather than
/// guessing. The caller treats `.unknown` as "do nothing" — TMEject must never eject
/// a non-TM drive. See `AppCoordinator.handleForeignTMDriveCandidate` for the gate.
actor TMDriveClassifier {

    enum Classification: String, Sendable, Equatable {
        /// Volume is a Time Machine destination (role = Backup OR FS markers found).
        case isTMDrive
        /// We have positive evidence the volume is NOT a TM destination (APFS role
        /// list complete, BSD found, role ≠ Backup, AND no FS markers).
        case notTMDrive
        /// Could not classify. Strategy A errored or returned no role info for this
        /// BSD, AND strategy B's markers are absent. Caller MUST NOT eject — fail
        /// safe direction per design.
        case unknown
    }

    struct APFSRoleSnapshot: Sendable, Equatable {
        let fetchedAt: TimeInterval
        let backupBSDNames: Set<String>
        let knownBSDNames: Set<String>
    }

    /// Stable seam for tests — wraps the `diskutil apfs list -plist` shell-out.
    protocol APFSRoleQuery: Sendable {
        /// Returns the set of BSD names whose APFS role array contains `"Backup"`, and
        /// the set of BSD names known to the plist at all. Returns `nil` when the
        /// shell-out fails (non-zero exit, can't launch, plist unparseable) — that's
        /// the "errored out" branch the fail-safe rule references.
        func currentSnapshot() async -> (backup: Set<String>, allKnown: Set<String>)?
    }

    /// Stable seam for tests — wraps `FileManager.default.fileExists`.
    protocol VolumeFileProbe: Sendable {
        func exists(atPath path: String) -> Bool
    }

    static let cacheTTLSeconds: TimeInterval = 30

    private let roleQuery: APFSRoleQuery
    private let fileProbe: VolumeFileProbe
    private let clock: MonotonicClock
    private var cached: APFSRoleSnapshot?

    init(
        roleQuery: APFSRoleQuery = LiveAPFSRoleQuery(),
        fileProbe: VolumeFileProbe = LiveVolumeFileProbe(),
        clock: MonotonicClock = SystemClock()
    ) {
        self.roleQuery = roleQuery
        self.fileProbe = fileProbe
        self.clock = clock
    }

    /// Mark the cache as stale. Call from `DADiskAppearedCallback` and
    /// `DADiskDisappearedCallback` — every mount event changes the topology, so the
    /// next classify() must re-query.
    func invalidate() {
        cached = nil
    }

    /// Force a fresh role query immediately. Used by the observer at startup so the
    /// "TMEject launched after the foreign drive was already mounted" enumeration
    /// has a warm cache to compare against.
    func warm() async {
        cached = nil
        _ = await currentBackupBSDNames()
    }

    /// Classify a volume. `bsdName` is the BSD device identifier (e.g. `"disk7s2"`)
    /// — must match the form `diskutil` reports under `DeviceIdentifier`. `mountPath`
    /// is the volume's mount point (e.g. `/Volumes/Foo`); both strategies need it.
    func classify(bsdName: String, mountPath: String) async -> Classification {
        let snapshot = await currentBackupBSDNames()
        let roleSaysBackup = snapshot?.backupBSDNames.contains(bsdName) ?? false
        let bsdKnownToPlist = snapshot?.knownBSDNames.contains(bsdName) ?? false
        let plistAvailable = snapshot != nil

        let mountURL = URL(fileURLWithPath: mountPath)
        let ioCheckPath  = mountURL.appendingPathComponent(".com.apple.TimeMachine.IOCheck").path
        let backupsDBPath = mountURL.appendingPathComponent("Backups.backupdb").path
        let hasIOCheck   = fileProbe.exists(atPath: ioCheckPath)
        let hasBackupsDB = fileProbe.exists(atPath: backupsDBPath)
        let markersSayYes = hasIOCheck || hasBackupsDB

        let logSnap = plistAvailable
            ? "backupBSDs=\(snapshot?.backupBSDNames.sorted().joined(separator: ",") ?? "") known=\(snapshot?.knownBSDNames.count ?? 0)"
            : "plist=ERR"
        TMEjectLog.observer.debug(
            "TMDriveClassifier(\(bsdName) @ \(mountPath)): \(logSnap) "
                + "roleSaysBackup=\(roleSaysBackup) bsdInPlist=\(bsdKnownToPlist) "
                + "IOCheck=\(hasIOCheck) BackupsDB=\(hasBackupsDB)"
        )

        if roleSaysBackup || markersSayYes {
            return .isTMDrive
        }

        // Neither path said yes. To return `.notTMDrive` we need POSITIVE evidence
        // (role list complete + BSD found in it). Otherwise we have to fail-safe to
        // `.unknown` — the team-lead-locked rule: classification failure → do nothing,
        // not "assume safe to eject."
        if plistAvailable && bsdKnownToPlist {
            return .notTMDrive
        }
        TMEjectLog.observer.error(
            "TMDriveClassifier: classification UNKNOWN for \(bsdName) @ \(mountPath) — "
                + "plistAvailable=\(plistAvailable) bsdInPlist=\(bsdKnownToPlist) "
                + "IOCheck=\(hasIOCheck) BackupsDB=\(hasBackupsDB); fail-safe → do nothing"
        )
        return .unknown
    }

    // MARK: - Internal

    private func currentBackupBSDNames() async -> APFSRoleSnapshot? {
        let now = clock.now()
        if let cached, now - cached.fetchedAt < Self.cacheTTLSeconds {
            return cached
        }
        guard let snap = await roleQuery.currentSnapshot() else {
            // Shell-out failed — do NOT cache the error; next call re-tries fresh.
            cached = nil
            return nil
        }
        let snapshot = APFSRoleSnapshot(
            fetchedAt: now,
            backupBSDNames: snap.backup,
            knownBSDNames: snap.allKnown
        )
        cached = snapshot
        return snapshot
    }
}

// MARK: - Live implementations

/// Wraps `/usr/sbin/diskutil apfs list -plist`. Parses the plist, walks every
/// container's `Volumes` array, and collects BSD names whose `Roles` array contains
/// `"Backup"`. Returns nil on any failure — the classifier's fail-safe rule kicks in.
struct LiveAPFSRoleQuery: TMDriveClassifier.APFSRoleQuery {
    private let diskutilPath: String

    init(diskutilPath: String = "/usr/sbin/diskutil") {
        self.diskutilPath = diskutilPath
    }

    func currentSnapshot() async -> (backup: Set<String>, allKnown: Set<String>)? {
        let data: Data
        do {
            data = try await Self.runProcess(path: diskutilPath, args: ["apfs", "list", "-plist"])
        } catch {
            TMEjectLog.observer.error("diskutil apfs list -plist failed: \(error)")
            return nil
        }
        guard let parsed = try? PropertyListSerialization.propertyList(from: data,
                                                                        format: nil) as? [String: Any] else {
            TMEjectLog.observer.error("diskutil apfs list -plist returned unparseable plist (\(data.count)B)")
            return nil
        }
        guard let containers = parsed["Containers"] as? [[String: Any]] else {
            TMEjectLog.observer.error("diskutil apfs list -plist missing 'Containers' key")
            return nil
        }
        var backupBSDs: Set<String> = []
        var knownBSDs: Set<String> = []
        for container in containers {
            guard let volumes = container["Volumes"] as? [[String: Any]] else { continue }
            for volume in volumes {
                guard let device = volume["DeviceIdentifier"] as? String else { continue }
                knownBSDs.insert(device)
                let roles = (volume["Roles"] as? [String]) ?? []
                if roles.contains("Backup") {
                    backupBSDs.insert(device)
                }
            }
        }
        TMEjectLog.observer.debug(
            "LiveAPFSRoleQuery: known=\(knownBSDs.count) backupRole=\(backupBSDs.sorted().joined(separator: ","))"
        )
        return (backup: backupBSDs, allKnown: knownBSDs)
    }

    private static func runProcess(path: String, args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            let outHandle = outPipe.fileHandleForReading
            let errHandle = errPipe.fileHandleForReading
            p.terminationHandler = { proc in
                let outData = (try? outHandle.readToEnd()) ?? Data()
                let errData = (try? errHandle.readToEnd()) ?? Data()
                if proc.terminationStatus == 0 {
                    cont.resume(returning: outData)
                } else {
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: NSError(
                        domain: "TMDriveClassifier", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "diskutil exit \(proc.terminationStatus): \(stderr)"]
                    ))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

struct LiveVolumeFileProbe: TMDriveClassifier.VolumeFileProbe {
    func exists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

import Foundation
@preconcurrency import DiskArbitration

struct ResolvedDestination: Equatable, Sendable {
    let volumeUUID: UUID?
    let bsdName: String
    let volumeURL: URL
    let volumeName: String?
}

struct VolumeDADescription: Sendable {
    let volumeUUID: UUID?
    let bsdName: String?
    let volumeName: String?
}

protocol DiskArbitrationBridge: Sendable {
    func mountedVolumeURLs() -> [URL]
    func description(forVolumeAt url: URL) -> VolumeDADescription?
}

struct LiveDiskArbitrationBridge: DiskArbitrationBridge {
    private let session: DASession

    init() {
        guard let s = DASessionCreate(kCFAllocatorDefault) else {
            fatalError("DASessionCreate returned nil")
        }
        self.session = s
    }

    func mountedVolumeURLs() -> [URL] {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey, .volumeURLKey]
        return FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
    }

    func description(forVolumeAt url: URL) -> VolumeDADescription? {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            return nil
        }
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else {
            return nil
        }
        let uuidString: String? = {
            guard let raw = desc[kDADiskDescriptionVolumeUUIDKey as String] else { return nil }
            let cfUUID = raw as! CFUUID
            return CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String?
        }()
        let bsdName: String? = {
            desc[kDADiskDescriptionMediaBSDNameKey as String] as? String
        }()
        let volumeName: String? = {
            desc[kDADiskDescriptionVolumeNameKey as String] as? String
        }()
        return VolumeDADescription(
            volumeUUID: uuidString.flatMap(UUID.init(uuidString:)),
            bsdName: bsdName,
            volumeName: volumeName
        )
    }
}

/// Existence probe for the mount point, abstracted so tests don't depend on the real fs.
protocol FileExistsProbe: Sendable {
    func exists(atPath path: String) -> Bool
}

struct LiveFileExistsProbe: FileExistsProbe {
    func exists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

struct DestinationResolver: Sendable {
    let bridge: DiskArbitrationBridge
    let fileExists: FileExistsProbe

    init(
        bridge: DiskArbitrationBridge = LiveDiskArbitrationBridge(),
        fileExists: FileExistsProbe = LiveFileExistsProbe()
    ) {
        self.bridge = bridge
        self.fileExists = fileExists
    }

    /// Resolves a Time Machine destination to its mounted volume using `tmutil`'s own
    /// `MountPoint` field — tmutil already knows where the destination is mounted; we don't
    /// need to derive it.
    ///
    /// Step 4's original design matched `DestinationInfo.id` against `kDADiskDescriptionVolumeUUIDKey`.
    /// End-to-end backup verification on macOS 26.3.1 revealed those are two ORTHOGONAL
    /// identifiers — the tmutil registry `ID` is not the filesystem volume UUID. Empirical
    /// `DADiskCopyDescription` dump on a configured TM drive exposes zero fields that
    /// contain the tmutil `ID`. The fallback to name matching that landed in dbdb6cb worked
    /// but was solving a problem that didn't exist: `tmutil destinationinfo -X` already
    /// includes `MountPoint`. Use that.
    ///
    /// Returns nil when:
    /// - `mountPoint` is nil (tmutil didn't report a mount — destination not currently mounted).
    /// - The mount path doesn't exist on disk (drive was yanked between the tmutil read and
    ///   the resolver call).
    /// - DiskArbitration can't describe the volume (very unusual — would indicate the path
    ///   isn't a real volume root, or DA permissions broke).
    /// - DA returns no `MediaBSDName` (we need it for the unmount syscall).
    ///
    /// No name-match fallback: if MountPoint isn't there, surface the failure cleanly rather
    /// than guessing. The dbdb6cb name-match path is gone.
    func resolve(mountPoint: URL?) -> ResolvedDestination? {
        guard let mountPoint else { return nil }
        guard fileExists.exists(atPath: mountPoint.path) else {
            TMEjectLog.observer.error(
                "DestinationResolver: tmutil reported MountPoint \(mountPoint.path) but the path doesn't exist"
            )
            return nil
        }
        guard let desc = bridge.description(forVolumeAt: mountPoint) else {
            TMEjectLog.observer.error(
                "DestinationResolver: DA returned no description for \(mountPoint.path)"
            )
            return nil
        }
        guard let bsd = desc.bsdName else {
            TMEjectLog.observer.error(
                "DestinationResolver: DA description for \(mountPoint.path) missing BSD name"
            )
            return nil
        }
        return ResolvedDestination(
            volumeUUID: desc.volumeUUID,
            bsdName: bsd,
            volumeURL: mountPoint,
            volumeName: desc.volumeName
        )
    }
}

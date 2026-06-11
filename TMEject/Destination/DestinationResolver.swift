import Foundation
@preconcurrency import DiskArbitration

struct ResolvedDestination: Equatable, Sendable {
    let volumeUUID: UUID
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
        // DASessionCreate returns nil only under OOM, in which case the caller can't recover.
        // Crashing here surfaces the real OS condition rather than masking it as "no destinations."
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
            // The framework returns a CFUUIDRef under kDADiskDescriptionVolumeUUIDKey; round-trip
            // through CFUUIDCreateString to get its canonical string form.
            guard let raw = desc[kDADiskDescriptionVolumeUUIDKey as String] else { return nil }
            let cfUUID = raw as! CFUUID
            return CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String?
        }()
        let bsdName: String? = {
            // BSD name comes back as a CFString like "disk4s2". Caller never prepends /dev/.
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

struct DestinationResolver: Sendable {
    let bridge: DiskArbitrationBridge

    init(bridge: DiskArbitrationBridge = LiveDiskArbitrationBridge()) {
        self.bridge = bridge
    }

    func resolve(destinationID: UUID) -> ResolvedDestination? {
        for url in bridge.mountedVolumeURLs() {
            guard let desc = bridge.description(forVolumeAt: url) else { continue }
            guard let volUUID = desc.volumeUUID, volUUID == destinationID else { continue }
            guard let bsd = desc.bsdName else {
                TMEjectLog.observer.error(
                    "DestinationResolver: UUID match for \(destinationID) at \(url.path) but missing BSD name"
                )
                continue
            }
            return ResolvedDestination(
                volumeUUID: volUUID,
                bsdName: bsd,
                volumeURL: url,
                volumeName: desc.volumeName
            )
        }
        return nil
    }
}

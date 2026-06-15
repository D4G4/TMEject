import Foundation

struct StatusPlist: Equatable, Sendable {
    let running: Bool
    let backupPhase: String?
    let rawTotalBytes: Int64?
    let percent: Double?
    let destinationID: UUID?

    init(
        running: Bool,
        backupPhase: String? = nil,
        rawTotalBytes: Int64? = nil,
        percent: Double? = nil,
        destinationID: UUID? = nil
    ) {
        self.running = running
        self.backupPhase = backupPhase
        self.rawTotalBytes = rawTotalBytes
        self.percent = percent
        self.destinationID = destinationID
    }

    static func parse(plistData: Data) throws -> StatusPlist {
        let any: Any
        do {
            any = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        } catch {
            throw TMUtilError.malformedPlist(underlying: error)
        }
        guard let dict = any as? [String: Any] else {
            throw TMUtilError.malformedPlist(underlying: nil)
        }
        let running = (dict["Running"] as? Bool) ?? false
        let phase = dict["BackupPhase"] as? String

        let totalBytes: Int64?
        if let n = dict["_raw_totalBytes"] as? NSNumber { totalBytes = n.int64Value }
        else if let s = dict["_raw_totalBytes"] as? String { totalBytes = Int64(s) }
        else { totalBytes = nil }

        let percent: Double?
        if let n = dict["Percent"] as? NSNumber { percent = n.doubleValue }
        else if let s = dict["Percent"] as? String { percent = Double(s) }
        else { percent = nil }

        let destID: UUID?
        if let s = dict["DestinationID"] as? String { destID = UUID(uuidString: s) }
        else { destID = nil }

        return StatusPlist(
            running: running,
            backupPhase: phase,
            rawTotalBytes: totalBytes,
            percent: percent,
            destinationID: destID
        )
    }
}

struct DestinationInfo: Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: String
    let lastDestination: Bool
    /// Volume mount point as reported by `tmutil destinationinfo -X` (the `MountPoint` key).
    /// Used by `DestinationResolver` to identify the live volume — TM's destination registry
    /// `id` is NOT the filesystem volume UUID on macOS 26.x, so we can't match against DA's
    /// volume UUID. tmutil already knows where the destination is mounted; use its answer
    /// directly. Nil when the destination isn't currently mounted, or for network
    /// destinations that haven't been auto-mounted yet.
    let mountPoint: URL?

    init(
        id: UUID,
        name: String,
        kind: String,
        lastDestination: Bool,
        mountPoint: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.lastDestination = lastDestination
        self.mountPoint = mountPoint
    }

    static func parseList(plistData: Data) throws -> [DestinationInfo] {
        let any: Any
        do {
            any = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        } catch {
            throw TMUtilError.malformedPlist(underlying: error)
        }
        guard let root = any as? [String: Any] else {
            throw TMUtilError.malformedPlist(underlying: nil)
        }
        guard let array = root["Destinations"] as? [[String: Any]] else { return [] }
        return array.compactMap { dict -> DestinationInfo? in
            let idString = (dict["ID"] as? String) ?? (dict["DestinationID"] as? String)
            guard let idString, let uuid = UUID(uuidString: idString) else { return nil }
            let name = (dict["Name"] as? String) ?? ""
            let kind = (dict["Kind"] as? String) ?? ""
            let lastDest: Bool = {
                if let n = dict["LastDestination"] as? NSNumber { return n.intValue != 0 }
                if let b = dict["LastDestination"] as? Bool { return b }
                return false
            }()
            // tmutil reports the mount as a path string under `MountPoint`. No known legacy
            // alias on supported macOS versions — leave it nil if absent rather than guessing.
            let mountPoint: URL? = {
                guard let path = dict["MountPoint"] as? String, !path.isEmpty else { return nil }
                return URL(fileURLWithPath: path)
            }()
            return DestinationInfo(id: uuid, name: name, kind: kind,
                                    lastDestination: lastDest, mountPoint: mountPoint)
        }
    }
}

enum TMUtilError: Error, CustomStringConvertible {
    case launchFailed(underlying: Error)
    case nonZeroExit(code: Int32, stderr: String)
    case malformedPlist(underlying: Error?)
    case latestBackupUnavailable(stderr: String)

    var description: String {
        switch self {
        case .launchFailed(let e):       return "tmutil launch failed: \(e)"
        case .nonZeroExit(let c, let s): return "tmutil exit \(c): \(s)"
        case .malformedPlist(let e):     return "tmutil plist malformed: \(e.map { "\($0)" } ?? "no dict root")"
        case .latestBackupUnavailable(let s): return "tmutil latestbackup unavailable: \(s)"
        }
    }
}

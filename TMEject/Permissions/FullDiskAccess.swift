import Foundation

enum FDAState: Sendable, Equatable {
    /// Definitive — tmutil latestbackup succeeded (or failed for a non-FDA reason).
    case granted
    /// Definitive — tmutil latestbackup refused with the FDA stderr substring.
    case denied
    /// Probe itself couldn't return a definitive answer (tmutil binary missing, etc.).
    case unknown
}

protocol FullDiskAccessProbing: Sendable {
    func currentState() async -> FDAState
}

struct LiveFullDiskAccessProber: FullDiskAccessProbing {
    let tmutil: TMUtilClient

    init(tmutil: TMUtilClient) {
        self.tmutil = tmutil
    }

    func currentState() async -> FDAState {
        let raw = await tmutil.latestBackupRaw()
        return Self.classify(raw)
    }

    /// Visible for tests. The classification rule is:
    /// - stderr contains "Full Disk Access" → .denied.
    /// - exit 0 (regardless of stdout — empty stdout just means no snapshots yet) → .granted.
    /// - any other non-zero exit (e.g. "Failed to mount destination" when the drive is
    ///   unplugged) → .granted. We HAD permission to ask; tmutil's refusal is unrelated to
    ///   our privilege level.
    /// - probe couldn't run at all (exit -1 from launch failure) → .unknown.
    static func classify(_ raw: TMUtilRawResult) -> FDAState {
        if raw.stderr.contains("Full Disk Access") { return .denied }
        if raw.exitCode == -1 { return .unknown }
        return .granted
    }
}

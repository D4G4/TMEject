import Foundation

protocol TMUtilClient: Sendable {
    func status() async throws -> StatusPlist
    func destinationInfo() async throws -> [DestinationInfo]
    func latestBackup() async throws -> URL?
    func stopBackup() async throws

    /// Raw three-tuple variant of `latestbackup`. Used by the FDA prober to inspect stderr
    /// for the FDA refusal string distinctly from any other failure mode (no destination,
    /// disk not mounted, etc.). Never throws — failures are encoded in the tuple.
    func latestBackupRaw() async -> TMUtilRawResult
}

struct TMUtilRawResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

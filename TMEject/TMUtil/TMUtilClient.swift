import Foundation

protocol TMUtilClient: Sendable {
    func status() async throws -> StatusPlist
    func destinationInfo() async throws -> [DestinationInfo]
    func latestBackup() async throws -> URL?
    func stopBackup() async throws
}

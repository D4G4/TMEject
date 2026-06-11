import Foundation
@testable import TMEject

struct FakeDiskArbitrationBridge: DiskArbitrationBridge {
    let volumes: [(URL, VolumeDADescription?)]

    func mountedVolumeURLs() -> [URL] {
        volumes.map(\.0)
    }

    func description(forVolumeAt url: URL) -> VolumeDADescription? {
        for (vURL, desc) in volumes where vURL == url {
            return desc
        }
        return nil
    }
}

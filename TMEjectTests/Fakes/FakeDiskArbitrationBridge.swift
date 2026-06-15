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

/// File-existence probe whose `exists` answer is configurable per test path. Used by
/// `DestinationResolverTests` and any coordinator-level test that hands a tmutil
/// `MountPoint` to the resolver — the synthetic test paths (`/Volumes/Backup`) don't
/// actually exist on the test runner, so the live probe would reject them.
struct FakeFileExistsProbe: FileExistsProbe {
    let existingPaths: Set<String>

    init(existing: [URL] = []) {
        self.existingPaths = Set(existing.map(\.path))
    }

    func exists(atPath path: String) -> Bool { existingPaths.contains(path) }
}

/// Convenience for "every path exists" — used by coordinator tests that just want the
/// resolver to succeed when DA also returns a matching description.
struct AlwaysExistsFileProbe: FileExistsProbe {
    func exists(atPath path: String) -> Bool { true }
}

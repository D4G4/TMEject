import Foundation

protocol ScreenLocker: Sendable {
    func lockScreen() async -> Result<Void, ScreenLockError>
}

enum ScreenLockError: Error, CustomStringConvertible {
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
    case binaryMissing(path: String)

    var description: String {
        switch self {
        case .launchFailed(let m):       return "CGSession launch failed: \(m)"
        case .nonZeroExit(let c, let s): return "CGSession exit \(c): \(s)"
        case .binaryMissing(let p):      return "CGSession binary missing at \(p)"
        }
    }
}

struct LiveScreenLocker: ScreenLocker {
    static let cgSessionPath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

    private let binaryPath: String

    init(binaryPath: String = LiveScreenLocker.cgSessionPath) {
        self.binaryPath = binaryPath
    }

    func lockScreen() async -> Result<Void, ScreenLockError> {
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            // macOS deprecation watch: if Apple ever removes User.menu/CGSession we'll need a
            // fallback. Today this binary is present on every released macOS through 26.x.
            return .failure(.binaryMissing(path: binaryPath))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<Void, ScreenLockError>, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binaryPath)
            proc.arguments = ["-suspend"]
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = Pipe()
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume(returning: .success(()))
                } else {
                    let err = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    cont.resume(returning: .failure(.nonZeroExit(
                        code: p.terminationStatus,
                        stderr: String(data: err, encoding: .utf8) ?? ""
                    )))
                }
            }
            do {
                try proc.run()
            } catch {
                cont.resume(returning: .failure(.launchFailed("\(error)")))
            }
        }
    }
}

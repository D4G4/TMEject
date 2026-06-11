import Foundation

struct LiveTMUtilClient: TMUtilClient {
    private let tmutilPath: String

    init(tmutilPath: String = "/usr/bin/tmutil") {
        self.tmutilPath = tmutilPath
    }

    func status() async throws -> StatusPlist {
        let result = try await run(args: ["status", "-X"])
        return try StatusPlist.parse(plistData: result.stdout)
    }

    func destinationInfo() async throws -> [DestinationInfo] {
        let result = try await run(args: ["destinationinfo", "-X"])
        return try DestinationInfo.parseList(plistData: result.stdout)
    }

    func latestBackup() async throws -> URL? {
        // `tmutil latestbackup` writes the path to stdout on success.
        // When no destination is reachable it exits non-zero with a backupd error string;
        // we surface that distinctly from a generic launch failure so the caller can decide
        // whether to treat "no snapshot yet" as success-vs-cancellation later.
        do {
            let result = try await run(args: ["latestbackup"])
            let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        } catch TMUtilError.nonZeroExit(_, let stderr) {
            throw TMUtilError.latestBackupUnavailable(stderr: stderr)
        }
    }

    func stopBackup() async throws {
        _ = try await run(args: ["stopbackup"])
    }

    // MARK: - Process plumbing

    private struct ProcessResult {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
        var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
        var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    private func run(args: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmutilPath)
            process.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Drain both pipes off the termination handler to avoid the read-side blocking
            // a child that writes more than the pipe buffer (64 KB on macOS).
            let outHandle = outPipe.fileHandleForReading
            let errHandle = errPipe.fileHandleForReading

            process.terminationHandler = { proc in
                let outData = (try? outHandle.readToEnd()) ?? Data()
                let errData = (try? errHandle.readToEnd()) ?? Data()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: ProcessResult(
                        stdout: outData, stderr: errData, exitCode: 0
                    ))
                } else {
                    continuation.resume(throwing: TMUtilError.nonZeroExit(
                        code: proc.terminationStatus,
                        stderr: String(data: errData, encoding: .utf8) ?? ""
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TMUtilError.launchFailed(underlying: error))
            }
        }
    }
}

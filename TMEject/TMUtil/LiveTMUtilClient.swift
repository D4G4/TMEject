import Foundation

struct LiveTMUtilClient: TMUtilClient {
    private let tmutilPath: String

    init(tmutilPath: String = "/usr/bin/tmutil") {
        self.tmutilPath = tmutilPath
    }

    func status() async throws -> StatusPlist {
        let result = try await run(args: ["status", "-X"])
        let status = try StatusPlist.parse(plistData: result.stdout)
        let pct = status.percent.map { String(format: "%.1f", $0) } ?? "nil"
        TMEjectLog.tmutil.debug(
            "status -X → Running=\(status.running) Percent=\(pct) BackupPhase=\(status.backupPhase ?? "nil") _raw_totalBytes=\(status.rawTotalBytes.map(String.init) ?? "nil")"
        )
        return status
    }

    func destinationInfo() async throws -> [DestinationInfo] {
        let result = try await run(args: ["destinationinfo", "-X"])
        let dests = try DestinationInfo.parseList(plistData: result.stdout)
        let summary = dests.map { d -> String in
            "ID=\(d.id.uuidString.prefix(8))… MountPoint=\(d.mountPoint?.path ?? "nil")"
        }.joined(separator: " | ")
        TMEjectLog.tmutil.debug("destinationinfo -X → [\(summary.isEmpty ? "no destinations" : summary)]")
        return dests
    }

    func latestBackup() async throws -> URL? {
        // `tmutil latestbackup` writes the path to stdout on success.
        // When no destination is reachable it exits non-zero with a backupd error string;
        // we surface that distinctly from a generic launch failure so the caller can decide
        // whether to treat "no snapshot yet" as success-vs-cancellation later.
        do {
            let result = try await run(args: ["latestbackup"])
            let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            TMEjectLog.tmutil.debug("latestbackup → \(path.isEmpty ? "<empty>" : path)")
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        } catch TMUtilError.nonZeroExit(let code, let stderr) {
            TMEjectLog.tmutil.debug("latestbackup → exit \(code) stderr=\(Self.truncate(stderr))")
            throw TMUtilError.latestBackupUnavailable(stderr: stderr)
        }
    }

    func stopBackup() async throws {
        TMEjectLog.tmutil.debug("stopbackup → invoking")
        _ = try await run(args: ["stopbackup"])
        TMEjectLog.tmutil.debug("stopbackup → ok")
    }

    /// Truncate to 2KB max for log output — keeps the log readable when tmutil prints a
    /// multi-line backupd error blob.
    private static func truncate(_ s: String, max: Int = 2048) -> String {
        s.count <= max ? s : s.prefix(max) + "…[+\(s.count - max)B]"
    }

    func latestBackupRaw() async -> TMUtilRawResult {
        // Doesn't throw — caller (FDA prober) needs to look at stderr text to distinguish
        // "FDA missing" (exit 80 + "Full Disk Access" stderr) from "no destination mounted"
        // (exit non-zero + backupd error) from "no snapshots yet" (exit 0, empty stdout).
        do {
            let result = try await run(args: ["latestbackup"])
            return TMUtilRawResult(
                stdout: result.stdoutString,
                stderr: result.stderrString,
                exitCode: 0
            )
        } catch TMUtilError.nonZeroExit(let code, let stderr) {
            return TMUtilRawResult(stdout: "", stderr: stderr, exitCode: code)
        } catch {
            return TMUtilRawResult(stdout: "", stderr: "\(error)", exitCode: -1)
        }
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

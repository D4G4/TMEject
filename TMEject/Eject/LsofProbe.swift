import Foundation

struct LsofHolder: Equatable, Sendable {
    let command: String      // e.g. "mds_stores"
    let pid: Int             // e.g. 412

    var humanSummary: String { "\(command) (pid \(pid))" }
}

protocol LsofProbe: Sendable {
    func holdersOf(volumePath: String) async -> [LsofHolder]
}

struct LiveLsofProbe: LsofProbe {
    private let lsofPath: String

    init(lsofPath: String = "/usr/sbin/lsof") {
        self.lsofPath = lsofPath
    }

    func holdersOf(volumePath: String) async -> [LsofHolder] {
        // `lsof +f -- /Volumes/<name>` lists every open file under that mount point.
        // Default human-readable output gives us COMMAND and PID in the first two columns;
        // that's all we need for the "Last error" surface.
        let output: String
        do {
            output = try await runLsof(volumePath: volumePath)
        } catch {
            TMEjectLog.eject.error("lsof failed for \(volumePath): \(error)")
            return []
        }
        return parse(lsofOutput: output)
    }

    func parse(lsofOutput: String) -> [LsofHolder] {
        var seen = Set<String>()
        var holders: [LsofHolder] = []
        let lines = lsofOutput.split(separator: "\n", omittingEmptySubsequences: true)
        for (idx, line) in lines.enumerated() {
            if idx == 0 { continue }                              // header: COMMAND PID USER FD TYPE …
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2 else { continue }
            let cmd = String(cols[0])
            guard let pid = Int(cols[1]) else { continue }
            let key = "\(cmd)-\(pid)"
            if seen.insert(key).inserted {
                holders.append(LsofHolder(command: cmd, pid: pid))
            }
        }
        return holders
    }

    private func runLsof(volumePath: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: lsofPath)
            proc.arguments = ["+f", "--", volumePath]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = Pipe()
            proc.terminationHandler = { _ in
                let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

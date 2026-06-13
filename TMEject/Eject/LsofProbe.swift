import Foundation

struct LsofHolder: Equatable, Sendable {
    let command: String      // e.g. "mds_stores", "Google Chrome Helper"
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
        // `lsof -Fpcn <mountpoint>` — when the path argument is a mount point, lsof matches
        // by fsid and returns every process holding ANY file on that filesystem, INCLUDING
        // files in subdirectories. The previous `lsof +f -- <path>` only matched the literal
        // path (a Time Machine drive's real holders — mds_stores, backupd — sit on files inside
        // /Volumes/Backup/Backups.backupdb/… and were silently invisible).
        // `-Fpcn` emits field-mode output (`p<pid>\nc<command>\nn<path>`) which parses
        // unambiguously even when the command name contains spaces (e.g. "Google Chrome Helper").
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
        var holders: [LsofHolder] = []
        var seen = Set<String>()
        var currentPid: Int?
        var currentCommand: String?

        func flushIfReady() {
            if let pid = currentPid, let cmd = currentCommand {
                let key = "\(cmd)-\(pid)"
                if seen.insert(key).inserted {
                    holders.append(LsofHolder(command: cmd, pid: pid))
                }
            }
        }

        for line in lsofOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p":
                // A new record starts here; emit the previous one if it was ready.
                flushIfReady()
                currentPid = Int(value)
                currentCommand = nil
            case "c":
                currentCommand = value
            default:
                // f (descriptor), n (name), t (type), a (access mode), etc. — ignored.
                break
            }
        }
        flushIfReady()
        return holders
    }

    private func runLsof(volumePath: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: lsofPath)
            proc.arguments = ["-Fpcn", volumePath]
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

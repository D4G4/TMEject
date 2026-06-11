import Foundation
import os

enum TMEjectLog {
    static let app      = TMEjectLogger("App")
    static let state    = TMEjectLogger("State")
    static let observer = TMEjectLogger("Observer")
    static let tmutil   = TMEjectLogger("TMUtil")
    static let eject    = TMEjectLogger("Eject")
    static let ui       = TMEjectLogger("UI")

    private static let lock = NSLock()
    private static let maxEntries = 2000
    nonisolated(unsafe) private static var _entries: [String] = []
    nonisolated(unsafe) private static var fileHandle: FileHandle?

    static var entries: [String] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    private static let sessionStart = Date()

    private static let logsDir: URL? = {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = appSupport
            .appendingPathComponent("TMEject", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h-mm-ss-a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func currentFileHandle() -> FileHandle? {
        if let handle = fileHandle { return handle }
        guard let dir = logsDir else { return nil }

        let dayDir = dir.appendingPathComponent(dayFormatter.string(from: sessionStart), isDirectory: true)
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let fileURL = dayDir.appendingPathComponent("session-\(timeFormatter.string(from: sessionStart)).log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return nil }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let header = "TMEject v\(version) (\(build)) | macOS \(ProcessInfo.processInfo.operatingSystemVersionString) | \(ISO8601DateFormatter().string(from: sessionStart))\n\n"
        handle.write(Data(header.utf8))

        fileHandle = handle
        return handle
    }

    static func append(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        _entries.append(entry)
        if _entries.count > maxEntries {
            _entries.removeFirst(_entries.count - maxEntries)
        }
        if let handle = currentFileHandle() {
            handle.write(Data((entry + "\n").utf8))
        }
    }

    static func export() -> String {
        lock.lock(); defer { lock.unlock() }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let header = """
        TMEject Log Export
        ==================
        Exported: \(ISO8601DateFormatter().string(from: Date()))
        Entries: \(_entries.count)
        Version: \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)

        """
        return header + _entries.joined(separator: "\n")
    }

    static func pruneOldLogs(olderThan days: Int = 7) {
        guard let dir = logsDir else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            if let folderDate = dayFormatter.date(from: item.lastPathComponent), folderDate < cutoff {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    static var logDirectoryURL: URL? { logsDir }

    static var currentSessionDayDirectoryURL: URL? {
        logsDir?.appendingPathComponent(dayFormatter.string(from: sessionStart), isDirectory: true)
    }
}

struct TMEjectLogger {
    private let logger: Logger
    private let category: String

    init(_ category: String) {
        self.logger = Logger(subsystem: "co.dls.tmeject", category: category)
        self.category = category
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        TMEjectLog.append("[\(Self.timestamp())] [INFO] [\(category)] \(message)")
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        TMEjectLog.append("[\(Self.timestamp())] [DEBUG] [\(category)] \(message)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        TMEjectLog.append("[\(Self.timestamp())] [ERROR] [\(category)] \(message)")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss.SSS a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}

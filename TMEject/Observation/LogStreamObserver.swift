import Foundation

/// Wake-latency optimization. Streams `log stream --predicate '(processImagePath CONTAINS
/// "backupd") OR (subsystem == "com.apple.TimeMachine")' --info --style=ndjson` and fires
/// `onWake` (debounced 1s) when an event arrives.
///
/// Replaces the DNC wake-optimization plan: `NSDistributedNotificationCenter.addObserver(
/// forName: nil, ...)` is a privileged operation since macOS 10.15 Catalina and silently
/// fails for non-root processes. Prior art (gettes/TimeMachineMonitor,
/// BrianHenryIE/UnmountVolumeAfterTimeMachine) uses log-stream too.
///
/// Per locked architecture decision #1, polling `tmutil status -X` remains PRIMARY. This
/// observer only nudges the poller to run sooner than its scheduled 30s/5s cadence — it
/// never drives state transitions on its own.
actor LogStreamObserver {

    /// Set `TMEJECT_LOG_DISCOVERY=1` in the env to log every parsed event at `notice`
    /// level (visible in the session log) — used during the Step 13 discovery backup to
    /// capture eventMessage strings for `KnownLogEvents.swift`.
    static var discoveryModeEnabled: Bool {
        ProcessInfo.processInfo.environment["TMEJECT_LOG_DISCOVERY"] == "1"
    }

    private let onWake: @Sendable () async -> Void
    private let clock: MonotonicClock
    private var process: Process?
    private var lineBuffer: Data = Data()
    private var lastWakeAt: TimeInterval = -.greatestFiniteMagnitude
    private static let wakeDebounceSeconds: TimeInterval = 1.0

    init(onWake: @escaping @Sendable () async -> Void,
         clock: MonotonicClock = SystemClock()) {
        self.onWake = onWake
        self.clock = clock
    }

    func start() {
        guard process == nil else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream",
            "--predicate",
            "(processImagePath CONTAINS \"backupd\") OR (subsystem == \"com.apple.TimeMachine\")",
            "--info",
            "--style", "ndjson"
        ]

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()

        // FileHandle's readabilityHandler runs on a background queue, so we hop back into
        // the actor to mutate state.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            Task { [weak self] in
                await self?.ingest(chunk)
            }
        }

        do {
            try proc.run()
            process = proc
            TMEjectLog.observer.info("LogStreamObserver started (discoveryMode=\(Self.discoveryModeEnabled))")
        } catch {
            TMEjectLog.observer.error("LogStreamObserver failed to start: \(error)")
        }
    }

    func stop() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        lineBuffer.removeAll()
    }

    // MARK: - Ingest pipeline

    private func ingest(_ chunk: Data) async {
        lineBuffer.append(chunk)
        // ndjson: one JSON object per line. Split on \n, hold any trailing partial line.
        while let newlineIdx = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newlineIdx)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIdx)
            guard !lineData.isEmpty else { continue }
            await processLine(lineData)
        }
    }

    private func processLine(_ data: Data) async {
        // `log stream` emits a "Filtering the log data..." preamble + occasional empty lines;
        // skip anything that isn't a JSON object.
        guard data.first == UInt8(ascii: "{") else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let summary = LogEventSummary(rawDict: obj)

        if Self.discoveryModeEnabled {
            TMEjectLog.observer.info(
                "log-event ts=\(summary.timestamp ?? "?") subsystem=\(summary.subsystem ?? "?") "
                    + "category=\(summary.category ?? "?") process=\(summary.processName ?? "?") "
                    + "msg=\(summary.eventMessage ?? "?")"
            )
        }

        await maybeFireWake()
    }

    private func maybeFireWake() async {
        let now = clock.now()
        guard now - lastWakeAt >= Self.wakeDebounceSeconds else { return }
        lastWakeAt = now
        await onWake()
    }
}

/// Convenience accessors over the `log stream --style=ndjson` event dictionary. We type
/// the fields we care about; everything else stays in `rawDict` for the discovery dump.
struct LogEventSummary {
    let rawDict: [String: Any]

    var timestamp: String?   { rawDict["timestamp"]    as? String }
    var subsystem: String?   { rawDict["subsystem"]    as? String }
    var category: String?    { rawDict["category"]     as? String }
    var processName: String? { rawDict["processImagePath"] as? String }
    var eventMessage: String? { rawDict["eventMessage"] as? String }
}

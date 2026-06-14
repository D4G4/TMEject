import Foundation

/// Substring matchers for backupd / TimeMachine `eventMessage` strings worth waking the
/// poller for. Verified on **macOS 26.3.1 (Tahoe)** on 2026-06-14 by triggering
/// `tmutil startbackup --block` with `TMEJECT_LOG_DISCOVERY=1` and grepping every
/// `subsystem == "com.apple.TimeMachine"` event.
///
/// These are wake-latency optimizations, NOT state drivers — per locked architecture
/// decision #1, `tmutil status -X` polling remains primary. The matchers cut the worst-case
/// detection latency from 30s (idle poll interval) to ~1s (the wake debounce window).
///
/// **Re-verification**: when a new major macOS ships, re-run the discovery procedure in
/// `docs/log-stream-discovery.md` and update this file with any changed messages.
enum KnownLogEvents {

    /// Last empirical verification date (yyyy-MM-dd) and macOS version.
    static let verifiedOn = "2026-06-14"
    static let verifiedMacOS = "26.3.1 (Tahoe)"

    /// Returns true iff this event is one TMEject should react to by waking the poller.
    /// Filters out the dominant XPC connection-setup noise (~99% of subsystem events).
    static func isWakeWorthy(_ summary: LogEventSummary) -> Bool {
        guard summary.subsystem == "com.apple.TimeMachine" else { return false }
        guard let msg = summary.eventMessage else { return false }
        // Drop subsystem noise that fires constantly but tells us nothing about backup state.
        if msg.contains("connection invalid") { return false }
        if msg.contains("TRY_ERROR_BLOCK") { return false }
        if msg.contains("Limiting logging for limit") { return false }
        return wakeMessages.contains(where: msg.contains)
    }

    /// Substring matchers — order doesn't matter, each is checked independently.
    ///
    /// **Start signals** (fire when a backup begins; let us poll within 1s instead of
    /// up to 30s):
    /// - `Backup requested to last destination` — `category=BackupDispatching`, fires at
    ///   the moment `tmutil startbackup` or the scheduler invokes backupd
    /// - `Attempting backup with mode` — `category=BackupJob`, fires immediately after
    ///   BackupDispatching, includes the trigger mode ("manual backup" vs scheduled)
    /// - `Mounting destination` — `category=MountedDestinationManager`, fires when backupd
    ///   mounts the destination volume for the backup session
    ///
    /// **Progress signal** (broader filter for the in-progress phases):
    /// - `Found a destination disk mounted at` — `category=BackupDestination`, fires once
    ///   per backup at setup
    ///
    /// **Completion signals** (let us see success/completion within 1s instead of waiting
    /// for the next confirming-phase poll):
    /// - `Completing backup` — `category=BackupEngine`, fires when the copy phase finishes
    ///   and backupd begins finalizing
    /// - `Successfully completed backing up` — `category=BackupEngine`, fires when the
    ///   new snapshot path is committed; includes the snapshot URL in the message body
    private static let wakeMessages: [String] = [
        // Start
        "Backup requested to last destination",
        "Attempting backup with mode",
        "Mounting destination",
        // Mid-flight
        "Found a destination disk mounted at",
        // Completion
        "Completing backup",
        "Successfully completed backing up",
    ]
}

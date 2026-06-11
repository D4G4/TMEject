import Foundation

/// Polls `tmutil status -X` and feeds derived events into the state machine.
/// Primary observation signal per locked architecture decision #1 — DNC/FSEvents are
/// wake-optimizations layered on top in Step 13.
actor PollingObserver {
    enum Tunables {
        static let idlePollInterval: TimeInterval = 30
        static let activePollInterval: TimeInterval = 5
        static let stallTimeout: TimeInterval = 10 * 60      // 10 min totalBytes unchanged → stall
        static let confirmingHardCap: TimeInterval = 4 * 60 * 60   // 4h
    }

    private let tmutil: TMUtilClient
    private let clock: MonotonicClock
    private let emit: @Sendable (AppEvent) async -> Void
    private var task: Task<Void, Never>?

    // Initial state implies "TM is idle, never seen running." On the first real poll a
    // mid-running backup correctly emits backupBegan (or confirmingEntered if it's already
    // past Copying) so TMEject reacts to backups that started before it launched.
    private var lastRunning: Bool = false
    private var lastPhaseKind: BackupPhaseKind = .preCopy
    private var lastTotalBytes: Int64?
    private var totalBytesUnchangedSince: TimeInterval?
    private var confirmingStartedAt: TimeInterval?
    private var supplyingActiveCadence: Bool = false

    init(tmutil: TMUtilClient, clock: MonotonicClock = SystemClock(),
         emit: @escaping @Sendable (AppEvent) async -> Void) {
        self.tmutil = tmutil
        self.clock = clock
        self.emit = emit
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func pokeNow() async {
        // External wake nudges call this so the next poll runs immediately instead of waiting
        // out the idle 30s.
        await runOnce()
    }

    private func loop() async {
        while !Task.isCancelled {
            await runOnce()
            let interval = supplyingActiveCadence ? Tunables.activePollInterval : Tunables.idlePollInterval
            do {
                try await clock.sleep(seconds: interval)
            } catch {
                return
            }
        }
    }

    /// One poll tick. Visible to tests via `pokeNow()`.
    func runOnce() async {
        let status: StatusPlist
        do {
            status = try await tmutil.status()
        } catch {
            TMEjectLog.observer.error("tmutil status failed: \(error)")
            return
        }

        let phase = BackupPhaseKind.classify(status.backupPhase)
        let now = clock.now()

        // Cadence flips with running OR confirming.
        supplyingActiveCadence = status.running || phase.isConfirming

        let prevRunning = lastRunning

        // Transition: idle → running, non-confirming.
        if !prevRunning && status.running && !phase.isConfirming {
            lastTotalBytes = status.rawTotalBytes
            totalBytesUnchangedSince = now
            await emit(.backupBegan)
        }

        // Transition: enter confirming.
        if !lastPhaseKind.isConfirming && phase.isConfirming {
            confirmingStartedAt = now
            let snap = await captureLatestBackup()
            await emit(.confirmingEntered(latestBackupPath: snap))
        }

        // Transition: exit confirming.
        // We treat "no longer in a confirming phase" as the exit signal — that covers
        // (a) phase moves away from confirming while Running is still true (rare), and
        // (b) Running flips false directly out of confirming. Both call for the same
        // snapshot-advance check.
        if lastPhaseKind.isConfirming && !phase.isConfirming {
            confirmingStartedAt = nil
            let snap = await captureLatestBackup()
            await emit(.confirmingExited(newLatestBackupPath: snap))
        }

        // Transition: running → stopped, NOT in confirming.
        // confirming case is handled by the exit branch above (which fires before this).
        if prevRunning && !status.running && !lastPhaseKind.isConfirming && !phase.isConfirming {
            await emit(.backupStopped)
            totalBytesUnchangedSince = nil
        }

        // Stall detection (during backingUp): totalBytes unchanged for stallTimeout.
        if status.running && !phase.isConfirming {
            if status.rawTotalBytes != lastTotalBytes {
                lastTotalBytes = status.rawTotalBytes
                totalBytesUnchangedSince = now
            } else if let since = totalBytesUnchangedSince,
                      now - since >= Tunables.stallTimeout {
                TMEjectLog.observer.error("Stall detected: _raw_totalBytes unchanged for \(Int(now - since))s")
                await emit(.stallDetected)
                totalBytesUnchangedSince = nil
            }
        } else {
            totalBytesUnchangedSince = nil
        }

        // Confirming hard cap.
        if phase.isConfirming, let started = confirmingStartedAt, now - started >= Tunables.confirmingHardCap {
            TMEjectLog.observer.error("Confirming phase exceeded \(Int(Tunables.confirmingHardCap))s — emitting timeout")
            confirmingStartedAt = nil
            await emit(.confirmingTimedOut)
        }

        lastRunning = status.running
        lastPhaseKind = phase
    }

    private func captureLatestBackup() async -> URL? {
        do {
            return try await tmutil.latestBackup()
        } catch {
            TMEjectLog.observer.error("latestbackup failed: \(error)")
            return nil
        }
    }
}

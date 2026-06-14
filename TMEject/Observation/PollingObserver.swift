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
    /// Bonus channel — every poll's StatusPlist (whether or not it triggered a state-machine
    /// event). Used by the coordinator for UI-only updates (backupPct, drivePresent revalidation).
    /// The state machine is fed by `emit` only; this channel must never drive transitions.
    private let onStatus: @Sendable (StatusPlist) async -> Void
    private var task: Task<Void, Never>?

    // Initial state implies "TM is idle, never seen running." A mid-running backup at launch
    // therefore correctly emits backupBegan (or confirmingEntered) on the first poll.
    private var lastRunning: Bool = false
    private var lastPhaseKind: BackupPhaseKind = .preCopy

    // Stall + confirming-cap tracking — activated by the coordinator in response to the state
    // machine's startStallTimer/stopStallTimer/startConfirmingTimer/stopConfirmingTimer commands
    // (M5). When inactive the observer skips the corresponding evaluation entirely.
    private var stallActive: Bool = false
    private var stallLastTotalBytes: Int64?
    private var stallUnchangedSince: TimeInterval?

    private var confirmingActive: Bool = false
    private var confirmingStartedAt: TimeInterval?

    init(tmutil: TMUtilClient, clock: MonotonicClock = SystemClock(),
         emit: @escaping @Sendable (AppEvent) async -> Void,
         onStatus: @escaping @Sendable (StatusPlist) async -> Void = { _ in }) {
        self.tmutil = tmutil
        self.clock = clock
        self.emit = emit
        self.onStatus = onStatus
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
        await runOnce()
    }

    // MARK: - Timer commands (M5: observer consumes state machine commands)

    func setStallTracking(active: Bool) {
        stallActive = active
        stallLastTotalBytes = nil
        stallUnchangedSince = nil
    }

    func setConfirmingTracking(active: Bool) {
        confirmingActive = active
        confirmingStartedAt = active ? clock.now() : nil
    }

    private func loop() async {
        while !Task.isCancelled {
            await runOnce()
            let active = lastRunning || lastPhaseKind.isConfirming
            let interval = active ? Tunables.activePollInterval : Tunables.idlePollInterval
            do {
                try await clock.sleep(seconds: interval)
            } catch {
                return
            }
        }
    }

    func runOnce() async {
        let status: StatusPlist
        do {
            status = try await tmutil.status()
        } catch {
            TMEjectLog.observer.error("tmutil status failed: \(error)")
            return
        }
        await onStatus(status)

        let phase = BackupPhaseKind.classify(status.backupPhase)
        let now = clock.now()
        let prevRunning = lastRunning
        let prevPhaseKind = lastPhaseKind

        // Transition: idle → running, non-confirming.
        if !prevRunning && status.running && !phase.isConfirming {
            await emit(.backupBegan)
        }

        // Transition: enter confirming.
        if !prevPhaseKind.isConfirming && phase.isConfirming {
            let (path, failed) = await captureLatestBackup()
            await emit(.confirmingEntered(latestBackupPath: path, entryProbeFailed: failed))
        }

        // Transition: exit confirming. Covers (a) phase moves away while Running stays true,
        // (b) Running flips false directly out of confirming.
        if prevPhaseKind.isConfirming && !phase.isConfirming {
            let (path, failed) = await captureLatestBackup()
            await emit(.confirmingExited(newLatestBackupPath: path, exitProbeFailed: failed))
        }

        // Transition: running → stopped, NOT in confirming.
        if prevRunning && !status.running && !prevPhaseKind.isConfirming && !phase.isConfirming {
            await emit(.backupStopped)
        }

        // Stall detection (only when active).
        if stallActive {
            if status.rawTotalBytes != stallLastTotalBytes {
                stallLastTotalBytes = status.rawTotalBytes
                stallUnchangedSince = now
            } else if let since = stallUnchangedSince,
                      now - since >= Tunables.stallTimeout {
                TMEjectLog.observer.error("Stall detected: _raw_totalBytes unchanged for \(Int(now - since))s")
                await emit(.stallDetected)
                stallUnchangedSince = nil
            }
        }

        // Confirming hard cap (only when active).
        if confirmingActive, let started = confirmingStartedAt,
           now - started >= Tunables.confirmingHardCap {
            TMEjectLog.observer.error("Confirming phase exceeded \(Int(Tunables.confirmingHardCap))s — emitting timeout")
            confirmingStartedAt = nil
            await emit(.confirmingTimedOut)
        }

        lastRunning = status.running
        lastPhaseKind = phase
    }

    private func captureLatestBackup() async -> (path: URL?, failed: Bool) {
        do {
            let path = try await tmutil.latestBackup()
            return (path, false)
        } catch {
            TMEjectLog.observer.error("latestbackup failed: \(error) — propagating probe-failed flag")
            return (nil, true)
        }
    }
}

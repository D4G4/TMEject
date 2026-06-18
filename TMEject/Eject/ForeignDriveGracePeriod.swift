import Foundation

/// Per-drive 10-second cancellable countdown before ejecting a foreign Time Machine
/// drive. Spec:
///
/// - On a foreign-TM-drive detection, `startGrace(for:)` schedules an eject in 10s.
/// - The popover/toast Cancel button calls `cancel(volumeURL:)` to abort.
/// - Multiple drives can be in flight simultaneously — keyed by `volumeURL`.
/// - If the same drive disconnects then re-mounts mid-grace, the second mount fires a
///   new grace (no per-UUID memory of cancels) per locked decision #4. The
///   `DiskAppearedObserver` calls `cancel(volumeURL:)` on unmount to drop the in-flight
///   timer for a yanked drive before scheduling a new one when it re-appears.
///
/// All side effects happen via the injected `onExpire` callback so the actor stays
/// free of UI/coordinator dependencies.
actor ForeignDriveGracePeriod {

    static let graceDurationSeconds: TimeInterval = 10

    enum CancelReason: String, Sendable, Equatable {
        /// User clicked the Cancel button on the toast/popover.
        case user
        /// Drive was unmounted before the grace expired (e.g. yanked manually).
        case unmount
        /// Settings were toggled off mid-grace.
        case settingOff
    }

    enum ExpireOutcome: Sendable, Equatable {
        /// Grace expired naturally → caller should eject.
        case expired
        /// Grace was cancelled before expiry — caller does nothing.
        case cancelled(CancelReason)
    }

    private let clock: MonotonicClock
    private let onExpire: @Sendable (ForeignTMDriveCandidate) async -> Void
    /// Per-volume bookkeeping. The `Task` is the timer; `cancellation` is set when
    /// `cancel()` aborts it so the task can decide "expired vs cancelled" on wake.
    private var inFlight: [URL: Pending] = [:]

    private struct Pending {
        let candidate: ForeignTMDriveCandidate
        let startedAt: TimeInterval
        let task: Task<Void, Never>
        var cancelReason: CancelReason?
    }

    init(
        clock: MonotonicClock = SystemClock(),
        onExpire: @escaping @Sendable (ForeignTMDriveCandidate) async -> Void
    ) {
        self.clock = clock
        self.onExpire = onExpire
    }

    /// Number of pending grace timers — exposed for the popover/diagnostics and tests.
    var inFlightCount: Int { inFlight.count }

    /// Snapshot of pending candidates (useful for surfaces that want to render
    /// "2 foreign drives ejecting in Ns").
    var pendingCandidates: [ForeignTMDriveCandidate] {
        inFlight.values.map(\.candidate)
    }

    /// Start a grace window for `candidate`. If one is already in flight for the
    /// same `volumeURL`, this is a no-op (the existing timer keeps running) — that
    /// way a duplicate DA appeared callback (which DA does emit at registration
    /// time) doesn't reset the clock under the user's feet.
    func startGrace(for candidate: ForeignTMDriveCandidate) {
        if inFlight[candidate.volumeURL] != nil {
            TMEjectLog.eject.debug(
                "ForeignDriveGracePeriod: startGrace ignored — already pending for \(candidate.volumeURL.path)"
            )
            return
        }
        let started = clock.now()
        let myClock = clock
        let onExpire = onExpire
        TMEjectLog.eject.info(
            "ForeignDriveGracePeriod: starting 10s grace for \(candidate.volumeName) "
                + "(\(candidate.bsdName) @ \(candidate.volumeURL.path))"
        )
        let url = candidate.volumeURL
        let task = Task { [weak self] in
            do {
                try await myClock.sleep(seconds: Self.graceDurationSeconds)
            } catch {
                return
            }
            guard let self else { return }
            await self.fireExpiry(url: url, onExpire: onExpire)
        }
        inFlight[candidate.volumeURL] = Pending(
            candidate: candidate, startedAt: started, task: task, cancelReason: nil
        )
    }

    /// Cancel a pending grace window. No-op if there's no in-flight entry. The
    /// expiration task picks up `cancelReason` and skips the eject.
    func cancel(volumeURL: URL, reason: CancelReason) {
        guard var pending = inFlight[volumeURL] else { return }
        pending.cancelReason = reason
        inFlight[volumeURL] = pending
        pending.task.cancel()
        // Drop immediately — the task body's early-return covers the race where the
        // timer was already firing.
        inFlight.removeValue(forKey: volumeURL)
        TMEjectLog.eject.info(
            "ForeignDriveGracePeriod: cancelled grace for \(pending.candidate.volumeName) "
                + "(\(pending.candidate.bsdName)) reason=\(reason.rawValue)"
        )
    }

    /// Cancel every in-flight grace (used when the setting is toggled off mid-flight).
    func cancelAll(reason: CancelReason) {
        let urls = Array(inFlight.keys)
        for url in urls { cancel(volumeURL: url, reason: reason) }
    }

    // MARK: - Internal

    private func fireExpiry(
        url: URL,
        onExpire: @escaping @Sendable (ForeignTMDriveCandidate) async -> Void
    ) async {
        // Removed already → cancelled before fire; do nothing.
        guard let pending = inFlight.removeValue(forKey: url) else { return }
        let elapsed = clock.now() - pending.startedAt
        TMEjectLog.eject.info(
            "ForeignDriveGracePeriod: grace expired for \(pending.candidate.volumeName) "
                + "after \(String(format: "%.1f", elapsed))s — firing eject"
        )
        await onExpire(pending.candidate)
    }
}

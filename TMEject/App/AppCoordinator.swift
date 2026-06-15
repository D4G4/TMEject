import Foundation
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var state: AppState = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var lastToast: ToastMessage?
    @Published private(set) var loginItemStatus: LoginItemStatus = .notRegistered
    @Published private(set) var fdaState: FDAState = .unknown
    @Published private(set) var backupPct: Double = 0
    @Published private(set) var ejectPct: Double = 0
    @Published private(set) var ejectAttempt: Int = 0
    @Published private(set) var drivePresent: Bool = false
    @Published private(set) var driveName: String?
    @Published private(set) var lastBackupCompletedAt: Date?
    /// Popover overlay state for the Eject & Lock ritual confirmation. nil → no overlay.
    /// 0…100 — the inner ring fills as the confirmation runs out.
    @Published var ritualConfirmPct: Double?

    struct ToastMessage: Equatable, Identifiable {
        let level: AppCommand.ToastLevel
        let text: String
        let subtitle: String?
        let kind: ToastKind
        let actionLabel: String?
        let id: UUID = UUID()

        init(level: AppCommand.ToastLevel,
             text: String,
             subtitle: String? = nil,
             kind: ToastKind? = nil,
             actionLabel: String? = nil) {
            self.level = level
            self.text = text
            self.subtitle = subtitle
            self.kind = kind ?? ToastKind.fromLevel(level)
            self.actionLabel = actionLabel
        }
    }

    /// Extends ToastLevel with the design-pass kinds (busy, neutral) that don't map onto a
    /// state-machine ToastLevel.
    enum ToastKind: Sendable, Equatable {
        case ok, err, busy, neutral

        static func fromLevel(_ level: AppCommand.ToastLevel) -> ToastKind {
            switch level {
            case .info:    return .neutral
            case .success: return .ok
            case .warning: return .err     // soft fold — warnings render in the err palette
            case .error:   return .err
            }
        }
    }

    private var machine = StateMachine()
    private let tmutil: TMUtilClient
    private let ejector: Ejector
    private let resolver: DestinationResolver
    private let defaults: UserDefaults
    private let locker: ScreenLocker
    private let confirmDialog: ConfirmDialog
    private let clock: MonotonicClock
    private let notifier: SystemNotifier
    private let toastPresenter: ToastPresenter?
    private let loginItem: LoginItemManaging
    private let fdaProber: FullDiskAccessProbing
    private var lastFDAProbeAt: TimeInterval = -.greatestFiniteMagnitude
    private var fdaProbeInFlight: Task<Void, Never>?
    private var lastFDANotificationAt: TimeInterval = -.greatestFiniteMagnitude
    private static let fdaProbeDebounceSeconds: TimeInterval = 5
    private static let fdaNotificationRateLimitSeconds: TimeInterval = 60 * 60 * 24    // once per 24h
    private var observer: PollingObserver?
    private var lastResolvedDestination: ResolvedDestination?

    // Toast suppression default — Step 10's Advanced tab UI flips this.
    private static let toastsEnabledKey = "co.dls.tmeject.toastsEnabled"

    // M3 (Step 12.7+13 renamed): UserDefaults key for the snapshot path captured at
    // backupBegan. Was preConfirmLatestBackupPath when the capture point was confirming-entry;
    // the Tahoe snapshot-delta race fix moves capture to backupBegan and renames accordingly.
    private static let preBackupPathKey = "co.dls.tmeject.preBackupLatestBackupPath"

    init(
        tmutil: TMUtilClient = LiveTMUtilClient(),
        ejector: Ejector = Ejector(),
        resolver: DestinationResolver = DestinationResolver(),
        defaults: UserDefaults = .standard,
        locker: ScreenLocker = LiveScreenLocker(),
        confirmDialog: ConfirmDialog = LiveConfirmDialog(),
        clock: MonotonicClock = SystemClock(),
        notifier: SystemNotifier = LiveSystemNotifier(),
        toastPresenter: ToastPresenter? = nil,
        loginItem: LoginItemManaging = LiveLoginItemManager(),
        fdaProber: FullDiskAccessProbing? = nil
    ) {
        self.tmutil = tmutil
        self.ejector = ejector
        self.resolver = resolver
        self.defaults = defaults
        self.locker = locker
        self.confirmDialog = confirmDialog
        self.clock = clock
        self.notifier = notifier
        self.toastPresenter = toastPresenter
        self.loginItem = loginItem
        self.fdaProber = fdaProber ?? LiveFullDiskAccessProber(tmutil: tmutil)

        if defaults.object(forKey: Self.toastsEnabledKey) == nil {
            defaults.set(true, forKey: Self.toastsEnabledKey)
        }
        // Per the design pass (Step 12.7): auto-eject defaults ON. The hourly-backup-trap
        // warning lives in the Settings cooldown copy + docs/architecture.md.
        if defaults.object(forKey: SettingsKey.autoEjectEnabled) == nil {
            defaults.set(true, forKey: SettingsKey.autoEjectEnabled)
        }
        self.loginItemStatus = loginItem.currentStatus()
        defaults.set(self.loginItemStatus == .enabled, forKey: SettingsKey.launchAtLogin)
    }

    // MARK: - Full Disk Access

    /// Re-probe the FDA permission. Debounced to once per 5s by default — use `force: true`
    /// to bypass (used at launch + on explicit user action like "Check again" in onboarding).
    /// Callable from any thread; coroutine work is wrapped in a Task on this MainActor.
    func refreshFDAState(force: Bool = false) {
        let now = clock.now()
        if !force && (now - lastFDAProbeAt) < Self.fdaProbeDebounceSeconds {
            return
        }
        if let inflight = fdaProbeInFlight, !inflight.isCancelled { return }
        lastFDAProbeAt = now
        fdaProbeInFlight = Task { [weak self] in
            guard let self else { return }
            let newState = await self.fdaProber.currentState()
            await MainActor.run {
                let prior = self.fdaState
                self.fdaState = newState
                if prior != newState {
                    TMEjectLog.app.info("FDA: \(prior) → \(newState)")
                }
                self.evaluateAutoEjectGate(reason: "fdaState=\(newState)")
                self.fdaProbeInFlight = nil
            }
        }
    }

    /// Whether the auto-eject path can actually function right now. Auto-eject ON +
    /// FDA granted = green. Auto-eject ON + FDA denied = stuck (snapshot-path delta success
    /// detection can't run, so the state machine will safely refuse success → never ejects).
    var isAutoEjectFunctional: Bool {
        guard defaults.bool(forKey: SettingsKey.autoEjectEnabled) else { return true }
        return fdaState == .granted
    }

    /// Called from the Settings toggle and from onboarding when the user opts in.
    /// Does NOT fight the user's intent — the toggle is stored regardless of FDA. Surfaces
    /// the dependency via lastError + a rate-limited notification.
    func setAutoEjectEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: SettingsKey.autoEjectEnabled)
        UIActionLogger.settingChanged("autoEjectEnabled", value: "\(enabled)")
        if enabled {
            Task { _ = await self.requestNotificationAuthIfNeeded() }
            refreshFDAState(force: true)
        }
        evaluateAutoEjectGate(reason: "toggle=\(enabled)")
    }

    /// Reconciles lastError + the one-time FDA-required system notification when the gate
    /// state changes. Idempotent — safe to call multiple times.
    private func evaluateAutoEjectGate(reason: String) {
        let autoEjectOn = defaults.bool(forKey: SettingsKey.autoEjectEnabled)
        if autoEjectOn && fdaState == .denied {
            lastError = "Auto-eject pending — Full Disk Access required"
            maybeSendFDANotification()
        } else if !autoEjectOn, lastError == "Auto-eject pending — Full Disk Access required" {
            // User flipped auto-eject OFF — clear the surface.
            lastError = nil
        }
        TMEjectLog.app.debug("evaluateAutoEjectGate (\(reason)) autoEjectOn=\(autoEjectOn) fdaState=\(fdaState)")
    }

    private func maybeSendFDANotification() {
        // Gate on onboarding completion (Step 12.7 High #4): on a fresh install, init seeds
        // autoEjectEnabled=true and start()'s force-probe puts us in the denied branch before
        // the AppDelegate has shown the launch HUD. Firing the system notification at that
        // moment surfaces it ON TOP of the HUD — confusing first-run UX. The FDA pill in
        // popover / Settings / Onboarding still surfaces the state; we just defer the
        // notification until the user finishes the initial flow.
        guard defaults.bool(forKey: SettingsKey.hasCompletedOnboarding) else {
            TMEjectLog.app.debug("Skipping FDA notification — onboarding not complete")
            return
        }
        let now = clock.now()
        if (now - lastFDANotificationAt) < Self.fdaNotificationRateLimitSeconds { return }
        lastFDANotificationAt = now
        Task {
            await notifier.deliver(
                title: "TMEject needs Full Disk Access",
                body: "Auto-eject can't detect backup completion without it. Open System Settings → Privacy & Security → Full Disk Access.",
                category: .generic
            )
        }
    }

    /// Returns a human-readable explanation of why the cooldown blocks auto-eject right now,
    /// or `nil` if it doesn't (cooldown=0, can't derive next-backup time, or window cleared).
    ///
    /// Inputs:
    /// - `SettingsKey.cooldownMinutes` — user-configured cooldown window in minutes
    /// - `lastBackupCompletedAt` — best-effort "previous backup ended at" timestamp
    ///
    /// Tahoe's hourly TM schedule means the NEXT backup fires ~60 min after the last one.
    /// If the cooldown window covers that next backup, eject would just force a reconnect.
    /// When we can't derive a baseline (first run, nil lastBackupCompletedAt), we DON'T
    /// block — the user explicitly opted in to auto-eject and missing data should fail open.
    func cooldownBlocksEject() -> String? {
        let cooldown = defaults.integer(forKey: SettingsKey.cooldownMinutes)
        guard cooldown > 0 else { return nil }
        guard let last = lastBackupCompletedAt else { return nil }
        let elapsed = Date().timeIntervalSince(last) / 60.0
        // Tahoe's stock TM schedule is hourly. Approximate "next backup time" as
        // last + 60min; if cooldown straddles that, the eject would just force a manual
        // reconnect before the next backup. Skip with a friendly toast.
        let nextBackupInMin = max(0, 60.0 - elapsed)
        if nextBackupInMin < Double(cooldown) {
            return "~\(Int(nextBackupInMin.rounded()))m"
        }
        return nil
    }

    /// Called from the Popover's @AppStorage `.onChange` so a toggle flip in the popover
    /// still drives the coordinator's side-effects (FDA probe + rate-limited notification).
    /// The popover's `@AppStorage` is the source of truth for the bool itself.
    func respondToAutoEjectChange(_ enabled: Bool) {
        UIActionLogger.settingChanged("autoEjectEnabled", value: "\(enabled)")
        if enabled {
            Task { _ = await self.requestNotificationAuthIfNeeded() }
            refreshFDAState(force: true)
        }
        evaluateAutoEjectGate(reason: "popoverToggle=\(enabled)")
    }

    /// Polled at popover/window appearances. Cheap (single SMAppService.status read).
    /// Keeps the @AppStorage mirror in sync with reality — if the user toggled the OS pane
    /// directly, we'll observe it here.
    func refreshLoginItemStatus() {
        let now = loginItem.currentStatus()
        loginItemStatus = now
        defaults.set(now == .enabled, forKey: SettingsKey.launchAtLogin)
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try loginItem.register()
        } else {
            try loginItem.unregister()
        }
        UIActionLogger.settingChanged("launchAtLogin", value: "\(enabled)")
        refreshLoginItemStatus()
    }

    var toastsEnabled: Bool { defaults.bool(forKey: Self.toastsEnabledKey) }

    func start() {
        guard observer == nil else { return }
        TMEjectLog.app.info("AppCoordinator.start")

        Task { await self.restoreFromRelaunchIfNeeded() }
        refreshFDAState(force: true)
        refreshDrivePresence()

        let observer = PollingObserver(
            tmutil: tmutil,
            emit: { [weak self] event in
                await self?.deliver(event)
            },
            onStatus: { [weak self] status in
                await self?.handleStatusSnapshot(status)
            }
        )
        self.observer = observer
        Task { await observer.start() }
    }

    /// Drive-presence is what gates the popover's primary CTA, so we refresh on the same
    /// hooks as login-item + FDA: popover .onAppear, prefs .onAppear, app didBecomeActive.
    func refreshDrivePresence() {
        Task { @MainActor in
            // destinationInfo doesn't need FDA, so this works even before the user grants it.
            let infos = (try? await tmutil.destinationInfo()) ?? []
            guard let dest = infos.first(where: { $0.lastDestination }) ?? infos.first else {
                drivePresent = false
                driveName = nil
                return
            }
            driveName = dest.name
            drivePresent = (resolver.resolve(mountPoint: dest.mountPoint) != nil)
        }
    }

    /// Bonus channel from PollingObserver that doesn't go through the state machine.
    /// Used to update UI-only state: backupPct, drivePresent (cheap revalidation).
    ///
    /// `status.percent` is already normalized to 0…100 by `StatusPlist.normalizePercent`
    /// (see StatusPlist.swift). No further scaling here. When the daemon hasn't reported a
    /// percent yet but we know we're running, we keep the last-known value rather than
    /// snapping to 0 — avoids a brief 78 → 0 → 78 flicker between polls.
    private func handleStatusSnapshot(_ status: StatusPlist) {
        if let pct = status.percent {
            backupPct = pct
        } else if !status.running {
            backupPct = 0
        }
    }

    func stop() async {
        await observer?.stop()
        observer = nil
    }

    func requestPokeNow() {
        guard let observer else { return }
        Task { await observer.pokeNow() }
    }

    func requestManualEject(lock: Bool) {
        UIActionLogger.menuItemSelected(lock ? "Eject & Lock" : "Eject now")
        Task { await deliver(.ejectRequested(lock: lock, source: .manual)) }
    }

    /// "Eject & Lock" path. Differs from `requestManualEject(lock: true)`:
    /// - in `backingUp` / `confirming`: prompts via ConfirmDialog, then stops the backup,
    ///   waits for tmutil to settle, and only then drives the eject.
    /// - in `ejecting`: ignored (menu item is disabled — defense in depth).
    /// - otherwise: equivalent to requestManualEject(lock: true).
    func requestEjectAndLock() {
        UIActionLogger.logAction("Request: Eject & Lock", context: "state=\(state)")
        Task { await self.runEjectAndLock() }
    }

    private var ritualTask: Task<Void, Never>?
    private static let ritualDurationSeconds: TimeInterval = 1.8

    /// Click "Eject & Lock" in the new popover → start the 1.8s ritual confirmation overlay.
    /// During the countdown the user can press Cancel. At t=1.8s the overlay dismisses and
    /// the existing `requestEjectAndLock` flow runs.
    func startEjectAndLockRitual() {
        guard ritualTask == nil else { return }
        UIActionLogger.logAction("Ritual confirm start", context: "state=\(state)")
        ritualConfirmPct = 0
        let start = clock.now()
        let theClock = clock
        ritualTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let elapsed = theClock.now() - start
                if elapsed >= Self.ritualDurationSeconds { break }
                self.ritualConfirmPct = min(100, max(0, elapsed / Self.ritualDurationSeconds * 100))
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            if Task.isCancelled { return }
            self.ritualConfirmPct = nil
            self.ritualTask = nil
            self.requestEjectAndLock()
        }
    }

    func cancelEjectAndLockRitual() {
        UIActionLogger.logAction("Ritual confirm cancelled")
        ritualTask?.cancel()
        ritualTask = nil
        ritualConfirmPct = nil
    }

    var isManualEjectAllowed: Bool {
        StateMachine.isManualEjectAllowed(in: state)
    }

    /// Eject & Lock is enabled in every state except `.ejecting` per spec. The stop-backup
    /// confirmation prompt handles backingUp/confirming.
    var isEjectAndLockAllowed: Bool {
        state != .ejecting
    }

    // MARK: - M3 relaunch restore

    /// Step 13 fixup — migrate the pre-rename key. Existing installs persisted in-flight
    /// state under `co.dls.tmeject.preConfirmLatestBackupPath`; the Tahoe baseline fix
    /// moved capture to backupBegan and renamed to `preBackupLatestBackupPath`. Copy any
    /// stale value forward once, then delete the legacy key. Idempotent — subsequent runs
    /// see the legacy key already gone.
    private static let legacyPreConfirmPathKey = "co.dls.tmeject.preConfirmLatestBackupPath"

    private func migrateLegacyPersistedBaseline() {
        guard let legacy = defaults.string(forKey: Self.legacyPreConfirmPathKey) else { return }
        if defaults.string(forKey: Self.preBackupPathKey) == nil {
            defaults.set(legacy, forKey: Self.preBackupPathKey)
            TMEjectLog.app.info("Migrated preConfirmLatestBackupPath → preBackupLatestBackupPath: \(legacy)")
        }
        defaults.removeObject(forKey: Self.legacyPreConfirmPathKey)
    }

    private func restoreFromRelaunchIfNeeded() async {
        migrateLegacyPersistedBaseline()
        guard let savedPath = defaults.string(forKey: Self.preBackupPathKey) else { return }
        let status: StatusPlist
        do {
            status = try await tmutil.status()
        } catch {
            TMEjectLog.app.error("Could not poll tmutil at restore: \(error) — clearing stale preBackup path")
            defaults.removeObject(forKey: Self.preBackupPathKey)
            return
        }
        let phase = BackupPhaseKind.classify(status.backupPhase)
        guard status.running else {
            // Backup ended while we were down; nothing useful to restore. The next idle poll
            // will emit nothing, and the next backupBegan will capture a fresh baseline.
            defaults.removeObject(forKey: Self.preBackupPathKey)
            return
        }
        let restoredURL = URL(fileURLWithPath: savedPath)
        // Restore the matching state. Confirming → .confirming + start cap timer. Anything
        // else (copying, preCopy) → .backingUp + start stall timer.
        let target: AppState = phase.isConfirming ? .confirming : .backingUp
        machine.restoreInFlightFromRelaunch(
            intoState: target,
            baselineLatestBackupPath: restoredURL,
            baselineProbeFailed: false
        )
        state = machine.state
        TMEjectLog.app.info("Restored \(target) state from previous run; baseline=\(savedPath)")
        if target == .confirming {
            await observer?.setConfirmingTracking(active: true)
        } else {
            await observer?.setStallTracking(active: true)
        }
    }

    // MARK: - Event delivery

    // Test seam for EjectAndLockTests; drives the state machine without the observer chain.
    func deliverFromTest(_ event: AppEvent) async {
        await deliver(event)
    }

    /// Test seam — drives the PollingObserver's bonus `onStatus` channel without spinning up
    /// the observer task itself. Used by tests that assert `backupPct` flow on the same
    /// `StatusPlist` shape the live observer would hand us.
    func deliverStatusSnapshotFromTest(_ status: StatusPlist) {
        handleStatusSnapshot(status)
    }

    #if DEBUG
    /// Snapshot-test seam — set every UI-bound property at once for reproducible renders.
    /// Marked DEBUG-only so the setters can't leak into a shipping build.
    func applySnapshotState(
        state: AppState? = nil,
        backupPct: Double? = nil,
        ejectPct: Double? = nil,
        ejectAttempt: Int? = nil,
        drivePresent: Bool? = nil,
        driveName: String? = nil,
        lastError: String? = nil,
        ritualConfirmPct: Double? = nil,
        loginItemStatus: LoginItemStatus? = nil,
        fdaState: FDAState? = nil
    ) {
        if let state            { self.state = state }
        if let backupPct        { self.backupPct = backupPct }
        if let ejectPct         { self.ejectPct = ejectPct }
        if let ejectAttempt     { self.ejectAttempt = ejectAttempt }
        if let drivePresent     { self.drivePresent = drivePresent }
        if let driveName        { self.driveName = driveName }
        if let lastError        { self.lastError = lastError }
        if let ritualConfirmPct { self.ritualConfirmPct = ritualConfirmPct }
        if let loginItemStatus  { self.loginItemStatus = loginItemStatus }
        if let fdaState         { self.fdaState = fdaState }
    }
    #endif

    private func deliver(_ event: AppEvent) async {
        TMEjectLog.state.debug("Event: \(event)")
        let prior = machine.state
        let outcome = machine.handle(event)
        switch outcome {
        case .ignored(let reason):
            TMEjectLog.state.debug("Ignored: \(reason)")
        case .accepted(let commands):
            if prior != machine.state {
                TMEjectLog.state.info("State: \(prior) → \(machine.state)")
            }
            state = machine.state
            for command in commands {
                await run(command)
            }
        }
    }

    private func run(_ command: AppCommand) async {
        switch command {
        case .requestPoll:
            await observer?.pokeNow()
        case .recordPreBackupLatestBackup(let path):
            if let path {
                defaults.set(path.path, forKey: Self.preBackupPathKey)
            } else {
                // Persist a sentinel so a relaunch can still see "we entered confirming with
                // no snapshot baseline" vs "no confirming state at all". We use an empty
                // string for that. The restore code path treats an empty string the same as
                // a missing key (no restore) — current behaviour is conservative; revisit if
                // a real distinction is needed.
                defaults.removeObject(forKey: Self.preBackupPathKey)
            }
        case .clearPreBackupLatestBackup:
            defaults.removeObject(forKey: Self.preBackupPathKey)
        case .beginEject(let lock):
            await runEject(lock: lock)
        case .signalBackupCompleted:
            // Track when the backup completed for the cooldown calc below.
            lastBackupCompletedAt = Date()
            let autoEjectOn = defaults.bool(forKey: SettingsKey.autoEjectEnabled)
            if !autoEjectOn {
                TMEjectLog.eject.info("signalBackupCompleted — auto-eject is OFF, leaving drive mounted")
                break
            }
            if !isAutoEjectFunctional {
                // FDA pill / notification already surfaces this; just log and bail.
                TMEjectLog.eject.info("signalBackupCompleted — auto-eject ON but blocked (fdaState=\(fdaState))")
                break
            }
            if let cooldown = cooldownBlocksEject() {
                TMEjectLog.eject.info("signalBackupCompleted — cooldown blocks eject (\(cooldown))")
                lastToast = ToastMessage(
                    level: .info,
                    text: "Backup complete",
                    subtitle: "Skipping eject — next backup due in \(cooldown)",
                    kind: .ok
                )
                if toastsEnabled {
                    toastPresenter?.present(level: .info,
                                            message: "Backup complete",
                                            subtitle: "Skipping eject — next backup due in \(cooldown)",
                                            kind: .ok,
                                            actionLabel: nil)
                }
                break
            }
            TMEjectLog.eject.info("signalBackupCompleted — firing auto-eject")
            await deliver(.ejectRequested(lock: false, source: .auto))
        case .showToast(let level, let message):
            let enriched = enrichToast(level: level, message: message)
            lastToast = enriched
            TMEjectLog.ui.info("Toast [\(level.rawValue)]: \(enriched.text)")
            if toastsEnabled {
                toastPresenter?.present(level: level, message: enriched.text,
                                         subtitle: enriched.subtitle,
                                         kind: enriched.kind,
                                         actionLabel: enriched.actionLabel)
            }
        case .notify(let title, let body):
            TMEjectLog.ui.info("Notify: \(title) — \(body)")
            await notifier.deliver(title: title, body: body, category: categorize(title: title))
        case .setLastError(let err):
            lastError = err
            if let err { TMEjectLog.state.info("LastError: \(err)") }
            else { TMEjectLog.state.info("LastError cleared") }
        case .startStallTimer:
            await observer?.setStallTracking(active: true)
        case .stopStallTimer:
            await observer?.setStallTracking(active: false)
        case .startConfirmingTimer:
            await observer?.setConfirmingTracking(active: true)
        case .stopConfirmingTimer:
            await observer?.setConfirmingTracking(active: false)
        case .showQuitDuringEjectWarning:
            TMEjectLog.ui.info("(placeholder) Quit-during-eject warning")
        }
    }

    /// Called by Ejector after each unmount attempt. Surfaces holder + retry countdown in
    /// `lastError` mid-9-min retry window. Also updates the UI-only `ejectPct` /
    /// `ejectAttempt` published values for the menu bar ring + popover. State machine does
    /// NOT see this; state stays `.ejecting` until the final report.
    private func handleEjectProgress(_ attempt: EjectAttempt) {
        ejectAttempt = attempt.attemptNumber
        // Linear approximation — attempts done / total. The user sees motion that matches
        // perceived progress, even though the real underlying signal is discrete.
        ejectPct = Double(attempt.attemptNumber) / Double(attempt.totalAttempts) * 100
        switch attempt.result {
        case .success, .other:
            // Final success / non-retryable failure — the EjectReport drives the eventual
            // `.ejectAttemptCompleted` event, which calls setLastError with the final value.
            // Nothing to update here.
            return
        case .busy(let message):
            let holderSummary = attempt.holders.isEmpty
                ? "no holders found by lsof — \(message)"
                : "held by \(attempt.holders.map(\.humanSummary).joined(separator: ", "))"
            let countdown: String
            if let next = attempt.nextRetryDelay {
                countdown = " · retrying in \(Int(next))s"
            } else {
                countdown = " · no more retries"
            }
            lastError = "Busy attempt \(attempt.attemptNumber)/\(attempt.totalAttempts): \(holderSummary)\(countdown)"
        }
    }

    /// Public entry point for AppDelegate / hot paths that need to drive the state machine
    /// outside the observer loop (Step 12.5 fix for applicationWillTerminate not delivering
    /// `.appWillTerminate`).
    func dispatch(_ event: AppEvent) async {
        await deliver(event)
    }

    /// Maps the state-machine's lean `.showToast(level, message)` to the design-pass-rich
    /// (title, subtitle, kind, action) shape. Subtitle / kind / action are derived from the
    /// current coordinator state — keeps the state machine free of UI concerns.
    private func enrichToast(level: AppCommand.ToastLevel, message: String) -> ToastMessage {
        let autoOn = defaults.bool(forKey: SettingsKey.autoEjectEnabled)
        let drive  = driveName ?? "Backup Drive"
        switch message {
        case "Backup started":
            return ToastMessage(
                level: level,
                text: "Backing up…",
                subtitle: autoOn ? "TMEject will eject when it's done"
                                 : "Time Machine is writing to \(drive)",
                kind: .busy
            )
        case "Backup complete":
            return ToastMessage(
                level: level,
                text: "Backup complete",
                subtitle: autoOn ? "Ejecting \(drive)…"
                                 : "\(drive) is safe to keep connected",
                kind: .ok
            )
        case "Drive ejected":
            return ToastMessage(
                level: level,
                text: "\(drive) ejected",
                subtitle: "Safe to unplug",
                kind: .ok
            )
        case let m where m.hasPrefix("Eject failed"):
            return ToastMessage(
                level: level,
                text: "Eject failed",
                subtitle: lastError,
                kind: .err,
                actionLabel: "Retry"
            )
        case "Backup stopped",
             "Backup ended without a new snapshot":
            return ToastMessage(
                level: level,
                text: "Backup didn't complete",
                subtitle: "TMEject will not eject",
                kind: .err
            )
        default:
            return ToastMessage(level: level, text: message)
        }
    }

    private func categorize(title: String) -> NotificationCategory {
        // Title-based dispatch keeps the state machine free of UNUserNotificationCenter
        // category strings.
        if title.contains("Eject failed") { return .ejectFailurePersistent }
        if title.contains("Backup") && title.contains("complete") { return .generic }
        if title.contains("Backup") { return .backupFailure }
        return .generic
    }

    /// Called by Settings (Step 10) or onboarding (Step 11) when the user opts in to auto-eject.
    /// Returns whether system notifications are available — caller can fall back to the in-app
    /// toast + lastError surface when false.
    func requestNotificationAuthIfNeeded() async -> Bool {
        await notifier.requestAuthorizationIfNeeded()
    }

    /// Resolves the current Time Machine destination via DiskArbitration and reports what an
    /// eject would target — without actually unmounting. Used by the Advanced tab's "Test
    /// eject (dry run)" button to verify the destination wiring + DA permissions.
    func dryRunEject() async -> String {
        do {
            let destinations = try await tmutil.destinationInfo()
            guard let destination = destinations.first(where: { $0.lastDestination }) ?? destinations.first else {
                return "No Time Machine destination configured."
            }
            guard let resolved = resolver.resolve(mountPoint: destination.mountPoint) else {
                return "Destination \(destination.name) (UUID \(destination.id.uuidString)) is not currently mounted (tmutil MountPoint=\(destination.mountPoint?.path ?? "nil"))."
            }
            return "Would eject \(resolved.volumeName ?? resolved.bsdName) at \(resolved.volumeURL.path) (BSD \(resolved.bsdName))."
        } catch {
            return "tmutil destinationinfo failed: \(error)"
        }
    }

    private func runEject(lock: Bool) async {
        let destinations: [DestinationInfo]
        do {
            destinations = try await tmutil.destinationInfo()
        } catch {
            TMEjectLog.eject.error("destinationInfo failed: \(error)")
            await deliver(.ejectAttemptCompleted(success: false,
                                                  errorSummary: "Could not list TM destinations: \(error)"))
            return
        }
        guard let destination = destinations.first(where: { $0.lastDestination }) ?? destinations.first else {
            await deliver(.ejectAttemptCompleted(success: false,
                                                  errorSummary: "No Time Machine destination configured"))
            return
        }
        guard let resolved = resolver.resolve(mountPoint: destination.mountPoint) else {
            let mp = destination.mountPoint?.path ?? "<nil>"
            await deliver(.ejectAttemptCompleted(success: false,
                                                  errorSummary: "Destination \(destination.name) not mounted (tmutil MountPoint=\(mp))"))
            return
        }
        lastResolvedDestination = resolved
        TMEjectLog.eject.info("Ejecting \(resolved.volumeName ?? resolved.bsdName) at \(resolved.volumeURL.path)")
        let report = await ejector.eject(volumeURL: resolved.volumeURL,
                                          onAttempt: { [weak self] attempt in
            await self?.handleEjectProgress(attempt)
        })
        if lock && report.succeeded {
            let lockResult = await locker.lockScreen()
            switch lockResult {
            case .success:
                TMEjectLog.eject.info("Screen locked after eject")
            case .failure(let err):
                TMEjectLog.eject.error("Lock-after-eject failed: \(err)")
                // Eject still succeeded; surface the lock failure as lastError but report
                // the eject success so the state machine doesn't transition to idleEjectFailed.
                lastError = "Eject succeeded but lock failed: \(err)"
            }
        }
        await deliver(.ejectAttemptCompleted(success: report.succeeded, errorSummary: report.lastError))
    }

    // MARK: - Eject & Lock flow

    /// Wait up to `cap` for `tmutil status -X` to report `Running=false`. When it settles,
    /// eagerly drive the state machine to `.idle` matching the prior state — the observer's
    /// next poll might be up to 5s out and the user is mid-flow.
    /// Returns true if it settled, false on timeout.
    private func waitForBackupToStop(priorState: AppState, cap: TimeInterval) async -> Bool {
        let start = clock.now()
        while clock.now() - start < cap {
            do {
                let status = try await tmutil.status()
                if !status.running {
                    switch priorState {
                    case .confirming:
                        // Cancelled — no new-snapshot success; mark as exit-probe-failed so the
                        // state machine refuses to claim success on the way out.
                        await deliver(.confirmingExited(newLatestBackupPath: nil, exitProbeFailed: true))
                    case .backingUp:
                        await deliver(.backupStopped)
                    default:
                        break
                    }
                    return true
                }
            } catch {
                TMEjectLog.eject.error("waitForBackupToStop tmutil status failed: \(error)")
                return false
            }
            try? await clock.sleep(seconds: 1)
        }
        return false
    }

    private func runEjectAndLock() async {
        switch state {
        case .ejecting:
            return
        case .idle, .idleEjectFailed:
            await deliver(.ejectRequested(lock: true, source: .manual))
        case .backingUp, .confirming:
            // Pause the observer-driven event stream of the in-flight backup by asking the user
            // first. If they confirm we stop the backup, wait for tmutil to settle, then drive
            // the eject. State machine transitions normally: backingUp/confirming → idle on
            // backupStopped/confirmingExited → ejecting on ejectRequested.
            let yes = await confirmDialog.confirmStopAndEject()
            guard yes else {
                UIActionLogger.logAction("Eject & Lock: cancelled at confirmation")
                return
            }
            UIActionLogger.logAction("Eject & Lock: stopping backup")
            let priorState = state
            do {
                try await tmutil.stopBackup()
            } catch {
                lastError = "tmutil stopbackup failed: \(error)"
                TMEjectLog.eject.error("tmutil stopbackup failed: \(error)")
                return
            }
            let settled = await waitForBackupToStop(priorState: priorState, cap: 30)
            if !settled {
                lastError = "Timed out waiting for backup to stop (30s)"
                TMEjectLog.eject.error("Backup did not settle within 30s after stopbackup")
                return
            }
            // The observer should have driven the state machine through backupStopped /
            // confirmingExited by now. If we somehow still aren't in an eject-eligible state,
            // refuse rather than fight the guard table.
            guard StateMachine.isManualEjectAllowed(in: state) else {
                lastError = "After stopbackup state is \(state) — not eject-eligible"
                TMEjectLog.eject.error("Post-stopbackup state \(state) is not eject-eligible")
                return
            }
            await deliver(.ejectRequested(lock: true, source: .manual))
        }
    }
}

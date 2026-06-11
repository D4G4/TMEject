import Foundation
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var state: AppState = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var lastToast: ToastMessage?

    struct ToastMessage: Equatable {
        let level: AppCommand.ToastLevel
        let text: String
        let id: UUID = UUID()
    }

    private var machine = StateMachine()
    private let tmutil: TMUtilClient
    private let ejector: Ejector
    private let resolver: DestinationResolver
    private let defaults: UserDefaults
    private var observer: PollingObserver?
    private var lastResolvedDestination: ResolvedDestination?

    // M3: UserDefaults key for the snapshot path captured at confirming-entry.
    private static let preConfirmPathKey = "co.dls.tmeject.preConfirmLatestBackupPath"

    init(
        tmutil: TMUtilClient = LiveTMUtilClient(),
        ejector: Ejector = Ejector(),
        resolver: DestinationResolver = DestinationResolver(),
        defaults: UserDefaults = .standard
    ) {
        self.tmutil = tmutil
        self.ejector = ejector
        self.resolver = resolver
        self.defaults = defaults
    }

    func start() {
        guard observer == nil else { return }
        TMEjectLog.app.info("AppCoordinator.start")

        // M3: restore confirming state from prior run if TM is still mid-confirming.
        Task { await self.restoreFromRelaunchIfNeeded() }

        let observer = PollingObserver(tmutil: tmutil, emit: { [weak self] event in
            await self?.deliver(event)
        })
        self.observer = observer
        Task { await observer.start() }
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

    var isManualEjectAllowed: Bool {
        StateMachine.isManualEjectAllowed(in: state)
    }

    // MARK: - M3 relaunch restore

    private func restoreFromRelaunchIfNeeded() async {
        guard let savedPath = defaults.string(forKey: Self.preConfirmPathKey) else { return }
        let status: StatusPlist
        do {
            status = try await tmutil.status()
        } catch {
            TMEjectLog.app.error("Could not poll tmutil at restore: \(error) — clearing stale preConfirm path")
            defaults.removeObject(forKey: Self.preConfirmPathKey)
            return
        }
        let phase = BackupPhaseKind.classify(status.backupPhase)
        if status.running, phase.isConfirming {
            let restoredURL = URL(fileURLWithPath: savedPath)
            machine.restoreConfirmingFromRelaunch(latestBackupPath: restoredURL, entryProbeFailed: false)
            state = machine.state
            TMEjectLog.app.info("Restored confirming state from previous run; baseline=\(savedPath)")
            // Activate the confirming-cap timer immediately. The polling observer will see
            // phase-still-confirming and won't re-emit confirmingEntered (state == .confirming
            // → that event is ignored by the guard table).
            await observer?.setConfirmingTracking(active: true)
        } else {
            defaults.removeObject(forKey: Self.preConfirmPathKey)
        }
    }

    // MARK: - Event delivery

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
        case .recordPreConfirmLatestBackup(let path):
            if let path {
                defaults.set(path.path, forKey: Self.preConfirmPathKey)
            } else {
                // Persist a sentinel so a relaunch can still see "we entered confirming with
                // no snapshot baseline" vs "no confirming state at all". We use an empty
                // string for that. The restore code path treats an empty string the same as
                // a missing key (no restore) — current behaviour is conservative; revisit if
                // a real distinction is needed.
                defaults.removeObject(forKey: Self.preConfirmPathKey)
            }
        case .clearPreConfirmLatestBackup:
            defaults.removeObject(forKey: Self.preConfirmPathKey)
        case .beginEject(let lock):
            await runEject(lock: lock)
        case .signalBackupCompleted:
            // Step 6 stub: auto-eject is OFF by default (decision #7). Real cooldown + setting
            // plumbing lands in Step 10/11; for now we just log.
            TMEjectLog.eject.info("signalBackupCompleted received — auto-eject OFF until Step 10/11")
        case .showToast(let level, let message):
            lastToast = ToastMessage(level: level, text: message)
            TMEjectLog.ui.info("Toast [\(level.rawValue)]: \(message)")
        case .notify(let title, let body):
            TMEjectLog.ui.info("Notify: \(title) — \(body)")
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
        guard let resolved = resolver.resolve(destinationID: destination.id) else {
            await deliver(.ejectAttemptCompleted(success: false,
                                                  errorSummary: "Destination \(destination.name) not mounted"))
            return
        }
        lastResolvedDestination = resolved
        TMEjectLog.eject.info("Ejecting \(resolved.volumeName ?? resolved.bsdName) at \(resolved.volumeURL.path)")
        let report = await ejector.eject(volumeURL: resolved.volumeURL)
        if lock && report.succeeded {
            TMEjectLog.eject.info("(placeholder) Lock-after-eject not yet wired — will land in Step 8")
        }
        await deliver(.ejectAttemptCompleted(success: report.succeeded, errorSummary: report.lastError))
    }
}

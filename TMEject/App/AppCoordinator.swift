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
    private var observer: PollingObserver?

    init(tmutil: TMUtilClient = LiveTMUtilClient()) {
        self.tmutil = tmutil
    }

    func start() {
        guard observer == nil else { return }
        TMEjectLog.app.info("AppCoordinator.start")
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
        Task { await deliver(.manualEjectRequested(lock: lock)) }
    }

    var isManualEjectAllowed: Bool {
        StateMachine.isManualEjectAllowed(in: state)
    }

    // MARK: - Event delivery

    private func deliver(_ event: AppEvent) async {
        TMEjectLog.state.debug("Event: \(event)")
        let outcome = machine.handle(event)
        switch outcome {
        case .ignored(let reason):
            TMEjectLog.state.debug("Ignored: \(reason)")
        case .accepted(let commands):
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
        case .recordPreConfirmLatestBackup, .clearPreConfirmLatestBackup:
            // State machine manages the value; observer captures the comparison value
            // when emitting confirmingEntered/Exited. Nothing for the coordinator to do.
            break
        case .beginEject(let lock):
            await beginEjectPlaceholder(lock: lock)
        case .attemptAutoEjectIfAllowed:
            // Step 6 stub: log + simulate manual request only if auto-eject is enabled.
            // Real cooldown / setting plumbing lands in Step 10/11.
            TMEjectLog.eject.info("attemptAutoEjectIfAllowed (auto-eject is OFF by default in Step 6 — no-op)")
        case .showToast(let level, let message):
            lastToast = ToastMessage(level: level, text: message)
            TMEjectLog.ui.info("Toast [\(level.rawValue)]: \(message)")
        case .notify(let title, let body):
            TMEjectLog.ui.info("Notify: \(title) — \(body)")
        case .setLastError(let err):
            lastError = err
            if let err { TMEjectLog.state.info("LastError: \(err)") }
            else { TMEjectLog.state.info("LastError cleared") }
        case .startStallTimer, .stopStallTimer,
             .startConfirmingTimer, .stopConfirmingTimer:
            // Step 6: the PollingObserver enforces both timers internally via its tick;
            // these commands are advisory hooks for a later UI countdown.
            break
        case .showQuitDuringEjectWarning:
            TMEjectLog.ui.info("(placeholder) Quit-during-eject warning")
        }
    }

    private func beginEjectPlaceholder(lock: Bool) async {
        // Real ejector lands in Step 7. For Step 6 wiring we log and immediately complete
        // so the state machine returns to idle — letting an end-to-end smoke loop close.
        TMEjectLog.eject.info("(placeholder) beginEject lock=\(lock) — Step 7 will implement DADiskUnmount")
        await deliver(.ejectAttemptCompleted(success: false, errorSummary: "Step 7 not yet implemented"))
    }
}

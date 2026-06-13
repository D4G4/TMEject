import Foundation
@preconcurrency import DiskArbitration

enum DAUnmountResult: Equatable, Sendable {
    case success
    case busy(message: String)
    case other(code: Int32, message: String)
}

protocol UnmountBridge: Sendable {
    func unmountVolume(at url: URL) async -> DAUnmountResult
}

struct LiveUnmountBridge: UnmountBridge {
    private let session: DASession

    init() {
        guard let s = DASessionCreate(kCFAllocatorDefault) else {
            fatalError("DASessionCreate returned nil")
        }
        DASessionSetDispatchQueue(s, DispatchQueue.global(qos: .userInitiated))
        self.session = s
    }

    func unmountVolume(at url: URL) async -> DAUnmountResult {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            return .other(code: -1, message: "DADiskCreateFromVolumePath returned nil for \(url.path)")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<DAUnmountResult, Never>) in
            let box = UnmountCallbackBox(continuation: cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { _, dissenter, ctx in
                guard let ctx else { return }
                let box = Unmanaged<UnmountCallbackBox>.fromOpaque(ctx).takeRetainedValue()
                if let dissenter {
                    let code = DADissenterGetStatus(dissenter)
                    let cfMsg = DADissenterGetStatusString(dissenter) as String? ?? ""
                    if Int(code) == Int(kDAReturnBusy) {
                        box.continuation.resume(returning: .busy(message: cfMsg.isEmpty ? "kDAReturnBusy" : cfMsg))
                    } else {
                        box.continuation.resume(returning: .other(code: Int32(code), message: cfMsg))
                    }
                } else {
                    box.continuation.resume(returning: .success)
                }
            }, ctx)
        }
    }

    private final class UnmountCallbackBox {
        let continuation: CheckedContinuation<DAUnmountResult, Never>
        init(continuation: CheckedContinuation<DAUnmountResult, Never>) {
            self.continuation = continuation
        }
    }
}

struct EjectAttempt: Equatable, Sendable {
    let attemptNumber: Int          // 1-based
    let totalAttempts: Int
    let result: DAUnmountResult
    let holders: [LsofHolder]
    /// nil iff there are no more retries (success, non-busy error, or last attempt was busy).
    let nextRetryDelay: TimeInterval?
}

struct EjectReport: Sendable {
    let succeeded: Bool
    let attempts: [EjectAttempt]
    let lastError: String?

    var humanSummary: String {
        if succeeded { return "ejected" }
        if let last = lastError { return last }
        return "eject failed (unknown cause)"
    }
}

/// Locked Architecture Decision #6 — 8 attempts (1 immediate + 7 backoffs: 2, 5, 15, 30, 60, 120, 300s).
struct EjectorRetrySchedule: Sendable {
    let backoffsSeconds: [TimeInterval]

    static let `default` = EjectorRetrySchedule(backoffsSeconds: [0, 2, 5, 15, 30, 60, 120, 300])

    var totalAttempts: Int { backoffsSeconds.count }
}

actor Ejector {
    private let unmount: UnmountBridge
    private let lsof: LsofProbe
    private let clock: MonotonicClock
    private let schedule: EjectorRetrySchedule

    init(
        unmount: UnmountBridge = LiveUnmountBridge(),
        lsof: LsofProbe = LiveLsofProbe(),
        clock: MonotonicClock = SystemClock(),
        schedule: EjectorRetrySchedule = .default
    ) {
        self.unmount = unmount
        self.lsof = lsof
        self.clock = clock
        self.schedule = schedule
    }

    /// `onAttempt` fires after each unmount attempt with the result + (on busy) the holders
    /// list + the wait until the NEXT retry. Coordinator uses this to update `lastError`
    /// mid-retry so the menu surface doesn't go silent for the full ~9-min window.
    func eject(
        volumeURL: URL,
        onAttempt: (@Sendable (EjectAttempt) async -> Void)? = nil
    ) async -> EjectReport {
        var attempts: [EjectAttempt] = []
        for (idx, backoff) in schedule.backoffsSeconds.enumerated() {
            if backoff > 0 {
                TMEjectLog.eject.info("Retry \(idx + 1)/\(schedule.totalAttempts) in \(Int(backoff))s")
                do {
                    try await clock.sleep(seconds: backoff)
                } catch {
                    return EjectReport(succeeded: false, attempts: attempts,
                                       lastError: "cancelled mid-retry: \(error)")
                }
            }
            let result = await unmount.unmountVolume(at: volumeURL)
            switch result {
            case .success:
                let attempt = EjectAttempt(
                    attemptNumber: idx + 1, totalAttempts: schedule.totalAttempts,
                    result: result, holders: [], nextRetryDelay: nil
                )
                attempts.append(attempt)
                await onAttempt?(attempt)
                TMEjectLog.eject.info("Ejected \(volumeURL.path) on attempt \(idx + 1)")
                return EjectReport(succeeded: true, attempts: attempts, lastError: nil)
            case .busy(let message):
                let holders = await lsof.holdersOf(volumePath: volumeURL.path)
                let nextDelay: TimeInterval? = {
                    let nextIdx = idx + 1
                    return nextIdx < schedule.backoffsSeconds.count
                        ? schedule.backoffsSeconds[nextIdx]
                        : nil
                }()
                let attempt = EjectAttempt(
                    attemptNumber: idx + 1, totalAttempts: schedule.totalAttempts,
                    result: result, holders: holders, nextRetryDelay: nextDelay
                )
                attempts.append(attempt)
                await onAttempt?(attempt)
                let holderSummary = holders.isEmpty
                    ? "no holders found by lsof"
                    : holders.map(\.humanSummary).joined(separator: ", ")
                TMEjectLog.eject.error("Busy on attempt \(idx + 1)/\(schedule.totalAttempts): \(message); held by \(holderSummary)")
            case .other(let code, let message):
                let attempt = EjectAttempt(
                    attemptNumber: idx + 1, totalAttempts: schedule.totalAttempts,
                    result: result, holders: [], nextRetryDelay: nil
                )
                attempts.append(attempt)
                await onAttempt?(attempt)
                let summary = "DA error code \(code): \(message)"
                TMEjectLog.eject.error(summary)
                return EjectReport(succeeded: false, attempts: attempts, lastError: summary)
            }
        }
        let last = attempts.last
        let holderTail = last?.holders.map(\.humanSummary).joined(separator: ", ") ?? ""
        let summary: String
        if !holderTail.isEmpty {
            summary = "busy after \(schedule.totalAttempts) attempts — held by \(holderTail)"
        } else {
            summary = "busy after \(schedule.totalAttempts) attempts — no lsof holders identified"
        }
        return EjectReport(succeeded: false, attempts: attempts, lastError: summary)
    }
}

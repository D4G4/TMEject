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
            // DADiskUnmount is volume-only — preserves other partitions on the same physical
            // disk and surfaces DAReturn distinctly (busy vs IO error). NEVER swap this for
            // DADiskEject or NSWorkspace.unmountAndEjectDevice — they're whole-device and
            // swallow the busy code.
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
    let attemptIndex: Int       // 1-based
    let result: DAUnmountResult
    let holders: [LsofHolder]
    let waitedSecondsBefore: TimeInterval
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

/// 7-step retry schedule on kDAReturnBusy per locked architecture decision #6.
/// Backoff sleeps happen BEFORE each retry attempt — the first attempt is immediate.
struct EjectorRetrySchedule: Sendable {
    let backoffsSeconds: [TimeInterval]

    static let `default` = EjectorRetrySchedule(backoffsSeconds: [0, 2, 5, 15, 30, 60, 120, 300])
    // ↑ 8 entries → 8 attempts total. Spec says "7 attempts, ~9 min total." 7 RETRIES after
    // the first immediate attempt = 1 + 7 = 8 attempts. Sums: 2+5+15+30+60+120+300 = 532s ≈ 8.9min.
    // (The spec wording "7 attempts" lists 7 delays — interpreted as 7 RETRIES after the first
    // try.) Tests can pass a shortened schedule.

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

    func eject(volumeURL: URL) async -> EjectReport {
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
                attempts.append(EjectAttempt(attemptIndex: idx + 1, result: result,
                                             holders: [], waitedSecondsBefore: backoff))
                TMEjectLog.eject.info("Ejected \(volumeURL.path) on attempt \(idx + 1)")
                return EjectReport(succeeded: true, attempts: attempts, lastError: nil)
            case .busy(let message):
                let holders = await lsof.holdersOf(volumePath: volumeURL.path)
                attempts.append(EjectAttempt(attemptIndex: idx + 1, result: result,
                                             holders: holders, waitedSecondsBefore: backoff))
                let holderSummary = holders.isEmpty ? "no holders found by lsof"
                                                    : holders.map(\.humanSummary).joined(separator: ", ")
                TMEjectLog.eject.error("Busy on attempt \(idx + 1)/\(schedule.totalAttempts): \(message); held by \(holderSummary)")
            case .other(let code, let message):
                attempts.append(EjectAttempt(attemptIndex: idx + 1, result: result,
                                             holders: [], waitedSecondsBefore: backoff))
                // Non-busy DA errors are not retryable — IO error, no such media, etc.
                // Surface immediately rather than wasting the 9-min retry window.
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

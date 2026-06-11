import Foundation
@testable import TMEject

final class FakeLoginItemManager: LoginItemManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: LoginItemStatus = .notRegistered
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    var registerError: Error?
    var unregisterError: Error?

    func setStatus(_ s: LoginItemStatus) {
        lock.lock(); defer { lock.unlock() }
        _status = s
    }

    func currentStatus() -> LoginItemStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    func register() throws {
        lock.lock()
        registerCount += 1
        let err = registerError
        lock.unlock()
        if let err { throw err }
        setStatus(.enabled)
    }

    func unregister() throws {
        lock.lock()
        unregisterCount += 1
        let err = unregisterError
        lock.unlock()
        if let err { throw err }
        setStatus(.notRegistered)
    }
}

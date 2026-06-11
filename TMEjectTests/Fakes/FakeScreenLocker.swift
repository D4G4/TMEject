import Foundation
@testable import TMEject

actor FakeScreenLocker: ScreenLocker {
    private(set) var lockCount = 0
    var nextResult: Result<Void, ScreenLockError> = .success(())

    func setNext(_ result: Result<Void, ScreenLockError>) {
        nextResult = result
    }

    func lockScreen() async -> Result<Void, ScreenLockError> {
        lockCount += 1
        return nextResult
    }
}

actor FakeConfirmDialog: ConfirmDialog {
    private(set) var presentCount = 0
    var answer: Bool = true

    func setAnswer(_ answer: Bool) { self.answer = answer }

    func confirmStopAndEject() async -> Bool {
        presentCount += 1
        return answer
    }
}

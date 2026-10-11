import Foundation

/// 裏で走る仕事(待たずに投げる書き込みなど)の結果が見えるまで、少しずつ待つ。
///
/// **待ち合わせる口があるならそちらを使うこと**(`ViewerViewModel.settle()`、`FileBrowserOperations.settle()`、
/// `BookLoader.load(onPageListStored:)` など)。これは、結果を書く側が知らせる口を持たない(あるいは持たせると本体の形が
/// 歪む)ものだけに使う。時間で決め打ちに待たない ―― 条件が満たされた時点で抜ける。
nonisolated func eventually(
    timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// 一度だけ鳴る合図(`BookLoader.load(onPageListStored:)` などの閉包から受け取って、テストの本文で待つ)。
nonisolated final class OneShotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        lock.lock()
        fired = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    var hasFired: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }

    /// 鳴るまで待つ。`timeout` を過ぎたら false。
    func wait(timeout: Duration = .seconds(10)) async -> Bool {
        await eventually(timeout: timeout) { self.hasFired }
    }
}

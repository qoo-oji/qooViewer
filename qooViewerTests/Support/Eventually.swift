import Foundation

/// テストが「成り立つまで待つ」ときの締め切り(2026-10-25 の CI の監査。docs/02「テストの待ち方」)。
///
/// **締め切りは長く、1 か所で決める。** 通る回は成り立った時点で抜けるので、長くしても速さは変わらない。短い締め切り(1 秒・2 秒・
/// 5 秒がテストごとにばらばらだった)は、CI(3 vCPU の仮想マシンで、テストを 8 本ずつ並べて走らせる)で手元では起きない遅れに当たり、
/// 条件は正しいのに落ちた(2026-10-04 の自動リネーム: 製品は書き込みが落ち着くのを待ってから名前を変えるので、5 秒では足りない回が
/// あった)。締め切りが意味を持つのは「起きないことを待つ」ときだけで、それは sleep の理由の印で書く(scripts/ci/check-test-waits.sh)。
nonisolated enum TestPatience {
    /// 条件が成り立つまで待つ最長の時間。
    static let condition: Duration = .seconds(30)
}

/// 裏で走る仕事(待たずに投げる書き込みなど)の結果が見えるまで、少しずつ待つ。
///
/// **待ち合わせる口があるならそちらを使うこと**(`ViewerViewModel.settle()`、`FileBrowserOperations.settle()`、
/// `BookLoader.load(onPageListStored:)` など)。これは、結果を書く側が知らせる口を持たない(あるいは持たせると本体の形が
/// 歪む)ものだけに使う。時間で決め打ちに待たない ―― 条件が満たされた時点で抜ける。
nonisolated func eventually(
    timeout: Duration = TestPatience.condition, _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// 呼び出し側のアクターの上で条件を見る版(`eventually` と同じ。条件の閉包を Sendable にしなくてよい ―― メインアクターのテストの
/// 値も、手元の `var` もそのまま見られる)。成り立たなければ false。
nonisolated(nonsending) func eventuallyHere(timeout: Duration = TestPatience.condition, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
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
    func wait(timeout: Duration = TestPatience.condition) async -> Bool {
        await eventually(timeout: timeout) { self.hasFired }
    }
}

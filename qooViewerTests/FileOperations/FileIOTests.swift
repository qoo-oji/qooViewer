import Foundation
import Testing

@testable import qooViewer

/// ブロッキング I/O の窓口(Services/FileOperations/FileIO.swift)。
///
/// いちばん大事なのは枯渇のテスト ―― 協調スレッドプールをコア数ぶん塞いだ状態でも `perform` が走り出すこと。
/// これが崩れると、応答しない共有 1 つでアプリの async 処理が全部止まる(qooLibrary 実測)。
struct FileIOTests {
    /// **測定はすべてプールの外(Thread と semaphore)で行う。** プールを塞いでいる間は、テスト自身の
    /// await の継続も、`.timeLimit` の見張りも、同じテストホストで並行に走る他のテストも動けない ――
    /// async で書くと塞いだ瞬間にテストごと止まる(最初に書いた形がそうなった)。塞ぐのは測る間だけで、
    /// 放してから結果を受け取る。
    @Test("協調スレッドプールが塞がっていても 1 秒以内に走り出す")
    func submittedWorkStartsWhileTheCooperativePoolIsStarved() async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blockerCount = cores + 2
        for _ in 0..<blockerCount {
            Task.detached(priority: .userInitiated) {
                entered.signal()
                blockThisThread(until: release) // 協調プールのスレッドを同期で塞ぐ(ブロッキング I/O の代わり)
            }
        }
        let result: (blocked: Int, startedWithin: Duration?) = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                // プールの幅はコア数なので、塞がったのは高々その数。全部が入ったことを数えて確かめる。
                var blocked = 0
                while blocked < cores, entered.wait(timeout: .now() + (blocked == 0 ? 5 : 1)) == .success { blocked += 1 }
                let started = ContinuousClock.now
                let ran = DispatchSemaphore(value: 0)
                FileIO.submit { ran.signal() }
                let startedWithin: Duration? = ran.wait(timeout: .now() + 1) == .success ? ContinuousClock.now - started : nil
                for _ in 0..<blockerCount { release.signal() }
                continuation.resume(returning: (blocked, startedWithin))
            }
        }
        // 全部が入りきるとは限らない ―― テスト全体を並行に走らせると、他のテストが握っているスレッドのぶん
        // 入れない(実測: 10 コアで 9)。その場合もプールは埋まっている(残りを他のテストが使っている)ので、
        // 1 本も塞げなかったときだけ測定を無効とみなす。
        #expect(result.blocked > 0, "プールを塞げていないので、この測定は意味を持たない")
        #expect(result.startedWithin != nil, "プールが塞がっている間に走り出さなかった")
    }

    /// 本体は放すまで返らない(20 秒で自分から諦める)。期限の 200ms で戻ってくれば、本体がまだ走っている
    /// うちに戻ったことになる。
    ///
    /// 戻るまでの時間を 200ms 付近で見ないのは、**戻った継続は協調プールの上で走る**ため ―― テスト全体を
    /// 並行に走らせると、タイマーが 200ms で発火していても継続が走り出すまで 9 秒待たされた(実測)。
    /// 見たいのは「本体を待たずに戻る」ことなので、本体の終わりと比べる。
    @Test("期限を過ぎたら待つのをやめる(本体は止めない)", .timeLimit(.minutes(1)))
    func deadlineStopsWaiting() async throws {
        let release = DispatchSemaphore(value: 0)
        let finished = Cancellation()
        await #expect(throws: FileOperationError.self) {
            try await FileIO.withDeadline(.milliseconds(200)) {
                await FileIO.perform {
                    _ = release.wait(timeout: .now() + 20)
                    finished.request()
                }
            }
        }
        #expect(!finished.isRequested, "期限で戻った時点では本体はまだ走っている")
        release.signal()
    }

    @Test("期限より先に終われば結果が返る")
    func deadlineReturnsTheResultWhenFastEnough() async throws {
        let value = try await FileIO.withDeadline(.seconds(5)) { await FileIO.perform { 42 } }
        #expect(value == 42)
    }

    @Test("呼び出し元タスクの取り消しは、借りたスレッドの上で Cancellation として見える", .timeLimit(.minutes(1)))
    func taskCancellationIsVisibleOnTheBorrowedThread() async throws {
        let entered = DispatchSemaphore(value: 0)
        let task = Task {
            await FileIO.perform { () -> (sawTaskCancelled: Bool, sawFlag: Bool) in
                entered.signal()
                let deadline = Date().addingTimeInterval(10)
                while !Cancellation.isRequestedInCurrentScope, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                // 借りたスレッドには Task の文脈が無いので Task.isCancelled は常に false ―― だから旗が要る。
                return (Task.isCancelled, Cancellation.isRequestedInCurrentScope)
            }
        }
        await FileIO.perform { entered.wait() }
        task.cancel()
        let result = await task.value
        #expect(result.sawFlag)
        #expect(!result.sawTaskCancelled)
    }

    @Test("中止ボタンの旗も同じく見える")
    func externalCancellationIsVisible() async throws {
        let cancellation = Cancellation()
        cancellation.request()
        let seen = await FileIO.perform(cancellation: cancellation) { Cancellation.isRequestedInCurrentScope }
        #expect(seen)
        let unrelated = await FileIO.perform { Cancellation.isRequestedInCurrentScope }
        #expect(!unrelated)
    }

    @Test("メインスレッドの外で走る")
    @MainActor
    func performRunsOffTheMainThread() async {
        let onMain = await FileIO.perform { Thread.isMainThread }
        #expect(!onMain)
    }
}

/// 同期の関数に包むのは、async の文脈から semaphore の wait を直に呼ぶと警告になるため
/// (ここでは協調プールのスレッドを塞ぐことそのものが目的)。
private nonisolated func blockThisThread(until semaphore: DispatchSemaphore) {
    semaphore.wait()
}

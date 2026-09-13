import Foundation

/// **ブロッキングするファイル I/O を、協調スレッドプールとメインアクターの外で走らせる窓口**
/// (改善要望7 段階 2、2026-09-13。qooLibrary の `FileIO` を写したもの)。
///
/// ■ なぜ `Task.detached` では足りないのか(qooLibrary 実測、論理コア 10 の機)
/// 協調スレッドプールは論理コア数ぶんしかスレッドを持たない。そこで同期のブロッキング I/O を
/// すると、そのスレッドはランタイムから見えないまま塞がる。**コア数ぶんのブロッキング I/O を
/// `Task` で走らせると、ごく普通の `Task` が 5 秒間一度も動かなかった**。`Task.detached` も
/// 同じプールなので逃げ場にならない。応答しない SMB は 30 秒、NFS(hard マウント)は無限に
/// 返ってこないので、ネットワーク上の 1 フォルダがアプリの async 処理を全部止めうる。
///
/// ■ 投入ごとに新しい serial queue を作る(同じく実測)
/// | 実行先 | プールを塞いだ状態で 4 件のブロッキング I/O を始められるか |
/// |---|---|
/// | private concurrent queue | 0/4(10 秒待っても始まらない) |
/// | `DispatchQueue.global()` | 0/4 |
/// | **投入ごとに新しい serial queue** | **4/4 が 0ms で開始**(費用は 1 件約 1µs) |
///
/// libdispatch が「ブロックされたら新しいスレッドを起こす」のは overcommit なキューだけで、
/// concurrent queue も global queue も non-overcommit(幅が CPU 数に縛られる)。serial queue は
/// 1 本ずつが overcommit 扱いなので、並べれば必ずスレッドを貰える。**決まった本数を使い回すと
/// デッドロックする**(同じキューに載った 2 件が互いの開始を待ち合う。qooLibrary で踏んだ)ので、
/// 投入ごとに作る。
///
/// ■ 取り消し
/// 借りたスレッドには Task の文脈が無いので、`body` の中の `Task.isCancelled` は**常に false**。
/// 取り消しは `Cancellation` で伝える(`perform` が呼び出し元タスクの取り消しを橋渡しする)。
/// **`body` の中とその先では `Task.isCancelled` ではなく `Cancellation.isRequestedInCurrentScope` を読む。**
///
/// ■ 期限
/// macOS に中断できるファイル I/O は無い。`withDeadline` が行うのは**待つのをやめること**だけで、
/// 走っている I/O は止まらない。
///
/// 既存の `FolderExistenceProbe`(CollectionAutoFolderRow.swift)も同じ理由で同じ形をしている。
/// 動いているものなので段階 2 では寄せない。
nonisolated enum FileIO {
    /// 同期のブロッキング処理を、プールとメインスレッドの外で実行する。
    ///
    /// - Parameter cancellation: 呼び出し側が持つ中止ボタンの旗。`body` の中からは
    ///   `Cancellation.isRequestedInCurrentScope` で、タスクの取り消しと合わせて見える。
    ///
    /// 取り消されても待つのはやめない(旗を立てて `body` に伝えるだけ)。`body` は最後まで走り、
    /// その結果が返る。
    static func perform<T: Sendable>(
        cancellation: Cancellation? = nil,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let scope = Cancellation(parent: cancellation)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                submit {
                    continuation.resume(with: Result { try Cancellation.withScope(scope) { try body() } })
                }
            }
        } onCancel: {
            // 既に取り消された状態で入った場合もここが呼ばれる(Swift の保証)ので、
            // body が走り出す前に旗が立つ経路も塞がっている。
            scope.request()
        }
    }

    /// 失敗しない処理向け。
    static func perform<T: Sendable>(
        cancellation: Cancellation? = nil,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        let scope = Cancellation(parent: cancellation)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                submit {
                    continuation.resume(returning: Cancellation.withScope(scope) { body() })
                }
            }
        } onCancel: {
            scope.request()
        }
    }

    /// 期限付きで待つ。**時間が来たら待つのをやめるだけで、I/O 自体は止まらない。**
    /// 期限を過ぎたら `FileOperationError.timedOut` を投げ、`operation` の結果は捨てる。
    ///
    /// - Note: **タイマーは `DispatchSource`**。`Task.sleep` も `DispatchQueue.asyncAfter`(global)も、
    ///   プールが塞がっていると 5 秒待っても発火しなかった ―― 期限が要るのはまさにその場面
    ///   (qooLibrary 実測)。
    /// - Note: **構造化並行性で書かない。** TaskGroup で本体とスリープを競争させると、
    ///   抜けるときにグループが全子タスクの完了を暗黙に待つので期限が効かない。
    static func withDeadline<T: Sendable>(
        _ limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = SingleResume<T>()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        return try await withCheckedThrowingContinuation { continuation in
            box.arm(continuation)
            let work = Task {
                // 先に終わったならタイマーは用済み。cancel() がハンドラ(タイマー自身を捕まえている)を
                // 解放して循環も切れる。
                defer { timer.cancel() }
                do { box.resume(.success(try await operation())) } catch { box.resume(.failure(error)) }
            }
            timer.schedule(deadline: .now() + limit.fileIOSeconds)
            timer.setEventHandler {
                timer.cancel()
                guard box.resume(.failure(FileOperationError.timedOut(seconds: limit.fileIOSeconds))) else { return }
                // 待つのはやめたが、区切りを持つ処理には中止を伝える。
                work.cancel()
            }
            // **resume() へ必ず到達すること(早期 return を挟まない)。** 一度も resume されないまま
            // 解放された DispatchSource は SIGTRAP で落ちる(qooLibrary 実測)。
            timer.resume()
        }
    }

    /// ブロッキングしてよい仕事を 1 件、そのためだけの実行先へ渡す。`perform` の土台で、テストが
    /// 「プールが塞がっていても走り出す」を async を経ずに確かめるためにだけ internal にしてある。
    ///
    /// 実行先は直列(overcommit を得る)で、使い回さない(待ち合いを作らない)。
    /// `.userInitiated`: 一覧を出す・ファイルを運ぶ、というユーザーの操作に直結する仕事なので。
    static func submit(_ work: @escaping @Sendable () -> Void) {
        DispatchQueue(label: "jp.qooViewer.fileIO", qos: .userInitiated).async(execute: work)
    }

    /// 期限の発火専用。**I/O と混ぜない**(見張り役が見張りたい相手に待たされる)。
    /// ここに載るのは継続を 1 回再開するだけの処理なので 1 本を使い回してよい。
    private static let timerQueue = DispatchQueue(label: "jp.qooViewer.fileIO.deadline", qos: .userInitiated)

    /// 1 度だけ再開できる継続。二重再開は CheckedContinuation がクラッシュとして検出するので鍵で絞る。
    private final class SingleResume<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        func arm(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
        }

        /// - Returns: この呼び出しが実際に応答したか(先着だったか)。
        @discardableResult
        func resume(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
            return pending != nil
        }
    }
}

/// **1 つの仕事への取り消し要求**。借りたスレッドの上でも見える(`FileIO` の型コメント参照)。
///
/// - 中止ボタンを持つ呼び出し側は 1 つ作って `request()` を呼ぶ。
/// - `FileIO.perform` はそれを親にした旗を作り、呼び出し元タスクの取り消しもそこへ立てる。
/// - 中で働く側は `Cancellation.isRequestedInCurrentScope` を読む。スコープの中なら旗を、
///   外なら `Task.isCancelled` を見るので、どちらの世界から呼ばれても正しく動く。
///
/// 旗は 1 度立てたら下ろせない。立てても走っている `copyfile` や `read(2)` は止まらず、
/// 見るのは次の区切り(copyfile の status callback、走査の 1 件ごと)。
nonisolated final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private let parent: Cancellation?

    init() {
        parent = nil
    }

    fileprivate init(parent: Cancellation?) {
        self.parent = parent
    }

    /// 取り消しを要求する。何度呼んでもよい。
    func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    var isRequested: Bool {
        lock.lock()
        let mine = requested
        lock.unlock()
        return mine || (parent?.isRequested ?? false)
    }

    /// いま取り消しを要求されているか。`withScope` の中ならその旗を、外なら `Task.isCancelled` を見る。
    static var isRequestedInCurrentScope: Bool {
        if let raw = pthread_getspecific(key) {
            return Unmanaged<Cancellation>.fromOpaque(raw).takeUnretainedValue().isRequested
        }
        return Task.isCancelled
    }

    /// このスレッドの上で走る `body` を `flag` に結び付ける。`flag` の寿命は呼び出し側が持つ
    /// (ここでは所有権を取らない)。入れ子にしても前の結び付きを defer で戻す。
    static func withScope<T>(_ flag: Cancellation, _ body: () throws -> T) rethrows -> T {
        let previous = pthread_getspecific(key)
        pthread_setspecific(key, Unmanaged.passUnretained(flag).toOpaque())
        defer { pthread_setspecific(key, previous) }
        return try body()
    }

    /// スレッドごとの「いまどの旗を見るか」。走査の内側で数万回読むので、threadDictionary
    /// (NSMutableDictionary への橋渡し)ではなく pthread の TLS。値は非所有なので破棄関数は渡さない。
    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()
}

extension Duration {
    /// 小数を含む秒数。`components.seconds` は整数部だけなので、1 秒未満の期限が全部 0 になる。
    nonisolated var fileIOSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

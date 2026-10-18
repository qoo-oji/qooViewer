import Foundation
import StackNestViewerKit

/// 終了(⌘Q など)のときに、StackNest へまだ送っていない読書位置を送り切る(最長 `timeout`)。
///
/// ■ なぜ部品の `StackNestProgressRegistry.flushAll` を使わないか(2026-10-18 のレビューの実測)
/// 最初の案は `applicationShouldTerminate` で `.terminateLater` を返し、部品の `flushAll` の完了で
/// `reply(toApplicationShouldTerminate:)` を呼んでいた。`flushAll` は書き戻しの役(MainActor)とメインキューの時計で進むので、
/// 終了が**メインキューの仕事の中から**頼まれる(`Task { @MainActor }`・`DispatchQueue.main.async` の中の `NSApp.terminate`。
/// スライドショーの末尾・マウスの割り当ての「終了」・保存データの削除の後の終了・Debug の制御口の quit)と、AppKit の終了待ちの
/// 入れ子のループの間はメインキューが回らず(メインキューは入れ子に回らない)、返事が来ないまま**アプリが永久に止まった**
/// (送っていない位置があり、StackNest が応答しないときに実測)。
///
/// ここでは、送る位置をメインの上で控えてから、送るのはメインキューを使わない Task で行い、メインはセマフォで最長 `timeout` だけ
/// 待つ(終了を遅らせるのはこの時間だけ)。部品のセッションの書き戻し(`postProgress`)は部品の中でメインを使わない
/// (URLSession の delegate のキュー・XPC の返事のキュー)ので、メインが待っていても進む。
@MainActor
final class StackNestQuitFlush {
    /// アプリで 1 つ(終了は 1 回)。試験は自分のインスタンスを作る。
    static let shared = StackNestQuitFlush()

    /// 載せる側が使う既定値。テストでは共有の状態に触れないよう nil(MemoryUsageRegistry.forCurrentProcess と同じ)。
    static var forCurrentProcess: StackNestQuitFlush? {
        RuntimeEnvironment.isRunningTests ? nil : shared
    }

    private struct Entry {
        weak var reporter: StackNestProgressReporter?
        let session: StackNestBookSession
        /// まだ送っていないかもしれない最後のページ(StackNest のページ番号)。
        let lastPage: () -> Int?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// 閉じた本のうち、閉じたときの送信がまだ終わっていないもの(`unregister`)。役が送り終えたら(役が消えた・送るものが無い)外す。
    private var closing: [Entry] = []

    init() {}

    /// 書き戻しの役を持つビューア(`owner`)を載せる。`lastPage` は最後に `note(page:)` したページ。
    func register(
        owner: AnyObject, reporter: StackNestProgressReporter, session: StackNestBookSession,
        lastPage: @escaping () -> Int?
    ) {
        entries = entries.filter { $0.value.reporter != nil }
        entries[ObjectIdentifier(owner)] = Entry(reporter: reporter, session: session, lastPage: lastPage)
    }

    /// 本を閉じた(書き戻しの役は自分で送り切る)。
    ///
    /// 閉じたときの送信がまだ飛んでいれば、送り終えるまで控えに残す(2026-10-19 のレビュー: 以前はすぐ外したので、「最後のウインドウを
    /// 閉じたら終了」で閉じてすぐ終了すると、控えが空のまま待たずに終わり、その送信が切れえた)。持ち主(ビューア)はもう居ないので、
    /// ページは今の値を写して持つ。
    func unregister(owner: AnyObject) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(owner)) else { return }
        if let reporter = entry.reporter, reporter.hasUnsentWork, let page = entry.lastPage() {
            closing.append(Entry(reporter: reporter, session: entry.session, lastPage: { page }))
        }
    }

    /// 送っていない位置を送り、送り終わるか `timeout` が来るまでメインで待つ。送るものが無ければ待たない。
    /// - Returns: 送ろうとした数。
    @discardableResult
    func flushBlocking(timeout: TimeInterval) -> Int {
        closing.removeAll { $0.reporter?.hasUnsentWork != true }
        let jobs: [(StackNestBookSession, Int)] = (Array(entries.values) + closing).compactMap { entry in
            guard let reporter = entry.reporter, reporter.hasUnsentWork, let page = entry.lastPage() else { return nil }
            return (entry.session, page)
        }
        guard !jobs.isEmpty else { return 0 }
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for (session, page) in jobs {
                    group.addTask { try? await session.postProgress(page: page) }
                }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return jobs.count
    }
}

import Foundation
import os

/// `PagePixelBuffer`の**厳密なLRU**メモリキャッシュ。PageLoaderの3つのメモリキャッシュ
/// (ページ画像・進捗バー用サムネイル・拡大サムネイル)はすべてこれで持つ。
///
/// ■ なぜNSCacheをやめたのか(リソースモニタの実測に基づく)
/// 以前は`NSCache`(+出し入れの帳簿)だった。NSCacheは上限に達したときに**どれを追い出すかを
/// 約束しない**。実際に、上限いっぱい(1000MB・47MBのページ×21枚)でページを送っていくと、
/// 先読みしたばかりの隣のページが追い出されて、遠くの古いページが残る(モニタの表示で
/// 「前 18・後 1」)状態になった。ページ送りの直後に必要なのは隣のページなので、これでは
/// 先読みの意味が無い。
///
/// ここでは「最後に触ってから最も時間が経ったもの」から順に追い出す。`prefetch(around:)`が
/// ページ送りのたびに前後の範囲を`object(forKey:)`で触るので、いま読んでいる場所の周りが
/// 常に最新になり、追い出されるのは読み終えて遠ざかったページになる。
///
/// NSCacheが持っていた「メモリが逼迫したら自動的に空ける」は、`DispatchSource`の
/// メモリ圧迫通知で自前に行う(`.warning`で半分まで、`.critical`で全部)。NSCacheのそれは
/// いつ・どれだけ空けるかが不明だったので、むしろ動作が明確になった。
///
/// ■ 上限
/// - `totalCostLimit`: 合計バイト数(`PagePixelBuffer.byteCount`の和)。入れた直後に超えていれば
///   その場で古いものから追い出すので、**瞬間的にも超えない**(入れる1枚が上限より大きい
///   場合だけは、その1枚は残す。追い出しても意味が無いため)。
/// - `countLimit`: 枚数。同じく超えない。
///
/// ■ スレッド
/// 使うのはPageLoader(actor)の中だけだが、メモリ圧迫通知は別スレッドから来るため、状態は
/// ロックで守る。操作はどれも辞書と配列の出し入れで、ロックを握る時間は無視できる。
///
/// ■ リソースモニタ向け
/// `snapshot()`で合計バイト・枚数・キーの集合を返す。帳簿を別に持たなくても、自分自身が
/// 中身を知っている。
nonisolated final class PagePixelCache: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var totalBytes: Int
        var count: Int
        var keys: Set<String>

        static let empty = Snapshot(totalBytes: 0, count: 0, keys: [])
    }

    private struct State {
        var entries: [String: PagePixelBuffer] = [:]
        /// 最後に触った順(先頭が最も古い)。`entries`と同じキーを持つ。
        /// 配列の先頭削除・中間削除はO(n)だが、nは最大でも数百(countLimit)で、
        /// ページ送り1回あたり数回しか動かないので問題にならない。
        var recency: [String] = []
        var totalBytes = 0
        var countLimit: Int
        var totalCostLimit: Int

        mutating func touch(_ key: String) {
            if let index = recency.firstIndex(of: key) {
                recency.remove(at: index)
            }
            recency.append(key)
        }

        mutating func remove(_ key: String) {
            guard let buffer = entries.removeValue(forKey: key) else { return }
            totalBytes -= buffer.byteCount
            if let index = recency.firstIndex(of: key) {
                recency.remove(at: index)
            }
        }

        /// 上限に収まるまで古いものから追い出す。`keep`は追い出してはならないキー
        /// (入れたばかりの1枚)。
        mutating func evictToFit(keeping keep: String?) {
            while (totalBytes > totalCostLimit && totalCostLimit > 0) || entries.count > countLimit {
                guard let oldest = recency.first(where: { $0 != keep }) else { return }
                remove(oldest)
            }
        }

        mutating func trim(toBytes target: Int) {
            while totalBytes > target, let oldest = recency.first {
                remove(oldest)
            }
        }
    }

    private let state: OSAllocatedUnfairLock<State>
    private let memoryPressureSource: DispatchSourceMemoryPressure

    init(countLimit: Int, totalCostLimit: Int = 0) {
        state = OSAllocatedUnfairLock(initialState: State(countLimit: countLimit, totalCostLimit: totalCostLimit))
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility)
        )
        memoryPressureSource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.memoryPressureSource.data
            if event.contains(.critical) {
                self.removeAll()
            } else if event.contains(.warning) {
                self.state.withLock { $0.trim(toBytes: $0.totalBytes / 2) }
            }
        }
        memoryPressureSource.activate()
    }

    deinit {
        memoryPressureSource.cancel()
    }

    var totalCostLimit: Int {
        get { state.withLock { $0.totalCostLimit } }
        set {
            state.withLock { state in
                state.totalCostLimit = newValue
                state.evictToFit(keeping: nil)
            }
        }
    }

    /// 取り出すと「最後に触った」扱いになる。
    func object(forKey key: NSString) -> PagePixelBuffer? {
        let key = key as String
        return state.withLock { state in
            guard let buffer = state.entries[key] else { return nil }
            state.touch(key)
            return buffer
        }
    }

    /// コストは常に`PagePixelBuffer.byteCount`(実際に占めているバイト数)。
    func store(_ buffer: PagePixelBuffer, forKey key: NSString) {
        let key = key as String
        state.withLock { state in
            state.remove(key)
            state.entries[key] = buffer
            state.totalBytes += buffer.byteCount
            state.touch(key)
            state.evictToFit(keeping: key)
        }
    }

    func removeAll() {
        state.withLock { state in
            state.entries.removeAll()
            state.recency.removeAll()
            state.totalBytes = 0
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { state in
            Snapshot(totalBytes: state.totalBytes, count: state.entries.count, keys: Set(state.entries.keys))
        }
    }
}

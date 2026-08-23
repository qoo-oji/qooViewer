import Foundation
import os

/// `NSCache`の**中身の帳簿**。NSCacheは「いま何バイト入っているか」「どのキーが残っているか」を
/// 一切教えてくれない(`totalCostLimit`は上限であって現在値ではなく、キーの列挙もできない)。
/// サイドパネルのリソースモニタが「設定の上限に対して実際にどれだけ使っているか」「前後
/// 何ページが残っているか」を出すために、出し入れを自分で記録する。
///
/// ■ 仕組み
/// - 入れるとき: `record(_:key:bytes:)`で「そのオブジェクト → (キー, バイト数)」を覚える。
///   PageLoader側は`NSCache.setObject`の直前に必ずこれを呼ぶ(`TrackedPixelCache.store(_:forKey:)`)。
/// - 出ていくとき: `NSCacheDelegate.cache(_:willEvictObject:)`で知らされるので、そのオブジェクトの
///   記録を消す。上限超過による自動退避・`removeAllObjects()`・同じキーへの上書き、のどれでも
///   呼ばれる。オブジェクトの同一性(`ObjectIdentifier`)で引くのは、デリゲートに渡されるのが
///   オブジェクトだけでキーが分からないため。
///
/// ■ スレッド
/// デリゲートは**NSCacheが退避を決めたスレッド**で呼ばれる(`setObject`を呼んだactorの
/// スレッドのこともあれば、メモリ逼迫時のバックグラウンドのこともある)。そのためactorの
/// 状態には置けず、ロックで守る。記録は整数の足し引きだけなので、ロックを握る時間は無視できる。
///
/// ■ 正確さの限界
/// `willEvictObject`が「これから退避する」という通知なので、帳簿はNSCacheより**わずかに先に**
/// 減る。逆に`setObject`の直前に記録するので、わずかに先に増える。どちらも同じ関数の中の
/// 数命令ぶんの差で、1秒に1回読む用途では見えない。
///
/// nonisolated / @unchecked Sendable: PageLoader(actor)からもNSCacheのデリゲート呼び出し
/// (任意のスレッド)からも触るため。状態はすべてロックの内側にある。
nonisolated final class CacheLedger: NSObject, NSCacheDelegate, @unchecked Sendable {
    /// ある時点の中身。`keys`はキャッシュの種類によって意味が違う(ページ画像なら`PageRef.id`、
    /// 拡大サムネイルなら`"id|px"`)。
    struct Snapshot: Equatable, Sendable {
        var totalBytes: Int
        var count: Int
        var keys: Set<String>

        static let empty = Snapshot(totalBytes: 0, count: 0, keys: [])
    }

    private struct Entry {
        let key: String
        let bytes: Int
    }

    private struct State {
        var entries: [ObjectIdentifier: Entry] = [:]
        /// 同じキーを別のオブジェクトで上書きしたとき、古いほうの記録を確実に消すための逆引き。
        /// NSCacheは上書き時にも`willEvictObject`を呼ぶが、それに頼らず自前でも消しておく
        /// (呼ばれる順序が`setObject`の前か後かに依存しないようにするため)。
        var objectByKey: [String: ObjectIdentifier] = [:]
        var totalBytes = 0

        mutating func remove(_ id: ObjectIdentifier) {
            guard let entry = entries.removeValue(forKey: id) else { return }
            totalBytes -= entry.bytes
            if objectByKey[entry.key] == id {
                objectByKey.removeValue(forKey: entry.key)
            }
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `NSCache.setObject`の**直前**に呼ぶ。
    func record(_ object: AnyObject, key: String, bytes: Int) {
        let id = ObjectIdentifier(object)
        state.withLock { state in
            if let previous = state.objectByKey[key], previous != id {
                state.remove(previous)
            }
            if let existing = state.entries[id] {
                state.totalBytes -= existing.bytes
            }
            state.entries[id] = Entry(key: key, bytes: bytes)
            state.objectByKey[key] = id
            state.totalBytes += bytes
        }
    }

    /// `NSCache.removeAllObjects()`の後に呼ぶ。デリゲートで1件ずつ消えているはずだが、
    /// 呼ばれなかった場合にも帳簿が空になるよう、明示的に空にする。
    func removeAll() {
        state.withLock { $0 = State() }
    }

    func snapshot() -> Snapshot {
        state.withLock { state in
            Snapshot(
                totalBytes: state.totalBytes,
                count: state.entries.count,
                keys: Set(state.objectByKey.keys)
            )
        }
    }

    // MARK: NSCacheDelegate

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        let id = ObjectIdentifier(obj as AnyObject)
        state.withLock { $0.remove(id) }
    }
}


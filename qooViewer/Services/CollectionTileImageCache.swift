import Foundation
import CoreGraphics
import os

/// 焼いた札の絵(CollectionTileImageStore)の、**復号済み**メモリキャッシュ。厳密なLRU。
///
/// ■ なぜ要るのか(ユーザー報告 2026-09-09: 「スクロール時にカバー画像の読み込みがランダムに
/// 発生する」)
/// ウェルカム画面のグリッドは、画面外セルの保持物を手放すために予算超過で`.id(epoch)`ごと
/// 作り直す(LazyCellImageBudget参照)。ページ一覧グリッドでは、作り直しの直後にセルが
/// 読み直す画像がPageLoaderのメモリキャッシュに残っているため一瞬で戻るが、コレクションの
/// カバーには**メモリキャッシュが一つも無かった** ―― 作り直しのたびに画面内の全セルが
/// ディスクから読み直しになり、絵が消えてから出てくるのが見えていた。ここに残しておけば、
/// 作り直しの直後でも同期で(待たずに)描ける(CollectionTile.sheetImage(for:)参照)。
///
/// ■ 鍵に復号サイズが入る
/// 札の大きさはスライダーで変わり、そのたびに必要な画素数も変わる。同じ絵でも復号サイズが
/// 違えば別物なので、鍵は「署名 + 復号した画素数」(CollectionTileImageStore.cacheKey)。
/// スライダーのドラッグ中に鍵が1ptごとに変わらないよう、画素数は呼び出し側が量子化する。
///
/// 実装(OSAllocatedUnfairLockで守った辞書 + 最終アクセス順の配列、メモリ逼迫で自分から
/// 空ける)は`PagePixelCache`と同じ。あちらは`PagePixelBuffer`専用で、リソースモニタ向けの
/// snapshot()やpeek()を持つなど本のページ表示に合わせた作りなので、CGImage1種類だけを
/// 相手にするこちらは別に持つ。
nonisolated final class CollectionTileImageCache: @unchecked Sendable {
    private struct State {
        var entries: [String: CGImage] = [:]
        /// 最後に触った順(先頭が最も古い)。`entries`と同じ鍵を持つ。
        var recency: [String] = []
        var totalBytes = 0
        let countLimit: Int
        let totalCostLimit: Int

        mutating func touch(_ key: String) {
            if let index = recency.firstIndex(of: key) {
                recency.remove(at: index)
            }
            recency.append(key)
        }

        mutating func remove(_ key: String) {
            guard let image = entries.removeValue(forKey: key) else { return }
            totalBytes -= image.bytesPerRow * image.height
            if let index = recency.firstIndex(of: key) {
                recency.remove(at: index)
            }
        }

        /// 上限に収まるまで古いものから追い出す。`keep`は追い出してはならない鍵
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

    init(countLimit: Int, totalCostLimit: Int) {
        state = OSAllocatedUnfairLock(
            initialState: State(countLimit: countLimit, totalCostLimit: totalCostLimit)
        )
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

    /// 取り出すと「最後に触った」扱いになる。
    func image(forKey key: String) -> CGImage? {
        state.withLock { state in
            guard let image = state.entries[key] else { return nil }
            state.touch(key)
            return image
        }
    }

    func store(_ image: CGImage, forKey key: String) {
        state.withLock { state in
            state.remove(key)
            state.entries[key] = image
            state.totalBytes += image.bytesPerRow * image.height
            state.touch(key)
            state.evictToFit(keeping: key)
        }
    }

    /// この接頭辞で始まる鍵を全部捨てる。鍵の先頭はコレクションのidなので、
    /// 「このコレクションの焼いた絵を作り直す」ときに、復号サイズ違いをまとめて落とせる。
    func removeAll(withPrefix prefix: String) {
        state.withLock { state in
            // 走査中に辞書を触らないよう、消す鍵を先に集める。
            let keys = state.entries.keys.filter { $0.hasPrefix(prefix) }
            for key in keys {
                state.remove(key)
            }
        }
    }

    func removeAll() {
        state.withLock { state in
            state.entries.removeAll()
            state.recency.removeAll()
            state.totalBytes = 0
        }
    }
}

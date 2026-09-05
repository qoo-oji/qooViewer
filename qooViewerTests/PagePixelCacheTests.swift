import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// ページ画像のメモリキャッシュ(Services/PagePixelCache.swift)。
///
/// `NSCache` をやめてまで**厳密な LRU** にしたのは、上限いっぱいで先読みしたばかりの隣のページが
/// 追い出され、遠い古いページが残る状態を実測したため(型コメント参照)。ここで固定するのは
/// その2点 ―― 「追い出されるのは最後に触ってから最も古いもの」「上限は瞬間的にも超えない」。
struct PagePixelCacheTests {
    /// 中身は問わないので、フィクスチャのページ画像をそのまま使う。1枚のバイト数は行の
    /// パディング次第なので、期待値は数えずに実物(`byteCount`)から組む。
    private func buffer() throws -> PagePixelBuffer {
        try #require(PagePixelBuffer(rendering: PageImageFactory.cgImage(number: 1)))
    }

    private func store(_ cache: PagePixelCache, _ keys: [String], _ buffer: PagePixelBuffer) {
        for key in keys { cache.store(buffer, forKey: key as NSString) }
    }

    // MARK: - 出し入れ

    @Test("入れたものが取り出せる")
    func storeAndRetrieve() throws {
        let cache = PagePixelCache(countLimit: 4)
        let buffer = try buffer()
        cache.store(buffer, forKey: "a")
        #expect(cache.object(forKey: "a") === buffer)
        #expect(cache.object(forKey: "b") == nil)
        #expect(cache.snapshot() == PagePixelCache.Snapshot(
            totalBytes: buffer.byteCount, count: 1, keys: ["a"]
        ))
    }

    @Test("同じキーへ入れ直しても、合計バイト数は二重に数えない")
    func storingTheSameKeyTwiceDoesNotDoubleCount() throws {
        let cache = PagePixelCache(countLimit: 4)
        let buffer = try buffer()
        cache.store(buffer, forKey: "a")
        cache.store(buffer, forKey: "a")
        #expect(cache.snapshot().count == 1)
        #expect(cache.snapshot().totalBytes == buffer.byteCount)
    }

    @Test("removeAll で空になる")
    func removeAllEmptiesTheCache() throws {
        let cache = PagePixelCache(countLimit: 4)
        store(cache, ["a", "b"], try buffer())
        cache.removeAll()
        #expect(cache.snapshot() == .empty)
        #expect(cache.object(forKey: "a") == nil)
    }

    // MARK: - 枚数の上限

    @Test("枚数の上限を超えたら、最も古いものから追い出す")
    func theCountLimitEvictsTheOldest() throws {
        let cache = PagePixelCache(countLimit: 3)
        store(cache, ["a", "b", "c", "d"], try buffer())
        #expect(cache.snapshot().keys == ["b", "c", "d"])
        #expect(cache.snapshot().count == 3)
    }

    @Test("取り出すと「最後に触った」扱いになり、追い出されにくくなる")
    func retrievingPromotesTheEntry() throws {
        let cache = PagePixelCache(countLimit: 3)
        store(cache, ["a", "b", "c"], try buffer())
        _ = cache.object(forKey: "a") // a が最新になる
        store(cache, ["d"], try buffer())
        #expect(cache.snapshot().keys == ["a", "c", "d"]) // 追い出されたのは b
    }

    @Test("peek は「最後に触った」扱いにしない")
    func peekDoesNotPromote() throws {
        // サムネイルの材料として遠いページを覗いたときに、LRU の並びを乱さないためのもの。
        let cache = PagePixelCache(countLimit: 3)
        let buffer = try buffer()
        store(cache, ["a", "b", "c"], buffer)
        #expect(cache.peek(forKey: "a") === buffer)
        store(cache, ["d"], buffer)
        #expect(cache.snapshot().keys == ["b", "c", "d"]) // 覗いた a が追い出された
    }

    // MARK: - バイト数の上限

    @Test("バイト数の上限は、入れた瞬間にも超えない")
    func theByteLimitIsNeverExceededEvenMomentarily() throws {
        let buffer = try buffer()
        let cache = PagePixelCache(countLimit: 100, totalCostLimit: buffer.byteCount * 2)
        store(cache, ["a", "b", "c"], buffer)
        #expect(cache.snapshot().totalBytes <= buffer.byteCount * 2)
        #expect(cache.snapshot().keys == ["b", "c"])
    }

    @Test("1枚で上限を超える画像は、それでも残す")
    func anOversizedBufferIsStillKept() throws {
        // 追い出しても意味が無い(次に読みに行っても同じ大きさ)ため、この1枚だけは例外。
        let buffer = try buffer()
        let cache = PagePixelCache(countLimit: 100, totalCostLimit: buffer.byteCount / 2)
        cache.store(buffer, forKey: "big")
        #expect(cache.snapshot().keys == ["big"])
    }

    @Test("上限 0 はバイト数の制限なし(枚数だけで抑える)")
    func aZeroByteLimitMeansUnlimited() throws {
        let cache = PagePixelCache(countLimit: 10, totalCostLimit: 0)
        store(cache, ["a", "b", "c"], try buffer())
        #expect(cache.snapshot().count == 3)
    }

    @Test("上限を下げると、その場で追い出す")
    func loweringTheLimitEvictsImmediately() throws {
        let buffer = try buffer()
        let cache = PagePixelCache(countLimit: 100, totalCostLimit: buffer.byteCount * 4)
        store(cache, ["a", "b", "c", "d"], buffer)
        #expect(cache.snapshot().count == 4)

        cache.totalCostLimit = buffer.byteCount * 2
        #expect(cache.totalCostLimit == buffer.byteCount * 2)
        #expect(cache.snapshot().keys == ["c", "d"])
    }
}

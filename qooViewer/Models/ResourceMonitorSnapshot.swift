import Foundation

/// サイドパネルのリソースモニタに出す、**このウインドウで開いている本**のメモリキャッシュと
/// 先読みの状態。`ViewerViewModel.resourceSnapshot(prefetchPageCount:)`が`PageLoader.cacheStatistics()`
/// と現在ページから組み立てる。
///
/// 値型(Equatable)なのは、AppState経由で1秒ごとに取り直すため、変わっていなければ
/// SwiftUIの再描画を起こさないようにするため。
nonisolated struct ResourceMonitorSnapshot: Equatable, Sendable {
    /// 1種類のメモリキャッシュの「上限に対する実使用量」。
    struct CacheUsage: Equatable, Sendable {
        var usedBytes: Int
        var limitBytes: Int
        var count: Int

        var fraction: Double {
            limitBytes > 0 ? Double(usedBytes) / Double(limitBytes) : 0
        }
    }

    var pageImages: CacheUsage
    var thumbnails: CacheUsage
    var gridThumbnails: CacheUsage

    /// 現在ページ(0始まり)。
    var currentIndex: Int
    var pageCount: Int
    /// 環境設定「前後に先読みするページ数」。
    var prefetchRadius: Int
    /// 現在ページから前(小さいインデックス)へ、**途切れずに**キャッシュに残っているページ数。
    /// 先読みが効いているなら`prefetchRadius`以上になる(以前見たページも残っているため)。
    var residentBefore: Int
    /// 同じく後ろへ。
    var residentAfter: Int
    /// ページ画像がキャッシュに残っているページのインデックス(現在ページの前後
    /// `prefetchRadius + 2`の範囲だけ。帯の表示用)。
    var residentIndicesAroundCurrent: Set<Int>
    /// いま先読みのタスクが走っているページのインデックス。
    var prefetchingIndices: Set<Int>
    /// 先読みが設定より広い範囲に及んでいるか(異常判定の材料)。
    var isPrefetchingBeyondRadius: Bool {
        prefetchingIndices.contains { abs($0 - currentIndex) > prefetchRadius }
    }

    /// 3つのキャッシュの実使用量の合計。「説明のつかないメモリ」の計算に使う。
    var totalCacheBytes: Int {
        pageImages.usedBytes + thumbnails.usedBytes + gridThumbnails.usedBytes
    }

    init(statistics: PageCacheStatistics, pageIDs: [String], currentIndex: Int, prefetchRadius: Int) {
        pageImages = CacheUsage(
            usedBytes: statistics.pageImages.totalBytes,
            limitBytes: statistics.pageImageLimitBytes,
            count: statistics.pageImages.count
        )
        thumbnails = CacheUsage(
            usedBytes: statistics.thumbnails.totalBytes,
            limitBytes: statistics.thumbnailLimitBytes,
            count: statistics.thumbnails.count
        )
        gridThumbnails = CacheUsage(
            usedBytes: statistics.gridThumbnails.totalBytes,
            limitBytes: statistics.gridThumbnailLimitBytes,
            count: statistics.gridThumbnails.count
        )
        self.currentIndex = currentIndex
        pageCount = pageIDs.count
        self.prefetchRadius = prefetchRadius
        prefetchingIndices = statistics.prefetchingIndices

        let resident = statistics.pageImages.keys
        func isResident(_ index: Int) -> Bool {
            pageIDs.indices.contains(index) && resident.contains(pageIDs[index])
        }
        var before = 0
        while isResident(currentIndex - before - 1) { before += 1 }
        var after = 0
        while isResident(currentIndex + after + 1) { after += 1 }
        residentBefore = before
        residentAfter = after

        let span = prefetchRadius + 2
        residentIndicesAroundCurrent = Set(
            ((currentIndex - span)...(currentIndex + span)).filter(isResident)
        )
    }
}

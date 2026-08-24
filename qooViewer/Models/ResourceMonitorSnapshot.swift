import Foundation

/// サイドパネルのリソースモニタに出す、**このウインドウで開いている本**のメモリキャッシュと
/// メモリ常駐の状態。`ViewerViewModel.resourceSnapshot()`が`PageLoader.cacheStatistics()`
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

    /// 現在ページ(0始まり)。見開きのときは**左右のうちファイル順で先のページ**。
    var currentIndex: Int
    /// いま画面に出ているページ数(単ページなら1、見開きなら2)。表示中のページは
    /// `currentIndex ..< currentIndex + displayedPageCount`。帯はこの範囲を「現在」として
    /// 塗り、先読みの数からも外す(見開きの相方を先読み扱いしないため)。
    var displayedPageCount: Int
    var pageCount: Int
    /// この本の読み方向が右開きか。表示側が帯とラベルの並びを読み方向に合わせるために使う
    /// (右開きでは、後のページが画面の**左**側に来る)。
    var isRightToLeft: Bool
    /// 環境設定「前後に先読みするページ数」。
    var prefetchRadius: Int
    /// 現在ページから前(小さいインデックス)へ、**途切れずに**キャッシュに残っているページ数。
    ///
    /// 「先読みした枚数」ではない。読み終えたページは環境設定「メモリに残しておくページ画像」
    /// の上限に達するまでLRUで残り続けるので、読み進めてきた側は`prefetchRadius`を大きく
    /// 上回るのが正常(枚数の上限は`PageLoader.imageCache`のcountLimit=64)。
    /// 表示側はこれをそのまま出さず、先読みの範囲より外側にはみ出した分
    /// (`residentBefore - prefetchRadius`)を「既読」として出す。先読みと履歴を1つの数字と
    /// 1本の帯で兼ねさせると、帯が飽和しているのに数字だけ伸び続けて異常に見えるため
    /// (ユーザー指摘。SidePanelResourcesSectionViewのpreloadRow/alreadyReadRow参照)。
    var residentBefore: Int
    /// ページ画像がキャッシュに残っているページのインデックス(表示中のページの前後
    /// `prefetchRadius`の範囲 = 先読みの帯が描く範囲だけ)。
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

    init(
        statistics: PageCacheStatistics,
        pageIDs: [String],
        currentIndex: Int,
        prefetchRadius: Int,
        displayedPageCount: Int,
        isRightToLeft: Bool
    ) {
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
        self.displayedPageCount = max(displayedPageCount, 1)
        pageCount = pageIDs.count
        self.isRightToLeft = isRightToLeft
        self.prefetchRadius = prefetchRadius
        prefetchingIndices = statistics.prefetchingIndices

        let resident = statistics.pageImages.keys
        func isResident(_ index: Int) -> Bool {
            pageIDs.indices.contains(index) && resident.contains(pageIDs[index])
        }
        var before = 0
        while isResident(currentIndex - before - 1) { before += 1 }
        residentBefore = before

        // 帯が描くのは「表示中のページ + その前後radius枚」。後ろ側の基点が表示中の
        // 最後のページなのは、先読み自体がそうなっているため(PageLoader.prefetch参照)。
        let lastDisplayed = currentIndex + self.displayedPageCount - 1
        residentIndicesAroundCurrent = Set(
            ((currentIndex - prefetchRadius)...(lastDisplayed + prefetchRadius)).filter(isResident)
        )
    }
}

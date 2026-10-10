import Foundation
import Testing

@testable import qooViewer

/// サイドパネルのリソースモニタの、値を組み立てる側。
///
/// - `ResourceMonitorSnapshot`(Models/): `PageLoader` の統計と現在ページから、帯とラベルの材料を作る。
/// - `ResourceAnomalyDetector`(ViewModels/): そこから「異常」を出す。
/// - `ResourceHistory`(Services/ProcessResourceSampler.swift): グラフの 2 段の履歴。
///
/// 異常の判定は「何も出ない = 正常」を信じてもらう場所なので、**瞬間的な値で鳴らさない**ことが
/// 仕様そのもの。持続回数の数え方(何回連続で、何が起きたらリセットされるか)をここで固定する。
nonisolated struct ResourceSnapshotFactory {
    /// 3 つのメモリキャッシュだけを指定した統計。他は 0。
    static func statistics(
        pageImages: (bytes: Int, limit: Int, keys: Set<String>) = (0, 100, []),
        thumbnails: (bytes: Int, limit: Int) = (0, 100),
        gridThumbnails: (bytes: Int, limit: Int) = (0, 100),
        prefetching: Set<Int> = []
    ) -> PageCacheStatistics {
        PageCacheStatistics(
            pageImages: .init(totalBytes: pageImages.bytes, count: pageImages.keys.count, keys: pageImages.keys),
            pageImageLimitBytes: pageImages.limit,
            thumbnails: .init(totalBytes: thumbnails.bytes, count: 0, keys: []),
            thumbnailLimitBytes: thumbnails.limit,
            gridThumbnails: .init(totalBytes: gridThumbnails.bytes, count: 0, keys: []),
            gridThumbnailLimitBytes: gridThumbnails.limit,
            nestedArchives: .init(
                openReaderCount: 0, inMemoryArchiveCount: 0, inMemoryBytes: 0, inMemoryLimitBytes: 0,
                temporaryArchiveCount: 0, temporaryBytes: 0
            ),
            prefetchingIndices: prefetching
        )
    }

    static func pageIDs(_ count: Int) -> [String] { (0..<count).map { "p\($0)" } }

    static func snapshot(
        statistics: PageCacheStatistics,
        pageCount: Int = 100,
        currentIndex: Int = 50,
        prefetchRadius: Int = 3,
        displayedPageCount: Int = 1,
        isRightToLeft: Bool = false
    ) -> ResourceMonitorSnapshot {
        ResourceMonitorSnapshot(
            statistics: statistics, pageIDs: pageIDs(pageCount), currentIndex: currentIndex,
            prefetchRadius: prefetchRadius, displayedPageCount: displayedPageCount,
            isRightToLeft: isRightToLeft
        )
    }

    static func storage(
        thumbnailCacheBytes: Int? = nil,
        fileBrowserThumbnailCacheBytes: Int? = nil,
        pageListCacheBytes: Int? = nil,
        collectionTileBytes: Int? = nil,
        staleTemporaryEntryCount: Int = 0,
        nestedTemporaryFileCount: Int = 0,
        stagedTemporaryFileCount: Int = 0,
        scannedAt: Date = Date()
    ) -> StorageUsage {
        StorageUsage(
            containerBytes: nil,
            nestedTemporaryFileCount: nestedTemporaryFileCount,
            stagedTemporaryFileCount: stagedTemporaryFileCount,
            staleTemporaryEntryCount: staleTemporaryEntryCount,
            thumbnailCacheBytes: thumbnailCacheBytes, pageListCacheBytes: pageListCacheBytes,
            collectionTileBytes: collectionTileBytes,
            fileBrowserThumbnailCacheBytes: fileBrowserThumbnailCacheBytes,
            scannedAt: scannedAt
        )
    }

    /// 本を読む持ち主 1 人(PageLoader の統計から)。`id` を揃えれば同じ持ち主として数え続ける。
    static let bookOwnerID = UUID()
    static func bookOwner(_ statistics: PageCacheStatistics, id: UUID = bookOwnerID) -> MemoryUsageOwner {
        MemoryUsageOwner(id: id, role: .viewerBook(title: "book"), items: MemoryUsageItem.items(from: statistics))
    }
}

@MainActor
struct ResourceAnomalyDetectorTests {
    private typealias Factory = ResourceSnapshotFactory

    private func input(
        book: ResourceMonitorSnapshot? = nil,
        memory: [MemoryUsageOwner] = [],
        storage: StorageUsage? = nil,
        isDiskCacheEnabled: Bool = true,
        diskCacheLimitBytes: Int = 1_000_000,
        isFileBrowserCacheEnabled: Bool = true,
        fileBrowserCacheLimitBytes: Int = 1_000_000,
        bookReaderCount: Int = 1,
        liveNetworkCopyCount: Int = 0
    ) -> ResourceAnomalyDetector.Input {
        .init(
            bookSnapshot: book, memory: memory, storage: storage, isDiskCacheEnabled: isDiskCacheEnabled,
            diskCacheLimitBytes: diskCacheLimitBytes, isFileBrowserCacheEnabled: isFileBrowserCacheEnabled,
            fileBrowserCacheLimitBytes: fileBrowserCacheLimitBytes, bookReaderCount: bookReaderCount,
            liveNetworkCopyCount: liveNetworkCopyCount
        )
    }

    private func book(_ statistics: PageCacheStatistics) -> [MemoryUsageOwner] {
        [Factory.bookOwner(statistics)]
    }

    // MARK: - メモリキャッシュの上限超過

    @Test("上限ちょうどは異常ではない(超えたときだけ数え始める)")
    func beingExactlyAtTheLimitIsNormal() {
        let detector = ResourceAnomalyDetector()
        let atLimit = book(Factory.statistics(pageImages: (100, 100, [])))
        for _ in 0..<10 {
            #expect(detector.evaluate(input(memory: atLimit)).isEmpty)
        }
    }

    @Test("上限超過は 3 回(3 秒)続いたときだけ異常にする")
    func anOverLimitCacheMustPersistForThreeEvaluations() {
        let detector = ResourceAnomalyDetector()
        let over = book(Factory.statistics(pageImages: (101, 100, [])))
        #expect(ResourceAnomalyDetector.persistenceThreshold == 3)
        #expect(detector.evaluate(input(memory: over)).isEmpty)
        #expect(detector.evaluate(input(memory: over)).isEmpty)
        #expect(detector.evaluate(input(memory: over)) == [.memoryOverLimit(.pageImages)])
        // 一度成立したら、続く限り出続ける。
        #expect(detector.evaluate(input(memory: over)) == [.memoryOverLimit(.pageImages)])
    }

    @Test("途中で収まったら数え直し(瞬間的な超過で鳴らさない)")
    func aSingleFrameOfOverLimitResetsTheStreak() {
        let detector = ResourceAnomalyDetector()
        let over = book(Factory.statistics(pageImages: (101, 100, [])))
        let normal = book(Factory.statistics(pageImages: (50, 100, [])))
        #expect(detector.evaluate(input(memory: over)).isEmpty)
        #expect(detector.evaluate(input(memory: over)).isEmpty)
        #expect(detector.evaluate(input(memory: normal)).isEmpty)
        #expect(detector.evaluate(input(memory: over)).isEmpty)
        #expect(detector.evaluate(input(memory: over)).isEmpty)
        #expect(detector.evaluate(input(memory: over)) == [.memoryOverLimit(.pageImages)])
    }

    @Test("走査の後の判定(拍の外)は持続回数を進めず、今の回数で判定する(監査 SP-12)")
    func evaluationsOutsideTheTickDoNotAdvanceTheStreak() {
        let detector = ResourceAnomalyDetector()
        let over = book(Factory.statistics(pageImages: (101, 100, [])))
        #expect(detector.evaluate(input(memory: over)).isEmpty)
        // 「今すぐ更新」の連打・走査の終わり。何度呼んでも 3 回目の拍の前に異常へ届かない。
        for _ in 0..<5 {
            #expect(detector.evaluate(advancingStreaks: false, input(memory: over)).isEmpty)
        }
        #expect(detector.evaluate(input(memory: over)).isEmpty)
        #expect(detector.evaluate(input(memory: over)) == [.memoryOverLimit(.pageImages)])
        // 成立した後は、拍の外でも続いている限り出す(走査の後に異常の一覧から消えない)。
        #expect(detector.evaluate(advancingStreaks: false, input(memory: over)) == [.memoryOverLimit(.pageImages)])
    }

    @Test("3 種類のキャッシュはそれぞれ別に数える")
    func eachCacheHasItsOwnStreak() {
        let detector = ResourceAnomalyDetector()
        let over = book(Factory.statistics(
            pageImages: (101, 100, []), thumbnails: (101, 100), gridThumbnails: (101, 100)
        ))
        _ = detector.evaluate(input(memory: over))
        _ = detector.evaluate(input(memory: over))
        #expect(Set(detector.evaluate(input(memory: over)))
                == [.memoryOverLimit(.pageImages), .memoryOverLimit(.thumbnails), .memoryOverLimit(.gridThumbnails)])
    }

    @Test("本を閉じたら持続回数は捨てる(次に開いた本へ持ち越さない)")
    func closingTheBookClearsTheStreaks() {
        let detector = ResourceAnomalyDetector()
        let over = book(Factory.statistics(pageImages: (101, 100, [])))
        _ = detector.evaluate(input(memory: over))
        _ = detector.evaluate(input(memory: over))
        #expect(detector.evaluate(input(memory: [])).isEmpty)
        // 数え直しになるので、再び 3 回必要。
        #expect(detector.evaluate(input(memory: over)).isEmpty)
        #expect(detector.evaluate(input(memory: over)).isEmpty)
        #expect(detector.evaluate(input(memory: over)) == [.memoryOverLimit(.pageImages)])
    }

    @Test("持ち主ごとに数える ―― 2 冊が 1 秒ずつ交互に超えても、どちらも 3 秒続いていなければ異常にしない")
    func eachOwnerHasItsOwnStreak() {
        let detector = ResourceAnomalyDetector()
        let first = UUID(), second = UUID()
        let over = Factory.statistics(pageImages: (101, 100, []))
        let normal = Factory.statistics(pageImages: (50, 100, []))
        for index in 0..<6 {
            let owners = [
                Factory.bookOwner(index.isMultiple(of: 2) ? over : normal, id: first),
                Factory.bookOwner(index.isMultiple(of: 2) ? normal : over, id: second),
            ]
            #expect(detector.evaluate(input(memory: owners)).isEmpty)
        }
    }

    @Test("ホームのキャッシュ・ほかのウインドウの本も、上限超過を見る(2026-10-11 の点検で広げた)")
    func homeCachesAndOtherBooksAreChecked() {
        let detector = ResourceAnomalyDetector()
        let home = MemoryUsageOwner(id: UUID(), role: .homeCaches, items: [
            MemoryUsageItem(kind: .fileBrowserThumbnails, usedBytes: 11, limitBytes: 10, count: 1),
            MemoryUsageItem(kind: .collectionCovers, usedBytes: 5, limitBytes: 10, count: 1),
            MemoryUsageItem(kind: .collectionTiles, usedBytes: 11, limitBytes: 10, count: 1),
        ])
        let editor = MemoryUsageOwner(id: UUID(), role: .bookmarkEditor(title: nil), items: MemoryUsageItem.items(
            from: Factory.statistics(thumbnails: (101, 100))))
        for _ in 0..<2 { _ = detector.evaluate(input(memory: [home, editor])) }
        #expect(detector.evaluate(input(memory: [home, editor]))
                == [.memoryOverLimit(.thumbnails), .memoryOverLimit(.fileBrowserThumbnails), .memoryOverLimit(.collectionTiles)])
    }

    @Test("上限の無い項目・見積もりは上限超過を見ない")
    func itemsWithoutALimitAreNotChecked() {
        let detector = ResourceAnomalyDetector()
        let owner = MemoryUsageOwner(id: UUID(), role: .pageListCells, items: [
            MemoryUsageItem(kind: .cellImages, usedBytes: 1 << 40),
        ])
        for _ in 0..<5 { #expect(detector.evaluate(input(memory: [owner])).isEmpty) }
    }

    // MARK: - 先読み

    @Test("先読みが設定より広ければ、持続を待たずにすぐ異常")
    func prefetchingBeyondTheRadiusIsReportedImmediately() {
        let detector = ResourceAnomalyDetector()
        // 現在ページ 50、設定 3 ―― 54 は範囲の外。
        let snapshot = Factory.snapshot(
            statistics: Factory.statistics(prefetching: [54]), currentIndex: 50, prefetchRadius: 3
        )
        #expect(detector.evaluate(input(book: snapshot)) == [.prefetchWiderThanSetting])
    }

    @Test("設定の範囲内の先読みは異常ではない")
    func prefetchingInsideTheRadiusIsNormal() {
        let detector = ResourceAnomalyDetector()
        let snapshot = Factory.snapshot(
            statistics: Factory.statistics(prefetching: [47, 48, 49, 51, 52, 53]),
            currentIndex: 50, prefetchRadius: 3
        )
        #expect(detector.evaluate(input(book: snapshot)).isEmpty)
    }

    @Test("判定に使うのは走っている先読みだけ ―― 残留しているページは何枚あっても正常")
    func residentPagesOutsideTheRadiusAreNotAnAnomaly() {
        let detector = ResourceAnomalyDetector()
        // 上限内に収まったまま、ずっと前のページまでキャッシュに残っている状態(既読のぶん)。
        let keys = Set(Factory.pageIDs(100).prefix(51))
        let statistics = Factory.statistics(pageImages: (50, 100, keys))
        let snapshot = Factory.snapshot(statistics: statistics, currentIndex: 50, prefetchRadius: 3)
        #expect(snapshot.residentBefore == 50)
        for _ in 0..<5 { #expect(detector.evaluate(input(book: snapshot, memory: book(statistics))).isEmpty) }
    }

    // MARK: - ディスクキャッシュ

    @Test("OFF なのにファイルが残っていれば異常。OFF で 0 なら正常")
    func filesLeftBehindWithTheDiskCacheOffAreAnAnomaly() {
        let detector = ResourceAnomalyDetector()
        #expect(detector.evaluate(input(storage: Factory.storage(thumbnailCacheBytes: 1),
                                        isDiskCacheEnabled: false)) == [.diskCacheDisabledButPresent])
        #expect(detector.evaluate(input(storage: Factory.storage(thumbnailCacheBytes: 0),
                                        isDiskCacheEnabled: false)).isEmpty)
        // 測れなかった(フォルダが無い)ときは何も言わない。
        #expect(detector.evaluate(input(storage: Factory.storage(thumbnailCacheBytes: nil),
                                        isDiskCacheEnabled: false)).isEmpty)
    }

    @Test("ディスクキャッシュの境目は上限 + 刈り込みの余裕(本体が許している範囲は異常にしない)")
    func theDiskCacheLimitIncludesTheTrimSlack() {
        let detector = ResourceAnomalyDetector()
        let limit = 1_000_000
        let slack = ThumbnailDiskCache.trimThreshold(for: limit)
        #expect(slack > 0)
        // 上限は超えているが、本体はまだ刈り込まなくてよいと判断する範囲。
        #expect(detector.evaluate(input(storage: Factory.storage(thumbnailCacheBytes: limit + slack),
                                        diskCacheLimitBytes: limit)).isEmpty)
        #expect(detector.evaluate(input(storage: Factory.storage(thumbnailCacheBytes: limit + slack + 1),
                                        diskCacheLimitBytes: limit)) == [.diskCacheOverLimit])
    }

    @Test("ディスクキャッシュの上限超過は持続を待たない(走査そのものが 30 秒に 1 回)")
    func theDiskCacheAnomalyIsReportedOnTheFirstScan() {
        let detector = ResourceAnomalyDetector()
        let limit = 1_000
        let over = limit + ThumbnailDiskCache.trimThreshold(for: limit) + 1
        #expect(detector.evaluate(input(storage: Factory.storage(thumbnailCacheBytes: over),
                                        diskCacheLimitBytes: limit)) == [.diskCacheOverLimit])
    }

    @Test("ファイルブラウザのディスクキャッシュも、OFF なのに残っている・上限 + 余裕を超えたら異常")
    func theFileBrowserDiskCacheIsCheckedLikeThePageThumbnails() {
        let detector = ResourceAnomalyDetector()
        #expect(detector.evaluate(input(storage: Factory.storage(fileBrowserThumbnailCacheBytes: 1),
                                        isFileBrowserCacheEnabled: false)) == [.fileBrowserCacheDisabledButPresent])
        let limit = 1_000_000
        let slack = ThumbnailDiskCache.trimThreshold(for: limit)
        #expect(detector.evaluate(input(storage: Factory.storage(fileBrowserThumbnailCacheBytes: limit + slack),
                                        fileBrowserCacheLimitBytes: limit)).isEmpty)
        #expect(detector.evaluate(input(storage: Factory.storage(fileBrowserThumbnailCacheBytes: limit + slack + 1),
                                        fileBrowserCacheLimitBytes: limit)) == [.fileBrowserCacheOverLimit])
    }

    @Test("ページ一覧のキャッシュとコレクションのタイルは、上限の 2 倍を超えたときだけ(刈り込みの間に超えるのは仕様)")
    func intermittentlyTrimmedCachesAreReportedOnlyFarOverTheLimit() {
        let detector = ResourceAnomalyDetector()
        let pageLists = BookPageListCache.maxTotalBytes
        let tiles = CollectionTileImageStore.maxTotalBytes
        #expect(detector.evaluate(input(storage: Factory.storage(
            pageListCacheBytes: pageLists * 2, collectionTileBytes: tiles * 2))).isEmpty)
        #expect(detector.evaluate(input(storage: Factory.storage(
            pageListCacheBytes: pageLists * 2 + 1, collectionTileBytes: tiles * 2 + 1)))
                == [.pageListCacheFarOverLimit, .collectionTilesFarOverLimit])
    }

    // MARK: - 一時ファイル

    @Test("他の起動が残した一時ファイルは 1 つでも異常(起動時に消えているはず)")
    func staleTemporaryFilesAreAlwaysAnAnomaly() {
        let detector = ResourceAnomalyDetector()
        #expect(detector.evaluate(input(storage: Factory.storage(staleTemporaryEntryCount: 1)))
                == [.staleTemporaryFiles])
    }

    @Test("「本を読んでいるものが無いのに入れ子の書庫の一時ファイル」は走査 2 回連続で成立したときだけ")
    func orphanTemporaryFilesNeedTwoConsecutiveScans() {
        let detector = ResourceAnomalyDetector()
        let first = Factory.storage(nestedTemporaryFileCount: 3, scannedAt: Date(timeIntervalSince1970: 100))
        let second = Factory.storage(nestedTemporaryFileCount: 3, scannedAt: Date(timeIntervalSince1970: 130))
        #expect(detector.evaluate(input(storage: first, bookReaderCount: 0)).isEmpty)
        #expect(detector.evaluate(input(storage: second, bookReaderCount: 0)) == [.orphanTemporaryFiles])
    }

    @Test("同じ走査結果を何度渡しても数は進まない(1 秒ごとの呼び出しで誤報しない)")
    func repeatingTheSameScanDoesNotAdvanceTheStreak() {
        let detector = ResourceAnomalyDetector()
        // 本を開いている最中は、BookLoader が展開した直後の一瞬だけ「読む側が無いのに一時ファイル」が
        // 正しく成立する。走査結果が同じうちは数えない。
        let scan = Factory.storage(nestedTemporaryFileCount: 3, scannedAt: Date(timeIntervalSince1970: 100))
        for _ in 0..<30 {
            #expect(detector.evaluate(input(storage: scan, bookReaderCount: 0)).isEmpty)
        }
    }

    @Test("途中で本が開けば数え直し")
    func openingABookResetsTheOrphanStreak() {
        let detector = ResourceAnomalyDetector()
        func scan(_ seconds: TimeInterval) -> StorageUsage {
            Factory.storage(nestedTemporaryFileCount: 3, scannedAt: Date(timeIntervalSince1970: seconds))
        }
        #expect(detector.evaluate(input(storage: scan(100), bookReaderCount: 0)).isEmpty)
        #expect(detector.evaluate(input(storage: scan(130), bookReaderCount: 1)).isEmpty)
        #expect(detector.evaluate(input(storage: scan(160), bookReaderCount: 0)).isEmpty)
        #expect(detector.evaluate(input(storage: scan(190), bookReaderCount: 0)) == [.orphanTemporaryFiles])
    }

    @Test("ネットワークボリュームの写しは、読み込み層が知っている数より多いまま走査 2 回続いたら異常")
    func networkCopiesUnknownToTheRegistryAreReportedAfterTwoScans() {
        let detector = ResourceAnomalyDetector()
        func scan(_ seconds: TimeInterval) -> StorageUsage {
            Factory.storage(stagedTemporaryFileCount: 2, scannedAt: Date(timeIntervalSince1970: seconds))
        }
        // 読み込み層が 2 つとも知っていれば(本を開いている・閉じた直後の猶予の間)正常。本が無くても入れ子の判定には入らない。
        #expect(detector.evaluate(input(storage: scan(100), bookReaderCount: 0, liveNetworkCopyCount: 2)).isEmpty)
        #expect(detector.evaluate(input(storage: scan(130), bookReaderCount: 0, liveNetworkCopyCount: 2)).isEmpty)
        #expect(detector.evaluate(input(storage: scan(160), liveNetworkCopyCount: 1)).isEmpty)
        #expect(detector.evaluate(input(storage: scan(190), liveNetworkCopyCount: 1)) == [.orphanNetworkCopies])
    }

    @Test("何も無ければ何も出ない")
    func aHealthyStateReportsNothing() {
        let detector = ResourceAnomalyDetector()
        let statistics = Factory.statistics(pageImages: (50, 100, []))
        let snapshot = Factory.snapshot(statistics: statistics)
        for _ in 0..<5 {
            #expect(detector.evaluate(input(book: snapshot, memory: book(statistics),
                                            storage: Factory.storage(thumbnailCacheBytes: 10)))
                    .isEmpty)
        }
    }
}

@MainActor
struct ResourceMonitorSnapshotTests {
    private typealias Factory = ResourceSnapshotFactory

    @Test("先読みの範囲外かどうかは、表示中のページからの距離で見る")
    func theRadiusIsMeasuredFromTheCurrentIndex() {
        let inside = Factory.snapshot(
            statistics: Factory.statistics(prefetching: [47, 53]), currentIndex: 50, prefetchRadius: 3)
        #expect(!inside.isPrefetchingBeyondRadius)
        let before = Factory.snapshot(
            statistics: Factory.statistics(prefetching: [46]), currentIndex: 50, prefetchRadius: 3)
        #expect(before.isPrefetchingBeyondRadius)
        let after = Factory.snapshot(
            statistics: Factory.statistics(prefetching: [54]), currentIndex: 50, prefetchRadius: 3)
        #expect(after.isPrefetchingBeyondRadius)
    }

    @Test("residentBefore は現在ページから前へ途切れずに残っている枚数")
    func residentBeforeCountsTheUnbrokenRun() {
        let ids = Factory.pageIDs(100)
        // 45〜49 が残っている(50 は現在ページ)。44 が欠けているので、そこで途切れる。
        let keys = Set(ids[45...49]).union([ids[43]])
        let snapshot = Factory.snapshot(
            statistics: Factory.statistics(pageImages: (10, 100, keys)), currentIndex: 50, prefetchRadius: 3)
        #expect(snapshot.residentBefore == 5)
    }

    @Test("帯が描くのは表示中のページの前後 radius だけ(それより外の残留は入れない)")
    func theResidentBandIsClippedToTheRadius() {
        let ids = Factory.pageIDs(100)
        let keys = Set(ids)  // 全ページが残っている
        let snapshot = Factory.snapshot(
            statistics: Factory.statistics(pageImages: (10, 100, keys)),
            currentIndex: 50, prefetchRadius: 2, displayedPageCount: 2)
        // 見開きなので後ろ側の基点は 51。48…53 の 6 つ。
        #expect(snapshot.residentIndicesAroundCurrent == Set(48...53))
    }

    @Test("表示中のページ数は最低 1(0 を渡されても帯が壊れない)")
    func theDisplayedPageCountIsAtLeastOne() {
        let snapshot = Factory.snapshot(statistics: Factory.statistics(), displayedPageCount: 0)
        #expect(snapshot.displayedPageCount == 1)
    }

    @Test("入れ子の書庫は、メモリの上のぶんとディスクのぶんを分けて持つ")
    func nestedArchivesKeepMemoryAndDiskApart() {
        var statistics = Factory.statistics()
        statistics.nestedArchives.inMemoryBytes = 7
        statistics.nestedArchives.temporaryBytes = 5000  // ディスク上
        let snapshot = Factory.snapshot(statistics: statistics)
        #expect(snapshot.nestedArchives.usedBytes == 7)
        #expect(snapshot.nestedArchiveTemporaryBytes == 5000)
    }

    @Test("上限が 0 なら割合は 0(0 除算にしない)")
    func aZeroLimitYieldsAZeroFraction() {
        let usage = ResourceMonitorSnapshot.CacheUsage(usedBytes: 10, limitBytes: 0, count: 1)
        #expect(usage.fraction == 0)
        #expect(ResourceMonitorSnapshot.CacheUsage(usedBytes: 50, limitBytes: 100, count: 1).fraction == 0.5)
    }
}

struct ResourceHistoryTests {
    private func sample(_ second: Int, cpu: Double = 0, footprint: Int = 0,
                        read: Double = 0, write: Double = 0) -> ResourceSample {
        ResourceSample(
            timestamp: Date(timeIntervalSince1970: TimeInterval(second)), cpuPercent: cpu,
            physicalFootprint: footprint, diskReadBytesPerSecond: read, diskWriteBytesPerSecond: write
        )
    }

    @Test("2 段の容量は 1 秒 × 2 分と 10 秒 × 1 時間")
    func theTwoTiersCoverTwoMinutesAndOneHour() {
        #expect(ResourceHistory.fineCapacity == 120)
        #expect(ResourceHistory.coarseBucketSize == 10)
        #expect(ResourceHistory.coarseCapacity == 360)
        #expect(ResourceHistory.coarseCapacity * ResourceHistory.coarseBucketSize == 3600)
    }

    @Test("細かい側は容量を超えたら古い方から捨てる")
    func theFineTierDropsTheOldestSamples() {
        var history = ResourceHistory()
        for second in 0..<(ResourceHistory.fineCapacity + 25) { history.append(sample(second)) }
        #expect(history.fine.count == ResourceHistory.fineCapacity)
        #expect(history.fine.first?.timestamp == Date(timeIntervalSince1970: 25))
        #expect(history.fine.last?.timestamp == Date(timeIntervalSince1970: 144))
    }

    @Test("粗い側は 10 個たまるごとに 1 点だけ増える")
    func theCoarseTierAdvancesOncePerBucket() {
        var history = ResourceHistory()
        for second in 0..<9 { history.append(sample(second)) }
        #expect(history.coarse.isEmpty)
        history.append(sample(9))
        #expect(history.coarse.count == 1)
        for second in 10..<19 { history.append(sample(second)) }
        #expect(history.coarse.count == 1)
        history.append(sample(19))
        #expect(history.coarse.count == 2)
    }

    @Test("速度は平均、footprint と時刻は区間末の値")
    func theCoarseSampleAveragesRatesButNotAmounts() throws {
        var history = ResourceHistory()
        for second in 0..<10 {
            history.append(sample(second, cpu: Double(second), footprint: second * 100,
                                  read: Double(second) * 2, write: Double(second) * 4))
        }
        let point = try #require(history.coarse.first)
        #expect(point.cpuPercent == 4.5)              // 0…9 の平均
        #expect(point.diskReadBytesPerSecond == 9)    // (0…9)*2 の平均
        #expect(point.diskWriteBytesPerSecond == 18)  // (0…9)*4 の平均
        #expect(point.physicalFootprint == 900)       // 区間末の値(量なので平均しない)
        #expect(point.timestamp == Date(timeIntervalSince1970: 9))
    }

    @Test("粗い側も容量を超えたら古い方から捨てる")
    func theCoarseTierDropsTheOldestBuckets() {
        var history = ResourceHistory()
        let total = (ResourceHistory.coarseCapacity + 3) * ResourceHistory.coarseBucketSize
        for second in 0..<total { history.append(sample(second)) }
        #expect(history.coarse.count == ResourceHistory.coarseCapacity)
        // 最初の 3 バケツ(区間末は 9・19・29 秒)が落ちて、39 秒から始まる。
        #expect(history.coarse.first?.timestamp == Date(timeIntervalSince1970: 39))
        #expect(history.coarse.last?.timestamp == Date(timeIntervalSince1970: TimeInterval(total - 1)))
    }

    @Test("作りたては空(計測を止めるたびにここから始まる)")
    func aFreshHistoryIsEmpty() {
        let history = ResourceHistory()
        #expect(history.fine.isEmpty)
        #expect(history.coarse.isEmpty)
    }

    @Test("2 つの読み値の差から作る 1 点は、区間の速度と区間末の絶対値")
    func aSampleIsTheDeltaBetweenTwoReadings() {
        let previous = ProcessResourceReading(
            timestamp: Date(timeIntervalSince1970: 100), cpuTime: 10, physicalFootprint: 1000,
            lifetimeMaxFootprint: 2000, diskBytesRead: 500, diskBytesWritten: 100)
        let current = ProcessResourceReading(
            timestamp: Date(timeIntervalSince1970: 102), cpuTime: 13, physicalFootprint: 1500,
            lifetimeMaxFootprint: 2000, diskBytesRead: 2500, diskBytesWritten: 100)
        let sample = ResourceSample(from: previous, to: current)
        #expect(sample.timestamp == current.timestamp)
        #expect(sample.cpuPercent == 150)  // 2 秒で 3 秒ぶん = 1.5 コア
        #expect(sample.physicalFootprint == 1500)
        #expect(sample.diskReadBytesPerSecond == 1000)
        #expect(sample.diskWriteBytesPerSecond == 0)
    }

    @Test("累積値が巻き戻って見えても負の速度にはしない")
    func aNegativeDeltaIsClampedToZero() {
        let previous = ProcessResourceReading(
            timestamp: Date(timeIntervalSince1970: 100), cpuTime: 10, physicalFootprint: 1000,
            lifetimeMaxFootprint: 2000, diskBytesRead: 500, diskBytesWritten: 500)
        let current = ProcessResourceReading(
            timestamp: Date(timeIntervalSince1970: 101), cpuTime: 9, physicalFootprint: 900,
            lifetimeMaxFootprint: 2000, diskBytesRead: 400, diskBytesWritten: 400)
        let sample = ResourceSample(from: previous, to: current)
        #expect(sample.cpuPercent == 0)
        #expect(sample.diskReadBytesPerSecond == 0)
        #expect(sample.diskWriteBytesPerSecond == 0)
    }

    @Test("同じ時刻の 2 点でも 0 除算にならない")
    func twoReadingsAtTheSameInstantDoNotDivideByZero() {
        let reading = ProcessResourceReading(
            timestamp: Date(timeIntervalSince1970: 100), cpuTime: 10, physicalFootprint: 1000,
            lifetimeMaxFootprint: 2000, diskBytesRead: 500, diskBytesWritten: 500)
        let sample = ResourceSample(from: reading, to: reading)
        #expect(sample.cpuPercent == 0)
        #expect(sample.diskReadBytesPerSecond == 0)
        #expect(sample.diskWriteBytesPerSecond.isFinite)
    }
}

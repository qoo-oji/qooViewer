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
        staleTemporaryEntryCount: Int = 0,
        sessionTemporaryFileCount: Int = 0,
        scannedAt: Date = Date()
    ) -> StorageUsage {
        StorageUsage(
            containerBytes: nil, sessionTemporaryBytes: 0,
            sessionTemporaryFileCount: sessionTemporaryFileCount,
            staleTemporaryBytes: 0, staleTemporaryEntryCount: staleTemporaryEntryCount,
            thumbnailCacheBytes: thumbnailCacheBytes, pageListCacheBytes: nil, databaseBytes: nil,
            scannedAt: scannedAt
        )
    }
}

@MainActor
struct ResourceAnomalyDetectorTests {
    private typealias Factory = ResourceSnapshotFactory

    private func input(
        book: ResourceMonitorSnapshot? = nil,
        storage: StorageUsage? = nil,
        isDiskCacheEnabled: Bool = true,
        diskCacheLimitBytes: Int = 1_000_000,
        openBookCount: Int = 1
    ) -> ResourceAnomalyDetector.Input {
        .init(
            bookSnapshot: book, storage: storage, isDiskCacheEnabled: isDiskCacheEnabled,
            diskCacheLimitBytes: diskCacheLimitBytes, openBookCount: openBookCount
        )
    }

    // MARK: - メモリキャッシュの上限超過

    @Test("上限ちょうどは異常ではない(超えたときだけ数え始める)")
    func beingExactlyAtTheLimitIsNormal() {
        let detector = ResourceAnomalyDetector()
        let atLimit = Factory.snapshot(statistics: Factory.statistics(pageImages: (100, 100, [])))
        for _ in 0..<10 {
            #expect(detector.evaluate(input(book: atLimit)).isEmpty)
        }
    }

    @Test("上限超過は 3 回(3 秒)続いたときだけ異常にする")
    func anOverLimitCacheMustPersistForThreeEvaluations() {
        let detector = ResourceAnomalyDetector()
        let over = Factory.snapshot(statistics: Factory.statistics(pageImages: (101, 100, [])))
        #expect(ResourceAnomalyDetector.persistenceThreshold == 3)
        #expect(detector.evaluate(input(book: over)).isEmpty)
        #expect(detector.evaluate(input(book: over)).isEmpty)
        #expect(detector.evaluate(input(book: over)) == [.pageImageCacheOverLimit])
        // 一度成立したら、続く限り出続ける。
        #expect(detector.evaluate(input(book: over)) == [.pageImageCacheOverLimit])
    }

    @Test("途中で収まったら数え直し(瞬間的な超過で鳴らさない)")
    func aSingleFrameOfOverLimitResetsTheStreak() {
        let detector = ResourceAnomalyDetector()
        let over = Factory.snapshot(statistics: Factory.statistics(pageImages: (101, 100, [])))
        let normal = Factory.snapshot(statistics: Factory.statistics(pageImages: (50, 100, [])))
        #expect(detector.evaluate(input(book: over)).isEmpty)
        #expect(detector.evaluate(input(book: over)).isEmpty)
        #expect(detector.evaluate(input(book: normal)).isEmpty)
        #expect(detector.evaluate(input(book: over)).isEmpty)
        #expect(detector.evaluate(input(book: over)).isEmpty)
        #expect(detector.evaluate(input(book: over)) == [.pageImageCacheOverLimit])
    }

    @Test("3 種類のキャッシュはそれぞれ別に数える")
    func eachCacheHasItsOwnStreak() {
        let detector = ResourceAnomalyDetector()
        let statistics = Factory.statistics(
            pageImages: (101, 100, []), thumbnails: (101, 100), gridThumbnails: (101, 100)
        )
        let snapshot = Factory.snapshot(statistics: statistics)
        _ = detector.evaluate(input(book: snapshot))
        _ = detector.evaluate(input(book: snapshot))
        #expect(Set(detector.evaluate(input(book: snapshot)))
                == [.pageImageCacheOverLimit, .thumbnailCacheOverLimit, .gridThumbnailCacheOverLimit])
    }

    @Test("本を閉じたら持続回数は捨てる(次に開いた本へ持ち越さない)")
    func closingTheBookClearsTheStreaks() {
        let detector = ResourceAnomalyDetector()
        let over = Factory.snapshot(statistics: Factory.statistics(pageImages: (101, 100, [])))
        _ = detector.evaluate(input(book: over))
        _ = detector.evaluate(input(book: over))
        #expect(detector.evaluate(input(book: nil)).isEmpty)
        // 数え直しになるので、再び 3 回必要。
        #expect(detector.evaluate(input(book: over)).isEmpty)
        #expect(detector.evaluate(input(book: over)).isEmpty)
        #expect(detector.evaluate(input(book: over)) == [.pageImageCacheOverLimit])
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
        let snapshot = Factory.snapshot(
            statistics: Factory.statistics(pageImages: (50, 100, keys)), currentIndex: 50, prefetchRadius: 3
        )
        #expect(snapshot.residentBefore == 50)
        for _ in 0..<5 { #expect(detector.evaluate(input(book: snapshot)).isEmpty) }
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

    // MARK: - 一時ファイル

    @Test("他の起動が残した一時ファイルは 1 つでも異常(起動時に消えているはず)")
    func staleTemporaryFilesAreAlwaysAnAnomaly() {
        let detector = ResourceAnomalyDetector()
        #expect(detector.evaluate(input(storage: Factory.storage(staleTemporaryEntryCount: 1)))
                == [.staleTemporaryFiles])
    }

    @Test("「本が 0 冊なのに一時ファイル」は走査 2 回連続で成立したときだけ")
    func orphanTemporaryFilesNeedTwoConsecutiveScans() {
        let detector = ResourceAnomalyDetector()
        let first = Factory.storage(sessionTemporaryFileCount: 3, scannedAt: Date(timeIntervalSince1970: 100))
        let second = Factory.storage(sessionTemporaryFileCount: 3, scannedAt: Date(timeIntervalSince1970: 130))
        #expect(detector.evaluate(input(storage: first, openBookCount: 0)).isEmpty)
        #expect(detector.evaluate(input(storage: second, openBookCount: 0)) == [.orphanTemporaryFiles])
    }

    @Test("同じ走査結果を何度渡しても数は進まない(1 秒ごとの呼び出しで誤報しない)")
    func repeatingTheSameScanDoesNotAdvanceTheStreak() {
        let detector = ResourceAnomalyDetector()
        // 本を開いている最中は、BookLoader が展開した直後の一瞬だけ「0 冊なのに一時ファイル」が
        // 正しく成立する。走査結果が同じうちは数えない。
        let scan = Factory.storage(sessionTemporaryFileCount: 3, scannedAt: Date(timeIntervalSince1970: 100))
        for _ in 0..<30 {
            #expect(detector.evaluate(input(storage: scan, openBookCount: 0)).isEmpty)
        }
    }

    @Test("途中で本が開けば数え直し")
    func openingABookResetsTheOrphanStreak() {
        let detector = ResourceAnomalyDetector()
        func scan(_ seconds: TimeInterval) -> StorageUsage {
            Factory.storage(sessionTemporaryFileCount: 3, scannedAt: Date(timeIntervalSince1970: seconds))
        }
        #expect(detector.evaluate(input(storage: scan(100), openBookCount: 0)).isEmpty)
        #expect(detector.evaluate(input(storage: scan(130), openBookCount: 1)).isEmpty)
        #expect(detector.evaluate(input(storage: scan(160), openBookCount: 0)).isEmpty)
        #expect(detector.evaluate(input(storage: scan(190), openBookCount: 0)) == [.orphanTemporaryFiles])
    }

    @Test("何も無ければ何も出ない")
    func aHealthyStateReportsNothing() {
        let detector = ResourceAnomalyDetector()
        let snapshot = Factory.snapshot(statistics: Factory.statistics(pageImages: (50, 100, [])))
        for _ in 0..<5 {
            #expect(detector.evaluate(input(book: snapshot, storage: Factory.storage(thumbnailCacheBytes: 10)))
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

    @Test("説明のつくメモリはピクセルキャッシュ 3 つとメモリ上の入れ子の書庫の合計")
    func theExplainedMemoryIsTheSumOfTheFourBudgets() {
        var statistics = Factory.statistics(
            pageImages: (100, 1000, []), thumbnails: (20, 1000), gridThumbnails: (3, 1000))
        statistics.nestedArchives.inMemoryBytes = 7
        statistics.nestedArchives.temporaryBytes = 5000  // ディスク上なので足さない
        let snapshot = Factory.snapshot(statistics: statistics)
        #expect(snapshot.totalCacheBytes == 130)
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

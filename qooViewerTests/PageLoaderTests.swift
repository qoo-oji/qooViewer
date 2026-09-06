import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// ページ画像の読み出し役(Services/PageLoader.swift)。本 1 冊につき 1 つの `actor`。
///
/// **`usesThumbnailDiskCache: false` を必ず渡すこと** ―― 既定の `true` は
/// `ThumbnailDiskCache.shared`(実物のアプリと同じコンテナのフォルダ)へ書きに行く。
/// 拡大サムネイルも `usesDiskCache: false` を明示する。ここで見るのはメモリ側だけ:
/// キャッシュの出入りと上限、先読みの範囲、寸法の取得、書き出し用の生データ。
@MainActor
struct PageLoaderTests {
    private struct Source {
        let temporary: TemporaryDirectory
        let book: MangaBook
    }

    /// 縦長のページが `pageCount` 枚並んだフォルダの本(R = ページ番号)。
    private func makeSource(_ label: String, pageCount: Int = 8,
                            fileExtension: String = "png") async throws -> Source {
        let temporary = try TemporaryDirectory(label)
        let directory = temporary.file("book")
        try FixtureFolder.make(at: directory, pages: (1...pageCount).map {
            FixtureFolder.Page(String(format: "p%02d.\(fileExtension)", $0), number: UInt8($0))
        })
        return Source(temporary: temporary, book: try await FixtureBook.load(directory))
    }

    private func makeLoader(_ book: MangaBook, imageCacheLimitBytes: Int = 8 * 1024 * 1024) -> PageLoader {
        PageLoader(book: book, usesThumbnailDiskCache: false, imageCacheLimitBytes: imageCacheLimitBytes)
    }

    // MARK: - ページ画像

    @Test("ページ番号どおりの画像が返る")
    func eachIndexYieldsItsOwnPage() async throws {
        let source = try await makeSource("loader-pages")
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        for index in 0..<source.book.pages.count {
            let image = try #require(await loader.pageImage(at: index))
            #expect(PageColorReader.number(in: image) == index + 1)
        }
    }

    @Test("範囲外の番号は nil(落ちない)")
    func anOutOfRangeIndexReturnsNil() async throws {
        let source = try await makeSource("loader-range", pageCount: 3)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        #expect(await loader.pageImage(at: -1) == nil)
        #expect(await loader.pageImage(at: 3) == nil)
        #expect(await loader.pageSize(at: 99) == nil)
        #expect(await loader.rawImageData(at: -1) == nil)
    }

    @Test("読んだページはメモリキャッシュに残る")
    func aLoadedPageStaysInTheMemoryCache() async throws {
        let source = try await makeSource("loader-cache", pageCount: 4)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        #expect(await loader.cacheStatistics().pageImages.count == 0)
        _ = await loader.pageImage(at: 0)
        _ = await loader.pageImage(at: 1)
        let statistics = await loader.cacheStatistics()
        #expect(statistics.pageImages.count == 2)
        #expect(statistics.pageImages.totalBytes > 0)
        #expect(statistics.pageImages.keys == Set(source.book.pages[0...1].map(\.id)))
    }

    @Test("同じページを何度読んでもキャッシュは 1 件のまま")
    func loadingTheSamePageTwiceDoesNotDuplicateIt() async throws {
        let source = try await makeSource("loader-dedupe", pageCount: 2)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        _ = await loader.pageImage(at: 0)
        let firstBytes = await loader.cacheStatistics().pageImages.totalBytes
        _ = await loader.pageImage(at: 0)
        _ = await loader.pageImage(at: 0)
        let statistics = await loader.cacheStatistics()
        #expect(statistics.pageImages.count == 1)
        #expect(statistics.pageImages.totalBytes == firstBytes)
    }

    @Test("同じページへの同時の要求はまとめられる(デコードは 1 回)")
    func concurrentRequestsForTheSamePageAreDeduplicated() async throws {
        let source = try await makeSource("loader-concurrent", pageCount: 2)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        async let a = loader.pageImage(at: 0)
        async let b = loader.pageImage(at: 0)
        async let c = loader.pageImage(at: 0)
        let images = await [a, b, c]
        #expect(images.allSatisfy { $0 != nil })
        #expect(await loader.cacheStatistics().pageImages.count == 1)
    }

    @Test("上限を下げるとその場で追い出される")
    func loweringTheLimitEvictsImmediately() async throws {
        let source = try await makeSource("loader-limit", pageCount: 6)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        for index in 0..<6 { _ = await loader.pageImage(at: index) }
        let before = await loader.cacheStatistics()
        #expect(before.pageImages.count == 6)

        // 1 枚ぶんにも満たない上限。「1 枚だけは残す」仕様どおり 1 件までは残りうる。
        await loader.setImageCacheLimit(bytes: 1)
        let after = await loader.cacheStatistics()
        #expect(after.pageImageLimitBytes == 1)
        #expect(after.pageImages.count <= 1)
        #expect(after.pageImages.totalBytes < before.pageImages.totalBytes)
    }

    @Test("解放するとメモリキャッシュは空になる")
    func releasingClearsEveryCache() async throws {
        let source = try await makeSource("loader-release", pageCount: 3)
        let loader = makeLoader(source.book)

        _ = await loader.pageImage(at: 0)
        _ = await loader.thumbnail(at: 0)
        #expect(await loader.cacheStatistics().pageImages.count == 1)

        await loader.releaseAllResources()
        let statistics = await loader.cacheStatistics()
        #expect(statistics.pageImages.count == 0)
        #expect(statistics.thumbnails.count == 0)
        #expect(statistics.gridThumbnails.count == 0)
    }

    // MARK: - サムネイル

    @Test("進捗バー用サムネイルは別のキャッシュに入る")
    func thumbnailsUseTheirOwnCache() async throws {
        let source = try await makeSource("loader-thumb", pageCount: 3)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        #expect(await loader.thumbnail(at: 0) != nil)
        let statistics = await loader.cacheStatistics()
        #expect(statistics.thumbnails.count == 1)
        #expect(statistics.pageImages.count == 0)  // ページ画像の側は増えない
    }

    @Test("拡大サムネイルは指定した長辺に収まる(小さい画像は拡大しない)")
    func gridThumbnailsFitTheRequestedSize() async throws {
        let source = try await makeSource("loader-grid", pageCount: 2)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        let image = try #require(await loader.gridThumbnail(at: 0, maxPixelSize: 4, usesDiskCache: false))
        #expect(max(image.width, image.height) <= 4)

        // 元が 8x12 なので、それより大きい指定では引き伸ばさない。
        let big = try #require(await loader.gridThumbnail(at: 1, maxPixelSize: 512, usesDiskCache: false))
        #expect(big.width == PageImageFactory.width)
        #expect(big.height == PageImageFactory.height)
    }

    @Test("拡大サムネイルのキャッシュの鍵は寸法ごとに別(同じページでも 2 件になる)")
    func gridThumbnailsAreCachedPerSize() async throws {
        let source = try await makeSource("loader-grid-key", pageCount: 2)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        _ = await loader.gridThumbnail(at: 0, maxPixelSize: 4, usesDiskCache: false)
        _ = await loader.gridThumbnail(at: 0, maxPixelSize: 6, usesDiskCache: false)
        #expect(await loader.cacheStatistics().gridThumbnails.count == 2)
    }

    // MARK: - 寸法

    @Test("ページの寸法はヘッダーだけで分かる(縦長・横長を見分けられる)")
    func thePageSizeComesFromTheHeader() async throws {
        let temporary = try TemporaryDirectory("loader-size")
        let directory = temporary.file("book")
        try FixtureFolder.make(at: directory, pages: [
            .init("p01.png", number: 1),
            .init("p02.png", number: 2, wide: true),
        ])
        let book = try await FixtureBook.load(directory)
        let loader = makeLoader(book)
        defer { Task { await loader.releaseAllResources() } }

        let tall = try #require(await loader.pageSize(at: 0))
        #expect(tall.width == PageImageFactory.width && tall.height == PageImageFactory.height)
        let wide = try #require(await loader.pageSize(at: 1))
        #expect(wide.width == PageImageFactory.wideWidth && wide.height == PageImageFactory.height)
        #expect(wide.width > wide.height)
    }

    @Test("寸法を測ってもページ画像のキャッシュは太らない")
    func measuringDoesNotFillThePageImageCache() async throws {
        let source = try await makeSource("loader-size-cache", pageCount: 4)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        for index in 0..<4 { _ = await loader.pageSize(at: index) }
        #expect(await loader.cacheStatistics().pageImages.count == 0)
    }

    // MARK: - 書き出し用の生データ

    @Test("生データは元のファイルのバイト列そのもの(再エンコードしない)")
    func theRawDataIsTheOriginalFile() async throws {
        let source = try await makeSource("loader-raw", pageCount: 2)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        let data = try #require(await loader.rawImageData(at: 1))
        let onDisk = try Data(contentsOf: source.temporary.file("book/p02.png"))
        #expect(data == onDisk)
        #expect(PageColorReader.number(in: data) == 2)
    }

    @Test("書き出し用の拡張子は元のページの形式", arguments: ["png", "jpg"])
    func theExportableExtensionFollowsTheSource(fileExtension: String) async throws {
        let source = try await makeSource("loader-export-\(fileExtension)", pageCount: 1,
                                          fileExtension: fileExtension)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        #expect(try await loader.exportableImageFileExtension(at: 0) == fileExtension)
        let exported = try #require(try await loader.exportableImage(at: 0))
        #expect(exported.fileExtension == fileExtension)
        #expect(PageColorReader.matches(exported.data, number: 1))
    }

    // MARK: - 先読み

    @Test("先読みは進行方向の前後 radius 枚をキャッシュへ入れる")
    func prefetchingFillsTheNeighbourhood() async throws {
        let source = try await makeSource("loader-prefetch", pageCount: 12)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        _ = await loader.pageImage(at: 5)
        await loader.prefetch(around: 5, radius: 2, displayedPageCount: 1)
        // 先読みのタスクが片付くまで待つ ―― 時間ではなく、走っているタスクが無くなることで見る。
        try await waitForPrefetchToSettle(loader)

        let keys = await loader.cacheStatistics().pageImages.keys
        let ids = source.book.pages.map(\.id)
        for index in 3...7 {
            #expect(keys.contains(ids[index]), "ページ \(index) が先読みされていない")
        }
        // 範囲の外までは読まない。
        #expect(!keys.contains(ids[0]))
        #expect(!keys.contains(ids[11]))
    }

    @Test("先読み中のページは統計に出る(異常判定がこれを見る)")
    func inFlightPrefetchesAreVisibleInTheStatistics() async throws {
        let source = try await makeSource("loader-prefetch-stats", pageCount: 12)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        await loader.prefetch(around: 5, radius: 2, displayedPageCount: 1)
        try await waitForPrefetchToSettle(loader)
        // 走り終われば空に戻る(残り続けると「設定より広く先読み」の誤報になる)。
        #expect(await loader.cacheStatistics().prefetchingIndices.isEmpty)
    }

    /// 走っている先読みタスクが無くなるまで待つ。**時間で待たないこと**(段階 2 の教訓)。
    private func waitForPrefetchToSettle(_ loader: PageLoader) async throws {
        for _ in 0..<200 {
            if await loader.cacheStatistics().prefetchingIndices.isEmpty { return }
            await Task.yield()
        }
        Issue.record("先読みが終わらない")
    }

    // MARK: - 本の差し替え

    @Test("ページ一覧を差し替えると、新しい並びで読める")
    func updatingTheBookSwapsThePageList() async throws {
        let source = try await makeSource("loader-update", pageCount: 4)
        let loader = makeLoader(source.book)
        defer { Task { await loader.releaseAllResources() } }

        #expect(PageColorReader.number(in: try #require(await loader.pageImage(at: 0))) == 1)

        // ビューアが並べ替え・除外を反映するときと同じ形 ―― ページ一覧だけ差し替えた本を渡す。
        var reordered = source.book
        reordered.pages = source.book.pages.reversed()
        await loader.updateBook(reordered)
        #expect(PageColorReader.number(in: try #require(await loader.pageImage(at: 0))) == 4)
    }
}

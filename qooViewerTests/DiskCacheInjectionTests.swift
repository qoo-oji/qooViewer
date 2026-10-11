import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// ディスクキャッシュを差し替える口(Services/BookDiskCaches.swift)を通した、キャッシュの経路そのもの。
///
/// 2026-10-11 まで、これらの経路はテストで一度も走っていなかった ―― テストは利用者のキャッシュへ書かないために
/// `cachesPageList: false` / `usesThumbnailDiskCache: false` / `usesDiskCaches: false` で経路ごと止めていたため。
/// ここでは作業フォルダの中のキャッシュ(`BookDiskCaches(directory:)`)を渡して経路を通す。**`.shared` は使わない。**
@MainActor
struct DiskCacheInjectionTests {
    // MARK: - 材料

    /// 縦長のページが `pageCount` 枚入った zip の本(R = ページ番号)。
    private func makeZipBook(in temporary: TemporaryDirectory, named name: String = "book.cbz", pageCount: Int = 3) throws -> URL {
        var builder = ZipFixtureBuilder()
        for number in 1...pageCount {
            builder.add(String(format: "p%02d.png", number), PageImageFactory.png(number: UInt8(number)))
        }
        let url = temporary.file(name)
        try builder.write(to: url)
        return url
    }

    /// ページ一覧をキャッシュへ書き戻す読み込み。書き終えるまで待つ。
    private func loadCaching(_ url: URL, caches: BookDiskCaches) async throws -> MangaBook {
        let stored = OneShotSignal()
        let book = try await BookLoader.load(
            from: url, cachesPageList: true, caches: caches, onPageListStored: { stored.fire() }
        )
        #expect(await stored.wait(), "ページ一覧の書き戻しが終わらない")
        return book
    }

    private func thumbnailKey(for book: MangaBook) -> ThumbnailDiskCache.BookKey {
        ThumbnailDiskCache.BookKey(
            sourceURL: book.sourceURL, bookID: book.id, contrastCorrectionEnabled: false,
            maxPixelSize: ImageDecoder.progressBarThumbnailMaxPixelSize
        )
    }

    // MARK: - BookLoader: ページ一覧と構造キャッシュ

    @Test("読み込んだ本のページ一覧は、渡したキャッシュへ書き戻される")
    func loadStoresPageListInInjectedCache() async throws {
        let temporary = try TemporaryDirectory("cache-store")
        let caches = BookDiskCaches(directory: temporary.file("caches"))
        let url = try makeZipBook(in: temporary)

        let book = try await loadCaching(url, caches: caches)

        let entry = try #require(await caches.pageLists.pageList(forBookID: book.id))
        #expect(entry.pages.map(\.sortKey) == book.pages.map(\.sortKey))
        #expect(entry.rootPath == url.path)
        #expect(entry.fingerprint == BookPageListCache.Entry.Fingerprint.current(for: url))
        // 平な zip は高速経路の対象外(入れ子の書庫を含む本だけ)。
        #expect(entry.hasNestedArchives == false)
    }

    @Test("cachesPageList: false の読み込みは、キャッシュを渡しても書かない(シークレットの約束)")
    func loadWithoutCachingLeavesInjectedCacheEmpty() async throws {
        let temporary = try TemporaryDirectory("cache-off")
        let caches = BookDiskCaches(directory: temporary.file("caches"))
        let url = try makeZipBook(in: temporary)

        let book = try await BookLoader.load(from: url, cachesPageList: false, caches: caches)

        // 書かない側は裏の仕事を投げもしないので、待たずに確かめてよい。
        #expect(await caches.pageLists.pageList(forBookID: book.id) == nil)
    }

    @Test("入れ子の書庫を含む本は、2 回目からは構造キャッシュから組み立て直し、本体が変われば読み直す")
    func nestedBookIsRestoredFromStructureCacheUntilTheFileChanges() async throws {
        let temporary = try TemporaryDirectory("cache-structure")
        let caches = BookDiskCaches(directory: temporary.file("caches"))
        let url = temporary.file("nested.cbz")
        try FileManager.default.copyItem(at: Fixtures.url("nested/nested-zip-in-zip.cbz"), to: url)

        let first = try await loadCaching(url, caches: caches)
        let entry = try #require(await caches.pageLists.pageList(forBookID: first.id))
        #expect(entry.hasNestedArchives == true)

        // 復元の経路を通ったことが分かるよう、保存されている先頭ページの sortKey だけを書き換える
        // (フルの読み込みなら書庫から読んだ本来の値になる)。
        let marker = "restored-from-structure-cache"
        var pages = entry.pages
        let original = pages[0]
        pages[0] = BookPageListCache.Entry.Page(
            sortKey: marker, displayName: original.displayName, folderPath: original.folderPath,
            idSuffix: original.idSuffix, nestedPath: original.nestedPath, entryPath: original.entryPath,
            spreadPosition: original.spreadPosition
        )
        let tampered = BookPageListCache.Entry(
            pages: pages, schemaVersion: entry.schemaVersion, rootPath: entry.rootPath,
            fingerprint: entry.fingerprint, hasNestedArchives: entry.hasNestedArchives
        )
        await caches.pageLists.store(tampered, forBookID: first.id)

        let restored = try await BookLoader.load(from: url, cachesPageList: true, caches: caches)
        #expect(restored.pages.first?.sortKey == marker)
        #expect(restored.pages.count == first.pages.count)
        #expect(restored.pages.map(\.id) == first.pages.map(\.id))

        // シークレット(cachesPageList: false)は構造キャッシュを読みもしない。
        let uncached = try await BookLoader.load(from: url, cachesPageList: false, caches: caches)
        #expect(uncached.pages.map(\.sortKey) == first.pages.map(\.sortKey))

        // 本体の更新日時が変われば指紋が合わず、フルの読み込みへ落ちる。
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path
        )
        let reread = try await loadCaching(url, caches: caches)
        #expect(reread.pages.map(\.sortKey) == first.pages.map(\.sortKey))
    }

    // MARK: - PageLoader: サムネイルとページ寸法

    @Test("サムネイルは渡したディスクキャッシュへ書かれ、次の PageLoader はそこから読む")
    func thumbnailsRoundTripThroughInjectedDiskCache() async throws {
        let temporary = try TemporaryDirectory("cache-thumbnail")
        let caches = BookDiskCaches(directory: temporary.file("caches"))
        await caches.thumbnails.configure(isEnabled: true, maxTotalBytes: 16 * 1024 * 1024, generation: 1)
        let book = try await FixtureBook.load(try makeZipBook(in: temporary))
        let key = thumbnailKey(for: book)
        let firstPageID = book.pages[0].id

        let writer = PageLoader(book: book, usesThumbnailDiskCache: true, diskCaches: caches)
        let made = try #require(await writer.thumbnail(at: 0))
        #expect(PageColorReader.number(in: made) == 1)
        let thumbnails = caches.thumbnails
        #expect(await eventually { await thumbnails.hasThumbnail(bookKey: key, pageID: firstPageID) })
        await writer.releaseAllResources()

        // ディスクにあるものが使われることを確かめるため、別のページの絵で置き換えておく。
        await caches.thumbnails.store(PageImageFactory.cgImage(number: 42), bookKey: key, pageID: firstPageID)
        let reader = PageLoader(book: book, usesThumbnailDiskCache: true, diskCaches: caches)
        let fromDisk = try #require(await reader.thumbnail(at: 0))
        #expect(PageColorReader.number(in: fromDisk) == 42)
        await reader.releaseAllResources()
    }

    @Test("usesThumbnailDiskCache: false の PageLoader は、渡したディスクキャッシュを読みも書きもしない")
    func privateLoaderNeverTouchesInjectedDiskCache() async throws {
        let temporary = try TemporaryDirectory("cache-thumbnail-off")
        let caches = BookDiskCaches(directory: temporary.file("caches"))
        await caches.thumbnails.configure(isEnabled: true, maxTotalBytes: 16 * 1024 * 1024, generation: 1)
        let book = try await FixtureBook.load(try makeZipBook(in: temporary))
        let key = thumbnailKey(for: book)
        await caches.thumbnails.store(PageImageFactory.cgImage(number: 42), bookKey: key, pageID: book.pages[1].id)

        let loader = PageLoader(book: book, usesThumbnailDiskCache: false, diskCaches: caches)
        // ディスクにある 42 ではなく、本体の 2 ページ目が返る(読まない)。
        let image = try #require(await loader.thumbnail(at: 1))
        #expect(PageColorReader.number(in: image) == 2)
        _ = await loader.thumbnail(at: 0)
        await loader.releaseAllResources()
        // 書かない側は書き込みの Task を投げもしない。
        #expect(await caches.thumbnails.hasThumbnail(bookKey: key, pageID: book.pages[0].id) == false)
    }

    @Test("分かったページ寸法は構造キャッシュへ書き戻され、次の PageLoader は書庫に触らずそれを使う")
    func pageSizesPersistAcrossLoaders() async throws {
        let temporary = try TemporaryDirectory("cache-page-sizes")
        let caches = BookDiskCaches(directory: temporary.file("caches"))
        let url = try makeZipBook(in: temporary)
        let book = try await loadCaching(url, caches: caches)
        let fingerprint = try #require(BookPageListCache.Entry.Fingerprint.current(for: url))

        let first = PageLoader(book: book, usesThumbnailDiskCache: true, diskCaches: caches)
        var sizes: [String: [Int]] = [:]
        for index in book.pages.indices {
            let size = try #require(await first.pageSize(at: index))
            sizes[book.pages[index].sortKey] = [size.width, size.height]
        }
        await first.persistPageSizesIfNeeded()
        await first.releaseAllResources()
        #expect(await caches.pageLists.pageSizes(forBookID: book.id, fingerprint: fingerprint) == sizes)

        // 持ち越した寸法が使われることを確かめるため、1 ページ目の寸法だけ書き換えておく。
        var marked = sizes
        marked[book.pages[0].sortKey] = [7, 11]
        await caches.pageLists.storePageSizes(marked, forBookID: book.id, fingerprint: fingerprint)
        let second = PageLoader(book: book, usesThumbnailDiskCache: true, diskCaches: caches)
        await second.loadPersistedPageSizes()
        let carried = try #require(await second.pageSize(at: 0))
        #expect(carried.width == 7 && carried.height == 11)
        await second.releaseAllResources()

        // シークレットの PageLoader は持ち越しを読まない。
        let isolated = PageLoader(book: book, usesThumbnailDiskCache: false, diskCaches: caches)
        await isolated.loadPersistedPageSizes()
        let measured = try #require(await isolated.pageSize(at: 0))
        #expect([measured.width, measured.height] == sizes[book.pages[0].sortKey])
        await isolated.releaseAllResources()
    }

    // MARK: - ViewerViewModel: 取り込むものが無かった記録

    @Test("ComicInfo.xml の無い本を開くと、無かったことがキャッシュに記録される(記録を残さない本は記録しない)")
    func viewerRecordsAbsentComicInfo() async throws {
        let harness = try ViewerHarness(label: "cache-source-probe")
        defer { harness.close() }
        let url = try makeZipBook(in: harness.temporary)
        let book = try await harness.loadBookCachingPageList(url)
        let pageLists = harness.diskCaches.pageLists
        #expect(await pageLists.sourceProbe(forBookID: book.id, sourceURL: url)?.comicInfoIsAbsent == nil)

        _ = await harness.open(book, skipsPersistence: true, usesDiskCaches: true)
        #expect(await pageLists.sourceProbe(forBookID: book.id, sourceURL: url)?.comicInfoIsAbsent == nil)

        _ = await harness.open(book, usesDiskCaches: true)
        #expect(await eventually {
            await pageLists.sourceProbe(forBookID: book.id, sourceURL: url)?.comicInfoIsAbsent == true
        })
    }

    // MARK: - BookSavedDataEraser

    @Test("本の保存データを消すと、渡したキャッシュのページ一覧も消える")
    func eraserRemovesPageListFromInjectedCache() async throws {
        let temporary = try TemporaryDirectory("cache-eraser")
        let library = try InMemoryLibrary(label: "cache-eraser")
        defer { library.close() }
        let caches = BookDiskCaches(directory: temporary.file("caches"))
        let keep = try await loadCaching(try makeZipBook(in: temporary, named: "keep.cbz"), caches: caches)
        let erase = try await loadCaching(try makeZipBook(in: temporary, named: "erase.cbz"), caches: caches)

        let eraser = BookSavedDataEraser(
            favoritesStore: library.favorites, collectionStore: library.collections,
            bookmarkStore: library.bookmarks, layoutStore: library.layouts,
            metadataStore: library.metadata, modelContext: library.context,
            pageListCache: caches.pageLists
        )
        let purge = try #require(eraser.deleteAllData(forBookIDs: [erase.id]))
        await purge.value

        #expect(await caches.pageLists.pageList(forBookID: erase.id) == nil)
        #expect(await caches.pageLists.pageList(forBookID: keep.id) != nil)
    }

    @Test("テストの中の既定の BookSavedDataEraser は、共有のキャッシュに触らない")
    func eraserDefaultsToNoCacheUnderTests() throws {
        #expect(BookSavedDataEraser.defaultPageListCache == nil)
    }
}

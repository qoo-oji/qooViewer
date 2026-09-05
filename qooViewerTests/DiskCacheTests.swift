import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// 2つのディスクキャッシュ(Services/ThumbnailDiskCache.swift、
/// Services/BookPageListCache.swift)。
///
/// どちらも `init(directory:)` で保存先を作業フォルダへ向ける ―― 既定(`shared`)は利用者の
/// キャッシュそのものなので、テストから触ってはいけない。
struct DiskCacheTests {
    private func decodedImage(number: UInt8) throws -> CGImage {
        try #require(ImageDecoder.decode(
            PageImageFactory.data(number: number, fileExtension: "png"), maxPixelSize: 4096
        ))
    }

    private func bookKey(_ bookID: String, contrast: Bool = false, maxPixelSize: CGFloat = 256)
        -> ThumbnailDiskCache.BookKey
    {
        ThumbnailDiskCache.BookKey(
            sourceURL: URL(fileURLWithPath: bookID), bookID: bookID,
            contrastCorrectionEnabled: contrast, maxPixelSize: maxPixelSize
        )
    }

    // MARK: - サムネイル

    @Test("設定がONなら、保存したサムネイルを読み直せる")
    func aStoredThumbnailComesBack() async throws {
        let temporary = try TemporaryDirectory("thumbnails")
        let cache = ThumbnailDiskCache(directory: temporary.url)
        await cache.configure(isEnabled: true, maxTotalBytes: 10 * 1024 * 1024, generation: 1)
        let key = bookKey("/books/a")

        #expect(await cache.hasThumbnail(bookKey: key, pageID: "p1") == false)
        await cache.store(try decodedImage(number: 7), bookKey: key, pageID: "p1")

        #expect(await cache.hasThumbnail(bookKey: key, pageID: "p1"))
        let image = try #require(await cache.thumbnail(bookKey: key, pageID: "p1"))
        // 中身まで確かめる(ページ画像の R = ページ番号)。
        #expect(PageColorReader.number(in: image) == 7)
    }

    @Test("設定がOFFのあいだは、書きも読みもしない")
    func nothingIsWrittenOrReadWhileDisabled() async throws {
        let temporary = try TemporaryDirectory("thumbnails")
        let cache = ThumbnailDiskCache(directory: temporary.url)
        await cache.configure(isEnabled: false, maxTotalBytes: 10 * 1024 * 1024, generation: 1)
        let key = bookKey("/books/a")

        await cache.store(try decodedImage(number: 1), bookKey: key, pageID: "p1")
        #expect(await cache.hasThumbnail(bookKey: key, pageID: "p1") == false)
        #expect(await cache.thumbnail(bookKey: key, pageID: "p1") == nil)
        #expect(await cache.totalBytes() == 0)
    }

    @Test("本の指紋・補正の有無・寸法が違えば、別のサムネイルとして扱う")
    func theKeyCoversEverythingThatChangesTheImage() async throws {
        let temporary = try TemporaryDirectory("thumbnails")
        let cache = ThumbnailDiskCache(directory: temporary.url)
        await cache.configure(isEnabled: true, maxTotalBytes: 10 * 1024 * 1024, generation: 1)
        await cache.store(try decodedImage(number: 1), bookKey: bookKey("/books/a"), pageID: "p1")

        #expect(await cache.hasThumbnail(bookKey: bookKey("/books/a"), pageID: "p1"))
        // 補正の有無でデコード結果が変わる。
        #expect(await cache.hasThumbnail(
            bookKey: bookKey("/books/a", contrast: true), pageID: "p1") == false)
        // 寸法が違えば別物。
        #expect(await cache.hasThumbnail(
            bookKey: bookKey("/books/a", maxPixelSize: 512), pageID: "p1") == false)
        // 別の本。
        #expect(await cache.hasThumbnail(bookKey: bookKey("/books/b"), pageID: "p1") == false)
        // 同じ本の別のページ。
        #expect(await cache.hasThumbnail(bookKey: bookKey("/books/a"), pageID: "p2") == false)
    }

    @Test("古い設定が遅れて届いても、新しい設定を上書きしない")
    func anOlderConfigurationIsIgnored() async throws {
        let temporary = try TemporaryDirectory("thumbnails")
        let cache = ThumbnailDiskCache(directory: temporary.url)
        await cache.configure(isEnabled: true, maxTotalBytes: 1024 * 1024, generation: 2)
        // AppPreferencesは独立したTaskで設定を送るので、到着順は保証されない。
        await cache.configure(isEnabled: false, maxTotalBytes: 1024 * 1024, generation: 1)
        #expect(await cache.isEnabled)
    }

    @Test("上限を超えたら、最終アクセスが古いものから上限の8割まで削る")
    func trimmingDropsTheOldestFilesFirst() throws {
        let temporary = try TemporaryDirectory("thumbnails")
        let directory = try temporary.directory("cache")
        // 100バイトずつ、古い順に old0 → old4。
        for index in 0..<5 {
            let url = directory.appendingPathComponent("old\(index)")
            try Data(repeating: 0, count: 100).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceReferenceDate: Double(index))],
                ofItemAtPath: url.path
            )
        }

        // 上限500なら何もしない(超えていない)。
        ThumbnailDiskCache.trimIfNeeded(in: directory, maxTotalBytes: 500)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 5)

        // 上限300 → 目標は8割の240。古い順に消して240以下になるまで(残り2つ = 200バイト)。
        ThumbnailDiskCache.trimIfNeeded(in: directory, maxTotalBytes: 300)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(remaining == ["old3", "old4"])
    }

    // MARK: - ページ一覧

    private func entry(_ sortKeys: [String], fingerprint: BookPageListCache.Entry.Fingerprint?)
        -> BookPageListCache.Entry
    {
        BookPageListCache.Entry(
            pages: sortKeys.map {
                BookPageListCache.Entry.Page(sortKey: $0, displayName: $0, folderPath: nil)
            },
            schemaVersion: BookPageListCache.Entry.currentSchemaVersion,
            rootPath: "/books/a", fingerprint: fingerprint, hasNestedArchives: false
        )
    }

    @Test("保存したページ一覧を読み直せる")
    func aStoredPageListComesBack() async throws {
        let temporary = try TemporaryDirectory("pagelists")
        let cache = BookPageListCache(directory: temporary.url)

        #expect(await cache.pageList(forBookID: "/books/a") == nil)
        await cache.store(entry(["p1", "p2"], fingerprint: nil), forBookID: "/books/a")

        let loaded = try #require(await cache.pageList(forBookID: "/books/a"))
        #expect(loaded.pages.map(\.sortKey) == ["p1", "p2"])
        // 本が違えば別の行。
        #expect(await cache.pageList(forBookID: "/books/b") == nil)
    }

    @Test("ページ寸法は、本体の指紋が一致するときだけ書けて、読める")
    func pageSizesAreGuardedByTheFingerprint() async throws {
        let temporary = try TemporaryDirectory("pagelists")
        let cache = BookPageListCache(directory: temporary.url)
        let fingerprint = BookPageListCache.Entry.Fingerprint(
            modificationDate: Date(timeIntervalSinceReferenceDate: 0), fileSize: 100
        )
        let other = BookPageListCache.Entry.Fingerprint(
            modificationDate: Date(timeIntervalSinceReferenceDate: 1), fileSize: 100
        )
        await cache.store(entry(["p1"], fingerprint: fingerprint), forBookID: "/books/a")

        // 指紋が違う書き込みは無視する(別の本体の寸法を混ぜない)。
        await cache.storePageSizes(["p1": [10, 20]], forBookID: "/books/a", fingerprint: other)
        #expect(await cache.pageSizes(forBookID: "/books/a", fingerprint: fingerprint) == nil)

        await cache.storePageSizes(["p1": [10, 20]], forBookID: "/books/a", fingerprint: fingerprint)
        #expect(await cache.pageSizes(forBookID: "/books/a", fingerprint: fingerprint) == ["p1": [10, 20]])
        // 読み出しも指紋で守る ―― 本体が差し替わっていたら使わない。
        #expect(await cache.pageSizes(forBookID: "/books/a", fingerprint: other) == nil)
    }

    @Test("同じ本体を開き直したときは、前回のページ寸法を引き継ぐ")
    func pageSizesSurviveReopeningTheSameBook() async throws {
        let temporary = try TemporaryDirectory("pagelists")
        let cache = BookPageListCache(directory: temporary.url)
        let fingerprint = BookPageListCache.Entry.Fingerprint(
            modificationDate: Date(timeIntervalSinceReferenceDate: 0), fileSize: 100
        )
        await cache.store(entry(["p1"], fingerprint: fingerprint), forBookID: "/books/a")
        await cache.storePageSizes(["p1": [10, 20]], forBookID: "/books/a", fingerprint: fingerprint)

        // 本を開き直すと、読み込みは寸法を知らないまま書き直す(Entry.pageSizesのコメント参照)。
        await cache.store(entry(["p1"], fingerprint: fingerprint), forBookID: "/books/a")
        #expect(await cache.pageSizes(forBookID: "/books/a", fingerprint: fingerprint) == ["p1": [10, 20]])

        // 本体が差し替わっていれば引き継がない。
        let replaced = BookPageListCache.Entry.Fingerprint(
            modificationDate: Date(timeIntervalSinceReferenceDate: 2), fileSize: 200
        )
        await cache.store(entry(["p1"], fingerprint: replaced), forBookID: "/books/a")
        #expect(await cache.pageSizes(forBookID: "/books/a", fingerprint: replaced) == nil)
    }

    @Test("すべて削除すると、保存先ごと消える")
    func removingEverythingClearsTheDirectory() async throws {
        let temporary = try TemporaryDirectory("pagelists")
        let directory = try temporary.directory("cache")
        let cache = BookPageListCache(directory: directory)
        await cache.store(entry(["p1"], fingerprint: nil), forBookID: "/books/a")
        #expect(await cache.totalBytes() > 0)

        await cache.removeAll()

        #expect(await cache.pageList(forBookID: "/books/a") == nil)
        #expect(await cache.totalBytes() == 0)
    }
}

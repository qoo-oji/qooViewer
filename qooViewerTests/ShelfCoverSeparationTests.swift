import CoreGraphics
import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// **コレクション表紙**(棚の表示)と**カバー画像**(EPUB/CBZ/PDFの書き出し)の分離
/// (2026-09-11。Models/BookLayoutSettings.swift の型コメント参照)。
///
/// 分離前は1組の列で両方を賄っていた。棚の絵はアプリが768pxのJPEGへ焼いて持つので元ファイルが
/// 消えても出続けるのに対し、書き出しは毎回そのファイルを読み直す ―― つまり元ファイルを消すと
/// **書き出しのカバーだけが黙って既定へ戻り、棚は何も変わらないので気づけない**。実測では
/// 外部ファイルを指定していた131冊すべてで元ファイルが失われていた。
///
/// ここで押さえるのは、間違えると**絵が消える**か**気づけないまま壊れる**もの:
/// - 移行が、失われた指定を棚側へ引き取り、書き出し側を空にすること
/// - 移行が `CollectionCovers` の JPEG に指一本触れないこと(あれがその絵の最後の1枚)
/// - 移行が取りこぼしたら済み印を立てないこと(次の起動でやり直せること)
/// - 分離後、片方を変えてももう片方が変わらないこと
/// - 指定した画像の表紙は、本の実体が無くても作れること
@MainActor
struct ShelfCoverSeparationTests {
    /// 抽出の司会役。**保存世代の作り直しは起こさない**ように、世代の印を先に立てておく ――
    /// あれは全件を `.pending` へ戻して焼き直すので、そのままだとここで見たい
    /// 「移行が `CollectionCovers` に触らないこと」が確かめられない
    /// (CollectionCoverExtractor.migrateCoverStorageIfNeeded 参照)。
    private func makeExtractor(
        _ library: InMemoryLibrary, suite: PreferencesSuite
    ) -> CollectionCoverExtractor {
        suite.defaults.set(
            CollectionCoverExtractor.coverStorageGeneration,
            forKey: "qooViewer.collections.coverStorageGeneration"
        )
        return CollectionCoverExtractor(
            collectionStore: library.collections, coverStore: library.collectionCovers,
            layoutStore: library.layouts, cachesPageList: false, defaults: suite.defaults
        )
    }

    private func makeFolderBook(_ temporary: TemporaryDirectory, named name: String = "book") throws -> URL {
        let directory = temporary.file(name)
        try FixtureFolder.make(at: directory, pages: [
            .init("001.png", number: 1), .init("002.png", number: 2),
        ])
        return directory
    }

    private func register(_ url: URL, in library: InMemoryLibrary) throws -> CollectionItem {
        let shelf = try #require(library.collections.libraries.first)
        let pending = try #require(CollectionStore.makePendingItem(for: url))
        let collection = try #require(
            library.collections.createCollection(name: "Shelf", in: shelf, items: [pending])
        )
        return try #require(collection.items.first)
    }

    /// 分離前の姿を作る: 「本に含まれない画像ファイル」をカバーに指定してあり、そのファイルは
    /// もう存在しない(ブックマークは残骸)。実物と同じく、棚には焼いた JPEG だけが残っている。
    ///
    /// ブックマークを実際に作らずバイト列を置くのは、**移行が見るのが「指定があるか」だけ**で、
    /// しかも実データでは131冊すべてが解決不能だったため ―― 解決できるブックマークを作って
    /// しまうと、むしろ現実と違う状況を試すことになる。
    private func makeLostExternalCover(
        forBookID bookID: String, sourceURL: URL, in library: InMemoryLibrary
    ) throws {
        // 行を作る入り口は公開 API しか無いので、いったんページ指定で作ってから書き換える。
        library.layouts.setCoverPageKey(
            forBookID: bookID, sourceURL: sourceURL, pageKey: "001.png", displayName: "001.png"
        )
        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: bookID))
        settings.coverPageKey = nil
        settings.coverPageDisplayName = nil
        settings.externalCoverBookmarkData = Data([0xAB, 0xCD])
        settings.externalCoverFileName = "表紙.webp"
        try library.context.save()
    }

    // MARK: - 移行

    @Test("失われた外部カバーの指定は、棚に残っている絵ごとコレクション表紙へ引き取られる")
    func migrationMovesLostExternalCoverToTheShelfSide() async throws {
        let library = try InMemoryLibrary(label: "shelf-sep-move")
        defer { library.close() }
        let suite = PreferencesSuite(label: "shelf-sep-move")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("shelf-sep-move")
        let url = try makeFolderBook(temporary)
        let item = try register(url, in: library)

        // 棚に出ている絵(= 分離前から見えていたもの)。これがその絵の最後の1枚。
        try await library.collectionCovers.write(PageImageFactory.cgImage(number: 7), for: item.id)
        library.collections.setCoverStatus(.ready, aspect: 1, for: item)
        let coverURL = library.collectionCovers.url(for: item.id)
        let before = try Data(contentsOf: coverURL)

        try makeLostExternalCover(forBookID: item.bookID, sourceURL: url, in: library)

        let extractor = makeExtractor(library, suite: suite)
        defer { extractor.releaseResources() }
        await extractor.waitUntilIdle()

        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: item.bookID))
        // 書き出し側は空に。指し示す先はもう無く、既に既定へ落ちていたので何も失われない。
        #expect(settings.externalCoverBookmarkData == nil)
        #expect(settings.externalCoverFileName == nil)
        #expect(settings.coverPageKey == nil)
        // 棚側が絵を引き取った。
        let storedName = try #require(settings.shelfCoverImageFileName)
        #expect(settings.shelfCoverPageKey == nil)

        #expect(extractor.extractionAttemptCount == 0)
        // 引き取った実体は、棚に出ていた JPEG **そのもの**(焼き直していない)。
        let storedURL = try #require(library.layouts.coverSourceStore.url(forFileName: storedName))
        #expect(try Data(contentsOf: storedURL) == before)
        // そして `CollectionCovers` 側には触れていない。
        #expect(try Data(contentsOf: coverURL) == before)
        #expect(item.coverState == .ready)
    }

    @Test("本の中のページ指定は、両側に残る(どちらの見え方も変えない)")
    func migrationCopiesPageSelectionToBothSides() async throws {
        let library = try InMemoryLibrary(label: "shelf-sep-page")
        defer { library.close() }
        let suite = PreferencesSuite(label: "shelf-sep-page")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("shelf-sep-page")
        let url = try makeFolderBook(temporary)
        let item = try register(url, in: library)
        library.layouts.setCoverPageKey(
            forBookID: item.bookID, sourceURL: url, pageKey: "002.png", displayName: "002.png"
        )

        let extractor = makeExtractor(library, suite: suite)
        defer { extractor.releaseResources() }
        await extractor.waitUntilIdle()

        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: item.bookID))
        #expect(settings.coverPageKey == "002.png")
        #expect(settings.shelfCoverPageKey == "002.png")
        #expect(settings.shelfCoverPageDisplayName == "002.png")
        #expect(settings.shelfCoverImageFileName == nil)
    }

    @Test("移行は一度きり。二度目は何もせず、既に表紙がある本には触らない")
    func migrationRunsOnlyOnce() async throws {
        let library = try InMemoryLibrary(label: "shelf-sep-once")
        defer { library.close() }
        let suite = PreferencesSuite(label: "shelf-sep-once")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("shelf-sep-once")
        let url = try makeFolderBook(temporary)
        let item = try register(url, in: library)
        try await library.collectionCovers.write(PageImageFactory.cgImage(number: 3), for: item.id)
        try makeLostExternalCover(forBookID: item.bookID, sourceURL: url, in: library)

        let first = makeExtractor(library, suite: suite)
        first.releaseResources()
        let storedName = try #require(
            library.layouts.bookLayoutSettings(forBookID: item.bookID)?.shelfCoverImageFileName
        )

        // 分離後に、利用者が書き出し用のカバー画像を指定し直した状況を作る。
        library.layouts.setCoverPageKey(
            forBookID: item.bookID, sourceURL: url, pageKey: "001.png", displayName: "001.png"
        )
        let second = makeExtractor(library, suite: suite)
        defer { second.releaseResources() }
        await second.waitUntilIdle()

        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: item.bookID))
        // 二度目は動かないので、指定し直したカバー画像が棚側へ持っていかれることはない。
        #expect(settings.coverPageKey == "001.png")
        #expect(settings.shelfCoverPageKey == nil)
        #expect(settings.shelfCoverImageFileName == storedName)
    }

    @Test("引き取る絵がまだ無い本があれば、済み印を立てずに次の起動へ回す")
    func migrationRetriesWhenTheImageIsNotThereYet() async throws {
        let library = try InMemoryLibrary(label: "shelf-sep-retry")
        defer { library.close() }
        let suite = PreferencesSuite(label: "shelf-sep-retry")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("shelf-sep-retry")
        let url = try makeFolderBook(temporary)
        let item = try register(url, in: library)
        // 棚の絵はまだ焼けていない(`.pending`)。
        try makeLostExternalCover(forBookID: item.bookID, sourceURL: url, in: library)

        let first = makeExtractor(library, suite: suite)
        first.releaseResources()
        #expect(
            library.layouts.bookLayoutSettings(forBookID: item.bookID)?.shelfCoverImageFileName == nil
        )
        #expect(suite.defaults.bool(forKey: "qooViewer.collections.shelfCoverSeparation") == false)

        // 絵が焼けた後に立ち上げ直せば、今度は引き取れる。
        try await library.collectionCovers.write(PageImageFactory.cgImage(number: 5), for: item.id)
        let second = makeExtractor(library, suite: suite)
        defer { second.releaseResources() }
        await second.waitUntilIdle()

        #expect(
            library.layouts.bookLayoutSettings(forBookID: item.bookID)?.shelfCoverImageFileName != nil
        )
        #expect(suite.defaults.bool(forKey: "qooViewer.collections.shelfCoverSeparation"))
    }

    // MARK: - 分離後の独立性

    @Test("コレクション表紙を変えても、書き出すカバー画像は変わらない(逆も)")
    func theTwoCoversDoNotAffectEachOther() throws {
        let library = try InMemoryLibrary(label: "shelf-sep-independent")
        defer { library.close() }
        let temporary = try TemporaryDirectory("shelf-sep-independent")
        let url = try makeFolderBook(temporary)
        let bookID = url.path

        library.layouts.setCoverPageKey(
            forBookID: bookID, sourceURL: url, pageKey: "001.png", displayName: "001.png"
        )
        library.layouts.setShelfCoverPageKey(
            forBookID: bookID, sourceURL: url, pageKey: "002.png", displayName: "002.png"
        )

        var settings = try #require(library.layouts.bookLayoutSettings(forBookID: bookID))
        #expect(settings.coverPageKey == "001.png")
        #expect(settings.shelfCoverPageKey == "002.png")

        // 表紙だけを既定へ戻しても、書き出し用は残る。
        library.layouts.clearShelfCover(forBookID: bookID)
        settings = try #require(library.layouts.bookLayoutSettings(forBookID: bookID))
        #expect(settings.coverPageKey == "001.png")
        #expect(settings.hasShelfCoverOverride == false)

        // 逆向きも同じ。
        library.layouts.setShelfCoverPageKey(
            forBookID: bookID, sourceURL: url, pageKey: "002.png", displayName: "002.png"
        )
        library.layouts.clearCoverOverride(forBookID: bookID)
        settings = try #require(library.layouts.bookLayoutSettings(forBookID: bookID))
        #expect(settings.hasCoverOverride == false)
        #expect(settings.shelfCoverPageKey == "002.png")
    }

    @Test("表紙に指定した画像はアプリの中へ複製され、元ファイルを消しても残る")
    func aChosenImageIsCopiedIntoTheApp() async throws {
        let library = try InMemoryLibrary(label: "shelf-sep-copy")
        defer { library.close() }
        let temporary = try TemporaryDirectory("shelf-sep-copy")
        let bookID = "/nowhere/book.cbz"
        let imageURL = temporary.file("chosen.png")
        try PageImageFactory.png(number: 9).write(to: imageURL)

        try await library.layouts.setShelfCoverImage(forBookID: bookID, sourceURL: nil, fileURL: imageURL)
        let storedName = try #require(library.layouts.shelfCoverImageFileName(forBookID: bookID))
        let storedURL = try #require(library.layouts.coverSourceStore.url(forFileName: storedName))

        // 利用者が元ファイルを捨てても、複製は残っていて表紙は出せる。
        try FileManager.default.removeItem(at: imageURL)
        let data = try Data(contentsOf: storedURL)
        #expect(PageColorReader.number(in: data) == 9)

        // 既定へ戻せば複製も消える(参照されない絵を残さない)。
        library.layouts.clearShelfCover(forBookID: bookID)
        #expect(FileManager.default.fileExists(atPath: storedURL.path) == false)
    }

    @Test("指定した画像の表紙は、本の実体が見つからなくても作れる")
    func aChosenImageWorksWithoutTheBook() async throws {
        let library = try InMemoryLibrary(label: "shelf-sep-missing-book")
        defer { library.close() }
        let suite = PreferencesSuite(label: "shelf-sep-missing-book")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("shelf-sep-missing-book")
        let url = try makeFolderBook(temporary)
        let item = try register(url, in: library)
        let imageURL = temporary.file("chosen.png")
        try PageImageFactory.png(number: 4).write(to: imageURL)
        try await library.layouts.setShelfCoverImage(
            forBookID: item.bookID, sourceURL: url, fileURL: imageURL
        )
        // 本ごと消す(未接続のボリューム上にある本と同じ状況)。
        try FileManager.default.removeItem(at: url)

        let extractor = makeExtractor(library, suite: suite)
        defer { extractor.releaseResources() }
        extractor.enqueue([item])
        await extractor.waitUntilIdle()

        #expect(item.coverState == .ready)
        // 表紙の元画像は保管庫へ入れる時点で JPEG へ焼き直されるので、色は ±2 ずれる
        // (PageColorReader.matches と同じ基準)。
        let image = try #require(await library.collectionCovers.image(for: item.id))
        let number = try #require(PageColorReader.number(in: image))
        #expect(abs(number - 4) <= 2)
    }

    // MARK: - 保管庫そのもの

    @Test("画像として読めないものは保管庫に入らない")
    func theStoreRejectsNonImages() async throws {
        let temporary = try TemporaryDirectory("shelf-sep-reject")
        let store = CollectionCoverSourceStore(directory: temporary.file("sources"))
        let notAnImage = temporary.file("evil.png")
        try Data("<?xml version=\"1.0\"?><svg/>".utf8).write(to: notAnImage)

        await #expect(throws: (any Error).self) { try await store.store(imageAt: notAnImage) }
        // 何も書かれていない(壊れたファイルが保管庫に残らない)。
        let contents = try? FileManager.default.contentsOfDirectory(
            at: store.directory, includingPropertiesForKeys: nil
        )
        #expect((contents ?? []).isEmpty)
    }

    @Test("保管庫の外を指すファイル名は組み立てられない")
    func theStoreRefusesToLeaveItsDirectory() throws {
        let temporary = try TemporaryDirectory("shelf-sep-escape")
        let store = CollectionCoverSourceStore(directory: temporary.file("sources"))

        #expect(store.url(forFileName: "../escaped.jpg") == nil)
        #expect(store.url(forFileName: "sub/dir.jpg") == nil)
        #expect(store.url(forFileName: "..") == nil)
        #expect(store.url(forFileName: "") == nil)
        #expect(store.url(forFileName: "ok.jpg") != nil)
    }
}

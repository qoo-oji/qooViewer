import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// コレクションのカバーを 1 冊ずつ抽出する司会役(Services/CollectionCoverExtractor.swift)。
///
/// 押さえるのは、間違えるとカバーが**二度と出なくなる**か**無駄に作り直される**もの:
/// - 実体が見つからない本は `.failed` にしない(`.pending` のまま置く)。未接続のボリューム上の本が
///   全冊灰色になって、再接続しても戻らなかった(監査で指摘 2026-09-09)
/// - 存在確認で「無い」と分かっている本は待ち行列に積まない。結果が変わったら組み直す
/// - カバーの指定(どのページか)が変われば作り直し、切り出し位置の変更では作り直さない
/// - 保存の仕方の世代が上がったときの作り直しは、一度だけ・save 1 回
///
/// 待ち合わせは時間ではなく仕事の終わりで行う(`waitUntilIdle` / `settleExistenceRefresh`)。
/// カバーの保管庫は `InMemoryLibrary` が一時フォルダへ向けている。
@MainActor
struct CollectionCoverExtractorTests {
    private func makeExtractor(
        _ library: InMemoryLibrary, suite: PreferencesSuite
    ) -> CollectionCoverExtractor {
        CollectionCoverExtractor(
            collectionStore: library.collections, coverStore: library.collectionCovers,
            layoutStore: library.layouts, cachesPageList: false, defaults: suite.defaults
        )
    }

    /// 001・002 の 2 ページが並んだフォルダの本。
    private func makeFolderBook(_ temporary: TemporaryDirectory, named name: String = "book") throws -> URL {
        let directory = temporary.file(name)
        try FixtureFolder.make(at: directory, pages: [
            .init("001.png", number: 1), .init("002.png", number: 2),
        ])
        return directory
    }

    /// 1 ページの cbz。
    private func makeArchiveBook(_ temporary: TemporaryDirectory, named name: String, number: UInt8) throws -> URL {
        let url = temporary.file(name)
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: number))
        try builder.write(to: url)
        return url
    }

    /// 本をコレクションへ登録して、その行を返す。
    private func register(_ url: URL, in library: InMemoryLibrary) throws -> CollectionItem {
        let shelf = try #require(library.collections.libraries.first)
        let pending = try #require(CollectionStore.makePendingItem(for: url))
        let collection = try #require(
            library.collections.createCollection(name: "Shelf", in: shelf, items: [pending])
        )
        return try #require(collection.items.first)
    }

    private func coverNumber(of item: CollectionItem, in library: InMemoryLibrary) async -> Int? {
        guard let image = await library.collectionCovers.image(for: item.id) else { return nil }
        return PageColorReader.number(in: image)
    }

    // MARK: - 抽出の結果

    @Test("開ける本はカバーが抽出され、ディスクに残る")
    func aReadableBookGetsItsCoverExtracted() async throws {
        let library = try InMemoryLibrary(label: "cover-extractor-ready")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-extractor-ready")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-extractor-ready")
        let item = try register(try makeFolderBook(temporary), in: library)
        let extractor = makeExtractor(library, suite: suite)
        defer { extractor.releaseResources() }

        extractor.enqueue([item])
        await extractor.waitUntilIdle()

        #expect(item.coverState == .ready)
        #expect(item.coverAspect > 0)
        #expect(extractor.inFlightItemIDs.isEmpty)
        #expect(await coverNumber(of: item, in: library) == 1)
    }

    @Test("実体が見つからない本は failed にせず pending のまま置く")
    func aMissingBookStaysPending() async throws {
        let library = try InMemoryLibrary(label: "cover-extractor-missing")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-extractor-missing")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-extractor-missing")
        let url = try makeArchiveBook(temporary, named: "01.cbz", number: 1)
        let item = try register(url, in: library)
        try FileManager.default.removeItem(at: url)
        let extractor = makeExtractor(library, suite: suite)
        defer { extractor.releaseResources() }

        extractor.enqueue([item])
        await extractor.waitUntilIdle()

        // 解決しにはいった(存在確認がまだなので「ある」として扱われる)が、失敗にはしない。
        #expect(extractor.extractionAttemptCount >= 1)
        #expect(item.coverState == .pending)
        #expect(await library.collectionCovers.image(for: item.id) == nil)
    }

    @Test("開けない本は failed(灰色の枠と形式バッジで描く側)")
    func aBrokenBookIsMarkedFailed() async throws {
        let library = try InMemoryLibrary(label: "cover-extractor-broken")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-extractor-broken")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-extractor-broken")
        let broken = temporary.file("not-a-book.cbz")
        try Data("this is not a zip".utf8).write(to: broken)
        let item = try register(broken, in: library)
        let extractor = makeExtractor(library, suite: suite)
        defer { extractor.releaseResources() }

        extractor.enqueue([item])
        await extractor.waitUntilIdle()

        #expect(item.coverState == .failed)
        #expect(item.coverAspect == 0)
    }

    // MARK: - 存在確認との連携

    @Test("存在確認で「無い」と分かっている本は待ち行列に積まない")
    func refillSkipsBooksKnownToBeMissing() async throws {
        let library = try InMemoryLibrary(label: "cover-extractor-skip-missing")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-extractor-skip-missing")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-extractor-skip-missing")
        let url = try makeArchiveBook(temporary, named: "01.cbz", number: 1)
        let item = try register(url, in: library)
        try FileManager.default.removeItem(at: url)
        library.collections.scheduleExistenceRefresh()
        await library.collections.settleExistenceRefresh()
        #expect(library.collections.cachedFileExists(for: item) == false)

        let extractor = makeExtractor(library, suite: suite)
        defer { extractor.releaseResources() }
        extractor.refill()
        await extractor.waitUntilIdle()

        #expect(extractor.extractionAttemptCount == 0)
        #expect(item.coverState == .pending)
    }

    @Test("戻ってきた本は、存在確認の結果が変わった時点で抽出される")
    func aBookThatComesBackIsExtractedWhenTheExistenceCheckChanges() async throws {
        let library = try InMemoryLibrary(label: "cover-extractor-comeback")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-extractor-comeback")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-extractor-comeback")
        let url = try makeArchiveBook(temporary, named: "01.cbz", number: 5)
        let item = try register(url, in: library)
        // 外付けボリュームの取り外しに見立てて、実体を消す。**同じボリュームの中へ退避する
        // 形では再現しない** ―― セキュリティスコープ付きブックマークは i ノードで追いかけるので、
        // 動かしただけの本は「ある」と解決される(実測)。戻すときは同じパスへ作り直す
        // (ブックマークは i ノードで見つからなければパスへ落ちる)。
        try FileManager.default.removeItem(at: url)
        library.collections.scheduleExistenceRefresh()
        await library.collections.settleExistenceRefresh()
        #expect(library.collections.cachedFileExists(for: item) == false)

        let extractor = makeExtractor(library, suite: suite)
        defer { extractor.releaseResources() }
        extractor.refill()
        await extractor.waitUntilIdle()
        #expect(extractor.extractionAttemptCount == 0)

        // 戻す。存在確認の結果が変わった時点(settle が返った時点)で待ち行列が組み直されている。
        _ = try makeArchiveBook(temporary, named: "01.cbz", number: 5)
        library.collections.scheduleExistenceRefresh()
        await library.collections.settleExistenceRefresh()
        #expect(library.collections.cachedFileExists(for: item))
        await extractor.waitUntilIdle()

        #expect(extractor.extractionAttemptCount == 1)
        #expect(item.coverState == .ready)
        #expect(await coverNumber(of: item, in: library) == 5)
    }

    // MARK: - やり直しの契機

    @Test("コレクション表紙のページを変えると作り直すが、切り出し位置とカバー画像の変更では作り直さない")
    func changingTheCoverPageReExtractsButTheCropAnchorDoesNot() async throws {
        let library = try InMemoryLibrary(label: "cover-extractor-signature")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-extractor-signature")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-extractor-signature")
        let url = try makeFolderBook(temporary)
        let item = try register(url, in: library)
        let extractor = makeExtractor(library, suite: suite)
        defer { extractor.releaseResources() }
        extractor.enqueue([item])
        await extractor.waitUntilIdle()
        #expect(await coverNumber(of: item, in: library) == 1)
        let attemptsAfterFirst = extractor.extractionAttemptCount

        // 切り出し位置は表示のたびに効かせる値なので、抽出はやり直さない。
        library.layouts.setCoverCropAnchor(forBookID: item.bookID, sourceURL: url, anchor: .start)
        await extractor.waitUntilIdle()
        #expect(extractor.extractionAttemptCount == attemptsAfterFirst)
        #expect(item.coverState == .ready)

        // 書き出し用のカバー画像は棚の絵とは別物なので、こちらを変えても作り直さない
        // (2026-09-11の分離。ShelfCoverSeparationTests 参照)。
        library.layouts.setCoverPageKey(
            forBookID: item.bookID, sourceURL: url,
            pageKey: url.appendingPathComponent("002.png").path, displayName: "002.png"
        )
        await extractor.waitUntilIdle()
        #expect(extractor.extractionAttemptCount == attemptsAfterFirst)
        #expect(await coverNumber(of: item, in: library) == 1)

        // コレクション表紙のページ指定は絵そのものが変わるので、pending へ戻して作り直す。
        // フォルダの本の sortKey は絶対パス(PageRef.sortKey)。
        library.layouts.setShelfCoverPageKey(
            forBookID: item.bookID, sourceURL: url,
            pageKey: url.appendingPathComponent("002.png").path, displayName: "002.png"
        )
        await extractor.waitUntilIdle()
        #expect(extractor.extractionAttemptCount == attemptsAfterFirst + 1)
        #expect(item.coverState == .ready)
        #expect(await coverNumber(of: item, in: library) == 2)
    }

    /// 並び順の設定を差し替えられる入れ物(テストが共有の環境設定に触れないため)。
    private final class OrderSetting {
        var usesFinderOrder = true
    }

    @Test("「並び順をFinderに揃える」を切り替えると、先頭が変わる本だけを、表紙を出したまま作り直す")
    func togglingTheFinderOrderRefreshesOnlyBooksWhoseFirstPageChanges() async throws {
        let library = try InMemoryLibrary(label: "cover-extractor-page-order")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-extractor-page-order")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-extractor-page-order")
        // 大文字小文字が混ざった名前: Finderの順なら a が先、文字コード順なら B が先。
        let mixed = temporary.file("mixed")
        try FixtureFolder.make(at: mixed, pages: [.init("a.png", number: 1), .init("B.png", number: 2)])
        // どちらの順でも 001 が先の本(作り直してはいけない)。
        let plain = try makeFolderBook(temporary, named: "plain")
        let shelf = try #require(library.collections.libraries.first)
        let collection = try #require(library.collections.createCollection(
            name: "Shelf", in: shelf,
            items: [mixed, plain].compactMap(CollectionStore.makePendingItem(for:))
        ))
        let mixedItem = try #require(collection.items.first { $0.bookID == mixed.path })
        let plainItem = try #require(collection.items.first { $0.bookID == plain.path })

        let setting = OrderSetting()
        // mixed はキャッシュが無い(= 判定できないので作り直す)、plain はキャッシュで判定できる。
        let plainPages = [
            BookPageListCache.Entry.Page(sortKey: plain.appendingPathComponent("001.png").path, displayName: "001.png"),
            BookPageListCache.Entry.Page(sortKey: plain.appendingPathComponent("002.png").path, displayName: "002.png"),
        ]
        let plainBookID = plain.path
        let extractor = CollectionCoverExtractor(
            collectionStore: library.collections, coverStore: library.collectionCovers,
            layoutStore: library.layouts, cachesPageList: false, defaults: suite.defaults,
            usesFinderOrder: { setting.usesFinderOrder },
            cachedPageList: { bookID in bookID == plainBookID ? plainPages : nil }
        )
        defer { extractor.releaseResources() }
        extractor.enqueue([mixedItem, plainItem])
        await extractor.waitUntilIdle()
        #expect(await coverNumber(of: mixedItem, in: library) == 1)
        let attempts = extractor.extractionAttemptCount
        let revision = library.collections.coverRevision(for: mixedItem)

        setting.usesFinderOrder = false
        extractor.handlePageOrderSettingChange()
        // 作り直しを待つ間も表紙は出たまま(pending へ戻さない)。
        #expect(mixedItem.coverState == .ready)
        await extractor.settlePageOrderEvaluation()
        await extractor.waitUntilIdle()

        #expect(extractor.extractionAttemptCount == attempts + 1)
        #expect(await coverNumber(of: mixedItem, in: library) == 2)
        #expect(await coverNumber(of: plainItem, in: library) == 1)
        #expect(mixedItem.coverState == .ready)
        // 状態が変わらなくても、画面が読み直す合図は進む。
        #expect(library.collections.coverRevision(for: mixedItem) == revision + 1)
    }

    @Test("表紙を指定してある本は、並び順の設定を変えても作り直さない")
    func booksWithAChosenCoverIgnoreTheFinderOrder() async throws {
        let library = try InMemoryLibrary(label: "cover-extractor-page-order-pinned")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-extractor-page-order-pinned")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-extractor-page-order-pinned")
        let mixed = temporary.file("mixed")
        try FixtureFolder.make(at: mixed, pages: [.init("a.png", number: 1), .init("B.png", number: 2)])
        let item = try register(mixed, in: library)
        library.layouts.setShelfCoverPageKey(
            forBookID: item.bookID, sourceURL: mixed,
            pageKey: mixed.appendingPathComponent("a.png").path, displayName: "a.png"
        )
        let setting = OrderSetting()
        let extractor = CollectionCoverExtractor(
            collectionStore: library.collections, coverStore: library.collectionCovers,
            layoutStore: library.layouts, cachesPageList: false, defaults: suite.defaults,
            usesFinderOrder: { setting.usesFinderOrder }, cachedPageList: { _ in nil }
        )
        defer { extractor.releaseResources() }
        extractor.enqueue([item])
        await extractor.waitUntilIdle()
        let attempts = extractor.extractionAttemptCount

        setting.usesFinderOrder = false
        extractor.handlePageOrderSettingChange()
        await extractor.settlePageOrderEvaluation()
        await extractor.waitUntilIdle()

        #expect(extractor.extractionAttemptCount == attempts)
        #expect(await coverNumber(of: item, in: library) == 1)
    }

    // MARK: - 保存の仕方の世代

    @Test("保存の世代が上がっていたら全件を pending へ戻す(一度だけ・save は 1 回)")
    func theStorageGenerationMigrationRunsOnceInOneSave() async throws {
        let library = try InMemoryLibrary(label: "cover-extractor-migration")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-extractor-migration")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-extractor-migration")
        // 実体の無い本にしておく(戻した pending を抽出が勝手に ready へ進めないように)。
        let url = try makeArchiveBook(temporary, named: "01.cbz", number: 1)
        let item = try register(url, in: library)
        try FileManager.default.removeItem(at: url)
        library.collections.setCoverStatus(.ready, aspect: 1, for: item)
        let revisionBefore = library.collections.revision

        // まだ世代を記録していない保存先 = 古い作り方で保存してあった、と見なす。
        let first = makeExtractor(library, suite: suite)
        #expect(item.coverState == .pending)
        #expect(library.collections.revision == revisionBefore + 1)
        #expect(suite.defaults.integer(forKey: "qooViewer.collections.coverStorageGeneration")
            == CollectionCoverExtractor.coverStorageGeneration)
        await first.waitUntilIdle()
        first.releaseResources()

        // 記録済みの保存先で作り直しても、二度目は何もしない。
        library.collections.setCoverStatus(.ready, aspect: 1, for: item)
        let revisionBetween = library.collections.revision
        let second = makeExtractor(library, suite: suite)
        defer { second.releaseResources() }
        #expect(item.coverState == .ready)
        #expect(library.collections.revision == revisionBetween)
    }
}

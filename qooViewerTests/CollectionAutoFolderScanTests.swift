import Foundation
import Testing

@testable import qooViewer

/// 自動登録フォルダから拾う本を決めるところ(Services/CollectionAutoFolderScanner.swift の
/// `CollectionAutoFolderScan`)。
///
/// ここで押さえるのは2つ:
/// - **拾う範囲がドロップと一致すること。** 判定はShelfFolderResolver.role の `.shelf(books:)`
///   そのもの ―― 直下だけで、ファイルの本と画像を直接持つフォルダが並び順どおりに入る。
///   ここがずれると「フォルダを落としたときに入る本」と「自動で入る本」が食い違う。
/// - **書き終わっていないファイルを登録しないこと。** コピー中のファイルを本として登録すると、
///   カバーの抽出が`.failed`のまま固定される(`isSettled`のコメント参照)。一律の待ち時間では
///   なく「書き込みが止まったか」で判定するので、その境界を全部通しておく。
struct CollectionAutoFolderScanTests {
    /// 書庫・PDF が名前順に並び、画像フォルダの本と、本を持たない中間フォルダが混ざった棚。
    private func makeShelf(_ label: String) throws -> (TemporaryDirectory, URL) {
        let temporary = try TemporaryDirectory(label)
        let shelf = try temporary.directory("shelf")
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: 1))
        try builder.write(to: shelf.appendingPathComponent("01.cbz"))
        try PDFFixtureBuilder.write(to: shelf.appendingPathComponent("02.pdf"), pageNumbers: [2])
        // 画像を直接持つフォルダは、ファイルの本と同列に並ぶ1冊。
        try FixtureFolder.make(
            at: shelf.appendingPathComponent("03-folder"), pages: [.init("001.png", number: 3)]
        )
        // その中に本を持たないフォルダは、棚の中身にならない(奥まで降りない)。
        try FileManager.default.createDirectory(
            at: shelf.appendingPathComponent("zz-empty"), withIntermediateDirectories: true
        )
        return (temporary, shelf)
    }

    // MARK: - 拾う範囲

    @Test("拾うのは棚の直下だけで、並び順はフォルダブラウザと同じ")
    func picksUpOnlyTheBooksDirectlyInTheShelf() throws {
        let (temporary, shelf) = try makeShelf("auto-folder-shelf")
        defer { _ = temporary }

        let books = CollectionAutoFolderScan.books(in: shelf, order: .byName)

        #expect(books == [
            shelf.appendingPathComponent("01.cbz"),
            shelf.appendingPathComponent("02.pdf"),
            shelf.appendingPathComponent("03-folder"),
        ])
        // ドロップで同じフォルダを落としたときに入る本と、1冊のずれもなく一致する。
        #expect(CollectionDropClassifier.classify([shelf], order: .byName) == [
            .shelf(folder: shelf, books: books)
        ])
    }

    @Test("棚でないフォルダからは何も拾わない(指定そのものは弾かない)")
    func foldersThatAreNotShelvesYieldNothing() throws {
        let temporary = try TemporaryDirectory("auto-folder-not-a-shelf")
        // それ自体が1冊(直下に画像がある)。
        let singleBook = temporary.file("book")
        try FixtureFolder.make(at: singleBook, pages: [.init("001.jpg", number: 1)])
        // 空のフォルダ。
        let empty = try temporary.directory("empty")

        #expect(CollectionAutoFolderScan.books(in: singleBook, order: .byName).isEmpty)
        #expect(CollectionAutoFolderScan.books(in: empty, order: .byName).isEmpty)
        #expect(
            CollectionAutoFolderScan.books(in: temporary.file("does-not-exist"), order: .byName)
                .isEmpty
        )
    }

    // MARK: - 書き込みが止まったかどうか

    private func observation(
        size: Int64, modifiedAgo: TimeInterval, atAgo: TimeInterval = 0, now: Date
    ) -> CollectionAutoFolderScan.Observation {
        CollectionAutoFolderScan.Observation(
            snapshot: .init(size: size, modified: now.addingTimeInterval(-modifiedAgo)),
            at: now.addingTimeInterval(-atAgo)
        )
    }

    @Test("更新が止まってしばらく経っていれば、その場で通す")
    func afileThatStoppedChangingLongAgoIsSettledImmediately() {
        let now = Date()
        // 同じボリューム内の移動・リネームは元の更新時刻を引き継ぐので、ここで即座に通る。
        let old = observation(size: 100, modifiedAgo: 60, now: now)
        #expect(CollectionAutoFolderScan.isSettled(old, previous: nil))
    }

    @Test("書かれたばかりのファイルは、1回目の観測では通さない")
    func afreshlyWrittenFileIsNotSettledOnTheFirstLook() {
        let now = Date()
        let fresh = observation(size: 100, modifiedAgo: 0.1, now: now)
        #expect(CollectionAutoFolderScan.isSettled(fresh, previous: nil) == false)
    }

    @Test("間隔を空けた2回の観測で変わっていなければ通す")
    func twoIdenticalLooksFarEnoughApartCountAsSettled() {
        let now = Date()
        let previous = observation(
            size: 100, modifiedAgo: 0.6,
            atAgo: CollectionAutoFolderScan.recheckDelay, now: now
        )
        let current = observation(size: 100, modifiedAgo: 0.6, now: now)
        #expect(CollectionAutoFolderScan.isSettled(current, previous: previous))
    }

    @Test("まだ大きさが増えている間は通さない")
    func agrowingFileIsNotSettled() {
        let now = Date()
        let previous = observation(
            size: 100, modifiedAgo: 0.6,
            atAgo: CollectionAutoFolderScan.recheckDelay, now: now
        )
        let current = observation(size: 200, modifiedAgo: 0.1, now: now)
        #expect(CollectionAutoFolderScan.isSettled(current, previous: previous) == false)
    }

    @Test("2回の観測が近すぎるときは通さない(一瞬止まっただけを拾わない)")
    func twoLooksTooCloseTogetherDoNotCount() {
        let now = Date()
        let previous = observation(size: 100, modifiedAgo: 0.2, atAgo: 0.01, now: now)
        let current = observation(size: 100, modifiedAgo: 0.2, now: now)
        #expect(CollectionAutoFolderScan.isSettled(current, previous: previous) == false)
    }

    @Test("更新時刻が未来のファイルも通す(通さないと永久に登録されない)")
    func afileDatedInTheFutureIsSettled() {
        let now = Date()
        let future = CollectionAutoFolderScan.Observation(
            snapshot: .init(size: 100, modified: now.addingTimeInterval(3600)), at: now
        )
        #expect(CollectionAutoFolderScan.isSettled(future, previous: nil))
    }

    // MARK: - 走査役(端から端まで)

    /// 走査役 1 つぶんの支度。フォルダのアクセス権と環境設定は、その場限りの suite に載せる。
    @MainActor
    private struct ScannerHarness {
        let library: InMemoryLibrary
        let suite: PreferencesSuite
        let folderAccess: FolderAccessStore
        let extractor: CollectionCoverExtractor
        let scanner: CollectionAutoFolderScanner

        init(_ label: String) throws {
            library = try InMemoryLibrary(label: label)
            suite = PreferencesSuite(label: label)
            folderAccess = FolderAccessStore(defaults: suite.defaults)
            extractor = CollectionCoverExtractor(
                collectionStore: library.collections, coverStore: library.collectionCovers,
                layoutStore: library.layouts, cachesPageList: false, defaults: suite.defaults
            )
            scanner = CollectionAutoFolderScanner(
                collectionStore: library.collections, coverExtractor: extractor,
                folderAccess: folderAccess, preferences: suite.makePreferences()
            )
        }

        /// 走査と、それが積んだ抽出が終わるまで待つ。
        func settle() async {
            await scanner.settle()
            await extractor.waitUntilIdle()
        }

        func close() {
            scanner.releaseResources()
            extractor.releaseResources()
            library.close()
        }
    }

    private func writeArchive(_ url: URL, number: UInt8, modifiedAgo: TimeInterval? = nil) throws {
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: number))
        try builder.write(to: url)
        if let modifiedAgo {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-modifiedAgo)], ofItemAtPath: url.path
            )
        }
    }

    @Test("自動登録フォルダに置いた本は、書き終わっているものから順に入る(二重には入らない)")
    @MainActor
    func booksPlacedInTheAutoFolderAreAdded() async throws {
        let harness = try ScannerHarness("auto-folder-scanner")
        defer { harness.close() }
        let temporary = try TemporaryDirectory("auto-folder-scanner")
        let shelf = try temporary.directory("shelf")
        let seed = shelf.appendingPathComponent("00.cbz")
        try writeArchive(seed, number: 1, modifiedAgo: 60)
        let library = try #require(harness.library.collections.libraries.first)
        // `#require` の中に `#require` を入れると、マクロが再帰的に展開されて通らない。
        let seedItem = try #require(CollectionStore.makePendingItem(for: seed))
        let collection = try #require(
            harness.library.collections.createCollection(name: "Shelf", in: library, items: [seedItem])
        )
        harness.library.collections.setAutoFolder(shelf, for: collection)
        #expect(harness.folderAccess.add(url: shelf))

        // 更新が止まって久しいもの(同じボリューム内の移動など)と、書かれたばかりのもの。
        let settled = shelf.appendingPathComponent("01.cbz")
        let fresh = shelf.appendingPathComponent("02.cbz")
        try writeArchive(settled, number: 2, modifiedAgo: 60)
        try writeArchive(fresh, number: 3)

        harness.scanner.scheduleScan()
        await harness.settle()

        // 書かれたばかりのものも、見直し(recheckDelay 後)で「書き込みが止まった」と分かれば入る。
        #expect(Set(collection.items.map(\.bookID)) == [seed.path, settled.path, fresh.path])
        // 入った本のカバーはそのまま抽出される。
        #expect(collection.items.allSatisfy { $0.coverState == .ready })

        // もう一度走らせても増えない。
        harness.scanner.scheduleScan()
        await harness.settle()
        #expect(collection.items.count == 3)
    }

    @Test("列挙する権限の無いフォルダは黙って見送る")
    @MainActor
    func foldersWithoutAccessAreSkipped() async throws {
        let harness = try ScannerHarness("auto-folder-scanner-no-access")
        defer { harness.close() }
        let temporary = try TemporaryDirectory("auto-folder-scanner-no-access")
        let shelf = try temporary.directory("shelf")
        let seed = shelf.appendingPathComponent("00.cbz")
        try writeArchive(seed, number: 1, modifiedAgo: 60)
        let library = try #require(harness.library.collections.libraries.first)
        // `#require` の中に `#require` を入れると、マクロが再帰的に展開されて通らない。
        let seedItem = try #require(CollectionStore.makePendingItem(for: seed))
        let collection = try #require(
            harness.library.collections.createCollection(name: "Shelf", in: library, items: [seedItem])
        )
        harness.library.collections.setAutoFolder(shelf, for: collection)
        try writeArchive(shelf.appendingPathComponent("01.cbz"), number: 2, modifiedAgo: 60)

        harness.scanner.scheduleScan()
        await harness.settle()

        #expect(collection.items.count == 1)
    }

    @Test("大きさと更新時刻を実ファイルから読める")
    func snapshotReadsTheSizeAndModificationDate() throws {
        let temporary = try TemporaryDirectory("auto-folder-snapshot")
        let file = temporary.file("01.cbz")
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: 1))
        try builder.write(to: file)
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)

        let snapshot = try #require(CollectionAutoFolderScan.snapshot(of: file))

        #expect(snapshot.size > 0)
        #expect(abs(snapshot.modified.timeIntervalSince(stamp)) < 1)
        // 読めないものはnil(呼び出し側は「判定の材料が無い」として通す)。
        #expect(CollectionAutoFolderScan.snapshot(of: temporary.file("missing")) == nil)
    }
}

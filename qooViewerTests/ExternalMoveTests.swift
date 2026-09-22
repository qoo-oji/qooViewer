import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// アプリの外(Finder など)で名前を変えた本の保存データの付け替え(2026-09-22、利用者の指示)。
/// ストアはテスト専用のライブラリ(InMemoryLibrary)の上。
@MainActor
struct ExternalMoveTests {
    private func makeRelocator(_ library: InMemoryLibrary) -> BookRecordRelocator {
        BookRecordRelocator(
            favoritesStore: library.favorites, bookmarkStore: library.bookmarks, layoutStore: library.layouts,
            metadataStore: library.metadata, collectionStore: library.collections, modelContext: library.context
        )
    }

    /// 利用者が登録した(ロックした)メタデータの行を、ブックマークと識別子つきで作る。
    private func registerLocked(_ url: URL, in library: InMemoryLibrary) {
        _ = library.metadata.upsert(bookID: url.path, author: "A", title: "T", series: "", seriesIndex: "", sourceURL: url)
    }

    @Test("新しいパスに読みだけの行があっても、付け替えは直した行で置き換える")
    func relocationReplacesAParsedOnlyRow() async throws {
        let library = try InMemoryLibrary(label: "outside-move-replace")
        defer { library.close() }
        let temporary = try TemporaryDirectory("outside-move-replace")
        let old = temporary.file("before.cbz")
        try Data("a".utf8).write(to: old)
        registerLocked(old, in: library)
        let new = temporary.file("after.cbz")
        try FileManager.default.moveItem(at: old, to: new)
        library.metadata.registerParsed(bookID: new.path, rules: library.metadataRules.rules)
        #expect(library.metadata.metadata(forBookID: new.path)?.isParsedOnly == true)

        await makeRelocator(library).apply(FileSystemChange(relocations: [.init(from: old, to: new)])).value

        #expect(library.metadata.registeredBookIDs == [new.path])
        #expect(library.metadata.metadata(forBookID: new.path)?.author == "A")
    }

    @Test("本を開いたときの付け替えも、新しいパスの読みだけの行を置き換え、元のパスを返す")
    func reconcileOnOpenReplacesAParsedOnlyRow() throws {
        let library = try InMemoryLibrary(label: "outside-move-open")
        defer { library.close() }
        let temporary = try TemporaryDirectory("outside-move-open")
        let old = temporary.file("before.cbz")
        try Data("a".utf8).write(to: old)
        registerLocked(old, in: library)
        let new = temporary.file("after.cbz")
        try FileManager.default.moveItem(at: old, to: new)
        library.metadata.registerParsed(bookID: new.path, rules: library.metadataRules.rules)

        let book = MangaBook(id: new.path, title: "after", sourceURL: new, pages: [])
        #expect(library.metadata.reconcileBookIDIfMoved(book: book) == old.path)
        #expect(library.metadata.registeredBookIDs == [new.path])
        #expect(library.metadata.metadata(forBookID: new.path)?.author == "A")
    }

    @Test("本を開いたときの追従: 識別子を持たないメタデータの行も、ほかのストアが見つけた元のパスで付いてくる")
    func openingFollowsRowsWithoutIdentity() throws {
        // AppState.open と同じ手順(5 つの reconcile → 元のパスで applyBookRelocation)を、ストアの上で通す。
        let library = try InMemoryLibrary(label: "outside-move-open-all")
        defer { library.close() }
        let temporary = try TemporaryDirectory("outside-move-open-all")
        let old = temporary.file("before.cbz")
        try Data("a".utf8).write(to: old)
        // レイアウトは識別子つき、メタデータは識別子無し(メタデータの編集ウインドウが作った形)。
        library.layouts.setForcedDisplayMode(for: MangaBook(id: old.path, title: "before", sourceURL: old, pages: []), .single)
        library.metadata.upsertAll([.init(bookID: old.path, values: BookMetadataValues(title: "直した題"), state: .locked)])
        let new = temporary.file("after.cbz")
        try FileManager.default.moveItem(at: old, to: new)
        let book = MangaBook(id: new.path, title: "after", sourceURL: new, pages: [])

        let movedFrom = library.layouts.reconcileBookIDIfMoved(book: book)
        #expect(movedFrom == old.path)
        #expect(library.metadata.reconcileBookIDIfMoved(book: book) == nil, "識別子が無いので自分では見つけられない")
        let plan = BookRelocationPlan(bookIDs: [old.path: new.path], locators: [:], directoryBookIDs: [])
        library.metadata.applyBookRelocation(plan)

        #expect(library.metadata.metadata(forBookID: new.path)?.title == "直した題")
        #expect(library.metadata.metadata(forBookID: old.path) == nil)
    }

    @Test("一時フォルダへ書き出した入れ子の書庫の本は、保存データに何も残さない本として扱う(2026-09-22 の監査)")
    func temporaryCopiesLeaveNoRecord() {
        let temporary = TemporaryFileStore.makeFileURL(extension: "cbz")
        #expect(MangaBook(id: temporary.path, title: "x", sourceURL: temporary, pages: []).leavesNoRecord)
        let ordinary = URL(fileURLWithPath: "/Users/someone/book-a.cbz")
        #expect(!MangaBook(id: ordinary.path, title: "x", sourceURL: ordinary, pages: []).leavesNoRecord)
    }

    @Test("消したメタデータは、この起動の間だけ「消した」と覚える(ファイル名の読みだけの書き手には外させない)")
    func deletedRowsAreRememberedForTheSession() throws {
        let library = try InMemoryLibrary(label: "metadata-deleted")
        defer { library.close() }
        let bookID = "/nowhere/deleted.cbz"
        library.metadata.registerParsed(bookID: bookID, rules: library.metadataRules.rules)
        library.metadata.upsertAll([.init(bookID: bookID, values: nil)])
        #expect(library.metadata.deletedThisSession == [bookID])

        // スマートライブラリ・規則の読み直しと同じ書き方(onlyIfUnlocked)では外れない。
        library.metadata.upsertAll([.init(bookID: bookID, values: BookMetadataValues(title: "T"), onlyIfUnlocked: true)])
        #expect(library.metadata.deletedThisSession == [bookID])
        // 本を開いた・窓が登録した(読みだけではない書き手)なら外れる。
        library.metadata.upsertAll([.init(bookID: bookID, values: nil)])
        library.metadata.registerParsed(bookID: bookID, rules: library.metadataRules.rules)
        #expect(library.metadata.deletedThisSession.isEmpty)
    }

    @Test("読書位置も付け替える(新しいパスに既にあれば触らない)")
    func readingStatesFollow() throws {
        let library = try InMemoryLibrary(label: "outside-move-reading")
        defer { library.close() }
        library.context.insert(BookReadingState(bookID: "/x/old.cbz", lastPageIndex: 5))
        library.context.insert(BookReadingState(bookID: "/x/a.cbz"))
        library.context.insert(BookReadingState(bookID: "/x/b.cbz"))
        try library.context.save()

        BookRecordRelocator.relocateReadingStates(["/x/old.cbz": "/x/new.cbz", "/x/a.cbz": "/x/b.cbz"], in: library.context)

        let states = try library.context.fetch(FetchDescriptor<BookReadingState>())
        #expect(Set(states.map(\.bookID)) == ["/x/new.cbz", "/x/a.cbz", "/x/b.cbz"])
        #expect(states.first { $0.bookID == "/x/new.cbz" }?.lastPageIndex == 5)
    }

    @Test("コレクションの実在確認は、別の名前で見つかった本を知らせる")
    func collectionRefreshReportsRenamedBooks() async throws {
        let library = try InMemoryLibrary(label: "outside-move-collection")
        defer { library.close() }
        let temporary = try TemporaryDirectory("outside-move-collection")
        let old = temporary.file("before.cbz")
        try Data("a".utf8).write(to: old)
        let target = try #require(library.collections.libraries.first)
        let pending = try #require(CollectionStore.makePendingItem(for: old))
        _ = try #require(library.collections.createCollection(name: "Series", in: target, items: [pending]))
        await library.collections.settleExistenceRefresh()
        var reported: [FileSystemChange.Relocation] = []
        library.collections.onBooksFoundAtNewPaths = { reported += $0 }

        let new = temporary.file("after.cbz")
        try FileManager.default.moveItem(at: old, to: new)
        library.collections.scheduleExistenceRefresh()
        await library.collections.settleExistenceRefresh()

        #expect(reported.map(\.from.path) == [old.path])
        #expect(reported.map { BookExistenceProbe.comparablePath($0.to.path) } == [BookExistenceProbe.comparablePath(new.path)])
    }

    @Test("起動後の見回りは、ブックマークを持つ本の新しい名前を見つける(持たない本と、動いていない本は挙げない)")
    func theSweeperFindsRenamedBooks() async throws {
        let library = try InMemoryLibrary(label: "outside-move-sweep")
        defer { library.close() }
        let suite = PreferencesSuite(label: "outside-move-sweep")
        let temporary = try TemporaryDirectory("outside-move-sweep")
        let old = temporary.file("before.cbz"), still = temporary.file("still.cbz")
        try Data("a".utf8).write(to: old)
        try Data("a".utf8).write(to: still)
        registerLocked(old, in: library)
        registerLocked(still, in: library)
        library.context.insert(BookReadingState(bookID: temporary.file("no-bookmark.cbz").path))
        try library.context.save()
        let new = temporary.file("after.cbz")
        try FileManager.default.moveItem(at: old, to: new)

        let moved = await ExternalMoveSweeper.movedBooks(
            favoritesStore: library.favorites, collectionStore: library.collections, bookmarkStore: library.bookmarks,
            layoutStore: library.layouts, metadataStore: library.metadata,
            folderAccess: FolderAccessStore(defaults: suite.defaults), modelContext: library.context,
            skipsCollectionBooks: true)

        #expect(moved.map(\.from.path) == [old.path])
        #expect(moved.first.map { BookExistenceProbe.comparablePath($0.to.path) } == BookExistenceProbe.comparablePath(new.path))
    }

    @Test("ビューアで開いている本(その中・その上のフォルダも)の付け替えは見送る")
    func openBooksAreNotRelocated() {
        let relocations: [FileSystemChange.Relocation] = [
            .init(from: URL(fileURLWithPath: "/x/open.cbz"), to: URL(fileURLWithPath: "/x/open-renamed.cbz")),
            .init(from: URL(fileURLWithPath: "/y/shelf"), to: URL(fileURLWithPath: "/y/shelf-renamed")),
            .init(from: URL(fileURLWithPath: "/z/closed.cbz"), to: URL(fileURLWithPath: "/z/closed-renamed.cbz")),
        ]
        let kept = ExternalMoveSweeper.excludingOpenBooks(relocations, openBookIDs: ["/x/open.cbz", "/y/shelf/book-a"])
        #expect(kept.map(\.from.path) == ["/z/closed.cbz"])
        #expect(ExternalMoveSweeper.excludingOpenBooks(relocations, openBookIDs: []).count == 3)
    }

    @Test("繋がっていないボリュームの本は見ない")
    func unmountedVolumesAreSkipped() {
        let mounts = MountTable.current()
        #expect(ExternalMoveSweeper.isLocallyReachable("/Users/someone/book.cbz", mounts: mounts))
        #expect(!ExternalMoveSweeper.isLocallyReachable(
            "/Volumes/qooViewer-no-such-volume-\(UUID().uuidString)/book.cbz", mounts: mounts))
    }

    @Test("ゴミ箱へ移した本は付け替え先にしない(「無い」になる)")
    func aBookMovedToTheTrashIsNotARelocation() throws {
        let temporary = try TemporaryDirectory("outside-move-trash")
        let old = temporary.file("before.cbz")
        try Data("a".utf8).write(to: old)
        let bookmark = try old.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        // 本物のゴミ箱には触らない(CLAUDE.md)。ブックマークは移動を追うので、`.Trash` という名前のフォルダへ移せば同じ形になる。
        let trash = try temporary.directory(".Trash")
        try FileManager.default.moveItem(at: old, to: trash.appendingPathComponent("before.cbz"))

        let located = BookExistenceProbe(bookID: old.path, bookmarkCandidates: [bookmark], isPathCovered: true)
            .locateAtRecordedPath()
        #expect(located.result == .missing)
        #expect(located.movedTo == nil)
    }
}

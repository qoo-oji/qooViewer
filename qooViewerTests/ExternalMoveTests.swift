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

import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// アプリ自身が移した・名前を変えた本の保存データの付け替え(ViewModels/BookRecordRelocator.swift、Services/BookRelocation.swift。
/// 2026-09-19 の監査の H1)。ストアはテスト専用のライブラリ(InMemoryLibrary)の上。
@MainActor
struct BookRecordRelocatorTests {
    private func makeBookFolder(at url: URL) throws {
        try FixtureFolder.make(at: url, pages: [.init("001.jpg", number: 1)])
    }

    private func makeRelocator(_ library: InMemoryLibrary) -> BookRecordRelocator {
        BookRecordRelocator(
            favoritesStore: library.favorites, bookmarkStore: library.bookmarks, layoutStore: library.layouts,
            metadataStore: library.metadata, collectionStore: library.collections, modelContext: library.context
        )
    }

    /// 1 冊ぶんの保存データ(棚・ブックマーク・メタデータ・読書位置)を付ける。
    private func register(_ book: URL, in library: InMemoryLibrary) throws -> BookCollection {
        let target = try #require(library.collections.libraries.first)
        let pending = try #require(CollectionStore.makePendingItem(for: book))
        let collection = try #require(library.collections.createCollection(name: "Series", in: target, items: [pending]))
        #expect(library.bookmarks.addBookmark(
            bookID: book.path, pageIndex: 0, name: "p1", fileNodeIdentifier: FileNodeIdentifier.current(for: book)
        ))
        _ = library.metadata.upsert(bookID: book.path, author: "A", title: "T", series: "", seriesIndex: "", sourceURL: book)
        library.context.insert(BookReadingState(bookID: book.path))
        try library.context.save()
        return collection
    }

    @Test("フォルダごと名前を変えても、中の本の保存データは新しいパスへ付いていく(本を開かなくても)")
    func recordsFollowARenamedParentFolder() async throws {
        let library = try InMemoryLibrary(label: "relocator-rename")
        defer { library.close() }
        let temporary = try TemporaryDirectory("relocator-rename")
        let shelf = try temporary.directory("shelf")
        let book = shelf.appendingPathComponent("book-a", isDirectory: true)
        try makeBookFolder(at: book)
        let collection = try register(book, in: library)

        let renamedShelf = temporary.file("shelf-renamed")
        try FileManager.default.moveItem(at: shelf, to: renamedShelf)
        let newPath = renamedShelf.appendingPathComponent("book-a").path
        await makeRelocator(library).apply(FileSystemChange(relocations: [.init(from: shelf, to: renamedShelf)])).value

        #expect(library.collections.allRegisteredBookIDs() == [newPath])
        #expect(collection.items.map(\.title) == ["book-a"], "本の名前は変わっていないのでキャプションはそのまま")
        #expect(library.bookmarks.bookmarks(forBookID: newPath).count == 1)
        #expect(library.bookmarks.bookmarks(forBookID: book.path).isEmpty)
        #expect(library.metadata.metadata(forBookID: newPath)?.author == "A")
        let states = try library.context.fetch(FetchDescriptor<BookReadingState>())
        #expect(states.map(\.bookID) == [newPath])
    }

    @Test("本そのものの名前を変えたら、棚のキャプションも新しいファイル名になる。取り消しで戻せば元へ戻る")
    func theShelfCaptionFollowsTheBooksOwnRename() async throws {
        let library = try InMemoryLibrary(label: "relocator-caption")
        defer { library.close() }
        let temporary = try TemporaryDirectory("relocator-caption")
        let book = temporary.file("book-a")
        try makeBookFolder(at: book)
        let collection = try register(book, in: library)
        let relocator = makeRelocator(library)

        let renamed = temporary.file("book-b")
        try FileManager.default.moveItem(at: book, to: renamed)
        await relocator.apply(FileSystemChange(relocations: [.init(from: book, to: renamed)])).value
        #expect(library.collections.allRegisteredBookIDs() == [renamed.path])
        #expect(collection.items.map(\.title) == ["book-b"])

        try FileManager.default.moveItem(at: renamed, to: book)
        await relocator.apply(FileSystemChange(relocations: [.init(from: renamed, to: book)])).value
        #expect(library.collections.allRegisteredBookIDs() == [book.path])
        #expect(collection.items.map(\.title) == ["book-a"])
        #expect(library.bookmarks.bookmarks(forBookID: book.path).count == 1)
    }

    @Test("移った先のパスにすでに行があるストアでは付け替えない(置き換えた本の行と混ぜない)")
    func anOccupiedDestinationIsLeftAlone() async throws {
        let library = try InMemoryLibrary(label: "relocator-occupied")
        defer { library.close() }
        let temporary = try TemporaryDirectory("relocator-occupied")
        let from = temporary.file("from"), to = temporary.file("to")
        try makeBookFolder(at: from)
        try makeBookFolder(at: to)
        #expect(library.bookmarks.addBookmark(bookID: from.path, pageIndex: 0, name: "from"))
        #expect(library.bookmarks.addBookmark(bookID: to.path, pageIndex: 0, name: "to"))

        await makeRelocator(library).apply(FileSystemChange(relocations: [.init(from: from, to: to)])).value
        #expect(library.bookmarks.bookmarks(forBookID: from.path).map(\.name) == ["from"])
        #expect(library.bookmarks.bookmarks(forBookID: to.path).map(\.name) == ["to"])
    }

    @Test("「置き換える」で移した本は、置き換えられた本の保存データを消してから付け替える(2026-09-22 の監査)")
    func aReplacedDestinationGivesWayToTheMovedBook() async throws {
        let library = try InMemoryLibrary(label: "relocator-replace")
        defer { library.close() }
        let temporary = try TemporaryDirectory("relocator-replace")
        let from = temporary.file("from"), to = temporary.file("to")
        try makeBookFolder(at: from)
        try makeBookFolder(at: to)
        #expect(library.bookmarks.addBookmark(bookID: from.path, pageIndex: 0, name: "moved"))
        #expect(library.bookmarks.addBookmark(bookID: to.path, pageIndex: 0, name: "replaced"))
        library.context.insert(BookReadingState(bookID: to.path, lastPageIndex: 9))
        try library.context.save()

        await makeRelocator(library).apply(FileSystemChange(relocations: [.init(from: from, to: to)], replaced: [to])).value

        #expect(library.bookmarks.bookmarks(forBookID: to.path).map(\.name) == ["moved"])
        #expect(library.bookmarks.bookmarks(forBookID: from.path).isEmpty)
        let states = try library.context.fetch(FetchDescriptor<BookReadingState>())
        #expect(states.isEmpty, "置き換えられた本の読書位置は消える(移した本は読書位置を持っていなかった)")
    }

    @Test("置き換えられた本がゴミ箱へ行ったなら、保存データもゴミ箱の中へ付け替え、⌘Z で戻すと元へ戻る(2026-09-23 の 3 回目の監査の中 1)")
    func aReplacedBookThatWentToTheTrashKeepsItsData() async throws {
        let library = try InMemoryLibrary(label: "relocator-replace-trash")
        defer { library.close() }
        let temporary = try TemporaryDirectory("relocator-replace-trash")
        let from = temporary.file("from"), to = temporary.file("to"), trashed = temporary.file("PseudoTrash/to")
        try makeBookFolder(at: from)
        try makeBookFolder(at: to)
        #expect(library.bookmarks.addBookmark(bookID: from.path, pageIndex: 0, name: "moved"))
        #expect(library.bookmarks.addBookmark(bookID: to.path, pageIndex: 0, name: "replaced"))
        library.context.insert(BookReadingState(bookID: to.path, lastPageIndex: 9))
        try library.context.save()
        let relocator = makeRelocator(library)

        await relocator.apply(FileSystemChange(
            relocations: [.init(from: from, to: to)], replaced: [to], replacedIntoTrash: [.init(from: to, to: trashed)]
        )).value
        #expect(library.bookmarks.bookmarks(forBookID: to.path).map(\.name) == ["moved"])
        #expect(library.bookmarks.bookmarks(forBookID: trashed.path).map(\.name) == ["replaced"], "置き換えられた本の保存データを消した")
        #expect(try library.context.fetch(FetchDescriptor<BookReadingState>()).map(\.bookID) == [trashed.path])

        // ⌘Z: 移した本を元へ戻し(移動の取り消し)、置き換えられた本をゴミ箱から戻す。
        await relocator.apply(FileSystemChange(relocations: [.init(from: to, to: from)])).value
        await relocator.apply(FileSystemChange(returnedFromTrash: [.init(from: trashed, to: to)])).value
        #expect(library.bookmarks.bookmarks(forBookID: from.path).map(\.name) == ["moved"])
        #expect(library.bookmarks.bookmarks(forBookID: to.path).map(\.name) == ["replaced"])
        #expect(try library.context.fetch(FetchDescriptor<BookReadingState>()).map(\.bookID) == [to.path])
    }

    @Test("別ボリュームへ移した本も付いていく: inode とブックマークを新しい場所で取り直し、棚で「見つからない」にならない")
    func recordsFollowAMoveToAnotherVolume() async throws {
        // 以前は inode が変わるので追えず(docs/06「ボリュームをまたぐ移動は諦める」)、棚では見つからない本になり、次の起動の掃除の候補に挙がった。
        guard let volume = DisposableVolume.make(.apfs, "relocator-volume") else { return }
        let library = try InMemoryLibrary(label: "relocator-volume")
        defer { library.close() }
        let temporary = try TemporaryDirectory("relocator-volume")
        let book = temporary.file("book-a")
        try makeBookFolder(at: book)
        _ = try register(book, in: library)
        let before = try #require(FileNodeIdentifier.current(for: book))

        let service = FileOperationService(environment: .pseudoTrash(at: try temporary.directory("PseudoTrash")))
        let outcome = try await service.move([book], to: volume.url)
        let moved = try #require(outcome.receipts.first).destination
        await makeRelocator(library).apply(FileSystemChange(relocations: [.init(from: book, to: moved)])).value

        #expect(library.collections.allRegisteredBookIDs() == [moved.path])
        let item = try #require(library.collections.allItems().first)
        let after = try #require(item.fileNodeIdentifier)
        #expect(after != before)
        #expect(after == FileNodeIdentifier.current(for: moved))
        #expect(library.collections.location(for: item).exists, "移した先の本が棚で見つからない扱いになった")
        #expect(library.bookmarks.bookmarks(forBookID: moved.path).first?.fileNodeIdentifier == after)
    }
}

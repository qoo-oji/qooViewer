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

    // MARK: - 付け替えの知らせ(2026-10-04 の監査 §1-7。BookRelocationNotice)

    /// 届いた付け替えの知らせを控える(並んで走るほかのテストの知らせも届くので、受け手は自分のパスで引く)。
    /// `onNotice` は知らせが**届いたその時点で**呼ぶ(受け手がそこでストアを引けるか ―― 順序を確かめる)。
    private final class NoticeRecorder {
        private(set) var notices: [BookRelocationNotice] = []
        private var token: NSObjectProtocol?

        init(onNotice: (@MainActor (BookRelocationNotice) -> Void)? = nil) {
            token = NotificationCenter.default.addObserver(forName: .booksDidRelocate, object: nil, queue: nil) { [weak self] note in
                guard let notice = BookRelocationNotice(note) else { return }
                MainActor.assumeIsolated {
                    self?.notices.append(notice)
                    onNotice?(notice)
                }
            }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }

        func newBookID(for bookID: String) -> String? {
            notices.lazy.compactMap { $0.newBookID(for: bookID) }.first
        }
    }

    @Test("付け替え終えたら、画面が握っている bookID のために旧 → 新を知らせる。どのストアにも行の無い本にも答える")
    func relocatingPostsTheOldToNewNotice() async throws {
        let library = try InMemoryLibrary(label: "relocator-notice")
        defer { library.close() }
        let temporary = try TemporaryDirectory("relocator-notice")
        let shelf = try temporary.directory("shelf")
        let book = shelf.appendingPathComponent("book-a", isDirectory: true)
        try makeBookFolder(at: book)
        _ = try register(book, in: library)
        let renamedShelf = temporary.file("shelf-renamed")
        let newPath = renamedShelf.appendingPathComponent("book-a").path
        // 知らせはストアを書き換え終えた後に届く(受け手が新しい bookID でストアを引ける)。届いたその時点で引いて確かめる
        // (2026-10-04 のレビューの R4-5: 以前は apply を待ち終えてから引いていたので、届いた時点の順序を見ていなかった)。
        let bookmarksSeenAtNotice = RelocatorTestBox<[Int]>([])
        let recorder = NoticeRecorder { notice in
            guard let new = notice.newBookID(for: book.path) else { return }
            bookmarksSeenAtNotice.value.append(library.bookmarks.bookmarks(forBookID: new).count)
        }

        try FileManager.default.moveItem(at: shelf, to: renamedShelf)
        await makeRelocator(library).apply(FileSystemChange(relocations: [.init(from: shelf, to: renamedShelf)])).value

        #expect(recorder.newBookID(for: book.path) == newPath)
        #expect(bookmarksSeenAtNotice.value == [1], "知らせが届いた時点で、移った先にブックマークが無かった")
        // 行の無い本(インスペクタで初めて打っている本)も、同じ知らせで引き直せる。
        let unknown = shelf.appendingPathComponent("not-registered.cbz").path
        #expect(recorder.newBookID(for: unknown) == renamedShelf.appendingPathComponent("not-registered.cbz").path)
        #expect(recorder.newBookID(for: temporary.file("elsewhere").path) == nil)
    }

    @Test("知らせの引き直しは、移った先にすでに値があればそちらを残し、2 つが同じ先へ移ったら名前順で先のほう")
    func rekeyingKeepsWhatIsAlreadyAtTheDestination() {
        let notice = BookRelocationNotice(change: FileSystemChange(relocations: [
            .init(from: URL(fileURLWithPath: "/架空/a"), to: URL(fileURLWithPath: "/架空/b")),
        ]))
        #expect(notice.rekeyed(["/架空/a": 1, "/架空/c": 3]) == ["/架空/b": 1, "/架空/c": 3])
        #expect(notice.rekeyed(["/架空/a": 1, "/架空/b": 2]) == ["/架空/b": 2])
        #expect(notice.rekeyed(Set(["/架空/a/1.jpg", "/架空/c"])) == Set(["/架空/b/1.jpg", "/架空/c"]))
        #expect(notice.current("/架空/c") == "/架空/c")
        // 2 つが同じ先へ移ったら、古い bookID の名前順で先のほう(2026-10-04 のレビューの R4-5: 名前にあるのに確かめていなかった)。
        let merged = BookRelocationNotice(change: FileSystemChange(relocations: [
            .init(from: URL(fileURLWithPath: "/架空/y"), to: URL(fileURLWithPath: "/架空/z")),
            .init(from: URL(fileURLWithPath: "/架空/x"), to: URL(fileURLWithPath: "/架空/z")),
        ]))
        #expect(merged.rekeyed(["/架空/y": 2, "/架空/x": 1]) == ["/架空/z": 1])
    }

    // MARK: - 計画を作っている間の書き込み(2026-10-04 のレビューの R4-1)

    @Test("付け替えの計画を作っている間に古い bookID へ書かれた行も運ぶ(知らせの前にインスペクタの欄が消えて書いた行。R4-1)")
    func rowsWrittenWhilePlanningAreCarried() async throws {
        let library = try InMemoryLibrary(label: "relocator-while-planning")
        defer { library.close() }
        let temporary = try TemporaryDirectory("relocator-while-planning")
        let shelf = try temporary.directory("shelf")
        // ほかの本の行(どのストアにも行が無いと、計画を作らずに終わる ―― 待つ間も無い)。
        let other = shelf.appendingPathComponent("other-book", isDirectory: true)
        try makeBookFolder(at: other)
        _ = try register(other, in: library)
        // インスペクタで初めて打っている、行の無い本。
        let book = shelf.appendingPathComponent("book-a.cbz")
        try Data("a".utf8).write(to: book)
        let renamed = shelf.appendingPathComponent("book-b.cbz")
        try FileManager.default.moveItem(at: book, to: renamed)

        let relocator = makeRelocator(library)
        // アプリでの順: アプリの中の変更の知らせで一覧が選択を書き換え、欄が消えて古い bookID へ書く ―― それが、付け替え役が計画を
        // メインの外で作っている間に起きた。
        let wroteWhilePlanning = RelocatorTestBox(false)
        relocator.afterPlanningForTesting = {
            guard !wroteWhilePlanning.value else { return }
            wroteWhilePlanning.value = true
            library.metadata.upsertAll([BookMetadataStore.BatchEntry(
                bookID: book.path, values: BookMetadataValues(title: "打ちかけの題"), sourceURL: nil,
                state: BookMetadataRowState(isLocked: false))])
        }
        let rowSeenAtNotice = RelocatorTestBox<String?>(nil)
        let recorder = NoticeRecorder { notice in
            guard let new = notice.newBookID(for: book.path) else { return }
            rowSeenAtNotice.value = library.metadata.metadata(forBookID: new)?.title
        }

        await relocator.apply(FileSystemChange(relocations: [.init(from: book, to: renamed)])).value

        #expect(wroteWhilePlanning.value)
        #expect(library.metadata.metadata(forBookID: book.path) == nil, "古い bookID の行が実在しないパスに取り残された")
        #expect(library.metadata.metadata(forBookID: renamed.path)?.title == "打ちかけの題")
        #expect(recorder.newBookID(for: book.path) == renamed.path)
        #expect(rowSeenAtNotice.value == "打ちかけの題", "知らせが届いた時点で、移った先に行が無かった")
    }
}

/// 閉包から書き換える値の箱。
@MainActor
private final class RelocatorTestBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

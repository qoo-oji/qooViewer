import Foundation
import Testing

@testable import qooViewer

/// 保存データの削除の取り消し(DataUndoStack。2026-09-27、監査 34)。
///
/// 押さえるのは:
/// - 取り消した行が**元の行と見分けが付かない**こと(id・日付・並び・ピン留め)
/// - 取り消せる間はコレクションの表紙のファイルを消さず、取り消せなくなったら消すこと
/// - 消した後に同じものが足されていたら、取り消しで二重にしないこと
/// - 積み場所の深さとやり直し先の捨て方
@MainActor
struct DataUndoTests {
    private func makeBookFolder(_ temporary: TemporaryDirectory, named name: String) throws -> URL {
        let directory = temporary.file(name)
        try FixtureFolder.make(at: directory, pages: [.init("001.jpg", number: 1)])
        return directory
    }

    private func pendingItems(_ urls: [URL]) -> [CollectionStore.PendingItem] {
        urls.compactMap { CollectionStore.makePendingItem(for: $0) }
    }

    /// 非同期に走る後始末(表紙のファイルの削除)を待つ。時間ではなく条件で待つ。
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("条件が満たされない")
    }

    /// 消えないことを確かめるために、裏の後始末が走る機会を与える。
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// 積み場所を深さいっぱいまで埋めて、先に積んだものを捨てさせる。
    private func overflow(_ stack: DataUndoStack) {
        for _ in 0..<DataUndoStack.depth { stack.push(NoOpStep()) }
    }

    // MARK: - 積み場所

    @Test("取り消すとやり直し先へ移り、新しい操作を積むとやり直し先は捨てられる")
    func redoIsDroppedByANewStep() {
        let stack = DataUndoStack()
        let first = NoOpStep(title: "一")
        let second = NoOpStep(title: "二")
        stack.push(first)
        #expect(stack.undoTitle == "一")
        stack.undo()
        #expect(stack.undoTitle == nil)
        #expect(stack.redoTitle == "一")
        stack.push(second)
        #expect(stack.redoTitle == nil)
        #expect(first.discardCount == 1)
        #expect(stack.undoTitle == "二")
    }

    @Test("深さを超えたら古いものから捨てられる")
    func theOldestStepIsDiscardedBeyondTheDepth() {
        let stack = DataUndoStack()
        let oldest = NoOpStep(title: "最初")
        stack.push(oldest)
        overflow(stack)
        #expect(oldest.discardCount == 1)
    }

    @Test("すべて捨てると、取り消し先もやり直し先も空になり、どれも後片付けされる(道具のウインドウを閉じたとき。2026-10-04 の監査 BE-11)")
    func removeAllEmptiesBothSidesAndDiscardsEverything() {
        let stack = DataUndoStack()
        let undone = NoOpStep(title: "一")
        let pending = NoOpStep(title: "二")
        stack.push(undone)
        stack.push(pending)
        stack.undo()
        #expect(stack.undoTitle == "一")
        #expect(stack.redoTitle == "二")

        stack.removeAll()
        #expect(stack.undoTitle == nil)
        #expect(stack.redoTitle == nil)
        #expect(undone.discardCount == 1)
        #expect(pending.discardCount == 1)
        // 空になった後の ⌘Z は何も戻さない(以前は閉じて開き直した窓で、前回の削除が戻った)。
        stack.undo()
        #expect(undone.undoCount == 0)
    }

    @Test("戻せなかった操作は捨てられ、次の操作が出る")
    func aStepThatCannotUndoIsDropped() {
        let stack = DataUndoStack()
        let kept = NoOpStep(title: "残る")
        let failing = NoOpStep(title: "戻せない", undoSucceeds: false)
        stack.push(kept)
        stack.push(failing)
        stack.undo()
        #expect(failing.discardCount == 1)
        #expect(stack.undoTitle == "残る")
        #expect(stack.redoTitle == nil)
    }

    // MARK: - コレクション

    @Test("コレクションの削除を取り消すと、同じ id・日付・並び・ピン留めで戻り、表紙のファイルは消えていない")
    func undoingACollectionDeletionRestoresItExactly() async throws {
        let library = try InMemoryLibrary(label: "undo-collection")
        defer { library.close() }
        let temporary = try TemporaryDirectory("undo-collection")
        let store = library.collections
        let home = try #require(store.libraries.first)
        let books = try ["a", "b"].map { try makeBookFolder(temporary, named: "book-\($0)") }
        let collection = try #require(store.createCollection(name: "シリーズ", in: home, items: pendingItems(books)))
        store.setPinnedCollection(collection, atStart: true, in: home)
        let before = collection.items.map { ($0.id, $0.bookID, $0.addedAt, $0.sortOrder) }.sorted { $0.3 < $1.3 }
        let createdAt = collection.createdAt
        let coverURLs = collection.items.map { store.coverStore.url(for: $0.id) }
        for item in collection.items {
            try await library.collectionCovers.write(PageImageFactory.cgImage(number: 1), for: item.id)
        }
        let collectionID = collection.id
        let stack = DataUndoStack()

        DataUndoStack.deleteCollections([collection], in: store, recordingOn: stack)
        #expect(store.collection(withID: collectionID) == nil)
        #expect(home.pinnedFirstCollectionID == nil)
        await settle()
        #expect(coverURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        stack.undo()
        let restored = try #require(store.collection(withID: collectionID))
        #expect(restored.name == "シリーズ")
        #expect(restored.createdAt == createdAt)
        #expect(restored.library?.id == home.id)
        #expect(home.pinnedFirstCollectionID == collectionID)
        let after = restored.items.map { ($0.id, $0.bookID, $0.addedAt, $0.sortOrder) }.sorted { $0.3 < $1.3 }
        #expect(after.map(\.0) == before.map(\.0))
        #expect(after.map(\.1) == before.map(\.1))
        #expect(after.map(\.2) == before.map(\.2))

        stack.redo()
        #expect(store.collection(withID: collectionID) == nil)
        await settle()
        #expect(coverURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        // 取り消せなくなったら(積み場所から落ちたら)表紙のファイルを消す。
        overflow(stack)
        await waitUntil { coverURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
    }

    @Test("取り消した後に積み場所から落ちても、戻っているコレクションの表紙は消さない")
    func discardingAnUndoneDeletionKeepsTheCovers() async throws {
        let library = try InMemoryLibrary(label: "undo-collection-kept")
        defer { library.close() }
        let temporary = try TemporaryDirectory("undo-collection-kept")
        let store = library.collections
        let home = try #require(store.libraries.first)
        let book = try makeBookFolder(temporary, named: "book")
        let collection = try #require(store.createCollection(name: "A", in: home, items: pendingItems([book])))
        let item = try #require(collection.items.first)
        try await library.collectionCovers.write(PageImageFactory.cgImage(number: 1), for: item.id)
        let coverURL = store.coverStore.url(for: item.id)
        let stack = DataUndoStack()

        DataUndoStack.deleteCollections([collection], in: store, recordingOn: stack)
        stack.undo()
        // 新しい操作を積むと、やり直し先(= 取り消した削除)が捨てられる。
        stack.push(NoOpStep())
        await settle()
        #expect(FileManager.default.fileExists(atPath: coverURL.path))
    }

    @Test("ライブラリの削除を取り消すと、中のコレクションごと戻る。同じ名前が作られていたら番号を足す")
    func undoingALibraryDeletionRestoresItsCollections() throws {
        let library = try InMemoryLibrary(label: "undo-library")
        defer { library.close() }
        let temporary = try TemporaryDirectory("undo-library")
        let store = library.collections
        let target = try #require(store.createLibrary(name: "棚"))
        let book = try makeBookFolder(temporary, named: "book")
        let collection = try #require(store.createCollection(name: "A", in: target, items: pendingItems([book])))
        let libraryID = target.id
        let collectionID = collection.id
        let stack = DataUndoStack()

        DataUndoStack.deleteLibrary(target, in: store, recordingOn: stack)
        #expect(store.library(withID: libraryID) == nil)
        #expect(store.collection(withID: collectionID) == nil)
        // 消した後に、同じ名前のライブラリを作った。
        _ = try #require(store.createLibrary(name: "棚"))

        stack.undo()
        let restored = try #require(store.library(withID: libraryID))
        #expect(restored.name == "棚 2")
        #expect(store.collection(withID: collectionID)?.library?.id == libraryID)
    }

    // MARK: - コレクションからの削除

    @Test("コレクションから外した本を取り消すと、同じ id で戻り、コレクションの更新日も元に戻る")
    func undoingARemovalRestoresTheItems() async throws {
        let library = try InMemoryLibrary(label: "undo-removal")
        defer { library.close() }
        let temporary = try TemporaryDirectory("undo-removal")
        let store = library.collections
        let home = try #require(store.libraries.first)
        let books = try ["a", "b", "c"].map { try makeBookFolder(temporary, named: "book-\($0)") }
        let collection = try #require(store.createCollection(name: "S", in: home, items: pendingItems(books)))
        let updatedAt = collection.updatedAt
        let removed = Array(store.items(in: collection, sort: .nameAscending).prefix(2))
        let removedIDs = removed.map(\.id)
        let addedAt = removed.map(\.addedAt)
        let coverURLs = removedIDs.map { store.coverStore.url(for: $0) }
        for id in removedIDs {
            try await library.collectionCovers.write(PageImageFactory.cgImage(number: 1), for: id)
        }
        let stack = DataUndoStack()

        DataUndoStack.removeItems(removed, in: store, recordingOn: stack)
        #expect(store.items(in: collection, sort: .nameAscending).count == 1)
        await settle()
        #expect(coverURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        stack.undo()
        #expect(store.items(in: collection, sort: .nameAscending).count == 3)
        #expect(removedIDs.map { store.item(withID: $0)?.addedAt } == addedAt)
        #expect(collection.updatedAt == updatedAt)

        stack.redo()
        #expect(store.items(in: collection, sort: .nameAscending).count == 1)
        overflow(stack)
        await waitUntil { coverURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
    }

    @Test("外した後に同じ本が足し直されていたら(自動登録フォルダなど)、取り消しで二重にしない")
    func undoingARemovalDoesNotDuplicateAReaddedBook() throws {
        let library = try InMemoryLibrary(label: "undo-removal-readded")
        defer { library.close() }
        let temporary = try TemporaryDirectory("undo-removal-readded")
        let store = library.collections
        let home = try #require(store.libraries.first)
        let books = try ["a", "b"].map { try makeBookFolder(temporary, named: "book-\($0)") }
        let collection = try #require(store.createCollection(name: "S", in: home, items: pendingItems(books)))
        let removed = try #require(store.items(in: collection, sort: .nameAscending).first)
        let removedURL = URL(fileURLWithPath: removed.bookID)
        let stack = DataUndoStack()

        DataUndoStack.removeItems([removed], in: store, recordingOn: stack)
        _ = store.add(pendingItems([removedURL]), to: collection)
        #expect(store.items(in: collection, sort: .nameAscending).count == 2)

        stack.undo()
        #expect(store.items(in: collection, sort: .nameAscending).count == 2)
    }

    // MARK: - ブックマーク

    @Test("ブックマークの削除を取り消すと、同じ id・作成日で戻る。同じページに足されていたら戻さない")
    func undoingABookmarkDeletionRestoresIt() throws {
        let library = try InMemoryLibrary(label: "undo-bookmark")
        defer { library.close() }
        let store = library.bookmarks
        let bookID = "/tmp/undo-bookmark-book"
        store.addBookmark(bookID: bookID, pageIndex: 3, pageKey: "p3", name: "三")
        store.addBookmark(bookID: bookID, pageIndex: 7, pageKey: "p7", name: "七")
        let targets = store.bookmarks(forBookID: bookID)
        let original = targets.map(\.snapshot).sorted { $0.pageIndex < $1.pageIndex }
        let stack = DataUndoStack()

        DataUndoStack.deleteBookmarks(targets, in: store, recordingOn: stack)
        #expect(store.bookmarks(forBookID: bookID).isEmpty)
        // 消した後に、7 ページ目へ別のブックマークを付けた(本を開いて目次から取り込み直した、など)。
        store.addBookmark(bookID: bookID, pageIndex: 7, pageKey: "p7", name: "新しい七")

        stack.undo()
        let restored = store.bookmarks(forBookID: bookID).map(\.snapshot).sorted { $0.pageIndex < $1.pageIndex }
        #expect(restored.count == 2)
        #expect(restored.first == original.first)
        #expect(restored.last?.name == "新しい七")

        stack.redo()
        #expect(store.bookmarks(forBookID: bookID).map(\.name) == ["新しい七"])
    }

    @Test("1 冊分のブックマークを全部消しても取り消せる")
    func undoingDeleteAllBookmarksOfABook() throws {
        let library = try InMemoryLibrary(label: "undo-bookmark-all")
        defer { library.close() }
        let store = library.bookmarks
        let bookID = "/tmp/undo-bookmark-all-book"
        for index in 0..<4 { store.addBookmark(bookID: bookID, pageIndex: index, pageKey: "p\(index)", name: "\(index)") }
        let stack = DataUndoStack()

        DataUndoStack.deleteAllBookmarks(forBookID: bookID, in: store, recordingOn: stack)
        #expect(store.bookmarks(forBookID: bookID).isEmpty)
        stack.undo()
        #expect(store.bookmarks(forBookID: bookID).count == 4)
    }

    // MARK: - 履歴

    @Test("履歴の削除を取り消すと元の位置へ戻る。すべて削除も戻せる")
    func undoingAHistoryRemovalRestoresThePosition() throws {
        let suite = PreferencesSuite(label: "undo-history")
        let temporary = try TemporaryDirectory("undo-history")
        let store = RecentFilesStore(defaults: suite.defaults)
        for name in ["c", "b", "a"] {
            let url = temporary.file("\(name).cbz")
            try Data().write(to: url)
            store.record(url: url)
        }
        let order = store.entries.map(\.path)
        let stack = DataUndoStack()

        DataUndoStack.removeHistory([store.entries[1]], in: store, recordingOn: stack)
        #expect(store.entries.map(\.path) == [order[0], order[2]])
        stack.undo()
        #expect(store.entries.map(\.path) == order)

        DataUndoStack.removeAllHistory(in: store, recordingOn: stack)
        #expect(store.entries.isEmpty)
        stack.undo()
        #expect(store.entries.map(\.path) == order)
    }

    @Test("消した後に同じ本を開き直していたら、取り消しで二重にしない")
    func undoingAHistoryRemovalDoesNotDuplicateAReopenedBook() throws {
        let suite = PreferencesSuite(label: "undo-history-reopened")
        let temporary = try TemporaryDirectory("undo-history-reopened")
        let store = RecentFilesStore(defaults: suite.defaults)
        let urls = try ["b", "a"].map { name -> URL in
            let url = temporary.file("\(name).cbz")
            try Data().write(to: url)
            store.record(url: url)
            return url
        }
        let stack = DataUndoStack()

        DataUndoStack.removeAllHistory(in: store, recordingOn: stack)
        store.record(url: urls[0])
        stack.undo()
        #expect(store.entries.count == 2)
        #expect(Set(store.entries.map(\.path)).count == 2)
    }
}

/// 積み場所の振る舞いだけを見るための、何もしない操作。
@MainActor
private final class NoOpStep: DataUndoStep {
    let title: String
    private let undoSucceeds: Bool
    private(set) var discardCount = 0
    private(set) var undoCount = 0

    init(title: String = "何もしない", undoSucceeds: Bool = true) {
        self.title = title
        self.undoSucceeds = undoSucceeds
    }

    func undo() -> Bool {
        undoCount += 1
        return undoSucceeds
    }
    func redo() -> Bool { true }
    func discard() { discardCount += 1 }
}

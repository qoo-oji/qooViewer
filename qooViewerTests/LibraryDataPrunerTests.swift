import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// 読書状態の刈り込み(Services/LibraryDataPruner.swift)。
///
/// 消える側の処理なので、**何を消さないか**が本題:
/// - ブックマーク・レイアウト設定・書誌メタデータは対象外(設計コンセプト 10.3。手間をかけて
///   作ったものが履歴の古さだけで消えないようにする)。
/// - いまどこかのウインドウで開いている本は消さない(消すと、その `ViewerViewModel` が
///   削除済みのオブジェクトへ書き込み続けることになる)。
@MainActor
struct LibraryDataPrunerTests {
    /// `updatedAt` を明示した読書状態を `count` 件入れる。古い順に book0, book1, … になる。
    private func seed(_ library: InMemoryLibrary, count: Int) {
        let base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<count {
            let state = BookReadingState(bookID: "/books/book\(index)")
            state.updatedAt = base.addingTimeInterval(TimeInterval(index))
            library.context.insert(state)
        }
        try? library.context.save()
    }

    private func bookIDs(_ library: InMemoryLibrary) -> [String] {
        let descriptor = FetchDescriptor<BookReadingState>(
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        return ((try? library.context.fetch(descriptor)) ?? []).map(\.bookID)
    }

    @Test("上限以下なら何もしない")
    func nothingHappensBelowTheLimit() throws {
        let library = try InMemoryLibrary(label: "pruner-under")
        defer { library.close() }
        seed(library, count: 5)

        LibraryDataPruner.pruneIfNeeded(modelContext: library.context, maxTrackedBooks: 5, excludedBookIDs: [])
        #expect(bookIDs(library).count == 5)
        LibraryDataPruner.pruneIfNeeded(modelContext: library.context, maxTrackedBooks: 10, excludedBookIDs: [])
        #expect(bookIDs(library).count == 5)
    }

    @Test("上限が 0 以下なら何もしない(「無制限」を消し尽くしと取り違えない)")
    func aNonPositiveLimitIsIgnored() throws {
        let library = try InMemoryLibrary(label: "pruner-zero")
        defer { library.close() }
        seed(library, count: 5)

        LibraryDataPruner.pruneIfNeeded(modelContext: library.context, maxTrackedBooks: 0, excludedBookIDs: [])
        LibraryDataPruner.pruneIfNeeded(modelContext: library.context, maxTrackedBooks: -1, excludedBookIDs: [])
        #expect(bookIDs(library).count == 5)
    }

    @Test("超過したぶんだけ、最後に読んだ時刻が古い順に消す")
    func theOldestBooksAreRemovedDownToTheLimit() throws {
        let library = try InMemoryLibrary(label: "pruner-trim")
        defer { library.close() }
        seed(library, count: 10)

        LibraryDataPruner.pruneIfNeeded(modelContext: library.context, maxTrackedBooks: 6, excludedBookIDs: [])
        #expect(bookIDs(library) == (4..<10).map { "/books/book\($0)" })
    }

    @Test("開いている本は飛ばし、その次に古い本を消す(総数の上限は変わらず守られる)")
    func anOpenBookIsSkippedAndTheNextOldestGoesInstead() throws {
        let library = try InMemoryLibrary(label: "pruner-open")
        defer { library.close() }
        seed(library, count: 10)

        // 最も古い book0 と book1 が開きっぱなし。消えるのは book2〜book5。
        LibraryDataPruner.pruneIfNeeded(
            modelContext: library.context, maxTrackedBooks: 6,
            excludedBookIDs: ["/books/book0", "/books/book1"]
        )
        #expect(bookIDs(library) == ["/books/book0", "/books/book1"] + (6..<10).map { "/books/book\($0)" })
    }

    @Test("消せる本が足りなければ、消せるだけ消して上限を超えたままにする")
    func everythingBeingOpenLeavesTheCountAboveTheLimit() throws {
        let library = try InMemoryLibrary(label: "pruner-all-open")
        defer { library.close() }
        seed(library, count: 8)

        // 全部開いている ―― 削除済みのオブジェクトへ書き込ませないことを、上限より優先する。
        let allIDs = Set((0..<8).map { "/books/book\($0)" })
        LibraryDataPruner.pruneIfNeeded(
            modelContext: library.context, maxTrackedBooks: 3, excludedBookIDs: allIDs)
        #expect(bookIDs(library).count == 8)
    }

    @Test("ブックマーク・レイアウト設定・書誌メタデータは道連れにしない")
    func theOtherSavedDataSurvivesThePrune() async throws {
        let library = try InMemoryLibrary(label: "pruner-keeps")
        defer { library.close() }
        let temporary = try TemporaryDirectory("pruner-keeps")
        let directory = temporary.file("book")
        try FixtureFolder.make(at: directory, pages: [.init("001.jpg", number: 1), .init("002.jpg", number: 2)])
        let book = try await FixtureBook.load(directory)

        // 3 種類の保存データを持つ本の読書状態を、**最も古い**行として入れる
        // ―― 確実に刈り込みの対象になる位置。
        let state = BookReadingState(bookID: book.id)
        state.updatedAt = Date(timeIntervalSince1970: 1)
        library.context.insert(state)
        seed(library, count: 5)

        let pageKey = try #require(book.pages.first?.sortKey)
        library.bookmarks.addBookmark(bookID: book.id, pageIndex: 0, pageKey: pageKey, name: "しおり")
        library.layouts.setPageLayoutState(for: book, pageKey: pageKey, state: .spreadLeft)
        _ = library.metadata.upsert(
            bookID: book.id, author: "山田太郎", title: "第 1 巻", series: "", seriesIndex: "")

        LibraryDataPruner.pruneIfNeeded(modelContext: library.context, maxTrackedBooks: 3, excludedBookIDs: [])

        #expect(!bookIDs(library).contains(book.id))
        #expect(library.bookmarkRows(forBookID: book.id).count == 1)
        #expect(library.pageStates(forBookID: book.id) == [pageKey: .spreadLeft])
        #expect(library.metadata.metadata(forBookID: book.id)?.title == "第 1 巻")
    }
}

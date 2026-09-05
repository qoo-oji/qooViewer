import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// 「本ごとの保存データを削除」ウインドウ(ViewModels/LibraryCleanupViewModel.swift)。
///
/// この画面は**6 つの保存先を横断する**唯一の場所で、集めるのも消すのも 6 つすべてが
/// 対象になっている必要がある(段階 4 で見つけた `deleteAllFavorites` の取りこぼしと
/// 同じ性質の経路)。
@MainActor
struct LibraryCleanupTests {
    /// この画面が必要とする保存先(SwiftData の 5 種 + アクセス権)を、テスト 1 つぶんの
    /// 入れ物の上に組む。
    private struct Environment {
        let library: InMemoryLibrary
        let suite: PreferencesSuite
        let folderAccess: FolderAccessStore
        let temporary: TemporaryDirectory

        init() throws {
            library = try InMemoryLibrary(label: "cleanup")
            suite = PreferencesSuite(label: "cleanup")
            folderAccess = FolderAccessStore(defaults: suite.defaults)
            temporary = try TemporaryDirectory("cleanup")
        }

        /// テストの最後に必ず呼ぶ(`InMemoryLibrary.close()` のコメント参照)。
        func close() {
            library.close()
        }

        func makeViewModel() -> LibraryCleanupViewModel {
            LibraryCleanupViewModel(
                favoritesStore: library.favorites, bookmarkStore: library.bookmarks,
                layoutStore: library.layouts, metadataStore: library.metadata,
                folderAccess: folderAccess, modelContext: library.context
            )
        }

        /// この画面から見えるぶんだけの本。
        ///
        /// **実体(空のファイル)も作る** ―― お気に入りの登録はセキュリティスコープ付きの
        /// ブックマークを作れないと失敗するため(`FavoritesStore.makeBookmarkData`)。
        func book(_ name: String) throws -> MangaBook {
            let url = temporary.file(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url)
            }
            return MangaBook(
                id: url.path, title: name, sourceURL: url,
                pages: SamplePages.pages(["p1", "p2"]), pageOrderSource: .fileName
            )
        }

        /// 上の本の `bookID`(= 実体のパス)。
        func id(_ name: String) -> String { temporary.file(name).path }
    }

    @Test("一覧は6つの保存先すべてから本を集める(どれか1つでもあれば行になる)")
    func rowsAreCollectedFromEveryStore() throws {
        let env = try Environment()
        defer { env.close() }

        _ = env.library.favorites.addFavorite(book: try env.book("favorite"), to: nil)
        env.library.bookmarks.addBookmark(bookID: env.id("bookmarked"), pageIndex: 0, name: "b")
        env.library.layouts.setPageLayoutState(
            for: try env.book("layout"), pageKey: "p1", state: .single
        )
        env.library.layouts.setCoverPageKey(
            for: try env.book("cover"), pageKey: "p2", displayName: "p2"
        )
        env.library.metadata.upsert(
            bookID: env.id("metadata"), author: "a", title: "t", series: "", seriesIndex: ""
        )
        env.library.context.insert(BookReadingState(bookID: env.id("reading")))
        try env.library.context.save()

        let viewModel = env.makeViewModel()
        #expect(
            Set(viewModel.rows.map(\.bookID)) == Set(
                ["favorite", "bookmarked", "layout", "cover", "metadata", "reading"].map(env.id)
            )
        )
        #expect(viewModel.totalRowCount == 6)
        // 行は「何を持っているか」も示す(削除前の確認ダイアログの材料)。
        let layoutRow = viewModel.rows.first { $0.bookID == env.id("layout") }
        #expect(layoutRow?.hasLayout == true)
        #expect(layoutRow?.hasMetadata == false)
        #expect(viewModel.rows.first { $0.bookID == env.id("bookmarked") }?.bookmarkCount == 1)
        #expect(viewModel.rows.first { $0.bookID == env.id("favorite") }?.favoriteCount == 1)
    }

    @Test("削除は、その本のデータを6つの保存先すべてから消す")
    func deletingRemovesTheBookFromEveryStore() throws {
        let env = try Environment()
        defer { env.close() }
        let book = try env.book("everything")
        let bookID = book.id

        _ = env.library.favorites.addFavorite(book: book, to: nil)
        env.library.bookmarks.addBookmark(bookID: bookID, pageIndex: 0, name: "b")
        env.library.layouts.setPageLayoutState(for: book, pageKey: "p1", state: .single)
        env.library.layouts.setCoverPageKey(for: book, pageKey: "p2", displayName: "p2")
        env.library.metadata.upsert(
            bookID: bookID, author: "a", title: "t", series: "", seriesIndex: ""
        )
        env.library.context.insert(BookReadingState(bookID: bookID))
        try env.library.context.save()

        let viewModel = env.makeViewModel()
        #expect(viewModel.rows.count == 1)

        viewModel.deleteAllData(forBookIDs: [bookID])

        #expect(viewModel.rows.isEmpty)
        #expect(env.library.favorites.favoriteCount(forBookID: bookID) == 0)
        #expect(env.library.bookmarks.bookmarks(forBookID: bookID).isEmpty)
        #expect(env.library.layouts.bookLayoutSettings(forBookID: bookID) == nil)
        #expect(env.library.layouts.pageOverrides(forBookID: bookID).isEmpty)
        #expect(env.library.layouts.coverOverrideBookIDs().contains(bookID) == false)
        #expect(env.library.metadata.isRegistered(bookID: bookID) == false)
        // 読書履歴まで消すのは、残すとこの画面にもメタデータ編集にも行が出続けるため。
        let states = (try? env.library.context.fetch(FetchDescriptor<BookReadingState>())) ?? []
        #expect(states.contains { $0.bookID == bookID } == false)
    }

    @Test("他の本のデータは巻き込まない")
    func deletingOneBookLeavesTheOthersAlone() throws {
        let env = try Environment()
        defer { env.close() }
        env.library.bookmarks.addBookmark(bookID: env.id("a"), pageIndex: 0, name: "a")
        env.library.bookmarks.addBookmark(bookID: env.id("b"), pageIndex: 0, name: "b")

        let viewModel = env.makeViewModel()
        viewModel.deleteAllData(forBookIDs: [env.id("a")])

        #expect(viewModel.rows.map(\.bookID) == [env.id("b")])
        #expect(env.library.bookmarks.bookmarks(forBookID: env.id("b")).count == 1)
    }

    @Test("絞り込みを変えても選択は残る(積み上げて一括で消せる)")
    func theSelectionSurvivesFiltering() throws {
        let env = try Environment()
        defer { env.close() }
        for name in ["alpha", "beta", "gamma"] {
            env.library.bookmarks.addBookmark(bookID: env.id(name), pageIndex: 0, name: name)
        }
        let viewModel = env.makeViewModel()

        viewModel.searchText = "alpha"
        #expect(viewModel.rows.map(\.bookID) == [env.id("alpha")])
        viewModel.setAllShownRowsSelected(true)

        viewModel.searchText = "beta"
        // 一覧に出ていない本の選択は保持する(選択は一覧の見え方ではなくユーザーの意思)。
        #expect(viewModel.selectedBookIDs == [env.id("alpha")])
        viewModel.setAllShownRowsSelected(true)
        #expect(viewModel.selectedBookIDs == [env.id("alpha"), env.id("beta")])

        // 「表示中をすべて選択解除」も、表示されていない行には触れない。
        viewModel.setAllShownRowsSelected(false)
        #expect(viewModel.selectedBookIDs == [env.id("alpha")])

        viewModel.searchText = ""
        #expect(viewModel.rows.count == 3)
        #expect(viewModel.isEveryShownRowSelected == false)
    }

    @Test("保存データが無くなった本は、選択からも自動的に外れる")
    func theSelectionDropsBooksThatNoLongerHaveData() throws {
        let env = try Environment()
        defer { env.close() }
        env.library.bookmarks.addBookmark(bookID: env.id("a"), pageIndex: 0, name: "a")
        env.library.bookmarks.addBookmark(bookID: env.id("b"), pageIndex: 0, name: "b")
        let viewModel = env.makeViewModel()
        viewModel.setAllShownRowsSelected(true)
        #expect(viewModel.selectedBookIDs.count == 2)

        viewModel.deleteAllData(forBookIDs: [env.id("a")])

        // 一覧のどこにも出ていない本が削除対象に数えられ続けないように。
        #expect(viewModel.selectedBookIDs == [env.id("b")])
    }
}

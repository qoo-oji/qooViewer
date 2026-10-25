import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// 「本ごとの保存データを削除」ウインドウ(ViewModels/LibraryCleanupViewModel.swift)。
///
/// この画面は**5 つの保存先を横断する**唯一の場所で、集めるのも消すのも 5 つすべてが
/// 対象になっている必要がある(段階 4 で見つけた、当時のお気に入りの一括削除の取りこぼしと
/// 同じ性質の経路。お気に入りは 2026-10-24 に機能ごと削除した)。
@MainActor
struct LibraryCleanupTests {
    /// この画面が必要とする保存先(SwiftData の 4 種 + アクセス権)を、テスト 1 つぶんの
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
                collectionStore: library.collections,
                bookmarkStore: library.bookmarks, layoutStore: library.layouts,
                metadataStore: library.metadata, folderAccess: folderAccess,
                modelContext: library.context
            )
        }

        /// この画面から見えるぶんだけの本。
        ///
        /// **実体(空のファイル)も作る** ―― コレクションへの登録はセキュリティスコープ付きの
        /// ブックマークを作れないと失敗するため(`CollectionStore.makePendingItem`)。
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

        /// この本をコレクションへ1冊入れる(既定のライブラリの中に作る)。
        func addToCollection(named name: String) throws {
            _ = try book(name)
            let target = try #require(library.collections.libraries.first)
            let pending = try #require(
                CollectionStore.makePendingItem(for: temporary.file(name))
            )
            _ = library.collections.createCollection(
                name: "Collection \(name)", in: target, items: [pending]
            )
        }
    }

    @Test("一覧は5つの保存先すべてから本を集める(どれか1つでもあれば行になる)")
    func rowsAreCollectedFromEveryStore() throws {
        let env = try Environment()
        defer { env.close() }

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
        try env.addToCollection(named: "collected")
        env.library.context.insert(BookReadingState(bookID: env.id("reading")))
        try env.library.context.save()

        let viewModel = env.makeViewModel()
        #expect(
            Set(viewModel.rows.map(\.bookID)) == Set(
                ["bookmarked", "layout", "cover", "metadata", "collected", "reading"]
                    .map(env.id)
            )
        )
        #expect(viewModel.totalRowCount == 6)
        // 行は「何を持っているか」も示す(削除前の確認ダイアログの材料)。
        let layoutRow = viewModel.rows.first { $0.bookID == env.id("layout") }
        #expect(layoutRow?.hasLayout == true)
        #expect(layoutRow?.hasMetadata == false)
        #expect(viewModel.rows.first { $0.bookID == env.id("bookmarked") }?.bookmarkCount == 1)
        #expect(viewModel.rows.first { $0.bookID == env.id("collected") }?.collectionCount == 1)
    }

    @Test("削除は、その本のデータを5つの保存先すべてから消す")
    func deletingRemovesTheBookFromEveryStore() throws {
        let env = try Environment()
        defer { env.close() }
        let book = try env.book("everything")
        let bookID = book.id

        try env.addToCollection(named: "everything")
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
        #expect(env.library.collections.membershipCount(forBookID: bookID) == 0)
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

    // MARK: - 開き直し(2026-10-04 の監査 TW-7)

    /// 実在の判定が出そろうまで待つ(判定はメインアクターの外で走る)。
    private func waitForExistence(
        of bookID: String, in viewModel: LibraryCleanupViewModel, toBe expected: LibraryCleanupViewModel.FileExistence
    ) async -> Bool {
        await eventuallyHere {
            guard !viewModel.isCheckingExistence, let row = viewModel.rows.first(where: { $0.bookID == bookID }) else {
                return false
            }
            return row.existence == expected
        }
    }

    @Test("閉じて開き直すと、一覧も実在の判定も作り直す(見つからなかった本が戻っていれば「ある」になる)")
    func reopeningRebuildsTheListAndTheExistenceVerdicts() async throws {
        let env = try Environment()
        defer { env.close() }
        // 「見つかりません」と言えるのは許可済みのフォルダの中だけ(外では「不明」)。
        #expect(env.folderAccess.add(url: env.temporary.url))
        let bookID = env.id("away.cbz")
        env.library.bookmarks.addBookmark(bookID: bookID, pageIndex: 0, name: "b")
        let viewModel = env.makeViewModel()
        #expect(await waitForExistence(of: bookID, in: viewModel, toBe: .missing))
        viewModel.filter = .missingOnly
        viewModel.setAllShownRowsSelected(true)

        // 閉じている間に本が戻り、別の本に保存データができた。
        viewModel.setPresented(false)
        try Data().write(to: env.temporary.file("away.cbz"))
        env.library.bookmarks.addBookmark(bookID: env.id("later.cbz"), pageIndex: 0, name: "c")
        // 閉じたら選択と絞り込みは捨てる(次に開いたときの「削除」に見えないチェックが紛れ込まない)。
        #expect(viewModel.selectedBookIDs.isEmpty)
        #expect(viewModel.filter == .all)

        viewModel.setPresented(true)
        #expect(viewModel.rows.map(\.bookID).sorted() == [bookID, env.id("later.cbz")].sorted())
        // 以前は前回の「見つかりません」のまま、「見つからないファイルだけ」の一括削除で実在する本を消させた。
        #expect(await waitForExistence(of: bookID, in: viewModel, toBe: .exists))
        #expect(viewModel.missingCount == 1)
    }
}

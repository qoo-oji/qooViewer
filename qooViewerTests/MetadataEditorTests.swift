import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import qooViewer

/// 「メタデータの編集」ウインドウのロジック(ViewModels/MetadataEditorViewModel.swift)。
///
/// 一覧の母体は「このアプリが何らかの形で知っている本」= 5 つの保存先の bookID の和集合なので、
/// **どれか 1 つを数え忘れると、その本だけ一覧から消える**。ファイル名からの推測は
/// メインアクターの外で走るため、待ち合わせは `isPreparingDrafts` が下りるのを見る
/// (時間で待たないこと)。
///
/// **`defer { viewModel.releaseResources() }` を必ず書くこと。** この ViewModel は 3 つの
/// 変更通知を購読しており、`deinit` を待っていると、並行して走る他のテストが投げた通知で
/// 目を覚まし、既に捨てられている `ModelContainer` へフェッチしに行って**テストホストごと
/// 落ちる**(2026-09-06 にクラッシュレポートで確認。`InMemoryLibrary.close()` と同じ話)。
@MainActor
struct MetadataEditorTests {
    private func makeViewModel(_ library: InMemoryLibrary) -> MetadataEditorViewModel {
        MetadataEditorViewModel(
            metadataStore: library.metadata, formatStore: library.metadataFormats,
            bookmarkStore: library.bookmarks, layoutStore: library.layouts,
            favoritesStore: library.favorites, collectionStore: library.collections,
            modelContext: library.context
        )
    }

    /// ファイル名からの推測(`Task.detached`)が終わるまで待つ。
    private func settle(_ viewModel: MetadataEditorViewModel) async {
        for _ in 0..<500 {
            if !viewModel.isPreparingDrafts { return }
            await Task.yield()
        }
        Issue.record("推測が終わらない")
    }

    private func addReadingState(_ library: InMemoryLibrary, bookID: String) {
        library.context.insert(BookReadingState(bookID: bookID))
        try? library.context.save()
    }

    // MARK: - 推測に使う名前

    @Test("本として開ける拡張子だけを落とす",
          arguments: [("/books/作品名 第1巻.cbz", "作品名 第1巻"), ("/books/作品名.zip", "作品名"),
                      ("/books/作品名.rar", "作品名"), ("/books/作品名.7z", "作品名"),
                      ("/books/作品名.pdf", "作品名"), ("/books/作品名.epub", "作品名")])
    func aBookExtensionIsStripped(bookID: String, expected: String) {
        #expect(MetadataEditorViewModel.baseName(forBookID: bookID) == expected)
    }

    @Test("フォルダ名の中のドットは拡張子ではない(「作品名 vol.3」が「作品名 vol」にならない)")
    func aDotInAFolderNameIsNotAnExtension() {
        // 単純な deletingPathExtension だと巻数が落ちる ―― 推測が壊れる形。
        #expect(MetadataEditorViewModel.baseName(forBookID: "/books/作品名 vol.3") == "作品名 vol.3")
        #expect(MetadataEditorViewModel.baseName(forBookID: "/books/v1.5") == "v1.5")
        // 本として開けない拡張子もそのまま残す。
        #expect(MetadataEditorViewModel.baseName(forBookID: "/books/作品名.txt") == "作品名.txt")
    }

    // MARK: - 一覧の母体

    @Test("5 つの保存先すべてから本を集める(1 つでも欠けるとその本が一覧から消える)")
    func everyKindOfSavedDataContributesARow() async throws {
        let library = try InMemoryLibrary(label: "metadata-sources")
        defer { library.close() }
        let temporary = try TemporaryDirectory("metadata-sources")

        // 1. 読書履歴
        addReadingState(library, bookID: "/books/history.cbz")
        // 2. ブックマーク
        library.bookmarks.addBookmark(bookID: "/books/bookmarked.cbz", pageIndex: 0, name: "しおり")
        // 3. レイアウト設定
        let layoutDirectory = temporary.file("layout")
        try FixtureFolder.make(at: layoutDirectory, pages: [.init("001.jpg", number: 1)])
        let layoutBook = try await FixtureBook.load(layoutDirectory)
        library.layouts.setPageLayoutState(
            for: layoutBook, pageKey: try #require(layoutBook.pages.first?.sortKey), state: .single)
        // 4. お気に入り
        let favoriteDirectory = temporary.file("favorite")
        try FixtureFolder.make(at: favoriteDirectory, pages: [.init("001.jpg", number: 1)])
        let favoriteBook = try await FixtureBook.load(favoriteDirectory)
        library.favorites.forceAddFavorite(book: favoriteBook, to: nil)
        // 5. 登録済みメタデータ
        _ = library.metadata.upsert(
            bookID: "/books/registered.cbz", author: "著者", title: "題", series: "", seriesIndex: "")

        let viewModel = makeViewModel(library)
        defer { viewModel.releaseResources() }
        await settle(viewModel)

        let ids = Set(viewModel.rows.map(\.bookID))
        #expect(ids.contains("/books/history.cbz"))
        #expect(ids.contains("/books/bookmarked.cbz"))
        #expect(ids.contains(layoutBook.id))
        #expect(ids.contains(favoriteBook.id))
        #expect(ids.contains("/books/registered.cbz"))
        #expect(viewModel.totalRowCount == 5)
    }

    @Test("同じ本が複数の保存先にあっても行は 1 つ")
    func aBookKnownInSeveralWaysAppearsOnce() async throws {
        let library = try InMemoryLibrary(label: "metadata-dedupe")
        defer { library.close() }
        let bookID = "/books/same.cbz"
        addReadingState(library, bookID: bookID)
        library.bookmarks.addBookmark(bookID: bookID, pageIndex: 0, name: "しおり")
        _ = library.metadata.upsert(bookID: bookID, author: "著者", title: "題", series: "", seriesIndex: "")

        let viewModel = makeViewModel(library)
        defer { viewModel.releaseResources() }
        await settle(viewModel)
        #expect(viewModel.rows.map(\.bookID) == [bookID])
    }

    @Test("行はファイル名の自然順に並ぶ(2 が 10 より前)")
    func rowsAreSortedByFileNameNaturally() async throws {
        let library = try InMemoryLibrary(label: "metadata-sort")
        defer { library.close() }
        for name in ["book10.cbz", "book2.cbz", "book1.cbz"] {
            addReadingState(library, bookID: "/books/\(name)")
        }
        let viewModel = makeViewModel(library)
        defer { viewModel.releaseResources() }
        await settle(viewModel)
        #expect(viewModel.rows.map(\.fileName) == ["book1.cbz", "book2.cbz", "book10.cbz"])
    }

    @Test("行はファイル名と、推測に使う名前の両方を持つ")
    func eachRowCarriesBothNames() async throws {
        let library = try InMemoryLibrary(label: "metadata-names")
        defer { library.close() }
        addReadingState(library, bookID: "/books/作品名 第1巻.cbz")
        let viewModel = makeViewModel(library)
        defer { viewModel.releaseResources() }
        await settle(viewModel)

        let row = try #require(viewModel.rows.first)
        #expect(row.fileName == "作品名 第1巻.cbz")
        #expect(row.baseName == "作品名 第1巻")
    }

    // MARK: - 編集中の値

    @Test("登録済みの本は DB の値で、未登録の本はファイル名からの推測で埋まる")
    func draftsComeFromTheDatabaseOrTheFileName() async throws {
        let library = try InMemoryLibrary(label: "metadata-drafts")
        defer { library.close() }
        _ = library.metadata.upsert(
            bookID: "/books/registered.cbz", author: "登録した著者", title: "登録した題",
            series: "登録したシリーズ", seriesIndex: "3")
        addReadingState(library, bookID: "/books/[山田太郎] 冒険の書.cbz")

        let viewModel = makeViewModel(library)
        defer { viewModel.releaseResources() }
        await settle(viewModel)

        let registered = try #require(viewModel.drafts["/books/registered.cbz"])
        #expect(registered.author == "登録した著者")
        #expect(registered.title == "登録した題")
        #expect(registered.series == "登録したシリーズ")
        #expect(registered.seriesIndex == "3")

        // 推測の中身(既定ルール)は BookMetadataDeriverTests が固定している。ここで見るのは
        // 「未登録の行も空のままでは残らない」こと。
        let derived = try #require(viewModel.drafts["/books/[山田太郎] 冒険の書.cbz"])
        #expect(!derived.isEmpty)
    }

    @Test("登録すると DB へ入り、解除すると推測値へ戻る")
    func registeringAndUnregisteringRoundTrips() async throws {
        let library = try InMemoryLibrary(label: "metadata-register")
        defer { library.close() }
        let bookID = "/books/[山田太郎] 冒険の書.cbz"
        addReadingState(library, bookID: bookID)

        let viewModel = makeViewModel(library)
        defer { viewModel.releaseResources() }
        await settle(viewModel)
        #expect(!viewModel.isRegistered(bookID: bookID))

        viewModel.drafts[bookID] = .init()
        viewModel.drafts[bookID]?.author = "手で入れた著者"
        viewModel.drafts[bookID]?.title = "手で入れた題"
        viewModel.register(bookID: bookID)

        #expect(viewModel.isRegistered(bookID: bookID))
        #expect(library.metadata.metadata(forBookID: bookID)?.author == "手で入れた著者")
        #expect(viewModel.drafts[bookID]?.author == "手で入れた著者")

        viewModel.unregister(bookID: bookID)
        #expect(!viewModel.isRegistered(bookID: bookID))
        #expect(library.metadata.metadata(forBookID: bookID) == nil)
        // 表示は推測値へ戻る(手で入れた値が残り続けない)。
        #expect(viewModel.drafts[bookID]?.author != "手で入れた著者")
    }

    @Test("編集中の値は TextField 用の Binding から読み書きできる")
    func draftsAreReachableThroughBindings() async throws {
        let library = try InMemoryLibrary(label: "metadata-binding")
        defer { library.close() }
        let bookID = "/books/binding.cbz"
        addReadingState(library, bookID: bookID)
        let viewModel = makeViewModel(library)
        defer { viewModel.releaseResources() }
        await settle(viewModel)

        let binding = viewModel.binding(forBookID: bookID, keyPath: \.series)
        binding.wrappedValue = "新しいシリーズ"
        #expect(viewModel.drafts[bookID]?.series == "新しいシリーズ")
        #expect(binding.wrappedValue == "新しいシリーズ")
    }

    // MARK: - 絞り込み

    @Test("検索はファイル名・著者・タイトル・シリーズを対象に、大小文字を問わず部分一致")
    func searchMatchesFileNameAndTheEditedValues() async throws {
        let library = try InMemoryLibrary(label: "metadata-search")
        defer { library.close() }
        _ = library.metadata.upsert(
            bookID: "/books/aaa.cbz", author: "山田太郎", title: "冒険の書", series: "冒険シリーズ",
            seriesIndex: "1")
        _ = library.metadata.upsert(
            bookID: "/books/bbb.cbz", author: "鈴木花子", title: "日常の記録", series: "", seriesIndex: "")

        let viewModel = makeViewModel(library)
        defer { viewModel.releaseResources() }
        await settle(viewModel)
        #expect(viewModel.rows.count == 2)

        viewModel.searchText = "山田"
        #expect(viewModel.rows.map(\.bookID) == ["/books/aaa.cbz"])

        viewModel.searchText = "日常"
        #expect(viewModel.rows.map(\.bookID) == ["/books/bbb.cbz"])

        viewModel.searchText = "冒険シリーズ"
        #expect(viewModel.rows.map(\.bookID) == ["/books/aaa.cbz"])

        viewModel.searchText = "BBB"  // ファイル名は大小文字を問わない
        #expect(viewModel.rows.map(\.bookID) == ["/books/bbb.cbz"])

        viewModel.searchText = "   "  // 空白だけなら絞り込まない
        #expect(viewModel.rows.count == 2)
    }

    @Test("絞り込んでも全件数は変わらない(「N 件中 M 件」の N)")
    func theTotalCountIgnoresTheSearch() async throws {
        let library = try InMemoryLibrary(label: "metadata-total")
        defer { library.close() }
        for name in ["aaa.cbz", "bbb.cbz", "ccc.cbz"] {
            addReadingState(library, bookID: "/books/\(name)")
        }
        let viewModel = makeViewModel(library)
        defer { viewModel.releaseResources() }
        await settle(viewModel)

        viewModel.searchText = "aaa"
        #expect(viewModel.rows.count == 1)
        #expect(viewModel.totalRowCount == 3)
    }

    // MARK: - 読み直し

    @Test("読み直しても入力途中の値は消えない(開いたまま別の本を開いても入力が飛ばない)")
    func reloadingKeepsTheInProgressEdits() async throws {
        let library = try InMemoryLibrary(label: "metadata-reload")
        defer { library.close() }
        let bookID = "/books/editing.cbz"
        addReadingState(library, bookID: bookID)
        let viewModel = makeViewModel(library)
        defer { viewModel.releaseResources() }
        await settle(viewModel)

        viewModel.drafts[bookID]?.title = "入力途中"
        addReadingState(library, bookID: "/books/newly-opened.cbz")
        viewModel.reload()
        await settle(viewModel)

        #expect(viewModel.drafts[bookID]?.title == "入力途中")
        #expect(viewModel.rows.count == 2)
    }

    @Test("一覧から消えた本の編集中の値は捨てる")
    func draftsForVanishedBooksAreDropped() async throws {
        let library = try InMemoryLibrary(label: "metadata-vanish")
        defer { library.close() }
        let bookID = "/books/vanishing.cbz"
        addReadingState(library, bookID: bookID)
        let viewModel = makeViewModel(library)
        defer { viewModel.releaseResources() }
        await settle(viewModel)
        #expect(viewModel.drafts[bookID] != nil)

        let states = (try? library.context.fetch(FetchDescriptor<BookReadingState>())) ?? []
        for state in states { library.context.delete(state) }
        try? library.context.save()

        viewModel.reload()
        await settle(viewModel)
        #expect(viewModel.drafts[bookID] == nil)
        #expect(viewModel.rows.isEmpty)
    }
}

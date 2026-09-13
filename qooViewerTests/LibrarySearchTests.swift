import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// ウェルカム画面の検索・並び順「作成日」「変更日」・グリッドの列の割り付け(改善要望6、2026-09-13)。
///
/// 押さえるのは、間違えると**探している本が出てこない**か、**見えていないものに手が出る**もの:
/// - 照合の規則(大文字小文字・全角半角・Unicodeの正規化を畳む。濁点は畳まない)
/// - コレクションは「名前」か「中の本」のどちらかで一致する
/// - 検索を捨てる契機(ライブラリの切り替え・一致する本の無い棚を開いたとき)と、残す契機(戻る)
/// - 検索が変わったら選択を捨てる(ゴミ箱が見えていないものを消さない)
@MainActor
struct LibrarySearchTests {
    private func makeBookFolder(_ temporary: TemporaryDirectory, named name: String) throws -> URL {
        let directory = temporary.file(name)
        try FixtureFolder.make(at: directory, pages: [.init("001.jpg", number: 1)])
        return directory
    }

    private func pendingItems(_ urls: [URL]) -> [CollectionStore.PendingItem] {
        urls.compactMap { CollectionStore.makePendingItem(for: $0) }
    }

    // MARK: - 照合の規則

    @Test("空欄・空白だけの検索は、絞り込まない(nil)")
    func blankQueriesDoNotFilter() {
        #expect(LibrarySearchQuery("") == nil)
        #expect(LibrarySearchQuery("   ") == nil)
        #expect(LibrarySearchQuery("\u{3000}") == nil)
    }

    @Test("大文字小文字・全角半角・Unicodeの正規化を畳み、空白区切りの語はすべて含むものが一致する")
    func queriesFoldCaseWidthAndNormalization() throws {
        let haystack = LibrarySearchQuery.normalized("ﾊﾟﾝ屋の ABC 第1巻")
        #expect(try #require(LibrarySearchQuery("パン")).matches(normalized: haystack))
        #expect(try #require(LibrarySearchQuery("ａｂｃ")).matches(normalized: haystack))
        // 全角の空白で区切っても、順番を入れ替えても一致する(AND)。
        #expect(try #require(LibrarySearchQuery("第1巻\u{3000}abc")).matches(normalized: haystack))
        #expect(try #require(LibrarySearchQuery("abc 第2巻")).matches(normalized: haystack) == false)
        // APFSから返るNFD(「ハ」+結合半濁点)の名前も、打ち込んだNFCで一致する。
        let decomposed = LibrarySearchQuery.normalized("パン".decomposedStringWithCanonicalMapping)
        #expect(try #require(LibrarySearchQuery("パン")).matches(normalized: decomposed))
    }

    @Test("濁点は畳まない(「が」で「か」に一致しない)")
    func voicedSoundMarksAreDistinct() throws {
        #expect(try #require(LibrarySearchQuery("か")).matches(normalized: LibrarySearchQuery.normalized("が")) == false)
    }

    // MARK: - 絞り込み

    @Test("コレクションは名前か中の本(ファイル名・メタデータ)で一致し、本は本自身で一致する")
    func collectionsMatchByNameOrByTheirBooks() throws {
        let library = try InMemoryLibrary(label: "search-filter")
        defer { library.close() }
        let temporary = try TemporaryDirectory("search-filter")
        let shelf = try #require(library.collections.libraries.first)
        let alpha = try makeBookFolder(temporary, named: "alpha-book")
        let beta = try makeBookFolder(temporary, named: "beta-book")
        let comics = try #require(library.collections.createCollection(
            name: "Comics", in: shelf, items: pendingItems([alpha])
        ))
        let novels = try #require(library.collections.createCollection(
            name: "Novels", in: shelf, items: pendingItems([beta])
        ))
        library.metadata.upsert(
            bookID: beta.path, author: "Yamada", title: "Sky", series: "", seriesIndex: ""
        )
        let names = { (text: String) in
            library.collections.collections(in: shelf, sort: .nameAscending, matching: LibrarySearchQuery(text))
                .map(\.name)
        }

        #expect(names("") == ["Comics", "Novels"])
        #expect(names("comics") == ["Comics"])       // コレクションの名前
        #expect(names("ALPHA") == ["Comics"])        // 中の本のファイル名
        #expect(names("yamada") == ["Novels"])       // 中の本のメタデータ(作者)
        #expect(names("sky beta") == ["Novels"])     // メタデータとファイル名の両方(AND)
        #expect(names("nothing").isEmpty)

        let query = try #require(LibrarySearchQuery("yamada"))
        #expect(library.collections.items(in: novels, sort: .nameAscending, matching: query).count == 1)
        #expect(library.collections.items(in: comics, sort: .nameAscending, matching: query).isEmpty)
        #expect(library.collections.containsItem(in: novels, matching: query))
        #expect(!library.collections.containsItem(in: comics, matching: query))
    }

    @Test("メタデータを登録し直すと、その場で検索結果が変わる(照合の文字列を覚えたままにしない)")
    func searchFollowsMetadataChanges() throws {
        let library = try InMemoryLibrary(label: "search-metadata")
        defer { library.close() }
        let temporary = try TemporaryDirectory("search-metadata")
        let shelf = try #require(library.collections.libraries.first)
        let book = try makeBookFolder(temporary, named: "book")
        let collection = try #require(library.collections.createCollection(
            name: "Shelf", in: shelf, items: pendingItems([book])
        ))
        let query = try #require(LibrarySearchQuery("moon"))
        #expect(!library.collections.containsItem(in: collection, matching: query))

        library.metadata.upsert(bookID: book.path, author: "", title: "Moon", series: "", seriesIndex: "")
        #expect(library.collections.containsItem(in: collection, matching: query))
    }

    // MARK: - 検索を捨てる/残す

    @Test("ライブラリを切り替えると検索は消え、コレクションから戻っても検索は残る")
    func searchClearsOnLibrarySwitchButSurvivesGoingBack() {
        let suite = PreferencesSuite(label: "search-state")
        defer { withExtendedLifetime(suite) {} }
        let state = WelcomeLibraryState(defaults: suite.defaults)
        state.selectedLibraryID = UUID()

        state.searchText = "moon"
        state.openCollection(UUID(), keepingSearch: true)
        #expect(state.searchText == "moon")
        state.openedCollectionID = nil
        #expect(state.searchText == "moon")

        state.selectedLibraryID = UUID()
        #expect(state.searchText.isEmpty)
    }

    @Test("一致する本の無い棚を開くと検索は消える")
    func openingACollectionWithoutMatchingBooksClearsTheSearch() {
        let suite = PreferencesSuite(label: "search-open")
        defer { withExtendedLifetime(suite) {} }
        let state = WelcomeLibraryState(defaults: suite.defaults)
        state.searchText = "comics"
        state.openCollection(UUID(), keepingSearch: false)
        #expect(state.searchText.isEmpty)
    }

    @Test("検索が変わると選択は捨てる(絞り込みで見えなくなったものをゴミ箱が消さない)")
    func changingTheSearchClearsTheSelection() {
        let suite = PreferencesSuite(label: "search-selection")
        defer { withExtendedLifetime(suite) {} }
        let state = WelcomeLibraryState(defaults: suite.defaults)
        state.isEditing = true
        state.toggleCollectionSelection(UUID())
        state.searchText = "a"
        #expect(state.selectedCollectionIDs.isEmpty)
        // 同じ文字列の代入では捨てない。
        state.toggleCollectionSelection(UUID())
        state.searchText = "a"
        #expect(state.selectedCollectionIDs.count == 1)
    }

    // MARK: - 並び順「作成日」「変更日」

    @Test("作成日・変更日で並び、日付の分からない本は向きに関わらず末尾に来る")
    func sortingByFileDates() throws {
        let library = try InMemoryLibrary(label: "search-dates")
        defer { library.close() }
        let temporary = try TemporaryDirectory("search-dates")
        let shelf = try #require(library.collections.libraries.first)
        let old = try makeBookFolder(temporary, named: "a-old")
        let new = try makeBookFolder(temporary, named: "b-new")
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 作成日は old が古く、変更日は逆に old が新しい。
        try FileManager.default.setAttributes(
            [.creationDate: base, .modificationDate: base.addingTimeInterval(500)], ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.creationDate: base.addingTimeInterval(100), .modificationDate: base.addingTimeInterval(200)],
            ofItemAtPath: new.path
        )
        var pending = pendingItems([old, new])
        // 日付の読めなかった本(実体が見つからない等)。
        let unknown = try makeBookFolder(temporary, named: "c-unknown")
        var unknownPending = try #require(CollectionStore.makePendingItem(for: unknown))
        unknownPending.fileDates = nil
        pending.append(unknownPending)
        let collection = try #require(library.collections.createCollection(
            name: "Shelf", in: shelf, items: pending
        ))
        let titles = { (sort: FavoritesSortOption) in
            library.collections.items(in: collection, sort: sort).map(\.title)
        }

        #expect(titles(.dateCreatedAscending) == ["a-old", "b-new", "c-unknown"])
        #expect(titles(.dateCreatedDescending) == ["b-new", "a-old", "c-unknown"])
        #expect(titles(.dateModifiedAscending) == ["b-new", "a-old", "c-unknown"])
        #expect(titles(.dateModifiedDescending) == ["a-old", "b-new", "c-unknown"])
        // コレクションそのものには日付が無いので、名前として並ぶ。
        #expect(library.collections.collections(in: shelf, sort: .dateCreatedDescending).map(\.name) == ["Shelf"])
    }

    @Test("基準と向きの分解・組み立ては、作成日・変更日でも往復する")
    func sortOptionRoundTripsForFileDates() {
        for option in [FavoritesSortOption.dateCreatedAscending, .dateCreatedDescending,
                       .dateModifiedAscending, .dateModifiedDescending] {
            #expect(FavoritesSortOption(field: option.field, ascending: option.isAscending) == option)
        }
        // タイトルを持たないものの並べ替えメニューには出さない。
        #expect(!FavoritesSortOption.Field.withoutTitle.contains(.dateCreated))
        #expect(!FavoritesSortOption.Field.withoutTitle.contains(.dateModified))
    }

    // MARK: - 列の割り付け

    @Test("列はスライダーの値ちょうどの幅で、入るだけ並ぶ(余りは列の外)")
    func gridColumnsUseTheExactItemWidth() {
        // 使える幅 = 1000 - 余白24×2 = 952。(952 + 24) / (180 + 24) = 4.78 → 4列。
        let columns = WelcomeGridColumns(
            availableWidth: 1000, itemWidth: 180, spacing: 24, padding: 24, scrollerWidth: 0
        )
        #expect(columns.count == 4)
        #expect(columns.itemWidth == 180)
        #expect(abs(columns.contentWidth - CGFloat(180 * 4 + 24 * 3)) < 0.001)
        // 大きさを少し変えると、列数が変わらなくても幅がそのまま変わる(無段階)。
        let wider = WelcomeGridColumns(
            availableWidth: 1000, itemWidth: 190, spacing: 24, padding: 24, scrollerWidth: 0
        )
        #expect(wider.count == 4)
        #expect(wider.contentWidth > columns.contentWidth)
        // 常に表示するスクロールバーのぶんは使える幅から引く。
        // 845 - 48 = 797 → (797 + 24) / 204 = 4.02 で4列、15を引くと 3.95 で3列。
        #expect(WelcomeGridColumns(
            availableWidth: 845, itemWidth: 180, spacing: 24, padding: 24, scrollerWidth: 0
        ).count == 4)
        #expect(WelcomeGridColumns(
            availableWidth: 845, itemWidth: 180, spacing: 24, padding: 24, scrollerWidth: 15
        ).count == 3)
        // どれだけ狭くても1列は並ぶ。
        #expect(WelcomeGridColumns(availableWidth: 10, itemWidth: 300, spacing: 24, padding: 24).count == 1)
    }
}

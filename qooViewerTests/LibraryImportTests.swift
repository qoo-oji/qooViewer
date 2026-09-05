import Foundation
import Testing

@testable import qooViewer

/// 保存データの取り込み(`LibraryImportExportService.apply`)を、**メモリ内の SwiftData** の上で通す。
///
/// ファイル形式そのもの(往復・版 2)は `LibraryJSONSchemaTests` が見ている。こちらが見るのは
/// **JSON を実際のライブラリへ流し込んだ結果** ―― 方針(overwrite / merge / ignore)ごとの
/// 増減、ブックマークの鍵 → 番号の変換、そして「同じ JSON にレイアウトとブックマークの両方が
/// 入っているとき、どちらを先に取り込むか」。最後のものは利用者報告のあった不具合で、
/// 順序が逆に戻ると**保存済みのブックマークが別のページを指す**(`apply` のコメント参照)。
///
/// ライブラリは `InMemoryLibrary`(テストが自前で作るコンテナ)。本は `ExportSource` で
/// 作業フォルダの中に作る ―― 取り込みは本を実際に読み直す(鍵 → 番号の変換に実効ページ順が
/// 要る)ので、実在するファイルが必要になる。
///
/// ページ名は `001.png` … の連番だけを使う。この経路の `EffectivePageOrder` は
/// 「並び順を Finder に揃える」設定(`UserDefaults`)を読むが、連番の名前なら
/// どちらの比較でも同じ並びになるため、走らせる人の設定に結果が左右されない。
@MainActor
struct LibraryImportTests {

    // MARK: - 素材

    /// この JSON 1 冊分のブックマーク。
    private func bookmarkEntry(
        _ source: ExportSource, _ pages: [(page: String, name: String)]
    ) -> ExportedBookmarkEntry {
        ExportedBookmarkEntry(
            bookID: source.book.id,
            bookmarks: pages.map { ExportedBookmark(page: $0.page, name: $0.name) }
        )
    }

    private func layoutEntry(
        _ source: ExportSource,
        readingDirection: String? = nil,
        forcedDisplayMode: String? = nil,
        pageOrder: [String]? = nil,
        pages: [String: PageLayoutState] = [:]
    ) -> ExportedBookLayoutEntry {
        ExportedBookLayoutEntry(
            bookID: source.book.id,
            layout: ExportedBookLayout(
                readingDirection: readingDirection,
                forcedDisplayMode: forcedDisplayMode,
                pageOrder: pageOrder,
                pages: pages.isEmpty ? nil : pages.mapValues { ExportedPageState(state: $0.rawValue) }
            )
        )
    }

    private func favoritesFile(_ source: ExportSource, title: String, folders: [String]) -> ExportedFavorites {
        // folders は ["作者A", "続き"] のような上から下への並び。最後の要素の中へ本を入れる。
        var exported: [ExportedFavoriteFolder] = []
        var parentID: String?
        for (index, name) in folders.enumerated() {
            let id = "f\(index)"
            exported.append(ExportedFavoriteFolder(id: id, name: name, parentId: parentID))
            parentID = id
        }
        return ExportedFavorites(
            folders: exported,
            books: [ExportedFavoriteBook(bookID: source.book.id, title: title, folderId: parentID)]
        )
    }

    // MARK: - お気に入り

    @Test("お気に入りはフォルダ階層ごと復元される")
    func favoritesKeepTheFolderTree() async throws {
        let source = try await ExportSource.zip(pages: 3, label: "import-fav")
        let library = try InMemoryLibrary()

        let summary = await library.apply(
            QooLibraryExportFile(favorites: favoritesFile(source, title: "本 A", folders: ["作者A", "続き"])),
            policies: .all(.merge)
        )

        #expect(summary.favoritesImportedFolders == 2)
        #expect(summary.favoritesImportedBooks == 1)
        #expect(library.favoriteBookPaths() == ["作者A/続き/本 A"])
        // 登録されるのは JSON の bookID ではなく、実際に解決できたファイルのパス。
        #expect(library.favorites.isFavorited(bookID: source.book.id))
    }

    @Test("同じファイルを 2 回 merge しても、フォルダも登録も増えない")
    func mergingTwiceDoesNotDuplicate() async throws {
        let source = try await ExportSource.zip(pages: 3, label: "import-fav-twice")
        let library = try InMemoryLibrary()
        let file = QooLibraryExportFile(favorites: favoritesFile(source, title: "本 A", folders: ["作者A"]))

        await library.apply(file, policies: .all(.merge))
        let second = await library.apply(file, policies: .all(.merge))

        // 2 回目は「同名フォルダを再利用し、登録済みの本は足さない」。
        #expect(second.favoritesImportedFolders == 0)
        #expect(second.favoritesImportedBooks == 0)
        #expect(library.favoriteBookPaths() == ["作者A/本 A"])
    }

    @Test("overwrite は既存のお気に入りを消してから入れ直す")
    func overwriteReplacesTheWholeTree() async throws {
        let source = try await ExportSource.zip(pages: 3, label: "import-fav-overwrite")
        let library = try InMemoryLibrary()

        await library.apply(
            QooLibraryExportFile(favorites: favoritesFile(source, title: "古い名前", folders: ["古いフォルダ"])),
            policies: .all(.merge)
        )
        await library.apply(
            QooLibraryExportFile(favorites: favoritesFile(source, title: "新しい名前", folders: ["新しいフォルダ"])),
            policies: LibraryImportExportService.ImportPolicies(favorites: .overwrite)
        )

        #expect(library.favoriteBookPaths() == ["新しいフォルダ/新しい名前"])
    }

    @Test("上書きは、フォルダに入っていないお気に入りも消す")
    func overwriteAlsoDeletesRootLevelFavorites() async throws {
        // 回帰テスト(2026-09-06): FavoriteBook の一括削除(delete(model:))は、folder への
        // mandatory な逆リレーションのせいで**全件ぶん失敗**していた。実際に消えていたのは
        // FavoriteFolder のカスケードぶん = フォルダの中の本だけで、ルート直下の登録が残り、
        // 「上書きで取り込んだのに古い登録が残る」状態になっていた
        // (FavoritesStore.deleteAllFavorites のコメント参照)。
        let source = try await ExportSource.zip(pages: 3, label: "import-fav-root")
        let library = try InMemoryLibrary()
        let folder = try #require(try? library.favorites.createFolder(name: "古いフォルダ", parent: nil).get())
        library.favorites.forceAddFavorite(book: source.book, to: folder)
        library.favorites.forceAddFavorite(book: source.book, to: nil)
        #expect(library.favorites.totalFavoritesCount() == 2)

        await library.apply(
            QooLibraryExportFile(favorites: favoritesFile(source, title: "新しい名前", folders: ["新しいフォルダ"])),
            policies: LibraryImportExportService.ImportPolicies(favorites: .overwrite)
        )

        #expect(library.favoriteBookPaths() == ["新しいフォルダ/新しい名前"])
        #expect(library.favorites.totalFavoritesCount() == 1)
        #expect(library.favorites.subfolders(of: nil).map(\.name) == ["新しいフォルダ"])
    }

    @Test("ファイルが見つからない本は、お気に入りに登録しない")
    func favoritesSkipMissingFiles() async throws {
        let library = try InMemoryLibrary()
        let missing = ExportedFavorites(
            folders: [],
            books: [ExportedFavoriteBook(bookID: "/nowhere/missing.cbz", title: "無い本", folderId: nil)]
        )

        let summary = await library.apply(
            QooLibraryExportFile(favorites: missing), policies: .all(.merge)
        )

        #expect(summary.favoritesImportedBooks == 0)
        #expect(library.favoriteBookPaths().isEmpty)
    }

    // MARK: - ブックマーク

    @Test("ブックマークは鍵で書かれ、取り込み時に実効ページ順の番号へ変換される")
    func bookmarksConvertKeysToIndices() async throws {
        let source = try await ExportSource.zip(pages: 5, label: "import-bm")
        let library = try InMemoryLibrary()

        let summary = await library.apply(
            QooLibraryExportFile(
                bookmarks: [bookmarkEntry(source, [(source.key(2), "二枚目"), (source.key(5), "最後")])]
            ),
            policies: .all(.merge)
        )

        #expect(summary.bookmarksImportedBooks == 1)
        #expect(summary.bookmarksImportedEntries == 2)
        let rows = library.bookmarkRows(forBookID: source.book.id)
        #expect(rows.map(\.pageIndex) == [1, 4])
        // 番号だけの行にはしない ―― 鍵を持っていれば、あとで並びが変わっても追従できる。
        #expect(rows.map(\.pageKey) == [source.key(2), source.key(5)])
        #expect(rows.map(\.name) == ["二枚目", "最後"])
    }

    @Test("同じ JSON のレイアウトが先に効くので、除外があってもブックマークは同じページを指す")
    func layoutsAreImportedBeforeBookmarks() async throws {
        // 利用者報告の回帰テスト(apply のコメント参照)。3 ページ目を除外すると、
        // 4 枚目のページの番号は 3(0 始まり)へ繰り上がる。ブックマークを先に取り込むと
        // 除外前の並びで数えてしまい、番号 3 は 5 枚目を指してしまう。
        let source = try await ExportSource.zip(pages: 5, label: "import-order")
        let library = try InMemoryLibrary()

        await library.apply(
            QooLibraryExportFile(
                bookmarks: [bookmarkEntry(source, [(source.key(4), "四枚目")])],
                layouts: [layoutEntry(source, pages: [source.key(3): .excluded])]
            ),
            policies: .all(.merge)
        )

        let rows = library.bookmarkRows(forBookID: source.book.id)
        #expect(rows.map(\.pageIndex) == [2])
        #expect(rows.map(\.pageKey) == [source.key(4)])
    }

    @Test("並べ替えも同じ ―― 番号は取り込み後の並びで数える")
    func bookmarksFollowTheImportedPageOrder() async throws {
        let source = try await ExportSource.zip(pages: 4, label: "import-order-reverse")
        let library = try InMemoryLibrary()

        await library.apply(
            QooLibraryExportFile(
                bookmarks: [bookmarkEntry(source, [(source.key(1), "一枚目")])],
                layouts: [layoutEntry(source, pageOrder: source.pageKeys.reversed())]
            ),
            policies: .all(.merge)
        )

        // 逆順にしたので、1 枚目は最後(番号 3)。
        #expect(library.bookmarkRows(forBookID: source.book.id).map(\.pageIndex) == [3])
    }

    @Test("本の中に無い鍵のブックマークは落ちる(本ごと落ちはしない)")
    func unknownKeysAreDropped() async throws {
        let source = try await ExportSource.zip(pages: 3, label: "import-bm-unknown")
        let library = try InMemoryLibrary()

        let summary = await library.apply(
            QooLibraryExportFile(
                bookmarks: [bookmarkEntry(source, [("999.png", "無いページ"), (source.key(1), "一枚目")])]
            ),
            policies: .all(.merge)
        )

        #expect(summary.bookmarksImportedEntries == 1)
        #expect(library.bookmarkRows(forBookID: source.book.id).map(\.pageKey) == [source.key(1)])
    }

    @Test("ファイルが見つからない本のブックマークは飛ばし、残りは取り込む")
    func missingBooksAreReportedAndSkipped() async throws {
        let source = try await ExportSource.zip(pages: 3, label: "import-bm-missing")
        let library = try InMemoryLibrary()

        let summary = await library.apply(
            QooLibraryExportFile(
                bookmarks: [
                    ExportedBookmarkEntry(
                        bookID: "/nowhere/missing.cbz", bookmarks: [ExportedBookmark(page: "001.png", name: "x")]
                    ),
                    bookmarkEntry(source, [(source.key(1), "一枚目")])
                ]
            ),
            policies: .all(.merge)
        )

        #expect(summary.bookmarksSkippedBookIDs == ["/nowhere/missing.cbz"])
        #expect(summary.bookmarksImportedBooks == 1)
        #expect(library.bookmarkRows(forBookID: source.book.id).count == 1)
    }

    @Test("merge は同じページの既存ブックマークを残し、overwrite は入れ替える")
    func bookmarkPolicies() async throws {
        let source = try await ExportSource.zip(pages: 3, label: "import-bm-policy")
        let library = try InMemoryLibrary()
        library.bookmarks.addBookmark(
            bookID: source.book.id, pageIndex: 0, pageKey: source.key(1), name: "自分で付けた名前"
        )
        let file = QooLibraryExportFile(bookmarks: [bookmarkEntry(source, [(source.key(1), "JSON の名前")])])

        await library.apply(file, policies: .all(.merge))
        #expect(library.bookmarkRows(forBookID: source.book.id).map(\.name) == ["自分で付けた名前"])

        await library.apply(file, policies: LibraryImportExportService.ImportPolicies(bookmarks: .overwrite))
        #expect(library.bookmarkRows(forBookID: source.book.id).map(\.name) == ["JSON の名前"])
    }

    // MARK: - レイアウト設定

    @Test("レイアウトは読み方向・見開き・ページ順・ページ単位設定をまとめて取り込む")
    func layoutsImportEverything() async throws {
        let source = try await ExportSource.zip(pages: 4, label: "import-layout")
        let library = try InMemoryLibrary()

        let summary = await library.apply(
            QooLibraryExportFile(
                layouts: [layoutEntry(
                    source,
                    readingDirection: ReadingDirection.leftToRight.stableID,
                    forcedDisplayMode: DisplayMode.spread.stableID,
                    pageOrder: source.pageKeys.reversed(),
                    pages: [source.key(2): .excluded, source.key(3): .spreadLeft]
                )]
            ),
            policies: .all(.merge)
        )

        #expect(summary.layoutsImportedBooks == 1)
        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: source.book.id))
        #expect(settings.readingDirectionOverride == .leftToRight)
        #expect(settings.forcedDisplayMode == .spread)
        #expect(settings.pageOrderOverride == source.pageKeys.reversed())
        #expect(library.pageStates(forBookID: source.book.id) == [
            source.key(2): .excluded, source.key(3): .spreadLeft
        ])
    }

    @Test("merge は、本全体の設定が既にあるならその 3 つを丸ごと守る")
    func mergeKeepsExistingBookLevelSettings() async throws {
        let source = try await ExportSource.zip(pages: 3, label: "import-layout-merge")
        let library = try InMemoryLibrary()
        library.layouts.setReadingDirectionOverride(for: source.book, .rightToLeft)

        await library.apply(
            QooLibraryExportFile(
                layouts: [layoutEntry(
                    source,
                    readingDirection: ReadingDirection.leftToRight.stableID,
                    forcedDisplayMode: DisplayMode.spread.stableID,
                    pages: [source.key(1): .excluded]
                )]
            ),
            policies: .all(.merge)
        )

        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: source.book.id))
        // 本全体設定は 1 つの単位。読み方向が既にある以上、見開きだけ埋めることはしない。
        #expect(settings.readingDirectionOverride == .rightToLeft)
        #expect(settings.forcedDisplayMode == nil)
        // ページ単位設定は別勘定で、まだ無い鍵は入る。
        #expect(library.pageStates(forBookID: source.book.id) == [source.key(1): .excluded])
    }

    @Test("merge は既にあるページ単位設定を上書きしない")
    func mergeKeepsExistingPageStates() async throws {
        let source = try await ExportSource.zip(pages: 3, label: "import-layout-pages")
        let library = try InMemoryLibrary()
        library.layouts.setPageLayoutState(for: source.book, pageKey: source.key(1), state: .spreadRight)

        await library.apply(
            QooLibraryExportFile(
                layouts: [layoutEntry(source, pages: [source.key(1): .excluded, source.key(2): .excluded])]
            ),
            policies: .all(.merge)
        )

        #expect(library.pageStates(forBookID: source.book.id) == [
            source.key(1): .spreadRight, source.key(2): .excluded
        ])
    }

    @Test("overwrite はこの本のレイアウトを捨ててから入れ直す")
    func overwriteReplacesLayoutData() async throws {
        let source = try await ExportSource.zip(pages: 3, label: "import-layout-overwrite")
        let library = try InMemoryLibrary()
        library.layouts.setReadingDirectionOverride(for: source.book, .rightToLeft)
        library.layouts.setPageLayoutState(for: source.book, pageKey: source.key(1), state: .spreadRight)

        await library.apply(
            QooLibraryExportFile(
                layouts: [layoutEntry(
                    source, forcedDisplayMode: DisplayMode.single.stableID, pages: [source.key(2): .excluded]
                )]
            ),
            policies: LibraryImportExportService.ImportPolicies(layouts: .overwrite)
        )

        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: source.book.id))
        #expect(settings.readingDirectionOverride == nil)
        #expect(settings.forcedDisplayMode == .single)
        #expect(library.pageStates(forBookID: source.book.id) == [source.key(2): .excluded])
    }

    // MARK: - 書誌メタデータ

    @Test("メタデータは実ファイルが無くても取り込める")
    func metadataDoesNotNeedTheFile() async throws {
        let library = try InMemoryLibrary()
        let entry = ExportedBookMetadataEntry(
            bookID: "/nowhere/missing.cbz", author: "著者", title: "題名", series: "シリーズ", seriesIndex: "3"
        )

        let summary = await library.apply(
            QooLibraryExportFile(metadata: [entry]), policies: .all(.merge)
        )

        #expect(summary.metadataImportedBooks == 1)
        let stored = try #require(library.metadata.metadata(forBookID: "/nowhere/missing.cbz"))
        #expect(stored.author == "著者")
        #expect(stored.seriesIndex == "3")
    }

    @Test("メタデータの merge は既存の登録を触らず、overwrite は置き換える")
    func metadataPolicies() async throws {
        let library = try InMemoryLibrary()
        let bookID = "/nowhere/missing.cbz"
        let first = ExportedBookMetadataEntry(
            bookID: bookID, author: "最初の著者", title: "題名", series: "", seriesIndex: ""
        )
        let second = ExportedBookMetadataEntry(
            bookID: bookID, author: "あとの著者", title: "題名", series: "", seriesIndex: ""
        )
        await library.apply(QooLibraryExportFile(metadata: [first]), policies: .all(.merge))

        await library.apply(QooLibraryExportFile(metadata: [second]), policies: .all(.merge))
        #expect(library.metadata.metadata(forBookID: bookID)?.author == "最初の著者")

        await library.apply(
            QooLibraryExportFile(metadata: [second]),
            policies: LibraryImportExportService.ImportPolicies(metadata: .overwrite)
        )
        #expect(library.metadata.metadata(forBookID: bookID)?.author == "あとの著者")
    }

    @Test("フォーマット定義は丸ごと差し替え、巻数ルールは「巻数 → シリーズ名の分離」の順に並ぶ")
    func metadataFormatsAreReplacedInOrder() async throws {
        let library = try InMemoryLibrary()

        let summary = await library.apply(
            QooLibraryExportFile(
                metadataFormats: ExportedMetadataFormats(
                    filenameFormats: ["(著者) 題名"],
                    volumeNumberPatterns: ["第(\\d+)巻"],
                    seriesSeparatorPatterns: [" 上巻"],
                    exclusionPatterns: ["\\(同人\\)"]
                )
            ),
            policies: LibraryImportExportService.ImportPolicies(metadataFormats: .overwrite)
        )

        #expect(summary.didImportMetadataFormats)
        #expect(library.metadataFormats.filenameFormats.map(\.pattern) == ["(著者) 題名"])
        // 1 本の配列に、この並びで入る(照合の優先順位そのもの)。
        #expect(library.metadataFormats.volumeRules.map(\.pattern) == ["第(\\d+)巻", " 上巻"])
        #expect(library.metadataFormats.volumeRules.map(\.kind) == [.volumeNumber, .seriesSeparatorOnly])
        #expect(library.metadataFormats.exclusionRules.map(\.pattern) == ["\\(同人\\)"])
    }

    // MARK: - ignore

    @Test("ignore の指定があるカテゴリは、キーがあっても何も変えない")
    func ignoreChangesNothing() async throws {
        let source = try await ExportSource.zip(pages: 3, label: "import-ignore")
        let library = try InMemoryLibrary()

        let summary = await library.apply(
            QooLibraryExportFile(
                favorites: favoritesFile(source, title: "本 A", folders: ["作者A"]),
                bookmarks: [bookmarkEntry(source, [(source.key(1), "一枚目")])],
                layouts: [layoutEntry(source, readingDirection: ReadingDirection.leftToRight.stableID)],
                metadata: [ExportedBookMetadataEntry(
                    bookID: source.book.id, author: "著者", title: "題名", series: "", seriesIndex: ""
                )]
            ),
            policies: .all(.ignore)
        )

        #expect(summary.favoritesImportedBooks == 0)
        #expect(summary.bookmarksImportedEntries == 0)
        #expect(summary.layoutsImportedBooks == 0)
        #expect(summary.metadataImportedBooks == 0)
        #expect(library.favoriteBookPaths().isEmpty)
        #expect(library.bookmarkRows(forBookID: source.book.id).isEmpty)
        #expect(library.layouts.bookLayoutSettings(forBookID: source.book.id) == nil)
        #expect(library.metadata.metadata(forBookID: source.book.id) == nil)
    }

    // MARK: - 書き出し → 取り込みの往復

    /// 比べるために JSON の一部分を文字列にする(キーの並びを固定する)。
    private func encoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "<encode failed>"
    }

    @Test("別のライブラリへ移しても、書き出した内容がそのまま復元される")
    func aLibraryRoundTripsThroughTheFile() async throws {
        let source = try await ExportSource.zip(pages: 5, label: "roundtrip")
        let origin = try InMemoryLibrary(label: "origin")
        let destination = try InMemoryLibrary(label: "destination")

        // 移す側のライブラリを、4 カテゴリすべてが埋まった状態にする。
        let folder = try #require(try? origin.favorites.createFolder(name: "作者A", parent: nil).get())
        origin.favorites.forceAddFavorite(book: source.book, to: folder)
        origin.layouts.setReadingDirectionOverride(for: source.book, .leftToRight)
        origin.layouts.setPageLayoutState(for: source.book, pageKey: source.key(3), state: .excluded)
        origin.bookmarks.addBookmark(
            bookID: source.book.id, pageIndex: 3, pageKey: source.key(5), name: "最後"
        )
        _ = origin.metadata.upsert(
            bookID: source.book.id, author: "著者", title: "題名", series: "シリーズ", seriesIndex: "1",
            sourceURL: source.book.sourceURL
        )

        let (file, result) = await origin.buildExportFile(.everything)
        #expect(result.allSkippedFilePaths.isEmpty)
        await destination.apply(file, policies: .all(.merge))

        #expect(destination.favoriteBookPaths() == origin.favoriteBookPaths())
        #expect(destination.bookmarkRows(forBookID: source.book.id).map(\.pageKey) == [source.key(5)])
        // 除外を挟んだ実効ページ順で数え直されるので、番号も移す前と同じ。
        #expect(destination.bookmarkRows(forBookID: source.book.id).map(\.pageIndex) == [3])
        #expect(destination.pageStates(forBookID: source.book.id) == [source.key(3): .excluded])
        #expect(
            destination.layouts.bookLayoutSettings(forBookID: source.book.id)?.readingDirectionOverride
                == .leftToRight
        )
        #expect(destination.metadata.metadata(forBookID: source.book.id)?.series == "シリーズ")

        // 移した先から書き出し直すと、同じファイルになる。お気に入りのフォルダ id は取り込みで
        // 振り直される(このファイルの中だけで通用する一時的な文字列)ため、そこだけは
        // 「木の形」で比べる。
        let (again, _) = await destination.buildExportFile(.everything)
        #expect(encoded(again.bookmarks) == encoded(file.bookmarks))
        #expect(encoded(again.layouts) == encoded(file.layouts))
        #expect(encoded(again.metadata) == encoded(file.metadata))
        #expect(encoded(again.metadataFormats) == encoded(file.metadataFormats))
        #expect(again.favorites?.books.map(\.bookID) == file.favorites?.books.map(\.bookID))
        #expect(again.favorites?.folders.map(\.name) == file.favorites?.folders.map(\.name))
    }
}

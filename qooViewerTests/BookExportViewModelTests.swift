import Foundation
import Testing

@testable import qooViewer

/// 書き出しウインドウの下ごしらえと書き込み(ViewModels/BookExportViewModel.swift)。
///
/// 実際の書き出しの中身(CBZ / EPUB / PDF の往復)は段階 3 の `CbzExportTests` などが見る。
/// ここで見るのは**その前後** ―― 材料の集め方(`prepare`)と、出力先への置き方(`write`)。
///
/// 書き込みはテスト用のサブクラスで差し替える。`prepare` と `write` を分けてあるのは、
/// `exportOne` が `BookLoader.load(from:)` を通る(= 共有のページ一覧キャッシュに触れる)ため。
@MainActor
struct BookExportViewModelTests {
    /// 実際には書き出さず、材料と「書いた瞬間の様子」だけを控えるサブクラス。
    private final class StubExportViewModel: BookExportViewModel {
        override var format: BookExportFormat { .cbz }
        override var supportsCoverSelection: Bool { true }

        private(set) var writtenTo: [URL] = []
        /// `export` が呼ばれた時点で、この URL がまだ存在していたか。
        var sourceURLToWatch: URL?
        private(set) var sourceExistedDuringExport: [Bool] = []
        /// true にすると書き込みが失敗する(後始末の確認用)。
        var failsToWrite = false

        override func export(_ prepared: PreparedBook, to destinationURL: URL) async throws {
            if let sourceURLToWatch {
                sourceExistedDuringExport.append(
                    FileManager.default.fileExists(atPath: sourceURLToWatch.path)
                )
            }
            if failsToWrite { throw SimpleError(message: "stub failure") }
            writtenTo.append(destinationURL)
            try Data("stub".utf8).write(to: destinationURL)
        }
    }

    private struct Environment {
        let library: InMemoryLibrary
        let suite: PreferencesSuite
        let preferences: AppPreferences
        let temporary: TemporaryDirectory

        init() throws {
            library = try InMemoryLibrary(label: "export")
            suite = PreferencesSuite(label: "export")
            preferences = suite.makePreferences()
            temporary = try TemporaryDirectory("export")
        }

        func close() { library.close() }

        func makeViewModel() -> StubExportViewModel {
            StubExportViewModel(
                bookmarkStore: library.bookmarks, layoutStore: library.layouts,
                metadataStore: library.metadata, preferences: preferences,
                // 対象一覧は組み立てない(登録済みの全本の実在確認が走るため)。
                loadsEligibleRows: false
            )
        }

        /// ページの中身を持たない、材料集めから見えるぶんだけの本。
        func book(_ name: String, pageKeys: [String] = ["p1", "p2", "p3"]) -> MangaBook {
            let url = temporary.file(name)
            return MangaBook(
                id: url.path, title: name, sourceURL: url,
                pages: SamplePages.pages(pageKeys), pageOrderSource: .fileName
            )
        }

        func row(for book: MangaBook) -> BookExportViewModel.Row {
            BookExportViewModel.Row(
                bookID: book.id, hasLayout: false, hasBookmarks: false, hasMetadata: false
            )
        }
    }

    // MARK: - 読み方向の優先順位(DB > 開いている本 > 既定)

    @Test("読み方向は、本ごとの上書き → 開いている本の表示 → 環境設定の既定 の順に決まる")
    func theReadingDirectionFollowsItsPriority() throws {
        let env = try Environment()
        defer { env.close() }
        env.preferences.defaultReadingDirection = .leftToRight
        let viewModel = env.makeViewModel()
        let book = env.book("book")
        let row = env.row(for: book)
        let openRightToLeft = BookExportViewModel.OpenBookDisplayState(
            readingDirection: .rightToLeft, displayMode: .spread
        )

        // 3つとも無いときは環境設定の既定。**必ず確定した値になる**(nil のままにすると、
        // Apple Books が既定の左開きで開いてしまう。PreparedBook.readingDirection 参照)。
        #expect(viewModel.prepare(row: row, book: book, displayState: nil).readingDirection
            == .leftToRight)
        // 開いている本の表示は、環境設定より優先される。
        #expect(viewModel.prepare(row: row, book: book, displayState: openRightToLeft)
            .readingDirection == .rightToLeft)
        // 本ごとの上書きがあれば、それがいちばん強い。
        env.library.layouts.setReadingDirectionOverride(for: book, .leftToRight)
        #expect(viewModel.prepare(row: row, book: book, displayState: openRightToLeft)
            .readingDirection == .leftToRight)
    }

    @Test("見開きの強制も同じ順序で決まる(こちらは上書きが無ければ nil のまま)")
    func theForcedDisplayModeFollowsTheSamePriority() throws {
        let env = try Environment()
        defer { env.close() }
        let viewModel = env.makeViewModel()
        let book = env.book("book")
        let row = env.row(for: book)
        let openSingle = BookExportViewModel.OpenBookDisplayState(
            readingDirection: .leftToRight, displayMode: .single
        )

        #expect(viewModel.prepare(row: row, book: book, displayState: nil).forcedDisplayMode == nil)
        #expect(viewModel.prepare(row: row, book: book, displayState: openSingle)
            .forcedDisplayMode == .single)
        env.library.layouts.setForcedDisplayMode(for: book, .spread)
        #expect(viewModel.prepare(row: row, book: book, displayState: openSingle)
            .forcedDisplayMode == .spread)
    }

    // MARK: - ブックマークの解決

    @Test("鍵を持つブックマークは鍵で、持たない古い行は従来順の番号で解決する")
    func bookmarksAreResolvedByKeyOrByLegacyIndex() throws {
        let env = try Environment()
        defer { env.close() }
        let viewModel = env.makeViewModel()
        let book = env.book("book", pageKeys: ["p1", "p2", "p3"])
        let row = env.row(for: book)

        env.library.bookmarks.addBookmark(
            bookID: book.id, pageIndex: 0, pageKey: "p3", name: "keyed"
        )
        // 1.36 以前の行。番号は**従来順**で記録されている。
        env.library.bookmarks.addBookmark(bookID: book.id, pageIndex: 1, name: "legacy")
        // 範囲外の番号を持つ壊れた行は落とす。
        env.library.bookmarks.addBookmark(bookID: book.id, pageIndex: 99, name: "broken")

        let prepared = viewModel.prepare(row: row, book: book, displayState: nil)
        #expect(prepared.bookmarks.map(\.name) == ["keyed", "legacy"])
        // 鍵を持つ行は、番号(0)ではなく鍵(p3)が権威。
        #expect(prepared.bookmarks.map(\.pageKey) == ["p3", "p2"])
    }

    @Test("除外ページは、含めない設定なら古いブックマークの番号の数え方からも外れる")
    func excludedPagesShiftTheLegacyBookmarkIndices() throws {
        let env = try Environment()
        defer { env.close() }
        let viewModel = env.makeViewModel()
        let book = env.book("book", pageKeys: ["p1", "p2", "p3"])
        let row = env.row(for: book)
        env.library.layouts.setPageLayoutState(for: book, pageKey: "p1", state: .excluded)
        env.library.bookmarks.addBookmark(bookID: book.id, pageIndex: 1, name: "legacy")

        // 既定(除外ページを含めない)では、p1 が消えるので番号1は p3。
        #expect(viewModel.prepare(row: row, book: book, displayState: nil)
            .bookmarks.map(\.pageKey) == ["p3"])

        viewModel.includeExcludedPages = true
        #expect(viewModel.prepare(row: row, book: book, displayState: nil)
            .bookmarks.map(\.pageKey) == ["p2"])
    }

    // MARK: - 出力先への置き方

    @Test("出力先が元ファイルと同じでも、書いている間ずっと元ファイルは生きている")
    func theOriginalSurvivesWhenTheDestinationIsTheSameFile() async throws {
        let env = try Environment()
        defer { env.close() }
        let viewModel = env.makeViewModel()
        // 「cbz を開いて cbz として同じ場所へ書き出す」= 出力先のパスが元ファイルと同じになる。
        let sourceURL = env.temporary.file("book.cbz")
        try Data("original".utf8).write(to: sourceURL)
        let book = env.book("book.cbz")
        viewModel.sourceURLToWatch = sourceURL
        // 同名ファイルの確認には先に答えておく(この経路では画面が無い)。
        viewModel.resolveOverwrite(.overwrite, applyToRemaining: true)

        let prepared = viewModel.prepare(row: env.row(for: book), book: book, displayState: nil)
        try await viewModel.write(prepared, to: env.temporary.url)

        // バグ修正の要: Exporter は書き始めに出力先を消すので、直接書くと**元ファイルが消え**、
        // そこから1枚ずつ読み出すページ画像も失われていた。必ず一時ファイルへ書いて置き換える。
        #expect(viewModel.sourceExistedDuringExport == [true])
        #expect(viewModel.writtenTo.first?.lastPathComponent.hasPrefix(".qooViewer-export-") == true)
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == "stub")
        // 一時ファイルは残らない。
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: env.temporary.url.path)
        #expect(leftovers.contains { $0.hasPrefix(".qooViewer-export-") } == false)
    }

    @Test("書き出しに失敗したら、一時ファイルも出力先の中途半端なファイルも残さない")
    func aFailedExportLeavesNothingBehind() async throws {
        let env = try Environment()
        defer { env.close() }
        let viewModel = env.makeViewModel()
        let destination = env.temporary.file("book.cbz")
        try Data("original".utf8).write(to: destination)
        let book = env.book("book.cbz")
        viewModel.failsToWrite = true
        viewModel.resolveOverwrite(.overwrite, applyToRemaining: true)

        let prepared = viewModel.prepare(row: env.row(for: book), book: book, displayState: nil)
        await #expect(throws: (any Error).self) {
            try await viewModel.write(prepared, to: env.temporary.url)
        }

        // 元(= 出力先)のファイルはそのまま。
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: env.temporary.url.path)
        #expect(leftovers.contains { $0.hasPrefix(".qooViewer-export-") } == false)
    }

    @Test("同名ファイルの確認でスキップを選ぶと、出力先には手を付けない")
    func skippingLeavesTheExistingFileAlone() async throws {
        let env = try Environment()
        defer { env.close() }
        let viewModel = env.makeViewModel()
        let destination = env.temporary.file("book.cbz")
        try Data("original".utf8).write(to: destination)
        let book = env.book("book.cbz")
        viewModel.resolveOverwrite(.skip, applyToRemaining: true)

        let prepared = viewModel.prepare(row: env.row(for: book), book: book, displayState: nil)
        await #expect(throws: BookExportViewModel.ExportSkippedByUser.self) {
            try await viewModel.write(prepared, to: env.temporary.url)
        }
        #expect(viewModel.writtenTo.isEmpty)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    }
}

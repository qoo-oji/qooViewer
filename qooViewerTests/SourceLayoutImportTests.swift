import Foundation
import Testing

@testable import qooViewer

/// ファイル自身が持つレイアウト(EPUB の spine / PDF の Catalog)を DB へ**一度だけ**取り込む
/// `LayoutStore.importSourceLayoutIfNeeded(for:)`。メモリ内の SwiftData(`InMemoryLibrary`)の上で。
///
/// この 1 回きりの取り込みが、EPUB / PDF を「他の形式と同じように自由に設定を変えられる本」に
/// している要(CLAUDE.md / docs/07)。ファイルの指定は**種**であって権威ではない ―― 取り込んだ
/// あとは DB が正典なので、2 回目の呼び出しで利用者の変更を踏み潰さないことが肝心になる。
/// 以前はファイル側の指定が常に勝ち、切り替え自体がグレーアウトされていた(その設計は撤回済み)。
@MainActor
struct SourceLayoutImportTests {

    /// 見開き指定と読み方向を持つ EPUB を作って開く。`temp` は本が消えないよう一緒に返す。
    private func epubBook(
        pages: Int = 4,
        spreadProperties: [Int: String] = [0: "rendition:page-spread-center", 1: "page-spread-left",
                                           2: "page-spread-right"],
        pageProgressionDirection: String? = "rtl",
        renditionSpread: String? = "none",
        label: String = "source-layout-epub"
    ) async throws -> (temp: TemporaryDirectory, book: MangaBook) {
        let temp = try TemporaryDirectory(label)
        var builder = EpubFixtureBuilder.pages(pages)
        for (index, properties) in spreadProperties { builder.pages[index].spineProperties = properties }
        builder.pageProgressionDirection = pageProgressionDirection
        builder.renditionSpread = renditionSpread
        let url = temp.file("book.epub")
        try builder.write(to: url)
        return (temp, try await FixtureBook.load(url))
    }

    // MARK: - 取り込み

    @Test("EPUB の読み方向・見開き・ページごとの配置が、DB へそのまま入る")
    func epubLayoutLandsInTheDatabase() async throws {
        let (_, book) = try await epubBook()
        let library = try InMemoryLibrary()

        library.layouts.importSourceLayoutIfNeeded(for: book)

        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: book.id))
        #expect(settings.readingDirectionOverride == .rightToLeft)
        #expect(settings.forcedDisplayMode == .single)
        #expect(settings.didImportSourceLayout)
        // center → 単一ページ、left → 見開き左、right → 見開き右(PageLayoutState の変換と対)。
        #expect(library.pageStates(forBookID: book.id) == [
            "000000": .single, "000001": .spreadLeft, "000002": .spreadRight
        ])
    }

    @Test("2 回目は何もしない ―― 取り込んだあとに変えた設定はそのまま残る")
    func theSecondImportIsANoOp() async throws {
        let (_, book) = try await epubBook()
        let library = try InMemoryLibrary()

        library.layouts.importSourceLayoutIfNeeded(for: book)
        // 利用者が自分で変える(DB が正典)。
        library.layouts.setReadingDirectionOverride(for: book, .leftToRight)
        library.layouts.setPageLayoutState(for: book, pageKey: "000001", state: .excluded)

        library.layouts.importSourceLayoutIfNeeded(for: book)

        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: book.id))
        #expect(settings.readingDirectionOverride == .leftToRight)
        #expect(library.pageStates(forBookID: book.id)["000001"] == .excluded)
    }

    @Test("先に設定してあった本全体の設定は、取り込みで上書きされない")
    func existingBookLevelSettingsWin() async throws {
        let (_, book) = try await epubBook()
        let library = try InMemoryLibrary()
        // 取り込み前に(例えば別の経路で)読み方向だけ決まっている状態。
        library.layouts.setReadingDirectionOverride(for: book, .leftToRight)

        library.layouts.importSourceLayoutIfNeeded(for: book)

        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: book.id))
        #expect(settings.readingDirectionOverride == .leftToRight)
        // まだ空だった項目にはファイルの指定が入る。
        #expect(settings.forcedDisplayMode == .single)
        #expect(settings.didImportSourceLayout)
    }

    @Test("先に設定してあったページ単位の設定は、取り込みで上書きされない")
    func existingPageStatesWin() async throws {
        let (_, book) = try await epubBook()
        let library = try InMemoryLibrary()
        library.layouts.setPageLayoutState(for: book, pageKey: "000001", state: .spreadRight)

        library.layouts.importSourceLayoutIfNeeded(for: book)

        #expect(library.pageStates(forBookID: book.id) == [
            "000000": .single, "000001": .spreadRight, "000002": .spreadRight
        ])
    }

    // MARK: - 取り込むものが無い本

    @Test("取り込むものが何も無い EPUB では、行を作らない")
    func nothingToImportCreatesNoRow() async throws {
        let (_, book) = try await epubBook(
            spreadProperties: [:], pageProgressionDirection: nil, renditionSpread: nil,
            label: "source-layout-epub-empty"
        )
        let library = try InMemoryLibrary()

        library.layouts.importSourceLayoutIfNeeded(for: book)

        // EPUB は sourceLayoutHint 自体は必ず持つ(中身が空なだけ)。判定は中身で行う。
        #expect(book.sourceLayoutHint != nil)
        #expect(library.layouts.bookLayoutSettings(forBookID: book.id) == nil)
        #expect(library.layouts.pageOverrides(forBookID: book.id).isEmpty)
    }

    @Test("zip の本(ファイル側に指定が無い形式)でも、行を作らない")
    func archivesCreateNoRow() async throws {
        let source = try await ExportSource.zip(pages: 3, label: "source-layout-zip")
        let library = try InMemoryLibrary()

        library.layouts.importSourceLayoutIfNeeded(for: source.book)

        #expect(source.book.sourceLayoutHint == nil)
        #expect(library.layouts.bookLayoutSettings(forBookID: source.book.id) == nil)
    }

    // MARK: - PDF

    @Test("PDF は Catalog の /ViewerPreferences と /PageLayout が入る")
    func pdfCatalogLayoutLandsInTheDatabase() async throws {
        let temp = try TemporaryDirectory("source-layout-pdf")
        let url = temp.file("book.pdf")
        try PDFFixtureBuilder.write(to: url, pageNumbers: [1, 2, 3], title: "テスト本", author: "作者")
        try PDFCatalogAugmenter.apply(
            PDFCatalogAugmenter.Augmentation(
                viewerPreferencesDirection: PDFStructureResolver.catalogDirectionName(for: .rightToLeft),
                pageLayout: PDFStructureResolver.catalogPageLayoutName(for: .spread, direction: .rightToLeft)
            ),
            to: url
        )
        let book = try await FixtureBook.load(url)
        let library = try InMemoryLibrary()

        library.layouts.importSourceLayoutIfNeeded(for: book)

        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: book.id))
        #expect(settings.readingDirectionOverride == .rightToLeft)
        #expect(settings.forcedDisplayMode == .spread)
        #expect(settings.didImportSourceLayout)
        // PDF にはページごとの見開き指定が無いので、ページ単位の行は作られない。
        #expect(library.layouts.pageOverrides(forBookID: book.id).isEmpty)
    }
}

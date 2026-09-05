import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// PDF 書き出し(`PDFExporter` + `PDFCatalogAugmenter` + `PDFXMPMetadata`)のラウンドトリップ。
/// 書き出した PDF を `CGPDFDocument` と `PDFStructureResolver` ―― 読み込み側そのもの ―― で
/// 開き直して突き合わせる。
///
/// CoreGraphics の PDF コンテキストからは書けない項目(読み方向・見開き強制・シリーズの XMP)は、
/// 閉じたあとに増分更新で追記している。**その追記が壊れると PDF ごと開けなくなる**ので、
/// ここでは必ず「開き直せること」まで見る。
struct PDFExportTests {

    /// `options` を省くと既定(画面の既定値と同じ)。既定引数の式には `ExportInputs.pdfOptions` を
    /// 直接は書けない ―― 既定引数はメインアクター外として検査されるため(`MangaBook` と同じく
    /// `PDFExportOptions` もメインアクターの型)。nil を受けて中で解く。
    private func export(
        _ source: ExportSource, _ input: PDFExportInput,
        options: PDFExportOptions? = nil, name: String = "book"
    ) async throws -> URL {
        let url = source.destination("\(name).pdf")
        try await PDFExporter.export(input, options: options ?? ExportInputs.pdfOptions, to: url)
        return url
    }

    /// 書き出した PDF を本として開き直し、ページ順に「中身の番号」を読む。
    ///
    /// ページ画像は `PageLoader` から取る ―― ビューアがページを表示するのと同じ経路。
    /// **共有のサムネイルキャッシュに触れないよう `usesThumbnailDiskCache: false` を必ず渡す**
    /// (TEST_HOST は実物のアプリなので、手元では自分のコンテナで走る)。
    private func exportedPageNumbers(_ url: URL) async throws -> [Int] {
        let book = try await FixtureBook.load(url)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        var numbers: [Int] = []
        for index in book.pages.indices {
            let exportable = try await loader.exportableImage(at: index)
            numbers.append(exportable.map { PageColorReader.number(in: $0.data) ?? -1 } ?? -1)
        }
        return numbers
    }

    // MARK: - 並び順

    @Test("並べ替えと除外は、そのままページの並びとして書き出される")
    func pageOrderSurvivesRoundTrip() async throws {
        let source = try await ExportSource.folder(pages: 5, label: "pdf-order")
        let url = try await export(
            source,
            ExportInputs.pdf(
                source,
                pageOrderOverride: source.pageKeys.reversed(),
                pageOverrides: [source.key(3): .excluded]
            ),
            name: "order"
        )

        let document = try #require(CGPDFDocument(url as CFURL))
        #expect(document.numberOfPages == 4)
        #expect(try await exportedPageNumbers(url) == [5, 4, 2, 1])
    }

    @Test("書き出せるページが 1 枚も無ければ noEligiblePages(ファイルは作らない)")
    func noEligiblePages() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "pdf-empty")
        let destination = source.destination("empty.pdf")
        let overrides = Dictionary(uniqueKeysWithValues: source.pageKeys.map { ($0, PageLayoutState.excluded) })
        await #expect(throws: PDFExportError.self) {
            try await PDFExporter.export(
                ExportInputs.pdf(source, pageOverrides: overrides),
                options: ExportInputs.pdfOptions, to: destination
            )
        }
        // 「書き出しに失敗すると壊れたファイルだけが残る」不具合の再発防止(PDFExporter のコメント)。
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Document Catalog(増分更新で追記する項目)

    @Test(
        "読み方向と見開き強制は Catalog へ書かれ、読み取り側で同じ値に戻る",
        arguments: [
            (ReadingDirection.rightToLeft, DisplayMode.spread),
            (.leftToRight, .spread),
            (.rightToLeft, nil),
        ] as [(ReadingDirection, DisplayMode?)]
    )
    func layoutHintSurvivesRoundTrip(direction: ReadingDirection, mode: DisplayMode?) async throws {
        let source = try await ExportSource.folder(pages: 2, label: "pdf-layout")
        let url = try await export(
            source, ExportInputs.pdf(source, readingDirection: direction, forcedDisplayMode: mode),
            name: "layout-\(direction)-\(String(describing: mode))"
        )
        let document = try #require(CGPDFDocument(url as CFURL))
        #expect(
            PDFStructureResolver.resolveLayoutHint(document: document)
                == SourceLayoutHint(pageProgressionDirection: direction, forcedDisplayMode: mode)
        )

        // 本として開いたときの取り込み元(LayoutStore.importSourceLayoutIfNeeded が使う)。
        let book = try await FixtureBook.load(url)
        #expect(book.sourceLayoutHint?.pageProgressionDirection == direction)
    }

    @Test("シリーズ名・巻数・タイトル・著者は Calibre 互換の XMP として往復する")
    func xmpMetadataSurvivesRoundTrip() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "pdf-xmp")
        let url = try await export(
            source,
            ExportInputs.pdf(
                source, title: "テスト本", author: "作者", series: "テストシリーズ", seriesIndex: "3.5"
            ),
            name: "xmp"
        )

        let document = try #require(CGPDFDocument(url as CFURL))
        let packet = try #require(PDFXMPMetadata.readPacket(from: document), "XMP が埋め込まれていない")
        let metadata = PDFXMPMetadata.parse(packet)
        #expect(metadata.title == "テスト本")
        #expect(metadata.author == "作者")
        #expect(metadata.series == "テストシリーズ")
        #expect(metadata.seriesIndex == "3.5")

        // Info 辞書(XMP とは別経路)にも同じタイトル・著者が入っている。
        let info = PDFStructureResolver.resolveMetadata(url: url)
        #expect(info.title == "テスト本")
        #expect(info.author == "作者")
    }

    /// シリーズ名が無いときは XMP を足さない ―― パケットを置くと Info 辞書より優先されるように
    /// なるため、「XMP でしか表せないもの」が無いなら素の Quartz 製 PDF のままにする
    /// (`PDFXMPMetadata.packet` のコメント)。
    @Test("シリーズ名が無ければ XMP パケット自体を埋め込まない")
    func noXMPWithoutSeries() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "pdf-noxmp")
        let url = try await export(source, ExportInputs.pdf(source, title: "テスト本"), name: "noxmp")
        let document = try #require(CGPDFDocument(url as CFURL))
        #expect(PDFXMPMetadata.readPacket(from: document) == nil)
        // 読み方向は常に書くので、Catalog への追記そのものは行われている。
        #expect(PDFStructureResolver.resolveLayoutHint(document: document) != nil)
    }

    /// 増分更新は「追記」なので原理的には重ねられるが、Catalog に `/Metadata`・`/PageLayout`・
    /// `/ViewerPreferences` が既にあると項目が重複してしまうため、**追記済みの PDF は想定外として
    /// 断る**(readLayout の該当箇所)。断る側のふるまいで大事なのは「ファイルに手を付けないこと」
    /// ―― 追記に失敗して壊れた PDF だけが残る、が起きないこと。
    @Test("追記済みの PDF へもう一度追記しようとしても、ファイルには手を付けずに断る")
    func augmentingTwiceIsRefusedWithoutTouchingTheFile() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "pdf-twice")
        let url = try await export(
            source,
            ExportInputs.pdf(
                source, title: "テスト本", series: "最初のシリーズ", seriesIndex: "1",
                readingDirection: .rightToLeft, forcedDisplayMode: .spread
            ),
            name: "twice"
        )
        let before = try Data(contentsOf: url)

        #expect(throws: PDFCatalogAugmenter.AugmentError.self) {
            try PDFCatalogAugmenter.apply(
                PDFCatalogAugmenter.Augmentation(
                    xmpPacket: PDFXMPMetadata.packet(
                        title: "テスト本", author: nil, series: "あとのシリーズ", seriesIndex: "2"
                    ),
                    viewerPreferencesDirection: PDFStructureResolver.catalogDirectionName(for: .leftToRight),
                    pageLayout: PDFStructureResolver.catalogPageLayoutName(for: .single, direction: .leftToRight)
                ),
                to: url
            )
        }

        #expect(try Data(contentsOf: url) == before, "1 バイトも変わっていない")
        let document = try #require(CGPDFDocument(url as CFURL), "断られた後も PDF として開ける")
        #expect(document.numberOfPages == 2)
        let packet = try #require(PDFXMPMetadata.readPacket(from: document))
        #expect(PDFXMPMetadata.parse(packet).series == "最初のシリーズ")
        #expect(
            PDFStructureResolver.resolveLayoutHint(document: document)
                == SourceLayoutHint(pageProgressionDirection: .rightToLeft, forcedDisplayMode: .spread)
        )
        #expect(try await exportedPageNumbers(url) == [1, 2])
    }

    /// 何も足すものが無ければ、そもそもファイルを開きに行かない(`Augmentation.isEmpty`)。
    @Test("空の追記は何もしない(追記済みの PDF でも断らない)")
    func emptyAugmentationIsANoOp() async throws {
        let source = try await ExportSource.folder(pages: 1, label: "pdf-noop")
        let url = try await export(source, ExportInputs.pdf(source), name: "noop")
        let before = try Data(contentsOf: url)
        try PDFCatalogAugmenter.apply(PDFCatalogAugmenter.Augmentation(), to: url)
        #expect(try Data(contentsOf: url) == before)
    }

    // MARK: - アウトライン

    @Test("ブックマークはアウトラインになり、書き出し後のページ位置を指す")
    func bookmarksBecomeOutline() async throws {
        let source = try await ExportSource.folder(pages: 4, label: "pdf-outline")
        let url = try await export(
            source,
            ExportInputs.pdf(
                source,
                pageOrderOverride: source.pageKeys.reversed(),
                bookmarks: [
                    ExportBookmark(pageKey: source.key(4), name: "第1章"),
                    ExportBookmark(pageKey: source.key(1), name: "第2章"),
                ]
            ),
            name: "outline"
        )
        let entries = PDFStructureResolver.resolveOutline(url: url)
        // 逆順に並べ替えたので、4 ページ目が先頭(0)、1 ページ目が末尾(3)。
        #expect(entries.map(\.title) == ["第1章", "第2章"])
        #expect(entries.map(\.pageIndex) == [0, 3])
    }

    @Test("除外したページを指すブックマークは、アウトラインから落ちる")
    func bookmarksOnExcludedPagesAreDropped() async throws {
        let source = try await ExportSource.folder(pages: 3, label: "pdf-outline-excluded")
        let url = try await export(
            source,
            ExportInputs.pdf(
                source,
                pageOverrides: [source.key(2): .excluded],
                bookmarks: [
                    ExportBookmark(pageKey: source.key(2), name: "消えるしおり"),
                    ExportBookmark(pageKey: source.key(3), name: "残るしおり"),
                ]
            ),
            name: "outline-excluded"
        )
        let entries = PDFStructureResolver.resolveOutline(url: url)
        #expect(entries.map(\.title) == ["残るしおり"])
        #expect(entries.map(\.pageIndex) == [1])
    }
}

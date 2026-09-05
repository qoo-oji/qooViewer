import Foundation
import Testing

@testable import qooViewer

/// EPUB 書き出し(`EpubExporter`)のラウンドトリップ。書き出した EPUB を `EpubStructureResolver`
/// ―― 読み込み側そのもの ―― で開き直して突き合わせる。
///
/// EPUB はページ順・見開き・読み方向をファイル自身が持つ唯一の形式なので、CBZ と違って
/// 並べ替えは連番リネームに頼らず spine が運ぶ。書式そのものの正しさ(EPUBCheck)は CI が
/// 別途見る(添付として残した実物を `scripts/ci/validate-exports.sh` が検品する)。
struct EpubExportTests {

    /// 書き出した EPUB と、その解決結果。`source` を握り続けるのは、作業フォルダが消えると
    /// 出力ごと消えるため(`EpubStructureTests.Resolved` と同じ)。
    private struct Exported {
        let source: ExportSource
        let url: URL
        let reader: ArchiveReading
        let structure: EpubStructure

        /// spine 順に、ページ画像の中身の番号。
        func pageNumbers() throws -> [Int] {
            try structure.pages.map { PageColorReader.number(in: try reader.data(at: $0.entryPath)) ?? -1 }
        }

        func text(at entryPath: String) throws -> String {
            String(decoding: try reader.data(at: entryPath), as: UTF8.self)
        }
    }

    /// `options` を省くと既定(画面の既定値と同じ)。既定引数の式には `ExportInputs.epubOptions` を
    /// 直接は書けない ―― 既定引数はメインアクター外として検査されるため(`MangaBook` と同じく
    /// `EpubExportOptions` もメインアクターの型)。nil を受けて中で解く。
    private func export(
        _ source: ExportSource, _ input: EpubExportInput,
        options: EpubExportOptions? = nil, name: String = "book"
    ) async throws -> Exported {
        let url = source.destination("\(name).epub")
        try await EpubExporter.export(input, options: options ?? ExportInputs.epubOptions, to: url)
        // EPUBCheck にかけるため、CI では実物を控える(手元では何もしない)。
        ExportArtifacts.keep(url, as: "\(name).epub")
        let reader = try ZipArchiveReader(url: url)
        return Exported(
            source: source, url: url, reader: reader,
            structure: try EpubStructureResolver.resolve(reader: reader)
        )
    }

    // MARK: - 並び順

    @Test("並べ替えと除外は spine の順として書き出され、開き直すとそのまま戻る")
    func spineOrderSurvivesRoundTrip() async throws {
        let source = try await ExportSource.folder(pages: 5, label: "epub-order")
        let exported = try await export(
            source,
            ExportInputs.epub(
                source,
                pageOrderOverride: source.pageKeys.reversed(),
                pageOverrides: [source.key(3): .excluded]
            ),
            name: "order"
        )

        #expect(exported.structure.pages.map(\.entryPath) == (0..<4).map { "OEBPS/Images/\($0).png" })
        #expect(try exported.pageNumbers() == [5, 4, 2, 1])

        // 本として開き直しても同じ(ページ順は spine から来る)。EPUB の sortKey は spine 上の
        // 位置そのもの(6 桁連番)で、エントリのパスは id に入る(GeneratedFixtureTests.epubBook)。
        let book = try await FixtureBook.load(exported.url)
        #expect(book.pages.map(\.sortKey) == ["000000", "000001", "000002", "000003"])
        #expect(book.pages.map(\.id) == exported.structure.pages.map { "\(exported.url.path)#\($0.entryPath)" })
        #expect(book.pageOrderSource == .document)
    }

    /// 連番リネームを切っても、CBZ と違って並べ替えは失われない(spine が順序を持つため)。
    @Test("連番リネームを切っても spine が順序を運ぶ")
    func originalNamesKeepTheReorder() async throws {
        let source = try await ExportSource.folder(pages: 3, label: "epub-names")
        let exported = try await export(
            source, ExportInputs.epub(source, pageOrderOverride: source.pageKeys.reversed()),
            options: EpubExportOptions(renumberImagesSequentially: false, includeExcludedPages: false),
            name: "names"
        )
        #expect(exported.structure.pages.map(\.entryPath) == [
            "OEBPS/Images/003.png", "OEBPS/Images/002.png", "OEBPS/Images/001.png",
        ])
        #expect(try exported.pageNumbers() == [3, 2, 1])
    }

    @Test("書き出せるページが 1 枚も無ければ noEligiblePages(ファイルは作らない)")
    func noEligiblePages() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "epub-empty")
        let destination = source.destination("empty.epub")
        let overrides = Dictionary(uniqueKeysWithValues: source.pageKeys.map { ($0, PageLayoutState.excluded) })
        await #expect(throws: EpubExportError.self) {
            try await EpubExporter.export(
                ExportInputs.epub(source, pageOverrides: overrides),
                options: ExportInputs.epubOptions, to: destination
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - コンテナの形

    /// EPUB の仕様は「mimetype が zip の最初のエントリで、無圧縮(格納)であること」を求める。
    /// リーダーはここでファイル種別を判断するので、崩れると開けなくなる。ZIPFoundation 越しでは
    /// 「先頭であること」を確かめられないため、ローカルファイルヘッダを直に読む。
    @Test("mimetype は zip の先頭エントリで、無圧縮で入っている")
    func mimetypeIsFirstAndStored() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "epub-mimetype")
        let exported = try await export(source, ExportInputs.epub(source), name: "mimetype")
        let bytes = [UInt8](try Data(contentsOf: exported.url))

        #expect(Array(bytes[0..<4]) == [0x50, 0x4B, 0x03, 0x04], "ローカルファイルヘッダで始まる")
        let compressionMethod = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
        #expect(compressionMethod == 0, "無圧縮(格納)")
        let nameLength = Int(UInt16(bytes[26]) | UInt16(bytes[27]) << 8)
        #expect(String(decoding: bytes[30..<(30 + nameLength)], as: UTF8.self) == "mimetype")
        #expect(try exported.text(at: "mimetype") == "application/epub+zip")
    }

    @Test("container.xml は OPF を指し、OPF が示す画像がすべて実在する")
    func containerAndManifestAreConsistent() async throws {
        let source = try await ExportSource.folder(pages: 3, label: "epub-container")
        let exported = try await export(source, ExportInputs.epub(source), name: "container")
        #expect(try exported.text(at: "META-INF/container.xml").contains("OEBPS/package.opf"))

        let paths = Set(try exported.reader.listFilePaths())
        #expect(exported.structure.pages.allSatisfy { paths.contains($0.entryPath) })
        #expect(exported.structure.pages.map(\.sourceHref).allSatisfy { paths.contains($0) })
    }

    // MARK: - レイアウト

    @Test(
        "本全体の読み方向と見開き強制は spine / rendition:spread として往復する",
        arguments: [
            (ReadingDirection.rightToLeft, DisplayMode.spread),
            (.leftToRight, .single),
        ]
    )
    func layoutHintsSurviveRoundTrip(direction: ReadingDirection, mode: DisplayMode) async throws {
        let source = try await ExportSource.folder(pages: 2, label: "epub-layout")
        let exported = try await export(
            source, ExportInputs.epub(source, readingDirection: direction, forcedDisplayMode: mode),
            name: "layout-\(direction)-\(mode)"
        )
        #expect(exported.structure.pageProgressionDirection == direction)
        #expect(exported.structure.forcedDisplayMode == mode)

        // 本として開いたときの取り込み元(LayoutStore.importSourceLayoutIfNeeded が使う)。
        let book = try await FixtureBook.load(exported.url)
        #expect(book.sourceLayoutHint == SourceLayoutHint(pageProgressionDirection: direction, forcedDisplayMode: mode))
    }

    @Test("指定が無ければ読み方向も見開き強制も書かない")
    func noLayoutHints() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "epub-nolayout")
        let exported = try await export(source, ExportInputs.epub(source), name: "nolayout")
        #expect(exported.structure.pageProgressionDirection == nil)
        #expect(exported.structure.forcedDisplayMode == nil)
    }

    /// qooViewer の「単一ページ / 見開き左 / 見開き右」は、EPUB の spine の properties へ写す
    /// (`PageLayoutState.asEpubEquivalentSpreadPosition`)。往復して同じ位置へ戻ること。
    @Test("ページごとの見開き指定は spine の properties として往復する")
    func perPageSpreadPositions() async throws {
        let source = try await ExportSource.folder(pages: 4, label: "epub-spread")
        let exported = try await export(
            source,
            ExportInputs.epub(
                source,
                pageOverrides: [
                    source.key(1): .single, source.key(2): .spreadLeft, source.key(3): .spreadRight,
                ]
            ),
            name: "spread"
        )
        #expect(exported.structure.pages.map(\.spreadPosition) == [.center, .left, .right, nil])

        let book = try await FixtureBook.load(exported.url)
        #expect(book.pages.map(\.epubSpreadPosition) == [.center, .left, .right, nil])
    }

    // MARK: - 目次

    @Test("ブックマークは nav.xhtml の目次になり、書き出し後のページ位置を指す")
    func bookmarksBecomeTableOfContents() async throws {
        let source = try await ExportSource.folder(pages: 4, label: "epub-toc")
        let exported = try await export(
            source,
            ExportInputs.epub(
                source,
                pageOrderOverride: source.pageKeys.reversed(),
                bookmarks: [
                    ExportBookmark(pageKey: source.key(4), name: "第1章"),
                    ExportBookmark(pageKey: source.key(1), name: "第2章"),
                ]
            ),
            name: "toc"
        )
        let toc = EpubStructureResolver.resolveTableOfContents(
            reader: exported.reader, structure: exported.structure
        )
        // 逆順に並べ替えたので、4 ページ目が先頭(0)、1 ページ目が末尾(3)。
        #expect(toc.map(\.title) == ["第1章", "第2章"])
        #expect(toc.map(\.pageIndex) == [0, 3])
    }

    // MARK: - 書誌メタデータ

    @Test("タイトル・著者・シリーズ・巻数・言語が往復する")
    func metadataSurvivesRoundTrip() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "epub-metadata")
        let exported = try await export(
            source,
            ExportInputs.epub(
                source, title: "テスト本", author: "作者", series: "テストシリーズ", seriesIndex: "3.5",
                language: "ja"
            ),
            name: "metadata"
        )
        let metadata = EpubStructureResolver.resolveMetadata(reader: exported.reader)
        #expect(metadata.title == "テスト本")
        #expect(metadata.author == "作者")
        #expect(metadata.series == "テストシリーズ")
        #expect(metadata.seriesIndex == "3.5")
        // dc:language は EPUB3 の必須要素。解決役は言語を返さないので OPF を直接見る。
        #expect(try exported.text(at: "OEBPS/package.opf").contains("<dc:language>ja</dc:language>"))
    }

    @Test("言語の指定が無ければ en にする(dc:language は省略できない)")
    func languageFallsBackToEnglish() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "epub-language")
        let exported = try await export(source, ExportInputs.epub(source, language: nil), name: "language")
        #expect(try exported.text(at: "OEBPS/package.opf").contains("<dc:language>en</dc:language>"))
    }

    @Test("カバーは cover-image と EPUB2 互換の guide の両方で示す")
    func coverIsMarkedTwice() async throws {
        let source = try await ExportSource.folder(pages: 3, label: "epub-cover")
        let exported = try await export(
            source, ExportInputs.epub(source, coverOverride: .existingPage(pageKey: source.key(2))),
            name: "cover"
        )
        let opf = try exported.text(at: "OEBPS/package.opf")
        // 2 ページ目をカバーにしたので、その画像(1.png)に properties が付く。
        #expect(opf.contains("href=\"Images/1.png\" media-type=\"image/png\" properties=\"cover-image\""))
        #expect(opf.contains("<reference type=\"cover\" title=\"Cover\" href=\"Text/1.xhtml\"/>"))
        // カバーにしてもページは増えない(spine はそのまま 3 ページ)。
        #expect(exported.structure.pages.count == 3)
    }

    // MARK: - 画像形式

    /// EPUB へそのまま入れられるのは jpg / jpeg / png / gif だけ(`passthroughImageExtensions`)。
    /// それ以外は PNG へ変換して入れる ―― 変換したあとも中身が同じページであること。
    @Test("EPUB に入れられない形式は PNG へ変換して書き出す")
    func convertsUnsupportedImageFormats() async throws {
        let source = try await ExportSource.folder(pages: 2, fileExtension: "tif", label: "epub-convert")
        let exported = try await export(source, ExportInputs.epub(source), name: "convert")
        #expect(exported.structure.pages.map(\.entryPath) == ["OEBPS/Images/0.png", "OEBPS/Images/1.png"])
        #expect(try exported.pageNumbers() == [1, 2])
    }

    @Test("jpg はそのまま素通しする(再エンコードしない)")
    func passesThroughJPEG() async throws {
        let source = try await ExportSource.folder(pages: 2, fileExtension: "jpg", label: "epub-jpeg")
        let exported = try await export(source, ExportInputs.epub(source), name: "jpeg")
        #expect(exported.structure.pages.map(\.entryPath) == ["OEBPS/Images/0.jpg", "OEBPS/Images/1.jpg"])
        // 素通しなら、元のファイルとバイト単位で同じ。
        let original = try Data(contentsOf: URL(fileURLWithPath: source.key(1)))
        #expect(try exported.reader.data(at: "OEBPS/Images/0.jpg") == original)
    }
}

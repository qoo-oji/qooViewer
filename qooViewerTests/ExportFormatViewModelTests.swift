import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// 3 つの書き出しウインドウの、**形式ごとの差分**
/// (ViewModels/CbzExportViewModel.swift / EpubExportViewModel.swift / PDFExportViewModel.swift)。
///
/// 共通部分は基底クラスの `BookExportViewModelTests` が見ている。ここに残るのは各サブクラスが
/// 持つものだけ ―― `format` / `supportsCoverSelection` / 集めた材料を自分の形式の
/// ExportInput・ExportOptions へ詰め替えるところ。
///
/// 見方は `prepare` → `write` の往復。`write` はサブクラスの `export(_:to:)` を呼ぶので、
/// **詰め替えの結果は実物の出力を読み直せば分かる**(スタブで受け止めると、詰め替えを間違えても
/// テストは通ってしまう)。書き出しの中身そのものは段階 3 の `CbzExportTests` などの担当なので、
/// ここでは「ViewModel の値が出力まで届くか」だけを見る。
///
/// `exportOne` ではなく `prepare` + `write` を呼ぶのは、あちらが `BookLoader.load(from:)` を
/// 通る = 共有のページ一覧キャッシュに触れるため(`BookExportViewModelTests` と同じ)。
@MainActor
struct ExportFormatViewModelTests {
    private struct Environment {
        let library: InMemoryLibrary
        let suite: PreferencesSuite
        let preferences: AppPreferences
        let source: ExportSource

        static func make(pages: Int = 4, label: String = "format") async throws -> Environment {
            let suite = PreferencesSuite(label: label)
            return Environment(
                library: try InMemoryLibrary(label: label),
                suite: suite,
                preferences: suite.makePreferences(),
                source: try await ExportSource.folder(pages: pages, label: label)
            )
        }

        func close() { library.close() }

        var book: MangaBook { source.book }

        var row: BookExportViewModel.Row {
            BookExportViewModel.Row(
                bookID: book.id, hasLayout: false, hasBookmarks: false, hasMetadata: false
            )
        }

        /// 対象一覧は組み立てない(登録済みの全本の実在確認が走るため)。
        func viewModel(for format: BookExportFormat) -> BookExportViewModel {
            switch format {
            case .cbz: return cbz()
            case .epub: return epub()
            case .pdf: return pdf()
            }
        }

        func cbz() -> CbzExportViewModel {
            CbzExportViewModel(
                bookmarkStore: library.bookmarks, layoutStore: library.layouts,
                metadataStore: library.metadata, preferences: preferences, loadsEligibleRows: false
            )
        }

        func epub() -> EpubExportViewModel {
            EpubExportViewModel(
                bookmarkStore: library.bookmarks, layoutStore: library.layouts,
                metadataStore: library.metadata, preferences: preferences, loadsEligibleRows: false
            )
        }

        func pdf() -> PDFExportViewModel {
            PDFExportViewModel(
                bookmarkStore: library.bookmarks, layoutStore: library.layouts,
                metadataStore: library.metadata, preferences: preferences, loadsEligibleRows: false
            )
        }

        /// 材料を集めて、その形式で 1 冊書き出す。返すのは書き出したファイル。
        func write(_ viewModel: BookExportViewModel, name: String = "out") async throws -> URL {
            let folder = try source.temp.directory("\(name)-\(UUID().uuidString)")
            let prepared = viewModel.prepare(row: row, book: book, displayState: nil)
            try await viewModel.write(prepared, to: folder)
            return folder.appendingPathComponent("\(row.displayName).\(viewModel.outputFileExtension)")
        }

        /// 巻数だけを登録する(シリーズ名が無いと PDF は XMP 自体を書かない)。
        func setSeries(_ series: String, index: String) {
            library.metadata.upsert(
                bookID: book.id, author: "", title: "", series: series, seriesIndex: index
            )
        }
    }

    /// 書き出した cbz の ComicInfo.xml。
    private func comicInfo(in url: URL) throws -> ComicInfo {
        let reader = try ZipArchiveReader(url: url)
        return try #require(ComicInfoXML.parse(try reader.data(at: ComicInfoXML.fileName)))
    }

    /// 書き出した PDF に埋め込まれた XMP(Calibre 互換のシリーズ名・巻数)。
    /// `#require` は入れ子にできない(マクロの再帰展開になる)ので 1 つずつ解く。
    private func xmp(in url: URL) throws -> SourceBookMetadata {
        let document = try #require(CGPDFDocument(url as CFURL))
        let packet = try #require(PDFXMPMetadata.readPacket(from: document), "XMP が埋め込まれていない")
        return PDFXMPMetadata.parse(packet)
    }

    /// 書き出した EPUB の package document(OPF)の中身。
    private func opf(in url: URL) throws -> String {
        let reader = try ZipArchiveReader(url: url)
        let path = try #require(try reader.listFilePaths().first { $0.hasSuffix(".opf") })
        return String(decoding: try reader.data(at: path), as: UTF8.self)
    }

    // MARK: - どの Exporter が呼ばれるか

    @Test("形式ごとに、その拡張子で、その形式として開き直せる本が書き出される", arguments: BookExportFormat.allCases)
    func eachFormatWritesItsOwnKindOfFile(format: BookExportFormat) async throws {
        let environment = try await Environment.make(label: "kind-\(format.rawValue)")
        defer { environment.close() }

        let url = try await environment.write(environment.viewModel(for: format))
        #expect(url.pathExtension == format.fileExtension)
        // 開き直せる = その形式として妥当なファイルが書けている(どの Exporter が呼ばれたか)。
        let reopened = try await FixtureBook.load(url)
        #expect(reopened.pages.count == 4)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - オプションが出力まで届くか

    @Test("除外ページを含める指定は、どの形式でも出力のページ数に効く", arguments: BookExportFormat.allCases)
    func includingExcludedPagesReachesTheExporter(format: BookExportFormat) async throws {
        let environment = try await Environment.make(label: "excluded-\(format.rawValue)")
        defer { environment.close() }
        environment.library.layouts.setPageLayoutState(
            for: environment.book, pageKey: environment.source.key(2), state: .excluded
        )

        let withoutExcluded = try await environment.write(environment.viewModel(for: format), name: "off")
        let withoutExcludedPages = try await FixtureBook.load(withoutExcluded).pages.count
        #expect(withoutExcludedPages == 3)

        let viewModel = environment.viewModel(for: format)
        viewModel.includeExcludedPages = true
        let withExcluded = try await environment.write(viewModel, name: "on")
        let withExcludedPages = try await FixtureBook.load(withExcluded).pages.count
        #expect(withExcludedPages == 4)
    }

    @Test("Volume にも書き出す指定は、CBZ の ComicInfo.xml に届く")
    func theVolumeToggleReachesComicInfo() async throws {
        let environment = try await Environment.make(label: "volume")
        defer { environment.close() }
        environment.setSeries("シリーズ", index: "3")

        let off = try await environment.write(environment.cbz(), name: "off")
        #expect(try comicInfo(in: off).volume == nil)

        let viewModel = environment.cbz()
        viewModel.writesVolumeElement = true
        let on = try await environment.write(viewModel, name: "on")
        #expect(try comicInfo(in: on).volume == 3)
    }

    @Test("書き出しの言語は、CBZ の LanguageISO と EPUB の dc:language に同じ値で入る")
    func theExportLanguageReachesBothFormats() async throws {
        let environment = try await Environment.make(label: "language")
        defer { environment.close() }

        // 期待値は環境から取る ―― 言語はアプリの表示言語設定(「システムに従う」なら OS の
        // ロケール)から決まるので、手元と CI で違う値になる。
        let cbz = environment.cbz()
        let expected = cbz.exportLanguageCode
        #expect(try comicInfo(in: try await environment.write(cbz, name: "cbz")).languageISO == expected)

        let opfText = try opf(in: try await environment.write(environment.epub(), name: "epub"))
        #expect(opfText.contains(">\(expected)<"))
    }

    // MARK: - 巻数の書き方(CBZ だけ生のまま)

    @Test("CBZ は数値として読めない巻数もそのまま Number に書く(ComicInfo の Number は文字列)")
    func cbzWritesANonNumericSeriesIndexAsIs() async throws {
        let environment = try await Environment.make(label: "cbz-index")
        defer { environment.close() }
        environment.setSeries("シリーズ", index: "上")

        let info = try comicInfo(in: try await environment.write(environment.cbz()))
        #expect(info.series == "シリーズ")
        #expect(info.number == "上")
        // Volume は xs:int なので、書く指定でも数値でなければ入らない。
        let viewModel = environment.cbz()
        viewModel.writesVolumeElement = true
        #expect(try comicInfo(in: try await environment.write(viewModel, name: "volume")).volume == nil)
    }

    @Test("EPUB は数値として読めない巻数を書き出さない(group-position は数値必須)")
    func epubDropsANonNumericSeriesIndex() async throws {
        let environment = try await Environment.make(label: "epub-index")
        defer { environment.close() }

        environment.setSeries("シリーズ", index: "上")
        let dropped = try opf(in: try await environment.write(environment.epub(), name: "non-numeric"))
        #expect(dropped.contains("シリーズ"))
        #expect(!dropped.contains("group-position"))

        environment.setSeries("シリーズ", index: "3")
        let kept = try opf(in: try await environment.write(environment.epub(), name: "numeric"))
        #expect(kept.contains("group-position"))
    }

    @Test("PDF も数値として読めない巻数を書き出さない(Calibre は数値として読む)")
    func pdfDropsANonNumericSeriesIndex() async throws {
        let environment = try await Environment.make(label: "pdf-index")
        defer { environment.close() }

        environment.setSeries("シリーズ", index: "上")
        let dropped = try xmp(in: try await environment.write(environment.pdf(), name: "non-numeric"))
        #expect(dropped.series == "シリーズ")
        #expect(dropped.seriesIndex.isEmpty)

        environment.setSeries("シリーズ", index: "3")
        let kept = try xmp(in: try await environment.write(environment.pdf(), name: "numeric"))
        #expect(kept.seriesIndex == "3")
    }

    // MARK: - カバーの選択を持つ形式・持たない形式

    @Test("カバーの上書きは EPUB と CBZ にだけ渡り、PDF には渡らない")
    func onlyTheFormatsWithCoversReceiveTheCoverOverride() async throws {
        let environment = try await Environment.make(label: "cover")
        defer { environment.close() }
        let coverKey = environment.source.key(3)
        environment.library.layouts.setCoverPageKey(
            for: environment.book, pageKey: coverKey, displayName: "003.png"
        )

        for viewModel in [environment.cbz() as BookExportViewModel, environment.epub()] {
            #expect(viewModel.supportsCoverSelection)
            let prepared = viewModel.prepare(row: environment.row, book: environment.book, displayState: nil)
            guard case .existingPage(let pageKey) = prepared.coverOverride else {
                Issue.record("カバーの上書きが \(viewModel.format) に渡っていない")
                continue
            }
            #expect(pageKey == coverKey)
        }

        // PDF は「ページではないカバー」の仕組みを持たないため、DB に指定があっても無視する。
        let pdf = environment.pdf()
        #expect(!pdf.supportsCoverSelection)
        #expect(pdf.prepare(row: environment.row, book: environment.book, displayState: nil).coverOverride == nil)
    }

    // MARK: - 開いた直後のオプション

    @Test("連番リネームの出荷時の既定は CBZ だけ ON", arguments: BookExportFormat.allCases)
    func theRenumberDefaultIsOnForCbzOnly(format: BookExportFormat) async throws {
        let environment = try await Environment.make(pages: 1, label: "renumber-\(format.rawValue)")
        defer { environment.close() }

        #expect(environment.viewModel(for: format).renumberImagesSequentially == (format == .cbz))
    }

    @Test("Volume にも書き出すかは、環境設定の既定値から始まる(CBZ 専用)")
    func theVolumeToggleStartsFromThePreference() async throws {
        let environment = try await Environment.make(pages: 1, label: "volume-default")
        defer { environment.close() }

        #expect(!environment.cbz().writesVolumeElement)
        environment.preferences.bookExportWritesVolumeElement = true
        #expect(environment.cbz().writesVolumeElement)
    }
}

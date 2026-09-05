import Foundation
import Testing

@testable import qooViewer

/// 書き出し(CbzExporter / EpubExporter / PDFExporter)のラウンドトリップで使う、入力になる本。
///
/// 書き出しは「本を開く → 並べ替え・除外・書誌を反映して書く → 開き直す」の往復で見る。その
/// **行きの側**をここで作る ―― 番号を色に埋めたページ(`PageImageFactory`)が並んだフォルダ / zip の
/// 本を作り、`FixtureBook.load` で開く。帰りの側(開き直し)は `FixtureBook.load` /
/// `EpubStructureResolver` / `CGPDFDocument` をテスト本文から直接呼ぶ。
///
/// `temp` を持たせてあるのは `TemporaryDirectory` が手放されるとフォルダごと消えるため
/// (`EpubStructureTests.Resolved` と同じ理由)。書き出し先もこの中に取る。
///
/// `nonisolated` は付けない ―― `MangaBook` はメインアクターの型で、`@Test(arguments:)` の引数に
/// することも無いため(既定分離のまま、テスト本文と同じメインアクター上で使う)。
struct ExportSource {
    let temp: TemporaryDirectory
    let book: MangaBook

    /// 本のページ順(= 書き出し前の並び)の `PageRef.sortKey`。
    var pageKeys: [String] { book.pages.map(\.sortKey) }

    /// 1 始まりのページ番号(= 画像に埋めた番号)から `sortKey` を引く。
    func key(_ pageNumber: Int) -> String { pageKeys[pageNumber - 1] }

    func keys(_ pageNumbers: [Int]) -> [String] { pageNumbers.map(key) }

    /// 書き出し先(作業フォルダの中。まだ存在しない)。
    func destination(_ fileName: String) -> URL { temp.file(fileName) }

    /// 番号 1...count のページが `001.<ext>` … と並ぶフォルダの本。
    static func folder(
        pages count: Int, fileExtension: String = "png", label: String = "export"
    ) async throws -> ExportSource {
        let temp = try TemporaryDirectory(label)
        let root = try FixtureFolder.make(
            at: temp.file("book"),
            pages: (1...count).map {
                FixtureFolder.Page(String(format: "%03d.%@", $0, fileExtension), number: UInt8($0))
            }
        )
        return ExportSource(temp: temp, book: try await FixtureBook.load(root))
    }

    /// 名前を自分で決めるフォルダの本(NFD の名前など)。ページ番号は並べた順に 1, 2, … を振る。
    static func folder(named fileNames: [String], label: String = "export") async throws -> ExportSource {
        let temp = try TemporaryDirectory(label)
        let root = try FixtureFolder.make(
            at: temp.file("book"),
            pages: fileNames.enumerated().map { FixtureFolder.Page($1, number: UInt8($0 + 1)) }
        )
        return ExportSource(temp: temp, book: try await FixtureBook.load(root))
    }

    /// zip の本。`extraEntries` は画像以外のエントリ(元ファイルの ComicInfo.xml など)。
    static func zip(
        pages count: Int, extraEntries: [String: String] = [:], label: String = "export-zip"
    ) async throws -> ExportSource {
        let temp = try TemporaryDirectory(label)
        var builder = ZipFixtureBuilder()
        for number in 1...count {
            builder.add(String(format: "%03d.png", number), PageImageFactory.png(number: UInt8(number)))
        }
        for (path, text) in extraEntries.sorted(by: { $0.key < $1.key }) {
            builder.add(path, text: text)
        }
        let url = temp.file("book.cbz")
        try builder.write(to: url)
        return ExportSource(temp: temp, book: try await FixtureBook.load(url))
    }
}

/// 書き出しの入力を組み立てる。3 つの Exporter は受け取る材料がほぼ同じなので、テストごとに
/// 違うところ(並び順・除外・書誌)だけを引数にして、残りは既定値で埋める。
///
/// 既定値は画面から使ったときと同じ ―― 並べ替え無し・除外無し・書誌無し・右開き。
/// `ExportSource` と同じ理由で、こちらも既定分離のまま。
enum ExportInputs {
    static func cbz(
        _ source: ExportSource,
        pageOrderOverride: [String]? = nil,
        pageOverrides: [String: PageLayoutState] = [:],
        readingDirection: ReadingDirection = .rightToLeft,
        bookmarks: [ExportBookmark] = [],
        coverOverride: ExportCoverOverride? = nil,
        title: String? = nil, author: String? = nil,
        series: String? = nil, seriesIndex: String? = nil, language: String? = nil
    ) -> CbzExportInput {
        CbzExportInput(
            book: source.book, pageOrderOverride: pageOrderOverride, pageOverrides: pageOverrides,
            readingDirection: readingDirection, bookmarks: bookmarks, coverOverride: coverOverride,
            titleOverride: title, author: author, series: series, seriesIndex: seriesIndex,
            language: language
        )
    }

    static func epub(
        _ source: ExportSource,
        pageOrderOverride: [String]? = nil,
        pageOverrides: [String: PageLayoutState] = [:],
        readingDirection: ReadingDirection? = nil,
        forcedDisplayMode: DisplayMode? = nil,
        bookmarks: [ExportBookmark] = [],
        coverOverride: ExportCoverOverride? = nil,
        title: String? = nil, author: String? = nil,
        series: String? = nil, seriesIndex: String? = nil, language: String? = "ja"
    ) -> EpubExportInput {
        EpubExportInput(
            book: source.book, pageOrderOverride: pageOrderOverride, pageOverrides: pageOverrides,
            readingDirectionOverride: readingDirection, forcedDisplayMode: forcedDisplayMode,
            bookmarks: bookmarks, coverOverride: coverOverride, titleOverride: title, author: author,
            series: series, seriesIndex: seriesIndex, language: language
        )
    }

    static func pdf(
        _ source: ExportSource,
        pageOrderOverride: [String]? = nil,
        pageOverrides: [String: PageLayoutState] = [:],
        bookmarks: [ExportBookmark] = [],
        title: String? = nil, author: String? = nil,
        series: String? = nil, seriesIndex: String? = nil,
        readingDirection: ReadingDirection = .rightToLeft,
        forcedDisplayMode: DisplayMode? = nil
    ) -> PDFExportInput {
        PDFExportInput(
            book: source.book, pageOrderOverride: pageOrderOverride, pageOverrides: pageOverrides,
            bookmarks: bookmarks, titleOverride: title, author: author, series: series,
            seriesIndex: seriesIndex, readingDirection: readingDirection,
            forcedDisplayMode: forcedDisplayMode
        )
    }

    /// 既定のオプション(画面の既定値と同じ)。
    static let cbzOptions = CbzExportOptions(
        renumberImagesSequentially: true, includeExcludedPages: false, writesVolumeElement: false
    )
    static let epubOptions = EpubExportOptions(
        renumberImagesSequentially: true, includeExcludedPages: false
    )
    static let pdfOptions = PDFExportOptions(includeExcludedPages: false)
}

/// 書き出した実物を、**外部の検品ツールに渡すために**テストの添付ファイルとして残す。
///
/// CI はテストのあと、結果バンドルから添付ファイルを取り出して(`xcrun xcresulttool export
/// attachments`)、EPUB を EPUBCheck に、ComicInfo.xml を ComicInfo v2.0 の XSD にかける
/// (`scripts/ci/validate-exports.sh`)。取り出し先での名前は Xcode が付け直す(テスト名 + 連番)ので、
/// 検品する側は**拡張子だけ**を見て振り分ける。
///
/// 添付にしているのは、**サンドボックスの中でも確実に残せる唯一の手立て**だから。実測(2026-09-06):
/// - スキームの環境変数の値に `$(QOO_TEST_OUTPUT_DIR)` と書いても、ビルド設定へは展開されない
///   (テスト側には `$(QOO_TEST_OUTPUT_DIR)` という文字列がそのまま届く)。
/// - xcodebuild を起動したシェルの環境変数は、テストホストのプロセスへ**まったく引き継がれない**。
/// - 手元の TEST_HOST は署名済み = サンドボックスの中なので、コンテナの外のパスへは書けない
///   (CI は CODE_SIGNING_ALLOWED=NO で走るため書けてしまい、手元でだけ静かに失敗する形になる)。
nonisolated enum ExportArtifacts {
    /// 書き出したファイルを添付する。`name` の**拡張子**が検品の振り分けに使われる。
    static func keep(_ url: URL, as name: String) {
        guard let data = try? Data(contentsOf: url) else { return }
        keep(data, as: name)
    }

    static func keep(_ data: Data, as name: String) {
        Attachment.record(data, named: name)
    }
}

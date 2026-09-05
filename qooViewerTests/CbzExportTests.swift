import Foundation
import Testing

@testable import qooViewer

/// CBZ 書き出し(`CbzExporter`)のラウンドトリップ。書き出した cbz を `FixtureBook.load` で開き直し、
/// **ページの中身の番号**(`PageImageFactory` が色に埋めた R)で「どのページがどこへ行ったか」を追う。
///
/// CBZ には読み順を表すメタデータが無く、どのリーダーもアーカイブ内のファイル名順で読む。
/// 連番リネーム(既定 ON)が並べ替え・除外を出力へ焼き付ける唯一の手立てなので、そこを固定する。
struct CbzExportTests {

    /// 書き出した cbz を開き直して、ページ順に「中身の番号」を読む。
    private func exportedPageNumbers(_ url: URL) async throws -> [Int] {
        let book = try await FixtureBook.load(url)
        let reader = try ZipArchiveReader(url: url)
        return try book.pages.map { page in
            guard case .archive(_, let entryPath) = page.source else {
                throw ArchiveReaderError.cannotOpen
            }
            return PageColorReader.number(in: try reader.data(at: entryPath)) ?? -1
        }
    }

    private func comicInfo(in url: URL) throws -> ComicInfo {
        let reader = try ZipArchiveReader(url: url)
        let data = try reader.data(at: ComicInfoXML.fileName)
        ExportArtifacts.keep(data, as: "\(url.deletingPathExtension().lastPathComponent).xml")
        return try #require(ComicInfoXML.parse(data))
    }

    // MARK: - 並び順

    @Test("連番リネームは、並べ替えと除外をファイル名の順序として焼き付ける")
    func renumberedOrderSurvivesRoundTrip() async throws {
        let source = try await ExportSource.folder(pages: 5, label: "cbz-order")
        let destination = source.destination("order.cbz")
        try await CbzExporter.export(
            ExportInputs.cbz(
                source,
                pageOrderOverride: source.pageKeys.reversed(),
                pageOverrides: [source.key(3): .excluded]
            ),
            options: ExportInputs.cbzOptions, to: destination
        )

        let book = try await FixtureBook.load(destination)
        #expect(book.pages.map(\.sortKey) == ["0.png", "1.png", "2.png", "3.png"])
        // 逆順に並べ替えて 3 ページ目を除外 → 5, 4, 2, 1。
        #expect(try await exportedPageNumbers(destination) == [5, 4, 2, 1])
    }

    /// 連番リネームを切ると元の名前が残るぶん、**書き出した順は読み手には伝わらない**
    /// (既定を ON にしている理由。CbzExportOptions のコメント)。この性質自体を固定しておく。
    @Test("連番リネームを切ると元の名前が残り、開き直すと名前順に戻る")
    func originalNamesLoseTheReorder() async throws {
        let source = try await ExportSource.folder(pages: 3, label: "cbz-names")
        let destination = source.destination("names.cbz")
        try await CbzExporter.export(
            ExportInputs.cbz(source, pageOrderOverride: source.pageKeys.reversed()),
            options: CbzExportOptions(
                renumberImagesSequentially: false, includeExcludedPages: false, writesVolumeElement: false
            ),
            to: destination
        )

        let book = try await FixtureBook.load(destination)
        #expect(book.pages.map(\.sortKey) == ["001.png", "002.png", "003.png"])
        #expect(try await exportedPageNumbers(destination) == [1, 2, 3])
    }

    @Test("除外ページを含める指定なら、除外したページも書き出す")
    func includesExcludedPagesOnDemand() async throws {
        let source = try await ExportSource.folder(pages: 3, label: "cbz-excluded")
        let destination = source.destination("excluded.cbz")
        try await CbzExporter.export(
            ExportInputs.cbz(source, pageOverrides: [source.key(2): .excluded]),
            options: CbzExportOptions(
                renumberImagesSequentially: true, includeExcludedPages: true, writesVolumeElement: false
            ),
            to: destination
        )
        #expect(try await exportedPageNumbers(destination) == [1, 2, 3])
    }

    @Test("書き出せるページが 1 枚も無ければ noEligiblePages(ファイルは作らない)")
    func noEligiblePages() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "cbz-empty")
        let destination = source.destination("empty.cbz")
        let overrides = Dictionary(uniqueKeysWithValues: source.pageKeys.map { ($0, PageLayoutState.excluded) })
        await #expect(throws: CbzExportError.self) {
            try await CbzExporter.export(
                ExportInputs.cbz(source, pageOverrides: overrides),
                options: ExportInputs.cbzOptions, to: destination
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - ComicInfo.xml

    @Test("ComicInfo.xml に書誌・ページ数・読み方向・カバー・単一ページ・しおりが入る")
    func comicInfoContents() async throws {
        let source = try await ExportSource.folder(pages: 4, label: "cbz-comicinfo")
        let destination = source.destination("comicinfo.cbz")
        try await CbzExporter.export(
            ExportInputs.cbz(
                source,
                pageOverrides: [source.key(2): .single],
                readingDirection: .rightToLeft,
                bookmarks: [ExportBookmark(pageKey: source.key(3), name: "第2章")],
                title: "テスト本", author: "作者", series: "テストシリーズ", seriesIndex: "3",
                language: "ja"
            ),
            options: ExportInputs.cbzOptions, to: destination
        )

        let info = try comicInfo(in: destination)
        #expect(info.title == "テスト本")
        #expect(info.series == "テストシリーズ")
        #expect(info.number == "3")
        #expect(info.volume == nil)  // Volume は既定で書かない(Komga がシリーズを分裂させるため)
        #expect(info.writer == "作者")
        #expect(info.penciller == "作者")
        #expect(info.languageISO == "ja")
        #expect(info.pageCount == 4)
        #expect(info.manga == .yesAndRightToLeft)

        #expect(info.pages.map(\.image) == [0, 1, 2, 3])
        #expect(info.pages.map(\.type) == [.frontCover, nil, nil, nil])
        // 「単一ページ」= 1 枚に見開き 2 ページ分、が ComicInfo の DoublePage(ComicInfoPage のコメント)。
        #expect(info.pages.map(\.doublePage) == [nil, true, nil, nil])
        #expect(info.pages.map(\.bookmark) == [nil, nil, "第2章", nil])
        // 実寸は PageImageFactory の 8x12 px。バイト数は実際に書いたぶん。
        #expect(info.pages.allSatisfy { $0.imageWidth == 8 && $0.imageHeight == 12 })
        #expect(info.pages.allSatisfy { ($0.imageSize ?? 0) > 0 })
    }

    @Test("左開きなら Manga は Yes(方向の指定は持たない)")
    func comicInfoLeftToRight() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "cbz-ltr")
        let destination = source.destination("ltr.cbz")
        try await CbzExporter.export(
            ExportInputs.cbz(source, readingDirection: .leftToRight),
            options: ExportInputs.cbzOptions, to: destination
        )
        #expect(try comicInfo(in: destination).manga == .yes)
    }

    /// `Page@Image` は「書き込んだ順」ではなく「アーカイブ内の画像を名前順に並べたときの位置」
    /// (CbzExporter の readerOrder のコメント)。連番リネームを切ったときだけ両者がずれる。
    @Test("Page@Image は書き込み順ではなく名前順の位置を指す")
    func comicInfoPageIndicesFollowNameOrder() async throws {
        let source = try await ExportSource.folder(pages: 3, label: "cbz-index")
        let destination = source.destination("index.cbz")
        try await CbzExporter.export(
            ExportInputs.cbz(
                source,
                pageOrderOverride: source.pageKeys.reversed(),
                bookmarks: [ExportBookmark(pageKey: source.key(3), name: "最初のページ")]
            ),
            options: CbzExportOptions(
                renumberImagesSequentially: false, includeExcludedPages: false, writesVolumeElement: false
            ),
            to: destination
        )

        let info = try comicInfo(in: destination)
        // 書き込み順は 003, 002, 001。名前順では 001=0, 002=1, 003=2 なので、読書順の先頭
        // (= 003.png)に付くカバーとしおりは、どちらも 2 番へ載る。
        #expect(info.pages.map(\.image) == [0, 1, 2])
        #expect(info.pages.first(where: { $0.type == .frontCover })?.image == 2)
        #expect(info.pages.first(where: { $0.bookmark != nil })?.image == 2)
    }

    @Test("Volume を書く指定のときだけ、整数の巻数が Volume にも入る")
    func volumeElement() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "cbz-volume")
        let options = CbzExportOptions(
            renumberImagesSequentially: true, includeExcludedPages: false, writesVolumeElement: true
        )
        let numeric = source.destination("volume.cbz")
        try await CbzExporter.export(
            ExportInputs.cbz(source, series: "シリーズ", seriesIndex: "3"), options: options, to: numeric
        )
        #expect(try comicInfo(in: numeric).volume == 3)

        // Number は xs:string なので「上」も書けるが、Volume は xs:int で書けない。
        let textual = source.destination("volume-text.cbz")
        try await CbzExporter.export(
            ExportInputs.cbz(source, series: "シリーズ", seriesIndex: "上"), options: options, to: textual
        )
        let info = try comicInfo(in: textual)
        #expect(info.number == "上")
        #expect(info.volume == nil)
    }

    @Test("元ファイルの ComicInfo.xml は引き継ぐ(qooViewer が管理しない項目を失わない)")
    func inheritsSourceComicInfo() async throws {
        var original = ComicInfo()
        original.publisher = "出版社"
        original.summary = "あらすじ"
        original.year = 2020
        let source = try await ExportSource.zip(
            pages: 2, extraEntries: [ComicInfoXML.fileName: ComicInfoXML.makeDocument(original)],
            label: "cbz-inherit"
        )
        let destination = source.destination("inherited.cbz")
        try await CbzExporter.export(
            ExportInputs.cbz(source, title: "新しいタイトル"), options: ExportInputs.cbzOptions,
            to: destination
        )

        let info = try comicInfo(in: destination)
        #expect(info.publisher == "出版社")
        #expect(info.summary == "あらすじ")
        #expect(info.year == 2020)
        #expect(info.title == "新しいタイトル")
        #expect(info.pageCount == 2)
    }

    // MARK: - 文字の正規化

    /// ユーザー報告(2026-09-03): フォルダの本の NFD な名前がそのまま zip のエントリ名になり、
    /// Windows で濁点が分離して見えた。書き出しの出口で NFC へ揃える(nfcNormalizedForExport)。
    @Test("NFD のファイル名・書誌は NFC に揃えて書き出す")
    func normalizesToNFC() async throws {
        let decomposed = "\u{304B}\u{3099}.png"  // 「か」+ 結合濁点
        let source = try await ExportSource.folder(named: [decomposed], label: "cbz-nfc")
        #expect(source.book.pages.first?.displayName.unicodeScalars.count == decomposed.unicodeScalars.count, "元は NFD のまま")

        let destination = source.destination("nfc.cbz")
        try await CbzExporter.export(
            ExportInputs.cbz(source, title: "\u{304B}\u{3099}", series: "\u{304B}\u{3099}"),
            options: CbzExportOptions(
                renumberImagesSequentially: false, includeExcludedPages: false, writesVolumeElement: false
            ),
            to: destination
        )

        let entryPath = try #require(
            try ZipArchiveReader(url: destination).listFilePaths().first { isImageFile($0) }
        )
        #expect(entryPath == "\u{304C}.png")
        #expect(entryPath.unicodeScalars.count == decomposed.unicodeScalars.count - 1, "NFC へ揃っている")
        let info = try comicInfo(in: destination)
        #expect(info.title.unicodeScalars.count == 1)
        #expect(info.series.unicodeScalars.count == 1)
    }

    // MARK: - カバー

    @Test("本に含まれない専用ファイルをカバーにすると、先頭に 1 ページ増える")
    func standaloneCover() async throws {
        let source = try await ExportSource.folder(pages: 2, label: "cbz-cover")
        let destination = source.destination("cover.cbz")
        try await CbzExporter.export(
            ExportInputs.cbz(
                source, coverOverride: .externalFile(data: PageImageFactory.png(number: 99), fileExtension: "png")
            ),
            options: ExportInputs.cbzOptions, to: destination
        )

        #expect(try await exportedPageNumbers(destination) == [99, 1, 2])
        let info = try comicInfo(in: destination)
        #expect(info.pageCount == 3)
        #expect(info.pages.first(where: { $0.type == .frontCover })?.image == 0)
    }
}

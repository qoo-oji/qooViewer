import Foundation
import Testing

@testable import qooViewer

/// テストの中で作る本(フォルダ・zip・EPUB・PDF)を BookLoader で開く。
///
/// コミット済みのフィクスチャ(FixtureBookTests)が「実物のツールが作った書庫」を押さえるのに対し、
/// こちらは名前や構造を自由に組める側。Support/ のビルダーがちゃんと本になることの確認でもあり、
/// 段階 1 以降の EPUB / PDF / 書き出しのテストはこのビルダーの上に書く。
struct GeneratedFixtureTests {
    // MARK: - フォルダの本

    @Test("フォルダの本: 隠しファイルと画像以外を除き、フォルダごとに正準順で並ぶ")
    func folderBook() async throws {
        let temp = try TemporaryDirectory("folder")
        let root = try FixtureFolder.make(
            at: temp.file("book"),
            pages: [
                .init("010.png", number: 10),
                .init("2.jpg", number: 2),
                .init("vol1/002.png", number: 4),
                .init("vol1/001.png", number: 3),
                .init(".hidden.png", number: 5),
                .init("._001.png", number: 6),
            ],
            extraFiles: ["notes.txt": "not a page", "vol1/.DS_Store": ""]
        )
        let book = try await FixtureBook.load(root)

        // フォルダの本の sortKey は絶対パス(docs/04)。数字は数値として比べ、フォルダごとにまとまる。
        #expect(book.pages.map(\.sortKey) == [
            root.appendingPathComponent("2.jpg").path,
            root.appendingPathComponent("010.png").path,
            root.appendingPathComponent("vol1/001.png").path,
            root.appendingPathComponent("vol1/002.png").path,
        ])
        #expect(book.pages.map(\.id) == book.pages.map(\.sortKey))
        #expect(book.pages.map(\.displayName) == ["2.jpg", "010.png", "001.png", "002.png"])
        #expect(book.pages.map { $0.location(inBookAt: root).folderPath } == [nil, nil, "vol1", "vol1"])
        #expect(book.pageOrderSource == .fileName)
        #expect(book.sourceLayoutHint == nil)
        #expect(book.title == "book")
    }

    @Test("フォルダの本: 1.37 の報告と同じ命名は正準順(Finder と同じ)で保存される")
    func folderBookMixedCase() async throws {
        let temp = try TemporaryDirectory("mixed-case")
        let root = try FixtureFolder.make(
            at: temp.file("book"),
            pages: [
                .init("Page_0001.png", number: 2),
                .init("page-0002.png", number: 3),
                .init("_Cover.PNG", number: 1),
            ]
        )
        let book = try await FixtureBook.load(root)
        #expect(book.pages.map(\.displayName) == ["_Cover.PNG", "Page_0001.png", "page-0002.png"])
        #expect(PageOrder.differsByOrderSetting(keys: book.pages.map(\.sortKey)))
    }

    @Test("フォルダの本: NFD の名前はそのまま持つ(正規化しない)")
    func folderBookKeepsDecomposedNames() async throws {
        let temp = try TemporaryDirectory("nfd")
        // 「が」を か + 結合濁点(U+3099)で。APFS は正規化を保存するので、そのまま返ってくる。
        let decomposed = "\u{304B}\u{3099}.png"
        let root = try FixtureFolder.make(at: temp.file("book"), pages: [.init(decomposed, number: 1)])
        let book = try await FixtureBook.load(root)
        let name = try #require(book.pages.first?.displayName)
        #expect(name == decomposed)  // String の == は正準等価
        #expect(name.unicodeScalars.count == decomposed.unicodeScalars.count, "NFC に寄せられている")
    }

    // MARK: - zip

    @Test("zip: ディレクトリエントリと __MACOSX を数えず、無圧縮と deflate が混ざっていても読める")
    func zipBook() async throws {
        let temp = try TemporaryDirectory("zip")
        var zip = ZipFixtureBuilder()
        zip.addDirectory("vol")
        zip.add("vol/002.png", PageImageFactory.png(number: 2))
        zip.add("vol/001.png", PageImageFactory.png(number: 1))
        zip.addDirectory("__MACOSX/vol")
        zip.add("__MACOSX/vol/._001.png", Data([0, 5, 22, 7, 0, 2, 0, 0]))
        zip.add("cover.jpg", PageImageFactory.jpeg(number: 3), stored: true)
        zip.add("readme.txt", text: "not a page")
        let url = temp.file("book.cbz")
        try zip.write(to: url)

        let book = try await FixtureBook.load(url)
        #expect(book.pages.map(\.sortKey) == ["cover.jpg", "vol/001.png", "vol/002.png"])
        #expect(book.pages.map(\.id) == ["\(url.path)#cover.jpg", "\(url.path)#vol/001.png", "\(url.path)#vol/002.png"])
        #expect(book.pages.map { $0.location(inBookAt: url).folderPath } == [nil, "vol", "vol"])
        #expect(book.title == "book")
    }

    // MARK: - EPUB

    @Test("EPUB: 並びは spine の順、見開き指定と読み方向は sourceLayoutHint と epubSpreadPosition に入る")
    func epubBook() async throws {
        let temp = try TemporaryDirectory("epub")
        var builder = EpubFixtureBuilder.pages(4)
        builder.pages[0].spineProperties = "rendition:page-spread-center"
        builder.pages[1].spineProperties = "page-spread-left"
        builder.pages[2].spineProperties = "page-spread-right"
        builder.pages[3].wide = true
        builder.pageProgressionDirection = "rtl"
        builder.renditionSpread = "none"
        builder.manifestReversed = true
        let url = temp.file("book.epub")
        try builder.write(to: url)

        let book = try await FixtureBook.load(url)
        #expect(book.pages.map(\.sortKey) == ["000000", "000001", "000002", "000003"])
        #expect(book.pages.map(\.id) == builder.expectedEntryPaths.map { "\(url.path)#\($0)" })
        #expect(book.pages.map(\.epubSpreadPosition) == [.center, .left, .right, nil])
        #expect(book.pageOrderSource == .document)
        #expect(book.sourceLayoutHint == SourceLayoutHint(pageProgressionDirection: .rightToLeft, forcedDisplayMode: .single))
        // EPUB は中のフォルダを出さない(PageLocation の型コメント)
        #expect(book.pages.map { $0.location(inBookAt: url).folderPath } == [nil, nil, nil, nil])
    }

    @Test("EPUB: 画像そのものを指す spine、svg の画像、画像の無い項目")
    func epubBookVariants() async throws {
        let temp = try TemporaryDirectory("epub-variants")
        var builder = EpubFixtureBuilder.pages(4)
        builder.pages[0].imageInSpine = true
        builder.pages[1].svg = true
        builder.pages[2].imageMissing = true
        builder.namespacePrefixed = true
        let url = temp.file("book.epub")
        try builder.write(to: url)

        let book = try await FixtureBook.load(url)
        #expect(book.pages.count == 3)
        #expect(book.pages.map(\.id) == builder.expectedEntryPaths.map { "\(url.path)#\($0)" })
        #expect(book.sourceLayoutHint == SourceLayoutHint(pageProgressionDirection: nil, forcedDisplayMode: nil))
    }

    @Test("EPUB: container.xml が無ければ開けない")
    func epubWithoutContainer() async throws {
        let temp = try TemporaryDirectory("epub-broken")
        var builder = EpubFixtureBuilder.pages(2)
        builder.omitContainer = true
        let url = temp.file("book.epub")
        try builder.write(to: url)
        await #expect(throws: BookLoaderError.self) {
            _ = try await FixtureBook.load(url)
        }
    }

    // MARK: - PDF

    @Test("PDF: ページ数ぶんの連番になり、Catalog に指定が無ければ sourceLayoutHint は nil")
    func pdfBook() async throws {
        let temp = try TemporaryDirectory("pdf")
        let url = temp.file("book.pdf")
        try PDFFixtureBuilder.write(to: url, pageNumbers: [1, 2, 3], title: "テスト本", author: "作者")

        let book = try await FixtureBook.load(url)
        #expect(book.pages.map(\.sortKey) == ["000000", "000001", "000002"])
        #expect(book.pages.map(\.id) == ["\(url.path)#pdf#0", "\(url.path)#pdf#1", "\(url.path)#pdf#2"])
        #expect(book.pages.map(\.displayName) == ["book (1)", "book (2)", "book (3)"])
        #expect(book.pageOrderSource == .document)
        #expect(book.sourceLayoutHint == nil)
    }

    // MARK: - ページ画像

    @Test("PageImageFactory の番号は PageColorReader で読み戻せる(PNG は厳密、JPEG は近似)")
    func pageImageRoundTrip() {
        #expect(PageColorReader.number(in: PageImageFactory.png(number: 7)) == 7)
        #expect(PageColorReader.number(in: PageImageFactory.png(number: 200, wide: true)) == 200)
        #expect(PageColorReader.matches(PageImageFactory.jpeg(number: 42), number: 42))
    }
}

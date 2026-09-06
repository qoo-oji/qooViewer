import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// フォルダ/書庫の中に置かれた PDF・EPUB を、1 冊の本のページへ統合する経路
/// (ユーザー報告 2026-09-06: PDF と EPUB の入ったフォルダをドロップしても中身を認識しない。
/// zip/rar/7z はまとめて 1 冊になるのに、という指摘。docs/04 の「フォルダの中の PDF・EPUB」)。
///
/// ここで押さえるのは 3 つ:
/// - ページが「そのファイルが置かれていた位置」へ、ファイル自身が決めた順で差し込まれること
/// - `sortKey`(= DB のページキー)が書庫と同じ組み立て方(接頭辞 + ゼロ埋めの連番)になること
/// - そのページを実際に読み出せること(書庫の中の PDF はバイト列から開く)
struct EmbeddedDocumentBookTests {

    /// 画像 1 枚・2 ページの PDF・2 ページの EPUB が並んだフォルダ。
    /// `temporary` を持ち続けるのは、これが消えるとフォルダごと消えるため(PageLoaderTests と同じ)。
    private struct Folder {
        let temporary: TemporaryDirectory
        let root: URL
        var pdf: URL { root.appendingPathComponent("002.pdf") }
        var epub: URL { root.appendingPathComponent("003.epub") }
    }

    private func makeFolder(_ label: String) throws -> Folder {
        let temporary = try TemporaryDirectory(label)
        let root = try FixtureFolder.make(
            at: temporary.file("book"), pages: [.init("001.png", number: 1)]
        )
        try PDFFixtureBuilder.write(to: root.appendingPathComponent("002.pdf"), pageNumbers: [2, 3])
        try EpubFixtureBuilder.pages(2).write(to: root.appendingPathComponent("003.epub"))
        return Folder(temporary: temporary, root: root)
    }

    // MARK: - フォルダの本

    @Test("フォルダの中の PDF・EPUB は、置かれていた位置へ中身が展開されて 1 冊になる")
    func aFolderMergesPDFsAndEpubs() async throws {
        let folder = try makeFolder("folder-documents")
        let (root, pdf, epub) = (folder.root, folder.pdf, folder.epub)
        let book = try await FixtureBook.load(root)

        // 画像 1 枚 + PDF 2 ページ + EPUB 2 ページ。sortKey は書庫と同じ「接頭辞 + / + 連番」。
        #expect(book.pages.map(\.sortKey) == [
            root.appendingPathComponent("001.png").path,
            "\(pdf.path)/000000",
            "\(pdf.path)/000001",
            "\(epub.path)/000000",
            "\(epub.path)/000001",
        ])
        // id は、その PDF / EPUB を単体で開いたときと同じ形。
        #expect(book.pages.map(\.id) == [
            root.appendingPathComponent("001.png").path,
            "\(pdf.path)#pdf#0",
            "\(pdf.path)#pdf#1",
            "\(epub.path)#OEBPS/Images/p001.png",
            "\(epub.path)#OEBPS/Images/p002.png",
        ])
        #expect(book.pages.map(\.displayName) == ["001.png", "002 (1)", "002 (2)", "p001.png", "p002.png"])
        // 本そのものはフォルダなので、並び順の由来は従来どおりファイル名。
        #expect(book.pageOrderSource == .fileName)
        #expect(book.sourceLayoutHint == nil)

        // ページの出所。EPUB は zip コンテナなので書庫のエントリとして表せる。
        guard case .pdf(let container, let pageIndex) = book.pages[2].source else {
            Issue.record("PDF のページになっていない: \(book.pages[2].source)")
            return
        }
        #expect(container == .file(pdf))
        #expect(pageIndex == 1)
        guard case .archive(let locator, let entryPath) = book.pages[3].source else {
            Issue.record("書庫のエントリになっていない: \(book.pages[3].source)")
            return
        }
        #expect(locator == ArchiveLocator(rootURL: epub))
        #expect(entryPath == "OEBPS/Images/p001.png")

        // 「本の中のどこか」は、そのファイルまでの道順。EPUB の中のフォルダは畳んで捨てる。
        #expect(book.pages.map { $0.location(inBookAt: root).folderPath }
            == [nil, "002.pdf", "002.pdf", "003.epub", "003.epub"])
    }

    @Test("PDF と EPUB しか入っていないフォルダも開ける(以前はページ 0 で開けなかった)")
    func aFolderOfOnlyDocumentsOpens() async throws {
        let temp = try TemporaryDirectory("folder-only-documents")
        let root = temp.file("book")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PDFFixtureBuilder.write(to: root.appendingPathComponent("vol1.pdf"), pageNumbers: [1, 2])
        try EpubFixtureBuilder.pages(1).write(to: root.appendingPathComponent("vol2.epub"))

        let book = try await FixtureBook.load(root)
        #expect(book.pages.count == 3)
        #expect(book.title == "book")
    }

    @Test("リフロー型など、ページを取り出せない EPUB はその 1 冊ぶんが抜けるだけ")
    func aBrokenEpubIsSkipped() async throws {
        let temp = try TemporaryDirectory("folder-broken-epub")
        let root = try FixtureFolder.make(at: temp.file("book"), pages: [.init("001.png", number: 1)])
        var builder = EpubFixtureBuilder.pages(2)
        builder.omitContainer = true
        try builder.write(to: root.appendingPathComponent("broken.epub"))

        let book = try await FixtureBook.load(root)
        #expect(book.pages.map(\.displayName) == ["001.png"])
    }

    // MARK: - 書庫の本

    @Test("書庫の中の PDF・EPUB も同じ組み立て方で統合する")
    func anArchiveMergesPDFsAndEpubs() async throws {
        let temp = try TemporaryDirectory("archive-documents")
        let pdf = temp.file("inner.pdf")
        let epub = temp.file("inner.epub")
        try PDFFixtureBuilder.write(to: pdf, pageNumbers: [2, 3])
        try EpubFixtureBuilder.pages(2).write(to: epub)

        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: 1))
        builder.add("chapters/002.pdf", try Data(contentsOf: pdf))
        builder.add("chapters/003.epub", try Data(contentsOf: epub))
        let url = temp.file("book.cbz")
        try builder.write(to: url)

        let book = try await FixtureBook.load(url)
        // 本そのものの書庫が起点なので、接頭辞はエントリパスそのもの(sortKeyPrefix: nil)。
        #expect(book.pages.map(\.sortKey) == [
            "001.png",
            "chapters/002.pdf/000000",
            "chapters/002.pdf/000001",
            "chapters/003.epub/000000",
            "chapters/003.epub/000001",
        ])
        #expect(book.pages.map(\.id) == [
            "\(url.path)#001.png",
            "\(url.path)#chapters/002.pdf#pdf#0",
            "\(url.path)#chapters/002.pdf#pdf#1",
            "\(url.path)#chapters/003.epub#OEBPS/Images/p001.png",
            "\(url.path)#chapters/003.epub#OEBPS/Images/p002.png",
        ])
        // EPUB のページは、その EPUB を指す 1 段深い locator になる(入れ子の書庫と同じ)。
        guard case .archive(let locator, _) = book.pages[3].source else {
            Issue.record("書庫のエントリになっていない: \(book.pages[3].source)")
            return
        }
        #expect(locator == ArchiveLocator(rootURL: url, nestedPath: ["chapters/003.epub"]))
        // PDF は「その PDF を含んでいる書庫 + 書庫の中のパス」。
        guard case .pdf(let container, _) = book.pages[1].source else {
            Issue.record("PDF のページになっていない: \(book.pages[1].source)")
            return
        }
        #expect(container == .entry(locator: ArchiveLocator(rootURL: url), entryPath: "chapters/002.pdf"))
        #expect(container.revealURL == url)

        #expect(book.pages.map { $0.location(inBookAt: url).folderPath }
            == [nil, "chapters/002.pdf", "chapters/002.pdf", "chapters/003.epub", "chapters/003.epub"])
    }

    // MARK: - 読み出し

    @Test("書庫の中の PDF のページも、書庫の外の PDF と同じように読み出せる")
    func pagesInsideAnArchivedPDFCanBeRead() async throws {
        let temp = try TemporaryDirectory("archived-pdf-pages")
        let pdf = temp.file("inner.pdf")
        try PDFFixtureBuilder.write(to: pdf, pageNumbers: [4, 5, 6])
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: 1))
        builder.add("chapter.pdf", try Data(contentsOf: pdf))
        let url = temp.file("book.cbz")
        try builder.write(to: url)

        let book = try await FixtureBook.load(url)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        defer { Task { await loader.releaseAllResources() } }

        for (index, expected) in [1, 4, 5, 6].enumerated() {
            let image = try #require(await loader.pageImage(at: index), "ページ \(index) が読めない")
            // PDF へ貼ってあるのは JPEG なので、読み戻した番号は誤差を許して比べる。
            let read = try #require(PageColorReader.number(in: image))
            #expect(abs(read - expected) <= 2)
        }
        // 寸法は PDF のページ枠から取れる(PDF 全体を描かずに答える経路)。
        let size = try #require(await loader.pageSize(at: 1))
        #expect(size.width == Int(PDFFixtureBuilder.pageSize.width))
        #expect(size.height == Int(PDFFixtureBuilder.pageSize.height))
    }

    // MARK: - サイドパネル下段(本の中身ブラウザ)

    @MainActor
    @Test("本の中身ブラウザ: PDF・EPUB は踏み込めるコンテナで、中の行は本のページと一致する")
    func theContentsBrowserWalksIntoDocuments() async throws {
        let folder = try makeFolder("browser-documents")
        let book = try await FixtureBook.load(folder.root)
        let state = try #require(BookContentsBrowserState(book: book))
        defer { state.releaseResources() }
        state.pageOrder = Dictionary(
            uniqueKeysWithValues: book.pages.enumerated().map { ($0.element.sortKey, $0.offset) }
        )

        #expect(state.entries.map(\.displayName) == ["001.png", "002.pdf", "003.epub"])
        for entry in state.entries.dropFirst() {
            #expect(entry.isContainer)
            guard case .documentFileOnDisk = try #require(entry.navigateTarget) else {
                Issue.record("PDF/EPUB として踏み込めない: \(entry.displayName)")
                continue
            }
        }

        // PDF へ踏み込むと、その PDF のページだけが並ぶ。行の matchKey は本のページの sortKey。
        state.navigate(state.entries[1])
        #expect(state.currentLocationName == "002.pdf")
        #expect(state.entries.map(\.displayName) == ["002 (1)", "002 (2)"])
        #expect(state.entries.map(\.matchKey) == book.pages[1...2].map(\.sortKey))
        #expect(state.entries.allSatisfy { $0.isImage && $0.navigateTarget == nil })
        if case .jumpToPage(let index) = state.resolveImageClick(on: state.entries[0], bookPages: book.pages) {
            #expect(index == 1)
        } else {
            Issue.record("PDF のページ行から本のページへ飛べない")
        }

        // EPUB も同じ(行の名前は EPUB の中の画像のファイル名)。
        state.goBack()
        state.navigate(state.entries[2])
        #expect(state.currentLocationName == "003.epub")
        #expect(state.entries.map(\.matchKey) == book.pages[3...4].map(\.sortKey))
        #expect(state.entries.map(\.displayName) == book.pages[3...4].map(\.displayName))
    }
}

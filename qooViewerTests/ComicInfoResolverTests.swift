import Foundation
import Testing

@testable import qooViewer

/// 本の中から `ComicInfo.xml` を探す側(Services/ComicInfoResolver.swift)。
///
/// 「どれを選ぶか」が全部で、内容の解釈は `ComicInfoXMLTests` が見る。ルート直下を優先するのは
/// Komga / Kavita がそこしか見ないため、それでも無ければサブフォルダへ降りるのは、書庫全体を
/// もう1階層フォルダで包んでいる本から読み取りのときだけ拾うため。
struct ComicInfoResolverTests {
    private func document(title: String) -> String {
        var info = ComicInfo()
        info.title = title
        return ComicInfoXML.makeDocument(info)
    }

    // MARK: - フォルダの本

    @Test("フォルダ直下の ComicInfo.xml を読む")
    func findsComicInfoInAFolder() throws {
        let workspace = try TemporaryDirectory("comicinfo-folder")
        let book = try FixtureFolder.make(
            at: workspace.file("book"), pages: [.init("001.jpg", number: 1)],
            extraFiles: [ComicInfoXML.fileName: document(title: "フォルダの本")]
        )
        #expect(ComicInfoResolver.resolve(bookAt: book)?.title == "フォルダの本")
    }

    @Test("ファイル名の大文字小文字は問わない")
    func fileNameIsMatchedCaseInsensitively() throws {
        let workspace = try TemporaryDirectory("comicinfo-case")
        let book = try FixtureFolder.make(
            at: workspace.file("book"), pages: [.init("001.jpg", number: 1)],
            extraFiles: ["comicinfo.XML": document(title: "小文字")]
        )
        #expect(ComicInfoResolver.resolve(bookAt: book)?.title == "小文字")
    }

    @Test("ComicInfo.xml が無ければ nil")
    func missingComicInfoGivesNil() throws {
        let workspace = try TemporaryDirectory("comicinfo-none")
        let book = try FixtureFolder.make(at: workspace.file("book"), pages: [.init("001.jpg", number: 1)])
        #expect(ComicInfoResolver.resolve(bookAt: book) == nil)
    }

    @Test("フォルダのサブフォルダにあるものは拾わない")
    func aNestedFileInAFolderBookIsNotUsed() throws {
        let workspace = try TemporaryDirectory("comicinfo-nested-folder")
        let book = try FixtureFolder.make(
            at: workspace.file("book"), pages: [.init("ch01/001.jpg", number: 1)],
            extraFiles: ["ch01/\(ComicInfoXML.fileName)": document(title: "中の章")]
        )
        #expect(ComicInfoResolver.resolve(bookAt: book) == nil)
    }

    @Test("壊れた ComicInfo.xml は「無い」のと同じ")
    func aBrokenFileIsTreatedAsMissing() throws {
        let workspace = try TemporaryDirectory("comicinfo-broken")
        let book = try FixtureFolder.make(
            at: workspace.file("book"), pages: [.init("001.jpg", number: 1)],
            extraFiles: [ComicInfoXML.fileName: "<ComicInfo><Title>途中で終わ"]
        )
        #expect(ComicInfoResolver.resolve(bookAt: book) == nil)
    }

    // MARK: - 書庫

    @Test("書庫のルート直下を優先する")
    func theRootEntryWinsInAnArchive() throws {
        let workspace = try TemporaryDirectory("comicinfo-zip")
        var builder = ZipFixtureBuilder()
        builder.add("wrapper/\(ComicInfoXML.fileName)", text: document(title: "中"))
        builder.add(ComicInfoXML.fileName, text: document(title: "ルート"))
        builder.add("001.jpg", PageImageFactory.data(number: 1, fileExtension: "jpg"))
        let url = workspace.file("book.cbz")
        try builder.write(to: url)

        #expect(ComicInfoResolver.resolve(bookAt: url)?.title == "ルート")
    }

    @Test("ルート直下に無ければ、サブフォルダのものを拾う")
    func aNestedEntryIsUsedWhenTheRootHasNone() throws {
        let workspace = try TemporaryDirectory("comicinfo-zip-nested")
        var builder = ZipFixtureBuilder()
        builder.add("wrapper/\(ComicInfoXML.fileName)", text: document(title: "包まれた本"))
        builder.add("wrapper/001.jpg", PageImageFactory.data(number: 1, fileExtension: "jpg"))
        let url = workspace.file("book.cbz")
        try builder.write(to: url)

        #expect(ComicInfoResolver.resolve(bookAt: url)?.title == "包まれた本")
    }

    @Test("既に開いてある reader からも同じ結果になる")
    func theReaderOverloadAgrees() throws {
        let workspace = try TemporaryDirectory("comicinfo-reader")
        var builder = ZipFixtureBuilder()
        builder.add(ComicInfoXML.fileName, text: document(title: "同じ本"))
        builder.add("001.jpg", PageImageFactory.data(number: 1, fileExtension: "jpg"))
        let url = workspace.file("book.cbz")
        try builder.write(to: url)

        let reader = try makeArchiveReader(for: url)
        #expect(ComicInfoResolver.resolve(reader: reader)?.title == "同じ本")
        #expect(ComicInfoResolver.resolve(bookAt: url)?.title == "同じ本")
    }

    // MARK: - 無いのか、読めなかったのか(2026-09-26)

    @Test("無い・読めなかった・見つかったを分けて答える(フォルダ)")
    func lookupSeparatesAbsentFromUnreadableInAFolder() throws {
        let workspace = try TemporaryDirectory("comicinfo-lookup-folder")
        let none = try FixtureFolder.make(at: workspace.file("none"), pages: [.init("001.jpg", number: 1)])
        #expect(ComicInfoResolver.lookup(bookAt: none) == .absent)
        let broken = try FixtureFolder.make(
            at: workspace.file("broken"), pages: [.init("001.jpg", number: 1)],
            extraFiles: [ComicInfoXML.fileName: "<ComicInfo><Title>途中で終わ"]
        )
        #expect(ComicInfoResolver.lookup(bookAt: broken) == .absent)
        let found = try FixtureFolder.make(
            at: workspace.file("found"), pages: [.init("001.jpg", number: 1)],
            extraFiles: [ComicInfoXML.fileName: document(title: "ある本")]
        )
        #expect(ComicInfoResolver.lookup(bookAt: found).comicInfo?.title == "ある本")
        // 繋がっていない・消えた場所は「無い」ではない(覚えると、繋ぎ直しても取り込まれなくなる)。
        #expect(ComicInfoResolver.lookup(bookAt: workspace.file("ghost")) == .unreadable)
    }

    @Test("書庫の一覧や中身を読めなかったら「読めなかった」")
    func lookupReportsAnUnreadableArchive() {
        #expect(ComicInfoResolver.lookup(reader: UnreadableArchive(listing: nil)) == .unreadable)
        #expect(ComicInfoResolver.lookup(reader: UnreadableArchive(listing: [ComicInfoXML.fileName, "001.jpg"])) == .unreadable)
        #expect(ComicInfoResolver.lookup(reader: UnreadableArchive(listing: ["001.jpg"])) == .absent)
    }

    @Test("解放した PageLoader は「読めなかった」と答える(本を開いてすぐ閉じても「無い」と覚えない)")
    func aReleasedPageLoaderReportsUnreadable() async throws {
        let workspace = try TemporaryDirectory("comicinfo-released")
        var builder = ZipFixtureBuilder()
        builder.add("001.jpg", PageImageFactory.data(number: 1, fileExtension: "jpg"))
        let url = workspace.file("book.cbz")
        try builder.write(to: url)
        let loader = PageLoader(book: try await FixtureBook.load(url), usesThumbnailDiskCache: false)

        #expect(await loader.bookArchiveComicInfo() == .absent)
        await loader.releaseAllResources()
        #expect(await loader.bookArchiveComicInfo() == .unreadable)
    }

    // MARK: - 対象外

    @Test("PDF・EPUB・存在しないパスは常に nil")
    func unsupportedInputsGiveNil() throws {
        let workspace = try TemporaryDirectory("comicinfo-unsupported")
        let pdf = workspace.file("book.pdf")
        try PDFFixtureBuilder.write(to: pdf, pageNumbers: [1])
        #expect(ComicInfoResolver.resolve(bookAt: pdf) == nil)
        #expect(ComicInfoResolver.resolve(bookAt: workspace.file("ghost.cbz")) == nil)
    }
}

/// 一覧か中身を読めない書庫(瞬断した共有・閉じた後の reader を真似る)。`listing` が nil なら一覧も読めない。
nonisolated struct UnreadableArchive: ArchiveReading {
    var listing: [String]?

    func listFilePaths() throws -> [String] {
        guard let listing else { throw CocoaError(.fileReadUnknown) }
        return listing
    }
    func data(at path: String) throws -> Data { throw CocoaError(.fileReadUnknown) }
    func entryDates(at path: String) -> (created: Date?, modified: Date?) { (nil, nil) }
    func entriesInArchiveOrder() throws -> [ArchiveEntryDescriptor] { throw CocoaError(.fileReadUnknown) }
    func readEntry(at path: String, _ body: (Data) throws -> Void) throws { throw CocoaError(.fileReadUnknown) }
}

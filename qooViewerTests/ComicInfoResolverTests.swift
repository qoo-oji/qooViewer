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

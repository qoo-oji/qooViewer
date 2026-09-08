import Foundation
import Testing

@testable import qooViewer

/// 編集モードのウェルカム画面へドロップされたものの振り分け
/// (Services/CollectionDropClassifier.swift)。
///
/// 「本かどうか」「棚かどうか」の判定は `ShelfFolderResolver` と 1 つに揃えてあるので、
/// ここで見るのは**振り分けの結果**:
/// - 書庫/PDF/EPUB のファイル、画像を直接持つフォルダ、画像フォルダだけが並ぶフォルダ → 本
/// - 本のファイルが直下に並ぶフォルダ → 棚(名前と、**直下の**本の並び)
/// - 空フォルダ・画像1枚・中間フォルダだけのフォルダ・対応しないファイル → 対象外
struct CollectionDropClassifierTests {
    private func makeShelf(_ temporary: TemporaryDirectory, named name: String) throws -> URL {
        let shelf = try temporary.directory(name)
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: 1))
        try builder.write(to: shelf.appendingPathComponent("01.cbz"))
        try PDFFixtureBuilder.write(to: shelf.appendingPathComponent("02.pdf"), pageNumbers: [2])
        return shelf
    }

    @Test("書庫・PDF・EPUB のファイルは1冊の本")
    func bookFilesAreBooks() throws {
        let temporary = try TemporaryDirectory("drop-files")
        let shelf = try makeShelf(temporary, named: "shelf")
        let cbz = shelf.appendingPathComponent("01.cbz")
        let pdf = shelf.appendingPathComponent("02.pdf")
        #expect(CollectionDropClassifier.classify([cbz, pdf], order: .byName)
            == [.book(cbz), .book(pdf)])
    }

    @Test("画像を直接持つフォルダは1冊の本")
    func afolderOfImagesIsABook() throws {
        let temporary = try TemporaryDirectory("drop-folder-book")
        let directory = temporary.file("book")
        try FixtureFolder.make(at: directory, pages: [.init("001.png", number: 1)])
        #expect(CollectionDropClassifier.classify([directory], order: .byName) == [.book(directory)])
    }

    @Test("画像フォルダだけが並ぶフォルダは、章ごとに分けた1冊の本")
    func afolderOfImageFoldersIsOneBook() throws {
        let temporary = try TemporaryDirectory("drop-chapters")
        let directory = temporary.file("book")
        try FixtureFolder.make(at: directory, pages: [
            .init("ch1/001.png", number: 1), .init("ch2/001.png", number: 2),
        ])
        #expect(CollectionDropClassifier.classify([directory], order: .byName) == [.book(directory)])
    }

    @Test("本のファイルが直下に並ぶフォルダは棚。中身は直下の本だけを並び順で")
    func afolderOfBookFilesIsAShelf() throws {
        let temporary = try TemporaryDirectory("drop-shelf")
        let shelf = try makeShelf(temporary, named: "Series A")
        // 棚の中の画像フォルダも1冊として、ファイルと同列に並ぶ。
        try FixtureFolder.make(
            at: shelf.appendingPathComponent("03-folder"), pages: [.init("001.png", number: 3)]
        )
        // 中間フォルダ(本を直接持たない)は棚の中身に数えない。
        try FileManager.default.createDirectory(
            at: shelf.appendingPathComponent("zz-empty"), withIntermediateDirectories: true
        )

        #expect(CollectionDropClassifier.classify([shelf], order: .byName) == [
            .shelf(name: "Series A", books: [
                shelf.appendingPathComponent("01.cbz"),
                shelf.appendingPathComponent("02.pdf"),
                shelf.appendingPathComponent("03-folder"),
            ])
        ])
    }

    @Test("空フォルダ・画像1枚・対応しないファイルは対象外")
    func everythingElseIsIgnored() throws {
        let temporary = try TemporaryDirectory("drop-ignored")
        let empty = try temporary.directory("empty")
        let image = temporary.file("single.png")
        try PageImageFactory.png(number: 1).write(to: image)
        let text = temporary.file("notes.txt")
        try Data("hello".utf8).write(to: text)
        let missing = temporary.file("gone.cbz")

        #expect(CollectionDropClassifier.classify([empty, image, text, missing], order: .byName)
            == [.ignored(empty), .ignored(image), .ignored(text), .ignored(missing)])
    }

    @Test("複数をまとめてドロップしても、1件ずつ独立に振り分ける")
    func amixedDropIsClassifiedItemByItem() async throws {
        let temporary = try TemporaryDirectory("drop-mixed")
        let shelf = try makeShelf(temporary, named: "shelf")
        let book = temporary.file("book")
        try FixtureFolder.make(at: book, pages: [.init("001.png", number: 1)])
        let empty = try temporary.directory("empty")

        let result = await CollectionDropClassifier.classifyAsync(
            [shelf, book, empty], order: .byName
        )
        #expect(result == [
            .shelf(name: "shelf", books: [
                shelf.appendingPathComponent("01.cbz"), shelf.appendingPathComponent("02.pdf"),
            ]),
            .book(book),
            .ignored(empty),
        ])
    }
}

import Foundation
import Testing

@testable import qooViewer

/// 自動登録フォルダから拾う本を決めるところ(Services/CollectionAutoFolderScanner.swift の
/// `CollectionAutoFolderScan`)。
///
/// ここで押さえるのは2つ:
/// - **拾う範囲がドロップと一致すること。** 判定はShelfFolderResolver.role の `.shelf(books:)`
///   そのもの ―― 直下だけで、ファイルの本と画像を直接持つフォルダが並び順どおりに入る。
///   ここがずれると「フォルダを落としたときに入る本」と「自動で入る本」が食い違う。
/// - **書き終わっていないファイルを登録しないこと。** コピー中のファイルを本として登録すると、
///   カバーの抽出が`.failed`のまま固定される(`settlingInterval`のコメント参照)。
struct CollectionAutoFolderScanTests {
    /// 書庫・PDF が名前順に並び、画像フォルダの本と、本を持たない中間フォルダが混ざった棚。
    private func makeShelf(_ label: String) throws -> (TemporaryDirectory, URL) {
        let temporary = try TemporaryDirectory(label)
        let shelf = try temporary.directory("shelf")
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: 1))
        try builder.write(to: shelf.appendingPathComponent("01.cbz"))
        try PDFFixtureBuilder.write(to: shelf.appendingPathComponent("02.pdf"), pageNumbers: [2])
        // 画像を直接持つフォルダは、ファイルの本と同列に並ぶ1冊。
        try FixtureFolder.make(
            at: shelf.appendingPathComponent("03-folder"), pages: [.init("001.png", number: 3)]
        )
        // その中に本を持たないフォルダは、棚の中身にならない(奥まで降りない)。
        try FileManager.default.createDirectory(
            at: shelf.appendingPathComponent("zz-empty"), withIntermediateDirectories: true
        )
        return (temporary, shelf)
    }

    /// このテストが作ったばかりのファイルを「落ち着いた」と見なさせるための時刻
    /// (実時間を待たずに、更新時刻より十分あとから見る)。
    private func settledNow() -> Date {
        Date().addingTimeInterval(CollectionAutoFolderScan.settlingInterval + 60)
    }

    @Test("拾うのは棚の直下だけで、並び順はフォルダブラウザと同じ")
    func picksUpOnlyTheBooksDirectlyInTheShelf() throws {
        let (temporary, shelf) = try makeShelf("auto-folder-shelf")
        defer { _ = temporary }

        let books = CollectionAutoFolderScan.books(in: shelf, order: .byName, now: settledNow())

        #expect(books == [
            shelf.appendingPathComponent("01.cbz"),
            shelf.appendingPathComponent("02.pdf"),
            shelf.appendingPathComponent("03-folder"),
        ])
        // ドロップで同じフォルダを落としたときに入る本と、1冊のずれもなく一致する。
        #expect(CollectionDropClassifier.classify([shelf], order: .byName) == [
            .shelf(folder: shelf, books: books)
        ])
    }

    @Test("棚でないフォルダからは何も拾わない(指定そのものは弾かない)")
    func foldersThatAreNotShelvesYieldNothing() throws {
        let temporary = try TemporaryDirectory("auto-folder-not-a-shelf")
        // それ自体が1冊(直下に画像がある)。
        let singleBook = temporary.file("book")
        try FixtureFolder.make(at: singleBook, pages: [.init("001.jpg", number: 1)])
        // 空のフォルダ。
        let empty = try temporary.directory("empty")

        let now = settledNow()
        #expect(CollectionAutoFolderScan.books(in: singleBook, order: .byName, now: now).isEmpty)
        #expect(CollectionAutoFolderScan.books(in: empty, order: .byName, now: now).isEmpty)
        #expect(
            CollectionAutoFolderScan.books(
                in: temporary.file("does-not-exist"), order: .byName, now: now
            ).isEmpty
        )
    }

    @Test("書き終わったばかりのファイルは、次の走査まで見送る")
    func freshlyWrittenBooksAreLeftForTheNextScan() throws {
        let (temporary, shelf) = try makeShelf("auto-folder-settling")
        defer { _ = temporary }

        // いま作ったばかりの状態で見ると、まだどれも落ち着いていない。
        #expect(CollectionAutoFolderScan.books(in: shelf, order: .byName, now: Date()).isEmpty)
        // 待ち時間ぶん経ってから見ると、そのまま全部入る(見送りであって除外ではない)。
        #expect(CollectionAutoFolderScan.books(in: shelf, order: .byName, now: settledNow()).count == 3)
    }

    @Test("更新時刻が未来のファイルも通す(通さないと永久に登録されない)")
    func booksDatedInTheFutureAreStillPickedUp() throws {
        let temporary = try TemporaryDirectory("auto-folder-future")
        let shelf = try temporary.directory("shelf")
        let book = shelf.appendingPathComponent("01.cbz")
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: 1))
        try builder.write(to: book)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: book.path
        )

        #expect(CollectionAutoFolderScan.hasSettled(book, now: Date()))
        #expect(CollectionAutoFolderScan.books(in: shelf, order: .byName, now: Date()) == [book])
    }
}

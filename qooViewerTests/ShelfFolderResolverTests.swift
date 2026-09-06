import Foundation
import Testing

@testable import qooViewer

/// 本が並んでいるだけのフォルダ(棚)を開いたときに、実際に開く1冊を決める
/// (Services/ShelfFolderResolver.swift)。
///
/// ここで押さえるのは**境界**(ユーザーの指示の3つの場合分け):
/// 1. 直下に画像があるフォルダは、それ自体が1冊
/// 2. 本のファイルが無く画像フォルダだけが並ぶフォルダも、章ごとに分けた1冊
/// 3. 書庫/PDF/EPUB が直下にあるフォルダは棚で、その中では画像フォルダも1冊として並び順で競う
///
/// 並びはフォルダブラウザ・「次の本へ」と同じ`SiblingBookOrder`に従う。
struct ShelfFolderResolverTests {
    private struct Shelf {
        let temporary: TemporaryDirectory
        let url: URL

        /// 書庫・PDF・EPUB が名前順に並んだフォルダ。
        init(_ label: String) throws {
            temporary = try TemporaryDirectory(label)
            url = temporary.file("shelf")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var builder = ZipFixtureBuilder()
            builder.add("001.png", PageImageFactory.png(number: 1))
            try builder.write(to: url.appendingPathComponent("01.cbz"))
            try PDFFixtureBuilder.write(to: url.appendingPathComponent("02.pdf"), pageNumbers: [2])
            try EpubFixtureBuilder.pages(1).write(to: url.appendingPathComponent("03.epub"))
            // 一覧に出ない種類のファイルは、先頭の判定に混ざらない。
            try Data("not a book".utf8).write(to: url.appendingPathComponent("00-notes.txt"))
        }

        func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    }

    @Test("本だけが並んだフォルダは、その先頭の1冊へ解決される")
    func aShelfResolvesToItsFirstBook() throws {
        let shelf = try Shelf("shelf-first")
        #expect(ShelfFolderResolver.resolvedBookURL(for: shelf.url, order: .byName) == shelf.file("01.cbz"))
    }

    @Test("先頭は並び順に従う(降順なら末尾の本)")
    func theFirstBookFollowsTheOrder() throws {
        let shelf = try Shelf("shelf-order")
        let descending = SiblingBookOrder(
            sort: FolderBrowserSort(grouping: .mixedByName, key: .name, direction: .descending),
            restrictsToSameType: true
        )
        #expect(ShelfFolderResolver.resolvedBookURL(for: shelf.url, order: descending) == shelf.file("03.epub"))
    }

    @Test("直下に画像があるフォルダは、これまでどおりフォルダ自身が1冊")
    func aFolderWithImagesStaysAFolderBook() throws {
        let shelf = try Shelf("shelf-with-images")
        try PageImageFactory.png(number: 9).write(to: shelf.file("cover.png"))
        #expect(ShelfFolderResolver.resolvedBookURL(for: shelf.url, order: .byName) == shelf.url)
    }

    @Test("画像フォルダだけが並んでいるフォルダは、章ごとに分けた1冊としてそのまま開く")
    func aFolderOfChapterImageFoldersStaysOneBook() throws {
        let temporary = try TemporaryDirectory("shelf-chapters")
        let root = temporary.file("book")
        try FixtureFolder.make(at: root.appendingPathComponent("ch1"), pages: [.init("001.png", number: 1)])
        try FixtureFolder.make(at: root.appendingPathComponent("ch2"), pages: [.init("001.png", number: 2)])
        #expect(ShelfFolderResolver.resolvedBookURL(for: root, order: .byName) == root)
    }

    @Test("書庫と画像フォルダが混在するフォルダでは、画像フォルダも1冊として並び順で競う")
    func anImageFolderCompetesWithArchives() throws {
        let temporary = try TemporaryDirectory("shelf-mixed")
        let root = temporary.file("book")
        let ch2 = root.appendingPathComponent("ch2")
        try FixtureFolder.make(at: ch2, pages: [.init("001.png", number: 1)])
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: 1))
        // 名前順では ch1.cbz → ch2(フォルダ)。混在した時点で棚になり、先頭の本が開く。
        let archive = root.appendingPathComponent("ch1.cbz")
        try builder.write(to: archive)
        #expect(ShelfFolderResolver.resolvedBookURL(for: root, order: .byName) == archive)

        // 画像フォルダのほうが先に来るなら、そちらが「先頭の本」。
        // (フォルダのURLは列挙元がそのまま返すため末尾に "/" が付く。パスで比べる)
        let ch0 = root.appendingPathComponent("ch0")
        try FixtureFolder.make(at: ch0, pages: [.init("001.png", number: 2)])
        #expect(ShelfFolderResolver.resolvedBookURL(for: root, order: .byName).path == ch0.path)
    }

    @Test("画像がどこにも無ければ、サブフォルダの中まで降りて先頭の1冊を開く")
    func aShelfOfFoldersDescendsToTheFirstBook() throws {
        let shelf = try Shelf("shelf-of-folders")
        let root = shelf.temporary.file("shelf-root")
        // shelf(本だけが並んだフォルダ)を、さらにフォルダで束ねた形。
        let authorA = root.appendingPathComponent("author-a")
        try FileManager.default.createDirectory(at: authorA, withIntermediateDirectories: true)
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: 1))
        try builder.write(to: authorA.appendingPathComponent("10.cbz"))
        try builder.write(to: authorA.appendingPathComponent("11.cbz"))

        #expect(ShelfFolderResolver.resolvedBookURL(for: root, order: .byName)
            == authorA.appendingPathComponent("10.cbz"))
    }

    @Test("本を1冊も含まないフォルダは読み飛ばして、次の項目から探す")
    func emptyFoldersAreSkipped() throws {
        let shelf = try Shelf("shelf-skip-empty")
        let root = shelf.temporary.file("shelf-skip-root")
        // 名前順で先に来るが中身の無いフォルダ → その次のフォルダの本が開く。
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("aaa-empty/deeper"), withIntermediateDirectories: true
        )
        let books = root.appendingPathComponent("bbb-books")
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        try PDFFixtureBuilder.write(to: books.appendingPathComponent("01.pdf"), pageNumbers: [1])

        #expect(ShelfFolderResolver.resolvedBookURL(for: root, order: .byName)
            == books.appendingPathComponent("01.pdf"))
    }

    @Test("本が1冊も無いフォルダ・フォルダではないもの・存在しないものは、そのまま返す")
    func nothingToResolveReturnsTheInput() throws {
        let temporary = try TemporaryDirectory("shelf-empty")
        let empty = temporary.file("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(ShelfFolderResolver.resolvedBookURL(for: empty, order: .byName) == empty)

        let shelf = try Shelf("shelf-file")
        // ファイルを渡された場合(本を直接開く通常の経路)は何もしない。
        #expect(ShelfFolderResolver.resolvedBookURL(for: shelf.file("01.cbz"), order: .byName)
            == shelf.file("01.cbz"))
        let missing = temporary.file("missing")
        #expect(ShelfFolderResolver.resolvedBookURL(for: missing, order: .byName) == missing)
    }
}

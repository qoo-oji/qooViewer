import Foundation
import Testing

@testable import qooViewer

/// サイドパネル下段(本の中身ブラウザ)の一覧作り(`BookInternalBrowsing.entries`)。
///
/// ここで見たいのは **`matchKey` が `PageRef.sortKey` と一致すること**。この 2 つは別々の場所で
/// 同じ式(`prefix + "/" + path`)を組み立てており、食い違うとダブルクリックしても「本の中のページ」
/// と認識されず、誤って「新しい本として開く」へ落ちる(型コメント参照)。並びは名前順ではなく
/// **本のページ順**で、コンテナは中の最初のページの位置に入る。
struct BookInternalBrowsingTests {

    /// 本のページ順(sortKey → 読書順)。`BookContentsBrowserState.pageOrder` と同じもの。
    private func pageOrder(of book: MangaBook) -> [String: Int] {
        var order: [String: Int] = [:]
        for (index, page) in book.pages.enumerated() { order[page.sortKey] = index }
        return order
    }

    private func rootLevel(of url: URL) throws -> BookEntryLevel {
        let archive = try NestedArchiveResolver.openRootArchive(at: url)
        return .archive(
            archive: archive, allPaths: try archive.reader.listFilePaths(), prefix: "", matchKeyPrefix: nil
        )
    }

    // MARK: - 書庫の本

    @Test("書庫の中: 仮想フォルダと入れ子の書庫を、本のページ順に並べる")
    func archiveRootEntries() async throws {
        let url = Fixtures.url("nested/nested-in-subfolder.cbz")
        let book = try await FixtureBook.load(url)
        let entries = try BookInternalBrowsing.entries(at: rootLevel(of: url), pageOrder: pageOrder(of: book))

        // この本の中身は chapters/ フォルダだけ(その中に ch01.cbz / ch02.cbz)。
        #expect(entries.map(\.displayName) == ["chapters"])
        let chapters = try #require(entries.first)
        #expect(chapters.isContainer)
        #expect(!chapters.isImage)
        #expect(chapters.matchKey == "chapters/")
        guard case .archiveVirtualFolder(let prefix) = try #require(chapters.navigateTarget) else {
            Issue.record("仮想フォルダとして踏み込めない: \(String(describing: chapters.navigateTarget))")
            return
        }
        #expect(prefix == "chapters/")

        // 1 段潜ると入れ子の書庫が 2 つ。踏み込み方は「readerから取り出して開き直す」。
        let inside = try BookInternalBrowsing.entries(
            at: virtualFolder(of: url, prefix: prefix), pageOrder: pageOrder(of: book)
        )
        #expect(inside.map(\.displayName) == ["ch01.cbz", "ch02.cbz"])
        #expect(inside.allSatisfy { $0.isContainer })
        #expect(inside.map(\.matchKey) == ["chapters/ch01.cbz", "chapters/ch02.cbz"])
        for entry in inside {
            guard case .nestedArchiveEntry(let entryPath) = try #require(entry.navigateTarget) else {
                Issue.record("入れ子の書庫として踏み込めない: \(entry.displayName)")
                continue
            }
            #expect(entryPath == "chapters/\(entry.displayName)")
        }

        // コンテナの matchKey は、中のページの sortKey の接頭辞になっている(順位付けの前提)。
        let sortKeys = book.pages.map(\.sortKey)
        #expect(sortKeys.allSatisfy { $0.hasPrefix("chapters/") })
        #expect(inside.allSatisfy { entry in sortKeys.contains { $0.hasPrefix(entry.matchKey + "/") } })
    }

    @Test("書庫の中: 画像の matchKey は本のページの sortKey と一致する")
    func archiveImageEntriesMatchPages() async throws {
        let url = Fixtures.url("zip/zip-zipcli.cbz")
        let book = try await FixtureBook.load(url)
        let order = pageOrder(of: book)
        let entries = try BookInternalBrowsing.entries(at: rootLevel(of: url), pageOrder: order)

        // 表紙(1 ページ目)はフォルダより前。並びは名前順ではなく本のページ順。
        #expect(entries.map(\.displayName) == ["cover.png", "vol1", "vol2"])
        let cover = try #require(entries.first)
        #expect(cover.isImage)
        #expect(order[cover.matchKey] == 0)

        let inVol1 = try BookInternalBrowsing.entries(
            at: virtualFolder(of: url, prefix: "vol1/"), pageOrder: order
        )
        #expect(inVol1.map(\.matchKey) == ["vol1/001.png", "vol1/002.png"])
        #expect(inVol1.allSatisfy { order[$0.matchKey] != nil })
    }

    @Test("書庫の中: __MACOSX と ._ は一覧にも出さない(ページの数え上げと同じ除外)")
    func archiveHidesAppleDoubleEntries() async throws {
        let url = Fixtures.url("zip/zip-ditto.cbz")
        let book = try await FixtureBook.load(url)
        let entries = try BookInternalBrowsing.entries(at: rootLevel(of: url), pageOrder: pageOrder(of: book))
        #expect(entries.map(\.displayName) == ["B_src"])
        #expect(!entries.contains { $0.displayName.hasPrefix("__MACOSX") })
    }

    // MARK: - フォルダの本

    @Test("フォルダの中: 実フォルダ・ディスク上の書庫・画像を見分ける")
    func folderEntries() async throws {
        let temp = try TemporaryDirectory("browsing-folder")
        let root = try FixtureFolder.make(
            at: temp.file("book"),
            pages: [.init("cover.png", number: 1), .init("vol1/001.png", number: 2)],
            extraFiles: ["notes.txt": "not a page"]
        )
        // フォルダの中に書庫を置くと、その中身も 1 冊のページに統合される(BookLoader)。
        var zip = ZipFixtureBuilder()
        zip.add("003.png", PageImageFactory.png(number: 3))
        try zip.write(to: root.appendingPathComponent("ch02.cbz"))

        let book = try await FixtureBook.load(root)
        let order = pageOrder(of: book)
        let entries = try BookInternalBrowsing.entries(at: .folder(root), pageOrder: order)

        // 並びは名前順ではなく本のページ順。この本のページはフルパスの正準順なので
        // "ch02.cbz/003.png" < "cover.png" < "vol1/001.png" ―― 書庫が先頭に来る。
        #expect(entries.map(\.displayName) == ["ch02.cbz", "cover.png", "vol1"])
        // 一覧に出るのは画像・フォルダ・書庫だけ(notes.txt は出ない)。
        #expect(!entries.contains { $0.displayName == "notes.txt" })
        // フォルダの本の matchKey は絶対パス。
        #expect(entries.map(\.matchKey) == [
            root.appendingPathComponent("ch02.cbz").path,
            root.appendingPathComponent("cover.png").path,
            root.appendingPathComponent("vol1").path,
        ])

        let targets = entries.map(\.navigateTarget)
        if case .archiveFileOnDisk(let url) = try #require(targets[0]) {
            #expect(url.lastPathComponent == "ch02.cbz")
        } else {
            Issue.record("ディスク上の書庫として踏み込めない")
        }
        #expect(targets[1] == nil)
        if case .realFolder(let url) = try #require(targets[2]) {
            #expect(url.lastPathComponent == "vol1")
        } else {
            Issue.record("実フォルダとして踏み込めない")
        }
        // 画像の matchKey は本のページの sortKey そのもの。
        #expect(order[entries[1].matchKey] == 1)
    }

    // MARK: - 直接渡された画像

    @Test("画像ファイルの一覧は、渡された順(=本のページ順)のまま")
    func imageFileList() async throws {
        let temp = try TemporaryDirectory("browsing-images")
        let root = try FixtureFolder.make(
            at: temp.file("pages"),
            pages: [.init("1.png", number: 1), .init("2.png", number: 2), .init("10.png", number: 10)]
        )
        let urls = ["1.png", "2.png", "10.png"].map { root.appendingPathComponent($0) }
        let book = try await BookLoader.load(imageFiles: urls)

        let entries = try BookInternalBrowsing.entries(
            at: .imageFileList(urls), pageOrder: pageOrder(of: book)
        )
        #expect(entries.map(\.displayName) == ["1.png", "2.png", "10.png"])
        #expect(entries.map(\.matchKey) == book.pages.map(\.sortKey))
        #expect(entries.allSatisfy { $0.isImage && !$0.isContainer })
    }

    // MARK: - 道具

    /// 同じ書庫の中の、1 段深い仮想フォルダ(I/O 無しで prefix を深くするだけ)。
    private func virtualFolder(of url: URL, prefix: String) throws -> BookEntryLevel {
        let archive = try NestedArchiveResolver.openRootArchive(at: url)
        return .archive(
            archive: archive, allPaths: try archive.reader.listFilePaths(), prefix: prefix, matchKeyPrefix: nil
        )
    }
}

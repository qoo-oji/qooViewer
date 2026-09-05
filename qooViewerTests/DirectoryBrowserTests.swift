import Foundation
import Testing

@testable import qooViewer

/// フォルダの一覧と並べ替え(Services/DirectoryBrowser.swift)。
///
/// この一覧の並びは、サイドパネル上段・「次の本へ / 前の本へ」・「同じフォルダのファイルを開く」の
/// **共通の正典**(SiblingFinder は自前で列挙せず、ここに絞り込みを掛けるだけ)。比較は必ず
/// 全順序 ―― 名前 → パスまで見て決着させる ―― にしてあり、そのおかげで降順は昇順の完全な逆順に
/// なり、同じフォルダを開き直しても並びが揺れない。
struct DirectoryBrowserSortTests {
    private func entry(
        _ name: String, isDirectory: Bool = false, size: Int64? = nil,
        kind: String? = nil, created: Date? = nil, modified: Date? = nil,
        parent: String = "/books"
    ) -> DirectoryBrowser.Entry {
        DirectoryBrowser.Entry(
            url: URL(fileURLWithPath: "\(parent)/\(name)"), isDirectory: isDirectory,
            displayName: name, fileSize: isDirectory ? nil : size, typeDescription: kind,
            creationDate: created, modificationDate: modified,
            containsImageFile: false, containsSubdirectory: false
        )
    }

    private func sort(
        _ key: FolderBrowserSortKey, _ direction: FolderBrowserSortDirection = .ascending,
        grouping: SidePanelSortOrder = .mixedByName
    ) -> FolderBrowserSort {
        FolderBrowserSort(grouping: grouping, key: key, direction: direction)
    }

    private func names(_ entries: [DirectoryBrowser.Entry]) -> [String] { entries.map(\.displayName) }

    // MARK: - グループ分け

    @Test("フォルダを先にまとめる設定は、基準・向きより先に効く")
    func foldersComeFirstRegardlessOfDirection() {
        let entries = [entry("b.cbz"), entry("a", isDirectory: true), entry("c.cbz"), entry("z", isDirectory: true)]
        #expect(names(DirectoryBrowser.sortedEntries(entries, sort: sort(.name, grouping: .foldersFirst)))
            == ["a", "z", "b.cbz", "c.cbz"])
        // 降順にしてもフォルダは上のまま(Finder の「フォルダを常に上部に表示」と同じ)。
        #expect(names(DirectoryBrowser.sortedEntries(entries, sort: sort(.name, .descending, grouping: .foldersFirst)))
            == ["z", "a", "c.cbz", "b.cbz"])
    }

    @Test("グループ分けをしない設定では、フォルダもファイルも一列に並ぶ")
    func mixedGroupingInterleavesFoldersAndFiles() {
        let entries = [entry("b.cbz"), entry("a", isDirectory: true), entry("c", isDirectory: true)]
        #expect(names(DirectoryBrowser.sortedEntries(entries, sort: sort(.name))) == ["a", "b.cbz", "c"])
    }

    // MARK: - 基準

    @Test("名前は Finder と同じ照合(数字は数値、大文字小文字は区別しない)")
    func nameUsesLocalizedStandardCompare() {
        let entries = [entry("vol10.cbz"), entry("vol2.cbz"), entry("Vol1.cbz")]
        #expect(names(DirectoryBrowser.sortedEntries(entries, sort: sort(.name)))
            == ["Vol1.cbz", "vol2.cbz", "vol10.cbz"])
    }

    @Test("サイズ順。値を持たない項目(フォルダ)は昇順で先頭側にまとまる")
    func sizeSortsWithMissingValuesFirst() {
        let entries = [entry("big.cbz", size: 300), entry("small.cbz", size: 100), entry("dir", isDirectory: true)]
        #expect(names(DirectoryBrowser.sortedEntries(entries, sort: sort(.size)))
            == ["dir", "small.cbz", "big.cbz"])
    }

    @Test("日付順(作成日・変更日)")
    func dateSorting() {
        let old = Date(timeIntervalSince1970: 0)
        let new = Date(timeIntervalSince1970: 1000)
        let entries = [
            entry("new.cbz", created: new, modified: old),
            entry("old.cbz", created: old, modified: new),
        ]
        #expect(names(DirectoryBrowser.sortedEntries(entries, sort: sort(.creationDate))) == ["old.cbz", "new.cbz"])
        #expect(names(DirectoryBrowser.sortedEntries(entries, sort: sort(.modificationDate))) == ["new.cbz", "old.cbz"])
    }

    @Test("種類順(Finder の「種類」)")
    func kindSorting() {
        let entries = [entry("a.pdf", kind: "PDF"), entry("b.cbz", kind: "Comic Book"), entry("c.cbz", kind: nil)]
        #expect(names(DirectoryBrowser.sortedEntries(entries, sort: sort(.kind))) == ["c.cbz", "b.cbz", "a.pdf"])
    }

    // MARK: - 全順序であること

    @Test("同じ値のときは名前で、名前も同じならパスで決着する")
    func tiesAreBrokenByNameThenPath() {
        let entries = [
            entry("same.cbz", size: 100, parent: "/books/z"),
            entry("same.cbz", size: 100, parent: "/books/a"),
            entry("other.cbz", size: 100),
        ]
        let sorted = DirectoryBrowser.sortedEntries(entries, sort: sort(.size))
        #expect(sorted.map(\.url.path) == ["/books/other.cbz", "/books/a/same.cbz", "/books/z/same.cbz"])
    }

    @Test("降順は昇順の完全な逆順(グループ分け無しのとき)")
    func descendingIsTheExactReverseOfAscending() {
        // 比較が全順序でなければ、ここが崩れて並びが揺れる。
        let entries = (1...8).map { entry("book\($0).cbz", size: Int64($0 % 3)) }
        let ascending = DirectoryBrowser.sortedEntries(entries, sort: sort(.size))
        let descending = DirectoryBrowser.sortedEntries(entries, sort: sort(.size, .descending))
        #expect(names(descending) == names(ascending).reversed())
    }

    @Test("並べ替えは何度呼んでも同じ結果になる")
    func sortingIsStable() {
        let entries = (1...8).map { entry("book\($0).cbz", size: 1) }
        let once = DirectoryBrowser.sortedEntries(entries, sort: sort(.size))
        #expect(names(DirectoryBrowser.sortedEntries(once, sort: sort(.size))) == names(once))
        #expect(names(DirectoryBrowser.sortedEntries(entries.reversed(), sort: sort(.size))) == names(once))
    }
}

/// 実際のフォルダを列挙する側。
struct DirectoryBrowserListingTests {
    /// 本(cbz)・PDF・画像・サブフォルダ・対象外のファイルが 1 つずつあるフォルダ。
    private func makeWorkspace() throws -> TemporaryDirectory {
        let workspace = try TemporaryDirectory("browser")
        try FixtureFolder.make(
            at: workspace.file("root"), pages: [.init("cover.jpg", number: 1)],
            extraFiles: ["notes.txt": "対象外"]
        )
        var builder = ZipFixtureBuilder()
        builder.add("001.jpg", PageImageFactory.data(number: 1, fileExtension: "jpg"))
        try builder.write(to: workspace.file("root/book.cbz"))
        try PDFFixtureBuilder.write(to: workspace.file("root/book.pdf"), pageNumbers: [1])
        try FixtureFolder.make(at: workspace.file("root/chapter"), pages: [.init("001.jpg", number: 2)])
        try FileManager.default.createDirectory(
            at: workspace.file("root/empty"), withIntermediateDirectories: true
        )
        return workspace
    }

    @Test("開ける形式のファイルとフォルダだけを並べる(画像とその他のファイルは出さない)")
    func onlyOpenableFilesAndFoldersAreListed() throws {
        let workspace = try makeWorkspace()
        let entries = try DirectoryBrowser.entries(in: workspace.file("root"), sort: .default)
        // 画像(cover.jpg)は一覧に出さない ―― 一覧の目的は「本を探すこと」。
        #expect(entries.map(\.displayName).sorted() == ["book.cbz", "book.pdf", "chapter", "empty"])
    }

    @Test("一覧に出さない画像の有無は、Listing 側が伝える")
    func theListingReportsLooseImages() throws {
        let workspace = try makeWorkspace()
        #expect(try DirectoryBrowser.listing(in: workspace.file("root"), sort: .default).containsImageFile)
        #expect(try !DirectoryBrowser.listing(in: workspace.file("root/empty"), sort: .default).containsImageFile)
    }

    @Test("画像しか入っていないフォルダは「行き止まりの本」")
    func aFolderOfImagesIsALeafBook() throws {
        let workspace = try makeWorkspace()
        let entries = try DirectoryBrowser.entries(in: workspace.file("root"), sort: .default)
        let chapter = try #require(entries.first { $0.displayName == "chapter" })
        #expect(chapter.isDirectory)
        #expect(chapter.containsImageFile)
        #expect(!chapter.containsSubdirectory)
        #expect(chapter.isLeafBookFolder)

        let empty = try #require(entries.first { $0.displayName == "empty" })
        #expect(!empty.containsImageFile)
        #expect(!empty.isLeafBookFolder)
    }

    @Test("読めないフォルダは throw する(空フォルダと区別するため)")
    func anUnreadableDirectoryThrows() throws {
        let workspace = try TemporaryDirectory("browser-missing")
        #expect(throws: (any Error).self) {
            try DirectoryBrowser.entries(in: workspace.file("ghost"), sort: .default)
        }
    }

    @Test("直下に画像があるかどうかは、見つかった時点で打ち切って調べる")
    func directlyContainsImageFileStopsAtTheFirstHit() throws {
        let workspace = try makeWorkspace()
        #expect(DirectoryBrowser.directlyContainsImageFile(workspace.file("root")))
        #expect(DirectoryBrowser.directlyContainsImageFile(workspace.file("root/chapter")))
        #expect(!DirectoryBrowser.directlyContainsImageFile(workspace.file("root/empty")))
        #expect(!DirectoryBrowser.directlyContainsImageFile(workspace.file("ghost")))
    }

    @Test("表示名はボリューム名などを考えた Finder と同じ名前")
    func displayNameFallsBackToTheLastComponent() throws {
        let workspace = try makeWorkspace()
        #expect(DirectoryBrowser.displayName(for: workspace.file("root/chapter")) == "chapter")
    }
}

/// 同じフォルダの前後の本(Services/SiblingFinder.swift)。
struct SiblingFinderTests {
    /// a.cbz / b.cbz / c.cbz と、画像フォルダ folder1、本ではない中間フォルダ empty。
    private func makeWorkspace() throws -> TemporaryDirectory {
        let workspace = try TemporaryDirectory("siblings")
        try FileManager.default.createDirectory(at: workspace.file("shelf"), withIntermediateDirectories: true)
        for name in ["a", "b", "c"] {
            var builder = ZipFixtureBuilder()
            builder.add("001.jpg", PageImageFactory.data(number: 1, fileExtension: "jpg"))
            try builder.write(to: workspace.file("shelf/\(name).cbz"))
        }
        try FixtureFolder.make(at: workspace.file("shelf/folder1"), pages: [.init("001.jpg", number: 1)])
        try FileManager.default.createDirectory(
            at: workspace.file("shelf/empty"), withIntermediateDirectories: true
        )
        return workspace
    }

    @Test("本として開けるものだけを並べる(本を含まない中間フォルダは落とす)")
    func onlyBooksAreListed() throws {
        let workspace = try makeWorkspace()
        let urls = SiblingFinder.siblingBookURLs(of: workspace.file("shelf/a.cbz"), order: .byName)
        #expect(urls.map(\.lastPathComponent) == ["a.cbz", "b.cbz", "c.cbz", "folder1"])
    }

    @Test("次の本・前の本")
    func steppingThroughTheShelf() async throws {
        let workspace = try makeWorkspace()
        let b = workspace.file("shelf/b.cbz")
        #expect(await SiblingFinder.url(after: b, order: .byName)?.lastPathComponent == "c.cbz")
        #expect(await SiblingFinder.url(before: b, order: .byName)?.lastPathComponent == "a.cbz")
        // 端では nil。
        #expect(await SiblingFinder.url(before: workspace.file("shelf/a.cbz"), order: .byName) == nil)
        #expect(await SiblingFinder.url(after: workspace.file("shelf/c.cbz"), order: .byName) == nil)
    }

    @Test("「種類の異なる本を挟まない」設定では、ファイルとフォルダが混ざらない")
    func restrictingToTheSameTypeSkipsTheOtherKind() async throws {
        let workspace = try makeWorkspace()
        // c.cbz の次は folder1 だが、既定(byName)は同じ種類だけを歩く。
        #expect(await SiblingFinder.url(after: workspace.file("shelf/c.cbz"), order: .byName) == nil)

        let mixed = SiblingBookOrder.followingFolderBrowser(
            FolderBrowserSort(grouping: .mixedByName, key: .name, direction: .ascending)
        )
        #expect(await SiblingFinder.url(after: workspace.file("shelf/c.cbz"), order: mixed)?
            .lastPathComponent == "folder1")
    }

    @Test("末尾のスラッシュが違うだけの URL でも、同じ本として位置を見つける")
    func aTrailingSlashDoesNotBreakTheLookup() async throws {
        let workspace = try makeWorkspace()
        // フォルダの本は、開いた経路によって末尾のスラッシュの有無が変わる。
        let withSlash = URL(fileURLWithPath: workspace.file("shelf/folder1").path, isDirectory: true)
        let mixed = SiblingBookOrder.followingFolderBrowser(
            FolderBrowserSort(grouping: .mixedByName, key: .name, direction: .ascending)
        )
        #expect(await SiblingFinder.url(before: withSlash, order: mixed)?.lastPathComponent == "c.cbz")
    }

    @Test("読めないフォルダでは空の一覧になる(throw しない)")
    func anUnreadableFolderGivesAnEmptyList() throws {
        let workspace = try TemporaryDirectory("siblings-missing")
        #expect(SiblingFinder.siblingBookURLs(of: workspace.file("ghost/a.cbz"), order: .byName).isEmpty)
    }
}

/// ファイルノード識別子(Services/FileNodeIdentifier.swift)。
/// 移動・リネームしてもお気に入り・レイアウト・ブックマークを引き継ぐための手がかり。
struct FileNodeIdentifierTests {
    @Test("同じファイルなら同じ値、別のファイルなら別の値")
    func identifiersDistinguishFiles() throws {
        let workspace = try TemporaryDirectory("inode")
        let a = workspace.file("a.cbz")
        let b = workspace.file("b.cbz")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        let idA = try #require(FileNodeIdentifier.current(for: a))
        #expect(FileNodeIdentifier.current(for: a) == idA)
        #expect(FileNodeIdentifier.current(for: b) != idA)
        // 同じボリュームなので、デバイス番号は揃う。
        #expect(FileNodeIdentifier.current(for: b)?.volumeDeviceNumber == idA.volumeDeviceNumber)
    }

    @Test("リネーム・移動しても値は変わらない(これがこの識別子の目的)")
    func theIdentifierSurvivesARename() throws {
        let workspace = try TemporaryDirectory("inode-move")
        let original = workspace.file("before.cbz")
        try Data("book".utf8).write(to: original)
        let before = try #require(FileNodeIdentifier.current(for: original))

        let moved = try workspace.directory("sub").appendingPathComponent("after.cbz")
        try FileManager.default.moveItem(at: original, to: moved)
        #expect(FileNodeIdentifier.current(for: moved) == before)
    }

    @Test("中身を書き換えても値は変わらない(内容ではなくノードの識別子)")
    func theIdentifierIgnoresTheContent() throws {
        let workspace = try TemporaryDirectory("inode-content")
        let url = workspace.file("a.cbz")
        try Data("a".utf8).write(to: url)
        let before = try #require(FileNodeIdentifier.current(for: url))
        try Data("changed".utf8).write(to: url)
        #expect(FileNodeIdentifier.current(for: url) == before)
    }

    @Test("フォルダにも値がある / 無いパスは nil")
    func foldersHaveIdentifiersAndMissingPathsDoNot() throws {
        let workspace = try TemporaryDirectory("inode-folder")
        #expect(FileNodeIdentifier.current(for: workspace.url) != nil)
        #expect(FileNodeIdentifier.current(for: workspace.file("ghost")) == nil)
    }

    @Test("Codable で往復する(DB へ入る値)")
    func codableRoundTrip() throws {
        let identifier = FileNodeIdentifier(inodeNumber: 12345, volumeDeviceNumber: 16777220)
        let data = try JSONEncoder().encode(identifier)
        #expect(try JSONDecoder().decode(FileNodeIdentifier.self, from: data) == identifier)
    }
}

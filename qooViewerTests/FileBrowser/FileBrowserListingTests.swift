import Foundation
import Testing

@testable import qooViewer

/// ファイルブラウザの一覧の読み取り(Services/FileBrowser/FileBrowserListing.swift)。
///
/// 見るのは、サイドパネルのフォルダブラウザとの**違い**(全ファイルを出す・パッケージを1項目にする・
/// 子フォルダの中を見ない)と、失敗の分類(読めない / 無い)。名前はすべて合成名。
struct FileBrowserListingTests {
    @Test("すべてのファイルを出し、隠しファイルは出さない。フォルダはサイズを持たない")
    func listsEveryVisibleItem() throws {
        let temporary = try TemporaryDirectory("listing-all")
        let folder = try temporary.directory("root")
        try temporary.directory("root/sub")
        try Data("x".utf8).write(to: folder.appendingPathComponent("note.txt"))
        try Data("zip".utf8).write(to: folder.appendingPathComponent("book.cbz"))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden"))

        let entries = try FileBrowserListing.entries(in: folder)
        let names = Set(entries.map(\.url.lastPathComponent))
        #expect(names == ["sub", "note.txt", "book.cbz"])

        let sub = try #require(entries.first { $0.url.lastPathComponent == "sub" })
        #expect(sub.isNavigableFolder)
        #expect(sub.fileSize == nil)
        #expect(!sub.opensAsBook)

        let note = try #require(entries.first { $0.url.lastPathComponent == "note.txt" })
        #expect(!note.isDirectory)
        #expect(note.fileSize == 1)
        #expect(!note.opensAsBook)

        let book = try #require(entries.first { $0.url.lastPathComponent == "book.cbz" })
        #expect(book.opensAsBook)
    }

    @Test("パッケージは中へ入らない1項目で、「フォルダを上に」ではファイルの側に並ぶ")
    func packagesAreSingleItems() throws {
        let temporary = try TemporaryDirectory("listing-package")
        let folder = try temporary.directory("root")
        try temporary.directory("root/Tool.app/Contents")
        try temporary.directory("root/plain")

        let entries = try FileBrowserListing.entries(in: folder)
        let app = try #require(entries.first { $0.url.lastPathComponent == "Tool.app" })
        #expect(app.isDirectory)
        #expect(app.isPackage)
        #expect(!app.isNavigableFolder)
        #expect(!app.sortsAsFolder)

        let sorted = FolderBrowserSort.default.sorted(entries)
        #expect(sorted.map(\.url.lastPathComponent) == ["plain", "Tool.app"])
    }

    @Test("無いフォルダは notFound に分類される")
    func missingFolderIsNotFound() throws {
        let temporary = try TemporaryDirectory("listing-missing")
        let missing = temporary.file("gone")
        #expect(throws: (any Error).self) { try FileBrowserListing.entries(in: missing) }
        do {
            _ = try FileBrowserListing.entries(in: missing)
        } catch {
            #expect(FileBrowserLoadError.classify(error, folder: missing) == .notFound)
        }
    }

    @Test("読めないフォルダは空の一覧ではなく needsAccess になる")
    func unreadableFolderNeedsAccess() throws {
        let temporary = try TemporaryDirectory("listing-locked")
        let locked = try temporary.directory("locked")
        try Data("x".utf8).write(to: locked.appendingPathComponent("inside.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        do {
            let entries = try FileBrowserListing.entries(in: locked)
            Issue.record("読めないフォルダが \(entries.count) 件の一覧として返った")
        } catch {
            #expect(FileBrowserLoadError.classify(error, folder: locked) == .needsAccess)
        }
    }

    @Test("コンピュータには / と /Volumes 直下の、Finder に出すボリュームだけが並ぶ")
    func volumeEntriesFollowTheMountTable() {
        let table = MountTable(entries: [
            .init(mountPoint: "/", mountedFrom: "/dev/disk1", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
            .init(mountPoint: "/System/Volumes/Data", mountedFrom: "/dev/disk2", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: true),
            .init(mountPoint: "/dev", mountedFrom: "devfs", fileSystemType: "devfs", isLocal: true, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/Share", mountedFrom: "//server/share", fileSystemType: "smbfs", isLocal: false, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/Snapshot", mountedFrom: "/dev/disk3", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: true),
        ])
        let entries = FileBrowserListing.volumeEntries(mountTable: table)
        #expect(entries.map(\.url.path).sorted() == ["/", "/Volumes/Share"])
        #expect(entries.allSatisfy { $0.isVolume && $0.isNavigableFolder })
        // ネットワーク越しのボリュームには問い合わせない(名前はパスの成分)。
        #expect(entries.first { $0.url.path == "/Volumes/Share" }?.displayName == "Share")
    }

    @Test("絞り込みはウェルカム画面の検索と同じ規則(語の AND・大文字小文字と全角半角を区別しない)")
    func filteringUsesTheLibrarySearchRules() {
        let entries = ["Alpha Notes.txt", "beta.cbz", "ＡＬＰＨＡ report.pdf"].map {
            FileBrowserEntry(
                url: URL(fileURLWithPath: "/tmp/\($0)"), displayName: $0, isDirectory: false, isPackage: false,
                isSymbolicLink: false, isVolume: false, fileSize: nil, typeDescription: nil,
                creationDate: nil, modificationDate: nil
            )
        }
        #expect(FileBrowserListing.filtered(entries, by: "").count == 3)
        #expect(FileBrowserListing.filtered(entries, by: "alpha").map(\.displayName) == ["Alpha Notes.txt", "ＡＬＰＨＡ report.pdf"])
        #expect(FileBrowserListing.filtered(entries, by: "alpha report").map(\.displayName) == ["ＡＬＰＨＡ report.pdf"])
    }

    @Test("消えたフォルダの退避先は、残っているいちばん近い祖先")
    func nearestExistingAncestor() throws {
        let temporary = try TemporaryDirectory("listing-ancestor")
        let kept = try temporary.directory("a")
        let gone = kept.appendingPathComponent("b/c", isDirectory: true)
        let ancestor = try #require(FileBrowserListing.nearestExistingAncestor(of: gone))
        #expect(ancestor.path == kept.path)
    }

    @Test("外れたボリューム上のフォルダの退避先はコンピュータ(nil)")
    func unmountedVolumeRetreatsToComputer() {
        let table = MountTable(entries: [
            .init(mountPoint: "/", mountedFrom: "/dev/disk1", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
        ])
        let url = URL(fileURLWithPath: "/Volumes/NotConnected-\(UUID().uuidString)/folder", isDirectory: true)
        #expect(FileBrowserListing.nearestExistingAncestor(of: url, mountTable: table) == nil)
    }
}

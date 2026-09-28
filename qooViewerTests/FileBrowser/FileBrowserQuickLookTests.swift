import Foundation
import Testing

@testable import qooViewer

/// ファイルブラウザのクイックルックに渡す項目(Views/FileBrowser/FileBrowserQuickLook.swift)。パネルそのものは AppKit なので、
/// 記号リンク・エイリアスの先の解決だけを見る。
struct FileBrowserQuickLookTests {
    private static let localOnly = MountTable(entries: [
        .init(mountPoint: "/", mountedFrom: "disk", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
    ])

    @Test("記号リンク・エイリアスは先を見せ、題は「名前 (種類)」。ふつうの項目はそのまま。断られた先はリンク自身")
    func linksPreviewTheirTargets() throws {
        let temporary = try TemporaryDirectory("quicklook-links")
        let folder = try temporary.directory("root")
        let book = folder.appendingPathComponent("book.cbz")
        try Data("zip".utf8).write(to: book)
        let link = folder.appendingPathComponent("to-book")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: book)
        let alias = folder.appendingPathComponent("book alias")
        try URL.writeBookmarkData(
            try book.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil), to: alias
        )
        let toShare = folder.appendingPathComponent("to-share")
        try FileManager.default.createSymbolicLink(atPath: toShare.path, withDestinationPath: "/Volumes/Share")
        let remote = MountTable(entries: [
            .init(mountPoint: "/", mountedFrom: "disk", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/Share", mountedFrom: "//server/share", fileSystemType: "smbfs", isLocal: false, isHiddenFromBrowsing: false),
        ])

        let entries = try FileBrowserListing.entries(in: folder)
        func entry(_ name: String) throws -> FileBrowserEntry {
            try #require(entries.first { $0.url.lastPathComponent == name })
        }
        let items = FileBrowserQuickLook.previewItems(
            for: [try entry("book.cbz"), try entry("to-book"), try entry("book alias"), try entry("to-share")],
            currentFolder: folder, mountTable: remote, protectedPrefixes: [], categoryPrefixes: []
        )
        #expect(items.map(\.url.path) == [book.path, book.path, book.path, toShare.path])
        #expect(items[0].title == "book.cbz")
        // 題はリンクの名前と、一覧の種類の説明(Finder の「エイリアス」。OS の言語)。
        let linkKind = try #require(try entry("to-book").typeDescription)
        #expect(items[1].title == "to-book (\(linkKind))")
        #expect(items[2].title.hasPrefix("book alias ("))
        // 断られた先はリンク自身のままなので、題も名前だけ(「(エイリアス)」は先を見せているときの印)。
        #expect(items[3].title == "to-share")
    }
}

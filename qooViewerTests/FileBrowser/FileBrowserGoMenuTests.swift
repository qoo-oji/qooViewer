import Foundation
import Testing

@testable import qooViewer

/// ファイルブラウザの「移動」メニュー(Views/FileBrowser/FileBrowserGoMenu.swift)の、画面に依らない部分。
struct FileBrowserGoMenuTests {
    private let home = URL(fileURLWithPath: "/Users/nobody", isDirectory: true)

    @Test("「フォルダへ移動…」の入力: 絶対パスと ~ だけを受け付け、~ は実際のホームに読み替える")
    func resolvesPaths() {
        #expect(FileBrowserGoToFolderSheet.resolve("/Volumes/X", home: home)?.path == "/Volumes/X")
        #expect(FileBrowserGoToFolderSheet.resolve("  /Volumes/X/  ", home: home)?.path == "/Volumes/X")
        #expect(FileBrowserGoToFolderSheet.resolve("~", home: home)?.path == "/Users/nobody")
        #expect(FileBrowserGoToFolderSheet.resolve("~/Documents", home: home)?.path == "/Users/nobody/Documents")
        #expect(FileBrowserGoToFolderSheet.resolve("/Volumes/X/../Y", home: home)?.path == "/Volumes/Y")
        #expect(FileBrowserGoToFolderSheet.resolve("Documents", home: home) == nil)
        #expect(FileBrowserGoToFolderSheet.resolve("", home: home) == nil)
    }

    @Test("標準の場所は実際のホームの下(サンドボックスのコンテナではない)と /Applications")
    func standardLocations() {
        let realHome = FileBrowserListing.realHomeDirectory().path
        #expect(!realHome.contains("/Library/Containers/"))
        #expect(FileBrowserStandardLocation.home.url.path == realHome)
        #expect(FileBrowserStandardLocation.documents.url.path == realHome + "/Documents")
        #expect(FileBrowserStandardLocation.desktop.url.path == realHome + "/Desktop")
        #expect(FileBrowserStandardLocation.downloads.url.path == realHome + "/Downloads")
        #expect(FileBrowserStandardLocation.library.url.path == realHome + "/Library")
        #expect(FileBrowserStandardLocation.applications.url.path == "/Applications")
        #expect(FileBrowserStandardLocation.utilities.url.path == "/Applications/Utilities")
    }
}

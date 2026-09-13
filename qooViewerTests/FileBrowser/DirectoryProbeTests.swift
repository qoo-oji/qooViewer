import Foundation
import Testing

@testable import qooViewer

/// ツリーの三角の判定(Services/FileBrowser/DirectoryProbe.swift)。一時フォルダの上で、ツリーの一覧
/// (`FileBrowserListing.entries` → `isNavigableFolder`)と数える規則が揃っていることを見る。
struct DirectoryProbeTests {
    private func folder(_ label: String) throws -> (TemporaryDirectory, URL) {
        let temporary = try TemporaryDirectory(label)
        return (temporary, try temporary.directory("root"))
    }

    @Test("ファイルしか無ければ false、フォルダがあれば true")
    func filesOnlyVersusSubfolder() throws {
        let (temporary, root) = try folder("probe-basic")
        try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
        #expect(DirectoryProbe.hasSubdirectory(at: root, protectedPrefixes: []) == false)
        _ = try temporary.directory("root/sub")
        #expect(DirectoryProbe.hasSubdirectory(at: root, protectedPrefixes: []) == true)
    }

    @Test("隠しフォルダ(. で始まる・UF_HIDDEN)・パッケージ・記号リンクは数えない(ツリーに出ないので)")
    func ignoresWhatTheTreeHides() throws {
        let (temporary, root) = try folder("probe-hidden")
        _ = try temporary.directory("root/.dot")
        let flagged = try temporary.directory("root/flagged")
        #expect(chflags(flagged.path, UInt32(UF_HIDDEN)) == 0)
        _ = try temporary.directory("root/Some.app/Contents")
        let target = try temporary.directory("elsewhere")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
        #expect(DirectoryProbe.hasSubdirectory(at: root, protectedPrefixes: []) == false)
        // 一覧も同じものを出さないこと(規則がずれると「空なのに三角」になる)。
        #expect(try FileBrowserListing.entries(in: root).filter(\.isNavigableFolder).isEmpty)
    }

    @Test("保護下の場所とその中は読まずに nil、読めない場所も nil")
    func unknownWhenProtectedOrUnreadable() throws {
        let (temporary, root) = try folder("probe-protected")
        _ = try temporary.directory("root/sub")
        #expect(DirectoryProbe.hasSubdirectory(at: root, protectedPrefixes: [root.path]) == nil)
        #expect(DirectoryProbe.hasSubdirectory(at: root.appendingPathComponent("sub"), protectedPrefixes: [root.path]) == nil)
        // 名前の前方一致だけで保護下と見なさない。
        #expect(!DirectoryProbe.isPrivacyProtected(URL(fileURLWithPath: root.path + "2"), prefixes: [root.path]))
        #expect(DirectoryProbe.hasSubdirectory(at: root.appendingPathComponent("missing"), protectedPrefixes: []) == nil)
    }

    @Test("既定の保護下の一覧に、デスクトップ・書類・ダウンロードと ~/Library の他アプリのデータが入っている")
    func defaultPrefixes() {
        let home = FileBrowserListing.realHomeDirectory()
        for name in ["Desktop", "Documents", "Downloads", "Library/Containers", "Library/Mobile Documents"] {
            #expect(DirectoryProbe.isPrivacyProtected(home.appendingPathComponent(name)))
        }
        #expect(!DirectoryProbe.isPrivacyProtected(home))
    }
}

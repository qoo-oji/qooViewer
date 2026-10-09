import Foundation
import Testing

@testable import qooViewer

/// ツリーが見張るフォルダと、FSEvents のパスの読み替え(Models/FileBrowserTreeWatchPlan.swift)と、「フォルダへ移動…」で打った
/// パスをディスク上の書き方に直すこと(`FileBrowserListing.onDiskSpelling`)。2026-10-10、「サブフォルダを右と同じ順に並べる」の
/// 左右のずれの残っていた穴。
struct FileBrowserTreeWatchPlanTests {
    private func root(_ row: String, resolved: String, others: Set<String> = []) -> FileBrowserTreeWatchPlan.RootSpellings {
        FileBrowserTreeWatchPlan.RootSpellings(
            rowPath: row, resolvedPath: resolved, otherSpellings: others.union(resolved == row ? [] : [resolved])
        )
    }

    @Test("記号リンクを含む根の下の行へ、リンクを解いた知らせのパスを読み替えて当てる(同じ実体を別の根でも出していれば両方)")
    func eventPathsAreTranslatedToRowsUnderLinkedRoots() {
        let plan = FileBrowserTreeWatchPlan.make(
            rows: ["/vol-v", "/vol-v/real/Shelf", "/vol-v/link/Shelf"],
            roots: [
                root("/vol-v", resolved: "/vol-v"),
                root("/vol-v/link/Shelf", resolved: "/vol-v/real/Shelf"),
            ]
        )
        #expect(plan.rowPaths(forEventPath: "/vol-v/real/Shelf/Alpha/f.txt")
            == ["/vol-v/real/Shelf/Alpha/f.txt", "/vol-v/link/Shelf/Alpha/f.txt"])
        #expect(plan.rowPaths(forEventPath: "/vol-v/real/Shelf") == ["/vol-v/real/Shelf", "/vol-v/link/Shelf"])
        // 頭が文字列として重なるだけの別のフォルダには当てない。
        #expect(plan.rowPaths(forEventPath: "/vol-v/real/Shelf2/x") == ["/vol-v/real/Shelf2/x"])
        #expect(plan.watchedPaths == ["/vol-v"])
    }

    @Test("見張るフォルダの重なりは、リンクを解いたパスで判定する(文字列では配下でも、別のボリュームを指すリンクは見張る)")
    func watchedPathsAreDedupedByResolvedPath() {
        let plan = FileBrowserTreeWatchPlan.make(
            rows: ["/vol-a", "/vol-a/sub", "/vol-a/link/x", "/vol-a/link/x/y"],
            roots: [
                root("/vol-a", resolved: "/vol-a"),
                root("/vol-a/link/x", resolved: "/vol-b/x"),
            ]
        )
        #expect(plan.watchedPaths == ["/vol-a", "/vol-b/x"])
        #expect(plan.rowPaths(forEventPath: "/vol-b/x/y/z") == ["/vol-b/x/y/z", "/vol-a/link/x/y/z"])
    }

    @Test("根の書き方は、リンクを解いたパスと /private の付いた形を持つ(ディスクで調べる)")
    func rootSpellingsResolveLinksOnDisk() throws {
        let temporary = try TemporaryDirectory("tree-watch-spellings")
        let real = try temporary.directory("real/Shelf")
        let link = temporary.file("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: temporary.file("real"))
        let rowPath = FileBrowserState.id(for: link.appendingPathComponent("Shelf", isDirectory: true))
        let spellings = FileBrowserTreeWatchPlan.RootSpellings.make(rowPath: rowPath)
        let realPath = FileBrowserState.id(for: real)
        #expect(MountTable.normalized(URL(filePath: spellings.resolvedPath).resolvingSymlinksInPath().path)
            == MountTable.normalized(URL(filePath: realPath).resolvingSymlinksInPath().path))
        #expect(!spellings.otherSpellings.contains(rowPath))
        // 知らせは実体のパス(`/private` 付きのことがある)で来る。どちらの書き方でも行へ読み替えられる。
        let plan = FileBrowserTreeWatchPlan.make(rows: [rowPath], roots: [spellings])
        #expect(plan.rowPaths(forEventPath: realPath + "/Alpha").contains(rowPath + "/Alpha"))
    }

    @Test("打ったパスの大小文字と Unicode の正規化をディスク上の名前に直す。記号リンクは解かず、無い階層は打ったまま")
    func typedPathsTakeTheOnDiskSpelling() throws {
        let temporary = try TemporaryDirectory("on-disk-spelling")
        let decomposed = "がぎ".decomposedStringWithCanonicalMapping
        let actual = try temporary.directory("MixedCase/\(decomposed)")
        try FileManager.default.createSymbolicLink(at: temporary.file("Lnk"), withDestinationURL: temporary.file("MixedCase"))

        let typed = temporary.url.appendingPathComponent("mixedcase/\("がぎ".precomposedStringWithCanonicalMapping)", isDirectory: true)
        // 大小文字を区別するボリュームでは打ったパスが無い(このテストの前提が成り立たない)。
        guard FileManager.default.fileExists(atPath: typed.path) else { return }
        #expect(FileBrowserListing.onDiskSpelling(of: typed).path == actual.path)
        #expect(Array(FileBrowserListing.onDiskSpelling(of: typed).lastPathComponent.unicodeScalars)
            == Array(decomposed.unicodeScalars))

        let throughLink = temporary.url.appendingPathComponent("lnk/\(decomposed)", isDirectory: true)
        #expect(FileBrowserListing.onDiskSpelling(of: throughLink).path
            == temporary.url.appendingPathComponent("Lnk/\(decomposed)").path)

        // 大小文字・正規化のほかは書き方を変えない。`standardizedFileURL` を通すと実在するパスの頭の `/private` が外れた
        // (CI で発覚。サンドボックスの中の作業フォルダは `/private` を含まないので、手元では上の検査だけでは素通りした)。
        #expect(FileBrowserListing.onDiskSpelling(of: URL(filePath: "/private/var", directoryHint: .isDirectory)).path == "/private/var")

        let missing = temporary.url.appendingPathComponent("mixedcase/NoSuchFolder", isDirectory: true)
        #expect(FileBrowserListing.onDiskSpelling(of: missing).path
            == temporary.url.appendingPathComponent("MixedCase/NoSuchFolder").path)
    }
}

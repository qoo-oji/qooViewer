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

    /// ネットワーク上のボリュームを 1 つ持つマウント表(実際にはマウントしない。マウント表は文字列で引くだけ)。
    private static let remoteMountPoint = "/Volumes/qooViewer-test-remote-share"
    private static let mountsWithRemoteShare = MountTable(entries: [
        .init(mountPoint: "/", mountedFrom: "/dev/disk-test", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
        .init(mountPoint: remoteMountPoint, mountedFrom: "//test@server/share", fileSystemType: "smbfs",
              isLocal: false, isHiddenFromBrowsing: false),
    ])

    @Test("リンクの先がネットワーク上のボリュームに入る根は、そこへ触れずに見張れない根にし、配下の行を見張らない")
    func rootsLinkingIntoRemoteVolumesAreNotWatched() throws {
        // 2026-10-10 の監査の 1: `resolvingSymlinksInPath` はリンクの先の共有へ問い合わせ、応答しない共有では塞がった。
        let temporary = try TemporaryDirectory("tree-watch-remote-link")
        let local = try temporary.directory("local")
        let link = temporary.file("nas")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: Self.remoteMountPoint + "/share")
        let linkedRow = FileBrowserState.id(for: link.appendingPathComponent("Shelf", isDirectory: true))
        let localRow = FileBrowserState.id(for: local)

        #expect(FileBrowserTreeWatchPlan.resolvedWithoutTouchingRemoteVolumes(linkedRow, mountTable: Self.mountsWithRemoteShare) == nil)
        #expect(FileBrowserTreeWatchPlan.resolvedWithoutTouchingRemoteVolumes(Self.remoteMountPoint + "/x", mountTable: Self.mountsWithRemoteShare) == nil)
        let linked = FileBrowserTreeWatchPlan.RootSpellings.make(rowPath: linkedRow, mountTable: Self.mountsWithRemoteShare)
        #expect(!linked.isWatchable)
        let plain = FileBrowserTreeWatchPlan.RootSpellings.make(rowPath: localRow, mountTable: Self.mountsWithRemoteShare)
        #expect(plain.isWatchable)

        let plan = FileBrowserTreeWatchPlan.make(
            rows: [linkedRow, linkedRow + "/Alpha", localRow], roots: [linked, plain], mountTable: Self.mountsWithRemoteShare
        )
        #expect(plan.watchedPaths.count == 1)
        #expect(!plan.watchedPaths.contains { $0.hasPrefix(Self.remoteMountPoint) || $0.hasPrefix(linkedRow) })
        #expect(plan.aliases.allSatisfy { $0.rowPrefix != linkedRow })
    }

    @Test("循環するリンクの根は見張らない。無い階層から先は書かれたまま")
    func loopsAndMissingComponents() throws {
        let temporary = try TemporaryDirectory("tree-watch-loop")
        try FileManager.default.createSymbolicLink(atPath: temporary.file("a").path, withDestinationPath: temporary.file("b").path)
        try FileManager.default.createSymbolicLink(atPath: temporary.file("b").path, withDestinationPath: temporary.file("a").path)
        let mounts = MountTable.current()
        #expect(FileBrowserTreeWatchPlan.resolvedWithoutTouchingRemoteVolumes(temporary.file("a").path + "/x", mountTable: mounts) == nil)
        #expect(!FileBrowserTreeWatchPlan.RootSpellings.make(rowPath: temporary.file("a").path, mountTable: mounts).isWatchable)

        let missing = temporary.file("no-such/deeper").path
        let resolved = try #require(FileBrowserTreeWatchPlan.resolvedWithoutTouchingRemoteVolumes(missing, mountTable: mounts))
        #expect(resolved.hasSuffix("/no-such/deeper"))
    }

    @Test("書き方を調べている最中の根の配下は見張らず、見張れる浅い根の配下の行はそのまま見張る。解いたパスがネットワーク上なら外す")
    func pendingRootsAndRemotePathsAreLeftOut() {
        let plan = FileBrowserTreeWatchPlan.make(
            rows: ["/vol-a", "/vol-a/sub", "/vol-a/fav", "/vol-a/fav/x"],
            roots: [root("/vol-a", resolved: "/vol-a")],
            pendingRoots: ["/vol-a/fav"]
        )
        #expect(plan.watchedPaths == ["/vol-a"])
        // /vol-a の行が無ければ、調べている根の配下は 1 つも見張らない。
        let pendingOnly = FileBrowserTreeWatchPlan.make(rows: ["/vol-a/fav", "/vol-a/fav/x"], roots: [], pendingRoots: ["/vol-a/fav"])
        #expect(pendingOnly.watchedPaths.isEmpty)

        let afterMount = FileBrowserTreeWatchPlan.make(
            rows: ["/vol-a/link"], roots: [root("/vol-a/link", resolved: Self.remoteMountPoint + "/share")],
            mountTable: Self.mountsWithRemoteShare
        )
        #expect(afterMount.watchedPaths.isEmpty)
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

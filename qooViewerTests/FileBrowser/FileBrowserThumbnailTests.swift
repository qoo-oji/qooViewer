import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// ファイルブラウザのアイコン表示の絵(段階 7a。Services/FileBrowserThumbnails/)。
///
/// 絵の中身は `PageImageFactory` の番号(R = ページ番号)で確かめる。キャッシュは一時フォルダのもの、提供役は
/// テストの中で作る(実物の `FileBrowserThumbnailDiskCache.shared` と AppStores の提供役には触らない)。
@MainActor
struct FileBrowserThumbnailTests {
    // MARK: - 種類

    @Test("名前で種類を決める。パッケージは作らない(アプリケーションだけはアイコンを描く)。記号リンク・エイリアスは先のアイコン")
    func kindByName() {
        func kind(_ name: String, folder: Bool = false, package: Bool = false, link: Bool = false, alias: Bool = false) -> BookThumbnailer.Kind? {
            BookThumbnailer.kind(forName: name, isNavigableFolder: folder, isPackage: package, isSymbolicLink: link, isAliasFile: alias)
        }
        #expect(kind("a.JPG") == .image)
        #expect(kind("a.cbz") == .archive)
        #expect(kind("a.cb7") == .archive)
        #expect(kind("a.rar") == .archive)
        #expect(kind("a.epub") == .epub)
        #expect(kind("a.pdf") == .pdf)
        #expect(kind("chapter", folder: true) == .folder)
        #expect(kind("a.txt") == nil)
        #expect(kind("Some.app", package: true) == .application)
        #expect(kind("Some.APP", package: true) == .application)
        // 記号リンクの .app は先のアプリのアイコン(バッジ付き)。
        #expect(kind("Some.app", package: true, link: true) == .alias)
        #expect(kind("Some.bundle", package: true) == nil)
        // パッケージでない「.app」という名前のフォルダは、ふつうのフォルダ。
        #expect(kind("Some.app", folder: true) == .folder)
        // 記号リンク・エイリアスは中の絵ではなく先のアイコン(名前に関わらず)。
        #expect(kind("a.jpg", link: true) == .alias)
        #expect(kind("no-extension", link: true) == .alias)
        #expect(kind("book.cbz alias", alias: true) == .alias)
        #expect(kind("folder", folder: true, link: true) == .alias)
    }

    @Test("フォルダはネットワーク越しと保護下の場所では作らない。デスクトップ等の中を見ているときの同じ場所の中は作る")
    func folderKindRespectsProtectedLocations() {
        let desktop = "/Users/someone/Desktop"
        let support = "/Users/someone/Library/Application Support"
        let prefixes = [desktop, support]
        let categories: Set<String> = [desktop]
        func folder(_ path: String) -> FileBrowserEntry {
            FileBrowserEntry(
                url: URL(fileURLWithPath: path, isDirectory: true), displayName: "", isDirectory: true, isPackage: false,
                isSymbolicLink: false, isVolume: false, fileSize: nil, typeDescription: nil, creationDate: nil,
                modificationDate: nil
            )
        }
        func kind(_ entry: FileBrowserEntry, in current: String, mountTable: MountTable = MountTable(entries: [])) -> BookThumbnailer.Kind? {
            FileBrowserThumbnailProvider.kind(
                for: entry, currentFolder: URL(fileURLWithPath: current, isDirectory: true), mountTable: mountTable,
                protectedPrefixes: prefixes, categoryPrefixes: categories
            )
        }
        // ホームを見ているときのデスクトップそのもの → 中を読むと TCC の確認が出るので作らない。
        #expect(kind(folder(desktop), in: "/Users/someone") == nil)
        // デスクトップの中を見ているときの、その中のフォルダ → 許可は済んでいる。
        #expect(kind(folder(desktop + "/Book"), in: desktop) == .folder)
        // Application Support の中は、中を見ていても作らない(アプリごとに確認が出うる)。
        #expect(kind(folder(support + "/Other"), in: support) == nil)
        // 保護下でない場所。
        #expect(kind(folder("/opt/Book"), in: "/opt") == .folder)
        // ネットワーク越し。
        let remote = MountTable(entries: [
            .init(mountPoint: "/", mountedFrom: "disk", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/Share", mountedFrom: "//server/share", fileSystemType: "smbfs", isLocal: false, isHiddenFromBrowsing: false),
        ])
        // (パスの検査が `/Volumes/<名前>/<名前>` を蔵書の置き場として止めるので、共有の根そのものを見る。)
        #expect(kind(folder("/Volumes/Share"), in: "/Volumes", mountTable: remote) == nil)
    }

    @Test("アプリケーションのアイコンは頼んだ画素数の正方形に描き、フォルダと同じくネットワーク越しでは読まない")
    func applicationIcon() async throws {
        // 実在するアプリ(システムに必ずある Finder)。**描くだけで、何も書かない。**
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
        let pixels = try #require(await FileIO.perform { FileBrowserSystemIcon.render(at: finder, pixelSize: 64) })
        #expect(pixels.width == 64 && pixels.height == 64)
        let appEntry = FileBrowserEntry(
            url: finder, displayName: "Finder", isDirectory: true, isPackage: true, isSymbolicLink: false, isVolume: false,
            fileSize: nil, typeDescription: nil, creationDate: nil, modificationDate: nil
        )
        let temporary = try TemporaryDirectory("thumb-app")
        let provider = FileBrowserThumbnailProvider(diskCache: FileBrowserThumbnailDiskCache(directory: temporary.file("cache")))
        let viaProvider = try #require(await provider.thumbnail(for: appEntry, kind: .application, pixelSize: 128))
        #expect(viaProvider.width == 128)

        let remote = MountTable(entries: [
            .init(mountPoint: "/", mountedFrom: "disk", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
            .init(mountPoint: "/net/share", mountedFrom: "//server/share", fileSystemType: "smbfs", isLocal: false, isHiddenFromBrowsing: false),
        ])
        let remoteApp = FileBrowserEntry(
            url: URL(fileURLWithPath: "/net/share/Tool.app", isDirectory: true), displayName: "Tool", isDirectory: true,
            isPackage: true, isSymbolicLink: false, isVolume: false, fileSize: nil, typeDescription: nil, creationDate: nil,
            modificationDate: nil
        )
        #expect(FileBrowserThumbnailProvider.kind(for: remoteApp, currentFolder: nil, mountTable: remote) == nil)
        #expect(FileBrowserThumbnailProvider.kind(for: appEntry, currentFolder: nil, mountTable: remote) == .application)
    }

    // MARK: - 記号リンク・エイリアス(2026-09-29)

    // 既定引数(nonisolated な文脈)から参照するので nonisolated(CI の Xcode 26.6 はエラー、2026-09-29)。
    private nonisolated static let localOnly = MountTable(entries: [
        .init(mountPoint: "/", mountedFrom: "disk", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
    ])

    @Test("記号リンクの先は readlink の字面で決める(相対・絶対・..)。先には触らない")
    func symbolicLinkTargetIsLexical() {
        let link = URL(fileURLWithPath: "/opt/books/link")
        #expect(FileBrowserLinkResolver.symbolicLinkTarget("book.cbz", linkAt: link).path == "/opt/books/book.cbz")
        #expect(FileBrowserLinkResolver.symbolicLinkTarget("../other/./book.cbz", linkAt: link).path == "/opt/other/book.cbz")
        #expect(FileBrowserLinkResolver.symbolicLinkTarget("/Applications/Some.app", linkAt: link).path == "/Applications/Some.app")
        #expect(FileBrowserLinkResolver.symbolicLinkTarget("../../../..", linkAt: link).path == "/")
    }

    @Test("先を読んでよい場所の規則: ネットワーク越し・繋がっていないボリューム・保護下は読まない。同じ保護下の中を見ているときだけ読む")
    func aliasTargetRespectsUnenteredPlaces() throws {
        let temporary = try TemporaryDirectory("thumb-alias-rule")
        let folder = try temporary.directory("root")
        let target = try temporary.directory("elsewhere/Book")
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let desktop = "/Users/someone/Desktop"
        let support = "/Users/someone/Library/Application Support"
        let prefixes = [desktop, support]
        let categories: Set<String> = [desktop]
        func resolved(_ url: URL, from current: URL?, mountTable: MountTable = Self.localOnly) -> URL? {
            FileBrowserLinkResolver.backgroundTarget(
                of: url, currentFolder: current, mountTable: mountTable, protectedPrefixes: prefixes, categoryPrefixes: categories
            )
        }
        // 保護下でない場所の先。
        #expect(resolved(link, from: folder)?.path == target.path)
        let remote = MountTable(entries: [
            .init(mountPoint: "/", mountedFrom: "disk", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/Share", mountedFrom: "//server/share", fileSystemType: "smbfs", isLocal: false, isHiddenFromBrowsing: false),
        ])
        let toShare = folder.appendingPathComponent("to-share")
        // (パスの検査が `/Volumes/<名前>/<名前>` を蔵書の置き場として止めるので、共有の根そのものを指す。)
        try FileManager.default.createSymbolicLink(atPath: toShare.path, withDestinationPath: "/Volumes/Share")
        #expect(resolved(toShare, from: folder, mountTable: remote) == nil)
        // 繋がっていないボリュームの先(readlink は通るが、その先を stat すると自動マウントや 30 秒の待ちになりうる)。
        let toGone = folder.appendingPathComponent("to-gone")
        try FileManager.default.createSymbolicLink(atPath: toGone.path, withDestinationPath: "/Volumes/Gone")
        #expect(resolved(toGone, from: folder) == nil)
        // デスクトップの中の先は、デスクトップの中を見ているときだけ。Application Support の中は見ていても読まない。
        let toDesktop = folder.appendingPathComponent("to-desktop")
        try FileManager.default.createSymbolicLink(atPath: toDesktop.path, withDestinationPath: desktop + "/Book")
        #expect(resolved(toDesktop, from: folder) == nil)
        #expect(resolved(toDesktop, from: URL(fileURLWithPath: desktop, isDirectory: true))?.path == desktop + "/Book")
        let toSupport = folder.appendingPathComponent("to-support")
        try FileManager.default.createSymbolicLink(atPath: toSupport.path, withDestinationPath: support + "/Book")
        #expect(resolved(toSupport, from: URL(fileURLWithPath: support, isDirectory: true)) == nil)
        // 記号リンクでもエイリアスでもないファイル。
        let plain = folder.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: plain)
        #expect(resolved(plain, from: folder) == nil)

        // 途中の記号リンクも追う(レビュー 2026-09-29): ローカルのリンクを経由して共有へ向く先は、字面はローカルでも断る。
        let hop = folder.appendingPathComponent("hop")
        try FileManager.default.createSymbolicLink(atPath: hop.path, withDestinationPath: "/Volumes/Share")
        let viaHop = folder.appendingPathComponent("via-hop")
        try FileManager.default.createSymbolicLink(atPath: viaHop.path, withDestinationPath: "hop/Book")
        #expect(resolved(viaHop, from: folder, mountTable: remote) == nil)
        // 途中のリンクがローカルのフォルダへ向くなら、解いた先(記号リンクの無い絶対パス)になる。
        let hopLocal = folder.appendingPathComponent("hop-local")
        try FileManager.default.createSymbolicLink(at: hopLocal, withDestinationURL: temporary.file("elsewhere"))
        let viaLocal = folder.appendingPathComponent("via-local")
        try FileManager.default.createSymbolicLink(atPath: viaLocal.path, withDestinationPath: "hop-local/Book")
        #expect(resolved(viaLocal, from: folder)?.path == target.path)
        // ループは諦める。無い先は字面のまま(先が無いだけ)。
        let loopA = folder.appendingPathComponent("loop-a")
        let loopB = folder.appendingPathComponent("loop-b")
        try FileManager.default.createSymbolicLink(atPath: loopA.path, withDestinationPath: "loop-b")
        try FileManager.default.createSymbolicLink(atPath: loopB.path, withDestinationPath: "loop-a")
        #expect(resolved(loopA, from: folder) == nil)
        let dangling = folder.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/opt/nothing/here")
        #expect(resolved(dangling, from: folder)?.path == "/opt/nothing/here")

        // 「場所の規則で断った」と「決められない」は別の結果(レビュー 2026-09-29: リストのアイコンは前者だけをボリュームの着脱まで覚える。
        // 区別しないと、先が一時的に無いエイリアスがこの起動の間ずっと種類のアイコンのままになる)。
        func outcome(_ url: URL, mountTable: MountTable = Self.localOnly) -> FileBrowserLinkResolver.Outcome {
            FileBrowserLinkResolver.backgroundOutcome(
                of: url, currentFolder: folder, mountTable: mountTable, protectedPrefixes: prefixes, categoryPrefixes: categories
            )
        }
        #expect(outcome(toShare, mountTable: remote) == .refused)
        #expect(outcome(toGone) == .refused)
        #expect(outcome(toDesktop) == .refused)
        #expect(outcome(viaHop, mountTable: remote) == .refused)
        #expect(outcome(loopA) == .unresolvable)
        #expect(outcome(plain) == .unresolvable)
        // 記録されたパスに何も無く、ブックマークでも追えないエイリアス(先を消した)は決められない。先が戻れば決まる。
        let moving = try temporary.directory("elsewhere/Moving")
        let aliasFile = folder.appendingPathComponent("moving alias")
        try URL.writeBookmarkData(
            try moving.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil),
            to: aliasFile
        )
        #expect(outcome(aliasFile) == .target(moving))
        try FileManager.default.removeItem(at: moving)
        #expect(outcome(aliasFile) == .unresolvable)
        try FileManager.default.createDirectory(at: moving, withIntermediateDirectories: false)
        #expect(outcome(aliasFile) == .target(moving))
    }

    @Test("利用者の操作の解決は場所を選ばない: アプリへのリンクはパッケージとして、無い先は exists = false で返る")
    func openingResolutionGoesAnywhere() throws {
        let temporary = try TemporaryDirectory("thumb-alias-opening")
        let folder = try temporary.directory("root")
        let toFinder = folder.appendingPathComponent("to-finder")
        try FileManager.default.createSymbolicLink(
            at: toFinder, withDestinationURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
        )
        let finder = try #require(FileBrowserLinkResolver.openingTargetInfo(of: toFinder))
        #expect(finder.exists && finder.isDirectory && finder.isPackage)
        #expect(!finder.entry.isNavigableFolder)
        let dangling = folder.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/opt/nothing/here")
        let missing = try #require(FileBrowserLinkResolver.openingTargetInfo(of: dangling))
        #expect(!missing.exists && missing.url.path == "/opt/nothing/here")
        // 記号リンクでもエイリアスでもないものは nil。
        let plain = folder.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: plain)
        #expect(FileBrowserLinkResolver.openingTargetInfo(of: plain) == nil)
    }

    @Test("エイリアスの先は記録されたパス。先が動いていたらブックマークを解いて追う。一覧はエイリアスに印を付ける")
    func aliasFileTarget() throws {
        let temporary = try TemporaryDirectory("thumb-alias-file")
        let folder = try temporary.directory("root")
        let target = folder.appendingPathComponent("book.cbz")
        try Data("zip".utf8).write(to: target)
        let alias = folder.appendingPathComponent("book alias")
        let data = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: alias)

        let entries = try FileBrowserListing.entries(in: folder)
        let aliasEntry = try #require(entries.first { $0.url.lastPathComponent == "book alias" })
        #expect(aliasEntry.isAliasFile && !aliasEntry.isSymbolicLink)
        let bookEntry = try #require(entries.first { $0.url.lastPathComponent == "book.cbz" })
        #expect(!bookEntry.isAliasFile)
        #expect(FileBrowserThumbnailProvider.kind(for: aliasEntry, currentFolder: folder, mountTable: Self.localOnly) == .alias)

        func resolved() -> URL? {
            FileBrowserLinkResolver.backgroundTarget(of: alias, currentFolder: folder, mountTable: Self.localOnly, protectedPrefixes: [])
        }
        #expect(resolved()?.path == target.path)
        // 先を同じボリュームの中で動かす → 記録されたパスには無いので、ブックマークで追う。
        let moved = try temporary.directory("moved").appendingPathComponent("book.cbz")
        try FileManager.default.moveItem(at: target, to: moved)
        #expect(resolved()?.path == moved.path)

        // 記号リンク → エイリアス → 本、も先まで追う(レビュー 2026-09-29)。輪は諦める。
        let linkToAlias = folder.appendingPathComponent("link-to-alias")
        try FileManager.default.createSymbolicLink(at: linkToAlias, withDestinationURL: alias)
        #expect(FileBrowserLinkResolver.backgroundTarget(
            of: linkToAlias, currentFolder: folder, mountTable: Self.localOnly, protectedPrefixes: []
        )?.path == moved.path)
        let loopA = folder.appendingPathComponent("alias-a")
        let loopB = folder.appendingPathComponent("alias-b")
        try Data("placeholder".utf8).write(to: loopA)
        try URL.writeBookmarkData(try loopA.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil), to: loopB)
        try URL.writeBookmarkData(try loopB.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil), to: loopA)
        #expect(FileBrowserLinkResolver.backgroundTarget(
            of: loopA, currentFolder: folder, mountTable: Self.localOnly, protectedPrefixes: []
        ) == nil)
    }

    @Test("記号リンク・エイリアスのアイコンは先のアイコンを頼んだ画素数の正方形に描く。ネットワーク越しのリンクは種類のまま")
    func aliasIcon() async throws {
        let temporary = try TemporaryDirectory("thumb-alias-icon")
        let folder = try temporary.directory("root")
        let link = folder.appendingPathComponent("finder")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
        )
        let mountTable = MountTable.current()
        let outcome = await FileIO.perform {
            FileBrowserSystemIcon.renderAlias(at: link, currentFolder: folder, mountTable: mountTable, pixelSize: 64, protectedPrefixes: [])
        }
        guard case .made(let pixels) = outcome else {
            Issue.record("先のアイコンが描けなかった: \(outcome)")
            return
        }
        #expect(pixels.width == 64 && pixels.height == 64)
        // 場所の規則で断ったものは「作れなかった」とは別(失敗として覚えない)。
        let toShare = folder.appendingPathComponent("to-share")
        try FileManager.default.createSymbolicLink(atPath: toShare.path, withDestinationPath: "/Volumes/Share")
        let remoteTable = MountTable(entries: [
            .init(mountPoint: "/", mountedFrom: "disk", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/Share", mountedFrom: "//server/share", fileSystemType: "smbfs", isLocal: false, isHiddenFromBrowsing: false),
        ])
        let refused = await FileIO.perform {
            FileBrowserSystemIcon.renderAlias(at: toShare, currentFolder: folder, mountTable: remoteTable, pixelSize: 64, protectedPrefixes: [])
        }
        guard case .refused = refused else {
            Issue.record("共有の先を断らなかった: \(refused)")
            return
        }
        // バッジの絵(システムのバンドルの中)が読める。
        #expect(FileBrowserSystemIcon.aliasBadge() != nil)

        let entry = try #require(try FileBrowserListing.entries(in: folder).first { $0.url.lastPathComponent == "finder" })
        #expect(entry.isSymbolicLink)
        let provider = FileBrowserThumbnailProvider(diskCache: FileBrowserThumbnailDiskCache(directory: temporary.file("cache")))
        let viaProvider = try #require(await provider.thumbnail(for: entry, kind: .alias, pixelSize: 128, currentFolder: folder))
        #expect(viaProvider.width == 128)
        // 先がアプリなら、セルは影無しのアイコンとして描く。
        #expect(provider.aliasTargetKind(for: entry) == .application)
        #expect(provider.cachedThumbnail(for: entry, kind: .alias, pixelSize: 128) != nil)

        let remote = MountTable(entries: [
            .init(mountPoint: "/", mountedFrom: "disk", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
            .init(mountPoint: "/net/share", mountedFrom: "//server/share", fileSystemType: "smbfs", isLocal: false, isHiddenFromBrowsing: false),
        ])
        let remoteLink = FileBrowserEntry(
            url: URL(fileURLWithPath: "/net/share/link"), displayName: "link", isDirectory: false, isPackage: false,
            isSymbolicLink: true, isVolume: false, fileSize: nil, typeDescription: nil, creationDate: nil, modificationDate: nil
        )
        #expect(FileBrowserThumbnailProvider.kind(for: remoteLink, currentFolder: nil, mountTable: remote) == nil)
    }

    @Test("記号リンクの先が本なら、先の項目と同じ絵(1 ページ目)を同じキャッシュで出す。先のアイコンではない")
    func aliasToBookSharesTheTargetThumbnail() async throws {
        let temporary = try TemporaryDirectory("thumb-alias-book")
        let shelf = try temporary.directory("shelf")
        let links = try temporary.directory("links")
        var zip = ZipFixtureBuilder()
        zip.add("001.png", PageImageFactory.png(number: 1))
        let book = shelf.appendingPathComponent("book.cbz")
        try zip.write(to: book)
        let link = links.appendingPathComponent("to-book")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: book)
        let bookEntry = try entry(book, in: shelf)
        let linkEntry = try entry(link, in: links)
        #expect(FileBrowserThumbnailProvider.kind(for: linkEntry, currentFolder: links, mountTable: Self.localOnly) == .alias)

        // 一時フォルダはコンテナ(`~/Library/Containers`)の中で既定では保護下なので、規則の一覧は空にする。
        let provider = FileBrowserThumbnailProvider(
            diskCache: FileBrowserThumbnailDiskCache(directory: temporary.file("cache")), protectedPrefixes: [], categoryPrefixes: []
        )
        // まだ解いていない: 同期の当たりは無く、出どころの鍵は自分のもの。
        #expect(provider.cachedThumbnail(for: linkEntry, kind: .alias, pixelSize: 128) == nil)
        #expect(provider.aliasTargetKind(for: linkEntry) == nil)
        let viaLink = try #require(await provider.thumbnail(for: linkEntry, kind: .alias, pixelSize: 128, currentFolder: links))
        #expect(PageColorReader.number(in: try #require(viaLink.makeImage())) == 1)
        #expect(provider.generatedCount == 1)
        #expect(provider.aliasTargetKind(for: linkEntry) == .archive)
        // 先の項目そのものを頼んでも作り直さない(同じ鍵)。逆も同じ。
        _ = try #require(await provider.thumbnail(for: bookEntry, kind: .archive, pixelSize: 128))
        #expect(provider.generatedCount == 1)
        // 解いた後は同期の当たりがあり(ホームへ戻った最初のフレーム)、出どころの鍵は先の鍵になる。
        #expect(provider.cachedThumbnail(for: linkEntry, kind: .alias, pixelSize: 128) != nil)
        #expect(provider.sourceKey(for: linkEntry, kind: .alias) == "alias|" + provider.sourceKey(for: bookEntry, kind: .archive))

        // 先が画像の無いフォルダ: 中の絵は無いので先のアイコン(フォルダ)で出し、セルは影無しのアイコンとして描く。
        let empty = try temporary.directory("shelf/empty")
        let toEmpty = links.appendingPathComponent("to-empty")
        try FileManager.default.createSymbolicLink(at: toEmpty, withDestinationURL: empty)
        let emptyEntry = try entry(toEmpty, in: links)
        let folderIcon = try #require(await provider.thumbnail(for: emptyEntry, kind: .alias, pixelSize: 128, currentFolder: links))
        #expect(folderIcon.width == 128)
        #expect(provider.aliasTargetKind(for: emptyEntry) == .application)
        #expect(provider.cachedThumbnail(for: emptyEntry, kind: .alias, pixelSize: 128) != nil)
    }

    @Test("提供役: 同じリンクを待つセルは束ねて 1 度だけ解き、場所の規則で断られたリンクはボリュームの着脱まで解き直さない(2026-09-29 の監査)")
    func aliasResolutionIsCoalescedAndRefusalsAreRemembered() async throws {
        let temporary = try TemporaryDirectory("thumb-alias-refused")
        let links = try temporary.directory("links")
        // 繋がっていないボリュームの先(実物のマウント表で `/Volumes/<名前>` が無い)。触らずに断られる。
        // (パスの検査が `/Volumes/<名前>/<名前>` を蔵書の置き場として止めるので、ボリュームの根そのものを指す。)
        let toGone = links.appendingPathComponent("to-gone")
        try FileManager.default.createSymbolicLink(atPath: toGone.path, withDestinationPath: "/Volumes/qooViewer-test-not-mounted")
        let goneEntry = try entry(toGone, in: links)
        let provider = FileBrowserThumbnailProvider(
            diskCache: FileBrowserThumbnailDiskCache(directory: temporary.file("cache")), protectedPrefixes: [], categoryPrefixes: []
        )
        // 同時に頼んだ 2 つのセルは 1 つの頼みに束ねる。
        async let first = provider.thumbnail(for: goneEntry, kind: .alias, pixelSize: 128, currentFolder: links)
        async let second = provider.thumbnail(for: goneEntry, kind: .alias, pixelSize: 128, currentFolder: links)
        let results = await [first, second]
        #expect(results.allSatisfy { $0 == nil })
        #expect(provider.aliasResolutionCount == 1)
        // 断られたことを覚えているので、頼み直しても FileIO へは行かない。
        #expect(await provider.thumbnail(for: goneEntry, kind: .alias, pixelSize: 128, currentFolder: links) == nil)
        #expect(provider.aliasResolutionCount == 1)
        // ボリュームの着脱(の代わりに、その口)で忘れ、解き直す。
        provider.forgetRefusedAliasTargets()
        #expect(await provider.thumbnail(for: goneEntry, kind: .alias, pixelSize: 128, currentFolder: links) == nil)
        #expect(provider.aliasResolutionCount == 2)

        // 決められないだけのもの(壊れた記号リンクの輪)は覚えない: 頼むたびに解き直す(先が戻れば決まる)。
        let loopA = links.appendingPathComponent("loop-a")
        let loopB = links.appendingPathComponent("loop-b")
        try FileManager.default.createSymbolicLink(atPath: loopA.path, withDestinationPath: "loop-b")
        try FileManager.default.createSymbolicLink(atPath: loopB.path, withDestinationPath: "loop-a")
        let loopEntry = try entry(loopA, in: links)
        #expect(await provider.thumbnail(for: loopEntry, kind: .alias, pixelSize: 128, currentFolder: links) == nil)
        #expect(await provider.thumbnail(for: loopEntry, kind: .alias, pixelSize: 128, currentFolder: links) == nil)
        #expect(provider.aliasResolutionCount == 4)

        // 取り消されたセルは待たずに nil で戻り、誰も待たなくなった頼みは FileIO へ渡さない。
        let task = Task { await provider.thumbnail(for: goneEntry, kind: .alias, pixelSize: 128, currentFolder: links) }
        task.cancel()
        #expect(await task.value == nil)
        await provider.waitUntilIdle()
    }

    @Test("記号リンクの先の本に表紙の指定があれば、先と同じ表紙になり、指定を変えたら鍵が変わる(本棚と同じ表紙)")
    func aliasToBookFollowsShelfCover() async throws {
        let library = try InMemoryLibrary(label: "thumb-alias-cover")
        defer { library.close() }
        let temporary = try TemporaryDirectory("thumb-alias-cover")
        let shelf = try temporary.directory("shelf")
        let book = try temporary.directory("shelf/book")
        for (index, number) in [UInt8(10), 40, 80].enumerated() {
            try PageImageFactory.png(number: number).write(to: book.appendingPathComponent(String(format: "%03d.png", index + 1)))
        }
        let links = try temporary.directory("links")
        let link = links.appendingPathComponent("to-book")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: book)
        let bookEntry = try entry(book, in: shelf)
        let linkEntry = try entry(link, in: links)
        let provider = FileBrowserThumbnailProvider(
            diskCache: FileBrowserThumbnailDiskCache(directory: temporary.file("cache")), layoutStore: library.layouts,
            protectedPrefixes: [], categoryPrefixes: []
        )
        func number() async throws -> Int? {
            let buffer = try #require(await provider.thumbnail(
                for: linkEntry, kind: .alias, pixelSize: 128, savesToDisk: false, currentFolder: links
            ))
            return PageColorReader.number(in: try #require(buffer.makeImage()))
        }
        #expect(try await number() == 10)
        #expect(provider.aliasTargetKind(for: linkEntry) == .folder)
        let keyBefore = provider.sourceKey(for: linkEntry, kind: .alias)

        let loaded = try await FixtureBook.load(bookEntry.url)
        let third = try #require(loaded.pages.count == 3 ? loaded.pages[2] : nil)
        library.layouts.setShelfCoverPageKey(
            forBookID: bookEntry.id, sourceURL: bookEntry.url, pageKey: third.sortKey, displayName: "003.png"
        )
        let shelfPage = try await number()
        #expect(abs((shelfPage ?? 0) - 80) <= 2, "表紙に指定したページの絵になっていない: \(String(describing: shelfPage))")
        #expect(provider.sourceKey(for: linkEntry, kind: .alias) != keyBefore)
    }

    // MARK: - 先頭の絵の選び方

    @Test("台帳の本: 1 ページ目が書庫の直下のエントリなら、絵に選ぶエントリはそれと同じ", arguments: Fixtures.bookPaths)
    func archiveChoiceMatchesFirstPage(_ relativePath: String) async throws {
        let url = Fixtures.url(relativePath)
        guard isArchiveFile(relativePath) else { return }
        guard let book = try? await FixtureBook.load(url),
              let first = book.pages.first,
              case .archive(let locator, let entryPath) = first.source, !locator.isNested
        else { return }
        let reader = try makeArchiveReader(for: url)
        #expect(try BookThumbnailer.firstImageEntryPath(in: reader) == entryPath)
    }

    @Test("zip: __MACOSX と隠しファイルを外し、正準順(数字は数値として)の先頭を選ぶ")
    func zipPicksCanonicalFirstImage() throws {
        let temporary = try TemporaryDirectory("thumb-zip")
        var zip = ZipFixtureBuilder()
        zip.add("__MACOSX/._001.png", Data("x".utf8))
        zip.add(".hidden/000.png", PageImageFactory.png(number: 9))
        zip.add("010.png", PageImageFactory.png(number: 10))
        zip.add("b/001.png", PageImageFactory.png(number: 11))
        zip.add("2.png", PageImageFactory.png(number: 2))
        zip.add("notes.txt", text: "not a page")
        let url = temporary.file("book.cbz")
        try zip.write(to: url)
        let image = try #require(BookThumbnailer.thumbnail(of: url, kind: .archive, maxPixelSize: 512))
        #expect(PageColorReader.number(in: image) == 2)
    }

    @Test("画像の無い書庫・壊れた書庫は絵を作らない")
    func archiveWithoutImages() throws {
        #expect(BookThumbnailer.thumbnail(of: Fixtures.url("zip/zip-no-images.cbz"), kind: .archive, maxPixelSize: 512) == nil)
        #expect(BookThumbnailer.thumbnail(of: Fixtures.url("zip/zip-not-a-zip.cbz"), kind: .archive, maxPixelSize: 512) == nil)
    }

    @Test("フォルダ: 直下の画像のうち正準順の先頭。隠しファイル・UF_HIDDEN・サブフォルダの中は見ない")
    func folderPicksDirectImages() throws {
        let temporary = try TemporaryDirectory("thumb-folder")
        let folder = try FixtureFolder.make(at: temporary.file("Book"), pages: [
            .init("10.png", number: 10),
            .init("3.jpg", number: 3),
            .init(".0.png", number: 1),
            .init("0-flagged.png", number: 4),
            .init("0-sub/001.png", number: 5),
        ], extraFiles: ["00.txt": "text"])
        #expect(chflags(folder.appendingPathComponent("0-flagged.png").path, UInt32(UF_HIDDEN)) == 0)
        #expect(BookThumbnailer.firstImageFile(inFolder: folder)?.lastPathComponent == "3.jpg")
        let image = try #require(BookThumbnailer.thumbnail(of: folder, kind: .folder, maxPixelSize: 512))
        #expect(abs((PageColorReader.number(in: image) ?? 0) - 3) <= 2)

        let chaptersOnly = try FixtureFolder.make(at: temporary.file("Chapters"), pages: [.init("ch1/001.png", number: 1)])
        #expect(BookThumbnailer.thumbnail(of: chaptersOnly, kind: .folder, maxPixelSize: 512) == nil)
    }

    @Test("EPUB は spine の先頭、PDF は 1 ページ目")
    func epubAndPDF() throws {
        let temporary = try TemporaryDirectory("thumb-docs")
        var epub = EpubFixtureBuilder.pages(3)
        epub.manifestReversed = true
        let epubURL = temporary.file("book.epub")
        try epub.write(to: epubURL)
        let epubImage = try #require(BookThumbnailer.thumbnail(of: epubURL, kind: .epub, maxPixelSize: 512))
        #expect(PageColorReader.number(in: epubImage) == 1)

        let pdfURL = temporary.file("book.pdf")
        try PDFFixtureBuilder.write(to: pdfURL, pageNumbers: [7, 8], imageFormat: .png)
        let pdfImage = try #require(BookThumbnailer.thumbnail(of: pdfURL, kind: .pdf, maxPixelSize: 300))
        #expect(abs((PageColorReader.number(in: pdfImage) ?? 0) - 7) <= 2)
        // 長辺が要求の大きさになる(PDF はページの pt より大きく描ける)。
        #expect(max(pdfImage.width, pdfImage.height) == 300)
    }

    @Test("画像は長辺を縮めて読む。小さい画像は拡大しない")
    func imageDownsampling() throws {
        let temporary = try TemporaryDirectory("thumb-image")
        let url = temporary.file("page.png")
        try PageImageFactory.png(number: 5).write(to: url)
        let image = try #require(BookThumbnailer.thumbnail(of: url, kind: .image, maxPixelSize: 512))
        #expect(image.width == PageImageFactory.width)
        #expect(PageColorReader.number(in: image) == 5)
    }

    @Test("JPEG にするとき透明な地は白になる")
    func jpegFlattensTransparencyOnWhite() throws {
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 4, height: 4))
        let transparent = try #require(context.makeImage())
        let jpeg = try #require(FileBrowserThumbnailProvider.jpegData(from: transparent))
        #expect((PageColorReader.number(in: jpeg) ?? 0) > 245)
    }

    // MARK: - 鍵とディスクキャッシュ

    @Test("鍵は名前を変えても同じ、中身(サイズ・更新日時)が変わると別")
    func keyFollowsContentNotName() throws {
        let temporary = try TemporaryDirectory("thumb-key")
        let url = temporary.file("a.png")
        try PageImageFactory.png(number: 1).write(to: url)
        let table = MountTable.current()
        let original = try #require(FileBrowserThumbnailKey.of(url, mountTable: table))
        let renamed = temporary.file("b.png")
        try FileManager.default.moveItem(at: url, to: renamed)
        #expect(FileBrowserThumbnailKey.of(renamed, mountTable: table) == original)
        try PageImageFactory.png(number: 1, wide: true).write(to: renamed)
        let rewritten = try #require(FileBrowserThumbnailKey.of(renamed, mountTable: table))
        #expect(rewritten != original)
        #expect(rewritten.fileName != original.fileName)
    }

    @Test("ディスクキャッシュ: 書いて読める、無効なら読まない・書かない、無効にすると消える")
    func diskCacheRoundTripAndDisable() async throws {
        let temporary = try TemporaryDirectory("thumb-disk")
        let directory = temporary.file("cache")
        let cache = FileBrowserThumbnailDiskCache(directory: directory)
        let key = FileBrowserThumbnailKey(volume: "v", inode: 1, modified: 2, size: 3)
        let data = PageImageFactory.jpeg(number: 4)
        await cache.store(data, for: key)
        #expect(await cache.data(for: key) == data)
        // 使用量はディスクの上で確保された量(DiskFootprint)なので、ブロック単位に切り上がる。
        #expect(await cache.totalBytes() >= data.count)

        await cache.configure(isEnabled: false, maxTotalBytes: 1024 * 1024, generation: 1)
        #expect(await cache.data(for: key) == nil)
        // 削除は裏で走るので、消えるまで少し待つ。
        for _ in 0..<100 where FileManager.default.fileExists(atPath: directory.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await cache.store(data, for: key)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        // 古い世代の設定は捨てる。
        await cache.configure(isEnabled: true, maxTotalBytes: 1024 * 1024, generation: 1)
        #expect(await cache.isEnabled == false)
    }

    // MARK: - 提供役

    private func entry(_ url: URL, in folder: URL) throws -> FileBrowserEntry {
        try #require(FileBrowserListing.entries(in: folder).first { $0.url.lastPathComponent == url.lastPathComponent })
    }

    @Test("提供役: 1 回目は作り、2 回目はメモリ、別の提供役でもディスクから読む(作り直さない)")
    func providerCachesInMemoryAndOnDisk() async throws {
        let temporary = try TemporaryDirectory("thumb-provider")
        let folder = try temporary.directory("shelf")
        var zip = ZipFixtureBuilder()
        zip.add("001.png", PageImageFactory.png(number: 1))
        let url = folder.appendingPathComponent("book.cbz")
        try zip.write(to: url)
        let bookEntry = try entry(url, in: folder)
        let disk = FileBrowserThumbnailDiskCache(directory: temporary.file("cache"))

        let provider = FileBrowserThumbnailProvider(diskCache: disk)
        let first = try #require(await provider.thumbnail(for: bookEntry, kind: .archive, pixelSize: 128))
        #expect(provider.generatedCount == 1)
        #expect(PageColorReader.number(in: try #require(first.makeImage())) == 1)
        _ = await provider.thumbnail(for: bookEntry, kind: .archive, pixelSize: 128)
        #expect(provider.generatedCount == 1)

        let another = FileBrowserThumbnailProvider(diskCache: disk)
        let fromDisk = try #require(await another.thumbnail(for: bookEntry, kind: .archive, pixelSize: 256))
        #expect(another.generatedCount == 0)
        #expect(abs((PageColorReader.number(in: try #require(fromDisk.makeImage())) ?? 0) - 1) <= 2)
    }

    @Test("提供役: 鍵を渡せば項目を読みに行かずにディスクの絵を返す(スマートライブラリの保存した一覧。項目が見えなくても出る)")
    func providerUsesAKnownKeyWithoutTouchingTheItem() async throws {
        let temporary = try TemporaryDirectory("thumb-known-key")
        let folder = try temporary.directory("shelf")
        var zip = ZipFixtureBuilder()
        zip.add("001.png", PageImageFactory.png(number: 1))
        let url = folder.appendingPathComponent("book.cbz")
        try zip.write(to: url)
        let bookEntry = try entry(url, in: folder)
        let key = try #require(FileBrowserThumbnailKey.of(url, mountTable: MountTable.current()))
        let disk = FileBrowserThumbnailDiskCache(directory: temporary.file("cache"))
        _ = try #require(await FileBrowserThumbnailProvider(diskCache: disk).thumbnail(for: bookEntry, kind: .archive, pixelSize: 128))

        // 本が見えなくなっても(ネットワークが切れた・外した)、鍵があればディスクの絵が出る。鍵が無ければ作れない。
        try FileManager.default.removeItem(at: url)
        let withKey = FileBrowserThumbnailProvider(diskCache: disk)
        #expect(await withKey.thumbnail(for: bookEntry, kind: .archive, pixelSize: 128, knownKey: key) != nil)
        #expect(withKey.generatedCount == 0)
        #expect(await FileBrowserThumbnailProvider(diskCache: disk).thumbnail(for: bookEntry, kind: .archive, pixelSize: 128) == nil)
    }

    @Test("提供役: コレクションに入っていない本でも、コレクション表紙の指定(ページ・画像)を絵に使い、指定を変えたら頼み直させる")
    func providerUsesShelfCoverOverrideForUnregisteredBooks() async throws {
        let library = try InMemoryLibrary(label: "thumb-shelf-cover")
        defer { library.close() }
        let temporary = try TemporaryDirectory("thumb-shelf-cover")
        let shelf = try temporary.directory("shelf")
        let book = try temporary.directory("shelf/book")
        // 番号を離しておく(JPEG を通った絵の番号は少しずれうるので、隣り合う番号だと見分けられない)。
        for (index, number) in [UInt8(10), 40, 80].enumerated() {
            try PageImageFactory.png(number: number).write(to: book.appendingPathComponent(String(format: "%03d.png", index + 1)))
        }
        let bookEntry = try entry(book, in: shelf)
        let provider = FileBrowserThumbnailProvider(
            diskCache: FileBrowserThumbnailDiskCache(directory: temporary.file("cache")), layoutStore: library.layouts
        )
        // 共有のページ一覧キャッシュへ書かないよう、シークレットウインドウの頼みで取る(テストは共有の状態に触らない)。
        func number(pixelSize: CGFloat = 128) async throws -> Int? {
            let buffer = try #require(await provider.thumbnail(
                for: bookEntry, kind: .folder, pixelSize: pixelSize, savesToDisk: false
            ))
            return PageColorReader.number(in: try #require(buffer.makeImage()))
        }

        // 指定が無ければ先頭の絵。
        #expect(try await number() == 10)

        // ページを指定。キーはメタデータの編集のページ選びと同じく、読み込んだ本のページから取る。
        let loaded = try await FixtureBook.load(bookEntry.url)
        let third = try #require(loaded.pages.count == 3 ? loaded.pages[2] : nil)
        let revisionBefore = provider.revision
        library.layouts.setShelfCoverPageKey(
            forBookID: bookEntry.id, sourceURL: bookEntry.url, pageKey: third.sortKey, displayName: "003.png"
        )
        #expect(provider.revision != revisionBefore)
        // 作った絵は JPEG を通るので、色の番号は少しずれうる(ディスクキャッシュのテストと同じ許容)。
        let shelfPage = try await number()
        #expect(abs((shelfPage ?? 0) - 80) <= 2, "表紙に指定したページの絵になっていない: \(String(describing: shelfPage))")

        // 画像を指定 → 保管庫の画像。本は読まない(作った回数が増えない)。
        let image = temporary.file("cover.png")
        try PageImageFactory.png(number: 9).write(to: image)
        let generated = provider.generatedCount
        try await library.layouts.setShelfCoverImage(forBookID: bookEntry.id, sourceURL: bookEntry.url, fileURL: image)
        #expect(try await number(pixelSize: 256) == 9)
        #expect(provider.generatedCount == generated)

        // 既定へ戻すと先頭の絵(メモリに残っているので作り直さない)。
        library.layouts.clearShelfCover(forBookID: bookEntry.id)
        #expect(try await number() == 10)
        #expect(provider.generatedCount == generated)
    }

    @Test("提供役: シークレットウインドウの頼み(savesToDisk: false)で作った絵はディスクへ書かない。ディスクの絵は読む")
    func providerDoesNotWriteToDiskForPrivateWindows() async throws {
        let temporary = try TemporaryDirectory("thumb-private")
        let folder = try temporary.directory("shelf")
        var zip = ZipFixtureBuilder()
        zip.add("001.png", PageImageFactory.png(number: 1))
        let url = folder.appendingPathComponent("book.cbz")
        try zip.write(to: url)
        let bookEntry = try entry(url, in: folder)
        let disk = FileBrowserThumbnailDiskCache(directory: temporary.file("cache"))
        let key = try #require(FileBrowserThumbnailKey.of(url, mountTable: MountTable.current()))

        let privateProvider = FileBrowserThumbnailProvider(diskCache: disk)
        #expect(await privateProvider.thumbnail(for: bookEntry, kind: .archive, pixelSize: 128, savesToDisk: false) != nil)
        #expect(privateProvider.generatedCount == 1)
        #expect(await disk.contains(key) == false)

        // 通常ウインドウの頼みは書く。
        let normalProvider = FileBrowserThumbnailProvider(diskCache: disk)
        #expect(await normalProvider.thumbnail(for: bookEntry, kind: .archive, pixelSize: 128) != nil)
        #expect(await disk.contains(key))

        // シークレットウインドウでも、ディスクにある絵は読む(作り直さない)。
        let anotherPrivate = FileBrowserThumbnailProvider(diskCache: disk)
        #expect(await anotherPrivate.thumbnail(for: bookEntry, kind: .archive, pixelSize: 256, savesToDisk: false) != nil)
        #expect(anotherPrivate.generatedCount == 0)
    }

    @Test("提供役: 作れなかった絵は覚えて作り直さない。中身が変われば試し直す")
    func providerRemembersFailures() async throws {
        let temporary = try TemporaryDirectory("thumb-failure")
        let folder = try temporary.directory("shelf")
        var zip = ZipFixtureBuilder()
        zip.add("notes.txt", text: "no pages")
        let url = folder.appendingPathComponent("book.cbz")
        try zip.write(to: url)
        let provider = FileBrowserThumbnailProvider(diskCache: FileBrowserThumbnailDiskCache(directory: temporary.file("cache")))

        #expect(await provider.thumbnail(for: try entry(url, in: folder), kind: .archive, pixelSize: 128) == nil)
        #expect(await provider.thumbnail(for: try entry(url, in: folder), kind: .archive, pixelSize: 256) == nil)
        #expect(provider.generatedCount == 1)

        var fixed = ZipFixtureBuilder()
        fixed.add("notes.txt", text: "now with a page")
        fixed.add("001.png", PageImageFactory.png(number: 1))
        try fixed.write(to: url)
        #expect(await provider.thumbnail(for: try entry(url, in: folder), kind: .archive, pixelSize: 128) != nil)
        #expect(provider.generatedCount == 2)
    }

    @Test("提供役: 同じ絵を同時に頼まれても 1 回だけ作る。取り消されたセルには nil が返る")
    func providerDeduplicatesAndHonorsCancellation() async throws {
        let temporary = try TemporaryDirectory("thumb-dedupe")
        let folder = try temporary.directory("shelf")
        for index in 1...8 {
            var zip = ZipFixtureBuilder()
            zip.add("001.png", PageImageFactory.png(number: UInt8(index)))
            try zip.write(to: folder.appendingPathComponent("book\(index).cbz"))
        }
        let entries = try FileBrowserListing.entries(in: folder)
        let provider = FileBrowserThumbnailProvider(diskCache: FileBrowserThumbnailDiskCache(directory: temporary.file("cache")))
        let target = try #require(entries.first)

        async let a = provider.thumbnail(for: target, kind: .archive, pixelSize: 128)
        async let b = provider.thumbnail(for: target, kind: .archive, pixelSize: 128)
        let results = await [a, b]
        #expect(results.allSatisfy { $0 != nil })
        #expect(provider.generatedCount == 1)

        // 同時に 4 件までしか走らないので、後ろに並んだ仕事を取り消すと始まる前に捨てられる。
        let tasks = entries.dropFirst().map { entry in
            Task { await provider.thumbnail(for: entry, kind: .archive, pixelSize: 128) }
        }
        tasks.forEach { $0.cancel() }
        for task in tasks {
            #expect(await task.value == nil)
        }
        await provider.waitUntilIdle()
        #expect(provider.generatedCount < entries.count)
    }

    // MARK: - 監査の手当て(2026-09-14)

    @Test("書庫のエントリは伸長しながら上限を数え、超えた時点で読むのをやめる(宣言サイズを偽った伸長爆弾)")
    func entryLimitIsCountedWhileInflating() throws {
        // 宣言サイズを答えない(= 偽る)reader。1KB ずつ 100 回渡そうとする。
        let liar = StreamingReader(chunk: Data(count: 1024), chunkCount: 100)
        #expect(BookThumbnailer.boundedEntryData("a.png", in: liar, maxByteCount: 4096) == nil)
        #expect(liar.deliveredChunks == 5, "上限を超えた 5 回目で止まり、残りを伸長しない")
        let honest = StreamingReader(chunk: Data(count: 1024), chunkCount: 4)
        #expect(BookThumbnailer.boundedEntryData("a.png", in: honest, maxByteCount: 4096)?.count == 4096)

        // 本物の zip でも、上限は宣言と実際の両方で効く。
        let temporary = try TemporaryDirectory("thumb-bounded")
        var zip = ZipFixtureBuilder()
        zip.add("1.png", PageImageFactory.png(number: 1))
        let url = temporary.file("book.cbz")
        try zip.write(to: url)
        let reader = try ZipArchiveReader(url: url)
        let size = PageImageFactory.png(number: 1).count
        #expect(BookThumbnailer.boundedEntryData("1.png", in: reader, maxByteCount: Int64(size))?.count == size)
        #expect(BookThumbnailer.boundedEntryData("1.png", in: reader, maxByteCount: Int64(size - 1)) == nil)
    }

    @Test("書庫の順で先頭の画像より前にある量が上限を超えたら読まない。zip は見ない(2 回目の監査 21)")
    func entriesBeforeTheFirstImageAreBounded() throws {
        // ソリッドの 7z / rar は、先頭の画像を読むために前のエントリを全部伸長する。
        let reader = OrderedReader(entries: [("big.bin", 300), ("notes/", 0), ("001.png", 10), ("002.png", 10)])
        #expect(BookThumbnailer.readsTooMuchBefore("001.png", in: reader, limit: 299))
        #expect(!BookThumbnailer.readsTooMuchBefore("001.png", in: reader, limit: 300))
        #expect(!BookThumbnailer.readsTooMuchBefore("big.bin", in: reader, limit: 0), "先頭なら 0")

        let temporary = try TemporaryDirectory("thumb-before")
        var zip = ZipFixtureBuilder()
        zip.add("a.bin", Data(count: 4096))
        zip.add("1.png", PageImageFactory.png(number: 1))
        let url = temporary.file("book.cbz")
        try zip.write(to: url)
        #expect(!BookThumbnailer.readsTooMuchBefore("1.png", in: try ZipArchiveReader(url: url), limit: 0))
    }

    @Test("間引いて読めない形式の巨大な画像は一覧の絵にしない。JPEG・PNG は同じ大きさでも作る(2 回目の監査 24)")
    func hugeImagesThatCannotBeSubsampledAreSkipped() throws {
        // 16000² の無圧縮 BMP の縮小は約 2GB を確保した(PNG / TIFF / HEIC は数十 MB)。ヘッダーの寸法だけで決めるので、中身は小さくてよい。
        let bmp = Self.bmpHeader(width: 8000, height: 8000)
        #expect(ImageDecoder.decode(bmp, maxPixelSize: 128, maxFullDecodePixelCount: BookThumbnailer.maxFullDecodePixelCount) == nil)
        let small = Self.bmpHeader(width: 2, height: 2) + Data(count: 16)
        #expect(ImageDecoder.decode(small, maxPixelSize: 128, maxFullDecodePixelCount: BookThumbnailer.maxFullDecodePixelCount) != nil)
        let png = PageImageFactory.png(number: 1)
        #expect(ImageDecoder.decode(png, maxPixelSize: 128, maxFullDecodePixelCount: 1) != nil, "PNG は間引いて読むので上限を掛けない")
    }

    /// 32bpp・無圧縮の BMP の見出し(画素の中身は付けない)。
    private static func bmpHeader(width: Int32, height: Int32) -> Data {
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let pixelBytes = UInt32(clamping: Int64(width) * Int64(height) * 4)
        data.append(contentsOf: [0x42, 0x4D])
        append(UInt32(54).addingReportingOverflow(pixelBytes).partialValue.littleEndian)
        append(UInt32(0))
        append(UInt32(54).littleEndian)
        append(UInt32(40).littleEndian)
        append(width.littleEndian)
        append(height.littleEndian)
        append(UInt16(1).littleEndian)
        append(UInt16(32).littleEndian)
        append(UInt32(0))
        append(pixelBytes.littleEndian)
        append(Int32(2835).littleEndian)
        append(Int32(2835).littleEndian)
        append(UInt32(0))
        append(UInt32(0))
        return data
    }

    @Test("追い出されたファイルを落としてこない方針は、読み取りの間だけこのスレッドに掛かり、終わると元へ戻る")
    func datalessPolicyIsScopedToTheRead() async {
        let observed = await FileIO.perform { () -> (before: Int32, inside: Int32, after: Int32) in
            let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            let inside = DatalessFiles.withoutDownloading {
                getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            }
            let after = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            return (before, inside, after)
        }
        // サンドボックスの中(テストホスト)でも掛けられる。
        #expect(observed.inside == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        #expect(observed.after == observed.before)
        // 手元にある普通のファイルは「追い出された」ではない。
        #expect(!DatalessFiles.isDataless(Fixtures.url("zip/zip-no-images.cbz")))
    }

    @Test("PDF の箱: 無限・NaN・巨大・0 の箱は描く大きさの計算に使わない(Int への換算でトラップしない)")
    func unusablePDFBoxes() {
        #expect(CGRect(x: 0, y: 0, width: 595, height: 842).hasUsablePDFPageSize)
        #expect(!CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 842).hasUsablePDFPageSize)
        #expect(!CGRect(x: 0, y: 0, width: CGFloat.nan, height: 842).hasUsablePDFPageSize)
        #expect(!CGRect(x: 0, y: 0, width: 1e30, height: 842).hasUsablePDFPageSize)
        #expect(!CGRect(x: CGFloat.infinity, y: 0, width: 595, height: 842).hasUsablePDFPageSize)
        #expect(!CGRect(x: 0, y: 0, width: 0, height: 842).hasUsablePDFPageSize)
    }

    @Test("EPUB の絵は spine の先頭 1 ページで止める(残りの XHTML を読まない)")
    func epubStopsAtTheFirstPage() throws {
        let temporary = try TemporaryDirectory("thumb-epub-first")
        let url = temporary.file("book.epub")
        try EpubFixtureBuilder.pages(5).write(to: url)
        let reader = try ZipArchiveReader(url: url)
        #expect(try EpubStructureResolver.resolve(reader: reader, maxPages: 1).pages.count == 1)
        #expect(try EpubStructureResolver.resolve(reader: reader).pages.count == 5)
    }

    @Test("段: 表示の大きさの 2 倍を超えるいちばん小さい段")
    func pixelTiers() {
        #expect(FileBrowserThumbnailProvider.pixelTier(forDisplaySize: 48) == 128)
        #expect(FileBrowserThumbnailProvider.pixelTier(forDisplaySize: 64) == 128)
        #expect(FileBrowserThumbnailProvider.pixelTier(forDisplaySize: 96) == 256)
        #expect(FileBrowserThumbnailProvider.pixelTier(forDisplaySize: 256) == 512)
    }
}

/// 宣言サイズを答えず、決まった数のチャンクを渡す reader(伸長しながら数える上限のテスト)。
private nonisolated final class StreamingReader: ArchiveReading, @unchecked Sendable {
    let chunk: Data
    let chunkCount: Int
    private(set) var deliveredChunks = 0

    init(chunk: Data, chunkCount: Int) {
        self.chunk = chunk
        self.chunkCount = chunkCount
    }

    func listFilePaths() throws -> [String] { ["a.png"] }
    func data(at path: String) throws -> Data { Data(repeating: 0, count: chunk.count * chunkCount) }
    func entryDates(at path: String) -> (created: Date?, modified: Date?) { (nil, nil) }
    func entriesInArchiveOrder() throws -> [ArchiveEntryDescriptor] { [] }
    func readEntry(at path: String, _ body: (Data) throws -> Void) throws {
        for _ in 0..<chunkCount {
            deliveredChunks += 1
            try body(chunk)
        }
    }
}

/// 書庫の順とエントリの大きさだけを答える reader(先頭の画像より前の量の判定)。
private nonisolated final class OrderedReader: ArchiveReading, @unchecked Sendable {
    let entries: [(path: String, size: UInt64)]

    init(entries: [(path: String, size: UInt64)]) {
        self.entries = entries
    }

    func listFilePaths() throws -> [String] { entries.filter { !$0.path.hasSuffix("/") }.map(\.path) }
    func data(at path: String) throws -> Data { Data() }
    func entryDates(at path: String) -> (created: Date?, modified: Date?) { (nil, nil) }
    func entriesInArchiveOrder() throws -> [ArchiveEntryDescriptor] {
        entries.map { ArchiveEntryDescriptor(path: $0.path, kind: $0.path.hasSuffix("/") ? .directory : .file, uncompressedSize: $0.size, modified: nil) }
    }
    func readEntry(at path: String, _ body: (Data) throws -> Void) throws {}
}

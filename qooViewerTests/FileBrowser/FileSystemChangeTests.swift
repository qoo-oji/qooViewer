import AppKit
import Combine
import Foundation
import Testing

@testable import qooViewer

/// アプリ自身がファイルを動かした知らせ(Services/FileOperations/FileSystemChange.swift、2026-09-19 の監査)。
///
/// 見るのは (1) 知らせの中身の読み方、(2) エンジン(`FileOperationService`)が済んだ分を漏れなく知らせること、
/// (3) ファイルブラウザの状態が、別のウインドウの操作で読み直す・表示中のフォルダの名前の変更に付いていくこと。
/// 状態はどれも `activate` しない(FSEvents を張らない)ので、読み直しは知らせだけが起こす。ただし読み直すのは
/// 「見えている」状態だけなので、`makeVisibleWithoutWatching` で見えていることにする。
@MainActor
struct FileSystemChangeTests {
    // MARK: 知らせの中身

    @Test("移った先のパスは、起きた順に当てはめる。祖先が移っていれば配下も移る")
    func relocatedPathFollowsChainsAndAncestors() {
        let change = FileSystemChange(relocations: [
            .init(from: URL(fileURLWithPath: "/v/a"), to: URL(fileURLWithPath: "/v/b")),
            .init(from: URL(fileURLWithPath: "/v/b"), to: URL(fileURLWithPath: "/w/c")),
        ])
        #expect(change.relocatedPath(for: "/v/a") == "/w/c")
        #expect(change.relocatedPath(for: "/v/a/inner/book.zip") == "/w/c/inner/book.zip")
        #expect(change.relocatedPath(for: "/v/ab") == nil, "名前の途中までしか一致しないパスを動かした")
        #expect(change.relocatedPath(for: "/v/other") == nil)
        #expect(change.displaces("/v/a/inner"))
        #expect(!change.displaces("/w/c"))
    }

    @Test("読み直すのは、直下が変わった・直下のフォルダの中身が変わった・自身か祖先が無くなったフォルダだけ")
    func requiresReloadCoversChildrenGrandchildrenAndDisplacement() {
        let change = FileSystemChange(
            removed: [URL(fileURLWithPath: "/v/gone")], created: [URL(fileURLWithPath: "/v/shelf/sub/new.zip")]
        )
        #expect(change.requiresReload(ofFolderAt: "/v/shelf/sub"), "直下にできた")
        #expect(change.requiresReload(ofFolderAt: "/v/shelf"), "直下のフォルダの変更日が変わった")
        #expect(!change.requiresReload(ofFolderAt: "/v/shelf/other"))
        #expect(change.requiresReload(ofFolderAt: "/v"), "直下の項目が消えた")
        #expect(change.requiresReload(ofFolderAt: "/v/gone/inner"), "祖先が消えた")
        #expect(!change.requiresReload(ofFolderAt: "/elsewhere"))
    }

    @Test("箱は続けて届いた知らせを起きた順のまま 1 つにまとめて配る")
    func centerCoalescesInOrder() {
        let center = FileSystemChangeCenter()
        var received: [FileSystemChange] = []
        let subscription = center.changes.sink { received.append($0) }
        defer { subscription.cancel() }
        let a = URL(fileURLWithPath: "/v/a"), b = URL(fileURLWithPath: "/v/b"), c = URL(fileURLWithPath: "/v/c")
        center.report(FileSystemChange(relocations: [.init(from: a, to: b)]))
        center.report(FileSystemChange(relocations: [.init(from: b, to: c)]))
        center.report(FileSystemChange())
        center.flush()
        center.flush()
        #expect(received.count == 1)
        #expect(received.first?.relocatedPath(for: "/v/a") == "/v/c")
    }

    // MARK: エンジン

    @Test("エンジンは、済んだ操作を種類ごとに知らせる(作った・移した・名前を変えた・ゴミ箱へ送った・戻した)")
    func serviceReportsEveryKindOfChange() async throws {
        let temporary = try TemporaryDirectory("fs-change-service")
        let root = try temporary.directory("root")
        let other = try temporary.directory("other")
        let trash = try temporary.directory("PseudoTrash")
        let file = root.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        let center = FileSystemChangeCenter()
        var received = FileSystemChange()
        let subscription = center.changes.sink { received.merge($0) }
        defer { subscription.cancel() }
        let service = FileOperationService(environment: .pseudoTrash(at: trash), changeObserver: { center.report($0) })

        let folder = try await service.createDirectory(at: root.appendingPathComponent("made", isDirectory: true))
        let copied = try await service.copy([file], to: other)
        let renamed = try await service.rename(file, to: "b.txt")
        let moved = try await service.move([renamed.renamed], to: folder)
        let trashed = try await service.trash([try #require(copied.receipts.first).destination])
        let restored = await service.restoreFromTrash(trashed.receipts)
        center.flush()

        #expect(received.created.map(\.path) == [folder.path, other.appendingPathComponent("a.txt").path, other.appendingPathComponent("a.txt").path])
        #expect(restored.restored.count == 1)
        #expect(received.removed.map(\.path) == [other.appendingPathComponent("a.txt").path])
        let finalPath = try #require(moved.receipts.first).destination.path
        #expect(received.relocatedPath(for: file.path) == finalPath)
        #expect(received.relocations.count == 2)
    }

    @Test("早い除外(mayAffect)は祖先を辿って、移った元・消えた項目の配下だけを拾う(2026-09-23 の 3 回目の監査の低)")
    func mayAffectFollowsAncestors() {
        let change = FileSystemChange(
            relocations: [.init(from: URL(fileURLWithPath: "/V/A"), to: URL(fileURLWithPath: "/V/B"))],
            removed: [URL(fileURLWithPath: "/V/Gone/")]
        )
        let displaced = change.displacedPathSet
        #expect(FileSystemChange.mayAffect("/V/A", displaced: displaced))
        #expect(FileSystemChange.mayAffect("/V/A/book.cbz", displaced: displaced))
        #expect(FileSystemChange.mayAffect("/V/Gone/x/y.zip", displaced: displaced))
        #expect(!FileSystemChange.mayAffect("/V/AB/book.cbz", displaced: displaced))
        #expect(!FileSystemChange.mayAffect("/V", displaced: displaced))
        #expect(!FileSystemChange.mayAffect("/", displaced: displaced))
        #expect(!FileSystemChange.mayAffect("/V/A", displaced: []))
    }

    @Test("「置き換える」で移した・写した行き先は、replaced として知らせる(保存データの付け替え役が古い本の分を消すため)")
    func serviceReportsReplacedDestinations() async throws {
        let temporary = try TemporaryDirectory("fs-change-replace")
        let source = try temporary.directory("source")
        let destination = try temporary.directory("destination")
        let trash = try temporary.directory("PseudoTrash")
        for folder in [source, destination] { try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt")) }
        try Data("b".utf8).write(to: source.appendingPathComponent("b.txt"))
        let center = FileSystemChangeCenter()
        var received = FileSystemChange()
        let subscription = center.changes.sink { received.merge($0) }
        defer { subscription.cancel() }
        let service = FileOperationService(environment: .pseudoTrash(at: trash), changeObserver: { center.report($0) })

        _ = try await service.move([source.appendingPathComponent("a.txt"), source.appendingPathComponent("b.txt")],
                                   to: destination, options: FileOperationOptions(conflictPolicy: .replace))
        center.flush()

        #expect(received.replaced.map(\.lastPathComponent) == ["a.txt"], "置き換えなかった b.txt まで replaced に入った")
        #expect(received.relocations.count == 2)
        // ゴミ箱へ行った置き換えられた項目は、行き先 → ゴミ箱の中として知らせる(保存データはそこへ付いていく。中 1)。
        let intoTrash = try #require(received.replacedIntoTrash.first)
        #expect(received.replacedIntoTrash.count == 1)
        #expect(intoTrash.from == destination.appendingPathComponent("a.txt"))
        #expect(MountTable.path(BookExistenceProbe.comparablePath(intoTrash.to.path), isAtOrUnder: BookExistenceProbe.comparablePath(trash.path)))
    }

    // MARK: ファイルブラウザの状態

    @Test("別のウインドウの操作で、同じフォルダを表示している一覧も読み直す(FSEvents が無くても)")
    func anotherWindowsOperationReloadsThisList() async throws {
        let fixture = try Fixture("fs-change-windows")
        let a = fixture.makeState()
        let b = fixture.makeState()
        a.navigate(to: fixture.root)
        b.navigate(to: fixture.root)
        await a.settle()
        await b.settle()
        b.makeVisibleWithoutWatching()
        #expect(b.entries.map(\.url.lastPathComponent) == ["inner", "a.txt"])

        let target = try #require(a.entries.first { $0.url.lastPathComponent == "a.txt" })
        await a.operations.moveToTrash([target]).value
        await b.settle()
        #expect(b.entries.map(\.url.lastPathComponent) == ["inner"], "別のウインドウの一覧にゴミ箱へ送った項目が残った")

        // 取り消しで戻っても同じ。
        await a.operations.undo().value
        await b.settle()
        #expect(b.entries.map(\.url.lastPathComponent) == ["inner", "a.txt"])
    }

    @Test("表示中のフォルダの祖先の名前が変わったら、退避せずに付いていく。戻るの履歴も付け替える")
    func theDisplayedFolderFollowsARenamedAncestor() async throws {
        // 監査の M1: FSEvents は祖先の変化を知らせないので、以前はもう無いフォルダの一覧を出し続けた。
        let fixture = try Fixture("fs-change-follow")
        let a = fixture.makeState()
        let b = fixture.makeState()
        a.navigate(to: fixture.root)
        await a.settle()
        b.navigate(to: fixture.inner)
        b.navigate(to: fixture.leaf)
        await b.settle()
        b.makeVisibleWithoutWatching()

        let target = try #require(a.entries.first { $0.url.lastPathComponent == "inner" })
        await a.operations.rename(target, to: "renamed").value
        await b.settle()

        let renamedLeaf = fixture.root.appendingPathComponent("renamed/leaf")
        #expect(b.currentFolder?.path == renamedLeaf.path)
        #expect(b.loadError == nil)
        #expect(b.entries.map(\.url.lastPathComponent) == ["x.txt"])
        b.goBack()
        await b.settle()
        #expect(b.currentFolder?.path == fixture.root.appendingPathComponent("renamed").path, "戻るの履歴が古いパスのまま")
    }

    @Test("カットの記憶はアプリで 1 つ: 別のウインドウでペーストしても移動になり、どちらの一覧の淡色も下りる")
    func cutInOneWindowMovesWhenPastedInAnother() async throws {
        // 監査の M2: 以前はウインドウごとの記憶だったので、コピーになって元も先も残り、カットした側は淡色のままだった。
        let fixture = try Fixture("fs-change-cut")
        let a = fixture.makeState()
        let b = fixture.makeState()
        a.navigate(to: fixture.root)
        b.navigate(to: fixture.inner)
        await a.settle()
        await b.settle()
        let target = try #require(a.entries.first { $0.url.lastPathComponent == "a.txt" })
        a.operations.cut([target])
        #expect(a.isCut(target))
        #expect(!b.cutPaths.isEmpty, "別のウインドウにカットが写っていない")

        await b.operations.paste(into: fixture.inner).value
        #expect(!FileManager.default.fileExists(atPath: target.url.path), "移動のつもりがコピーになった")
        #expect(FileManager.default.fileExists(atPath: fixture.inner.appendingPathComponent("a.txt").path))
        #expect(a.cutPaths.isEmpty)
        #expect(b.cutPaths.isEmpty)
    }

    @Test("カットの後でペーストボードがほかで書き換えられたら、確かめ直した時点で淡色を下ろす")
    func cutIsForgottenWhenThePasteboardChanges() async throws {
        let fixture = try Fixture("fs-change-cut-stale")
        let state = fixture.makeState()
        state.navigate(to: fixture.root)
        await state.settle()
        let target = try #require(state.entries.first { $0.url.lastPathComponent == "a.txt" })
        state.operations.cut([target])
        fixture.clipboard.validate(against: fixture.pasteboard)
        #expect(!state.cutPaths.isEmpty, "書き換えられていないのに下ろした")

        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("something else", forType: .string)
        fixture.clipboard.validate(against: fixture.pasteboard)
        #expect(state.cutPaths.isEmpty)
    }

    // MARK: - 部品

    /// 同じ箱と、その箱へ知らせるエンジンを共有する状態を作る。`root/{inner/leaf/x.txt, a.txt}`。
    @MainActor
    final class Fixture {
        let temporary: TemporaryDirectory
        let suite: PreferencesSuite
        let preferences: AppPreferences
        let center = FileSystemChangeCenter()
        let clipboard = FileCutClipboard()
        let pasteboard = NSPasteboard.withUniqueName()
        let service: FileOperationService
        let root: URL
        let inner: URL
        let leaf: URL

        init(_ label: String) throws {
            temporary = try TemporaryDirectory(label)
            suite = PreferencesSuite(label: label)
            preferences = suite.makePreferences()
            preferences.fileBrowserReadOnly = false
            root = try temporary.directory("root")
            inner = try temporary.directory("root/inner")
            leaf = try temporary.directory("root/inner/leaf")
            try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
            try Data("x".utf8).write(to: leaf.appendingPathComponent("x.txt"))
            let center = center
            service = FileOperationService(
                environment: .pseudoTrash(at: try temporary.directory("PseudoTrash")), changeObserver: { center.report($0) }
            )
        }

        func makeState() -> FileBrowserState {
            let state = FileBrowserState(defaults: suite.defaults, changeCenter: center, cutClipboard: clipboard)
            state.preferences = preferences
            state.operations.fileOps = service
            state.operations.pasteboard = pasteboard
            state.operations.presenter = FileBrowserOperationsTests.ScriptedPresenter()
            return state
        }

        deinit {
            pasteboard.releaseGlobally()
        }
    }
}

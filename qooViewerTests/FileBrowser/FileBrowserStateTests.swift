import Foundation
import Testing

@testable import qooViewer

/// ファイルブラウザの閲覧状態(ViewModels/FileBrowserState.swift)。
///
/// 見るのは状態機械 ―― 一覧・並べ替え・絞り込み・戻る/進む/上・世代番号・消えたフォルダの退避・
/// reveal・クリックの選択規則・保存。**画面に出していない**(`activate`を呼ばない)ので、FSEvents の
/// 監視は動かない。読み込みの待ち合わせは`settle()`(テストのための口)。**時間で待たないこと。**
@MainActor
struct FileBrowserStateTests {
    private struct Fixture {
        let temporary: TemporaryDirectory
        let suite: PreferencesSuite
        let preferences: AppPreferences
        let state: FileBrowserState
        /// `root/{b-folder, a-folder/inner}` と `root/{c.txt, B.cbz}`。
        let root: URL
        let aFolder: URL
        let inner: URL
        let bFolder: URL

        init(_ label: String) throws {
            temporary = try TemporaryDirectory(label)
            suite = PreferencesSuite(label: label)
            preferences = suite.makePreferences()
            state = FileBrowserState(defaults: suite.defaults)
            state.preferences = preferences
            root = try temporary.directory("root")
            aFolder = try temporary.directory("root/a-folder")
            inner = try temporary.directory("root/a-folder/inner")
            bFolder = try temporary.directory("root/b-folder")
            try Data(repeating: 1, count: 30).write(to: root.appendingPathComponent("c.txt"))
            try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent("B.cbz"))
        }

        func names() -> [String] { state.entries.map(\.url.lastPathComponent) }

        func id(_ url: URL) -> String { FileBrowserState.id(for: url) }
    }

    // MARK: - 一覧と並べ替え

    @Test("移動すると一覧を読み、フォルダを上にして名前順に並ぶ")
    func navigateListsFoldersFirst() async throws {
        let fixture = try Fixture("fb-list")
        fixture.state.navigate(to: fixture.root)
        await fixture.state.settle()
        #expect(fixture.state.loadError == nil)
        #expect(fixture.names() == ["a-folder", "b-folder", "B.cbz", "c.txt"])
        #expect(FileBrowserState.id(of: fixture.state.currentFolder) == fixture.id(fixture.root))
    }

    @Test("並べ替えの基準と向きを変えると、読み直さずに並べ替わる。「フォルダを上に」を切ると混ざる")
    func sortingReordersInPlace() async throws {
        let fixture = try Fixture("fb-sort")
        fixture.state.navigate(to: fixture.root)
        await fixture.state.settle()

        fixture.state.sortKey = .size
        fixture.state.sortDirection = .descending
        // フォルダはサイズを持たない(nil は小さい側)が、「フォルダを上に」が先に効く。
        #expect(fixture.names() == ["b-folder", "a-folder", "c.txt", "B.cbz"])

        fixture.preferences.fileBrowserFoldersFirst = false
        // 設定の変更は次のランループで反映される(FileBrowserState.observePreferences)。
        await Task.yield()
        for _ in 0..<20 where fixture.names().first != "c.txt" { await Task.yield() }
        #expect(fixture.names() == ["c.txt", "B.cbz", "b-folder", "a-folder"])
    }

    @Test("表示形式・アイコンの大きさ・左の幅・隠した列は保存され、次に作った状態へ引き継がれる")
    func viewSettingsPersist() throws {
        let suite = PreferencesSuite(label: "fb-persist")
        let state = FileBrowserState(defaults: suite.defaults)
        // 既定では作成日の列だけを隠す。
        #expect(state.hiddenListColumns == ["created"])
        #expect(FileBrowserListView.Column.allCases.map(\.rawValue).contains("created"))
        state.viewMode = .icons
        state.iconSize = 150
        state.treeWidth = 300
        state.hiddenListColumns = ["kind", "created"]

        let reopened = FileBrowserState(defaults: suite.defaults)
        #expect(reopened.viewMode == .icons)
        #expect(reopened.iconSize == 150)
        #expect(reopened.treeWidth == 300)
        #expect(reopened.hiddenListColumns == ["kind", "created"])
        // 全部出したことも覚える(空を「保存なし」と取り違えて作成日を隠し直さない)。
        reopened.hiddenListColumns = []
        #expect(FileBrowserState(defaults: suite.defaults).hiddenListColumns.isEmpty)
    }

    @Test("並べ替えの基準と向きはサイドパネルのフォルダブラウザと同じ設定。どちらで変えても両方に効き、他のウインドウも並べ替わる")
    func sortIsSharedWithSidePanel() async throws {
        let fixture = try Fixture("fb-sort-shared")
        fixture.state.navigate(to: fixture.root)
        await fixture.state.settle()

        // ファイルブラウザで変えると、サイドパネルが読む設定が変わる(保存もそちら)。
        fixture.state.sortKey = .size
        fixture.state.sortDirection = .descending
        #expect(fixture.preferences.folderBrowserSortKey == .size)
        #expect(fixture.preferences.folderBrowserSortDirection == .descending)
        #expect(fixture.preferences.folderBrowserSort.key == .size)

        // サイドパネル(や別のウインドウ)で変えると、この一覧も並べ替わる(次のランループ)。
        fixture.preferences.folderBrowserSortKey = .name
        fixture.preferences.folderBrowserSortDirection = .ascending
        #expect(fixture.state.sortKey == .name)
        #expect(fixture.state.sortDirection == .ascending)
        for _ in 0..<20 where fixture.names() != ["a-folder", "b-folder", "B.cbz", "c.txt"] { await Task.yield() }
        #expect(fixture.names() == ["a-folder", "b-folder", "B.cbz", "c.txt"])

        // 同じ設定を見ている 2 つ目のウインドウ。
        let other = FileBrowserState(defaults: fixture.suite.defaults)
        other.preferences = fixture.preferences
        #expect(other.sortKey == .name)
        other.sortDirection = .descending
        #expect(fixture.state.sortDirection == .descending)
        for _ in 0..<20 where fixture.names().first != "b-folder" { await Task.yield() }
        #expect(fixture.names() == ["b-folder", "a-folder", "c.txt", "B.cbz"])
        other.releaseResources()
    }

    @Test("絞り込みは表示だけを絞り、見えなくなった項目を選択から外す。フォルダを移ると空になる")
    func filteringDropsHiddenSelection() async throws {
        let fixture = try Fixture("fb-filter")
        fixture.state.navigate(to: fixture.root)
        await fixture.state.settle()
        fixture.state.selection = [fixture.id(fixture.aFolder), fixture.id(fixture.bFolder)]

        fixture.state.filterText = "b"
        #expect(fixture.names() == ["b-folder", "B.cbz"])
        #expect(fixture.state.selection == [fixture.id(fixture.bFolder)])

        fixture.state.navigate(to: fixture.aFolder)
        #expect(fixture.state.filterText.isEmpty)
        await fixture.state.settle()
        #expect(fixture.names() == ["inner"])
    }

    // MARK: - 移動と履歴

    @Test("上へ移動すると元いたフォルダを選び、戻る/進むで行き来できる")
    func upBackAndForward() async throws {
        let fixture = try Fixture("fb-history")
        let state = fixture.state
        #expect(!state.canGoBack)
        state.navigate(to: fixture.root)
        await state.settle()
        state.navigate(to: fixture.aFolder)
        await state.settle()
        #expect(state.canGoBack)

        state.goUp()
        await state.settle()
        #expect(FileBrowserState.id(of: state.currentFolder) == fixture.id(fixture.root))
        #expect(state.selection == [fixture.id(fixture.aFolder)])
        #expect(state.scrollRequest?.id == fixture.id(fixture.aFolder))

        state.goBack()
        await state.settle()
        #expect(FileBrowserState.id(of: state.currentFolder) == fixture.id(fixture.aFolder))
        #expect(state.canGoForward)

        // 戻り先(root)が直前のフォルダ(a-folder)の親なら、そのフォルダを選ぶ。
        state.goBack()
        await state.settle()
        #expect(FileBrowserState.id(of: state.currentFolder) == fixture.id(fixture.root))
        #expect(state.selection == [fixture.id(fixture.aFolder)])

        state.goForward()
        await state.settle()
        #expect(FileBrowserState.id(of: state.currentFolder) == fixture.id(fixture.aFolder))
    }

    @Test("新しく移動すると、進むの履歴は捨てる")
    func navigatingClearsForward() async throws {
        let fixture = try Fixture("fb-forward")
        let state = fixture.state
        state.navigate(to: fixture.root)
        state.navigate(to: fixture.aFolder)
        state.goBack()
        #expect(state.canGoForward)
        state.navigate(to: fixture.bFolder)
        #expect(!state.canGoForward)
        await state.settle()
    }

    @Test("起動ボリュームの / から上へ行くとコンピュータ(nil)。そこでは上へ行けない")
    func upFromRootReachesComputer() async throws {
        let suite = PreferencesSuite(label: "fb-computer")
        let state = FileBrowserState(defaults: suite.defaults)
        state.navigate(to: URL(fileURLWithPath: "/", isDirectory: true))
        state.goUp()
        #expect(state.currentFolder == nil)
        #expect(!state.canGoUp)
        await state.settle()
        #expect(state.entries.contains { $0.url.path == "/" && $0.isVolume })
    }

    @Test("速く移動したとき、前のフォルダの結果は新しいフォルダの一覧に出ない(世代番号)")
    func staleResultsAreDiscarded() async throws {
        let fixture = try Fixture("fb-generation")
        let state = fixture.state
        state.navigate(to: fixture.root)
        state.navigate(to: fixture.aFolder)
        state.navigate(to: fixture.bFolder)
        await state.settle()
        #expect(FileBrowserState.id(of: state.currentFolder) == fixture.id(fixture.bFolder))
        #expect(state.entries.isEmpty)
        #expect(state.loadError == nil)
    }

    @Test("表示していたフォルダが消えたら、残っているいちばん近い祖先へ移る")
    func vanishedFolderRetreatsToAncestor() async throws {
        let fixture = try Fixture("fb-retreat")
        let state = fixture.state
        state.navigate(to: fixture.inner)
        await state.settle()
        try FileManager.default.removeItem(at: fixture.aFolder)

        state.reload()
        await state.settle()
        #expect(FileBrowserState.id(of: state.currentFolder) == fixture.id(fixture.root))
        #expect(state.loadError == nil)
        #expect(fixture.names() == ["b-folder", "B.cbz", "c.txt"])
    }

    @Test("外での変更で読み直すのは、表示中のフォルダ自身か直下の項目が変わったときだけ(配下の奥の書き込みでは読み直さない)")
    func externalChangesReloadOnlyForTheFolderAndItsDirectChildren() {
        // 2026-09-14 の監査の 4: 以前はパスを見ずに読み直し、ホームを表示している間は ~/Library の下の書き込みで読み直し続けた。
        let spellings = FileBrowserState.watchedFolderSpellings(of: URL(fileURLWithPath: "/Users/nobody", isDirectory: true))
        func touches(_ paths: [String]) -> Bool { FileBrowserState.changedPaths(paths, touchFolderSpelledAs: spellings) }
        #expect(touches(["/Users/nobody/new.cbz"]))
        #expect(touches(["/Users/nobody"]), "フォルダ自身(消えた・名前が変わった)")
        // 頭は定数から組む(`/Volumes/<名前>/<名前>` の形を書くと禁止語の検査が合成名でも止める)。
        #expect(touches([FileBrowserState.dataVolumePrefix + "/Users/nobody/new.cbz"]), "起動ボリュームのデータの頭が付いていても同じ")
        #expect(!touches(["/Users/nobody/Library/Caches/x/cache.db", "/Users/nobody/Library/Preferences/x.plist"]))
        #expect(!touches(["/Users/nobody-other.cbz", "/Users"]), "名前の頭が同じだけの隣")
        #expect(!FileBrowserState.changedPaths(["/Users/nobody/new.cbz"], touchFolderSpelledAs: []), "見張っていなければ読み直さない")
    }

    @Test("FSEvents はリンクを解いたパスで知らせるので、/var の下のフォルダは /private/var の書き方でも一致する")
    func watchedFolderSpellingsIncludeThePrivatePrefix() {
        let spellings = FileBrowserState.watchedFolderSpellings(of: URL(fileURLWithPath: "/var/qooViewer-nonexistent", isDirectory: true))
        #expect(spellings.contains("/var/qooViewer-nonexistent"))
        #expect(spellings.contains("/private/var/qooViewer-nonexistent"))
        #expect(!FileBrowserState.watchedFolderSpellings(of: URL(fileURLWithPath: "/Users/nobody")).contains { $0.hasPrefix("/private") })
    }

    @Test("reveal は入っているフォルダへ移り、その項目を選んでスクロールを頼む")
    func revealSelectsTheItem() async throws {
        let fixture = try Fixture("fb-reveal")
        let state = fixture.state
        state.navigate(to: fixture.bFolder)
        await state.settle()
        let target = fixture.root.appendingPathComponent("c.txt")

        state.reveal(target)
        await state.settle()
        #expect(FileBrowserState.id(of: state.currentFolder) == fixture.id(fixture.root))
        #expect(state.selection == [fixture.id(target)])
        #expect(state.scrollRequest?.id == fixture.id(target))
        #expect(state.canGoBack)
    }

    @Test("読み直しても、残っている項目の選択は保つ")
    func reloadKeepsSurvivingSelection() async throws {
        let fixture = try Fixture("fb-keep")
        let state = fixture.state
        state.navigate(to: fixture.root)
        await state.settle()
        state.selection = [fixture.id(fixture.aFolder), fixture.id(fixture.bFolder)]
        try FileManager.default.removeItem(at: fixture.bFolder)

        state.reload()
        await state.settle()
        #expect(state.selection == [fixture.id(fixture.aFolder)])
    }

    @Test("矢印キーは列数に沿って1件を選び直す。起点は置いた項目")
    func arrowKeysMoveTheSelection() async throws {
        let fixture = try Fixture("fb-arrows")
        let state = fixture.state
        state.navigate(to: fixture.root)
        await state.settle()
        let ids = state.entries.map(\.id)

        state.moveSelection(.right, columns: 2)
        #expect(state.selection == [ids[0]])
        state.moveSelection(.down, columns: 2)
        #expect(state.selection == [ids[2]])
        state.moveSelection(.right, columns: 2)
        #expect(state.selection == [ids[3]])
        state.moveSelection(.up, columns: 2)
        #expect(state.selection == [ids[1]])
        #expect(state.scrollRequest?.id == ids[1])

        // クリックで選んだ項目(アイコン表示が起点を置く)から動く。
        state.selection = [ids[0], ids[3]]
        state.setSelectionAnchor(ids[3])
        state.moveSelection(.left, columns: 2)
        #expect(state.selection == [ids[2]])
    }

    @Test("名前の編集の依頼は、一覧が済ませたら下ろす(別の依頼は残す)。フォルダを移ると捨てる")
    func renameRequestLifecycle() async throws {
        let fixture = try Fixture("fb-rename-request")
        let state = fixture.state
        state.navigate(to: fixture.root)
        await state.settle()
        let ids = state.entries.map(\.id)

        state.requestRename(ids[0])
        let first = try #require(state.renameRequest)
        state.requestRename(ids[1])
        // 古い依頼を済ませても、新しい依頼は下ろさない。
        state.finishRenameRequest(first)
        for _ in 0..<5 { await Task.yield() }
        #expect(state.renameRequest?.id == ids[1])

        let second = try #require(state.renameRequest)
        state.finishRenameRequest(second)
        for _ in 0..<20 where state.renameRequest != nil { await Task.yield() }
        #expect(state.renameRequest == nil)

        state.requestRename(ids[0])
        state.navigate(to: fixture.aFolder)
        #expect(state.renameRequest == nil)
        await state.settle()
    }

    @Test("type-select: 1文字は選択の次から一巡、2文字以上は先頭から、1秒空くと打ち直し、見つからなければそのまま")
    func typeSelectRules() async throws {
        let fixture = try Fixture("fb-typeselect")
        let state = fixture.state
        state.navigate(to: fixture.root)
        await state.settle()
        // a-folder, b-folder, B.cbz, c.txt
        let ids = state.entries.map(\.id)
        let origin = Date(timeIntervalSinceReferenceDate: 1000)

        #expect(state.typeSelect("b", now: origin))
        #expect(state.selection == [ids[1]])
        // 同じ文字の連打は次の同じ頭文字へ(大小文字は区別しない)。
        #expect(state.typeSelect("b", now: origin + 0.3))
        #expect(state.selection == [ids[2]])
        #expect(state.scrollRequest?.id == ids[2])
        // 1秒空いたので "c" から打ち直し。
        #expect(state.typeSelect("c", now: origin + 1.5))
        #expect(state.selection == [ids[3]])
        // 2文字以上は先頭から。
        #expect(state.typeSelect("b", now: origin + 3))
        #expect(state.selection == [ids[1]])
        #expect(state.typeSelect("-", now: origin + 3.2))
        #expect(state.selection == [ids[1]])
        #expect(state.typeSelect("B", now: origin + 5))
        #expect(state.selection == [ids[2]])
        // 見つからなければ選択は変えない。
        #expect(state.typeSelect("x", now: origin + 5.2) == false)
        #expect(state.selection == [ids[2]])
        #expect(state.typeSelect("b", now: origin + 7))
        #expect(state.selection == [ids[1]])
        // "b." は先頭から探して B.cbz。
        #expect(state.typeSelect(".", now: origin + 7.2))
        #expect(state.selection == [ids[2]])
    }

    // MARK: - 起動時のフォルダと保存

    @Test("起動時のフォルダ: ホーム / よく使う項目(無ければホーム) / 最後のフォルダ")
    func startupFolderResolution() async throws {
        let fixture = try Fixture("fb-startup")
        let state = fixture.state
        let favorites = FavoriteLocationStore(defaults: fixture.suite.defaults)
        state.favoriteLocations = favorites
        let home = FileBrowserListing.realHomeDirectory()

        #expect(state.startupFolder()?.path == home.path)

        fixture.preferences.fileBrowserStartupLocation = .favorite
        #expect(state.startupFolder()?.path == home.path)
        let item = favorites.add(fixture.bFolder)
        fixture.preferences.fileBrowserStartupFavoriteID = item.id.uuidString
        #expect(state.startupFolder()?.path == fixture.bFolder.path)
        favorites.remove(id: item.id)
        #expect(state.startupFolder()?.path == home.path)

        fixture.preferences.fileBrowserStartupLocation = .lastFolder
        #expect(state.startupFolder()?.path == home.path)
        state.navigate(to: fixture.aFolder)
        await state.settle()
        let next = FileBrowserState(defaults: fixture.suite.defaults)
        next.preferences = fixture.preferences
        #expect(next.startupFolder()?.path == fixture.aFolder.path)
    }

    @Test("シークレットウインドウでは最後に表示したフォルダを書かない")
    func privateWindowDoesNotRememberTheFolder() async throws {
        let fixture = try Fixture("fb-private")
        fixture.preferences.fileBrowserStartupLocation = .lastFolder
        let state = fixture.state
        state.isPrivate = true
        state.navigate(to: fixture.aFolder)
        await state.settle()

        let next = FileBrowserState(defaults: fixture.suite.defaults)
        next.preferences = fixture.preferences
        #expect(next.startupFolder()?.path == FileBrowserListing.realHomeDirectory().path)
    }
}

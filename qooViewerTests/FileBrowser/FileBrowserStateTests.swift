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

    @Test("ほかの窓・環境設定でフォルダの許可が変わったら、「アクセスを許可…」の案内を出していた一覧を読み直す(2026-10-04 の監査 FBU-5)")
    func aFolderAccessChangeReloadsANeedsAccessListing() async throws {
        let fixture = try Fixture("fb-access")
        let locked = fixture.aFolder
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        fixture.state.navigate(to: locked)
        await fixture.state.settle()
        #expect(fixture.state.loadError == .needsAccess)

        // 読めるようになった(許可が付いた)。以前は、フォルダを移り直すまで案内のままだった。
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        let access = FolderAccessStore(defaults: fixture.suite.defaults)
        fixture.state.folderAccess = access
        let revision = fixture.state.folderAccessRevision
        #expect(access.add(url: fixture.bFolder))
        #expect(fixture.state.folderAccessRevision != revision)
        await fixture.state.settle()
        #expect(fixture.state.loadError == nil)
        #expect(fixture.names() == ["inner"])
    }

    @Test("「隠しファイルを表示」を切り替えると読み直して隠しファイルが出入りし、値は次に作る状態へ引き継がれる")
    func showingHiddenFilesReloadsAndPersists() async throws {
        let fixture = try Fixture("fb-hidden")
        try Data("h".utf8).write(to: fixture.root.appendingPathComponent(".hidden"))
        fixture.state.navigate(to: fixture.root)
        await fixture.state.settle()
        #expect(!fixture.names().contains(".hidden"))

        fixture.state.showsHiddenFiles = true
        await fixture.state.settle()
        #expect(fixture.names().contains(".hidden"))
        #expect(fixture.state.entries.first { $0.url.lastPathComponent == ".hidden" }?.isHidden == true)
        #expect(FileBrowserState(defaults: fixture.suite.defaults).showsHiddenFiles)

        fixture.state.showsHiddenFiles = false
        await fixture.state.settle()
        #expect(!fixture.names().contains(".hidden"))
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

    @Test("選んだ項目は選択と一覧が変わるまで作り直さず、選択の番号は中身が変わったときだけ、別の状態と重ならない値で進む")
    func selectedEntriesFollowSelectionAndEntries() async throws {
        // 4 回目の監査: メニューバーの値を作るたびに全件を絞り込み、選んだ id の配列を作って比べていた。
        let fixture = try Fixture("fb-selected")
        fixture.state.navigate(to: fixture.root)
        await fixture.state.settle()
        let other = FileBrowserState(defaults: fixture.suite.defaults)

        fixture.state.selection = [fixture.id(fixture.aFolder), fixture.id(fixture.bFolder)]
        let revision = fixture.state.selectionRevision
        #expect(revision != 0)
        #expect(fixture.state.selectedEntries.map(\.url.lastPathComponent) == ["a-folder", "b-folder"])
        // 同じ中身を入れ直しても進まない。
        fixture.state.selection = [fixture.id(fixture.bFolder), fixture.id(fixture.aFolder)]
        #expect(fixture.state.selectionRevision == revision)

        // 一覧の並びが変われば、選んだ項目も表示順で作り直す。
        fixture.state.sortDirection = .descending
        #expect(fixture.state.selectedEntries.map(\.url.lastPathComponent) == ["b-folder", "a-folder"])

        fixture.state.selection = [fixture.id(fixture.aFolder)]
        #expect(fixture.state.selectionRevision != revision)
        #expect(fixture.state.selectedEntries.map(\.url.lastPathComponent) == ["a-folder"])

        // 別の状態の選択の番号は、この状態のものと同じ値にならない(メニューバーのサブメニューがウインドウをまたいで使い回されない)。
        other.selection = ["x"]
        #expect(other.selectionRevision != fixture.state.selectionRevision)
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

    @Test("直下のフォルダの中で項目が増減したら読み直す(変更日が変わる)。中身の書き換えだけ・もっと奥では読み直さない。あふれたら上でも下でも読み直す")
    func structuralGrandchildChangesAndOverflowsReload() {
        // 2026-09-19 の監査の L1・L4。
        let spellings: Set<String> = ["/v/shelf"]
        func reloads(_ event: FolderChangeWatcher.Event) -> Bool {
            FileBrowserState.eventsRequireReload([event], ofFolderSpelledAs: spellings)
        }
        typealias Event = FolderChangeWatcher.Event
        #expect(reloads(Event(path: "/v/shelf/sub/new.zip", mustScanSubdirectories: false, isStructuralChange: true)))
        #expect(!reloads(Event(path: "/v/shelf/sub/growing.zip", mustScanSubdirectories: false)), "書き換えだけで読み直した")
        #expect(!reloads(Event(path: "/v/shelf/sub/deep/new.zip", mustScanSubdirectories: false, isStructuralChange: true)))
        #expect(reloads(Event(path: "/v/shelf/a.zip", mustScanSubdirectories: false)))
        #expect(reloads(Event(path: "/v", mustScanSubdirectories: true)), "上であふれた")
        #expect(reloads(Event(path: "/v/shelf/sub/deep", mustScanSubdirectories: true)), "下であふれた")
        #expect(!reloads(Event(path: "/w", mustScanSubdirectories: true)))
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

    @Test("今いるフォルダへ移動し直すと、読み直すだけで選択は残り、戻るの履歴にも積まない(2026-10-04 の監査 FBU-7)")
    func navigatingToTheCurrentFolderKeepsTheSelection() async throws {
        let fixture = try Fixture("fb-same-place")
        let state = fixture.state
        state.navigate(to: fixture.root)
        state.navigate(to: fixture.aFolder)
        state.goBack()
        await state.settle()
        #expect(state.canGoForward)
        state.selection = [fixture.id(fixture.aFolder)]
        // 外で足した項目は、読み直しで一覧に出る(再読み込みとしても効く)。
        try Data(repeating: 1, count: 5).write(to: fixture.root.appendingPathComponent("d.txt"))

        state.navigate(to: fixture.root)
        await state.settle()
        #expect(state.selection == [fixture.id(fixture.aFolder)])
        #expect(fixture.names().contains("d.txt"))
        // 移動ではないので、進むの履歴も捨てない。
        #expect(state.canGoForward)
    }

    @Test("一覧の位置の控えは、控えた後の依頼・選択の変化を見て戻り方を決める(2026-10-04 の監査 FBU-8)")
    func theSavedScrollOriginYieldsToLaterRequestsAndSelections() async throws {
        let fixture = try Fixture("fb-scroll-restore")
        let state = fixture.state
        state.navigate(to: fixture.root)
        await state.settle()
        let origin = CGPoint(x: 0, y: 120)

        // 何も変わっていなければ控えた位置へ。控えは一度使ったら捨てる。
        state.saveScrollOrigin(origin, for: .list, folder: fixture.root)
        #expect(state.takeSavedScrollRestoration(for: .list) == .origin(origin))
        #expect(state.takeSavedScrollRestoration(for: .list) == nil)

        // もう一方の表示でクリックして選び直した → 選んだ項目を見せる。
        state.saveScrollOrigin(origin, for: .list, folder: fixture.root)
        state.selection = [fixture.id(fixture.bFolder)]
        #expect(state.takeSavedScrollRestoration(for: .list) == .reveal(id: fixture.id(fixture.bFolder)))

        // もう一方の表示でスクロールの依頼が出た(矢印キー・reveal)→ 控えは使わず、依頼のほうを拾わせる。
        state.saveScrollOrigin(origin, for: .icons, folder: fixture.root)
        state.reveal(fixture.root.appendingPathComponent("c.txt"))
        await state.settle()
        #expect(state.takeSavedScrollRestoration(for: .icons) == nil)
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

    @Test("⇧矢印は起点から移動先までを選ぶ(Finder・スマートライブラリと同じ。2026-09-27 までは 1 件を選び直していた)")
    func shiftArrowKeysExtendTheSelection() async throws {
        let fixture = try Fixture("fb-shift-arrows")
        let state = fixture.state
        state.navigate(to: fixture.root)
        await state.settle()
        let ids = state.entries.map(\.id)
        #expect(ids.count >= 4)

        state.moveSelection(.right, columns: 2)
        #expect(state.selection == [ids[0]])
        state.moveSelection(.right, columns: 2, extending: true)
        #expect(state.selection == [ids[0], ids[1]])
        state.moveSelection(.down, columns: 2, extending: true)
        #expect(state.selection == Set(ids[0...3]))
        // 伸ばした側を戻すと縮む(起点は最初の項目のまま)。
        state.moveSelection(.up, columns: 2, extending: true)
        #expect(state.selection == [ids[0], ids[1]])
        // ⇧ を離して動けば 1 件に戻る。
        state.moveSelection(.left, columns: 2)
        #expect(state.selection == [ids[0]])
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
        // よく使う項目は登録時に standardizedFileURL でパスをそろえる。サンドボックスの外(CI の署名なしホスト)では
        // 一時フォルダが /private/var/folders にあり、実在するので /private が外れて /var/… になる。期待値も同じ規則でそろえる。
        #expect(state.startupFolder()?.path == fixture.bFolder.standardizedFileURL.path)
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

    @Test("「最近の項目」は設定が ON のときだけ出せ、履歴の本を新しい順に並べ、履歴が変われば読み直し、書き込めない場所として振る舞う")
    func recentsListsHistoryNewestFirst() async throws {
        let fixture = try Fixture("fb-recents")
        let state = fixture.state
        let recent = RecentFilesStore(defaults: fixture.suite.defaults)
        state.recentFiles = recent
        state.makeVisibleWithoutWatching()
        state.navigate(to: fixture.root)
        await state.settle()

        // 既定 OFF: 何も起きない。
        #expect(!state.canShowRecents)
        state.showRecents()
        await state.settle()
        #expect(!state.isShowingRecents)
        #expect(FileBrowserState.id(of: state.currentFolder) == fixture.id(fixture.root))

        fixture.preferences.fileBrowserShowsRecents = true
        recent.record(url: fixture.root.appendingPathComponent("B.cbz"))
        recent.record(url: fixture.aFolder)
        state.showRecents()
        await state.settle()
        #expect(state.isShowingRecents)
        #expect(state.location == .recents)
        #expect(state.currentFolder == nil)  // 実フォルダは無い(書き込めない・上へ行けない)
        #expect(!state.canGoUp)
        #expect(state.canGoBack)
        #expect(fixture.names() == ["a-folder", "B.cbz"])  // 新しい順のまま(フォルダを上にしない)
        #expect(state.entries.map(\.isDirectory) == [true, false])

        // 履歴が変われば読み直す。
        recent.record(url: fixture.bFolder)
        try await Task.sleep(for: .milliseconds(100))
        await state.settle()
        #expect(fixture.names() == ["b-folder", "a-folder", "B.cbz"])

        // 戻ると元のフォルダへ。進むと最近の項目へ。
        state.goBack()
        await state.settle()
        #expect(!state.isShowingRecents)
        #expect(FileBrowserState.id(of: state.currentFolder) == fixture.id(fixture.root))
        state.goForward()
        await state.settle()
        #expect(state.isShowingRecents)

        // 「最後に表示したフォルダ」として覚え、次の状態は最近の項目から始まる。OFF ならホームへ読み替える。
        fixture.preferences.fileBrowserStartupLocation = .lastFolder
        let next = FileBrowserState(defaults: fixture.suite.defaults)
        next.preferences = fixture.preferences
        #expect(next.startupLocation() == .recents)
        #expect(next.startupFolder() == nil)

        // OFF にされたら、表示していた最近の項目から離れてホームへ。
        fixture.preferences.fileBrowserShowsRecents = false
        try await Task.sleep(for: .milliseconds(100))
        await state.settle()
        #expect(!state.isShowingRecents)
        #expect(state.currentFolder?.path == FileBrowserListing.realHomeDirectory().path)
        #expect(next.startupLocation() == .folder(FileBrowserListing.realHomeDirectory()))

        // 最近の項目は戻る/進むの履歴からも外れ、「戻る」は最近の項目の前に居たフォルダへ(レビュー 2026-09-29: 残すと押せる「戻る」が
        // 何もしなかった)。
        #expect(state.canGoBack && !state.canGoForward)
        state.goBack()
        await state.settle()
        #expect(!state.isShowingRecents)
        #expect(FileBrowserState.id(of: state.currentFolder) == fixture.id(fixture.root))

        // ホームから最近の項目へ行って OFF にすると、離れた先のホームが履歴の隣に残らない(「戻る」がホーム→ホームにならない)。
        let home = FileBrowserListing.realHomeDirectory()
        state.navigate(to: home)
        await state.settle()
        fixture.preferences.fileBrowserShowsRecents = true
        state.showRecents()
        await state.settle()
        #expect(state.isShowingRecents)
        fixture.preferences.fileBrowserShowsRecents = false
        try await Task.sleep(for: .milliseconds(100))
        await state.settle()
        #expect(state.currentFolder?.path == home.path)
        state.goBack()
        await state.settle()
        #expect(FileBrowserState.id(of: state.currentFolder) == fixture.id(fixture.root))
    }

    @Test("ネットワーク越しのボリュームにある記号リンク・エイリアスは、一覧の先の控えを作らない(リンクの数だけ往復しない。2026-09-29 の監査)")
    func linksOnNetworkVolumesAreNotResolvedInTheBackground() async throws {
        let fixture = try Fixture("fb-links-remote")
        let state = fixture.state
        state.linkTargetProtectedPrefixes = []
        state.linkTargetCategoryPrefixes = []
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("to-a"), withDestinationURL: fixture.aFolder
        )
        // 作業フォルダをネットワーク越しに見立てる(マウント表は文字列の比較だけ)。マウント先は `MountTable` が比べる形
        // (`standardizedFileURL`: 実在するパスの先頭の /private を外す。CI の一時フォルダは /private/var/… ―― docs/13)で書く。
        let remoteRoot = fixture.root.standardizedFileURL.path
        state.linkTargetMountTable = {
            MountTable(entries: [
                .init(mountPoint: "/", mountedFrom: "/dev/disk1", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
                .init(mountPoint: remoteRoot, mountedFrom: "//server/share", fileSystemType: "smbfs", isLocal: false, isHiddenFromBrowsing: false),
            ])
        }
        state.navigate(to: fixture.root)
        await state.settle()
        await state.waitForLinkTargets()
        let link = try #require(state.entries.first { $0.url.lastPathComponent == "to-a" })
        #expect(link.isLink)
        #expect(state.target(of: link) == nil)
        #expect(state.effective(link) == link)

        // ローカルなら解ける。
        state.linkTargetMountTable = { MountTable(entries: [
            .init(mountPoint: "/", mountedFrom: "/dev/disk1", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
        ]) }
        state.reload()
        try Data("x".utf8).write(to: fixture.root.appendingPathComponent("new.txt"))  // 一覧を変えて解き直させる
        state.reload()
        await state.settle()
        await state.waitForLinkTargets()
        #expect(state.target(of: link)?.url.path == fixture.aFolder.path)
    }

    @Test("一覧が同じでも、読み直しでリンクの先を解き直す(先が動いた・消えたのに古い先を使い続けない。2026-10-04、監査 FBU-2)")
    func linkTargetsAreResolvedAgainOnReload() async throws {
        let fixture = try Fixture("fb-links-refresh")
        let state = fixture.state
        state.linkTargetProtectedPrefixes = []
        state.linkTargetCategoryPrefixes = []
        // a-folder/inner に、外(root/b-folder)を指す記号リンク。先を動かしても inner の一覧は変わらない。
        try FileManager.default.createSymbolicLink(
            at: fixture.inner.appendingPathComponent("to-b"), withDestinationURL: fixture.bFolder
        )
        state.navigate(to: fixture.inner)
        await state.settle()
        await state.waitForLinkTargets()
        let link = try #require(state.entries.first { $0.url.lastPathComponent == "to-b" })
        #expect(state.target(of: link)?.url.path == fixture.bFolder.path)

        // Finder で先を動かして戻ってきた(アクティブ化の読み直し)。以前は一覧が同じなので解き直さず、古い先へ移ろうとした。
        try FileManager.default.moveItem(at: fixture.bFolder, to: fixture.root.appendingPathComponent("b-moved"))
        state.reload()
        await state.settle()
        await state.waitForLinkTargets()
        #expect(state.entries.map(\.url.lastPathComponent) == ["to-b"])
        #expect(state.target(of: link) == nil)
        #expect(state.effective(link) == link)
    }

    @Test("リンクの先の控えが変わったときだけ番号が進む(メニューバーの覚え書きの鍵。2026-10-04 の監査 X-2)")
    func linkTargetsRevisionAdvancesOnlyOnChange() async throws {
        let fixture = try Fixture("fb-links-revision")
        let state = fixture.state
        state.linkTargetProtectedPrefixes = []
        state.linkTargetCategoryPrefixes = []
        try FileManager.default.createSymbolicLink(
            at: fixture.inner.appendingPathComponent("to-b"), withDestinationURL: fixture.bFolder
        )
        let start = state.linkTargetsRevision
        state.navigate(to: fixture.inner)
        await state.settle()
        await state.waitForLinkTargets()
        // 先が解けた(以前は控えが publish されず、解ける前に作ったメニューの覚え書きが残った)。
        let resolved = state.linkTargetsRevision
        #expect(resolved != start)

        // 同じ答えの解き直しでは進めない(読み直しのたびに publish しない)。
        state.reload()
        await state.settle()
        await state.waitForLinkTargets()
        #expect(state.linkTargetsRevision == resolved)

        // 先が消えたら進む。
        try FileManager.default.moveItem(at: fixture.bFolder, to: fixture.root.appendingPathComponent("b-moved"))
        state.reload()
        await state.settle()
        await state.waitForLinkTargets()
        #expect(state.linkTargetsRevision != resolved)
    }

    @Test("シークレットウインドウでは「最近の項目」を出さない")
    func privateWindowNeverShowsRecents() async throws {
        let fixture = try Fixture("fb-recents-private")
        let state = fixture.state
        state.isPrivate = true
        fixture.preferences.fileBrowserShowsRecents = true
        state.navigate(to: fixture.root)
        await state.settle()
        #expect(!state.canShowRecents)
        state.showRecents()
        await state.settle()
        #expect(!state.isShowingRecents)
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

    /// タブバーの「＋」のタブは、正当なタブと分かってから ContentView が環境設定をつなぐ。それより先にペインが出ると、以前は起動時の
    /// フォルダの設定を読めずにホームから始まり、それを最後に表示したフォルダとして書いた(シークレットでも ―― 2026-09-23 の監査)。
    @Test("環境設定がつながる前に画面に出たら、つながるまで待ってから起動時のフォルダで始める")
    func activationWaitsForThePreferences() async throws {
        let fixture = try Fixture("fb-await-connection")
        fixture.preferences.fileBrowserStartupLocation = .lastFolder
        fixture.state.navigate(to: fixture.aFolder)
        await fixture.state.settle()

        let state = FileBrowserState(defaults: fixture.suite.defaults)
        state.activate()
        await state.settle()
        #expect(state.currentFolder == nil)
        #expect(!state.isVisible)
        // 待っている間の記録は変わらない。
        let probe = FileBrowserState(defaults: fixture.suite.defaults)
        probe.preferences = fixture.preferences
        #expect(probe.startupFolder()?.path == fixture.aFolder.path)

        state.preferences = fixture.preferences
        await state.settle()
        #expect(state.isVisible)
        #expect(state.currentFolder?.path == fixture.aFolder.path)
    }

    /// 名前の編集中に読み取り専用を ON にしたら、編集の欄を残さない(2026-09-23、利用者の決定)。一覧はこの通し番号の変化で取りやめる。
    @Test("ファイルを変えられなくなった瞬間だけ、名前の編集の取りやめを頼む")
    func turningReadOnlyOnAsksToCancelNameEditing() throws {
        let fixture = try Fixture("fb-cancel-rename")
        let preferences = fixture.preferences
        let state = fixture.state
        preferences.fileBrowserReadOnly = false
        let start = state.nameEditingCancelSerial

        preferences.fileBrowserReadOnly = true
        #expect(state.nameEditingCancelSerial == start + 1)
        // 変えられるようになる向きでは頼まない。
        preferences.fileBrowserReadOnly = false
        #expect(state.nameEditingCancelSerial == start + 1)
        // ファイルブラウザ機能を OFF にしたときも同じ(FileBrowserOperations.isReadOnly と同じ条件)。
        preferences.fileBrowserFeatureEnabled = false
        #expect(state.nameEditingCancelSerial == start + 2)
        // すでに変えられない間の切り替えでは頼まない。
        preferences.fileBrowserReadOnly = true
        #expect(state.nameEditingCancelSerial == start + 2)
    }

    /// Tab でのペインの行き来(2026-09-30、ユーザー要望。docs/15「Tab でのペインの行き来」)。焦点を動かすのは AppKit の一覧なので、
    /// ここで見るのは頼みの形だけ: 右ペインへ移すとき何も選ばれていなければ先頭の項目を選び、選ばれていれば触らない。
    @Test("右ペインへ焦点を移す頼みは、何も選ばれていなければ先頭の項目を選ぶ")
    func focusingTheContentPaneSelectsTheFirstItemWhenNothingIsSelected() async throws {
        let fixture = try Fixture("fb-focus-request")
        let state = fixture.state
        state.navigate(to: fixture.root)
        await state.settle()
        #expect(state.focusRequest == nil)

        state.requestFocus(.content)
        let first = try #require(state.focusRequest)
        #expect(first.pane == .content)
        #expect(state.selection == [fixture.id(fixture.aFolder)], "先頭の項目(フォルダを上にした名前順)を選ぶ")

        // 選ばれていれば触らない。頼みは毎回新しい値になる(同じキーを続けて押しても一覧が拾える)。
        state.selection = [fixture.id(fixture.bFolder)]
        state.requestFocus(.content)
        let second = try #require(state.focusRequest)
        #expect(second != first && second.pane == .content)
        #expect(state.selection == [fixture.id(fixture.bFolder)])

        // ツリーへ移すときは右ペインの選択に触らない。
        state.selection = []
        state.requestFocus(.tree)
        #expect(state.focusRequest?.pane == .tree)
        #expect(state.selection.isEmpty)
    }

    /// 作り直した一覧への焦点の引き継ぎ(2026-10-07。FileBrowserPaneFocusKeeper)。本を開いてホームが畳まれ、閉じて戻ったとき、
    /// 開くときに焦点を持っていたペインだけが 1 度だけ取り戻す。焦点を動かすのは AppKit の一覧なので、ここで見るのは控えの形だけ。
    @Test("畳まれたときに焦点を持っていたペインだけが、1 度だけ焦点を取り戻す")
    func focusIsRestoredOnlyToThePaneThatHeldIt() throws {
        let fixture = try Fixture("fb-focus-restore")
        let state = fixture.state
        #expect(!state.takeFocusToRestore(for: .content))

        // 右ペインが焦点を持ったまま外れ、ツリーは持たずに外れた(順序はどちらでも)。
        state.notePaneLeavingWindow(.tree, heldFocus: false)
        state.notePaneLeavingWindow(.content, heldFocus: true)
        #expect(!state.takeFocusToRestore(for: .tree))
        #expect(state.takeFocusToRestore(for: .content))
        #expect(!state.takeFocusToRestore(for: .content), "受け取ったら消える")

        state.notePaneLeavingWindow(.content, heldFocus: true)
        state.notePaneLeavingWindow(.tree, heldFocus: false)
        #expect(state.takeFocusToRestore(for: .content), "焦点を持たないもう一方のペインは控えを消さない")

        // 次に外れたとき焦点を持っていなければ、古い控えを捨てる。
        state.notePaneLeavingWindow(.content, heldFocus: true)
        state.notePaneLeavingWindow(.content, heldFocus: false)
        #expect(!state.takeFocusToRestore(for: .content))
    }

    @Test("つながる前に画面から外れたら、つながっても始めない")
    func deactivationCancelsTheAwaitedActivation() async throws {
        let fixture = try Fixture("fb-await-deactivate")
        let state = FileBrowserState(defaults: fixture.suite.defaults)
        state.activate()
        state.deactivate()
        state.preferences = fixture.preferences
        await state.settle()
        #expect(!state.isVisible)
        #expect(state.currentFolder == nil)
    }
}

import Foundation
import Testing

@testable import qooViewer

/// ホームのインスペクタ(右ペイン。2026-09-30)の、画面に依らない部分: 出し入れの状態と保存・「メタデータの編集…」からの頼み・
/// スマートライブラリの選択から見せるものを決める規則・フォルダの大きさ・メニューの可否。本の名前はすべて架空。
@MainActor
struct HomeInspectorTests {
    @Test("出し入れは保存され、次に作る状態(次のウインドウ)が引き継ぐ。幅は範囲に丸める")
    func visibilityAndWidthArePersisted() {
        let suite = PreferencesSuite(label: "inspector-persist")
        defer { withExtendedLifetime(suite) {} }
        let first = WelcomeLibraryState(defaults: suite.defaults)
        #expect(!first.isInspectorShown)
        #expect(first.inspectorWidth == WelcomeLibraryState.defaultInspectorWidth)
        first.isInspectorShown = true
        first.inspectorWidth = 333
        let second = WelcomeLibraryState(defaults: suite.defaults)
        #expect(second.isInspectorShown)
        #expect(second.inspectorWidth == 333)

        suite.defaults.set(10_000.0, forKey: "qooViewer.welcome.inspectorWidth")
        let third = WelcomeLibraryState(defaults: suite.defaults)
        #expect(third.inspectorWidth == WelcomeLibraryState.inspectorWidthRange.upperBound)
    }

    @Test("「情報 / リソース」の切り替えは保存され、次のウインドウが引き継ぐ。「メタデータの編集…」は「情報」へ戻す(2026-10-11)")
    func inspectorModeIsPersistedAndEditMetadataReturnsToInfo() {
        let suite = PreferencesSuite(label: "inspector-mode")
        defer { withExtendedLifetime(suite) {} }
        let first = WelcomeLibraryState(defaults: suite.defaults)
        #expect(first.inspectorMode == .info)
        first.inspectorMode = .resources
        let second = WelcomeLibraryState(defaults: suite.defaults)
        #expect(second.inspectorMode == .resources)

        // リソースモニタを出したまま右クリックの「メタデータの編集…」: 欄のある「情報」へ切り替え、頼みを置く。
        second.revealInspector(editingMetadataOf: "/books/fictional.cbz")
        #expect(second.isInspectorShown)
        #expect(second.inspectorMode == .info)
        #expect(second.hasInspectorFocusRequest(for: "/books/fictional.cbz"))

        suite.defaults.set("unknown", forKey: "qooViewer.welcome.inspectorMode")
        #expect(WelcomeLibraryState(defaults: suite.defaults).inspectorMode == .info)
    }

    @Test("3 つの機能が全部 OFF のホームには出さず、「メタデータの編集…」の頼みも置かない")
    func classicHomeHasNoInspector() {
        let suite = PreferencesSuite(label: "inspector-classic")
        defer { withExtendedLifetime(suite) {} }
        let state = WelcomeLibraryState(defaults: suite.defaults, restoresMode: false)
        state.isInspectorShown = true
        #expect(state.showsInspector)
        state.isLibraryFeatureEnabled = false
        state.isFileBrowserFeatureEnabled = false
        state.isSmartLibraryFeatureEnabled = false
        #expect(state.mode == .classic)
        #expect(!state.showsInspector)
        #expect(state.isInspectorShown, "設定そのものは残す(機能を戻せばまた出る)")

        state.isInspectorShown = false
        state.revealInspector(editingMetadataOf: "/books/a.cbz")
        #expect(!state.isInspectorShown)
        #expect(state.inspectorFocusRequest == nil)

        state.isFileBrowserFeatureEnabled = true
        state.revealInspector(editingMetadataOf: "/books/a.cbz")
        #expect(state.showsInspector)
        #expect(state.inspectorFocusRequest?.bookID == "/books/a.cbz")
    }

    @Test("「メタデータの編集…」の頼みは、その本の欄だけが拾える。古くなった頼みは効かず、モードを移ると捨てる")
    func focusRequestLifetime() {
        let suite = PreferencesSuite(label: "inspector-request")
        defer { withExtendedLifetime(suite) {} }
        let state = WelcomeLibraryState(defaults: suite.defaults, restoresMode: false)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

        state.revealInspector(editingMetadataOf: "/books/a.cbz", now: start)
        #expect(state.hasInspectorFocusRequest(for: "/books/a.cbz", now: start))
        #expect(!state.hasInspectorFocusRequest(for: "/books/b.cbz", now: start))
        #expect(state.isInspectorTakingFocus(now: start))
        #expect(!state.takeInspectorFocusRequest(for: "/books/b.cbz", now: start))
        #expect(state.takeInspectorFocusRequest(for: "/books/a.cbz", now: start.addingTimeInterval(1)))
        // 拾った直後は、一覧が焦点を取り返さない。
        #expect(state.isInspectorTakingFocus(now: start.addingTimeInterval(1.5)))
        #expect(!state.isInspectorTakingFocus(now: start.addingTimeInterval(3)))

        let late = WelcomeLibraryState.focusRequestLifetime + 1
        state.revealInspector(editingMetadataOf: "/books/a.cbz", now: start)
        #expect(!state.hasInspectorFocusRequest(for: "/books/a.cbz", now: start.addingTimeInterval(late)))
        #expect(!state.isInspectorTakingFocus(now: start.addingTimeInterval(late)),
                "拾われないまま古くなった頼みで、一覧が焦点を取り返すのを止め続けない")
        #expect(!state.takeInspectorFocusRequest(for: "/books/a.cbz", now: start.addingTimeInterval(late)))
        #expect(state.inspectorFocusRequest == nil, "古い頼みは拾おうとした時点で捨てる")

        state.revealInspector(editingMetadataOf: "/books/a.cbz", now: start)
        state.mode = .browser
        #expect(state.inspectorFocusRequest == nil)
    }

    @Test("スマートライブラリ: 本・束の中の本(リスト表示)・束・複数・並びに無いもの")
    func smartSelectionResolvesBooksAndGroups() {
        func book(_ path: String) -> SmartBook {
            SmartBook(id: path, fileName: (path as NSString).lastPathComponent, kind: .zip,
                      metadata: BookMetadataValues(), isRegistered: false)
        }
        let loose = book("/lib/loose.cbz")
        let inGroup = book("/lib/series 01.cbz")
        let group = SmartGridItem.group(.series, name: "Series", books: [inGroup, book("/lib/series 02.cbz")])
        let items: [SmartGridItem] = [.book(loose), group]
        let prefix = SmartGridItem.bookIDPrefix

        #expect(HomeInspectorSubject.smart(selection: [], items: items) == .none)
        #expect(HomeInspectorSubject.smart(selection: [prefix + loose.id], items: items) == .smartBook(loose))
        #expect(HomeInspectorSubject.smart(selection: [prefix + inGroup.id], items: items) == .smartBook(inGroup))
        #expect(HomeInspectorSubject.smart(selection: [group.id], items: items) == .smartGroup(name: "Series", bookCount: 2))
        #expect(HomeInspectorSubject.smart(selection: [prefix + loose.id, group.id], items: items) == .multiple(2))
        #expect(HomeInspectorSubject.smart(selection: [prefix + "/lib/gone.cbz"], items: items) == .none)
    }

    @Test("フォルダの大きさは中のファイルを全部足す(サブフォルダも)")
    func folderSizeSumsFiles() throws {
        let temporary = try TemporaryDirectory("inspector-folder-size")
        let folder = temporary.file("Book")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: folder.appendingPathComponent("a.png"))
        try Data(count: 234).write(to: folder.appendingPathComponent("sub/b.png"))
        #expect(HomeInspectorFolderSize.sum(folder) == .measured(1234, isPartial: false))
    }

    @Test("「インスペクタを表示/隠す」はホームが出ていて、旧ウェルカム画面でないときだけ")
    func menuItemAvailability() {
        var home = HomeMenuState(isShown: true, mode: .browser)
        #expect(home.canToggleInspector)
        home.mode = .classic
        #expect(!home.canToggleInspector)
        home = HomeMenuState(isShown: false, mode: .shelf)
        #expect(!home.canToggleInspector)
    }
}

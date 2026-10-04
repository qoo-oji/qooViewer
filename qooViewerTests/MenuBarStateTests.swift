import Foundation
import Testing

@testable import qooViewer

/// メニューバーへ出す値の写し(`AppState` が保留つきで持ち、`ContentView` が `MenuCheckmarkState` へ詰める値)。
///
/// 決まり(2026-10-04 の監査 §1-4、段 5): メニューが読む値は値型の写しに入れ、写しの鍵には表示に効く入力をすべて入れる。
/// ここでは AppState の側で、写しが中身の変化に付いていくかを見る。メニューの見た目そのもの(作り直されるか)は実機。
@MainActor
struct MenuBarStateTests {
    @Test("編集メニューの文言は見開きの相方のブックマークも数え、サイドパネルの「+」の判定は起点のページだけ(監査 V-3・SP-5)")
    func spreadBookmarkFlagCountsThePartnerPage() {
        let state = AppState(usesPageListCache: false)
        let onPartner = Bookmark(bookID: "/book", pageIndex: 3, name: "partner")
        state.updateCurrentBookmarks([onPartner])
        state.updateCurrentPageIndex(2)
        state.updateCurrentPartnerPageIndex(3)
        // 以前は起点のページ(2)だけを見て「追加」と出し、押すと相方のブックマークを消した。
        #expect(state.isCurrentSpreadBookmarked)
        #expect(!state.isCurrentPageBookmarked)

        // 相方が居なくなれば(単ページ・横長の自動単ページ化)、見開きの判定も外れる。
        state.updateCurrentPartnerPageIndex(nil)
        #expect(!state.isCurrentSpreadBookmarked)

        // 起点のページにあれば両方。
        state.updateCurrentPageIndex(3)
        #expect(state.isCurrentSpreadBookmarked)
        #expect(state.isCurrentPageBookmarked)
    }

    @Test("ブックマーク一覧が変わるたびに、メニューの作り直しの印が進む(同じ行の名前の変更も。監査 M-1)")
    func bookmarkListRevisionAdvancesOnEveryUpdate() {
        let state = AppState(usesPageListCache: false)
        let bookmark = Bookmark(bookID: "/book", pageIndex: 0, name: "first")
        let start = state.currentBookmarksRevision
        state.updateCurrentBookmarks([bookmark])
        #expect(state.currentBookmarksRevision == start &+ 1)
        // 名前だけ変わった同じ行(配列の比較では見分けられない)でも進める。
        bookmark.name = "renamed"
        state.updateCurrentBookmarks([bookmark])
        #expect(state.currentBookmarksRevision == start &+ 2)
    }

    @Test("メニューの「本が出ているか」は、ビューアに出ている本から作る(監査 M-6)")
    func menuShownBookFollowsTheShownBook() {
        let state = AppState(usesPageListCache: false)
        #expect(!state.menuShownBook.hasBook)
        let book = MangaBook(id: "/shown", title: "shown", sourceURL: URL(fileURLWithPath: "/shown"), pages: [])
        state.setMenuShownBook(MenuShownBook(book))
        #expect(state.menuShownBook.hasBook)
        #expect(state.menuShownBook.bookID == "/shown")
        #expect(!state.menuShownBook.leavesNoRecord)
        state.setMenuShownBook(MenuShownBook(nil))
        #expect(state.menuShownBook == MenuShownBook())
    }

    @Test("本のウインドウの削除の取り消しは、ファイルブラウザが出ている画面で積んだかを覚える(監査 M-2)")
    func dataUndoStepsRememberTheFileBrowserScreen() {
        let state = AppState(usesPageListCache: false)
        var home = HomeMenuState()
        home.isShown = true
        home.mode = .shelf
        state.setHomeMenu(home)
        state.dataUndo.push(MenuBarTestStep(title: "shelf"))
        #expect(state.dataUndo.undoTop?.isFromFileBrowserScreen == false)

        home.mode = .browser
        state.setHomeMenu(home)
        state.dataUndo.push(MenuBarTestStep(title: "browser"))
        #expect(state.dataUndo.undoTop?.isFromFileBrowserScreen == true)

        // 本を読んでいる間(ホームが出ていない)はファイルブラウザの画面ではない。
        home.isShown = false
        state.setHomeMenu(home)
        state.dataUndo.push(MenuBarTestStep(title: "viewer"))
        #expect(state.dataUndo.undoTop?.isFromFileBrowserScreen == false)
    }
}

/// 積み場所の振る舞いだけを見るための、何もしない操作。
@MainActor
private final class MenuBarTestStep: DataUndoStep {
    let title: String
    init(title: String) { self.title = title }
    func undo() -> Bool { true }
    func redo() -> Bool { true }
    func discard() {}
}

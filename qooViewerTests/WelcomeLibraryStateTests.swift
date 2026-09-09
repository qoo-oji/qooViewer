import Foundation
import Testing

@testable import qooViewer

/// ウェルカム画面の表示の状態(ViewModels/WelcomeLibraryState.swift)のうち、
/// **間違えると保存データが消える**選択の後始末だけを押さえる。
///
/// 編集モードのゴミ箱は「いま選ばれているもの」をまとめて削除する。選択が画面をまたいで
/// 残っていると、**目に見えていないものを消す**ことになるので、編集モードを抜けたとき・
/// コレクションの中へ入った/出たときに必ず捨てなければならない(選択の捨て方は didSet に
/// 集約してあり、画面側は自前で消さない)。
///
/// 保存先は `UserDefaults.standard` ではなくその場限りの suite
/// (テストは実物のアプリの中で走るため。PreferencesSuite のコメント参照)。
@MainActor
struct WelcomeLibraryStateTests {
    /// suite は最後まで生かしておく(deinit で領域ごと消えるため、テストの途中で解放されると
    /// 書き込み先が先に消える)。呼び出し側は `defer { withExtendedLifetime(suite) {} }` で
    /// 寿命をテストの終わりまで延ばす。
    private func makeState(_ label: String) -> (state: WelcomeLibraryState, suite: PreferencesSuite) {
        let suite = PreferencesSuite(label: label)
        return (WelcomeLibraryState(defaults: suite.defaults), suite)
    }

    @Test("クリックのたびに選択が入る/外れる")
    func selectionTogglesOnEachClick() {
        let (state, suite) = makeState("welcome-toggle")
        defer { withExtendedLifetime(suite) {} }
        let first = UUID()
        let second = UUID()

        state.toggleCollectionSelection(first)
        state.toggleCollectionSelection(second)
        #expect(state.selectedCollectionIDs == [first, second])
        state.toggleCollectionSelection(first)
        #expect(state.selectedCollectionIDs == [second])

        state.toggleItemSelection(first)
        #expect(state.selectedItemIDs == [first])
        state.toggleItemSelection(first)
        #expect(state.selectedItemIDs.isEmpty)
    }

    @Test("編集モードを抜けると選択は捨てる(入り直しても残っていない)")
    func leavingEditModeClearsTheSelection() {
        let (state, suite) = makeState("welcome-end-editing")
        defer { withExtendedLifetime(suite) {} }
        state.isEditing = true
        state.toggleCollectionSelection(UUID())
        state.toggleItemSelection(UUID())

        state.isEditing = false
        #expect(state.selectedCollectionIDs.isEmpty)
        #expect(state.selectedItemIDs.isEmpty)

        // 本を開いたときの後始末(endEditing)でも同じこと。
        state.isEditing = true
        state.toggleCollectionSelection(UUID())
        state.endEditing()
        #expect(state.isEditing == false)
        #expect(state.selectedCollectionIDs.isEmpty)
    }

    @Test("コレクションの中へ入る/出ると選択は捨てる(見えていないものを消さない)")
    func movingBetweenTheGridAndACollectionClearsTheSelection() {
        let (state, suite) = makeState("welcome-navigate")
        defer { withExtendedLifetime(suite) {} }
        state.isEditing = true
        state.toggleCollectionSelection(UUID())

        let collectionID = UUID()
        state.openedCollectionID = collectionID
        #expect(state.selectedCollectionIDs.isEmpty)

        state.toggleItemSelection(UUID())
        state.openedCollectionID = nil
        #expect(state.selectedItemIDs.isEmpty)
        // 場所が変わらない代入では何も起きない(@Published の再代入で選択を落とさない)。
        state.toggleItemSelection(UUID())
        state.openedCollectionID = nil
        #expect(state.selectedItemIDs.count == 1)
        #expect(state.isEditing)
    }
}

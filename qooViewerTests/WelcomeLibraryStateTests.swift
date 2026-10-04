import Foundation
import Testing

@testable import qooViewer

/// ウェルカム画面の表示の状態(ViewModels/WelcomeLibraryState.swift)のうち、
/// **間違えると保存データが消える**選択の後始末だけを押さえる。
///
/// 編集モードのゴミ箱は「いま選ばれているもの」をまとめて削除する。選択が画面をまたいで
/// 残っていると、**目に見えていないものを消す**ことになるので、ライブラリ・モードを移ったとき・
/// コレクションの中へ入った/出たときに必ず捨てなければならない(選択の捨て方は didSet に
/// 集約してあり、画面側は自前で消さない)。編集モードの出入りでは捨てない(2026-09-27 から、選択はモードの外でもできる)。
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

    @Test("編集モードの出入りでは選択を捨てない(本を開いたときの後始末でも) ―― 2026-09-27 から選択はモードの外でもできる")
    func editModeKeepsTheSelection() {
        let (state, suite) = makeState("welcome-end-editing")
        defer { withExtendedLifetime(suite) {} }
        let collection = UUID()
        let item = UUID()
        state.toggleCollectionSelection(collection)
        state.toggleItemSelection(item)

        state.isEditing = true
        #expect(state.selectedCollectionIDs == [collection])
        state.isEditing = false
        #expect(state.selectedCollectionIDs == [collection])
        #expect(state.selectedItemIDs == [item])

        // 本を開いたときの後始末(endEditing)は編集モードから出るが、選択は残す(戻ってきたら同じ画面)。
        state.isEditing = true
        state.endEditing()
        #expect(state.isEditing == false)
        #expect(state.selectedCollectionIDs == [collection])
    }

    @Test("コレクションから一覧へ戻ると、出てきたコレクションが選ばれている")
    func leavingACollectionSelectsIt() {
        let (state, suite) = makeState("welcome-leave-collection")
        defer { withExtendedLifetime(suite) {} }
        let opened = UUID()
        state.openCollection(opened, keepingSearch: false)
        state.toggleItemSelection(UUID())

        state.leaveCollection()
        #expect(state.openedCollectionID == nil)
        #expect(state.selectedCollectionIDs == [opened])
        #expect(state.selectedItemIDs.isEmpty)
        #expect(state.collectionSelection.cursor == opened)
    }

    @Test("モードを移ると選択を捨てる(見えていないものをゴミ箱が消さない)")
    func switchingModesClearsTheSelection() {
        let (state, suite) = makeState("welcome-mode-switch")
        defer { withExtendedLifetime(suite) {} }
        state.isLibraryFeatureEnabled = true
        state.isFileBrowserFeatureEnabled = true
        state.mode = .shelf
        state.toggleCollectionSelection(UUID())

        state.mode = .browser
        #expect(state.selectedCollectionIDs.isEmpty)
    }

    @Test("コレクションの中へ入る/出ると、編集モードから出て選択も捨てる")
    func movingBetweenTheGridAndACollectionLeavesEditMode() {
        let (state, suite) = makeState("welcome-navigate")
        defer { withExtendedLifetime(suite) {} }
        state.isEditing = true
        state.toggleCollectionSelection(UUID())

        state.openedCollectionID = UUID()
        #expect(state.isEditing == false)
        #expect(state.selectedCollectionIDs.isEmpty)

        state.isEditing = true
        state.toggleItemSelection(UUID())
        state.openedCollectionID = nil
        #expect(state.isEditing == false)
        #expect(state.selectedItemIDs.isEmpty)

        // 場所が変わらない代入では何も起きない(@Published の再代入で編集モードを落とさない)。
        state.isEditing = true
        state.toggleItemSelection(UUID())
        state.openedCollectionID = nil
        #expect(state.isEditing)
        #expect(state.selectedItemIDs.count == 1)
    }

    @Test("ライブラリを移っても編集モードから出る")
    func switchingLibrariesLeavesEditMode() {
        let (state, suite) = makeState("welcome-library-switch")
        defer { withExtendedLifetime(suite) {} }
        state.selectedLibraryID = UUID()
        state.isEditing = true
        state.toggleCollectionSelection(UUID())

        state.selectedLibraryID = UUID()
        #expect(state.isEditing == false)
        #expect(state.selectedCollectionIDs.isEmpty)

        // 同じライブラリを選び直しただけなら何も起きない。
        let current = state.selectedLibraryID
        state.isEditing = true
        state.selectedLibraryID = current
        #expect(state.isEditing)
    }

    // MARK: - 表示中の並びと操作の相手(2026-10-04、状態と画面の監査 H-1)

    @Test("並びが変わると選択を並びに絞り、操作の相手は表示中 ∩ 選択(表示順)")
    func showingANewOrderPrunesTheSelection() {
        let (state, suite) = makeState("welcome-prune-collections")
        defer { withExtendedLifetime(suite) {} }
        let (a, b, c) = (UUID(), UUID(), UUID())
        state.showCollections([a, b, c])
        state.selectedCollectionIDs = [a, c]
        #expect(state.targetCollectionIDs == [a, c])

        // c が見えなくなった(検索から外れた・別のウインドウが別のライブラリへ移した)。ゴミ箱とメニューの相手から外れる。
        state.showCollections([b, a])
        #expect(state.selectedCollectionIDs == [a])
        #expect(state.targetCollectionIDs == [a])

        // 戻ってきても、外した選択は戻らない(見えていない間に消す相手にならない)。
        state.showCollections([a, b, c])
        #expect(state.targetCollectionIDs == [a])
    }

    @Test("コレクションの中の本も同じ決まりで絞る")
    func showingANewItemOrderPrunesTheItemSelection() {
        let (state, suite) = makeState("welcome-prune-items")
        defer { withExtendedLifetime(suite) {} }
        let (a, b) = (UUID(), UUID())
        state.showItems([a, b])
        state.selectedItemIDs = [a, b]
        state.showItems([b])
        #expect(state.selectedItemIDs == [b])
        #expect(state.targetItemIDs == [b])
    }

    @Test("一覧へ戻ったとき、出てきた棚が一覧に出ないなら選択に残さない(以前は見えないまま選ばれていた)")
    func leavingACollectionThatIsNoLongerShownSelectsNothing() {
        let (state, suite) = makeState("welcome-leave-hidden")
        defer { withExtendedLifetime(suite) {} }
        let (opened, other) = (UUID(), UUID())
        state.showCollections([opened, other])
        state.openCollection(opened, keepingSearch: true)
        state.leaveCollection()
        #expect(state.selectedCollectionIDs == [opened])

        // 中で外した本が検索に当たっていて、戻った一覧にはもう出ない。一覧が出た時点で外れる。
        state.showCollections([other])
        #expect(state.selectedCollectionIDs.isEmpty)
        #expect(state.targetCollectionIDs.isEmpty)
    }

    @Test("チップとホーム ▸ ライブラリは同じ決まり: 見ているライブラリなら一覧へ戻って出てきた棚を選ぶ(2026-10-04 の監査 H-13)")
    func showingTheCurrentLibraryLeavesTheCollection() {
        let (state, suite) = makeState("welcome-show-library")
        defer { withExtendedLifetime(suite) {} }
        let (current, other) = (UUID(), UUID())
        let opened = UUID()
        state.selectedLibraryID = current
        state.showCollections([opened])
        state.openCollection(opened, keepingSearch: true)

        state.showLibrary(current, currentLibraryID: current)
        #expect(state.openedCollectionID == nil)
        #expect(state.selectedCollectionIDs == [opened])

        // 別のライブラリへは移る(開いていたコレクションからは出る)。
        state.openCollection(opened, keepingSearch: true)
        state.showLibrary(other, currentLibraryID: current)
        #expect(state.selectedLibraryID == other)
        #expect(state.openedCollectionID == nil)
    }

    @Test("別のライブラリへ移したコレクションだけを選択から外し、関係ない選択は残す(監査 H-13)")
    func movingCollectionsAwayKeepsTheRestOfTheSelection() {
        let (state, suite) = makeState("welcome-moved-away")
        defer { withExtendedLifetime(suite) {} }
        let (first, second, third) = (UUID(), UUID(), UUID())
        state.showCollections([first, second, third])
        state.toggleCollectionSelection(first)
        state.toggleCollectionSelection(second)

        // 選択の外のタイル(third)を右クリックして移した。
        state.collectionsMovedAway([third])
        #expect(state.selectedCollectionIDs == [first, second])

        state.collectionsMovedAway([first])
        #expect(state.selectedCollectionIDs == [second])

        // 開いていたコレクションを移したら一覧へ戻る。
        state.openCollection(second, keepingSearch: true)
        state.collectionsMovedAway([second])
        #expect(state.openedCollectionID == nil)
    }
}

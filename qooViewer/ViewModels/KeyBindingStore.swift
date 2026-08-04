import Foundation
import Combine

/// キーボード/マウスの操作割り当てを管理する。UserDefaultsにJSONで保存する。
/// (cooViewerの「入力タブ」のキー設定・マウス設定に相当する部分を簡略化したもの。
///  キーボードは1つの操作に複数のキーを割り当てられる(逆に1つのキーが割り当てられる
///  操作は1つまで。同じキーを別の操作に割り当てると、元の操作からは自動的に外れる)。
///  マウス(クリック/ホイール)は今まで通り、1トリガーにつき1操作まで)
@MainActor
final class KeyBindingStore: ObservableObject {
    /// RemappableKey.id -> ViewerAction
    @Published var keyBindings: [String: ViewerAction]
    /// InputTrigger -> ViewerAction
    @Published var mouseBindings: [InputTrigger: ViewerAction]

    private let keyDefaultsKey = "qooViewer.keyBindings.v1"
    private let mouseDefaultsKey = "qooViewer.mouseBindings.v1"

    // キーボードの既定値は、cooViewer(参考にしているMac用の既存の漫画ビューア)のノーマルモードの
    // 初期設定に、対応する操作がある範囲でできるだけ合わせつつ、qooViewer側の設計(画面位置基準の
    // spatialLeft/spatialRightと、読み方向に関わらない意味になるmoveNext/movePreviousを分けている
    // 点)を優先している。矢印キーは「左へ移動」「右へ移動」(spatialLeft/spatialRight)
    // に割り当て、moveNext/movePreviousにはcooViewerで次/前ページに使われている残り2キーずつ
    // (z/space、x/shift+space)を割り当てている。
    // 「最初のページへ」「最後のページへ」はcooViewerでは option+前ページキー / option+次ページキー
    // なので、それぞれ option+→ / option+← を追加で割り当てている(home/endも従来通り残す。
    // 1つの操作に複数キーを割り当てられるようになったため両立できる)。
    // 「次の本へ」「前の本へ」(cooViewerの「次のフォルダ・アーカイブへ」「前のフォルダ・アーカイブへ」に
    // 相当)はcooViewerでは control+次ブックマークキー / control+前ブックマークキー
    // (次ブックマークキー=c、前ブックマークキー=d)なので、control+c / control+d を割り当てている。
    // 「左/右の画像を実際のサイズで表示」はcooViewerでは「左ページを本来のサイズで表示」= q、
    // 「右ページを本来のサイズで表示」= w なので、それぞれ q / w を割り当てている。
    // 数字キー(0〜9)は、qooViewer独自の追加として全ページ数に対する割合でのページジャンプに
    // 割り当てている(0キー=先頭ページ[0%]、9キー=全ページ数の90%に相当するページ、
    // 以降10%刻み。ViewerAction.jumpToPercentileNN / ViewerViewModel.jump(toPercentile:)参照)。
    static let defaultKeyBindings: [String: ViewerAction] = [
        RemappableKey.leftArrow.id: .spatialLeft,
        RemappableKey.rightArrow.id: .spatialRight,
        RemappableKey.character("z").id: .moveNext,
        RemappableKey.space.id: .moveNext,
        RemappableKey.character("x").id: .movePrevious,
        RemappableKey.shiftSpace.id: .movePrevious,
        RemappableKey.shiftLeftArrow.id: .shiftOnePageLeft,
        RemappableKey.shiftRightArrow.id: .shiftOnePageRight,
        RemappableKey.home.id: .firstPage,
        RemappableKey.optionRightArrow.id: .firstPage,
        RemappableKey.end.id: .lastPage,
        RemappableKey.optionLeftArrow.id: .lastPage,
        RemappableKey.character("t").id: .showThumbnailGrid,
        RemappableKey.character("a").id: .toggleBookmark,
        RemappableKey.character("c").id: .nextBookmark,
        RemappableKey.character("d").id: .previousBookmark,
        RemappableKey.controlCharacter("c").id: .nextBook,
        RemappableKey.controlCharacter("d").id: .previousBook,
        RemappableKey.character("b").id: .showBookmarkList,
        // お気に入り関連(toggleFavorite/showFavoritesOrganizer)は、対応するブックマーク操作
        // (toggleBookmark = a、showBookmarkList = b)と同じキーにoptionを組み合わせた既定値に
        // している(ユーザーからの指示)。文字キーはshift押し/素押しを区別しない仕様
        // (RemappableKey.from参照)のため、shiftではなくoptionで組み合わせている。
        RemappableKey.optionCharacter("a").id: .toggleFavorite,
        RemappableKey.optionCharacter("b").id: .showFavoritesOrganizer,
        RemappableKey.character("g").id: .toggleSlideshow,
        RemappableKey.character("s").id: .toggleDisplayMode,
        RemappableKey.character("r").id: .toggleReadingDirection,
        RemappableKey.character("f").id: .cycleScalingMode,
        // 「現在の表示を基準に自動でレイアウトする」(ツールバーのアイコンボタン/メニューバー
        // 「Layout」→「Auto-Layout Based on Current View」と同じ操作)。他の既定キーと
        // 衝突しないeキーを割り当てている。
        RemappableKey.character("e").id: .autoLayoutFromCurrentView,
        RemappableKey.character("q").id: .showActualSizeLeft,
        RemappableKey.character("w").id: .showActualSizeRight,
        RemappableKey.character("0").id: .jumpToPercentile0,
        RemappableKey.character("1").id: .jumpToPercentile10,
        RemappableKey.character("2").id: .jumpToPercentile20,
        RemappableKey.character("3").id: .jumpToPercentile30,
        RemappableKey.character("4").id: .jumpToPercentile40,
        RemappableKey.character("5").id: .jumpToPercentile50,
        RemappableKey.character("6").id: .jumpToPercentile60,
        RemappableKey.character("7").id: .jumpToPercentile70,
        RemappableKey.character("8").id: .jumpToPercentile80,
        RemappableKey.character("9").id: .jumpToPercentile90,
    ]

    static let defaultMouseBindings: [InputTrigger: ViewerAction] = [
        .clickLeftZone: .spatialLeft,
        .clickRightZone: .spatialRight,
        .wheelUp: .movePrevious,
        .wheelDown: .moveNext,
    ]

    init() {
        keyBindings = Self.defaultKeyBindings
        mouseBindings = Self.defaultMouseBindings
        load()
    }

    func action(for key: RemappableKey) -> ViewerAction? {
        keyBindings[key.id]
    }

    func action(for trigger: InputTrigger) -> ViewerAction? {
        mouseBindings[trigger]
    }

    /// action に現在割り当てられているキーの一覧を返す(複数割り当て対応)。
    /// 表示順が毎回ばらつかないよう、RemappableKey.selectable の並び順に合わせて返す。
    func keys(for action: ViewerAction) -> [RemappableKey] {
        RemappableKey.selectable.filter { keyBindings[$0.id] == action }
    }

    /// action にキーを1つ追加で割り当てる。同じキーが既に別の操作に割り当てられている場合は、
    /// (1つのキーが同時に複数の操作を意味すると混乱するため)そちらの割り当てを自動的に外してから
    /// 付け替える。既にこの操作に割り当て済みのキーを指定した場合は何もしない。
    func addKeyBinding(_ action: ViewerAction, for key: RemappableKey) {
        guard keyBindings[key.id] != action else { return }
        keyBindings[key.id] = action
        persist()
    }

    /// 指定したキー1つの割り当てだけを外す(そのキーがどの操作に割り当てられていたかは問わない)。
    func removeKeyBinding(for key: RemappableKey) {
        keyBindings[key.id] = nil
        persist()
    }

    /// action に割り当てられているキーをすべて外す。
    func clearKeyBinding(for action: ViewerAction) {
        keyBindings = keyBindings.filter { $0.value != action }
        persist()
    }

    func setMouseBinding(_ action: ViewerAction, for trigger: InputTrigger) {
        mouseBindings[trigger] = action
        persist()
    }

    func clearMouseBinding(for trigger: InputTrigger) {
        mouseBindings[trigger] = nil
        persist()
    }

    func resetToDefaults() {
        keyBindings = Self.defaultKeyBindings
        mouseBindings = Self.defaultMouseBindings
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(keyBindings) {
            UserDefaults.standard.set(data, forKey: keyDefaultsKey)
        }
        let mouseDict: [String: ViewerAction] = Dictionary(
            uniqueKeysWithValues: mouseBindings.map { ($0.key.rawValue, $0.value) }
        )
        if let data = try? JSONEncoder().encode(mouseDict) {
            UserDefaults.standard.set(data, forKey: mouseDefaultsKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: keyDefaultsKey),
            let decoded = try? JSONDecoder().decode([String: ViewerAction].self, from: data)
        {
            keyBindings = decoded
        }
        if let data = UserDefaults.standard.data(forKey: mouseDefaultsKey),
            let decoded = try? JSONDecoder().decode([String: ViewerAction].self, from: data)
        {
            mouseBindings = Dictionary(
                uniqueKeysWithValues: decoded.compactMap { key, value in
                    InputTrigger(rawValue: key).map { ($0, value) }
                }
            )
        }
    }
}

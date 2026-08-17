import Foundation
import Combine

/// キーボード/マウスの操作割り当てを管理する。UserDefaultsにJSONで保存する。
/// (cooViewerの「入力タブ」のキー設定・マウス設定に相当する部分を簡略化したもの。
///  キーボードは1つの操作に複数のキーを割り当てられる(逆に1つのキーが割り当てられる
///  操作は1つまで。同じキーを別の操作に割り当てると、元の操作からは自動的に外れる)。
///  マウス(クリック/ホイール)は今まで通り、1トリガーにつき1操作まで)
@MainActor
final class KeyBindingStore: ObservableObject {
    /// RemappableKey.id -> ViewerAction(すべての表示モードで有効な、基本の割り当て)
    @Published var keyBindings: [String: ViewerAction]
    /// InputTrigger -> ViewerAction(同上)
    @Published var mouseBindings: [InputTrigger: ViewerAction]

    /// 「画面内に収める」以外の表示モードでのみ、上の基本の割り当てより優先して使われる上書き。
    /// 外側のキーがScalingMode、内側が基本と同じ形。
    ///
    /// cooViewerの`KeyArrayMode2`/`KeyArrayMode3`と同じ2段構え(モード別を先に引き、無ければ
    /// 基本へフォールバックする)を、qooViewerの表示モード4つに拡張したもの。cooViewerの
    /// 環境設定も、モードを選ぶポップアップ(PreferenceController.hのkeyModePopUpButton/
    /// mouseModePopUpButton)で**1度に1モード分だけ**表示・編集する作りになっており、
    /// リセットも「%@モードのキー設定をリセットしますか?」とモード単位である。
    ///
    /// 基本(画面内に収める)とは別の辞書のため、同じキーが両方に現れてよい。むしろそれが
    /// この仕組みの目的で、同じspaceキーを「画面内に収める」では次のページ、
    /// 「横幅に合わせる(単ページ)」では1画面分進む+次のページ、と使い分けられる。
    @Published var modeKeyBindings: [ScalingMode: [String: ViewerAction]]
    /// modeKeyBindingsのマウス版。
    @Published var modeMouseBindings: [ScalingMode: [InputTrigger: ViewerAction]]

    /// 表示モードごとの、マウスホイールを回したときの動作(WheelScrollBehavior参照)。
    ///
    /// cooViewerの`CanScrollMode`はアプリ全体で1つの設定だが、qooViewerではモード別にしている。
    /// 「単ページ幅に合わせたときはホイールだけで読み進めたいが、拡大縮小しない(原寸で細部を見る)ときは
    /// 勝手にページが送られたくない」といった使い分けが自然にできるうえ、「入力2」タブに
    /// モード別のものと共通のものが混在せず、すべてモード別で揃う(ユーザーからの指摘)。
    @Published var modeWheelBehaviors: [ScalingMode: WheelScrollBehavior]

    /// 上書きの土台になる「基本」の表示モード。ここに割り当てたものが、上書きの無い
    /// 他のモードにもそのまま引き継がれる。
    static let baseMode: ScalingMode = .fitToScreen
    /// 基本モードを上書きできるモード(=スクロールできるモード)。設定画面のポップアップの
    /// 並びにもこの順序を使う。
    static let overridableModes: [ScalingMode] = [.fitWidth, .fitWidthSplit, .noScale]

    private let keyDefaultsKey = "qooViewer.keyBindings.v1"
    private let mouseDefaultsKey = "qooViewer.mouseBindings.v1"
    // モード別の上書きは新しいキーで保存する。既存の2つのキーには一切触れないため、
    // この機能を追加する前から使っているユーザーの割り当てはそのまま引き継がれ、
    // 万一この機能を取り下げた場合にも元の状態に戻る。
    private let modeKeyDefaultsKey = "qooViewer.modeKeyBindings.v1"
    private let modeMouseDefaultsKey = "qooViewer.modeMouseBindings.v1"
    private let modeWheelDefaultsKey = "qooViewer.modeWheelBehaviors.v1"

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
        // ルーペ(qooViewer独自の追加機能)。cooViewerに対応する操作が無いため、
        // 他の既定キーと衝突しないlキーを新規に割り当てている(ユーザー要望: 既定はLキー)。
        RemappableKey.character("l").id: .toggleLoupe,
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

    // スクロールするモード用の既定値は、cooViewerのdefaultKeyArrayMode2/Mode3をそのまま
    // 写している(space=1画面分下へ+次のページ、shift+space=1画面分上へ+前のページ、
    // page down/up=1画面分下へ/上へ、home/end=最初へ/最後へスクロール)。
    // ここに無いキー(z/x、矢印キー、数字キーなど)は基本の割り当てへフォールバックするため、
    // ページ送りやジャンプはスクロールするモードでも今まで通り使える。
    static let defaultOverrideKeyBindings: [String: ViewerAction] = [
        RemappableKey.space.id: .scrollAndMoveNext,
        RemappableKey.shiftSpace.id: .scrollAndMovePrevious,
        RemappableKey.pageDown.id: .scrollScreenDown,
        RemappableKey.pageUp.id: .scrollScreenUp,
        RemappableKey.home.id: .scrollToPageStart,
        RemappableKey.end.id: .scrollToPageEnd,
    ]

    /// マウスは左右のクリックゾーンだけをスクロールするモード用に上書きし、ホイールは
    /// **あえて含めない**。cooViewerもホイールは既定(CanScrollMode = 0)でスクロール専用で、
    /// ページ送りには使わない。qooViewer側もScrollView自身がホイールを処理するため
    /// (ViewerView.handleScrollが画面内に収めるモード以外では早期returnする)、ここで
    /// ホイールに操作を割り当てるとScrollViewのスクロールと二重に効いてしまう。
    ///
    /// 左右どちらのクリックも「1画面分下へ+次のページ」にするのはcooViewerの
    /// defaultMouseArrayMode3と同じ(あちらも左右とも action 42 になっている)。
    /// 読み進める操作を画面のどこをクリックしても行える、という考え方。
    static let defaultOverrideMouseBindings: [InputTrigger: ViewerAction] = [
        .clickLeftZone: .scrollAndMoveNext,
        .clickRightZone: .scrollAndMoveNext,
    ]

    /// 上書き可能な3モードすべてに同じ既定値を入れたもの。cooViewerもMode2(横幅フィット)と
    /// Mode3(原寸+見開き分割)でほぼ同一の既定値を持っており、差は左右スクロール2件だけだった。
    static var defaultModeKeyBindings: [ScalingMode: [String: ViewerAction]] {
        Dictionary(uniqueKeysWithValues: overridableModes.map { ($0, defaultOverrideKeyBindings) })
    }

    static var defaultModeMouseBindings: [ScalingMode: [InputTrigger: ViewerAction]] {
        Dictionary(uniqueKeysWithValues: overridableModes.map { ($0, defaultOverrideMouseBindings) })
    }

    /// 既定はcooViewerと同じ「スクロールのみ」(CanScrollMode = 0)。
    static var defaultModeWheelBehaviors: [ScalingMode: WheelScrollBehavior] {
        Dictionary(uniqueKeysWithValues: overridableModes.map { ($0, WheelScrollBehavior.scrollOnly) })
    }

    init() {
        keyBindings = Self.defaultKeyBindings
        mouseBindings = Self.defaultMouseBindings
        modeKeyBindings = Self.defaultModeKeyBindings
        modeMouseBindings = Self.defaultModeMouseBindings
        modeWheelBehaviors = Self.defaultModeWheelBehaviors
        load()
    }

    // MARK: - ビューアからの参照(フォールバックあり)

    /// 表示モードを踏まえて、実際に実行すべき操作を解決する。
    /// 基本モード以外では、まずそのモードの上書きを引き、無ければ基本の割り当てへ
    /// フォールバックする(cooViewerのgetKeyAction:mod:mode:と同じ2段構え)。
    func resolvedAction(for key: RemappableKey, in mode: ScalingMode) -> ViewerAction? {
        if mode != Self.baseMode, let action = modeKeyBindings[mode]?[key.id] { return action }
        return keyBindings[key.id]
    }

    /// resolvedAction(for:in:)のマウス版。
    func resolvedAction(for trigger: InputTrigger, in mode: ScalingMode) -> ViewerAction? {
        if mode != Self.baseMode, let action = modeMouseBindings[mode]?[trigger] { return action }
        return mouseBindings[trigger]
    }

    /// そのモードでホイールを回したときの動作。基本モード(画面内に収める)にはスクロールする
    /// 余地が無いため、この設定は使わず常に割り当てられた操作を行う。
    func wheelBehavior(in mode: ScalingMode) -> WheelScrollBehavior {
        modeWheelBehaviors[mode] ?? .scrollOnly
    }

    func setWheelBehavior(_ behavior: WheelScrollBehavior, in mode: ScalingMode) {
        modeWheelBehaviors[mode] = behavior
        persist()
    }

    // MARK: - 設定画面からの参照・編集(フォールバックなし、モード単位)

    /// そのモードに**直接**割り当てられている操作(フォールバックしない)。
    /// 設定画面の表示と、キー重複チェックに使う。
    func assignedAction(for key: RemappableKey, in mode: ScalingMode) -> ViewerAction? {
        mode == Self.baseMode ? keyBindings[key.id] : modeKeyBindings[mode]?[key.id]
    }

    /// assignedAction(for:in:)のマウス版。
    func assignedAction(for trigger: InputTrigger, in mode: ScalingMode) -> ViewerAction? {
        mode == Self.baseMode ? mouseBindings[trigger] : modeMouseBindings[mode]?[trigger]
    }

    /// action にそのモードで現在割り当てられているキーの一覧を返す(複数割り当て対応)。
    /// 表示順が毎回ばらつかないよう、RemappableKey.selectable の並び順に合わせて返す。
    func keys(for action: ViewerAction, in mode: ScalingMode) -> [RemappableKey] {
        RemappableKey.selectable.filter { assignedAction(for: $0, in: mode) == action }
    }

    /// action にキーを1つ追加で割り当てる。既にこの操作に割り当て済みのキーを指定した場合は
    /// 何もしない。別の操作に割り当て済みのキーかどうかの確認は呼び出し側(設定画面)が
    /// assignedAction(for:in:)で行い、重複する場合はそもそもここへ来ない。
    ///
    /// モードが違えば同じキーを別の操作に割り当ててよい(それがモード別設定の目的そのもの)。
    func addKeyBinding(_ action: ViewerAction, for key: RemappableKey, in mode: ScalingMode) {
        guard assignedAction(for: key, in: mode) != action else { return }
        if mode == Self.baseMode {
            keyBindings[key.id] = action
        } else {
            modeKeyBindings[mode, default: [:]][key.id] = action
        }
        persist()
    }

    /// 指定したキー1つの割り当てだけを、そのモードから外す。
    func removeKeyBinding(for key: RemappableKey, in mode: ScalingMode) {
        if mode == Self.baseMode {
            keyBindings[key.id] = nil
        } else {
            modeKeyBindings[mode]?[key.id] = nil
        }
        persist()
    }

    func setMouseBinding(_ action: ViewerAction, for trigger: InputTrigger, in mode: ScalingMode) {
        if mode == Self.baseMode {
            mouseBindings[trigger] = action
        } else {
            modeMouseBindings[mode, default: [:]][trigger] = action
        }
        persist()
    }

    func clearMouseBinding(for trigger: InputTrigger, in mode: ScalingMode) {
        if mode == Self.baseMode {
            mouseBindings[trigger] = nil
        } else {
            modeMouseBindings[mode]?[trigger] = nil
        }
        persist()
    }

    /// 選んでいるモードの割り当てだけを初期状態へ戻す(cooViewerのkeyReset:/mouseReset:が
    /// 「%@モードのキー設定をリセットしますか?」とモード単位で確認するのと同じ考え方)。
    func resetToDefaults(in mode: ScalingMode) {
        if mode == Self.baseMode {
            keyBindings = Self.defaultKeyBindings
            mouseBindings = Self.defaultMouseBindings
        } else {
            modeKeyBindings[mode] = Self.defaultOverrideKeyBindings
            modeMouseBindings[mode] = Self.defaultOverrideMouseBindings
            modeWheelBehaviors[mode] = .scrollOnly
        }
        persist()
    }

    private func persist() {
        persistKeyBindings(keyBindings, forKey: keyDefaultsKey)
        persistMouseBindings(mouseBindings, forKey: mouseDefaultsKey)
        // モード別はScalingModeのrawValueをキーにした入れ子の辞書として1つにまとめて保存する。
        let modeKeys = Dictionary(uniqueKeysWithValues: modeKeyBindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(modeKeys) {
            UserDefaults.standard.set(data, forKey: modeKeyDefaultsKey)
        }
        let modeMice = Dictionary(
            uniqueKeysWithValues: modeMouseBindings.map { mode, bindings in
                (mode.rawValue, Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) }))
            }
        )
        if let data = try? JSONEncoder().encode(modeMice) {
            UserDefaults.standard.set(data, forKey: modeMouseDefaultsKey)
        }
        let wheels = Dictionary(uniqueKeysWithValues: modeWheelBehaviors.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(wheels) {
            UserDefaults.standard.set(data, forKey: modeWheelDefaultsKey)
        }
    }

    private func persistKeyBindings(_ bindings: [String: ViewerAction], forKey key: String) {
        if let data = try? JSONEncoder().encode(bindings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func persistMouseBindings(_ bindings: [InputTrigger: ViewerAction], forKey key: String) {
        let dict: [String: ViewerAction] = Dictionary(
            uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) }
        )
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        if let decoded = loadKeyBindings(forKey: keyDefaultsKey) {
            keyBindings = decoded
        }
        if let decoded = loadMouseBindings(forKey: mouseDefaultsKey) {
            mouseBindings = decoded
        }
        // モード別は、保存済みの値が無ければ既定値のまま残す(initで代入済み)。これにより、
        // この機能より前から使っているユーザーにもcooViewer準拠の既定の割り当てが適用される。
        if let data = UserDefaults.standard.data(forKey: modeKeyDefaultsKey),
            let decoded = try? JSONDecoder().decode([String: [String: ViewerAction]].self, from: data)
        {
            modeKeyBindings = Dictionary(
                uniqueKeysWithValues: decoded.compactMap { raw, bindings in
                    ScalingMode(rawValue: raw).map { ($0, bindings) }
                }
            )
        }
        if let data = UserDefaults.standard.data(forKey: modeMouseDefaultsKey),
            let decoded = try? JSONDecoder().decode([String: [String: ViewerAction]].self, from: data)
        {
            modeMouseBindings = Dictionary(
                uniqueKeysWithValues: decoded.compactMap { raw, bindings in
                    guard let mode = ScalingMode(rawValue: raw) else { return nil }
                    let triggers = Dictionary(
                        uniqueKeysWithValues: bindings.compactMap { key, value in
                            InputTrigger(rawValue: key).map { ($0, value) }
                        }
                    )
                    return (mode, triggers)
                }
            )
        }
        loadModeWheelBehaviors()
    }

    private func loadModeWheelBehaviors() {
        guard let data = UserDefaults.standard.data(forKey: modeWheelDefaultsKey),
            let decoded = try? JSONDecoder().decode([String: WheelScrollBehavior].self, from: data)
        else { return }
        modeWheelBehaviors = Dictionary(
            uniqueKeysWithValues: decoded.compactMap { raw, value in
                ScalingMode(rawValue: raw).map { ($0, value) }
            }
        )
    }

    private func loadKeyBindings(forKey key: String) -> [String: ViewerAction]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([String: ViewerAction].self, from: data)
    }

    private func loadMouseBindings(forKey key: String) -> [InputTrigger: ViewerAction]? {
        guard let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([String: ViewerAction].self, from: data)
        else { return nil }
        return Dictionary(
            uniqueKeysWithValues: decoded.compactMap { key, value in
                InputTrigger(rawValue: key).map { ($0, value) }
            }
        )
    }

}

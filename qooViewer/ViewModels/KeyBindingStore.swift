import Foundation
import Combine

/// キーボード/マウスの操作割り当てを管理する。UserDefaultsにJSONで保存する。
/// (cooViewerの「入力タブ」のキー設定・マウス設定に相当する部分を簡略化したもの。
///  キーボードは1つの操作に複数のキーを割り当てられる(逆に1つのキーが割り当てられる
///  操作は1つまで。同じキーを別の操作に割り当てると、元の操作からは自動的に外れる)。
///  マウスも同じ形にしてある ― 1つの操作に複数のトリガーを割り当てられ、1つのトリガーが
///  割り当てられる操作は1つまで。MouseTrigger参照)
@MainActor
final class KeyBindingStore: ObservableObject {
    /// RemappableKey.id -> ViewerAction(すべての表示モードで有効な、基本の割り当て)
    @Published var keyBindings: [String: ViewerAction]
    /// MouseTrigger.id -> ViewerAction(同上)
    ///
    /// キーボード側とまったく同じ形(識別子の文字列 -> 操作)にしてあるため、保存も読み込みも
    /// 同じ persistBindings/loadBindings を使い回せる。以前はInputTriggerという4択の
    /// 列挙型をキーにしていたため、マウス専用の保存・読み込み処理を別に持っていた。
    @Published var mouseBindings: [String: ViewerAction]

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
    @Published var modeMouseBindings: [ScalingMode: [String: ViewerAction]]

    /// 表示モードごとの、マウスホイールを回したときの動作(WheelScrollBehavior参照)。
    ///
    /// cooViewerの`CanScrollMode`はアプリ全体で1つの設定だが、qooViewerではモード別にしている。
    /// 「単ページ幅に合わせたときはホイールだけで読み進めたいが、拡大縮小しない(原寸で細部を見る)ときは
    /// 勝手にページが送られたくない」といった使い分けが自然にできるうえ、「入力2」タブに
    /// モード別のものと共通のものが混在せず、すべてモード別で揃う(ユーザーからの指摘)。
    @Published var modeWheelBehaviors: [ScalingMode: WheelScrollBehavior]

    /// 表示モードごとの、「上/下/左/右へスクロール」1回あたりの移動量(ポイント)。
    /// cooViewerも同じ操作に移動量を持たせている(既定20。あちらは割り当て1件ごとに
    /// 編集できるが、qooViewerでは表示モードごとに1つとしている)。
    @Published var modeScrollSteps: [ScalingMode: Double]

    /// 上書きの土台になる「基本」の表示モード。ここに割り当てたものが、上書きの無い
    /// 他のモードにもそのまま引き継がれる。
    static let baseMode: ScalingMode = .fitToScreen
    /// 基本モードを上書きできるモード(=スクロールできるモード)。設定画面のポップアップの
    /// 並びにもこの順序を使う。
    static let overridableModes: [ScalingMode] = [.fitWidth, .fitWidthSplit, .noScale]

    private let keyDefaultsKey = "qooViewer.keyBindings.v1"
    // マウスは「トリガー -> 操作」から「操作 -> トリガー(複数可)」へ作り直したのに伴い、
    // 保存する中身(InputTriggerのrawValue -> MouseTriggerのid)が変わるため、新しいキーで
    // 保存する。旧キー(legacy...)は**読むだけで書き換えない**。作り直し前から使っている
    // ユーザーの割り当ては初回だけ読み替えて新キーへ書き、旧キーはそのまま残るため、
    // 万一この変更を取り下げても元の状態に戻る(モード別の上書きを追加したときと同じ方針)。
    private let mouseDefaultsKey = "qooViewer.mouseTriggerBindings.v1"
    // モード別の上書きは新しいキーで保存する。既存の2つのキーには一切触れないため、
    // この機能を追加する前から使っているユーザーの割り当てはそのまま引き継がれ、
    // 万一この機能を取り下げた場合にも元の状態に戻る。
    private let modeKeyDefaultsKey = "qooViewer.modeKeyBindings.v1"
    private let modeMouseDefaultsKey = "qooViewer.modeMouseTriggerBindings.v1"
    private let legacyMouseDefaultsKey = "qooViewer.mouseBindings.v1"
    private let legacyModeMouseDefaultsKey = "qooViewer.modeMouseBindings.v1"
    private let modeWheelDefaultsKey = "qooViewer.modeWheelBehaviors.v1"
    private let modeScrollStepDefaultsKey = "qooViewer.modeScrollSteps.v1"

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

    // マウスの既定値もcooViewerのdefaultMouseArrayに、対応する操作がある範囲で合わせている
    // (左クリックした側でページ送り、shift+左クリックで1ページずらし、ホイールの上下でページ送り、
    //  ホイールクリック[button2]でルーペ=cooViewerのaction 43)。
    //
    // 中ボタンのルーペだけ位置を .anywhere にしている。左右どちらでクリックしても同じ動作で
    // よいものは、左右2件に分けずこの1件で書ける(MouseTrigger.Zone参照)。
    static let defaultMouseBindings: [String: ViewerAction] = [
        MouseTrigger(input: .click(.left, .leftHalf), modifiers: []).id: .spatialLeft,
        MouseTrigger(input: .click(.left, .rightHalf), modifiers: []).id: .spatialRight,
        MouseTrigger(input: .click(.left, .leftHalf), modifiers: .shift).id: .shiftOnePageLeft,
        MouseTrigger(input: .click(.left, .rightHalf), modifiers: .shift).id: .shiftOnePageRight,
        MouseTrigger(input: .click(.middle, .anywhere), modifiers: []).id: .toggleLoupe,
        MouseTrigger(input: .wheel(.up), modifiers: []).id: .movePrevious,
        MouseTrigger(input: .wheel(.down), modifiers: []).id: .moveNext,
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
        // ↑↓←→での少しずつのスクロールもcooViewerに合わせる。あちらは横幅フィットでは↑↓のみ、
        // 原寸・見開き分割では←→も割り当てているが、qooViewerでは3モードとも同じ既定にする
        // (←→は基本の割り当てではページ送りのため、ここで上書きしないと横へ動かせない)。
        RemappableKey.upArrow.id: .scrollUp,
        RemappableKey.downArrow.id: .scrollDown,
        RemappableKey.leftArrow.id: .scrollLeft,
        RemappableKey.rightArrow.id: .scrollRight,
    ]

    /// 左右のクリックゾーンには、**読み方向に応じて進む/戻るが決まる**スクロール送りを割り当てる。
    /// cooViewerの既定(action 42)が1つの割り当てでクリックした側により進む/戻るを決めており、
    /// 左右どちらでも「進む」にしてしまうとクリックで戻れなくなるため
    /// (ViewerAction.scrollAndMoveSpatialLeftのコメント参照)。
    ///
    /// マウスは左右のクリックゾーンだけをスクロールするモード用に上書きし、ホイールは
    /// **あえて含めない**。cooViewerもホイールは既定(CanScrollMode = 0)でスクロール専用で、
    /// ページ送りには使わない。qooViewer側もScrollView自身がホイールを処理するため
    /// (ViewerView.handleScrollが画面内に収めるモード以外では早期returnする)、ここで
    /// ホイールに操作を割り当てるとScrollViewのスクロールと二重に効いてしまう。
    ///
    /// 左右どちらのクリックも「1画面分下へ+次のページ」にするのはcooViewerの
    /// defaultMouseArrayMode3と同じ(あちらも左右とも action 42 になっている)。
    /// 読み進める操作を画面のどこをクリックしても行える、という考え方。
    static let defaultOverrideMouseBindings: [String: ViewerAction] = [
        MouseTrigger(input: .click(.left, .leftHalf), modifiers: []).id: .scrollAndMoveSpatialLeft,
        MouseTrigger(input: .click(.left, .rightHalf), modifiers: []).id: .scrollAndMoveSpatialRight,
    ]

    /// 上書き可能な3モードすべてに同じ既定値を入れたもの。cooViewerもMode2(横幅フィット)と
    /// Mode3(原寸+見開き分割)でほぼ同一の既定値を持っており、差は左右スクロール2件だけだった。
    static var defaultModeKeyBindings: [ScalingMode: [String: ViewerAction]] {
        Dictionary(uniqueKeysWithValues: overridableModes.map { ($0, defaultOverrideKeyBindings) })
    }

    static var defaultModeMouseBindings: [ScalingMode: [String: ViewerAction]] {
        Dictionary(uniqueKeysWithValues: overridableModes.map { ($0, defaultOverrideMouseBindings) })
    }

    /// 既定はcooViewerと同じ「スクロールのみ」(CanScrollMode = 0)。
    static var defaultModeWheelBehaviors: [ScalingMode: WheelScrollBehavior] {
        Dictionary(uniqueKeysWithValues: overridableModes.map { ($0, WheelScrollBehavior.scrollOnly) })
    }

    /// 既定の移動量。cooViewerのdefaultKeyArrayMode2/Mode3が持つvalue(20)に合わせている。
    static let defaultScrollStep: Double = 20

    static var defaultModeScrollSteps: [ScalingMode: Double] {
        Dictionary(uniqueKeysWithValues: overridableModes.map { ($0, defaultScrollStep) })
    }

    init() {
        keyBindings = Self.defaultKeyBindings
        mouseBindings = Self.defaultMouseBindings
        modeKeyBindings = Self.defaultModeKeyBindings
        modeMouseBindings = Self.defaultModeMouseBindings
        modeWheelBehaviors = Self.defaultModeWheelBehaviors
        modeScrollSteps = Self.defaultModeScrollSteps
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
    func resolvedAction(for trigger: MouseTrigger, in mode: ScalingMode) -> ViewerAction? {
        if mode != Self.baseMode, let action = modeMouseBindings[mode]?[trigger.id] { return action }
        return mouseBindings[trigger.id]
    }

    /// クリックに対して、実際に実行すべき操作を解決する。
    ///
    /// 位置は2段階で引く。**位置指定(画面の左側/右側)が「全体」より優先**され、それぞれの中では
    /// 上のresolvedAction(for:in:)どおり、表示モード別の上書きが基本の割り当てより優先される。
    /// 「具体的な指定が勝つ」という素直な規則をそのまま当てはめたもの。
    ///
    /// 例: 「中ボタン・全体」にルーペを割り当てたうえで「中ボタン・画面の左側」に別の操作を
    /// 割り当てると、左半分では後者、右半分ではルーペになる。
    func resolvedClickAction(
        button: MouseTrigger.Button,
        zone: MouseTrigger.Zone,
        modifiers: MouseTrigger.Modifiers,
        in mode: ScalingMode
    ) -> ViewerAction? {
        let specific = MouseTrigger(input: .click(button, zone), modifiers: modifiers)
        if let action = resolvedAction(for: specific, in: mode), action != .none { return action }
        guard zone != .anywhere else { return nil }
        let anywhere = MouseTrigger(input: .click(button, .anywhere), modifiers: modifiers)
        return resolvedAction(for: anywhere, in: mode)
    }

    /// そのモードで、クリックに何か1つでも操作が割り当てられているか。
    ///
    /// ビューア側は、割り当てが1つも無ければクリックの当たり判定そのものを無効にして、
    /// 下にあるScrollViewへクリックを通す(ViewerView.hasClickZoneAction参照)。
    /// 中ボタンにだけ割り当てた場合も当たり判定は必要なので、位置・修飾キー・ボタンを
    /// 問わず横断して調べる。
    func hasAnyClickAction(in mode: ScalingMode) -> Bool {
        MouseTrigger.selectable.contains { trigger in
            guard case .click = trigger.input else { return false }
            guard let action = resolvedAction(for: trigger, in: mode) else { return false }
            return action != .none
        }
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

    /// そのモードでの「上/下/左/右へスクロール」1回あたりの移動量(ポイント)。
    func scrollStep(in mode: ScalingMode) -> Double {
        modeScrollSteps[mode] ?? Self.defaultScrollStep
    }

    func setScrollStep(_ step: Double, in mode: ScalingMode) {
        modeScrollSteps[mode] = step
        persist()
    }

    // MARK: - 設定画面からの参照・編集(フォールバックなし、モード単位)

    /// そのモードに**直接**割り当てられている操作(フォールバックしない)。
    /// 設定画面の表示と、キー重複チェックに使う。
    func assignedAction(for key: RemappableKey, in mode: ScalingMode) -> ViewerAction? {
        mode == Self.baseMode ? keyBindings[key.id] : modeKeyBindings[mode]?[key.id]
    }

    /// assignedAction(for:in:)のマウス版。
    func assignedAction(for trigger: MouseTrigger, in mode: ScalingMode) -> ViewerAction? {
        mode == Self.baseMode ? mouseBindings[trigger.id] : modeMouseBindings[mode]?[trigger.id]
    }

    /// action にそのモードで現在割り当てられているキーの一覧を返す(複数割り当て対応)。
    /// 表示順が毎回ばらつかないよう、RemappableKey.selectable の並び順に合わせて返す。
    func keys(for action: ViewerAction, in mode: ScalingMode) -> [RemappableKey] {
        RemappableKey.selectable.filter { assignedAction(for: $0, in: mode) == action }
    }

    /// keys(for:in:)のマウス版。表示順が毎回ばらつかないよう、MouseTrigger.selectable の
    /// 並び順(ボタン→位置→修飾キー、最後にホイール)に合わせて返す。
    func triggers(for action: ViewerAction, in mode: ScalingMode) -> [MouseTrigger] {
        MouseTrigger.selectable.filter { assignedAction(for: $0, in: mode) == action }
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

    /// addKeyBinding(_:for:in:)のマウス版。競合の確認は呼び出し側(設定画面)が行う。
    func addMouseBinding(_ action: ViewerAction, for trigger: MouseTrigger, in mode: ScalingMode) {
        guard assignedAction(for: trigger, in: mode) != action else { return }
        if mode == Self.baseMode {
            mouseBindings[trigger.id] = action
        } else {
            modeMouseBindings[mode, default: [:]][trigger.id] = action
        }
        persist()
    }

    /// 指定したトリガー1つの割り当てだけを、そのモードから外す。
    func removeMouseBinding(for trigger: MouseTrigger, in mode: ScalingMode) {
        if mode == Self.baseMode {
            mouseBindings[trigger.id] = nil
        } else {
            modeMouseBindings[mode]?[trigger.id] = nil
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
            modeScrollSteps[mode] = Self.defaultScrollStep
        }
        persist()
    }

    private func persist() {
        persistBindings(keyBindings, forKey: keyDefaultsKey)
        persistBindings(mouseBindings, forKey: mouseDefaultsKey)
        // モード別はScalingModeのrawValueをキーにした入れ子の辞書として1つにまとめて保存する。
        persistModeBindings(modeKeyBindings, forKey: modeKeyDefaultsKey)
        persistModeBindings(modeMouseBindings, forKey: modeMouseDefaultsKey)
        let wheels = Dictionary(uniqueKeysWithValues: modeWheelBehaviors.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(wheels) {
            UserDefaults.standard.set(data, forKey: modeWheelDefaultsKey)
        }
        let steps = Dictionary(uniqueKeysWithValues: modeScrollSteps.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(steps) {
            UserDefaults.standard.set(data, forKey: modeScrollStepDefaultsKey)
        }
    }

    /// キーボードもマウスも「識別子の文字列 -> 操作」という同じ形なので、保存も1つで足りる
    /// (RemappableKey.id / MouseTrigger.id)。
    private func persistBindings(_ bindings: [String: ViewerAction], forKey key: String) {
        if let data = try? JSONEncoder().encode(bindings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func persistModeBindings(
        _ bindings: [ScalingMode: [String: ViewerAction]], forKey key: String
    ) {
        let dict = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        if let decoded = loadBindings(forKey: keyDefaultsKey) {
            keyBindings = decoded
        }
        // マウスは、新しいキーがあればそれを使う。無ければ「トリガー -> 操作」形式だった頃の
        // 旧キーを読み替える(migratedLegacyMouseBindings参照)。どちらも無ければ既定値のまま。
        if let decoded = loadBindings(forKey: mouseDefaultsKey) {
            mouseBindings = decoded
        } else if let legacy = loadBindings(forKey: legacyMouseDefaultsKey) {
            mouseBindings = Self.migratedLegacyMouseBindings(
                legacy, mergingInto: Self.defaultMouseBindings
            )
        }
        // モード別は、保存済みの値が無ければ既定値のまま残す(initで代入済み)。これにより、
        // この機能より前から使っているユーザーにもcooViewer準拠の既定の割り当てが適用される。
        if let decoded = loadModeBindings(forKey: modeKeyDefaultsKey) {
            modeKeyBindings = decoded
        }
        if let decoded = loadModeBindings(forKey: modeMouseDefaultsKey) {
            modeMouseBindings = decoded
        } else if let legacy = loadModeBindings(forKey: legacyModeMouseDefaultsKey) {
            modeMouseBindings = legacy.mapValues {
                Self.migratedLegacyMouseBindings($0, mergingInto: Self.defaultOverrideMouseBindings)
            }
        }
        loadModeWheelBehaviors()
        if let data = UserDefaults.standard.data(forKey: modeScrollStepDefaultsKey),
            let decoded = try? JSONDecoder().decode([String: Double].self, from: data)
        {
            modeScrollSteps = Dictionary(
                uniqueKeysWithValues: decoded.compactMap { raw, value in
                    ScalingMode(rawValue: raw).map { ($0, value) }
                }
            )
        }
    }

    /// 「トリガー -> 操作」形式だった頃のInputTrigger(4択)のrawValueと、対応する
    /// MouseTrigger.idの対応表。保存済みデータの読み替えにだけ使う。
    ///
    /// 当時のトリガーはいずれも「左ボタン・修飾キー無し」に相当する
    /// (ボタン番号も修飾キーも見ていなかったため)。
    private static let legacyMouseTriggerIDs: [String: String] = [
        "clickLeftZone": MouseTrigger(input: .click(.left, .leftHalf), modifiers: []).id,
        "clickRightZone": MouseTrigger(input: .click(.left, .rightHalf), modifiers: []).id,
        "wheelUp": MouseTrigger(input: .wheel(.up), modifiers: []).id,
        "wheelDown": MouseTrigger(input: .wheel(.down), modifiers: []).id,
    ]

    /// 旧形式で保存されていた割り当てを、新しいMouseTrigger.idのキーへ読み替える。
    ///
    /// 単純に旧データで置き換えるのではなく、**既定値を土台にして、旧形式が表現できた
    /// 4つのトリガーぶんだけを旧データで上書きする**。旧形式には中ボタンも修飾キーも
    /// 無かったため、置き換えてしまうと作り直しで増えた既定の割り当て
    /// (中クリック=ルーペ、shift+クリック=1ページずらし)が、以前から使っている
    /// ユーザーにだけ現れないことになってしまう。
    ///
    /// 逆に、旧形式で表現できた4つは必ず旧データが勝つ(旧UIで「なし」にした項目は
    /// 辞書からキーごと消えていたため、この上書きで既定値が復活することはない)。
    private static func migratedLegacyMouseBindings(
        _ legacy: [String: ViewerAction], mergingInto base: [String: ViewerAction]
    ) -> [String: ViewerAction] {
        let expressibleByLegacy = Set(legacyMouseTriggerIDs.values)
        var result = base.filter { !expressibleByLegacy.contains($0.key) }
        for (rawValue, action) in legacy {
            guard let id = legacyMouseTriggerIDs[rawValue] else { continue }
            result[id] = action
        }
        return result
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

    private func loadBindings(forKey key: String) -> [String: ViewerAction]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([String: ViewerAction].self, from: data)
    }

    private func loadModeBindings(forKey key: String) -> [ScalingMode: [String: ViewerAction]]? {
        guard let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([String: [String: ViewerAction]].self, from: data)
        else { return nil }
        return Dictionary(
            uniqueKeysWithValues: decoded.compactMap { raw, bindings in
                ScalingMode(rawValue: raw).map { ($0, bindings) }
            }
        )
    }

}

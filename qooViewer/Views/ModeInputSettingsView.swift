import SwiftUI

/// 環境設定ウインドウの「表示モード別の操作」画面。**表示モードによって変わる**キー・マウス操作
/// だけを扱う(表示モードに依存しない基本の割り当ては「キーボード」画面 = KeyBindingSettingsView と
/// 「マウス」画面 = MouseBindingSettingsView)。
///
/// ■ なぜ画面を分けるのか
/// cooViewerは環境設定の入力タブにモード切替ポップアップ(PreferenceController.hの
/// keyModePopUpButton/mouseModePopUpButton)を置き、**1度に1モード分だけ**表示・編集する。
/// qooViewerでも当初これに倣って1つの画面にまとめたが、
///
/// - 基本の設定とモード別の設定を並べると「同じ『画面の左側をクリック』が2つあって、
///   相反する設定ができるように見える」
/// - 逆にポップアップで切り替える形にすると、モードごとに独立させる意味のない操作
///   (ブックマーク・お気に入り・本の移動など)まで各モードに並んでしまう
///
/// という2つの問題が残った(いずれもユーザーからの指摘)。画面ごと分けることで、
/// 「キーボード」「マウス」画面にはどのモードでも同じように働く設定だけ、この画面には
/// モードによって変わる設定だけ、という状態にしている。
///
/// ■ ここに並べる操作を絞っている理由
/// 表示モードによって意味が変わる操作(スクロール系とページ送り系)だけを出す。これは
/// cooViewer自身の使われ方に倣ったもので、あちらもモード別配列(defaultKeyArrayMode2/Mode3)の
/// 既定値に入れているのはスクロール系(action 24〜33)だけである。
struct ModeInputSettingsView: View {
    @EnvironmentObject private var store: KeyBindingStore

    /// いま設定を表示・編集している表示モード。cooViewerのkeyModePopUpButtonに相当する。
    /// 「画面内に収める」はここには現れない ― あれが基本であり、その設定は「キーとマウス」画面が持つ。
    @State private var editingMode: ScalingMode = KeyBindingStore.overridableModes[0]

    /// スクロールできる表示モードでのみ意味を持つ操作。cooViewerがモード別のキー設定に
    /// 入れていたスクロール系(action 24〜29)と対応する。
    private let scrollActions: [ViewerAction] = [
        .scrollAndMoveNext, .scrollAndMovePrevious,
        .scrollAndMoveSpatialLeft, .scrollAndMoveSpatialRight,
        .scrollScreenDown, .scrollScreenUp,
        .scrollDown, .scrollUp, .scrollLeft, .scrollRight,
        .scrollToPageStart, .scrollToPageEnd,
    ]

    /// ページ送り系。スクロール系と同じキー/クリックを奪い合う関係にあるため、
    /// 「このモードでは素直にページ送りのままにしたい」という設定ができるよう一緒に並べる
    /// (ユーザーからの指示)。
    private let pageTurnActions: [ViewerAction] = [
        .moveNext, .movePrevious, .spatialLeft, .spatialRight,
    ]

    private var assignableActions: [ViewerAction] { scrollActions + pageTurnActions }

    /// ホイール(wheelUp/wheelDown)は**あえて含めない**。
    ///
    /// スクロールできるモードでのホイールの扱いは、下の「スクロールできるとき」
    /// (WheelScrollBehavior)が決めており、そこで「ページ送りのみ」を選んだときだけ
    /// 割り当てられた操作が実行される。つまりここにホイールの行を出しても、4つの設定のうち
    /// 3つでは何の効果も無い行が並ぶことになり、かえって分かりにくい。
    ///
    /// cooViewerもホイールは割り当て対象にしていない。あちらの`wheelUp`/`wheelDown`は
    /// prevPage/次ページ表示にハードコードされており(Controller_input.m)、マウス設定の配列に
    /// 入るのはクリック・ドラッグと、マルチタッチのスワイプ(multiTouchAction:のbutton 1000〜)
    /// だけである。ホイールの挙動を決めるのは`CanScrollMode`と`WheelSensitivity`のみ。
    ///
    /// なお、**修飾キー付き**のホイール(option+ホイール)は「スクロールできるとき」を通さず
    /// 必ず割り当てられた操作を行うが、そちらは「マウス」画面での割り当てが全モードに
    /// 適用されるため、ここで重ねて設定できるようにする必要はない
    /// (MouseBindingRow.includesWheel / ViewerView.handleScrollInScrollableMode参照)。

    var body: some View {
        SettingsPaneContainer {
            Section {
                SettingsPickerRow(
                    "Display Mode to Configure",
                    selection: $editingMode,
                    currentTitle: editingMode.titleKey,
                    help: "Settings here override Keyboard and Mouse while this display mode is active. Anything left unassigned keeps working as set there.",
                    controlWidth: 240
                ) {
                    ForEach(KeyBindingStore.overridableModes) { mode in
                        Text(mode.titleKey).tag(mode)
                    }
                }
            } header: {
                Text("Display Mode")
            }

            Section {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(assignableActions) { action in
                        KeyBindingRow(action: action, store: store, mode: editingMode)
                    }
                }
            } header: {
                Text("Keyboard")
            }

            Section {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(assignableActions) { action in
                        MouseBindingRow(
                            action: action, store: store, mode: editingMode,
                            includesWheel: false, includesDrag: false
                        )
                    }
                }
            } header: {
                Text("Mouse")
            } footer: {
                Text("Triggers left unassigned here fall back to the Mouse settings.")
            }

            // この画面の設定はすべて表示モードごとに独立させている。cooViewerのCanScrollModeは
            // アプリ全体で1つの設定だが、それをそのまま持ち込むとこの画面に「モード別のもの」と
            // 「共通のもの」が混在し、どれがどちらか分からなくなる(ユーザーからの指摘)。
            Section {
                SettingsPickerRow(
                    "When Scrolling Is Possible",
                    selection: bindingForWheelBehavior,
                    currentTitle: store.wheelBehavior(in: editingMode).titleKey,
                    help: "When scrolling is not possible — that is, in Fit to Screen — the wheel always performs the action assigned to it in Mouse, whatever you choose here.",
                    controlWidth: 240
                ) {
                    ForEach(WheelScrollBehavior.allCases) { behavior in
                        Text(behavior.titleKey).tag(behavior)
                    }
                }
            } header: {
                Text("Mouse Wheel")
            }

            Section {
                SettingsSlider(
                    "Distance per Scroll Step",
                    value: bindingForScrollStep,
                    in: 5...200,
                    step: 5
                ) { value in
                    "\(Int(value)) pt"
                }
            } header: {
                Text("Scrolling")
            }

            Section {
                Button("Reset This Mode to Defaults", role: .destructive) {
                    store.resetToDefaults(in: editingMode)
                }
                .help("Restores every setting on this page for the selected display mode only.")
            }
        }
    }

    private var bindingForScrollStep: Binding<Double> {
        Binding(
            get: { store.scrollStep(in: editingMode) },
            set: { store.setScrollStep($0, in: editingMode) }
        )
    }

    private var bindingForWheelBehavior: Binding<WheelScrollBehavior> {
        Binding(
            get: { store.wheelBehavior(in: editingMode) },
            set: { store.setWheelBehavior($0, in: editingMode) }
        )
    }

}

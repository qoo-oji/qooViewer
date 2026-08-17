import SwiftUI

/// 環境設定ウインドウの「入力2」タブ。**表示モードによって変わる**キー・マウス操作だけを
/// 扱う(表示モードに依存しない基本の割り当ては「入力」タブ = KeyBindingSettingsView)。
///
/// ■ なぜタブを分けるのか
/// cooViewerは環境設定の入力タブにモード切替ポップアップ(PreferenceController.hの
/// keyModePopUpButton/mouseModePopUpButton)を置き、**1度に1モード分だけ**表示・編集する。
/// qooViewerでも当初これに倣って1つのタブにまとめたが、
///
/// - 基本の設定とモード別の設定を並べると「同じ『画面の左側をクリック』が2つあって、
///   相反する設定ができるように見える」
/// - 逆にポップアップで切り替える形にすると、モードごとに独立させる意味のない操作
///   (ブックマーク・お気に入り・本の移動など)まで各モードに並んでしまう
///
/// という2つの問題が残った(いずれもユーザーからの指摘)。タブごと分けることで、
/// 「入力」タブにはどのモードでも同じように働く設定だけ、この「入力2」タブには
/// モードによって変わる設定だけ、という状態にしている。
///
/// ■ ここに並べる操作を絞っている理由
/// 表示モードによって意味が変わる操作(スクロール系とページ送り系)だけを出す。これは
/// cooViewer自身の使われ方に倣ったもので、あちらもモード別配列(defaultKeyArrayMode2/Mode3)の
/// 既定値に入れているのはスクロール系(action 24〜33)だけである。
struct ModeInputSettingsView: View {
    @EnvironmentObject private var store: KeyBindingStore

    /// いま設定を表示・編集している表示モード。cooViewerのkeyModePopUpButtonに相当する。
    /// 「画面内に収める」はここには現れない ― あれが基本であり、その設定は「入力」タブが持つ。
    @State private var editingMode: ScalingMode = KeyBindingStore.overridableModes[0]

    /// スクロールできる表示モードでのみ意味を持つ操作。cooViewerがモード別のキー設定に
    /// 入れていたスクロール系(action 24〜29)と対応する。
    private let scrollActions: [ViewerAction] = [
        .scrollAndMoveNext, .scrollAndMovePrevious,
        .scrollScreenDown, .scrollScreenUp,
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
    private let mouseTriggers: [InputTrigger] = [.clickLeftZone, .clickRightZone]

    var body: some View {
        SettingsTabContainer {
            Section {
                SettingsPickerRow(
                    "Display Mode to Configure",
                    selection: $editingMode,
                    currentTitle: editingMode.titleKey,
                    caption: "Settings here override the Input tab while this display mode is active. Anything left unassigned keeps working as set there.",
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
            } footer: {
                Text("Only actions whose meaning depends on the display mode are listed here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach(mouseTriggers, id: \.self) { trigger in
                    SettingsPickerRow(
                        trigger.titleKey,
                        selection: bindingForMouse(trigger),
                        currentTitle: store.assignedAction(for: trigger, in: editingMode)?.titleKey ?? "(None)",
                        controlWidth: 240
                    ) {
                        Text("(None)").tag(Optional<ViewerAction>.none)
                        ForEach(assignableActions) { action in
                            Text(action.titleKey).tag(Optional(action))
                        }
                    }
                }
            } header: {
                Text("Mouse")
            } footer: {
                Text("Triggers left unassigned here fall back to the Input tab.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // このタブの設定はすべて表示モードごとに独立させている。cooViewerのCanScrollModeは
            // アプリ全体で1つの設定だが、それをそのまま持ち込むとこのタブに「モード別のもの」と
            // 「共通のもの」が混在し、どれがどちらか分からなくなる(ユーザーからの指摘)。
            Section {
                SettingsPickerRow(
                    "When Scrolling Is Possible",
                    selection: bindingForWheelBehavior,
                    currentTitle: store.wheelBehavior(in: editingMode).titleKey,
                    caption: store.wheelBehavior(in: editingMode).detailKey,
                    controlWidth: 240
                ) {
                    ForEach(WheelScrollBehavior.allCases) { behavior in
                        Text(behavior.titleKey).tag(behavior)
                    }
                }
            } header: {
                Text("Mouse Wheel")
            } footer: {
                Text("When scrolling is not possible — that is, in Fit to Screen — the wheel always performs the action assigned to it on the Input tab, whatever you choose here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button("Reset This Mode to Defaults", role: .destructive) {
                    store.resetToDefaults(in: editingMode)
                }
            } footer: {
                Text("Restores every setting on this tab for the selected display mode only.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bindingForWheelBehavior: Binding<WheelScrollBehavior> {
        Binding(
            get: { store.wheelBehavior(in: editingMode) },
            set: { store.setWheelBehavior($0, in: editingMode) }
        )
    }

    private func bindingForMouse(_ trigger: InputTrigger) -> Binding<ViewerAction?> {
        Binding(
            get: { store.assignedAction(for: trigger, in: editingMode) },
            set: { newAction in
                if let newAction {
                    store.setMouseBinding(newAction, for: trigger, in: editingMode)
                } else {
                    store.clearMouseBinding(for: trigger, in: editingMode)
                }
            }
        )
    }
}

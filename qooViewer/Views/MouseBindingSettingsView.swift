import SwiftUI

/// 環境設定ウインドウの「マウス」画面。
/// 表示モードに依存しない、基本のマウス割り当てだけを扱う
/// (表示モードごとに変わるものは「表示モード別の操作」画面 = ModeInputSettingsView)。
///
/// ■ 「操作 → トリガー」の形にした理由
/// 以前はマウスだけが「トリガー(4択) → 操作をPickerで選ぶ」という逆向きの形で、同じ設定
/// ウインドウの中にキーボードと2つの向きのUIが同居していた。キーボードと同じ
/// 「操作ごとに、割り当てるトリガーを足していく」形へ揃えてある(ユーザーからの指示)。
/// これに伴いトリガーの語彙も「ボタン × 位置 × 修飾キー」「ホイールの向き × 修飾キー」へ
/// 広がった(MouseTrigger参照)。
///
/// ■ ここに並べる操作を絞っている理由
/// キーボードに割り当てられる操作すべてをマウスにも出す必要はない、という判断
/// (ユーザーからの指示)。レイアウト・ブックマーク・お気に入り・表示モードの切り替え・
/// 割合ジャンプは、マウスの限られたトリガーを使ってまで割り当てたいものではないため外し、
/// ページ移動と、拡大鏡・ページ一覧・実寸表示・スライドショーだけを残している。
/// スクロール系はスクロールできる表示モードでしか意味を持たないため、従来どおり
/// 「表示モード別の操作」画面が持つ。
struct MouseBindingSettingsView: View {
    @EnvironmentObject private var store: KeyBindingStore

    /// マウスに割り当てられる操作。並び順の考え方はKeyBindingSettingsViewと同じで、
    /// MANUAL.mdの章立て(ページ送り → 本の移動 → 表示)に沿ってグループでまとめている。
    private let assignableActions: [ViewerAction] = [
        // ページ送り。読み方向に関わらず同じ意味になるmoveNext/movePreviousを先頭に置き、
        // 続けて画面位置基準の送り・見開き調整用の1ページ送り・先頭/末尾ジャンプ。
        .moveNext, .movePrevious,
        .spatialLeft, .spatialRight,
        .shiftOnePageLeft, .shiftOnePageRight,
        .firstPage, .lastPage,
        .spatialEndRight, .spatialEndLeft,
        // 本の移動。
        .previousBook, .nextBook,
        // 表示。cooViewerがホイールクリックにルーペを割り当てているため、拡大鏡を先頭に置く。
        .toggleLoupe, .showThumbnailGrid,
        .showActualSizeLeft, .showActualSizeRight,
        .toggleSlideshow,
    ]

    /// この画面が扱うのは、表示モードに依存しない基本の割り当てだけ。
    private var editingMode: ScalingMode { KeyBindingStore.baseMode }

    var body: some View {
        SettingsPaneContainer {
            Section {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(assignableActions) { action in
                        MouseBindingRow(action: action, store: store, mode: editingMode)
                    }
                }
            } header: {
                Text("Mouse")
            } footer: {
                Text(
                    "Each action can have several triggers. Drag gestures are a stroke of at least 30 points, held for no more than a second. The right button and control-click always open the contextual menu, so they cannot be assigned."
                )
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    store.resetToDefaults(in: editingMode)
                }
                .help("Restores the built-in keyboard and mouse assignments. Nothing else is affected.")
            }
        }
    }
}

/// マウス操作1つ分の行(Gridの1行)。左列に操作名、右列に現在割り当てられているトリガーを
/// 1つずつ縦に並べて表示する(それぞれ×ボタンで外せる)。末尾に+ボタンがあり、押すと
/// メニューから新しいトリガーを選んで追加できる。
///
/// キーボードのKeyBindingRowと対になる作りで、重複時に**追加を拒否して警告を出す**
/// (元の操作から無言で奪わない)ところまで同じ。違いは＋メニューが2階層になっている点で、
/// これはクリックだけで24通りあり、1階層に並べると走査できないため
/// (第1階層で「ボタン・位置」または「ホイールの向き」、第2階層で修飾キーを選ぶ)。
///
/// 「表示モード別の操作」画面(ModeInputSettingsView)からも同じ行を使う。
struct MouseBindingRow: View {
    let action: ViewerAction
    @ObservedObject var store: KeyBindingStore
    /// この行が編集する表示モード。同じトリガーでも、モードが違えば別の操作に割り当ててよい。
    let mode: ScalingMode
    /// ＋メニューにホイールのトリガーを出すか。
    ///
    /// 「表示モード別の操作」画面ではfalseにする。スクロールできるモードでの素のホイールの
    /// 扱いは、その画面の「スクロールできるとき」(WheelScrollBehavior)が決めており、
    /// 4つの設定のうち3つでは割り当てが効かないため、そこに出しても紛らわしいだけである
    /// (修飾キー付きのホイールはWheelScrollBehaviorを通さず必ず効くが、そちらは
    /// 「マウス」画面での割り当てが全モードに適用されるので、ここで重ねる必要がない)。
    var includesWheel: Bool = true
    /// ＋メニューにドラッグジェスチャーのトリガーを出すか。
    ///
    /// 「表示モード別の操作」画面ではfalseにする。ジェスチャーの意味は表示モードで
    /// 変わらないうえ、スクロールできるモードでの左ボタンのドラッグは画像を掴んで動かす
    /// 操作が優先される(ViewerView.ClickZoneView.finishTracking参照)ため、その画面に
    /// 並べても設定できることと実際に起きることが噛み合わない。
    var includesDrag: Bool = true

    /// 追加しようとしたトリガーについての警告。2種類あるため、どちらかをkindで持つ。
    private struct TriggerAlert: Identifiable {
        /// 既に別の操作に割り当て済みだった(追加を拒否した)。
        /// もう一方は、位置指定と「全体」が重なった(追加はしたが、優先順位を知らせる)。
        enum Kind {
            case conflict(existing: ViewerAction)
            case overlap(other: MouseTrigger, otherAction: ViewerAction)
        }
        var id: String { trigger.id }
        let trigger: MouseTrigger
        let kind: Kind
    }

    @State private var alert: TriggerAlert?

    /// この操作に既に割り当て済みのトリガーは、上のチップとして表示されているため、
    /// 追加用メニューからは除外する。他の操作に割り当て済みのものはあえて残しておき、
    /// 選んだ時点で警告する(KeyBindingRow.availableKeysToAddと同じ方針)。
    private func availableTriggers(in group: MouseTrigger.Group) -> [MouseTrigger] {
        group.triggers.filter { store.assignedAction(for: $0, in: mode) != action }
    }

    private var availableGroups: [MouseTrigger.Group] {
        MouseTrigger.groups.filter { group in
            switch group.input {
            case .wheel where !includesWheel: return false
            case .drag where !includesDrag: return false
            default: break
            }
            return !availableTriggers(in: group).isEmpty
        }
    }

    /// 追加したトリガーと「同じボタン・同じ修飾キーで、位置だけが違う」割り当てのうち、
    /// 実際に隠す/隠される関係になるものを探す。
    ///
    /// 位置指定(画面の左側/右側)は「全体」より優先されるため、両方に別々の操作を
    /// 割り当てても破綻はしない(KeyBindingStore.resolvedClickAction参照)。拒否するのは
    /// やりすぎなので、追加は通したうえで、そうなっていることだけ知らせる。
    private func overlappingAssignment(with trigger: MouseTrigger) -> (MouseTrigger, ViewerAction)? {
        guard case .click(let button, let zone) = trigger.input else { return nil }
        let counterparts: [MouseTrigger.Zone] =
            zone == .anywhere ? [.leftHalf, .rightHalf] : [.anywhere]
        for counterpart in counterparts {
            let candidate = MouseTrigger(
                input: .click(button, counterpart), modifiers: trigger.modifiers
            )
            if let existing = store.assignedAction(for: candidate, in: mode), existing != action {
                return (candidate, existing)
            }
        }
        return nil
    }

    private func addTriggerIfAvailable(_ trigger: MouseTrigger) {
        if let existing = store.assignedAction(for: trigger, in: mode), existing != action {
            alert = TriggerAlert(trigger: trigger, kind: .conflict(existing: existing))
            return
        }
        store.addMouseBinding(action, for: trigger, in: mode)
        if let (other, otherAction) = overlappingAssignment(with: trigger) {
            alert = TriggerAlert(
                trigger: trigger, kind: .overlap(other: other, otherAction: otherAction)
            )
        }
    }

    var body: some View {
        GridRow(alignment: .top) {
            Text(action.titleKey)
                .frame(minWidth: 160, alignment: .leading)
                .padding(.top, 2)

            // 複数のトリガーが割り当てられている場合、横に並べると行の高さがバラバラになって
            // かえって見づらいため、1トリガー1行で縦に並べる(追加用の+ボタンは一番下)。
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.triggers(for: action, in: mode)) { trigger in
                    HStack(spacing: 3) {
                        trigger.label
                            .font(.callout)
                        Button {
                            store.removeMouseBinding(for: trigger, in: mode)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove This Trigger")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                }

                Menu {
                    ForEach(availableGroups) { group in
                        Menu {
                            ForEach(availableTriggers(in: group)) { trigger in
                                Button {
                                    addTriggerIfAvailable(trigger)
                                } label: {
                                    modifierLabel(for: trigger)
                                }
                            }
                        } label: {
                            group.label
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a Trigger")
            }
            .gridColumnAlignment(.leading)
        }
        .alert(item: $alert) { alert in
            switch alert.kind {
            case .conflict(let existing):
                return Alert(
                    title: Text("Trigger Already In Use"),
                    message: Text("“") + alert.trigger.label
                        + Text("” is already assigned to “") + Text(existing.titleKey)
                        + Text("”."),
                    dismissButton: .default(Text("OK"))
                )
            case .overlap(let other, let otherAction):
                return Alert(
                    title: Text("Trigger Overlaps Another"),
                    message: Text("“") + other.label + Text("” is assigned to “")
                        + Text(otherAction.titleKey)
                        + Text("”. When both apply, the one that names a side of the screen wins."),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    /// ＋メニューの第2階層に出す、修飾キーだけの名前。
    @ViewBuilder
    private func modifierLabel(for trigger: MouseTrigger) -> some View {
        if let name = trigger.modifiers.displayName {
            Text(verbatim: name)
        } else {
            Text("No Modifier")
        }
    }
}

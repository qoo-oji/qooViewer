import SwiftUI

/// 環境設定ウインドウの「キー・マウス操作」タブ。
/// cooViewerの「入力タブ」に相当する部分を簡略化したもの。
/// キーボードは1つの操作に複数のキーを割り当てられる(1つのキーが割り当てられる操作は1つまで)。
/// マウス(クリック/ホイール)は1トリガーにつき1操作まで、Pickerで選ぶだけのシンプルな形。
struct KeyBindingSettingsView: View {
    @EnvironmentObject private var store: KeyBindingStore

    /// キーボードの一覧に表示する操作の順序。読み方向に関わらず常に同じ意味になる
    /// moveNext/movePreviousを、最もよく使う操作として先頭に表示する
    /// (以前は列挙型の宣言順のままだったが、縦に長く見づらいという指摘を踏まえて並び替えている)。
    private let assignableActions: [ViewerAction] = {
        let priority: [ViewerAction] = [.moveNext, .movePrevious]
        let rest = ViewerAction.allCases.filter { $0 != .none && !priority.contains($0) }
        return priority + rest
    }()
    private let mouseTriggers: [InputTrigger] = [.clickLeftZone, .clickRightZone, .wheelUp, .wheelDown]

    var body: some View {
        Form {
            // 「操作名を上、割り当てキーを下」に積んでいくと項目数分だけ縦に伸びて見づらいため、
            // Gridで「操作名は左列、割り当てキーは右列」の2カラムに揃えて表示する。
            Section("Keyboard (each action can have multiple keys)") {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(assignableActions) { action in
                        KeyBindingRow(action: action, store: store)
                    }
                }
            }

            Section("Mouse") {
                ForEach(mouseTriggers, id: \.self) { trigger in
                    Picker(trigger.titleKey, selection: bindingForMouse(trigger)) {
                        Text("(None)").tag(Optional<ViewerAction>.none)
                        ForEach(assignableActions) { action in
                            Text(action.titleKey).tag(Optional(action))
                        }
                    }
                }
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    store.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func bindingForMouse(_ trigger: InputTrigger) -> Binding<ViewerAction?> {
        Binding(
            get: { store.mouseBindings[trigger] },
            set: { newAction in
                if let newAction {
                    store.setMouseBinding(newAction, for: trigger)
                } else {
                    store.clearMouseBinding(for: trigger)
                }
            }
        )
    }
}

/// キーボード操作1つ分の行(Gridの1行)。左列に操作名、右列に現在割り当てられているキーを
/// 1つずつ縦に並べて表示する(それぞれ×ボタンで外せる)。末尾に+ボタンがあり、押すと
/// メニューから新しいキーを選んで追加できる。
private struct KeyBindingRow: View {
    let action: ViewerAction
    @ObservedObject var store: KeyBindingStore

    /// まだどの操作にも割り当てられていないキー(追加用Pickerの選択肢)。
    /// 既に他の操作へ割り当て済みのキーをここに出すと、選ぶだけで元の操作から
    /// 無言で奪ってしまい紛らわしいため、この行の追加用Pickerには出さない
    /// (奪いたい場合は、まず元の操作側で×ボタンを押して外してから追加する)。
    private var availableKeysToAdd: [RemappableKey] {
        RemappableKey.selectable.filter { store.keyBindings[$0.id] == nil }
    }

    var body: some View {
        GridRow(alignment: .top) {
            Text(action.titleKey)
                .frame(minWidth: 160, alignment: .leading)
                .padding(.top, 2)

            // 複数のキーが割り当てられている場合、横に並べると行の高さがバラバラになって
            // かえって見づらいため、1キー1行で縦に並べる(追加用Pickerは一番下)。
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.keys(for: action)) { key in
                    HStack(spacing: 3) {
                        Text(key.displayName)
                            .font(.callout)
                        Button {
                            store.removeKeyBinding(for: key)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove This Key")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                }

                // 「(キーを追加)」というテキストのPickerだと、割り当て済みのキー(チップ)と
                // 並んだときに文字だけ浮いて見えるため、他のキー同様コンパクトな+ボタンにしている。
                // 押すとメニューで選択可能なキーの一覧が開き、選ぶとその場でaddKeyBindingが呼ばれる
                // (Pickerと違い「現在の選択」を保持し続ける必要がないので、Menu+Buttonの組み合わせで
                // 十分表現できる)。
                Menu {
                    ForEach(availableKeysToAdd) { key in
                        Button(key.displayName) {
                            store.addKeyBinding(action, for: key)
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a Key")
            }
            .gridColumnAlignment(.leading)
        }
    }
}

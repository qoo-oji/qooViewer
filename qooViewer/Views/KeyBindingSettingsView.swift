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
    /// お気に入り関連の操作(toggleFavorite/showFavoritesOrganizer)は、ブックマーク関連の操作
    /// (toggleBookmark/nextBookmark/previousBookmark/showBookmarkList)のすぐ下に並べる
    /// (ユーザーからの指示)。
    ///
    /// showFavoritesList(旧「お気に入り一覧を表示」)は、ツールバーの一覧ボタンを廃止した際に
    /// 他の入り口(メニューバー・コンテキストメニューは階層表示のサブメニューに置き換え済み)を
    /// すべて失い、この一覧に残しておいても割り当てる意味がなくなったため、キー・マウス操作の
    /// 一覧からは意図的に除外している(既定のキー割り当てを外すのではなく、項目自体を表示しない。
    /// ユーザーからの指示)。ViewerAction自体からは削除していない(将来別の入り口を復活させる
    /// 可能性に備えて残してある)。
    private let assignableActions: [ViewerAction] = {
        let priority: [ViewerAction] = [.moveNext, .movePrevious]
        let bookmarkGroup: [ViewerAction] = [.toggleBookmark, .nextBookmark, .previousBookmark, .showBookmarkList]
        let favoriteGroup: [ViewerAction] = [.toggleFavorite, .showFavoritesOrganizer]
        let hidden: [ViewerAction] = [.showFavoritesList]
        let placed = Set(priority + bookmarkGroup + favoriteGroup + hidden)
        let rest = ViewerAction.allCases.filter { $0 != .none && !placed.contains($0) }
        return priority + bookmarkGroup + favoriteGroup + rest
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

    /// 追加用メニューに表示するキーの一覧。この操作に既に割り当て済みのキーは、上の
    /// チップとして表示されているため、ここでは除外する(重複表示を避けるため)。
    /// 他の操作に割り当て済みのキーは、以前はここで非表示にして選べないようにしていたが、
    /// 「どのキーが既に使われているか分からない」という分かりにくさがあったため、あえて
    /// 一覧には残しておき、選んだ時点でaddKeyBindingIfAvailableが競合を検出して警告を出し、
    /// 割り当てを拒否する(元の操作から無言で奪うことはない)。
    private var availableKeysToAdd: [RemappableKey] {
        RemappableKey.selectable.filter { store.keyBindings[$0.id] != action }
    }

    /// 追加しようとしたキーが既に別の操作に割り当てられていた場合に、警告アラートへ
    /// 渡すための情報。どのキーが、どの操作に割り当て済みかをアラートの文面で示すために
    /// 両方保持しておく。
    private struct ConflictingKeyAssignment: Identifiable {
        var id: String { key.id }
        let key: RemappableKey
        let existingAction: ViewerAction
    }

    @State private var conflictingKey: ConflictingKeyAssignment?

    /// 選んだキーを実際にこの操作へ割り当てる前に、既に別の操作へ割り当て済みでないか
    /// 確認する。割り当て済みの場合は追加を行わず(拒否)、どの操作に割り当てられているかを
    /// 示す警告アラートを表示するだけにする。同じ操作への割り当てなら(通常この一覧には
    /// 出てこないが念のため)そのままstore.addKeyBindingへ委ねる。
    private func addKeyBindingIfAvailable(_ key: RemappableKey) {
        if let existingAction = store.action(for: key), existingAction != action {
            conflictingKey = ConflictingKeyAssignment(key: key, existingAction: existingAction)
            return
        }
        store.addKeyBinding(action, for: key)
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
                            addKeyBindingIfAvailable(key)
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
        // 選んだキーが既に別の操作へ割り当て済みだった場合の警告。どのキーがどの操作に
        // 割り当てられているかを文面に含めることで、ユーザーが次にどう対処すべきか
        // (先にその操作側で外すか、別のキーを選ぶか)判断できるようにする。
        .alert(item: $conflictingKey) { conflict in
            Alert(
                title: Text("Shortcut Already In Use"),
                message: Text("“") + Text(conflict.key.displayName)
                    + Text("” is already assigned to “") + Text(conflict.existingAction.titleKey)
                    + Text("”."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

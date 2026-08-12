import SwiftUI

/// 環境設定ウインドウの「キー・マウス操作」タブ。
/// cooViewerの「入力タブ」に相当する部分を簡略化したもの。
/// キーボードは1つの操作に複数のキーを割り当てられる(1つのキーが割り当てられる操作は1つまで)。
/// マウス(クリック/ホイール)は1トリガーにつき1操作まで、Pickerで選ぶだけのシンプルな形。
///
/// Sectionヘッダには「Keyboard (each action can have multiple keys)」のように
/// 説明を括弧書きで足していたが、ヘッダは**場面の見出し**であって説明を置く場所ではない
/// (他タブと同じ方針。SettingsControls.swift参照)。説明はfooterへ移してある。
struct KeyBindingSettingsView: View {
    @EnvironmentObject private var store: KeyBindingStore

    /// キーボードの一覧に表示する操作の順序。以前は「最もよく使う操作(moveNext/movePrevious)を
    /// 先頭に置き、残りは列挙型の宣言順」という並びだったが、宣言順のまま並べた後半部分
    /// (表示切替・ブックマーク・ページ一覧・スライドショー・実寸表示・本の移動が脈絡なく
    /// 入り混じっていた)が見づらいという指摘を踏まえ、MANUAL.mdの章立て(ページ送り→表示・
    /// レイアウト→ページ一覧→ブックマーク→お気に入り→スライドショー・実寸表示→本の移動)と
    /// 同じ流れになるよう、機能ごとのグループにまとめて並べ替えている。
    ///
    /// - ページ送りグループ: 読み方向に関わらず常に同じ意味になるmoveNext/movePreviousを、
    ///   最もよく使う操作として先頭に置き、続けて画面位置基準の送り・見開き調整用の1ページ送り・
    ///   先頭/末尾ジャンプ・割合ジャンプをまとめる
    /// - 表示・レイアウトグループ: 見開き/単ページ・読み方向・拡大縮小モードの切り替えに続けて、
    ///   自動レイアウト(9節)を並べる
    /// - お気に入り関連の操作(toggleFavorite/showFavoritesOrganizer)は、ブックマーク関連の操作
    ///   (toggleBookmark/nextBookmark/previousBookmark/showBookmarkList)のすぐ下に並べる
    ///   (ユーザーからの指示。この点は従来の並びを踏襲)
    ///
    /// showFavoritesList(旧「お気に入り一覧を表示」)は、ツールバーの一覧ボタンを廃止した際に
    /// 他の入り口(メニューバー・コンテキストメニューは階層表示のサブメニューに置き換え済み)を
    /// すべて失い、この一覧に残しておいても割り当てる意味がなくなったため、キー・マウス操作の
    /// 一覧からは意図的に除外している(既定のキー割り当てを外すのではなく、項目自体を表示しない。
    /// ユーザーからの指示)。ViewerAction自体からは削除していない(将来別の入り口を復活させる
    /// 可能性に備えて残してある)。
    private let assignableActions: [ViewerAction] = {
        let navigationGroup: [ViewerAction] = [
            .moveNext, .movePrevious,
            .spatialLeft, .spatialRight,
            .shiftOnePageLeft, .shiftOnePageRight,
            .firstPage, .lastPage,
            .jumpToPercentile0, .jumpToPercentile10, .jumpToPercentile20, .jumpToPercentile30,
            .jumpToPercentile40, .jumpToPercentile50, .jumpToPercentile60, .jumpToPercentile70,
            .jumpToPercentile80, .jumpToPercentile90,
        ]
        let displayGroup: [ViewerAction] = [
            .toggleDisplayMode, .toggleReadingDirection, .cycleScalingMode, .autoLayoutFromCurrentView,
        ]
        let pageListGroup: [ViewerAction] = [.showThumbnailGrid]
        let bookmarkGroup: [ViewerAction] = [.toggleBookmark, .nextBookmark, .previousBookmark, .showBookmarkList]
        let favoriteGroup: [ViewerAction] = [.toggleFavorite, .showFavoritesOrganizer]
        let slideshowAndActualSizeGroup: [ViewerAction] = [
            .toggleSlideshow, .toggleLoupe, .showActualSizeLeft, .showActualSizeRight,
        ]
        let bookNavigationGroup: [ViewerAction] = [.previousBook, .nextBook]
        let hidden: [ViewerAction] = [.showFavoritesList]

        let ordered =
            navigationGroup + displayGroup + pageListGroup + bookmarkGroup + favoriteGroup
            + slideshowAndActualSizeGroup + bookNavigationGroup
        // ViewerActionに新しいケースを追加した際、上記グループへの追加を忘れても一覧から
        // 漏れないよう、どのグループにも含まれていない残りのケースを末尾に補う
        // (通常は空になるはずのセーフティネット)。
        let placed = Set(ordered + hidden)
        let rest = ViewerAction.allCases.filter { $0 != .none && !placed.contains($0) }
        return ordered + rest
    }()
    private let mouseTriggers: [InputTrigger] = [.clickLeftZone, .clickRightZone, .wheelUp, .wheelDown]

    var body: some View {
        SettingsTabContainer {
            // 「操作名を上、割り当てキーを下」に積んでいくと項目数分だけ縦に伸びて見づらいため、
            // Gridで「操作名は左列、割り当てキーは右列」の2カラムに揃えて表示する。
            Section {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(assignableActions) { action in
                        KeyBindingRow(action: action, store: store)
                    }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("An action can have several keys. A key can be assigned to only one action.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                // 操作の選択肢は30個以上あり、いちばん長い項目に合わせて内容幅にすると
                // ポップアップが過大になるので、ここだけ固定幅を渡してコントロールの
                // 境界を4行すべてで揃える(SettingsPickerRowのcontrolWidth参照)。
                ForEach(mouseTriggers, id: \.self) { trigger in
                    SettingsPickerRow(
                        trigger.titleKey,
                        selection: bindingForMouse(trigger),
                        currentTitle: store.mouseBindings[trigger]?.titleKey ?? "(None)",
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
                Text("Each click zone and scroll direction can have one action.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    store.resetToDefaults()
                }
            } footer: {
                Text("Restores the built-in keyboard and mouse assignments. Nothing else is affected.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

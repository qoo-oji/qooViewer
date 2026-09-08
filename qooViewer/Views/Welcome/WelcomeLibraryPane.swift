import SwiftUI

/// ウェルカム画面の帯より下、本体の部分(改善要望5)。コレクションの一覧(タイル)と
/// コレクションの中(カバーの一覧)を切り替えて出す。
///
/// 右上の操作列は両方の画面で共通の部品(LibraryPaneControls)にしてあり、意味だけを
/// 引数で差し替える ―― 「＋」は一覧ならコレクションを作り、中なら本を足す。並べ替えと
/// 大きさのスライダーも、それぞれの画面の対象に効く。**位置と見た目が変わらない**ことを
/// 優先している(中へ入るたびにボタンが動くと、続けて操作するときに目で追う必要が出る)。
struct WelcomeLibraryPane: View {
    @EnvironmentObject private var collectionStore: CollectionStore
    @ObservedObject var state: WelcomeLibraryState
    let library: BookLibrary
    /// 編集操作を許すか(シークレットウインドウでは常にfalse。AppState.isPrivateWindow参照)。
    let allowsEditing: Bool

    private var openedCollection: BookCollection? {
        state.openedCollectionID.flatMap { collectionStore.collection(withID: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 開いていたコレクションが別のウインドウから消された場合は、黙って一覧へ戻す。
            if let collection = openedCollection {
                CollectionDetailView(
                    state: state, collection: collection, allowsEditing: allowsEditing
                )
            } else {
                CollectionGridView(
                    state: state, library: library, allowsEditing: allowsEditing
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 「本を追加」パネル。WelcomeView側には既に名前入力のシートが付いているため、
        // **別のビューに**付ける(SwiftUIでは同じビューに複数の`.sheet`を付けると
        // 後から付けたほうだけが効く)。
        .sheet(
            isPresented: Binding(
                get: { state.addingBooks != nil },
                set: { if !$0 { state.addingBooks = nil } }
            )
        ) {
            if let target = state.addingBooks {
                AddBooksPanel(
                    target: Binding(
                        get: { state.addingBooks ?? target },
                        set: { state.addingBooks = $0 }
                    )
                )
            }
        }
    }
}

/// 一覧・コレクションの中に共通の、右上の操作列。
struct LibraryPaneControls: View {
    /// 「＋」。一覧では新しいコレクション、コレクションの中では本の追加。
    let addHelp: LocalizedStringKey
    let onAdd: () -> Void
    @Binding var isEditing: Bool
    @Binding var sort: FavoritesSortOption
    /// 並べ替えの基準として選ばせるもの。コレクションの中では「更新日時」を出さない
    /// (本の行には後から更新される情報が無いため。CollectionStore.items(in:sort:)参照)。
    let sortFields: [FavoritesSortOption.Field]
    @Binding var size: CGFloat
    let sizeRange: ClosedRange<CGFloat>
    let sizeHelp: LocalizedStringKey
    /// 編集操作を許すか(シークレットウインドウではfalse)。
    let allowsEditing: Bool

    var body: some View {
        HStack(spacing: 6) {
            SidePanelNavButton(
                systemName: "plus", isDisabled: !allowsEditing || !isEditing, help: addHelp
            ) {
                onAdd()
            }
            WelcomeEditToggle(isEditing: $isEditing, isDisabled: !allowsEditing)
            WelcomeSortMenu(option: $sort, fields: sortFields)
            // ネイティブのスライダーはつまみが白く、明るい面の上で見えなくなる。輪郭ではなく
            // 溝を敷く(panelControlWellのコメント参照)。
            Slider(value: $size, in: sizeRange)
                .frame(width: 110)
                .panelControlWell()
                .help(sizeHelp)
        }
    }
}

/// 編集モードのトグル。選択中の見た目はサイドパネルのモードスイッチャと同じ
/// (アクセント地 + 反対色の縁)。
private struct WelcomeEditToggle: View {
    @Binding var isEditing: Bool
    let isDisabled: Bool

    var body: some View {
        Button {
            isEditing.toggle()
        } label: {
            Image(systemName: isEditing ? "checkmark" : "pencil")
                .font(.system(size: 15, weight: .medium))
                // 押していないときは地がほぼ無いので輪郭を掛ける。押している間は不透明な
                // アクセント地があるので掛けない(SidePanelModeSwitcherと同じ判断)。
                .panelOutlinedContent(isEnabled: !isEditing)
                .frame(width: PanelIconButtonLabel.width, height: PanelIconButtonLabel.height)
                .background(
                    RoundedRectangle(cornerRadius: PanelIconButtonLabel.cornerRadius, style: .continuous)
                        .fill(isEditing ? Color.accentColor : Color.clear)
                )
                .panelOutlinedAccent(
                    in: RoundedRectangle(
                        cornerRadius: PanelIconButtonLabel.cornerRadius, style: .continuous
                    ),
                    isEnabled: isEditing
                )
                .foregroundStyle(isEditing ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help("Edit")
    }
}

/// 並べ替えメニュー。基準と向きを区切り線で分けた2つのPickerにするのは、サイドパネルの
/// 並べ替え(SidePanelSortMenu)と同じ理由 ―― チェックマークの位置と字下げをSwiftUIに任せる。
private struct WelcomeSortMenu: View {
    @Binding var option: FavoritesSortOption
    let fields: [FavoritesSortOption.Field]

    var body: some View {
        Menu {
            Picker(selection: fieldBinding) {
                ForEach(fields) { field in
                    Text(field.titleKey).tag(field)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)

            Divider()

            Picker(selection: ascendingBinding) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .panelIconButtonLabel()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: PanelIconButtonLabel.width)
        .help("Sort By")
    }

    private var fieldBinding: Binding<FavoritesSortOption.Field> {
        Binding(
            get: { option.field },
            set: { option = FavoritesSortOption(field: $0, ascending: option.isAscending) }
        )
    }

    private var ascendingBinding: Binding<Bool> {
        Binding(
            get: { option.isAscending },
            set: { option = FavoritesSortOption(field: option.field, ascending: $0) }
        )
    }
}

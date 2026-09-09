import SwiftUI

/// ウェルカム画面いちばん上の帯(改善要望5)。左に本を開く2つの入り口、中央にライブラリの
/// 並び、右端にライブラリを増やす「＋」。
///
/// ■ 2つのボタンの幅を揃える
/// 「本を開く…」と「履歴から開く」は同じ役割の並びなので、長いほうのラベルに合わせて同じ幅に
/// する(MetadataButtonWidthEstimatorの実測。ローカライズ済みの文字列を測るため、表示言語が
/// 変われば幅も変わる)。`.frame(maxWidth: .infinity)`で揃えないのは、帯の幅いっぱいまで
/// 間延びしてしまうため。
///
/// ■ 輪郭(すりガラス面の決まりごと)
/// - 2つのボタン → `.panelControlWell()`。**「標準のボタンは自前の不透明な地を持つから何も
///   要らない」は誤り**だった ―― この面の背後にはウインドウ外を透かすすりガラス
///   (`BehindWindowVisualEffectView`)が敷いてあり、その上のAppKitのボタンのベゼルは
///   下地に合わせて描かれる。重ね色を文字色そのもの(ダーク+白100%)にすると、ベゼルも
///   文字も面に溶けて**ボタンが2つとも跡形もなく消える**(実測。作り直す前のウェルカム画面の
///   「開く…」も同じ状態だった)。輪郭ではなく溝を敷くのはスライダーと同じ理由で、
///   ベゼルの落ち影までシルエットに含めて太らせるとにじむため。溝だけでは**文字**が
///   薄いままなので、ラベルには併せて`.panelOutlinedContent()`も掛ける(溝は形を、輪郭は
///   文字を救う。どちらも「文字の影」の設定が0なら1ピクセルも変わらない)。
/// - 区切り線 → `.panelOutlinedContent()`。細い線1本なので、これも面に溶けて消える
/// - 「＋」 → `.panelIconButtonLabel()`が内側で輪郭を掛けている
/// - ライブラリ名 → 未選択は`.panelOutlinedContent()`、選択中はアクセント地なので
///   `.panelOutlinedAccent(in:)`(地の色と重ね色が近いと、どれを選んでいるか分からなくなる)
struct WelcomeTopBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.locale) private var locale
    @ObservedObject var state: WelcomeLibraryState
    /// 編集操作を許すか(シークレットウインドウではfalse)。
    let allowsEditing: Bool
    let selectedLibraryID: UUID?

    /// ライブラリの作成・リネーム・削除ができるか。**下のペインの編集モードと同じ鍵で開ける** ――
    /// 「編集モード中だけ棚をいじれる」という規則を帯にも通すため(閲覧しているだけのときに
    /// 右クリックからライブラリを消せてしまわない)。
    private var canEditLibraries: Bool { allowsEditing && state.isEditing }

    static let height: CGFloat = 44

    @State private var isShowingRecentBooks = false
    /// 出しているライブラリの名前入力。**2つの`.sheet`を同じビューに付けない**ため、作成と
    /// リネームを1つの状態にまとめている(SwiftUIでは同じビューに複数のシートを付けると
    /// 後から付けたほうだけが効く)。
    @State private var librarySheet: LibrarySheet?
    @State private var deletingLibraryID: UUID?

    private enum LibrarySheet {
        case create
        case rename(UUID)
    }

    var body: some View {
        HStack(spacing: 8) {
            // **幅はボタンではなくラベルに与える。** `Button(...).frame(width:)`だと、与えた
            // 幅はレイアウト上の枠にしか効かず、実際に描かれるベゼルは文字列の長さのまま枠の
            // 中央に置かれる(実測: 「本を開く…」82pt / 「履歴から開く」96pt)。ラベル側を
            // 同じ幅にすれば、ベゼルもその幅+左右のインセットで揃う。
            // 余白(chrome)を0にしているのはそのため ―― 足すのはmacOS側で、こちらは
            // 「文字が省略されずに収まる幅」だけを測る。
            //
            // 揃える相手は**実際に並んでいるボタンだけ**。「履歴から開く」を出さない設定の
            // ときにその幅まで見込むと、1つきりの「本を開く…」が理由もなく間延びする。
            let labelWidth = MetadataButtonWidthEstimator.equalWidth(
                for: [String(localized: "Open Book…", language: locale)]
                    + (preferences.showRecentFilesOnWelcome
                        ? [String(localized: "Open from History", language: locale)] : []),
                minWidth: 90,
                chrome: 0
            )
            Button {
                appState.openWithPanel()
            } label: {
                Text("Open Book…").panelOutlinedContent().frame(width: labelWidth)
            }
            .keyboardShortcut("o", modifiers: .command)
            .panelControlWell()
            // 環境設定「一般」の「最近開いたファイルを表示」がOFFなら、この入り口ごと出さない
            // (以前のウェルカム画面で一覧の列を出さなかったのと同じ意味。履歴そのものは
            // サイドパネルの「履歴」モードとファイルメニューの「Open Recent」に残る)。
            if preferences.showRecentFilesOnWelcome {
                Button {
                    isShowingRecentBooks = true
                } label: {
                    Text("Open from History").panelOutlinedContent().frame(width: labelWidth)
                }
                .panelControlWell()
                // シークレットウインドウでは履歴を一切見せない
                // (AppState.isPrivateWindowのコメント参照)。
                .disabled(appState.isPrivateWindow)
                .popover(isPresented: $isShowingRecentBooks, arrowEdge: .bottom) {
                    RecentBooksPopover()
                }
            }

            Divider()
                .frame(height: 22)
                .panelOutlinedContent()

            libraryChips

            Spacer(minLength: 0)

            Button {
                librarySheet = .create
            } label: {
                Image(systemName: "plus")
                    .panelIconButtonLabel()
            }
            .buttonStyle(.borderless)
            .disabled(!canEditLibraries)
            .help("New Library")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .sheet(
            isPresented: Binding(
                get: { librarySheet != nil },
                set: { if !$0 { librarySheet = nil } }
            )
        ) {
            librarySheetContent
        }
        .alert(
            "Delete Library?",
            isPresented: Binding(
                get: { deletingLibraryID != nil },
                set: { if !$0 { deletingLibraryID = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { deletingLibraryID = nil }
            Button("Delete", role: .destructive) {
                if let library = deletingLibraryID.flatMap({ collectionStore.library(withID: $0) }) {
                    collectionStore.delete(library)
                }
                deletingLibraryID = nil
            }
        } message: {
            Text("Every collection in this library is removed too. The books themselves are not deleted.")
        }
    }

    @ViewBuilder
    private var librarySheetContent: some View {
        switch librarySheet {
        case .create:
            CollectionNameSheet(
                kind: .newLibrary,
                initialName: "",
                isDuplicate: { collectionStore.hasLibraryNamed($0) },
                onCommit: { name in
                    if let created = collectionStore.createLibrary(name: name) {
                        state.selectedLibraryID = created.id
                        state.openedCollectionID = nil
                    }
                }
            )
        case .rename(let libraryID):
            if let library = collectionStore.library(withID: libraryID) {
                CollectionNameSheet(
                    kind: .renameLibrary,
                    initialName: library.name,
                    isDuplicate: { collectionStore.hasLibraryNamed($0, excluding: library) },
                    onCommit: { name in collectionStore.rename(library, to: name) }
                )
            }
        case nil:
            EmptyView()
        }
    }

    /// ライブラリ名の並び。数が増えると帯に収まらないので横スクロールにする。
    private var libraryChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(collectionStore.libraries, id: \.id) { library in
                    chip(for: library)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        // 横スクロールでも帯の高さを超えないようにする。
        .frame(maxHeight: Self.height)
    }

    @ViewBuilder
    private func chip(for library: BookLibrary) -> some View {
        let isSelected = library.id == selectedLibraryID
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let button = Button {
            guard !isSelected else { return }
            state.selectedLibraryID = library.id
            // 別のライブラリへ移ったら、開いていたコレクションからは出る(そのコレクションは
            // 今のライブラリには無いため)。
            state.openedCollectionID = nil
        } label: {
            Text(library.name)
                .lineLimit(1)
                // 選択中は不透明なアクセント地があるので輪郭は掛けない
                // (SidePanelModeSwitcherと同じ判断)。
                .panelOutlinedContent(isEnabled: !isSelected)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(shape.fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07)))
                .panelOutlinedAccent(in: shape, isEnabled: isSelected)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .contentShape(shape)
        }
        .buttonStyle(.plain)

        // 項目が空になるcontextMenuは付けない(CollectionGridView.tileと同じ判断)。
        if canEditLibraries {
            button.contextMenu {
                Button("Rename…") { librarySheet = .rename(library.id) }
                // 最後の1つは消させない ―― ライブラリが無くなるとコレクションを置く先が
                // 無くなり、画面が操作できなくなる(CollectionStore.delete(_ library:)参照)。
                if collectionStore.libraries.count > 1 {
                    Button("Delete…", role: .destructive) { deletingLibraryID = library.id }
                }
            }
        } else {
            button
        }
    }
}

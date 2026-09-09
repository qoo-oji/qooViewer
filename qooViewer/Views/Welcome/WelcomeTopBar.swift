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

    /// ライブラリの作成・リネーム・削除ができるか。
    ///
    /// 当初は**下のペインの編集モードと同じ鍵**にしていたが、やめた(ユーザー指摘 2026-09-09)。
    /// 帯とペインは区切り線で分かれた別の領域に見えるのに、**区切り線の下のボタンを押さないと
    /// 区切り線の上の名前を変えられない**のは筋が通らない。しかも編集モード外の右クリックは
    /// メニューすら出ない(項目が空のcontextMenuは付けない方針)ので、手がかりがゼロだった。
    ///
    /// ペインに編集モードがあるのは、クリックの意味が変わる(開く/選ぶ)ことと、まとめて削除する
    /// ための選択が要るからで、帯にはどちらの事情も無い ―― チップのクリックは常に切り替えだけ、
    /// リネームと削除は右クリックからしか辿れず、削除は確認も出す。塞ぐのはシークレット
    /// ウインドウ(保存データを書かない)だけでよい。
    private var canEditLibraries: Bool { allowsEditing }

    static let height: CGFloat = 44

    /// ライブラリ名の幅。**名前の長さでは変えない**(ユーザー指摘 2026-09-09 ―― 幅が名前ごとに
    /// 変わるチップが並ぶのは落ち着かない)。左の2つのボタンと同じ見積もりから求めて、帯の中の
    /// 刻みを1つに保つ。
    ///
    /// 「履歴から開く」を出さない設定でも**両方の文字列を測る** ―― あちらのラベル幅は実際に
    /// 並んでいるボタンだけで決めているが、こちらまで連動させると、無関係な設定を切り替えた
    /// だけでライブラリの幅が変わる。
    private var chipLabelWidth: CGFloat {
        MetadataButtonWidthEstimator.equalWidth(
            for: [
                String(localized: "Open Book…", language: locale),
                String(localized: "Open from History", language: locale),
            ],
            minWidth: 90,
            chrome: 0
        )
    }

    @State private var isShowingRecentBooks = false
    /// 出しているライブラリの名前入力。**2つの`.sheet`を同じビューに付けない**ため、作成と
    /// リネームを1つの状態にまとめている(SwiftUIでは同じビューに複数のシートを付けると
    /// 後から付けたほうだけが効く)。
    @State private var librarySheet: LibrarySheet?
    @State private var deletingLibraryID: UUID?
    /// いまドラッグしているチップ。落とし先の印を、掴んだチップ自身には出さないために持つ。
    @State private var draggingLibraryID: UUID?
    /// ドラッグが乗っているチップ。左端に挿入位置の線を出す。
    @State private var dropTargetLibraryID: UUID?

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
                    // 既定のライブラリは表示している見出しを初期値にする
                    // (BookLibrary.displayName参照)。
                    initialName: library.displayName(language: locale),
                    isDuplicate: { collectionStore.hasLibraryNamed($0, excluding: library) },
                    onCommit: { name in collectionStore.rename(library, to: name) }
                )
            }
        case nil:
            EmptyView()
        }
    }

    /// 落としたチップを、落とし先のチップが居た位置へ入れる(Safariのタブと同じ感じ方)。
    /// どう解釈するかは画面の都合なので、番号の振り直しだけをCollectionStoreへ渡す。
    private func move(libraryWithID draggedID: UUID, onto target: BookLibrary) -> Bool {
        guard draggedID != target.id else { return false }
        var ids = collectionStore.libraries.map(\.id)
        guard let from = ids.firstIndex(of: draggedID),
              let to = ids.firstIndex(of: target.id)
        else { return false }
        ids.remove(at: from)
        ids.insert(draggedID, at: to)
        collectionStore.reorderLibraries(ids)
        return true
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
            Text(library.displayName(language: locale))
                .lineLimit(1)
                .truncationMode(.middle)
                // 幅は名前によらず一定(chipLabelWidthのコメント参照)。収まらない名前は
                // 中略して出し、全体はツールチップで読める。
                .frame(width: chipLabelWidth)
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
        .help(library.displayName(language: locale))
        .opacity(draggingLibraryID == library.id ? 0.35 : 1)
        // 落とし先の印。**チップを丸ごと縁取る。**
        // 最初は左端に細い挿入線を出していたが、ドラッグ中は指の下にドラッグの絵が乗るので、
        // 線が隠れて何も見えなかった(実測)。縁なら絵の外側に残る。
        // 掴んだチップ自身には出さない(そこへ落としても何も起きないため)。
        .overlay {
            if dropTargetLibraryID == library.id, draggingLibraryID != library.id {
                shape.strokeBorder(Color.accentColor, lineWidth: 2)
                    // 面をアクセント色で塗られると縁が地に溶けるので輪郭を掛ける
                    // (すりガラス面の決まりごと。選択中の枠と同じ判断)。
                    .panelOutlinedAccent(in: shape)
            }
        }
        .modifier(
            LibraryChipReorder(
                isEnabled: canEditLibraries,
                library: library,
                title: library.displayName(language: locale),
                draggingLibraryID: $draggingLibraryID,
                dropTargetLibraryID: $dropTargetLibraryID,
                onDrop: { droppedID in move(libraryWithID: droppedID, onto: library) }
            )
        )

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

/// 帯のライブラリを掴んで並べ替えるための修飾(ユーザー要望 2026-09-09)。
///
/// **修飾子として切り出してある理由。** `.draggable`/`.dropDestination` は条件で付けたり
/// 外したりしたいのに(シークレットウインドウでは並べ替えさせない)、`if` で分岐すると
/// SwiftUI から見て別のビューになり、チップが作り直される ―― 選択中のアクセント地が
/// 一瞬消える、という形で出る。`ViewModifier` にして中で分岐すれば、同じビューのまま
/// 効き目だけを切り替えられる。
///
/// 運ぶのは `BookLibrary.id` の文字列。`Transferable` に適合した専用の型は作らない ――
/// このアプリの中でしか意味を持たない値で、外のアプリへ落としても何も起きないほうがよい
/// (文字列なら受け取り側が無視するだけで済む)。
private struct LibraryChipReorder: ViewModifier {
    let isEnabled: Bool
    let library: BookLibrary
    /// ドラッグ中に出す絵の文字。既定のライブラリはDBの文字列を表示に使わないので、
    /// 呼び出し側が`displayName(language:)`を解決して渡す(BookLibrary.displayName参照)。
    let title: String
    @Binding var draggingLibraryID: UUID?
    @Binding var dropTargetLibraryID: UUID?
    /// 落とせたらtrue。falseなら元の位置へ戻る。
    let onDrop: (UUID) -> Bool

    func body(content: Content) -> some View {
        content
            // `.draggable(_:preview:)`ではなく`.onDrag(_:preview:)`を使う ―― **掴んだ瞬間が
            // 分かる口が要る**ため(掴んでいるチップを淡く描いて、どれが動いているのかを見せる)。
            // `.draggable`にはその契機が無い。
            .onDrag {
                guard isEnabled else { return NSItemProvider() }
                draggingLibraryID = library.id
                return NSItemProvider(object: library.id.uuidString as NSString)
            } preview: {
                // ドラッグ中に指の下へ出す絵。**自前の地を持たせる** ―― 文字だけにすると、
                // 下を通るチップの文字と重なって両方読めなくなる(実測)。選択中の
                // アクセント地は引き継がない(滑っている最中に落とし先が見えにくいため)。
                Text(title)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }
            .dropDestination(for: String.self) { items, _ in
                dropTargetLibraryID = nil
                draggingLibraryID = nil
                guard isEnabled,
                      let first = items.first,
                      let droppedID = UUID(uuidString: first)
                else { return false }
                return onDrop(droppedID)
            } isTargeted: { isTargeted in
                if isTargeted {
                    dropTargetLibraryID = library.id
                } else if dropTargetLibraryID == library.id {
                    dropTargetLibraryID = nil
                }
            }
    }
}

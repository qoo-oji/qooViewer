import SwiftUI

/// ウェルカム画面いちばん上の帯(改善要望5)。左にライブラリの並び、右端にライブラリを増やす「＋」。
///
/// ■ 左端の「ファイルブラウザ」(改善要望7 段階3、2026-09-13)
/// 押すとファイルブラウザを出す(WelcomeLibraryState.selectMode。出ている間にもう一度押してもそのまま ―― 以前は本棚へ
/// 戻っていた。2026-09-23、利用者の指示)。ファイルブラウザの間はどのライブラリのチップも選ばれていない見た目にし、
/// チップを押すと本棚へ戻る。
///
/// ■ 左端の2つのボタン「本を開く…」「履歴から開く」(v1.50〜v1.56 の形)
/// 2026-09-13 に撤去した(改善要望7 ―― 左端をファイルブラウザへの切り替えに譲った。本を開くのはファイルメニューの
/// 「開く…」(⌘O)、履歴はファイルメニューの「最近使った項目を開く」とサイドパネルの「履歴」モードに残る)。
/// 2026-09-21 から、**環境設定「ファイルブラウザを有効にする」がOFFの間だけ**戻している(ユーザー要望: ファイルブラウザを
/// 使わないなら、ホームはファイルブラウザが入る前の形に戻る)。ONの間は今までどおり、左端は切り替えのボタン。
///
/// 2つのボタンにはAppKitのベゼルが面に溶けて消える問題があり、`.panelControlWell()`で溝を敷く
/// (重ね色を文字色そのもの ―― ダーク+白100% ―― にするとベゼルも文字も跡形もなく消えた。実測)。溝だけでは**文字**が
/// 薄いままなので、ラベルには併せて`.panelOutlinedContent()`も掛ける(溝は形を、輪郭は文字を救う)。
/// 当時との違い: 「履歴から開く」を出すかどうかの設定(showRecentFilesOnWelcome)は同じ日に撤去したので常に出す。
/// 「本を開く…」に ⌘O は付けない(ファイルメニューの「開く…」が持っている)。
///
/// ■ 輪郭(すりガラス面の決まりごと)
/// - 「＋」 → `.panelIconButtonLabel()`が内側で輪郭を掛けている
/// - 「ファイルブラウザ」 → 押していないときは`.panelOutlinedContent()`、押している間はアクセント地
///   なので`.panelOutlinedAccent(in:)`(ライブラリのチップと同じ描き方)
/// - ライブラリ名 → 未選択は`.panelOutlinedContent()`、選択中はアクセント地なので
///   `.panelOutlinedAccent(in:)`(地の色と重ね色が近いと、どれを選んでいるか分からなくなる)
struct WelcomeTopBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var collectionStore: CollectionStore
    @Environment(\.locale) private var locale
    /// 選択中のチップ・ファイルブラウザの切り替えの色(ウインドウが後ろなら灰色。`SelectionEmphasis`)。
    @Environment(\.appearsActive) private var appearsActive
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
    /// 変わるチップが並ぶのは落ち着かない)。
    ///
    /// 見積もりの材料は、左端の2つのボタン(型コメント)のラベル。ボタンが出ていない(ファイルブラウザ機能がONの)間も
    /// **チップの幅を変えないために同じ2つの文字列を測る**。ボタンのラベルの幅にもこの値を使う(帯の中の刻みを1つに保つ)。
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

    /// 出しているライブラリの名前入力。**2つの`.sheet`を同じビューに付けない**ため、作成と
    /// リネームを1つの状態にまとめている(SwiftUIでは同じビューに複数のシートを付けると
    /// 後から付けたほうだけが効く)。
    /// 「履歴から開く」のポップオーバー(ファイルブラウザ機能がOFFの間の帯。型コメント)。
    @State private var isShowingRecentBooks = false
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
            // 環境設定「ファイルブラウザを有効にする」がOFFの間は、切り替えのボタンと区切りを出さない
            // (ファイルブラウザを足す前の帯の形。2026-09-21、ユーザー要望)。
            if state.isFileBrowserFeatureEnabled {
                fileBrowserToggle
            } else {
                openButtons
            }
            // スマートライブラリ(2026-09-21、利用者の指示: ファイルブラウザとライブラリの間)。ファイルブラウザ(または本を開く
            // 2 つの入り口)とも役割が違うので区切る(2026-09-22、利用者の指示)。環境設定で OFF なら出さない(2026-09-22)。
            if state.isSmartLibraryFeatureEnabled {
                WelcomeSeparator(axis: .vertical, length: 20)
                smartLibraryToggle
            }
            // 左端(モードの切り替え、または本を開く2つの入り口)とライブラリの並び(本棚の中の選択)は別の役割なので区切る
            // (ユーザー要望 2026-09-13)。ライブラリ機能が OFF なら並びも「＋」も出さない(帯はスマートライブラリのために出ている)。
            if state.isLibraryFeatureEnabled {
                WelcomeSeparator(axis: .vertical, length: 20)
                libraryChips
            }

            Spacer(minLength: 0)

            if state.isLibraryFeatureEnabled {
                Button {
                    librarySheet = .create
                } label: {
                    Image(systemName: "plus")
                        .panelIconButtonLabel()
                }
                .buttonStyle(.borderless)
                .disabled(!canEditLibraries)
                .help("New Library")
                .accessibilityLabel(Text("New Library"))
            }
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
        // メニューバーの「ホーム」メニューから(WelcomeLibraryState.menuRequestのコメント)。右クリックと同じ状態を立てる。
        .onChange(of: state.menuRequest) { _, _ in
            guard canEditLibraries,
                  let kind = state.takeMenuRequest(where: {
                      switch $0 {
                      case .createLibrary, .renameLibrary, .deleteLibrary: true
                      default: false
                      }
                  })
            else { return }
            switch kind {
            case .createLibrary:
                librarySheet = .create
            case .renameLibrary(let id):
                librarySheet = .rename(id)
            case .deleteLibrary(let id):
                // 最後の1つは消させない(右クリックと同じ。メニュー側も淡色にしてある)。
                if collectionStore.libraries.count > 1 { deletingLibraryID = id }
            default:
                break
            }
        }
    }

    /// ファイルブラウザを出す(出ている間に押してもそのまま。`WelcomeLibraryState.selectMode`)。
    ///
    /// **アイコンではなく「ファイルブラウザ」と文字で出す**(ユーザー指示 2026-09-13)。フォルダの絵だけでは
    /// 何に切り替わるボタンなのか読めなかった。見た目はライブラリのチップと同じ形(地・角丸・余白)に揃え、
    /// **幅は文字に合わせる**(チップのように固定幅にしない。横長になってよい、というユーザーの指定)。
    /// チップと区別できるよう、先頭にフォルダのアイコンを添える。
    private var fileBrowserToggle: some View {
        let isBrowsing = state.mode == .browser
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button {
            state.selectMode(.browser)
        } label: {
            Label("File Browser", systemImage: "folder")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                // 選択中は不透明な地(アクセント色 / 後ろでは灰色)があるので輪郭は掛けない(チップと同じ判断)。
                .panelOutlinedContent(isEnabled: !isBrowsing)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(shape.fill(isBrowsing ? SelectionEmphasis.fill(isActive: appearsActive) : Color.primary.opacity(0.07)))
                .panelOutlinedAccent(in: shape, isEnabled: isBrowsing)
                .foregroundStyle(isBrowsing ? SelectionEmphasis.foreground(isActive: appearsActive) : Color.primary)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        // 輪郭(panelOutlinedContent)が文字を重ねて描くので、読み上げの名前は明示する(付けないと「ボタン」としか読まれなかった。
        // 2026-09-22 の実機検証)。
        .accessibilityLabel(Text("File Browser"))
        .accessibilityAddTraits(isBrowsing ? .isSelected : [])
    }

    /// スマートライブラリを出す(2026-09-21。出ている間に押してもそのまま)。形はファイルブラウザの切り替えと同じ(文字 + アイコン、幅は文字に合わせる)。
    private var smartLibraryToggle: some View {
        let isShowing = state.mode == .smart
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button {
            state.selectMode(.smart)
        } label: {
            Label("Smart Library", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .panelOutlinedContent(isEnabled: !isShowing)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(shape.fill(isShowing ? SelectionEmphasis.fill(isActive: appearsActive) : Color.primary.opacity(0.07)))
                .panelOutlinedAccent(in: shape, isEnabled: isShowing)
                .foregroundStyle(isShowing ? SelectionEmphasis.foreground(isActive: appearsActive) : Color.primary)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Smart Library"))
        .accessibilityAddTraits(isShowing ? .isSelected : [])
    }

    /// 「本を開く…」「履歴から開く」(型コメント「左端の2つのボタン」)。
    ///
    /// **幅はボタンではなくラベルに与える。** `Button(...).frame(width:)`だと、与えた幅はレイアウト上の枠にしか効かず、
    /// 実際に描かれるベゼルは文字列の長さのまま枠の中央に置かれる(実測: 「本を開く…」82pt / 「履歴から開く」96pt)。
    /// ラベル側を同じ幅にすれば、ベゼルもその幅+左右のインセットで揃う(同じ役割の並びなので幅を揃える)。
    @ViewBuilder
    private var openButtons: some View {
        Button {
            appState.openWithPanel()
        } label: {
            Text("Open Book…").panelOutlinedContent().frame(width: chipLabelWidth)
        }
        .panelControlWell()
        .accessibilityLabel(Text("Open Book…"))
        Button {
            isShowingRecentBooks = true
        } label: {
            Text("Open from History").panelOutlinedContent().frame(width: chipLabelWidth)
        }
        .panelControlWell()
        .accessibilityLabel(Text("Open from History"))
        // シークレットウインドウでは履歴を一切見せない(AppState.isPrivateWindowのコメント参照)。
        .disabled(appState.isPrivateWindow)
        .popover(isPresented: $isShowingRecentBooks, arrowEdge: .bottom) {
            RecentBooksPopover()
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
                onCommit: { name, _ in
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
                    onCommit: { name, _ in collectionStore.rename(library, to: name) }
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
        // ファイルブラウザの間はどのチップも選ばれていない見た目にする(型コメント)。
        let isSelected = library.id == selectedLibraryID && state.mode == .shelf
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let button = Button {
            // 選択中のライブラリをもう一度押したら、そのライブラリのコレクション一覧へ戻る
            // (ユーザー要望 2026-09-13)。以前は何も起きなかったが、コレクションの中にいるとき
            // 「ライブラリの名前を押す = そのライブラリの一番上へ」と読むのが自然。
            // **検索は残す** ―― ライブラリは移っていないので、戻るボタンと同じ扱いにする
            // (WelcomeLibraryState.searchTextのコメント参照)。
            // ファイルブラウザの間にチップを押したら本棚へ戻る。見ていたライブラリのチップなら、
            // 開いていたコレクションもそのまま(離れたときの棚へ戻る)。
            // スマートライブラリの間も同じ(本棚へ戻る)。
            if state.mode != .shelf {
                state.mode = .shelf
                if library.id == selectedLibraryID { return }
            }
            guard !isSelected else {
                state.openedCollectionID = nil
                return
            }
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
                .background(shape.fill(isSelected ? SelectionEmphasis.fill(isActive: appearsActive) : Color.primary.opacity(0.07)))
                .panelOutlinedAccent(in: shape, isEnabled: isSelected)
                .foregroundStyle(isSelected ? SelectionEmphasis.foreground(isActive: appearsActive) : Color.primary)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(library.displayName(language: locale))
        .accessibilityLabel(Text(verbatim: library.displayName(language: locale)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

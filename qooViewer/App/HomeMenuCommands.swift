import AppKit
import SwiftUI

// メニューバーのホーム画面(本棚・ファイルブラウザ)向けの項目(2026-09-15、ユーザー決定)。
//
// ■ 置き場所
// - 「ホーム」メニュー(新設。表示・移動の右): ライブラリ・コレクションの操作と、本棚 ⇄ ファイルブラウザの切り替え
// - ファイルメニュー: ファイルブラウザで選んだ項目を開く・名前を変更・ゴミ箱・圧縮・展開(Finder と同じくファイルそのものへの操作)
// - 編集メニュー: ここに項目を移動・検索
// - 表示メニュー: ホーム画面の間だけ中身を入れ替える(表示形式・並べ替え・大きさ・列)
// 名前の由来と割り振りの議論は docs/09-ui-and-windows.md「メニューバー」。
//
// ■ 決まりごと
// - **項目の数を状態で変えない**(MenuBarMenuGate の型コメント)。使えないときは淡色。「ホーム」メニューは本を読んでいる
//   ウインドウでも同じ並びのまま全部淡色になる。表示メニューの入れ替えは、本を開く・閉じるときだけ(「移動」メニューと同じ)。
// - 値はフォーカス中のウインドウの MenuCheckmarkState(値型)から読む。ライブラリとコレクションの名前は
//   HomeMenuDirectoryStore の写しから読む(CollectionStore そのものはメニューにつながない)。
// - 「ホーム」メニューにはショートカットを付けない(ユーザー判断。使ってみて欲しくなったら空いているキーから選ぶ)。
//   ファイル・編集・表示に載せる項目は、既にキーで動くもの・macOS の標準のキーがあるものだけ表示する。
// - 閉包は AppState を weak で持つ(メニュー項目は次の作り直しまで閉包を抱えるので、閉じたウインドウを残さない)。
//   Binding の `get` も値だけを捕まえる(`[home]`)。`home` を素のまま読むと構造体ごと ―― AppState を強く持つ `appState` ごと ―― 捕まえる
//   (2026-09-15 の 4 回目の監査)。

/// ⌘⌫・⌘↓ など、テキストの欄でも意味を持つキーをメニューが受けたときの振り分け。
///
/// キーの押下は、キーウインドウのビューが `performKeyEquivalent` で引き受けなければ**一覧の `keyDown` より先に
/// メニューへ届く**。名前の欄・検索欄を編集中の ⌘⌫(行頭まで削除)をメニューが奪うと文字が消せなくなるので、欄へ返す。
/// 一覧(リスト・アイコン)に焦点が無いときのキー操作は何もしない ―― 左のツリーを触っていても右の選択がゴミ箱へ
/// 行く、を作らない(キーで一覧が直接受けていた頃と同じ範囲)。メニューをクリックしたときは焦点に関係なく選択へ効く。
@MainActor
enum HomeMenuKeyRouting {
    /// 一覧の選択へ効かせてよいか。`textAction` はテキストの欄を編集中なら欄へ流す標準の動作。
    static func shouldPerformOnSelection(forwardingTextAction textAction: Selector?) -> Bool {
        guard NSApp.currentEvent?.type == .keyDown else { return true }
        let responder = NSApp.keyWindow?.firstResponder
        if responder is FileBrowserTableView || responder is FileBrowserCollectionView { return true }
        if let textAction, QooViewerApp.isEditingText {
            NSApp.sendAction(textAction, to: nil, from: nil)
        }
        return false
    }

    /// 「移動」メニューの ⌘↑・⇧⌘↑ のように、**どの一覧に焦点があっても効かせる**項目。テキストの欄を編集中のキーだけは欄へ返す
    /// (欄の中では「先頭へ」の意味。2026-09-19 の総点検 ―― 以前は名前の編集中・検索欄でも親フォルダへ移り、名前の編集は打ちかけの名前で
    /// 確定した)。メニューをクリックしたときは欄に関係なく効く。
    static func shouldPerformNavigation(forwardingTextAction textAction: Selector) -> Bool {
        guard NSApp.currentEvent?.type == .keyDown, QooViewerApp.isEditingText else { return true }
        NSApp.sendAction(textAction, to: nil, from: nil)
        return false
    }
}

// MARK: - 「ホーム」メニュー

/// **Toggle の `set` は渡される値を使わない**(2026-09-15 の実機): 押された値ではなく、押された項目が指す状態を
/// いまの値に対して作る。メニューの値(`get`)は MenuBarMenuGate の保留で古いことがあり、AX で続けて押したとき
/// 「編集モード」が 1 回目に効かず 2 回目に入った。「スライドショー」などの既存の Toggle と同じ書き方。
struct HomeMenuItems: View {
    /// 環境設定「ライブラリを有効にする」。false なら、ライブラリとコレクションの項目(本棚 ⇄ ファイルブラウザの切り替えを含む)を出さない。
    let isLibraryFeatureEnabled: Bool
    /// 環境設定「ファイルブラウザを有効にする」。false なら、本棚 ⇄ ファイルブラウザの切り替え・ファイルブラウザで選んだ本からの
    /// コレクションの作成/登録・「自動リネームの設定…」を出さない。両方 false のときはメニューごと出さない(QooViewerApp)。
    let isFileBrowserFeatureEnabled: Bool
    let home: HomeMenuState
    let selection: FileBrowserMenuSelection?
    let directory: HomeMenuDirectory
    let appState: AppState?
    let collectionStore: CollectionStore
    /// 既定のライブラリの名前を組み立てる表示言語(BookLibrary.displayName)。
    let locale: Locale
    /// 「自動リネームの設定…」(2026-09-15)。ウインドウを開く口は App が持つ(値の OpenWindowAction)。
    let openAutoRenameSettings: @MainActor () -> Void

    var body: some View {
        if isLibraryFeatureEnabled {
            libraryItems
        }
        if isLibraryFeatureEnabled, isFileBrowserFeatureEnabled {
            Divider()
        }
        if isFileBrowserFeatureEnabled {
            // ほかの項目と同じく、本を読んでいるウインドウでは淡色(型コメント「項目の数を状態で変えない」)。規則は保存を伴うので、
            // シークレットウインドウでも淡色(右クリックの「自動リネーム」と同じ。決定事項 Q8)。
            Button("Auto Rename Settings…") { openAutoRenameSettings() }
                .disabled(!home.isShown || !home.allowsEditing)
        }
    }

    @ViewBuilder
    private var libraryItems: some View {
        // 切り替える相手(ファイルブラウザ)が無ければ出さない。
        if isFileBrowserFeatureEnabled {
            Toggle("File Browser", isOn: Binding(
                get: { [home] in home.isShown && home.mode == .browser },
                set: { [weak appState] _ in
                    guard let welcome = appState?.welcomeLibrary else { return }
                    welcome.mode = welcome.mode == .browser ? .shelf : .browser
                }
            ))
            .disabled(!home.isShown)
        }

        Menu("Libraries") {
            // 外側の閉包でも`appState`を**明示的に**捕まえる(中の`[weak appState]`と揃えるため)。
            // Swift 6.4(Xcode 27)は「中で弱く捕まえているのに、外側が暗黙に強く捕まえている」形を
            // 警告する(#ImplicitStrongCapture)。捕まえ方は今までと同じ(暗黙の強参照を明示にしただけ)で、
            // メニュー項目に残る閉包が弱いまま、という肝心の点は変わらない。
            ForEach(directory.libraries) { [appState] library in
                Toggle(library.displayName(language: locale), isOn: Binding(
                    get: { [home] in home.isShelfShown && home.libraryID == library.id },
                    set: { [weak appState, home] _ in
                        Self.selectLibrary(library.id, appState: appState, home: home)
                    }
                ))
            }
        }
        .disabled(!home.isShown)

        Divider()

        Button("New Library…") { [weak appState] in Self.request(.createLibrary, appState) }
            .disabled(!home.canCreateLibrary)
        Button("Rename Library…") { [weak appState, home] in
            if let id = home.libraryID { Self.request(.renameLibrary(id), appState) }
        }
        .disabled(!home.canRenameLibrary)
        Button("Delete Library…") { [weak appState, home] in
            if let id = home.libraryID { Self.request(.deleteLibrary(id), appState) }
        }
        .disabled(!home.canDeleteLibrary(in: directory))

        Divider()

        Button("New Collection…") { [weak appState] in
            // 「＋」と同じ。名前だけ先に決め、本はこの後の「本を追加」パネルで入れる(CollectionGridView.beginCreatingCollection)。
            appState?.welcomeLibrary?.pendingCreations.append(
                .init(defaultName: "", books: [], fromShelf: false, fromDrop: false)
            )
        }
        .disabled(!home.canCreateCollection)
        Button("Add Books…") { [weak appState, home, collectionStore] in
            guard let id = home.singleCollectionTarget, let libraryID = home.libraryID,
                  let collection = collectionStore.collection(withID: id)
            else { return }
            appState?.welcomeLibrary?.addingBooks = .init(
                collectionID: collection.id, name: collection.name, libraryID: libraryID
            )
        }
        .disabled(!home.canAddBooks)
        Button("Rename Collection…") { [weak appState, home] in
            if let id = home.singleCollectionTarget { Self.request(.renameCollection(id), appState) }
        }
        .disabled(!home.canRenameCollection)
        Button("Delete Collection…") { [weak appState, home] in
            Self.request(.deleteCollections(home.collectionTargets), appState)
        }
        .disabled(!home.canDeleteCollections)
        Menu("Move to Library") {
            ForEach(directory.libraries.filter { $0.id != home.libraryID }) { [appState] library in
                let canMove = home.canMoveCollections(to: library.id, in: directory)
                let name = library.displayName(language: locale)
                Button { [weak appState, home, collectionStore] in
                    Self.moveCollections(to: library.id, appState: appState, home: home, collectionStore: collectionStore)
                } label: {
                    // 移す先に同じ名前があるときは選べない理由を名前に添える(右クリックと同じ。CollectionGridView.moveMenu)。
                    if canMove { Text(verbatim: name) } else { Text("\(name) (name already used)") }
                }
                .disabled(!canMove)
            }
        }
        .disabled(!home.canDeleteCollections || directory.libraries.count < 2)
        Button("Remove from Collection") { [weak appState, home] in
            Self.request(.removeItems(home.itemTargets), appState)
        }
        .disabled(!home.canRemoveItems)

        if isFileBrowserFeatureEnabled {
            Divider()
            fileBrowserSelectionItems
        }

        Divider()

        Toggle("Edit Mode", isOn: Binding(
            get: { [home] in home.isShelfShown && home.isEditing },
            set: { [weak appState] _ in appState?.welcomeLibrary?.isEditing.toggle() }
        ))
        .disabled(!home.canToggleEditing)
        Button("Library Settings…") { [weak appState] in Self.request(.showSettings, appState) }
            .disabled(!home.canShowLibrarySettings)
        Button("Collection Settings…") { [weak appState] in Self.request(.showSettings, appState) }
            .disabled(!home.canShowCollectionSettings)
    }

    /// ファイルブラウザで選んだ項目から(右クリックの「コレクションを作成」「コレクションに登録」と同じ)。
    @ViewBuilder
    private var fileBrowserSelectionItems: some View {
        // ライブラリが複数あるときは、作る先のライブラリを選ぶサブメニュー(右クリックと同じ。2026-09-21)。
        if directory.libraries.count > 1 {
            Menu("Create Collection") {
                ForEach(directory.libraries) { [appState] library in
                    Button { [weak appState] in
                        guard let actions = appState?.fileBrowserActions, let entries = actions.state?.selectedEntries else { return }
                        actions.createCollection(from: entries, libraryID: library.id)
                    } label: {
                        Text(verbatim: library.displayName(language: locale))
                    }
                }
            }
            .disabled(selection?.canUseAsBooks != true)
        } else {
            Button("Create Collection") { [weak appState] in
                guard let actions = appState?.fileBrowserActions, let entries = actions.state?.selectedEntries else { return }
                actions.createCollection(from: entries)
            }
            .disabled(selection?.canUseAsBooks != true)
        }
        Menu("Add to Collection") {
            if let actions = appState?.fileBrowserActions, let selection, selection.canUseAsBooks {
                FileBrowserMenuNodeItems(nodes: FileBrowserMenuCommand.addToCollection.dynamicChildren(
                    in: FileBrowserMenuContext(
                        kind: .file, entries: actions.state?.selectedEntries ?? [], folder: actions.state?.currentFolder
                    ),
                    actions: actions, locale: locale
                ) ?? [])
                // 選択とコレクションの名前が変わったら中身を組み直させる(FileBrowserMenuSelection.selectionRevision のコメント)。
                .id(HomeMenuSubmenuIdentity(selectionRevision: selection.selectionRevision, directory: directory))
            }
        }
        .disabled(selection?.canUseAsBooks != true)
    }

    private static func request(_ kind: WelcomeLibraryState.HomeMenuRequest.Kind, _ appState: AppState?) {
        appState?.welcomeLibrary?.request(kind)
    }

    /// 帯のライブラリのチップを押したときと同じ(WelcomeTopBar.chip)。
    private static func selectLibrary(_ id: UUID, appState: AppState?, home: HomeMenuState) {
        guard let welcome = appState?.welcomeLibrary else { return }
        if welcome.mode == .browser {
            welcome.mode = .shelf
            // 見ていたライブラリなら、開いていたコレクションもそのまま(離れたときの棚へ戻る)。
            if id == home.libraryID { return }
        }
        if id == home.libraryID {
            welcome.openedCollectionID = nil
            return
        }
        welcome.selectedLibraryID = id
        welcome.openedCollectionID = nil
    }

    /// 右クリックの「別のライブラリへ移動」と同じ(CollectionGridView.moveMenu)。1 つでも名前が衝突したら何もしない
    /// (CollectionStore.move が確かめ直す)。
    private static func moveCollections(
        to libraryID: UUID, appState: AppState?, home: HomeMenuState, collectionStore: CollectionStore
    ) {
        guard let welcome = appState?.welcomeLibrary, let target = collectionStore.library(withID: libraryID) else { return }
        let collections = home.collectionTargets.compactMap { collectionStore.collection(withID: $0) }
        guard collectionStore.move(collections, to: target) else { return }
        // 開いていたコレクションを移したら一覧へ戻る(いま見ているライブラリにはもう無い)。
        if let opened = welcome.openedCollectionID, home.collectionTargets.contains(opened) {
            welcome.openedCollectionID = nil
        }
        // 移した先は今見えていないので、選択に残さない(見えていないものをゴミ箱が消さないための決まり)。
        welcome.clearSelection()
    }
}

/// 中身が場面で変わるサブメニューを組み直させる鍵。
private struct HomeMenuSubmenuIdentity: Hashable {
    let selectionRevision: Int
    let directory: HomeMenuDirectory

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectionRevision == rhs.selectionRevision && lhs.directory == rhs.directory
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(selectionRevision)
        hasher.combine(directory.libraries.count)
    }
}

// MARK: - ファイルメニュー(ファイルブラウザ)

/// ファイルメニューの「ファイルブラウザで選んだ項目」の群。右クリックと同じ口(FileBrowserActions)を通る。
struct FileBrowserFileMenuItems: View {
    let selection: FileBrowserMenuSelection?
    let appState: AppState?
    let locale: Locale

    private var isShown: Bool { selection != nil }

    var body: some View {
        Button("Open") { [weak appState] in
            guard HomeMenuKeyRouting.shouldPerformOnSelection(
                forwardingTextAction: #selector(NSResponder.moveToEndOfDocument(_:))
            ) else { return }
            // **⌘↓ はダブルクリック / Return と同じ開き方**(2026-09-15 の 4 回目の監査)。メニューのキーが一覧の keyDown より先に受けるように
            // なって、⌘↓ が右クリックの「開く」(画像フォルダではダブルクリックと反対)になっていた。Finder の ⌘↓ も「開く」= ダブルクリック。
            // メニューの項目を選んだときは右クリックの「開く」と同じ。
            let fromKey = NSApp.currentEvent?.type == .keyDown
            Self.perform(appState) { actions, entries in
                if fromKey { actions.open(entries) } else { actions.openFromMenu(entries) }
            }
        }
        .homeMenuShortcut(.downArrow, modifiers: .command, isActive: isShown)
        .disabled(selection?.canOpen != true)

        Menu("Open With") {
            if let actions = appState?.fileBrowserActions, let selection, selection.canOpenWith {
                let entries = actions.state?.selectedEntries ?? []
                FileBrowserMenuNodeItems(nodes: OpenWithApplications.shared.menuNodes(
                    for: actions.openWithApplications(for: entries), locale: locale,
                    open: { [weak actions] application in actions?.open(entries, withApplicationAt: application) },
                    chooseOther: { [weak actions] in actions?.chooseApplicationAndOpen(entries) }
                ))
                .id(selection.selectionRevision)
            }
        }
        .disabled(selection?.canOpenWith != true)

        Button(renameTitle) { [weak appState] in
            Self.perform(appState) { actions, entries in actions.beginRename(entries) }
        }
        .disabled(selection?.canRename != true)

        Button("Move to Trash") { [weak appState] in
            guard HomeMenuKeyRouting.shouldPerformOnSelection(
                forwardingTextAction: #selector(NSResponder.deleteToBeginningOfLine(_:))
            ) else { return }
            Self.perform(appState) { actions, entries in actions.moveToTrash(entries) }
        }
        .homeMenuShortcut(.delete, modifiers: .command, isActive: isShown)
        .disabled(selection?.canMoveToTrash != true)

        Menu("Compress") {
            Button("Compress Here") { [weak appState] in
                Self.perform(appState) { actions, entries in actions.compress(entries, choosingDestination: false) }
            }
            Button("Compress To…") { [weak appState] in
                Self.perform(appState) { actions, entries in actions.compress(entries, choosingDestination: true) }
            }
        }
        .disabled(selection?.canCompress != true)

        Menu("Extract") {
            Button("Extract Here") { [weak appState] in
                Self.perform(appState) { actions, entries in
                    actions.extract(entries, placement: .contents, choosingDestination: false)
                }
            }
            Button(extractToFolderTitle) { [weak appState] in
                Self.perform(appState) { actions, entries in
                    actions.extract(entries, placement: .ownFolder, choosingDestination: false)
                }
            }
            Button("Extract To…") { [weak appState] in
                Self.perform(appState) { actions, entries in
                    actions.extract(entries, placement: .contents, choosingDestination: true)
                }
            }
        }
        .disabled(selection?.canExtract != true)

        Button("Add to Favorite Locations") { [weak appState] in
            Self.perform(appState) { actions, entries in actions.addToFavoriteLocations(entries) }
        }
        .disabled(selection?.canAddToFavoriteLocations != true)
    }

    /// 右クリックと同じ題(複数なら「N 項目の名前を変更…」。FileBrowserMenuCommand.title(in:locale:))。
    private var renameTitle: String {
        let count = selection?.renameCount ?? 0
        return count > 1
            ? String(format: String(localized: "Rename %lld Items…", language: locale), count)
            : String(localized: "Rename", language: locale)
    }

    private var extractToFolderTitle: String {
        if let name = selection?.extractFolderName {
            return String(format: String(localized: "Extract to “%@”", language: locale), name)
        }
        return String(localized: "Extract Each to Its Own Folder", language: locale)
    }

    private static func perform(_ appState: AppState?, _ body: (FileBrowserActions, [FileBrowserEntry]) -> Void) {
        guard let actions = appState?.fileBrowserActions, let entries = actions.state?.selectedEntries,
              !entries.isEmpty
        else { return }
        body(actions, entries)
    }
}

// MARK: - 表示メニュー(ホーム画面)

/// ホーム画面を出している間の表示メニューの中身。本棚とファイルブラウザで**同じ並び**にし、その場で意味の無い項目は淡色。
struct HomeViewMenuItems: View {
    /// 環境設定「ライブラリを有効にする」「ファイルブラウザを有効にする」。ファイルブラウザがOFFなら表示形式と列(ファイルブラウザだけの項目)を
    /// 出さず、両方OFF(本棚を足す前のウェルカム画面)なら何も出さない。
    let isLibraryFeatureEnabled: Bool
    let isFileBrowserFeatureEnabled: Bool
    let home: HomeMenuState
    let appState: AppState?

    private var isBrowser: Bool { home.isShown && home.mode == .browser }

    var body: some View {
        if isLibraryFeatureEnabled || isFileBrowserFeatureEnabled {
            items
        }
    }

    @ViewBuilder
    private var items: some View {
        if isFileBrowserFeatureEnabled {
            // 外側の閉包でも`appState`を明示的に捕まえる理由は HomeMenuItems の「ライブラリ」と同じ
            // (Swift 6.4 の #ImplicitStrongCapture。捕まえ方そのものは変えていない)。
            ForEach(FileBrowserViewMode.allCases, id: \.self) { [appState] mode in
                Toggle(String(localized: mode.menuTitle), isOn: Binding(
                    get: { [home, isBrowser] in isBrowser && home.browserViewMode == mode },
                    set: { [weak appState] _ in appState?.fileBrowser?.viewMode = mode }
                ))
                .disabled(!isBrowser)
            }

            Divider()
        }

        Menu("Sort By") {
            if isBrowser {
                ForEach(FolderBrowserSortKey.allCases) { [appState] key in
                    Toggle(key.titleKey, isOn: Binding(
                        get: { [home] in home.browserSortKey == key },
                        set: { [weak appState] _ in appState?.fileBrowser?.sortKey = key }
                    ))
                }
                Divider()
                ForEach(FolderBrowserSortDirection.allCases) { [appState] direction in
                    Toggle(direction.titleKey, isOn: Binding(
                        get: { [home] in home.browserSortDirection == direction },
                        set: { [weak appState] _ in appState?.fileBrowser?.sortDirection = direction }
                    ))
                }
            } else {
                // 選べる基準は操作列の並べ替えメニューと同じ(CollectionGridView / CollectionDetailView の sortFields)。
                let fields: [FavoritesSortOption.Field] = home.openedCollectionID == nil
                    ? FavoritesSortOption.Field.withoutTitle
                    : [.name, .title, .dateAdded, .dateCreated, .dateModified]
                ForEach(fields) { [appState] field in
                    Toggle(field.titleKey, isOn: Binding(
                        get: { [home] in home.shelfSort.field == field },
                        set: { [weak appState, home] _ in
                            Self.setShelfSort(field: field, ascending: nil, appState: appState, home: home)
                        }
                    ))
                }
                Divider()
                ForEach([true, false], id: \.self) { [appState] ascending in
                    Toggle(ascending ? LocalizedStringKey("Ascending") : LocalizedStringKey("Descending"), isOn: Binding(
                        get: { [home] in home.shelfSort.isAscending == ascending },
                        set: { [weak appState, home] _ in
                            Self.setShelfSort(field: nil, ascending: ascending, appState: appState, home: home)
                        }
                    ))
                }
            }
        }
        .disabled(!home.isShown)

        Divider()

        // 大きさ(操作列のスライダー・ピンチと同じ値)。ファイルブラウザはアイコン表示のときだけ。
        Button("Zoom In") { [weak appState, home] in Self.resize(larger: true, appState: appState, home: home) }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!canResize)
        Button("Zoom Out") { [weak appState, home] in Self.resize(larger: false, appState: appState, home: home) }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!canResize)

        if isFileBrowserFeatureEnabled {
            Divider()

            // リストの列(見出しの右クリックと同じ。名前の列は隠せない)。
            columnsMenu
        }

        // フルスクリーンの項目(AppKit が足す)との区切り。本を読んでいるときの中身と同じ理由(QooViewerApp の表示メニュー)。
        Divider()
    }

    private var columnsMenu: some View {
        Menu("Columns") {
            ForEach(FileBrowserListView.Column.allCases.filter(\.isHideable), id: \.self) { [appState] column in
                Toggle(String(localized: column.title), isOn: Binding(
                    get: { [home] in !home.hiddenListColumns.contains(column.rawValue) },
                    set: { [weak appState] _ in
                        guard let state = appState?.fileBrowser else { return }
                        if state.hiddenListColumns.contains(column.rawValue) {
                            state.hiddenListColumns.remove(column.rawValue)
                        } else {
                            state.hiddenListColumns.insert(column.rawValue)
                        }
                    }
                ))
            }
        }
        .disabled(!(isBrowser && home.browserViewMode == .list))
    }

    private var canResize: Bool {
        home.isShelfShown || (isBrowser && home.browserViewMode == .icons)
    }

    /// 基準か向きの片方だけを差し替える。もう片方は**いまの値**から取る(メニューの値は保留されうるので使わない)。
    private static func setShelfSort(
        field: FavoritesSortOption.Field?, ascending: Bool?, appState: AppState?, home: HomeMenuState
    ) {
        guard let welcome = appState?.welcomeLibrary else { return }
        let current = home.openedCollectionID == nil ? welcome.collectionSort : welcome.itemSort
        let option = FavoritesSortOption(field: field ?? current.field, ascending: ascending ?? current.isAscending)
        if home.openedCollectionID == nil { welcome.collectionSort = option } else { welcome.itemSort = option }
    }

    /// 1 回で約 1.25 倍 / 0.8 倍(ピンチと同じ積み上げ方。WelcomeLibraryState.resizeTiles(byMagnification:))。
    private static func resize(larger: Bool, appState: AppState?, home: HomeMenuState) {
        let magnification: CGFloat = larger ? 0.25 : -0.2
        if home.isShown && home.mode == .browser {
            appState?.fileBrowser?.stepIconSize(larger: larger)
        } else if home.openedCollectionID == nil {
            appState?.welcomeLibrary?.resizeTiles(byMagnification: magnification)
        } else {
            appState?.welcomeLibrary?.resizeCovers(byMagnification: magnification)
        }
    }
}

extension View {
    /// ファイルブラウザが出ている間だけキーを付ける。本を読んでいる間のキー(ビューアのキー割り当て・テキストの欄)を
    /// 淡色の項目に奪わせない。付け外しで項目の数は変わらない。
    @ViewBuilder
    func homeMenuShortcut(_ key: KeyEquivalent, modifiers: EventModifiers, isActive: Bool) -> some View {
        if isActive {
            keyboardShortcut(key, modifiers: modifiers)
        } else {
            self
        }
    }
}

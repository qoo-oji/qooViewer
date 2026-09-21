import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ウェルカム画面のファイルブラウザ(改善要望7 段階3、2026-09-13)。帯の下、本棚の代わりに出る。
///
/// ```
/// [ツリー] | [‹ › ↑]      [検索欄]      [リスト/アイコン][並べ替え][大きさ]
///          | リスト(NSTableView) または アイコン(NSCollectionView)
///          | パスバー(NSPathControl)
/// ```
///
/// 書く操作(コピー・カット・ペースト・名前の変更・ゴミ箱・新規フォルダ・取り消し)は段階4で載った
/// (FileBrowserOperations)。走っている間はパスバーの上に進捗の帯(FileBrowserProgressBar)が出る。
///
/// ■ すりガラス面の決まりごと
/// この画面全体が`PanelSurface.welcome`。操作列のアイコン → `.panelIconButtonLabel()`(輪郭込み)、
/// 表示切替の選択中 → アクセント地 + `.panelOutlinedAccent(in:)`、スライダー → `.panelControlWell()`、
/// 案内の文字 → `.panelOutlinedContent()`、検索欄とパスバーの帯 → 不透明な地なので掛けない、
/// AppKitの一覧 → セル側で同じ輪郭を描く(FileBrowserAppKitParts)。
struct FileBrowserPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @EnvironmentObject private var favoriteLocations: FavoriteLocationStore
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    // 既存機能との接続(段階 8。FileBrowserLibraryActions.swift)。
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var coverExtractor: CollectionCoverExtractor
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var metadataStore: BookMetadataStore
    /// アイコン表示の絵(`revision` と `includesVideo` を値でアイコン表示へ渡す。FileBrowserIconView のコメント)。
    @EnvironmentObject private var thumbnails: FileBrowserThumbnailProvider
    @EnvironmentObject private var autoRenameStore: AutoRenameStore
    @EnvironmentObject private var autoRenameService: AutoRenameService
    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
    @Environment(\.panelContentOutlineWidth) private var outlineWidth

    @ObservedObject var state: FileBrowserState

    /// 3つの一覧が共有する「開く」などの口。**ビューを捕まえない**(FileBrowserActionsの型コメント)。
    @State private var actions = FileBrowserActions()
    /// 左の幅をドラッグしている間の幅(離したときに状態へ書く。毎フレーム保存しない)。
    @State private var liveTreeWidth: CGFloat?
    @State private var dragStartWidth: CGFloat = 0
    /// 検索がボタンから欄へ広がっているか(ユーザー要望 2026-09-13)。
    @State private var isSearchExpanded = false
    /// 右ペインがドロップの受け口として反応しているか(表示中のフォルダへ落とす。段階4b)。
    @State private var isDropTargeted = false
    /// リスト・アイコン表示の全体が受け口になっている(FileBrowserListView.onWholeListDropTargetChange /
    /// FileBrowserIconView.onWholeViewDropTargetChange)。
    @State private var isListDropTargeted = false
    @FocusState private var isSearchFocused: Bool

    private static let coordinateSpace = "fileBrowser.pane"

    var body: some View {
        let treeWidth = liveTreeWidth ?? state.treeWidth
        HStack(spacing: 0) {
            FileBrowserTreeView(
                state: state, favoriteLocations: favoriteLocations, actions: actions,
                outlineWidth: outlineWidth, locale: locale,
                allowsEditingFavorites: !appState.isPrivateWindow,
                expandsToCurrentFolder: preferences.fileBrowserExpandsTreeToCurrentFolder,
                childSort: preferences.fileBrowserTreeFollowsListSort ? state.sort : FileBrowserTreeView.nameSort
            )
            .frame(width: treeWidth)

            // 左右の境目。標準の Divider はすりガラスの上で薄い(WelcomeSeparator参照)。
            WelcomeSeparator(axis: .vertical)
                .overlay { widthDragHandle(currentWidth: treeWidth) }

            VStack(spacing: 0) {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 操作の結果の知らせ(「コレクションに登録」。FileBrowserState.showToast)。一覧の下に浮かべ、
                    // クリックは一覧へ通す。見た目はビューアのトーストと共通(OverlayToast。文字の輪郭もそちらで掛ける)。
                    .overlay(alignment: .bottom) {
                        ZStack {
                            if let message = state.toastMessage {
                                OverlayToast(message: message)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 20)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        .allowsHitTesting(false)
                        .animation(.easeInOut(duration: 0.2), value: state.toastMessage)
                    }
                FileBrowserProgressBar(operations: state.operations)
                Divider()
                FileBrowserPathBar(
                    folder: state.currentFolder,
                    computerTitle: String(localized: "Computer", language: locale),
                    actions: actions,
                    onNavigate: { [weak state] folder in state?.navigate(to: folder) }
                )
                .frame(height: 24)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            // 右ペインの残り全部を受け口で覆う(操作列・トーストなど)。リスト・アイコン表示・パスバーは自分の受け口
            // (AppKit)が先に受ける。覆っておかないと、断ったドロップを
            // ウインドウ全体の「本を開く」受け口が拾う(FileBrowserDragAndDrop.swift の冒頭のコメント)。
            .onDrop(
                of: [.fileURL],
                delegate: FileBrowserDropDelegate(
                    destination: state.currentFolder, actions: actions,
                    onTargetChange: { isDropTargeted = $0 }
                )
            )
            // 受け口の強調はアクセント色の枠(ContentView のウインドウ全体の受け口と同じ描き方)。
            // すりガラス面の上のアクセント色なので輪郭を付ける。
            .overlay {
                if isDropTargeted || isListDropTargeted {
                    let shape = RoundedRectangle(cornerRadius: 6)
                    shape
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .panelOutlinedAccent(in: shape)
                        .allowsHitTesting(false)
                }
            }
        }
        .coordinateSpace(.named(Self.coordinateSpace))
        // トラックパッドの左右フリックとマウスのサイドボタンで戻る・進む(ユーザー要望 2026-09-21)。
        .fileBrowserNavigationGestures(appState: appState, actions: actions)
        .onAppear {
            connectActions()
            state.activate()
        }
        .onDisappear {
            state.deactivate()
            // 値で持っている口を外す(FileBrowserActions.openWindow のコメント)。現れ直したら connectActions が付け直す。
            actions.openWindow = nil
            if appState.fileBrowserActions === actions { appState.fileBrowserActions = nil }
        }
        // メニューバーの「検索」(⌘F。2026-09-15)。ボタンを押したときと同じく、欄に広げてから焦点を入れる。
        .onChange(of: state.searchFocusRequest) { _, _ in
            isSearchExpanded = true
            DispatchQueue.main.async { isSearchFocused = true }
        }
        .sheet(isPresented: $state.isShowingGoToFolder) {
            FileBrowserGoToFolderSheet(state: state)
        }
        // 右クリックの「メタデータの編集…」「本の書き出し」(段階 8)。
        .sheet(item: $state.bookSheet) { sheet in
            bookSheet(sheet)
        }
    }

    @ViewBuilder
    private func bookSheet(_ sheet: FileBrowserBookSheet) -> some View {
        switch sheet.kind {
        case .metadata(let entry):
            BookMetadataSheet(fileBrowserEntry: entry)
        case .export(let export):
            OpenBookExportSheet(
                viewModel: export.viewModel,
                format: export.format,
                book: export.book,
                // 画面の状態が無い(本を開いていない)。DBに無い項目は3つの書き出しウインドウと同じく既定値。
                displayState: nil,
                initialDestination: export.destination,
                asksBeforeExporting: export.asksBeforeExporting,
                // カバーの指定はDBに残るので、シークレットウインドウでは選ばせない(ビューアの右クリックと同じ)。
                allowsCoverSelection: !appState.isPrivateWindow
            ) { [weak state] _ in
                state?.bookSheet = nil
            }
        }
    }

    private func connectActions() {
        actions.state = state
        actions.appState = appState
        actions.launchCoordinator = launchCoordinator
        actions.folderAccess = folderAccess
        actions.favoriteLocations = favoriteLocations
        actions.preferences = preferences
        actions.openWindow = openWindow
        actions.collectionStore = collectionStore
        actions.coverExtractor = coverExtractor
        actions.bookmarkStore = bookmarkStore
        actions.layoutStore = layoutStore
        actions.metadataStore = metadataStore
        actions.autoRenameStore = autoRenameStore
        actions.autoRenameService = autoRenameService
        // メニューバーのファイルブラウザの項目(ファイル・編集・表示・ホーム)が、右クリックと同じ口を使えるように。
        appState.fileBrowserActions = actions
        // ビューアで開いている本は動かさせない(FileBrowserOperations.refusesBecauseOpenInViewer)。
        state.operations.openBookPaths = { [weak launchCoordinator] in
            launchCoordinator?.allOpenAppStates.flatMap { $0.currentBook?.pathsInUse ?? [] } ?? []
        }
        if state.operations.presenter == nil {
            state.operations.presenter = FileBrowserSheetPresenter(appState: appState)
        }
    }

    // MARK: - 操作列

    private var header: some View {
        WelcomePaneHeaderLayout {
            HStack(spacing: 2) {
                SidePanelNavButton(systemName: "chevron.left", isDisabled: !state.canGoBack, help: "Back") {
                    state.goBack()
                }
                SidePanelNavButton(systemName: "chevron.right", isDisabled: !state.canGoForward, help: "Forward") {
                    state.goForward()
                }
                SidePanelNavButton(systemName: "arrow.up", isDisabled: !state.canGoUp, help: "Enclosing Folder") {
                    state.goUp()
                }
            }
            // 行の中央は**いまのフォルダの名前**。検索は右端のボタンから広がる(ユーザー要望 2026-09-13)。
            folderTitle
            HStack(spacing: 6) {
                // アイコンの大きさ。**アイコン表示のときだけ出し、列の左端(リスト表示ボタンの左)に置く**
                // (ユーザー指示 2026-09-13)。列は右端に揃えてあるので、左へ伸びる形にしておけば出し入れしても
                // 表示切替・並べ替えのボタンが動かない(LibraryPaneControlsで編集モードの2ボタンを「＋」の左に
                // 足すのと同じ理由)。リスト表示で淡色のスライダーが残っていると、何を変えるものなのか読めない。
                // 行の中央の検索欄はWelcomePaneHeaderLayoutが行の中央に置くので動かない。
                // ネイティブのスライダーはつまみが白く明るい面で消えるので、輪郭ではなく溝を敷く
                // (LibraryPaneControlsと同じ)。
                if state.viewMode == .icons {
                    Slider(value: $state.iconSize, in: FileBrowserState.iconSizeRange)
                        .frame(width: 110)
                        .panelControlWell()
                        .help("Icon Size")
                }
                FileBrowserViewModeButton(mode: .list, selection: $state.viewMode)
                FileBrowserViewModeButton(mode: .icons, selection: $state.viewMode)
                FileBrowserSortMenu(key: $state.sortKey, direction: $state.sortDirection)
                search
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// いまのフォルダの名前(コンピュータなら「コンピュータ」)。すりガラス面に直に置く文字なので輪郭を掛ける。
    private var folderTitle: some View {
        // 名前の決め方はウインドウのタイトルと共有する(WindowTitle.folderName)。
        Text(WindowTitle.folderName(state.currentFolder, computerTitle: String(localized: "Computer", language: locale)))
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .panelOutlinedContent()
            .frame(maxWidth: .infinity)
            .help(state.currentFolder?.path ?? "")
    }

    /// 検索: ふだんは虫眼鏡のボタン、押すと欄に広がって焦点が入る。**欄が空のまま焦点が外れたら**(Esc・
    /// 他をクリック・フォルダを移って空になった)ボタンへ戻る。文字が入っている間は欄のまま
    /// (絞り込み中だと分かるように。ユーザー決定 2026-09-13)。欄は不透明な地を持つので輪郭は掛けない。
    @ViewBuilder
    private var search: some View {
        if isSearchExpanded || !state.filterText.isEmpty {
            WelcomeSearchField(
                text: $state.filterText, prompt: "Search This Folder", focus: $isSearchFocused,
                onEscape: {
                    state.filterText = ""
                    isSearchFocused = false
                    isSearchExpanded = false
                }
            )
                .frame(width: 200)
                .onChange(of: isSearchFocused) { _, focused in
                    if !focused, state.filterText.isEmpty { isSearchExpanded = false }
                }
                .onChange(of: state.filterText) { _, text in
                    if text.isEmpty, !isSearchFocused { isSearchExpanded = false }
                }
        } else {
            SidePanelNavButton(systemName: "magnifyingglass", isDisabled: false, help: "Search") {
                isSearchExpanded = true
                // 欄が出来てから焦点を入れる(同じ更新の中では TextField がまだ無い)。
                DispatchQueue.main.async { isSearchFocused = true }
            }
        }
    }

    // MARK: - 中身

    @ViewBuilder
    private var content: some View {
        if let error = state.loadError {
            loadErrorMessage(error)
        } else {
            // 空のフォルダでも一覧そのものは置き、案内はその上に重ねる(クリックは一覧へ通す)。
            // 案内だけに差し替えると、⌘V を受ける一覧も空きスペースの右クリックも無くなり、
            // **空のフォルダへペーストできなかった**(段階4の実機検証 2026-09-13)。
            ZStack {
                switch state.viewMode {
                case .list:
                    FileBrowserListView(
                        state: state, actions: actions, outlineWidth: outlineWidth, locale: locale,
                        onWholeListDropTargetChange: { isListDropTargeted = $0 }
                    )
                case .icons:
                    FileBrowserIconView(
                        state: state, actions: actions, thumbnails: thumbnails,
                        thumbnailRevision: thumbnails.revision, includesVideo: thumbnails.includesVideo,
                        outlineWidth: outlineWidth, locale: locale,
                        onWholeViewDropTargetChange: { isListDropTargeted = $0 }
                    )
                }
                if state.entries.isEmpty, !state.isLoading {
                    Group {
                        if !state.filterText.isEmpty {
                            WelcomeNoMatchesMessage(textKey: "No items match your search.")
                        } else {
                            FileBrowserMessage(systemImage: "folder", textKey: "This folder is empty.")
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func loadErrorMessage(_ error: FileBrowserLoadError) -> some View {
        switch error {
        case .needsAccess:
            VStack(spacing: 12) {
                FileBrowserMessage(
                    systemImage: "lock",
                    textKey: "qooViewer doesn't have permission to show the files in this folder."
                )
                .fixedSize()
                Button("Grant Access…") { actions.requestAccessToCurrentFolder() }
                    // アクセント色で塗った不透明なボタンにする。標準のベゼルに溝を敷く形
                    // (`.panelControlWell()`)では、ライト+黒100%の面で文字が地の灰色に溶けて
                    // 読めなかった(実測 2026-09-13)。
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound, .volumeUnavailable:
            FileBrowserMessage(systemImage: "questionmark.folder", textKey: "This folder can't be found.")
        case .other(let message):
            FileBrowserMessage(systemImage: "exclamationmark.triangle", textKey: "\(message)")
        }
    }

    // MARK: - 左の幅

    /// 区切り線の上の、幅を変える掴みどころ。**座標はペインの座標空間で読む** ―― 掴みどころ自身は
    /// 幅に合わせて動くので、自分の座標で読むとドラッグの出力が自分の位置を動かし、震える
    /// (SidePanelView.widthDragHitAreaで実際に起きた自己参照ループ)。
    private func widthDragHandle(currentWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordinateSpace))
                    .onChanged { value in
                        if liveTreeWidth == nil { dragStartWidth = currentWidth }
                        let range = FileBrowserState.treeWidthRange
                        let proposed = dragStartWidth + value.location.x - value.startLocation.x
                        liveTreeWidth = min(range.upperBound, max(range.lowerBound, proposed))
                    }
                    .onEnded { _ in
                        if let liveTreeWidth { state.treeWidth = liveTreeWidth }
                        liveTreeWidth = nil
                    }
            )
    }
}

/// 案内(空のフォルダ・読めないフォルダ)。すりガラス面に直に置く文字なので輪郭を掛ける。
struct FileBrowserMessage: View {
    let systemImage: String
    let textKey: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(textKey)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .panelOutlinedContent()
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 表示切替の1つ(リスト / アイコン)。選択中の見た目は本棚の編集トグル(WelcomeEditToggle)と同じ。
private struct FileBrowserViewModeButton: View {
    let mode: FileBrowserViewMode
    @Binding var selection: FileBrowserViewMode
    /// 選択中の地の色(ウインドウが後ろなら灰色。`SelectionEmphasis`)。
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let isSelected = selection == mode
        let shape = RoundedRectangle(cornerRadius: PanelIconButtonLabel.cornerRadius, style: .continuous)
        Button {
            selection = mode
        } label: {
            Image(systemName: mode == .list ? "list.bullet" : "square.grid.2x2")
                .font(.system(size: 15, weight: .medium))
                // 選ばれていないときは地がほぼ無いので輪郭を掛ける。選択中は不透明な地(アクセント色 / 後ろでは灰色)。
                .panelOutlinedContent(isEnabled: !isSelected)
                .frame(width: PanelIconButtonLabel.width, height: PanelIconButtonLabel.height)
                .background(shape.fill(isSelected ? SelectionEmphasis.fill(isActive: appearsActive) : Color.clear))
                .panelOutlinedAccent(in: shape, isEnabled: isSelected)
                .foregroundStyle(isSelected ? SelectionEmphasis.foreground(isActive: appearsActive) : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode == .list ? "as List" : "as Icons")
    }
}

/// 並べ替えメニュー。サイドパネルの並べ替え(SidePanelSortMenu)と同じ作り・同じ決まり事。
private struct FileBrowserSortMenu: View {
    @Binding var key: FolderBrowserSortKey
    @Binding var direction: FolderBrowserSortDirection

    var body: some View {
        Menu {
            Picker(selection: $key) {
                ForEach(FolderBrowserSortKey.allCases) { key in
                    Text(key.titleKey).tag(key)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)

            Divider()

            Picker(selection: $direction) {
                ForEach(FolderBrowserSortDirection.allCases) { direction in
                    Text(direction.titleKey).tag(direction)
                }
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
        // 以下2つはSidePanelSortMenuで実測済みの決まり事(あちらのコメント参照)。
        .fixedSize()
        .panelOutlinedContent()
        .help("Sort By")
    }
}

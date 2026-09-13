import AppKit
import SwiftUI

/// ウェルカム画面のファイルブラウザ(改善要望7 段階3、2026-09-13)。帯の下、本棚の代わりに出る。
///
/// ```
/// [ツリー] | [‹ › ↑]      [検索欄]      [リスト/アイコン][並べ替え][大きさ]
///          | リスト(NSTableView) または アイコン(LazyVGrid)
///          | パスバー(NSPathControl)
/// ```
///
/// 段階3は**読むだけ**(移動・開く・新規タブ/ウインドウ・Finderで表示)。書く操作(コピー・移動・
/// 名前の変更・ゴミ箱・新規フォルダ)と Undo は段階4で載る。
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
    @Environment(\.panelContentOutlineWidth) private var outlineWidth

    @ObservedObject var state: FileBrowserState

    /// 3つの一覧が共有する「開く」などの口。**ビューを捕まえない**(FileBrowserActionsの型コメント)。
    @State private var actions = FileBrowserActions()
    /// 左の幅をドラッグしている間の幅(離したときに状態へ書く。毎フレーム保存しない)。
    @State private var liveTreeWidth: CGFloat?
    @State private var dragStartWidth: CGFloat = 0

    private static let coordinateSpace = "fileBrowser.pane"

    var body: some View {
        let treeWidth = liveTreeWidth ?? state.treeWidth
        HStack(spacing: 0) {
            FileBrowserTreeView(
                state: state, favoriteLocations: favoriteLocations, actions: actions,
                outlineWidth: outlineWidth, locale: locale,
                allowsEditingFavorites: !appState.isPrivateWindow
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
                Divider()
                FileBrowserPathBar(
                    folder: state.currentFolder,
                    computerTitle: String(localized: "Computer", language: locale),
                    onNavigate: { [weak state] folder in state?.navigate(to: folder) }
                )
                .frame(height: 24)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .coordinateSpace(.named(Self.coordinateSpace))
        .onAppear {
            connectActions()
            state.activate()
        }
        .onDisappear {
            state.deactivate()
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
            WelcomeSearchField(text: $state.filterText, prompt: "Search This Folder")
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 中身

    @ViewBuilder
    private var content: some View {
        if let error = state.loadError {
            loadErrorMessage(error)
        } else if state.entries.isEmpty, !state.isLoading {
            if !state.filterText.isEmpty {
                WelcomeNoMatchesMessage(textKey: "No items match your search.")
            } else {
                FileBrowserMessage(systemImage: "folder", textKey: "This folder is empty.")
            }
        } else {
            switch state.viewMode {
            case .list:
                FileBrowserListView(state: state, actions: actions, outlineWidth: outlineWidth, locale: locale)
            case .icons:
                FileBrowserIconView(state: state, actions: actions)
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

    var body: some View {
        let isSelected = selection == mode
        let shape = RoundedRectangle(cornerRadius: PanelIconButtonLabel.cornerRadius, style: .continuous)
        Button {
            selection = mode
        } label: {
            Image(systemName: mode == .list ? "list.bullet" : "square.grid.2x2")
                .font(.system(size: 15, weight: .medium))
                // 選ばれていないときは地がほぼ無いので輪郭を掛ける。選択中は不透明なアクセント地。
                .panelOutlinedContent(isEnabled: !isSelected)
                .frame(width: PanelIconButtonLabel.width, height: PanelIconButtonLabel.height)
                .background(shape.fill(isSelected ? Color.accentColor : Color.clear))
                .panelOutlinedAccent(in: shape, isEnabled: isSelected)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
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

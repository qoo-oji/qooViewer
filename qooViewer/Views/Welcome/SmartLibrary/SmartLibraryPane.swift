import AppKit
import SwiftUI

/// ホームの「スマートライブラリ」(2026-09-21、利用者の指示。StackNest のスマートシェルフが土台)。
///
/// 2 ペイン: **左に絞り込みのすべて**(StackNest では画面の上にあるフィルタ・ブラウザ列と、サイドバーのスマートシェルフの一覧を
/// ここへ集めた)、右に表紙のグリッド。左ペインは上から 対象フォルダ / スマートコレクション / メタデータ(ブラウザ) / 絞り込み
/// (2026-09-22、利用者の指示)。
///
/// **UI の名前**: 保存した条件(コードでは `SmartShelf`、StackNest のスマートシェルフ)は「スマートコレクション」と呼ぶ
/// (2026-09-22、利用者の決定。画面そのものの「スマートライブラリ」と同じ名前で呼んでいて、どちらの話か読めなかった。
/// ライブラリの中にコレクション、と同じ並び)。対象の本・メタデータの決め方は `SmartLibraryCatalog` の型コメント、
/// 絞り込みの重なり方は `SmartLibraryViewState` の型コメント。
///
/// ■ すりガラス面の決まりごと
/// この画面も `PanelSurface.welcome` の上。文字・アイコンには `.panelOutlinedContent()`、選択中の行(アクセントの地)には
/// `.panelOutlinedAccent(in:)`、スライダーには `.panelControlWell()`(CLAUDE.md の表)。検索欄とメニューのボタンは
/// 本棚と同じ部品を使う。
struct SmartLibraryPane: View {
    @ObservedObject var home: WelcomeLibraryState
    let allowsEditing: Bool

    @EnvironmentObject private var catalog: SmartLibraryCatalog
    @EnvironmentObject private var store: SmartLibraryStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var preferences: AppPreferences
    @StateObject private var state = SmartLibraryViewState()
    @State private var liveSidebarWidth: CGFloat?
    @State private var dragStartWidth: CGFloat = 0

    private static let coordinateSpace = "smartLibraryPane"

    var body: some View {
        let width = liveSidebarWidth ?? state.sidebarWidth
        HStack(spacing: 0) {
            SmartLibrarySidebar(state: state, allowsEditing: allowsEditing)
                .frame(width: width)
            WelcomeSeparator(axis: .vertical)
                .overlay { widthDragHandle(currentWidth: width) }
            SmartLibraryContent(home: home, state: state, allowsEditing: allowsEditing)
        }
        .coordinateSpace(.named(Self.coordinateSpace))
        // シークレットウインドウに出している間は、並べた本を DB へ登録しない(SmartLibraryCatalog.persistingCount)。
        .onAppear {
            catalog.activate(persistsMetadata: !appState.isPrivateWindow)
            // 本を渡す前に著者の設定を当てておく(先に渡すと、設定を当て直す分だけ 2 度並べ直す)。
            state.usesFirstAuthorOnly = preferences.smartLibraryUsesFirstAuthorOnly
            state.update(books: catalog.books, shelves: store.shelves)
        }
        .onDisappear {
            catalog.deactivate(persistsMetadata: !appState.isPrivateWindow)
            home.smartSelectedBookPaths = []
        }
        // 選んでいる本をメニューバーの「Finder で表示」などの相手にする(2026-09-23。HomeMenuState.smartBookPaths)。
        .onChange(of: state.selectedBookPaths, initial: true) { _, paths in
            if home.smartSelectedBookPaths != paths { home.smartSelectedBookPaths = paths }
        }
        .onChange(of: catalog.revision) { state.update(books: catalog.books, shelves: store.shelves) }
        .onChange(of: store.shelves) { state.update(books: catalog.books, shelves: store.shelves) }
        // 環境設定「スマートライブラリ」→「先頭の著者だけを使う」(SmartLibraryViewState.usesFirstAuthorOnly)。
        .onChange(of: preferences.smartLibraryUsesFirstAuthorOnly) { _, value in state.usesFirstAuthorOnly = value }
    }

    /// 区切り線の上の、幅を変える掴みどころ(FileBrowserPane.widthDragHandle と同じ作り。座標はペインの座標空間で読む)。
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
                        if liveSidebarWidth == nil { dragStartWidth = currentWidth }
                        let range = SmartLibraryViewState.sidebarWidthRange
                        let proposed = dragStartWidth + value.location.x - value.startLocation.x
                        liveSidebarWidth = min(range.upperBound, max(range.lowerBound, proposed))
                    }
                    .onEnded { _ in
                        if let liveSidebarWidth { state.sidebarWidth = liveSidebarWidth }
                        liveSidebarWidth = nil
                    }
            )
    }
}

// MARK: - 左ペイン

/// 左ペイン: 対象フォルダ / スマートコレクション / メタデータ(ブラウザ) / 絞り込み(2026-09-22、利用者の指示)。
struct SmartLibrarySidebar: View {
    @ObservedObject var state: SmartLibraryViewState
    let allowsEditing: Bool

    @EnvironmentObject private var store: SmartLibraryStore
    @EnvironmentObject private var catalog: SmartLibraryCatalog
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    /// 対象フォルダの行の右クリックの「ファイルブラウザで表示」(2026-09-23)。
    @Environment(\.revealInFileBrowser) private var revealInFileBrowser
    /// 対象フォルダの欄へフォルダをドラッグしている最中(受け口の強調)。
    @State private var isFolderDropTargeted = false

    /// 編集中のスマートシェルフ(新しく作るときは id の無いもの)。
    @State private var editing: SmartShelfEditorTarget?
    @State private var deleting: SmartShelf?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                foldersSection
                shelvesSection
                browseSection
                filterSection
            }
            .padding(12)
        }
        .scrollIndicators(.automatic)
        .sheet(item: $editing) { target in
            SmartShelfEditorSheet(target: target) { saved in
                if store.shelf(withID: saved.id) != nil {
                    store.update(saved)
                } else {
                    store.add(saved)
                }
                state.selectedShelfID = saved.id
            }
        }
        .alert(
            "Delete Smart Collection?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting { store.removeShelf(id: deleting.id) }
                deleting = nil
            }
        } message: {
            Text("Only the conditions are deleted. The books themselves and their saved data are not affected.")
        }
    }

    // MARK: スマートシェルフ

    private var shelvesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SmartSidebarHeader(titleKey: "Smart Collections") {
                Button {
                    editing = SmartShelfEditorTarget(shelf: SmartShelf(
                        name: "", conditions: SmartShelfConditions(rules: [SmartShelfRule(field: .genre)])), isNew: true)
                } label: {
                    Image(systemName: "plus").panelIconButtonLabel()
                }
                .buttonStyle(.borderless)
                .disabled(!allowsEditing)
                .help("New Smart Collection…")
            }
            SmartSidebarRow(
                systemImage: "books.vertical", title: String(localized: "All Books", language: locale),
                count: state.shelfCounts[nil], isSelected: state.selectedShelfID == nil
            ) {
                state.selectedShelfID = nil
            }
            ForEach(store.shelves) { shelf in
                SmartSidebarRow(
                    systemImage: "line.3.horizontal.decrease.circle", title: shelf.name,
                    count: state.shelfCounts[shelf.id], isSelected: state.selectedShelfID == shelf.id
                ) {
                    state.selectedShelfID = shelf.id
                }
                .contextMenu {
                    Button("Edit Conditions…") { editing = SmartShelfEditorTarget(shelf: shelf, isNew: false) }
                        .disabled(!allowsEditing)
                    Button("Duplicate") {
                        store.duplicate(id: shelf.id, copySuffix: String(localized: " copy", language: locale))
                    }
                    .disabled(!allowsEditing)
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = shelf }
                        .disabled(!allowsEditing)
                }
            }
        }
    }

    // MARK: 対象フォルダ

    /// 並ぶ本はここに登録したフォルダの中の本だけ(SmartLibraryCatalog の型コメント)。
    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SmartSidebarHeader(titleKey: "Target Folders") {
                Button {
                    catalog.reload()
                } label: {
                    Image(systemName: "arrow.clockwise").panelIconButtonLabel()
                }
                .buttonStyle(.borderless)
                .help("Look for Books Again")
            }
            ForEach(store.folders) { folder in
                HStack(spacing: 6) {
                    Image(systemName: folderAccess.isPathCovered(folder.url) ? "folder" : "folder.badge.questionmark")
                        .foregroundStyle(.secondary)
                    Text(verbatim: folder.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.path)
                    Spacer(minLength: 0)
                    Button {
                        store.removeFolder(id: folder.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!allowsEditing)
                    .help("Remove This Folder")
                }
                .font(.callout)
                .panelOutlinedContent()
                .contentShape(Rectangle())
                // 右クリックで Finder / ファイルブラウザでフォルダを見に行く(2026-09-23、利用者の指示。外すのは右の −)。
                .contextMenu {
                    Button("Show in Finder") { showFolderInFinder(folder.url) }
                    if revealInFileBrowser.isFeatureEnabled {
                        Button("Show in File Browser") { revealInFileBrowser(folder.url, isDirectory: true) }
                    }
                }
            }
            Button {
                addFolder()
            } label: {
                Label("Add Folder…", systemImage: "plus")
            }
            .buttonStyle(.link)
            .disabled(!allowsEditing)
            .panelOutlinedContent()
            if catalog.isTruncated {
                Text("Some folders have too many items, so not every book in them is shown.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .panelOutlinedContent()
            }
        }
        // ファイルブラウザ・Finder からフォルダを落として足す(2026-09-23)。シークレットウインドウでは受けない(ウインドウ全体の
        // 「本を開く」へ回る)。このウインドウのホームから運び出している本は受けない(HomeBookDragTracker)。
        .overlay {
            if isFolderDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
        .modifier(SmartFolderDropTarget(
            isEnabled: allowsEditing, isTargeted: $isFolderDropTargeted,
            refusesDrop: { [weak appState] in appState.map { HomeBookDragTracker.isDragging(from: $0) } ?? false },
            receive: { urls in addDroppedFolders(urls) }
        ))
    }

    /// 対象フォルダを Finder で開く。在るかの確かめは FileIO の上で(ネットワークのボリュームで main を止めない)。
    private func showFolderInFinder(_ url: URL) {
        let path = url.path
        Task { @MainActor in
            if await FileIO.perform({ FileManager.default.fileExists(atPath: path) }) {
                FinderReveal.reveal(url)
            } else {
                NSSound.beep()
            }
        }
    }

    /// 対象フォルダの欄へ落とされたフォルダを足す(2026-09-23、利用者の指示。ファイルブラウザの右クリックの「スマートライブラリの
    /// 対象に追加」と同じ規則: 1 冊の本になるフォルダ・ファイルは足さない)。1 つも足せなければ鳴らす(足せたものは一覧に並ぶ)。
    private func addDroppedFolders(_ urls: [URL]) {
        guard allowsEditing, !urls.isEmpty else { return }
        // AppState は弱く持つ(応答しない共有から落とされたフォルダの確かめが終わらなくても、閉じたウインドウを生かし続けない。
        // 2026-09-23 の 3 回目の監査の低)。
        Task { @MainActor [weak appState, store, folderAccess] in
            let folders = await FileIO.perform {
                urls.filter { url in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                }
            }
            let result = await SmartLibraryTargetAdding.add(
                folders, store: store, folderAccess: folderAccess,
                isFeatureEnabled: { [weak appState] in
                    (appState?.preferences?.smartLibraryFeatureEnabled ?? false) && !(appState?.isPrivateWindow ?? true)
                }
            )
            if result?.added.isEmpty ?? true { NSSound.beep() }
        }
    }

    /// 対象フォルダを足す。読む権限は FolderAccessStore に一本化(よく使う項目と同じ。SmartLibraryStore の型コメント)。
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", language: locale)
        panel.message = String(localized: "Choose folders whose books appear in the smart library.", language: locale)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            folderAccess.add(url: url)
            store.addFolder(url)
        }
    }

    // MARK: ブラウザ

    /// 欄ごとのボタン(左ペインの幅いっぱい)。押すと選択パネルが出て、選んだ値(複数)はボタンの下に並ぶ
    /// (2026-09-22、利用者の指示。StackNest の上ペインのブラウザ列の代わり)。
    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 見出しは「メタデータ」(「ブラウザ」では何を選ぶ所か読めなかった。2026-09-22、利用者の指示)。
            SmartSidebarHeader(titleKey: "Metadata") {
                let addable = SmartFacetField.allCases.filter { !state.facetFields.contains($0) }
                Menu {
                    ForEach(addable, id: \.self) { field in
                        Button(LocalizedStringKey(field.titleKey)) { state.addFacetField(field) }
                    }
                } label: {
                    Image(systemName: "plus").panelIconButtonLabel()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .panelOutlinedContent()
                .disabled(addable.isEmpty)
                .help("Add Browser Button")
            }
            ForEach(state.facetFields, id: \.self) { field in
                SmartFacetButton(state: state, field: field, allowsPinning: allowsEditing)
            }
        }
    }

    // MARK: 絞り込み

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SmartSidebarHeader(titleKey: "Filter") {
                if state.isNarrowing {
                    Button("Clear All") { state.clearNarrowing() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .panelOutlinedContent()
                }
            }
            SmartKindPicker(selection: $state.quickFilter.kinds)
            SmartFilterPicker(titleKey: "Reading Status", selection: $state.quickFilter.readState,
                              options: SmartReadState.allCases.map { ($0, $0.titleKey) })
            SmartFilterPicker(titleKey: "Added", selection: $state.quickFilter.addedWithinDays,
                              options: Self.dayOptions)
            SmartFilterPicker(titleKey: "Last Read", selection: $state.quickFilter.readWithinDays,
                              options: Self.dayOptions)
        }
    }

    private static let dayOptions: [(Int, String)] = [
        (1, "Today"), (7, "In the last 7 days"), (30, "In the last 30 days"), (90, "In the last 90 days"),
        (365, "In the last year"),
    ]
}

/// 節の見出し(小さな灰色の文字と、右端の操作)。
private struct SmartSidebarHeader<Trailing: View>: View {
    let titleKey: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 4) {
            Text(titleKey)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .panelOutlinedContent()
            Spacer(minLength: 0)
            trailing
        }
        .frame(minHeight: 22)
    }
}

/// スマートシェルフの行(選んでいる行はアクセントの地。本棚のチップと同じ強調)。
private struct SmartSidebarRow: View {
    let systemImage: String
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: 16)
            Text(verbatim: title.isEmpty ? " " : title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let count {
                Text(verbatim: "\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? AnyShapeStyle(SelectionEmphasis.foreground(isActive: appearsActive)) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .panelOutlinedContent(isEnabled: !isSelected)
        .foregroundStyle(isSelected ? SelectionEmphasis.foreground(isActive: appearsActive) : Color.primary)
        .background(shape.fill(isSelected ? SelectionEmphasis.fill(isActive: appearsActive) : Color.clear))
        .panelOutlinedAccent(in: shape, isEnabled: isSelected)
        .contentShape(shape)
        .onTapGesture(perform: action)
    }
}

/// 値の見出し(「(空)」と、形式の欄の値は訳す)。
private func smartFacetLabel(_ value: SmartFacetValue, field: SmartFacetField, locale: Locale) -> String {
    switch value {
    case .empty: return String(localized: "(empty)", language: locale)
    case .value(let v):
        if field == .kind, let kind = SmartBookKind(rawValue: v) {
            return String(localized: String.LocalizationValue(kind.titleKey), language: locale)
        }
        return v
    }
}

/// ブラウザの欄のボタン 1 つ(左ペインの幅いっぱい)と、その下の選んだ値。
///
/// ボタンの地は薄い(`Color.primary.opacity(0.07)`)ので、文字には輪郭を掛ける(CLAUDE.md の表)。選んだ値のチップも同じ。
/// 右クリックで欄を替える・ボタンを外す。
private struct SmartFacetButton: View {
    @ObservedObject var state: SmartLibraryViewState
    let field: SmartFacetField
    /// ピン留めを変えられるか(`SmartFacetPanel.allowsPinning`)。
    let allowsPinning: Bool
    @Environment(\.locale) private var locale
    @State private var isShowingPanel = false

    var body: some View {
        let selected = state.facetSelection[field].sorted(by: SmartFacetValue.precedes)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isShowingPanel.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(field.titleKey))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !selected.isEmpty {
                        Text(verbatim: "\(selected.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .panelOutlinedContent()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(shape.fill(Color.primary.opacity(0.07)))
                .panelOutlinedFrame(in: shape)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingPanel, arrowEdge: .trailing) {
                SmartFacetPanel(state: state, field: field, allowsPinning: allowsPinning)
            }
            .contextMenu {
                Menu("Change Field") {
                    ForEach(SmartFacetField.allCases, id: \.self) { candidate in
                        Button(LocalizedStringKey(candidate.titleKey)) {
                            state.replaceFacetField(field, with: candidate)
                        }
                        .disabled(candidate == field)
                    }
                }
                Button("Clear Selection") { state.clearFacet(field) }
                    .disabled(selected.isEmpty)
                Divider()
                Button("Remove Button") { state.removeFacetField(field) }
            }
            if !selected.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(selected, id: \.self) { value in
                        SmartSelectedValueChip(title: smartFacetLabel(value, field: field, locale: locale)) {
                            state.toggleFacet(value, in: field)
                        }
                    }
                }
            }
        }
    }
}

/// 選んだ値のチップ(× で外す)。地は薄いので輪郭を掛ける。
private struct SmartSelectedValueChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        HStack(spacing: 3) {
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .font(.caption)
        .panelOutlinedContent()
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(shape.fill(Color.accentColor.opacity(0.18)))
        .panelOutlinedFrame(in: shape)
        .help(title)
    }
}

/// ボタンを押すと出る選択パネル(ポップオーバー。中身は macOS が不透明に描くので輪郭は要らない)。
///
/// 上に検索欄、その下に**ピン留めした値**(よく使う値。アプリで共有して保存、`SmartLibraryStore.pins`)、続けてすべての値
/// (ピン留めした値もこちらに残す ―― 2026-09-22、利用者の指示)。行を押すと選ぶ / 外す(複数選べる)。
/// ピンは行の右端に**いつも出し**、ピン留めしているかは色で見せる(ポインタを乗せたときだけ出していたら、ピン留めが
/// できること自体に気づけなかった。2026-09-22、利用者の指摘)。
private struct SmartFacetPanel: View {
    @ObservedObject var state: SmartLibraryViewState
    let field: SmartFacetField
    /// ピン留めを変えられるか。**シークレットウインドウでは淡色**(ピンは `SmartLibraryStore` に保存され、保存データの書き出しにも入る。
    /// 2026-09-23 の監査まではシークレットウインドウでも書けた)。ピン留めした値を上に出すこと(読むだけ)は変わらない。
    let allowsPinning: Bool
    @EnvironmentObject private var store: SmartLibraryStore
    @Environment(\.locale) private var locale
    @State private var query = ""

    private struct Row: Identifiable {
        let value: SmartFacetValue
        let title: String
        let count: Int
        let isPinned: Bool
        /// 行の識別子。**ピン留めの節とすべての節で別にする** ―― ピン留めした値は両方の節に出るので、値だけを識別子にすると
        /// 同じ LazyVStack の中で重なり、すべての節の行が空白で描かれた(2026-09-22 の実機検証)。
        let section: String
        var id: String { "\(section)|\(value)" }
    }

    var body: some View {
        let selected = state.facetSelection[field]
        let (pinned, others) = rows(selected: selected)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("", text: $query, prompt: Text("Search"))
                    .textFieldStyle(.roundedBorder)
                Button("Clear Selection") { state.clearFacet(field) }
                    .disabled(selected.isEmpty)
            }
            .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !pinned.isEmpty {
                        Section {
                            ForEach(pinned) { row in rowView(row, isSelected: selected.contains(row.value), isPinned: true) }
                        } header: {
                            sectionHeader("Pinned")
                        }
                    }
                    Section {
                        ForEach(others) { row in
                            rowView(row, isSelected: selected.contains(row.value), isPinned: row.isPinned)
                        }
                    } header: {
                        if !pinned.isEmpty { sectionHeader("All") }
                    }
                    if pinned.isEmpty, others.isEmpty {
                        Text("No Matches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 300, height: 380)
    }

    /// ピン留めした値(冊数が 0 でも出す ―― 覚えておいた場所が消えないように)と、すべての値(ピン留めした値も含む)。
    /// どちらも検索で絞る。
    private func rows(selected: Set<SmartFacetValue>) -> (pinned: [Row], others: [Row]) {
        let counts = state.facetValues[field] ?? []
        var countByValue: [SmartFacetValue: Int] = [:]
        for entry in counts { countByValue[entry.value] = entry.count }
        let pinnedValues = Set(store.pins[field] ?? [])
        // 候補に無くなっても、選んでいる値とピン留めした値は出す(外せるように)。
        var all = counts.map(\.value)
        for value in pinnedValues.union(selected) where countByValue[value] == nil { all.append(value) }
        all.sort(by: SmartFacetValue.precedes)
        let needle = LibrarySearchQuery.normalized(query.trimmingCharacters(in: .whitespaces))
        var pinned: [Row] = []
        var others: [Row] = []
        for value in all {
            let title = smartFacetLabel(value, field: field, locale: locale)
            if !needle.isEmpty, !LibrarySearchQuery.normalized(title).contains(needle) { continue }
            let isPinned = pinnedValues.contains(value)
            let count = countByValue[value] ?? 0
            if isPinned { pinned.append(Row(value: value, title: title, count: count, isPinned: true, section: "pinned")) }
            // ピン留めした値でも、冊数が 0 のもの(候補に無いもの)は上にだけ出す。
            if !isPinned || countByValue[value] != nil || selected.contains(value) {
                others.append(Row(value: value, title: title, count: count, isPinned: isPinned, section: "all"))
            }
        }
        return (pinned, others)
    }

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(.bar)
    }

    private func rowView(_ row: Row, isSelected: Bool, isPinned: Bool) -> some View {
        SmartFacetPanelRow(
            title: row.title, count: row.count, isSelected: isSelected, isPinned: isPinned,
            allowsPinning: allowsPinning,
            onToggle: { state.toggleFacet(row.value, in: field) },
            onPin: { [allowsPinning] in
                guard allowsPinning else { return }
                store.togglePin(row.value, in: field)
            }
        )
    }
}

private struct SmartFacetPanelRow: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let isPinned: Bool
    let allowsPinning: Bool
    let onToggle: () -> Void
    let onPin: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(verbatim: "\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button(action: onPin) {
                Image(systemName: "pin.fill")
                    .foregroundStyle(isPinned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            }
            .buttonStyle(.borderless)
            .disabled(!allowsPinning)
            // 淡色のボタンは押しても何もしないが、押したところが行の onTapGesture に落ちて**値を選んでしまった**(実機 2026-09-23、
            // シークレットウインドウ)。淡色の間はピンの上の押下を受け止めて捨てる。
            .overlay {
                if !allowsPinning {
                    Color.clear.contentShape(Rectangle()).onTapGesture {}
                }
            }
            .help(isPinned ? "Unpin" : "Pin")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .opacity(count == 0 && !isSelected ? 0.5 : 1)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
        .help(title)
    }
}

/// 絞り込みのドロップダウンのボタンの、文字の幅(5 つとも同じ幅に揃える ―― 2026-09-22、利用者の指摘)。
private let smartFilterLabelWidth: CGFloat = 112

/// 絞り込みの 1 行: 見出しと、ドロップダウンのボタン(押すとポップオーバーで選択肢が出る)。
///
/// **Menu ではなく Button + ポップオーバー**。Menu は(1)項目を 1 つ押すたびに閉じるので、形式を続けて何個も選べない
/// (利用者の指摘)、(2)ラベルに付けた幅を OS の版によって無視する(SettingsPicker.widthProbe のコメント)ので幅が揃わない。
/// Button はラベルの幅でベゼルが決まるので、ラベルを同じ幅にすれば 5 つとも揃う(WelcomeTopBar.openButtons と同じ)。
/// ポップオーバーは外をクリックすると閉じる。
private struct SmartFilterDropdown<Content: View>: View {
    let titleKey: LocalizedStringKey
    let currentTitle: String
    @Binding var isOpen: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) {
            Text(titleKey)
                .font(.callout)
                .lineLimit(1)
                .panelOutlinedContent()
            Spacer(minLength: 4)
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: currentTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .frame(width: smartFilterLabelWidth)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(currentTitle)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) { content }
                    .padding(12)
                    .fixedSize()
            }
        }
    }
}

/// 形式の絞り込み(複数選べる ―― 2026-09-22、利用者の指示)。何も選ばなければ全部。開いたまま何個でも付け外しでき、
/// 外をクリックするか「指定なし」を押すと閉じる(「指定なし」は全部外す)。
private struct SmartKindPicker: View {
    @Binding var selection: Set<SmartBookKind>
    @Environment(\.locale) private var locale
    @State private var isOpen = false

    var body: some View {
        SmartFilterDropdown(titleKey: "Book Format", currentTitle: currentTitle, isOpen: $isOpen) {
            Button("Any") {
                selection = []
                isOpen = false
            }
            .buttonStyle(.link)
            Divider()
            ForEach(SmartBookKind.allCases, id: \.self) { kind in
                Toggle(LocalizedStringKey(kind.titleKey), isOn: Binding(
                    get: { selection.contains(kind) },
                    set: { isOn in
                        if isOn { selection.insert(kind) } else { selection.remove(kind) }
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
    }

    private var currentTitle: String {
        let chosen = SmartBookKind.allCases.filter(selection.contains)
        guard !chosen.isEmpty else { return String(localized: "Any", language: locale) }
        return chosen.map { String(localized: String.LocalizationValue($0.titleKey), language: locale) }
            .joined(separator: ", ")
    }
}

/// 1 つだけ選ぶ絞り込み(読書の状態・追加日・最後に読んだ日・登録の有無)。選ぶと閉じる。
private struct SmartFilterPicker<Value: Hashable>: View {
    let titleKey: LocalizedStringKey
    @Binding var selection: Value?
    let options: [(Value, String)]
    @Environment(\.locale) private var locale
    @State private var isOpen = false

    var body: some View {
        SmartFilterDropdown(titleKey: titleKey, currentTitle: currentTitle, isOpen: $isOpen) {
            choice(title: String(localized: "Any", language: locale), isSelected: selection == nil) { selection = nil }
            Divider()
            ForEach(options, id: \.0) { option in
                choice(title: String(localized: String.LocalizationValue(option.1), language: locale),
                       isSelected: selection == option.0) { selection = option.0 }
            }
        }
    }

    /// 選択肢 1 行(選んでいるものに印)。
    private func choice(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            isOpen = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                Text(verbatim: title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var currentTitle: String {
        guard let selection, let option = options.first(where: { $0.0 == selection }) else {
            return String(localized: "Any", language: locale)
        }
        return String(localized: String.LocalizationValue(option.1), language: locale)
    }
}

// MARK: - 右ペイン

/// 右: 見出し(棚の名前・検索・並べ替え・大きさ)と表紙のグリッド。
struct SmartLibraryContent: View {
    @ObservedObject var home: WelcomeLibraryState
    @ObservedObject var state: SmartLibraryViewState
    let allowsEditing: Bool

    @EnvironmentObject private var catalog: SmartLibraryCatalog
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    /// 右クリックの「コレクションを作成」「コレクションに登録」(2026-09-23、利用者の指示。ファイルブラウザの右クリックと同じ)。
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var coverExtractor: CollectionCoverExtractor
    /// 右クリックの「本の書き出し」(2026-09-23)。
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var metadataStore: BookMetadataStore
    /// 表紙の下の文字の大きさ(行の高さの見積もり)と、ホイール1ノッチのスクロール量。
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.revealInFileBrowser) private var revealInFileBrowser
    @Environment(\.locale) private var locale
    /// 文字の輪郭の太さ(リスト表示の AppKit のセルへ渡す。すりガラス面の決まりごと)。
    @Environment(\.panelContentOutlineWidth) private var outlineWidth
    @FocusState private var isSearchFocused: Bool
    /// グリッドがキーの行き先か(矢印キー・Return を受ける。選択の枠の色もこれで決まる ―― `SelectionEmphasisBorder`)。
    @FocusState private var isGridFocused: Bool

    @State private var missingBook: String?
    /// グリッドのスクロール位置。選んだ枠を見える位置へ動かすときは、行の位置を実測から割り出して pt で渡す
    /// (`PanelListScrollTracker` の型コメント: Lazy コンテナの `scrollTo(id:anchor:)` は遠い行へ届かない)。
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollTracker = PanelListScrollTracker(verticalPadding: Self.gridPadding, rowSpacing: Self.spacing)
    /// 寸法を実測する前に頼まれた「見せる」相手(実測が届いたらやり直す)。
    @State private var pendingRevealID: String?
    @State private var metadataTarget: SmartMetadataTarget?
    /// 画面外の表紙を手放すための帳簿(型コメントは CollectionGridView「画面外のカバーを手放す」)。2026-09-22 の監査で指摘:
    /// ここだけ帳簿が無く、表紙の CGImage はセルの `@State` に残る ―― 絵は提供役の mmap 領域を共有するので、提供役の
    /// メモリの上限(96 MB)で追い出されても本体は残り、2,439 冊を端まで流すと 1.7 GB ほどがペインを閉じるまで残る計算だった。
    @State private var cellImageBudget = LazyCellImageBudget(byteBudget: Self.coverByteBudget)
    /// グリッドの見えている大きさ(帳簿の下限セル数を見積もるためだけ)。
    @State private var gridSize: CGSize = .zero
    /// グリッドを描いている `NSScrollView` の入れ物(ホイール1ノッチのスクロール量。`HomeWheelScroll`)。
    @State private var scrollBox = ScrollGeometryBox()
    /// 「コレクションに登録」のサブメニューの中身の控え(右クリックのメニューはセルの本体評価のたびに組まれる。
    /// CollectionMenuLibrary.libraries)。本体評価の中で書き換えるので `@State` の値ではなく入れ物に持つ。
    @State private var collectionMenuCache = CollectionMenuCacheBox()
    /// 操作の結果の知らせ(「コレクションに登録」。ファイルブラウザの FileBrowserState.showToast と同じ見た目・長さ)。
    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    /// 出している「本の書き出し」のシート。
    @State private var exportRequest: HomeBookExportRequest?

    private static let spacing: CGFloat = 16
    private static let gridPadding: CGFloat = 16
    /// 画面外に残ってよい表紙の総量(コレクションの一覧と同じ)。
    private static let coverByteBudget = 64 * 1024 * 1024

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            WelcomeSeparator(axis: .horizontal)
            // まだ一度も集め終えていない・集めている最中で並べる本がまだ無い間は、「本がありません」ではなく読み込み中
            // (SmartLibraryCatalog.hasLoaded のコメント)。
            if (!catalog.hasLoaded || catalog.isLoading), state.gridItems.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.gridItems.isEmpty {
                emptyMessage
            } else if state.viewMode == .list {
                list
            } else {
                grid
            }
        }
        // メニューバーの「ホーム」▸「検索」(⌘F)。
        .onChange(of: home.menuRequest) { _, _ in
            if home.takeMenuRequest(where: { if case .focusSearch = $0 { true } else { false } }) != nil {
                isSearchFocused = true
            }
        }
        .alert(
            "Book Not Found",
            isPresented: Binding(get: { missingBook != nil }, set: { if !$0 { missingBook = nil } })
        ) {
            Button("OK", role: .cancel) { missingBook = nil }
        } message: {
            Text(verbatim: missingBook ?? "")
        }
        .sheet(item: $metadataTarget) { target in
            BookMetadataSheet(fileBrowserEntry: target.entry)
        }
        .homeBookExportSheet($exportRequest, allowsCoverSelection: !appState.isPrivateWindow)
        // メニューバーの「Finder で表示」「ファイルブラウザで表示」(2026-09-23。選んでいる 1 冊。HomeMenuState.singleSmartBookTarget)。
        .onChange(of: home.menuRequest) { _, _ in
            handleBookMenuRequest()
        }
        // 操作の結果の知らせ。一覧の下に浮かべ、クリックは一覧へ通す(FileBrowserPane と同じ作り。文字の輪郭は OverlayToast が掛ける)。
        .overlay(alignment: .bottom) {
            ZStack {
                if let toastMessage {
                    OverlayToast(message: toastMessage)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.2), value: toastMessage)
        }
        .onDisappear { toastDismissTask?.cancel() }
    }

    private var header: some View {
        WelcomePaneHeaderLayout {
            HStack(spacing: 8) {
                // シリーズの束を開いている間は、戻るボタンとシリーズ名(束の一覧へ戻る)。
                if let series = state.openedGroup {
                    Button {
                        state.openedGroup = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .panelIconButtonLabel()
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help(String(format: String(localized: "Back to %@", language: locale),
                                 state.selectedShelf?.name ?? String(localized: "All Books", language: locale)))
                    Text(verbatim: series)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(verbatim: state.selectedShelf?.name ?? String(localized: "All Books", language: locale))
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(verbatim: countText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if catalog.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .panelOutlinedContent()

            WelcomeSearchField(text: $state.searchText, prompt: "Search Books", focus: $isSearchFocused)

            HStack(spacing: 6) {
                // 表紙の大きさはグリッドのときだけ(ファイルブラウザのアイコンの大きさと同じ置き方。左へ伸びるので、出し入れしても
                // 右のボタンは動かない)。
                if state.viewMode == .grid {
                    Slider(value: $state.coverSize, in: SmartLibraryViewState.coverSizeRange)
                        .frame(width: 110)
                        .panelControlWell()
                        .help("Cover Size")
                }
                PanelViewModeButton(systemImage: "square.grid.2x2", helpKey: "as Icons",
                                    isSelected: state.viewMode == .grid) { state.viewMode = .grid }
                PanelViewModeButton(systemImage: "list.bullet", helpKey: "as List",
                                    isSelected: state.viewMode == .list) { state.viewMode = .list }
                groupingMenu
                sortMenu
            }
        }
    }

    /// 束ねない / シリーズで束ねる / 著者で束ねる。束ねている間はアイコンが塗りつぶしになる。
    /// 形は並べ替えのメニューと同じ(WelcomeSortMenu の決まり事: fixedSize と、Menu 自体への輪郭)。
    private var groupingMenu: some View {
        Menu {
            Picker(selection: $state.grouping) {
                ForEach(SmartGrouping.allCases, id: \.self) { grouping in
                    Text(LocalizedStringKey(grouping.titleKey)).tag(grouping)
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: state.grouping == .none ? "square.stack" : "square.stack.fill")
                .panelIconButtonLabel()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .panelOutlinedContent()
        .help(String(localized: String.LocalizationValue(state.grouping.titleKey), language: locale))
    }

    private var countText: String {
        if state.openedGroup != nil {
            return String(format: String(localized: "%lld books", language: locale), state.gridItems.count)
        }
        let visible = state.visibleBooks.count
        let total = state.shelfBookCount
        if visible == total {
            return String(format: String(localized: "%lld books", language: locale), total)
        }
        return String(format: String(localized: "%1$lld of %2$lld books", language: locale), visible, total)
    }

    private var sortMenu: some View {
        Menu {
            Picker(selection: Binding(get: { state.sortKey }, set: { key in
                state.sortKey = key
                state.sortAscending = key.defaultAscending
            })) {
                ForEach(SmartSortKey.allCases, id: \.self) { key in
                    Text(LocalizedStringKey(key.titleKey)).tag(key)
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)
            Divider()
            Picker(selection: $state.sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            } label: { EmptyView() }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .panelIconButtonLabel()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // WelcomeSortMenu と同じ決まり事(fixedSize と、Menu 自体への輪郭)。
        .fixedSize()
        .panelOutlinedContent()
        .help("Sort By")
    }

    private var emptyMessage: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Text(catalog.books.isEmpty ? "No books to show" : "No books match")
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
            Text(catalog.books.isEmpty
                 ? "Books in the target folders you add on the left appear here."
                 : "Change the conditions or the filters on the left.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .panelOutlinedContent()
            if state.isNarrowing {
                Button("Clear All Filters") { state.clearNarrowing() }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 帳簿の下限セル数(CollectionGridView.minimumCellCount と同じ見積もり。表紙 + 下の 2 行)。
    private var minimumCellCount: Int {
        LazyCellImageBudget.minimumCellCount(
            visibleSize: gridSize, cellWidth: state.coverSize,
            cellHeight: state.coverSize * preferences.smartLibraryCoverShape.heightRatio + 30,
            spacing: Self.spacing, padding: Self.gridPadding
        )
    }

    /// セルが表紙を持った(帳簿に付ける)。
    private func noteRetained(_ image: CGImage) {
        cellImageBudget.note(retaining: image, minimumCellCount: minimumCellCount)
    }

    /// グリッドの作り直しの鍵。帳簿の世代に加えて、並ぶものが総入れ替えになる場面(棚の切り替え・束を開く/戻る)でも
    /// 作り直す ―― Lazy コンテナは ForEach の中身が入れ替わっても前のセルを手放さない(CollectionGridView の gridID と同じ)。
    private var gridID: String {
        "\(cellImageBudget.epoch)|\(state.selectedShelfID?.uuidString ?? "")|\(state.openedGroup ?? "")"
    }

    /// 列の数(グリッドの割り付けと同じ式)。矢印キーの上下の移動量と、行の位置の割り出しに使う。
    private var columnCount: Int {
        WelcomeGridColumns(
            availableWidth: gridSize.width, itemWidth: state.coverSize, spacing: Self.spacing, padding: Self.gridPadding
        ).count
    }

    private func rowCount(columns: Int) -> Int {
        (state.gridItems.count + columns - 1) / max(1, columns)
    }

    /// グリッド1行ぶんの間隔(表紙の高さ + 下の文字2行 + 行間)。ホイール1ノッチのスクロール量が使う。
    ///
    /// 実測ではなく見積もりである(`ThumbnailGridView.gridRowHeight` と同じ理由: 行の高さは LazyVGrid が
    /// 決めたあとでしか分からず、そのときにはホイールのイベントを処理し終えている)。下の文字は常に2行ぶん
    /// (`SmartCaptionLines`)で、行間1pt + 表紙との間 4pt。既定の10ptでは 31pt ―― `minimumCellCount` が
    /// 使っている概算の 30 とほぼ同じ。
    static func gridRowPitch(coverSize: CGFloat, coverShape: SmartLibraryCoverShape, appearance: AppearanceSettings) -> CGFloat {
        let fontSize = appearance.smartLibraryCaptionFontSize
        let caption = (fontSize * 1.3).rounded(.up) * 2 + 1 + 4
        return coverSize * coverShape.heightRatio + caption + Self.spacing
    }

    /// ■ 選択とキー操作(2026-09-22、利用者の指示。StackNest / ShelfRow の調査から)
    /// - クリックで選ぶ、⌘ で足す/外す、⇧ で範囲、余白のクリックで外す。**ダブルクリックで開く**(本は開き、束は中へ。
    ///   Finder・ファイルブラウザのアイコン表示と同じ。それまでは 1 回のクリックで開いていた)
    /// - 矢印キー(⇧ で範囲)・Home / End・PageUp / PageDown・⌘A・文字のキーで頭文字の枠へ(type-select)。Return / Enter /
    ///   ⌘↓ で開く、⌘↑ で束から出る(Esc の「戻る」と同じ)
    /// - 絞り込み・検索・並べ替えを変えたら先頭へ戻す(`scrollResetSerial`。裏での集め直しでは戻さない)
    /// - **キーは動かないグリッドの外枠で受ける**(ShelfRow が踏んだ罠: 使い回されるセルに焦点を持たせると、セルが
    ///   手放された時点でキーの行き先が消え、矢印キーを押し続けると止まる)。外枠は `.id(gridID)` の外なので作り直されない
    /// - スクロールは選択から一方向だけ(`reveal`)。見えていれば動かさず、はみ出したぶんだけ動かす
    ///
    /// 行の位置を割り出せるよう、セルの高さは揃えてある(`SmartCaptionLines`。下の文字は常に 2 行ぶん)。
    private var grid: some View {
        GeometryReader { proxy in
            let columns = WelcomeGridColumns(
                availableWidth: proxy.size.width, itemWidth: state.coverSize,
                spacing: Self.spacing, padding: Self.gridPadding
            )
            ScrollView {
                LazyVGrid(columns: columns.gridItems(alignment: .top), spacing: Self.spacing) {
                    ForEach(state.gridItems) { item in
                        let isSelected = state.selection.contains(item.id)
                        switch item {
                        case .book(let book):
                            SmartBookCell(
                                book: book, width: state.coverSize, coverShape: preferences.smartLibraryCoverShape,
                                // 著者でまとめている一覧では、束と同じく著者名だけを出す(2026-09-22、利用者の指示)。
                                showsAuthorOnly: state.grouping == .author && state.openedGroup == nil,
                                isSelected: isSelected, isFocused: isGridFocused,
                                savesToDisk: !appState.isPrivateWindow, onImageRetained: noteRetained
                            )
                                .onTapGesture { clicked(item) }
                                // Finder などへ運ぶと本がコピーされる(2026-09-23。HomeBookTransfer.swift の冒頭)。
                                .homeBookDragSource { beginDrag(from: item) }
                                .contextMenu { contextMenu(for: item) }
                        case .group(let grouping, let name, let books):
                            SmartGroupCell(grouping: grouping, name: name, books: books, width: state.coverSize,
                                           coverShape: preferences.smartLibraryCoverShape,
                                           isSelected: isSelected, isFocused: isGridFocused,
                                           savesToDisk: !appState.isPrivateWindow, onImageRetained: noteRetained)
                                .onTapGesture { clicked(item) }
                                .contextMenu {
                                    Button(grouping == .author ? "Show Books by This Author" : "Show Books in Series") {
                                        state.openedGroup = name
                                    }
                                    if grouping == .series, let first = books.first {
                                        Button("Open First Volume") { open(first) }
                                    }
                                }
                        }
                    }
                }
                .frame(width: columns.contentWidth)
                .frame(maxWidth: .infinity)
                .padding(Self.gridPadding)
                // 画面外の表紙をまとめて手放す(`cellImageBudget`)。ScrollView の内側なのでスクロール位置は変わらない。
                .id(gridID)
                // ホイール1ノッチのスクロール量のために、裏の NSScrollView を控える(ScrollViewAccessor の
                // コメント: **ScrollView の内側**に置くこと)。
                .background(ScrollViewAccessor(onResolve: { scrollBox.scrollView = $0 }))
            }
            .scrollPosition($scrollPosition)
            // 一覧の寸法とスクロール量を実測して控える(PanelListScrollTracker)。
            .onScrollGeometryChange(for: PanelListScrollTracker.Metrics.self) { geometry in
                PanelListScrollTracker.Metrics(
                    offsetY: geometry.contentOffset.y,
                    visibleRect: geometry.visibleRect,
                    contentHeight: geometry.contentSize.height
                )
            } action: { _, newValue in
                if scrollTracker.update(newValue, rowCount: rowCount(columns: columns.count)), let pendingRevealID {
                    reveal(pendingRevealID)
                }
            }
        }
        // 物理マウスホイール1ノッチで「設定したグリッドの行数」ぶん動かす(HomeWheelScroll)。
        .homeGridWheelScroll(
            scrollBox: scrollBox,
            distancePerNotch: Self.gridRowPitch(coverSize: state.coverSize, coverShape: preferences.smartLibraryCoverShape,
                                                appearance: appearance)
                * CGFloat(appearance.homeGridWheelScrollRows)
        )
        // 余白のクリックで選択を外す(セルのクリックはセルの側が先に受ける)。
        .contentShape(Rectangle())
        .onTapGesture {
            state.clearSelection()
            isGridFocused = true
        }
        .focusable()
        .focused($isGridFocused)
        .onKeyPress(phases: [.down, .repeat]) { press in
            handleKey(press)
        }
        // 「編集」▸「すべてを選択」(⌘A)。グリッドがキーの行き先のときだけ効く。
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            state.selectAll()
        }
        // 「編集」▸「コピー」(⌘C)。選んでいる本をコピーする(束は運ばない。右クリックと同じ)。
        .onCommand(#selector(NSText.copy(_:))) {
            copy(state.selectedItems)
        }
        .onChange(of: state.revealRequest) { _, request in
            if let request { reveal(request.id) }
        }
        // 絞り込み・検索・並べ替え・棚・束ね方を変えたら先頭から(`SmartLibraryViewState.scrollResetSerial`)。
        .onChange(of: state.scrollResetSerial) { _, _ in
            pendingRevealID = nil
            scrollPosition.scrollTo(edge: .top)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            gridSize = size
        }
    }

    /// セルのクリック。2 回目のクリック(ダブルクリック)なら開く。修飾キーはクリックの出来事から読む
    /// (SwiftUI の `TapGesture` は修飾キーもクリックの回数も渡さない。回数ごとに別の `TapGesture` を重ねると、
    /// 1 回のクリックがダブルクリックの間隔ぶん待たされる)。
    private func clicked(_ item: SmartGridItem) {
        isGridFocused = true
        let event = NSApp.currentEvent
        if let event, event.clickCount >= 2 {
            activate(item)
            return
        }
        let flags = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        let click: SmartGridSelection.Click = flags.contains(.command) ? .toggle : (flags.contains(.shift) ? .extend : .plain)
        state.click(item.id, click)
    }

    /// 枠を開く: 本は開き、束はその中へ。
    private func activate(_ item: SmartGridItem) {
        switch item {
        case .book(let book): open(book)
        case .group(_, let name, _): state.openedGroup = name
        }
    }

    /// Return / ⌘↓。開けるのは 1 つだけ選んでいるとき(複数のときに 1 つだけ開くと、どれが開いたのか読めない)。
    private func openSelection() {
        let items = state.selectedItems
        guard !items.isEmpty else { return }
        guard items.count == 1, let item = items.first else {
            NSSound.beep()
            return
        }
        activate(item)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let modifiers = press.modifiers
        guard modifiers.isDisjoint(with: [.option, .control]) else { return .ignored }
        let command = modifiers.contains(.command)
        let extending = modifiers.contains(.shift)
        let columns = columnCount
        var target: String?
        switch press.key {
        case .return, KeyEquivalent("\u{03}"):
            // Return とテンキーの Enter。
            guard !command else { return .ignored }
            openSelection()
            return .handled
        case .upArrow where command:
            guard state.openedGroup != nil else { return .ignored }
            state.openedGroup = nil
            return .handled
        case .downArrow where command:
            openSelection()
            return .handled
        case _ where command:
            return .ignored
        case .upArrow: target = state.moveSelection(.up, extending: extending, columns: columns)
        case .downArrow: target = state.moveSelection(.down, extending: extending, columns: columns)
        case .leftArrow: target = state.moveSelection(.left, extending: extending, columns: columns)
        case .rightArrow: target = state.moveSelection(.right, extending: extending, columns: columns)
        case .home: target = state.jumpSelection(.first, extending: extending)
        case .end: target = state.jumpSelection(.last, extending: extending)
        case .pageUp: target = state.jumpSelection(.pageUp(pageStep(columns: columns)), extending: extending)
        case .pageDown: target = state.jumpSelection(.pageDown(pageStep(columns: columns)), extending: extending)
        default:
            // 文字のキーは type-select(`SmartLibraryViewState.typeSelect`)。制御文字・矢印などの機能キー(U+F700〜)は受けない。
            let characters = press.characters
            guard !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ scalar in
                      !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
                          && scalar.value != 0x7F
                  })
            else { return .ignored }
            target = state.typeSelect(characters)
        }
        if let target { reveal(target) }
        return .handled
    }

    /// PageUp / PageDown で動く件数(1 画面の行数 × 列数)。
    private func pageStep(columns: Int) -> Int {
        (scrollTracker.rowsPerPage(rowCount: rowCount(columns: columns)) ?? 1) * columns
    }

    /// 枠を見える位置へ(見えていれば動かさない。はみ出していればそのぶんだけ。アニメーションはしない ―― 矢印キーを
    /// 押し続けたときに追いつかない)。寸法をまだ実測していなければ、届いたときにやり直す。
    private func reveal(_ id: String) {
        guard let index = state.gridItems.firstIndex(where: { $0.id == id }) else {
            pendingRevealID = nil
            return
        }
        let columns = columnCount
        let row = index / columns
        if let offset = scrollTracker.offsetToReveal(rows: row...row, rowCount: rowCount(columns: columns)) {
            scrollPosition.scrollTo(y: offset)
        }
        let pending = scrollTracker.hasPendingReveal ? id : nil
        if pendingRevealID != pending { pendingRevealID = pending }
    }

    /// 本の右クリック。**右クリックした本が選択に入っていれば選んだ本の全部が相手**(`SmartLibraryViewState.contextTargets`)。
    /// 1 冊を相手にする操作(開く・ファイルブラウザで表示・メタデータの編集)は、複数が相手のあいだ淡色にする
    /// (コレクションの中のカバーと同じ。押せてしまうと、どの 1 冊に効くのか画面から読めない)。
    /// 「情報を見る」はファイルブラウザの右クリックと同じ Finder の情報ウインドウ(2026-09-22、利用者の指示)。
    /// リスト表示の右クリック(`listMenu`)も同じ項目・同じ動き。
    @ViewBuilder
    private func contextMenu(for item: SmartGridItem) -> some View {
        let targets = Self.books(in: state.contextTargets(for: item))
        let isSingle = targets.count == 1
        if let book = targets.first {
            BookOpenContextMenuItems(
                onOpen: { open(book) },
                onOpenIn: { openIn(book, $0) }
            )
            .disabled(!isSingle)
            openWithMenu(for: book, isEnabled: isSingle)
            if showsCollections {
                Divider()
                collectionMenuItems(for: targets)
            }
            Divider()
            Button("Copy") { copy(targets) }
            Divider()
            Button("Show in Finder") { showInFinder(targets) }
            if revealInFileBrowser.isFeatureEnabled {
                Button("Show in File Browser") { showInFileBrowser(book) }
                    .disabled(!isSingle)
            }
            Button("Get Info") { getInfo(targets) }
            Divider()
            // シークレットウインドウでは淡色(保存データへの書き込み。項目ごと消すのは機能が OFF のときだけ ―― 利用者の決定 2026-09-23)。
            Button("Edit Metadata…") { editMetadata(book) }
                .disabled(!allowsEditing || !isSingle)
            // 「本の書き出し」(2026-09-23。ファイルブラウザの右クリックと同じ。書き出し自体は保存データを書かないので、シークレット
            // ウインドウでも使える ―― カバーの選択は淡色、ページ一覧のディスクキャッシュも読み書きしない)。
            BookExportMenu(isEnabled: isSingle && exportRequest == nil) { format in startExport(book, format: format) }
        }
    }

    /// 「このアプリケーションで開く」(2026-09-23。コレクションの中の本と同じ中身。候補は名前だけで引く)。
    @ViewBuilder
    private func openWithMenu(for book: SmartBook, isEnabled: Bool) -> some View {
        let title = String(localized: "Open With", language: locale)
        if isEnabled {
            Menu(title) { FileBrowserMenuNodeItems(nodes: openWithNodes(for: book)) }
        } else {
            FileBrowserDisabledSubmenu(title: title)
        }
    }

    private func openWithNodes(for book: SmartBook) -> [FileBrowserMenuNode] {
        let locale = locale
        return OpenWithApplications.shared.menuNodes(
            for: HomeBookOpenWith.applications(forBookAt: book.id), locale: locale,
            open: { application in openWith(book, application: application) },
            chooseOther: {
                guard let application = OpenWithApplications.chooseApplication(locale: locale) else { return }
                openWith(book, application: application)
            }
        )
    }

    private func openWith(_ book: SmartBook, application: URL) {
        let locale = locale
        withResolvedURL(for: book) { url in
            HomeBookOpenWith.open(url, withApplicationAt: application, scoped: false, locale: locale)
        }
    }

    /// 「本の書き出し」▸ 形式。保存先の決め方はファイルブラウザ・ビューアの右クリックと同じ(FileBrowserBookSheet.Export.make)。
    private func startExport(_ book: SmartBook, format: BookExportFormat) {
        guard exportRequest == nil else { return }
        withResolvedURL(for: book) { url in
            guard let export = FileBrowserBookSheet.Export.make(
                url: url, bookID: book.id, isDirectory: book.kind == .folder, format: format, preferences: preferences,
                bookmarkStore: bookmarkStore, layoutStore: layoutStore, metadataStore: metadataStore,
                usesPageListCache: !appState.isPrivateWindow
            ) else { return }
            exportRequest = HomeBookExportRequest(export: export)
        }
    }

    /// リスト表示の右クリック(AppKit のメニュー。中身はグリッドの `contextMenu` / 束の右クリックと同じ)。
    private func listMenu(clicked: SmartGridItem, targets: [SmartGridItem]) -> [SmartLibraryListView.MenuItem] {
        func title(_ key: String.LocalizationValue) -> String { String(localized: key, language: locale) }
        typealias Item = SmartLibraryListView.MenuItem
        if case .group(let grouping, let name, let books) = clicked {
            var items = [Item(title: title(grouping == .author ? "Show Books by This Author" : "Show Books in Series"),
                              action: { state.openedGroup = name })]
            if grouping == .series, let first = books.first {
                items.append(Item(title: title("Open First Volume"), action: { open(first) }))
            }
            return items
        }
        let books = Self.books(in: targets)
        guard let book = books.first else { return [] }
        let isSingle = books.count == 1
        var items: [Item] = [
            Item(title: title("Open"), isEnabled: isSingle, action: { open(book) }),
            .separator,
            Item(title: title("Open in New Normal Window"), isEnabled: isSingle, action: { openIn(book, .newNormalWindow) }),
            Item(title: title("Open in New Private Window"), isEnabled: isSingle, action: { openIn(book, .newPrivateWindow) }),
            Item(title: title("Open in New Tab"), isEnabled: isSingle, action: { openIn(book, .newTab) }),
            Item(title: title("Open With"), isEnabled: isSingle, submenu: isSingle ? openWithNodes(for: book) : []),
        ]
        if showsCollections {
            let libraries = collectionMenuLibraries()
            let isEnabled = allowsCollections
            items.append(.separator)
            if let nodes = CollectionMenuLibrary.createMenuNodes(for: libraries, create: { createCollection(from: books, libraryID: $0) }) {
                items.append(Item(title: title("Create Collection"), isEnabled: isEnabled, submenu: nodes))
            } else {
                items.append(Item(
                    title: title("Create Collection"), isEnabled: isEnabled, action: { createCollection(from: books, libraryID: nil) }
                ))
            }
            items.append(Item(
                title: title("Add to Collection"), isEnabled: isEnabled,
                submenu: CollectionMenuLibrary.addMenuNodes(for: libraries, locale: locale) { addToCollection(books, collectionID: $0) }
            ))
        }
        items += [
            .separator,
            Item(title: title("Copy"), action: { copy(books) }),
            .separator,
            Item(title: title("Show in Finder"), action: { showInFinder(books) }),
        ]
        if revealInFileBrowser.isFeatureEnabled {
            items.append(Item(title: title("Show in File Browser"), isEnabled: isSingle, action: { showInFileBrowser(book) }))
        }
        items.append(Item(title: title("Get Info"), action: { getInfo(books) }))
        items.append(.separator)
        items.append(Item(title: title("Edit Metadata…"), isEnabled: allowsEditing && isSingle, action: { editMetadata(book) }))
        items.append(Item(
            title: title("Export Book"), isEnabled: isSingle && exportRequest == nil,
            submenu: BookExportFormat.menuNodes(locale: locale) { format in startExport(book, format: format) }
        ))
        return items
    }

    /// メニューバーから、選んでいる本を Finder / ファイルブラウザで表示する。在るかの確かめは右クリックと同じ(withResolvedURL)。
    private func handleBookMenuRequest() {
        guard let kind = home.takeMenuRequest(where: {
            switch $0 {
            case .showSmartBookInFinder, .showSmartBookInFileBrowser: true
            default: false
            }
        }) else { return }
        switch kind {
        case .showSmartBookInFinder(let path):
            guard let book = catalog.books.first(where: { $0.id == path }) else { return }
            showInFinder([book])
        case .showSmartBookInFileBrowser(let path):
            guard revealInFileBrowser.isFeatureEnabled, let book = catalog.books.first(where: { $0.id == path }) else { return }
            showInFileBrowser(book)
        default:
            break
        }
    }

    // MARK: コレクション・コピー・ドラッグ(2026-09-23、利用者の指示)

    /// 右クリックに「コレクションを作成」「コレクションに登録」を出すか。ライブラリ機能が ON なら出す(ファイルブラウザの右クリックと同じ)。
    private var showsCollections: Bool { home.isLibraryFeatureEnabled }

    /// それらを押せるか。シークレットウインドウでは淡色(コレクションは保存データへの書き込み。項目ごと消すのは機能が OFF のときだけ ――
    /// 利用者の決定 2026-09-23。以前はシークレットウインドウでも消していた)。操作の入口もこれで断る。
    private var allowsCollections: Bool {
        allowsEditing && home.isLibraryFeatureEnabled
    }

    private func collectionMenuLibraries() -> [CollectionMenuLibrary] {
        CollectionMenuLibrary.libraries(
            in: collectionStore, sort: home.collectionSort, locale: locale, cache: &collectionMenuCache.cache
        )
    }

    /// 「コレクションを作成」「コレクションに登録」(グリッドの右クリック)。ライブラリが複数なら作る先はサブメニューで選ぶ
    /// (ファイルブラウザと同じ形。FileBrowserMenuCommand.dynamicChildren)。
    @ViewBuilder
    private func collectionMenuItems(for books: [SmartBook]) -> some View {
        if allowsCollections {
            enabledCollectionMenuItems(for: books)
        } else {
            // `.contextMenu` の中の `Menu` には `.disabled` が効かない(FileBrowserDisabledSubmenu の型コメント)。
            FileBrowserDisabledSubmenu(title: String(localized: "Create Collection", language: locale))
            FileBrowserDisabledSubmenu(title: String(localized: "Add to Collection", language: locale))
        }
    }

    @ViewBuilder
    private func enabledCollectionMenuItems(for books: [SmartBook]) -> some View {
        let libraries = collectionMenuLibraries()
        if let nodes = CollectionMenuLibrary.createMenuNodes(for: libraries, create: { createCollection(from: books, libraryID: $0) }) {
            Menu("Create Collection") { FileBrowserMenuNodeItems(nodes: nodes) }
        } else {
            Button("Create Collection") { createCollection(from: books, libraryID: nil) }
        }
        Menu("Add to Collection") {
            FileBrowserMenuNodeItems(nodes: CollectionMenuLibrary.addMenuNodes(for: libraries, locale: locale) {
                addToCollection(books, collectionID: $0)
            })
        }
    }

    /// 「コレクションを作成」。名前を訊くシート(ホームが持つ。WelcomeView.creationSheet)を積む。ここに並ぶのは 1 冊ずつの本なので、
    /// 選んだ本をまとめて 1 つのコレクションにする(ファイルブラウザでばらの本を選んだときと同じ。WelcomeDropHandling.queueCreations)。
    private func createCollection(from books: [SmartBook], libraryID: UUID?) {
        guard allowsCollections else { return }
        withResolvedURLs(for: books) { [home] urls in
            // 本を確かめているあいだにライブラリ機能を OFF にされていたら、シートを積まない(FileBrowserActions.createCollection と同じ)。
            guard home.isLibraryFeatureEnabled else { return }
            WelcomeDropHandling.queueCreations(from: urls.map { .book($0) }, into: home, libraryID: libraryID)
        }
    }

    /// 「コレクションに登録」▸ コレクション。同じ本が既に入っていれば足さない(CollectionStore.add)。何が入ったかを短く知らせる。
    private func addToCollection(_ books: [SmartBook], collectionID: UUID) {
        guard allowsCollections else { return }
        let locale = locale
        withResolvedURLs(for: books) { [home, collectionStore, coverExtractor] urls in
            // 本を確かめているあいだにライブラリ機能を OFF にされていたら登録しない(OFF の間はコレクションの行に触らない)。
            guard home.isLibraryFeatureEnabled else { return }
            Task { @MainActor in
                guard let result = await CollectionBookAdding.add(
                    urls, to: collectionID, collectionStore: collectionStore, coverExtractor: coverExtractor,
                    isStillEnabled: { home.isLibraryFeatureEnabled }
                ) else { return }
                showToast(FileBrowserActions.addedToCollectionMessage(
                    addedTitles: result.addedTitles, requestedCount: result.requestedCount,
                    collectionName: result.collectionName, locale: locale
                ))
            }
        }
    }

    private func showToast(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: FileBrowserState.toastDuration)
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }

    /// 右クリックの「コピー」・⌘C。本の実体をペーストボードへ(Finder へ貼るとコピーになる。HomeBookTransfer.swift の冒頭)。
    /// 束は運ばない(ファイルとしての実体が無い)。本が無ければ鳴らす。
    private func copy(_ items: [SmartGridItem]) {
        let books = Self.books(in: items)
        guard !books.isEmpty else {
            NSSound.beep()
            return
        }
        copy(books)
    }

    private func copy(_ books: [SmartBook]) {
        withResolvedURLs(for: books) { [weak appState] urls in
            HomeBookPasteboard.copy(urls, fileBrowser: appState?.fileBrowser)
        }
    }

    /// 表紙を引きずり始めた。右クリックと同じく、選んでいる本を掴んだなら選んだ本の全部を運ぶ(束は運ばない)。
    /// 在るかは確かめない ―― ドラッグは出来事の中で始めるので待てない(無ければ落とした先が断る)。
    private func beginDrag(from item: SmartGridItem) {
        let books = Self.books(in: state.contextTargets(for: item))
        HomeBookDragSource.begin(
            books: books.map { (URL(fileURLWithPath: $0.id, isDirectory: $0.kind == .folder), $0.kind == .folder) },
            appState: appState
        )
    }

    private static func books(in items: [SmartGridItem]) -> [SmartBook] {
        items.compactMap { item in
            if case .book(let book) = item { return book }
            return nil
        }
    }

    private func openIn(_ book: SmartBook, _ destination: BookOpenDestination) {
        let sequence = state.sequence(opening: book)
        withResolvedURL(for: book) { url in
            BookWindowOpener.open(
                BookOpenRequest(url, sequence: sequence), to: destination, from: appState,
                launchCoordinator: launchCoordinator, openWindow: openWindow
            )
        }
    }

    private func showInFinder(_ books: [SmartBook]) {
        withResolvedURLs(for: books) { urls in
            if urls.count == 1, let url = urls.first {
                FinderReveal.reveal(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    }

    private func showInFileBrowser(_ book: SmartBook) {
        withResolvedURL(for: book) { revealInFileBrowser($0) }
    }

    private func getInfo(_ books: [SmartBook]) {
        withResolvedURLs(for: books) { FinderReveal.showInfo($0) }
    }

    private func editMetadata(_ book: SmartBook) {
        // シークレットウインドウでは淡色(右クリック)。入口でも断る。
        guard allowsEditing else { return }
        withResolvedURL(for: book) { url in
            metadataTarget = SmartMetadataTarget(entry: FileBrowserEntry(
                url: url, displayName: book.fileName, isDirectory: book.kind == .folder, isPackage: false,
                isSymbolicLink: false, isVolume: false, fileSize: book.fileSize, typeDescription: nil,
                creationDate: book.creationDate, modificationDate: book.modificationDate))
        }
    }

    /// リスト表示(`SmartLibraryListView`。束は疑似的なフォルダ)。選択・並べ替え・束の出入りはグリッドと同じ状態を使う。
    private var list: some View {
        SmartLibraryListView(
            items: state.gridItems,
            selection: state.selection,
            sortKey: state.sortKey,
            sortAscending: state.sortAscending,
            revealRequest: state.revealRequest,
            scrollResetSerial: state.scrollResetSerial,
            outlineWidth: outlineWidth,
            locale: locale,
            wheelScrollRows: appearance.homeListWheelScrollRows,
            onSelectionChange: { [state] ids, cursor in state.setSelection(ids, cursor: cursor) },
            onSort: { [state] key, ascending in
                state.sortKey = key
                state.sortAscending = ascending
            },
            onActivate: { item in activate(item) },
            onLeaveGroup: { [state] in
                guard state.openedGroup != nil else { return false }
                state.openedGroup = nil
                return true
            },
            menu: { clicked, targets in listMenu(clicked: clicked, targets: targets) },
            onCopy: { items in copy(items) },
            onDragBegan: { [weak appState] urls in HomeBookDragTracker.begin(urls, from: appState) }
        )
    }

    /// 本の実体の URL(パスそのもの。FolderAccessStore が許可した対象フォルダの中)を確かめてから `body` を呼ぶ。
    /// 見つからなければ「本が見つかりません」。
    ///
    /// **在るかの確かめは FileIO の上で**(2026-09-22 の監査で指摘)。一覧は保存した前回のものを先に出すので、対象フォルダが
    /// 眠っている・切れているネットワークのボリュームでも表紙は並ぶ。そこで main から `fileExists` を呼ぶと、クリック 1 回で
    /// SMB のタイムアウト(30 秒)までアプリ全体が固まった。
    private func withResolvedURL(for book: SmartBook, _ body: @escaping @MainActor (URL) -> Void) {
        let url = URL(fileURLWithPath: book.id, isDirectory: book.kind == .folder)
        let path = url.path
        Task { @MainActor in
            let exists = await FileIO.perform { FileManager.default.fileExists(atPath: path) }
            if exists {
                body(url)
            } else {
                missingBook = book.id
            }
        }
    }

    /// 何冊か(右クリックの相手)の URL を確かめてから `body` を呼ぶ。見つかった本だけを渡し、1 冊も見つからなければ
    /// 「本が見つかりません」。確かめは FileIO の上で(`withResolvedURL` と同じ理由)。
    private func withResolvedURLs(for books: [SmartBook], _ body: @escaping @MainActor ([URL]) -> Void) {
        let urls = books.map { URL(fileURLWithPath: $0.id, isDirectory: $0.kind == .folder) }
        let paths = urls.map(\.path)
        Task { @MainActor in
            let exists = await FileIO.perform { paths.map { FileManager.default.fileExists(atPath: $0) } }
            let found = zip(urls, exists).filter(\.1).map(\.0)
            if found.isEmpty {
                missingBook = books.first?.id
            } else {
                body(found)
            }
        }
    }

    private func open(_ book: SmartBook) {
        // 見えている並びを渡す ―― 「次の本へ」「前の本へ」がこの並びをたどる(BookSequence)。
        let sequence = state.sequence(opening: book)
        withResolvedURL(for: book) { appState.open(request: BookOpenRequest($0, sequence: sequence)) }
    }
}

/// メタデータの編集シートの相手(ファイルブラウザの右クリックと同じ版で開く)。
private struct SmartMetadataTarget: Identifiable {
    let entry: FileBrowserEntry
    var id: String { entry.id }
}

/// 表紙 1 枚と、その下の題・著者。
private struct SmartBookCell: View {
    let book: SmartBook
    let width: CGFloat
    /// 表紙の形(環境設定「スマートライブラリ」。枠の高さと、切るかどうか)。
    var coverShape: SmartLibraryCoverShape = .matchImage
    /// 著者名だけを出す(著者でまとめた一覧の、1 冊だけの著者の本。束の下と揃える)。著者の無い本は題を出す
    /// (出せる名前が無いので)。
    var showsAuthorOnly = false
    /// 選んでいるか・グリッドがキーの行き先か(選択の枠の色。`SmartBookThumbnail`)。
    var isSelected = false
    var isFocused = true
    /// 作った表紙をディスクキャッシュへ書くか(シークレットウインドウは false。FileBrowserThumbnailProvider の型コメント)。
    var savesToDisk = true
    /// 表紙の絵をセルが持ったときに呼ぶ(グリッドの帳簿。SmartLibraryContent.cellImageBudget)。
    var onImageRetained: (CGImage) -> Void = { _ in }
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        // 文字の大きさは環境設定「外観」→「ホーム」→「スマートライブラリ」(2026-09-22)。2 行とも同じ大きさ
        // (設定にする前の .caption / .caption2 は macOS ではどちらも 10pt)。
        let fontSize = appearance.smartLibraryCaptionFontSize
        VStack(spacing: 4) {
            SmartBookThumbnail(book: book, width: width, height: width * coverShape.heightRatio,
                               cropAspect: coverShape.cropAspect, isSelected: isSelected, isFocused: isFocused,
                               savesToDisk: savesToDisk, onImageRetained: onImageRetained)
            SmartCaptionLines(fontSize: fontSize, width: width) {
                if showsAuthorOnly, let author = book.metadata.authors.first, !author.isEmpty {
                    Text(verbatim: author)
                        .font(.system(size: fontSize, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(verbatim: book.displayTitle)
                        .font(.system(size: fontSize))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let author = book.metadata.authors.first {
                        Text(verbatim: author)
                            .font(.system(size: fontSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .help(helpText)
    }

    private var helpText: String {
        var lines = [book.fileName]
        if !book.metadata.series.isEmpty {
            lines.append(book.metadata.volume.isEmpty ? book.metadata.series : "\(book.metadata.series) \(book.metadata.volume)")
        }
        return lines.joined(separator: "\n")
    }
}

/// 表紙の下の文字。**いつも 2 行ぶんの高さを取る**(2026-09-22): グリッドの行の高さが揃っていないと、キー操作で選んだ枠の
/// 行の位置を実測から割り出せない(`SmartLibraryContent.reveal`)。StackNest も同じ理由で文字の高さを固定している。
/// 中身が 1 行なら上に寄せる。
private struct SmartCaptionLines<Content: View>: View {
    let fontSize: CGFloat
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            // 高さを取るためだけの 2 行(見せない)。
            VStack(spacing: 1) {
                Text(verbatim: " ")
                Text(verbatim: " ")
            }
            .font(.system(size: fontSize))
            .hidden()
            VStack(spacing: 1) { content }
        }
        .frame(width: width)
        .panelOutlinedContent()
    }
}

/// シリーズの束(2026-09-22、利用者の指示)。**束だと見て分かるように**、1 巻目の表紙の後ろに紙を 2 枚ずらして重ね、
/// 右下に冊数のバッジを付ける(コレクションの札の冊数バッジと同じ形 ―― 地が不透明なので輪郭は掛けない)。
/// 紙とバッジは**表紙の絵の実際の大きさ**に合わせる(枠に合わせると、細長い表紙の左右から紙がはみ出した。利用者の指摘)
/// ので、描くのは表紙と同じ `SmartBookThumbnail`(`stack`)。下の文字はシリーズ名と著者(冊数はバッジにあるので書かない。
/// 2026-09-22、利用者の指示)。押すと束の中の本が並ぶ(SmartLibraryViewState.openedGroup)。
///
/// 著者の束(2026-09-22)も同じ形。下の文字は著者名と、2 行目にその著者のシリーズ(1 つならその名前、複数なら
/// 「N シリーズ」、シリーズの無い本だけなら出さない)。
private struct SmartGroupCell: View {
    let grouping: SmartGrouping
    let name: String
    let books: [SmartBook]
    let width: CGFloat
    var coverShape: SmartLibraryCoverShape = .matchImage
    var isSelected = false
    var isFocused = true
    var savesToDisk = true
    var onImageRetained: (CGImage) -> Void = { _ in }
    @EnvironmentObject private var appearance: AppearanceSettings

    /// 名前の下の 2 行目。シリーズの束は著者。**著者の束は何も出さない**(2026-09-22、利用者の指示: 著者でまとめたら、
    /// 著者名の下に作品名は出さない。以前は束の本が 1 つのシリーズならその名前、複数なら「N シリーズ」を出していた ――
    /// 1 冊だけの著者の本も著者名だけなので、束によって作品名が出たり出なかったりした)。
    private var subtitle: String? {
        switch grouping {
        case .series: return author
        case .author, .none: return nil
        }
    }

    /// シリーズの著者: 束の本の先頭の著者のうち、いちばん多く出てくるもの(同数なら巻の早いほう)。
    /// 巻ごとに作画担当が違うシリーズでも 1 人に決まり、束の下が長くならない。
    private var author: String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for book in books {
            guard let first = book.metadata.authors.first, !first.isEmpty else { continue }
            if counts[first] == nil { order.append(first) }
            counts[first, default: 0] += 1
        }
        return order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) || ((counts[$0] ?? 0) == (counts[$1] ?? 0)
            && (order.firstIndex(of: $0) ?? 0) > (order.firstIndex(of: $1) ?? 0)) }
    }

    /// 後ろの紙のずらし幅。
    private var offset: CGFloat { max(3, width * 0.035) }

    var body: some View {
        let height = width * coverShape.heightRatio
        VStack(spacing: 4) {
            if let first = books.first {
                // 紙をずらすぶん(右と上に 2 枚ぶん)を空けて、表紙はその内側に描く。
                SmartBookThumbnail(
                    book: first, width: width - offset * 2, height: height - offset * 2,
                    cropAspect: coverShape.cropAspect,
                    stack: .init(layers: 2, offset: offset, count: books.count),
                    isSelected: isSelected, isFocused: isFocused,
                    savesToDisk: savesToDisk, onImageRetained: onImageRetained
                )
                .frame(width: width, height: height, alignment: .bottomLeading)
            }
            SmartCaptionLines(fontSize: appearance.smartLibraryCaptionFontSize, width: width) {
                Text(verbatim: name)
                    .font(.system(size: appearance.smartLibraryCaptionFontSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: appearance.smartLibraryCaptionFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .help(name)
    }
}

/// 本の表紙(ファイルブラウザのアイコン表示と同じ提供役から引く。FileBrowserCoverArea と同じ)。
private struct SmartBookThumbnail: View {
    /// 束として描くときの、後ろの紙と冊数バッジ(SmartGroupCell)。
    struct Stack {
        let layers: Int
        let offset: CGFloat
        let count: Int
    }

    let book: SmartBook
    let width: CGFloat
    let height: CGFloat
    /// 切り取る枠の比(幅 ÷ 高さ。`SmartLibraryCoverShape.cropAspect`)。nil なら切らずに枠へ収める。
    /// 切るときは、その比の枠を `width`×`height` に収めた大きさで描く(束は紙のずらし幅を引いた箱なので、箱の比と
    /// 少し違う)。絵を枠いっぱいに合わせ、中央を残す。
    var cropAspect: CGFloat?
    var stack: Stack?
    /// 選択の枠(表紙の絵の実際の大きさに掛ける ―― 枠に掛けると細長い表紙の左右が空く。紙と同じ理由)。
    var isSelected = false
    var isFocused = true
    var savesToDisk = true
    var onImageRetained: (CGImage) -> Void = { _ in }
    @EnvironmentObject private var appearance: AppearanceSettings

    @EnvironmentObject private var thumbnails: FileBrowserThumbnailProvider
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var didFail = false

    private var entry: FileBrowserEntry {
        FileBrowserEntry(
            url: URL(fileURLWithPath: book.id, isDirectory: book.kind == .folder), displayName: book.fileName,
            isDirectory: book.kind == .folder, isPackage: false, isSymbolicLink: false, isVolume: false,
            fileSize: book.fileSize, typeDescription: nil, creationDate: book.creationDate,
            modificationDate: book.modificationDate
        )
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CollectionCoverThumbnail.cornerRadius(forWidth: width), style: .continuous)
        ZStack(alignment: .bottom) {
            if let image {
                // 絵を描く大きさ(紙とバッジをこの大きさに合わせる)。切らないなら絵を枠に収めた大きさ、切るならその比の枠。
                let box = CGSize(width: width, height: height)
                let size = cropAspect.map { Self.fittedSize(aspect: $0, in: box) } ?? Self.fittedSize(of: image, in: box)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: cropAspect == nil ? .fit : .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .overlay { selectionBorder(shape: shape) }
                    .panelOutlinedAccent(in: shape, isEnabled: isSelected)
                    .background(alignment: .bottomLeading) { stackedSheets(shape: shape) }
                    .overlay(alignment: .bottomTrailing) { countBadge }
            } else {
                shape.fill(Color.secondary.opacity(0.15))
                    .panelOutlinedFrame(in: shape)
                    .overlay { selectionBorder(shape: shape) }
                    .background(alignment: .bottomLeading) { stackedSheets(shape: shape) }
                    .overlay(alignment: .bottomTrailing) { countBadge }
                    .overlay {
                        if didFail {
                            Image(systemName: book.kind == .folder ? "folder" : "book.closed")
                                .font(.system(size: width / 4))
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .frame(width: width, height: height, alignment: .bottom)
        // 鍵(更新日時・サイズ・inode)も入れる: 探し直してファイルが差し替わっていたと分かったら、新しい表紙を引き直す。
        // 切るかどうかも入れる(切るときは大きめに引く。`load`)。
        .task(id: "\(book.id)|\(Int(width))|\(cropAspect != nil)|\(thumbnails.revision)|\(book.thumbnailKey.map { "\($0.inode)-\($0.modified)-\($0.size)" } ?? "")") {
            await load()
        }
    }

    /// 枠(`box`)に縦横比を保って収めた大きさ。
    static func fittedSize(of image: CGImage, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        return fittedSize(aspect: CGFloat(image.width) / CGFloat(image.height), in: box)
    }

    /// 比(幅 ÷ 高さ)`aspect` の長方形を、枠(`box`)に収めた大きさ。
    static func fittedSize(aspect: CGFloat, in box: CGSize) -> CGSize {
        guard aspect > 0, box.height > 0 else { return box }
        if aspect > box.width / box.height {
            return CGSize(width: box.width, height: box.width / aspect)
        }
        return CGSize(width: box.height * aspect, height: box.height)
    }

    /// 選択の枠(コレクションの中のカバーと同じ形。すりガラス面の色に溶けないよう、呼ぶ側で反対色の縁も掛ける)。
    @ViewBuilder
    private func selectionBorder(shape: RoundedRectangle) -> some View {
        if isSelected {
            SelectionEmphasisBorder(shape: shape, isFocused: isFocused)
        }
    }

    /// 束の後ろの紙(奥ほど薄く、右上へずらす)。表紙と同じ大きさ(`.background` なので前の面の大きさで描かれる)。
    /// 絵の無い面なので、すりガラス面を文字色で塗っても在りかが分かるよう縁を引く。
    @ViewBuilder
    private func stackedSheets(shape: RoundedRectangle) -> some View {
        if let stack {
            ZStack {
                ForEach((1...max(1, stack.layers)).reversed(), id: \.self) { layer in
                    // 色は環境設定「外観」→「ホーム」→「スマートライブラリ」(既定は明暗に追従するコントロールの地)。
                    shape.fill(appearance.effectiveSmartLibrarySeriesSheet.opacity(layer == stack.layers ? 0.7 : 0.9))
                        .overlay(shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                        .panelOutlinedFrame(in: shape)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                        .offset(x: stack.offset * CGFloat(layer), y: -stack.offset * CGFloat(layer))
                }
            }
        }
    }

    /// 束の冊数バッジ(表紙の右下。コレクションの札の冊数バッジと同じ形。大きさは環境設定「外観」→「ホーム」→
    /// 「スマートライブラリ」の「冊数バッジの大きさ」)。
    @ViewBuilder
    private var countBadge: some View {
        if let stack {
            let size = appearance.smartLibraryBadgeSize
            Text(verbatim: "\(stack.count)")
                .font(.system(size: size.fontSize))
                .monospacedDigit()
                .padding(.horizontal, size.horizontalPadding)
                .padding(.vertical, size.verticalPadding)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: size.borderWidth))
                .foregroundStyle(Color.white)
                .padding(4)
        }
    }

    private func load() async {
        let entry = entry
        guard let kind = BookThumbnailer.kind(
            forName: entry.url.lastPathComponent, isNavigableFolder: entry.isNavigableFolder,
            isPackage: false, isSymbolicLink: false
        ) else {
            didFail = true
            return
        }
        // 切るときは、枠からはみ出して捨てるぶんも見込んで 1.5 倍で引く(2:3 の絵を 1:1 や 3:2 の枠いっぱいに合わせると、
        // 長いほうの辺は枠の長いほうの辺の 1.5 倍になる。3:2 の絵を 2:3 の枠に合わせても同じ)。
        let displaySize = max(width, height) * (cropAspect == nil ? 1 : 1.5)
        let pixelSize = FileBrowserThumbnailProvider.pixelTier(forDisplaySize: displaySize, scale: displayScale)
        // 探したときに記録した鍵で引く(ネットワークの本でもファイルを読みに行かずに、保存してある表紙が出る)。
        let buffer = await thumbnails.thumbnail(for: entry, kind: kind, pixelSize: pixelSize, savesToDisk: savesToDisk,
                                                knownKey: book.thumbnailKey)
        guard !Task.isCancelled else { return }
        guard let made = buffer?.makeImage() else {
            didFail = image == nil
            return
        }
        didFail = false
        image = made
        onImageRetained(made)
    }
}

/// 対象フォルダの欄の受け口(使えないときは付けない ―― 付けたまま断ると、ウインドウ全体の受け口へ回らない)。
private struct SmartFolderDropTarget: ViewModifier {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let refusesDrop: () -> Bool
    let receive: ([URL]) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.fileURLDropTarget(isTargeted: $isTargeted, refusesDrop: refusesDrop, receiveURLs: receive)
        } else {
            content
        }
    }
}

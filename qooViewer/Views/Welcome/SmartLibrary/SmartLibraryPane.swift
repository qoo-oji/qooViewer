import AppKit
import SwiftUI

/// ホームの「スマートライブラリ」(2026-09-21、利用者の指示。StackNest のスマートシェルフが土台)。
///
/// 2 ペイン: **左に絞り込みのすべて**(StackNest では画面の上にあるフィルタ・ブラウザ列と、サイドバーのスマートシェルフの一覧を
/// ここへ集めた)、右に表紙のグリッド。対象の本・メタデータの決め方は `SmartLibraryCatalog` の型コメント、
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
        .onAppear {
            catalog.activate()
            state.update(books: catalog.books, shelves: store.shelves)
        }
        .onDisappear { catalog.deactivate() }
        .onChange(of: catalog.revision) { state.update(books: catalog.books, shelves: store.shelves) }
        .onChange(of: store.shelves) { state.update(books: catalog.books, shelves: store.shelves) }
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

/// 左ペイン: スマートシェルフの一覧 / 対象 / 絞り込み / ブラウザ列。
struct SmartLibrarySidebar: View {
    @ObservedObject var state: SmartLibraryViewState
    let allowsEditing: Bool

    @EnvironmentObject private var store: SmartLibraryStore
    @EnvironmentObject private var catalog: SmartLibraryCatalog
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.locale) private var locale

    /// 編集中のスマートシェルフ(新しく作るときは id の無いもの)。
    @State private var editing: SmartShelfEditorTarget?
    @State private var deleting: SmartShelf?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                shelvesSection
                sourcesSection
                filterSection
                browseSection
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
            "Delete Smart Library?",
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
            SmartSidebarHeader(titleKey: "Smart Libraries") {
                Button {
                    editing = SmartShelfEditorTarget(shelf: SmartShelf(
                        name: "", conditions: SmartShelfConditions(rules: [SmartShelfRule(field: .genre)])), isNew: true)
                } label: {
                    Image(systemName: "plus").panelIconButtonLabel()
                }
                .buttonStyle(.borderless)
                .disabled(!allowsEditing)
                .help("New Smart Library…")
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

    // MARK: 対象

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SmartSidebarHeader(titleKey: "Books to Include") {
                Button {
                    catalog.reload()
                } label: {
                    Image(systemName: "arrow.clockwise").panelIconButtonLabel()
                }
                .buttonStyle(.borderless)
                .help("Look for Books Again")
            }
            Toggle("Books in the libraries", isOn: $store.sources.library)
                .panelOutlinedContent()
            if preferences.fileBrowserFeatureEnabled {
                Toggle("Books in Favorite Locations", isOn: $store.sources.favoriteLocations)
                    .panelOutlinedContent()
            }
            Toggle("Books in these folders", isOn: $store.sources.folders)
                .panelOutlinedContent()
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
                .padding(.leading, 20)
                .panelOutlinedContent()
                .opacity(store.sources.folders ? 1 : 0.5)
            }
            Button {
                addFolder()
            } label: {
                Label("Add Folder…", systemImage: "plus")
            }
            .buttonStyle(.link)
            .padding(.leading, 20)
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
            SmartKindChips(selection: $state.quickFilter.kinds)
            SmartFilterPicker(titleKey: "Reading Status", selection: $state.quickFilter.readState,
                              options: SmartReadState.allCases.map { ($0, $0.titleKey) })
            SmartFilterPicker(titleKey: "Added", selection: $state.quickFilter.addedWithinDays,
                              options: Self.dayOptions)
            SmartFilterPicker(titleKey: "Last Read", selection: $state.quickFilter.readWithinDays,
                              options: Self.dayOptions)
            SmartFilterPicker(titleKey: "Metadata", selection: $state.quickFilter.registered,
                              options: [(true, "Registered"), (false, "Not registered")])
        }
    }

    private static let dayOptions: [(Int, String)] = [
        (1, "Today"), (7, "In the last 7 days"), (30, "In the last 30 days"), (90, "In the last 90 days"),
        (365, "In the last year"),
    ]

    // MARK: ブラウザ列

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SmartSidebarHeader(titleKey: "Browse") { EmptyView() }
            ForEach(0..<SmartLibraryViewState.facetCount, id: \.self) { index in
                SmartFacetColumn(state: state, index: index)
            }
        }
    }
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

/// 種類で絞るチップ(何も選ばなければ全部)。
private struct SmartKindChips: View {
    @Binding var selection: Set<SmartBookKind>
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(SmartBookKind.allCases, id: \.self) { kind in
                let isOn = selection.contains(kind)
                let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
                Button {
                    if isOn { selection.remove(kind) } else { selection.insert(kind) }
                } label: {
                    Text(LocalizedStringKey(kind.titleKey))
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .panelOutlinedContent(isEnabled: !isOn)
                        .foregroundStyle(isOn ? SelectionEmphasis.foreground(isActive: appearsActive) : Color.primary)
                        .background(shape.fill(isOn ? SelectionEmphasis.fill(isActive: appearsActive) : Color.primary.opacity(0.07)))
                        .panelOutlinedAccent(in: shape, isEnabled: isOn)
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
            }
        }
        .help("Show only these kinds of books. With none chosen, every kind is shown")
    }
}

/// 絞り込みの 1 行(見出しと、選んだ値のメニュー)。**Menu の label は Text 1 つだけ**(CLAUDE.md)。
private struct SmartFilterPicker<Value: Hashable>: View {
    let titleKey: LocalizedStringKey
    @Binding var selection: Value?
    let options: [(Value, String)]
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 6) {
            Text(titleKey)
                .font(.callout)
                .panelOutlinedContent()
            Spacer(minLength: 4)
            Menu {
                Button("Any") { selection = nil }
                Divider()
                ForEach(options, id: \.0) { option in
                    Button(LocalizedStringKey(option.1)) { selection = option.0 }
                }
            } label: {
                Text(verbatim: currentTitle)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var currentTitle: String {
        guard let selection, let option = options.first(where: { $0.0 == selection }) else {
            return String(localized: "Any", language: locale)
        }
        return String(localized: String.LocalizationValue(option.1), language: locale)
    }
}

/// ブラウザ列 1 つ(StackNest の上ペインの列)。見出しのメニューで欄を替え、先頭の「すべて」と値(冊数つき)を並べる。
private struct SmartFacetColumn: View {
    @ObservedObject var state: SmartLibraryViewState
    let index: Int
    @Environment(\.locale) private var locale
    @Environment(\.appearsActive) private var appearsActive

    static let height: CGFloat = 150

    var body: some View {
        let field = state.facetFields[index]
        let values = index < state.facetValues.count ? state.facetValues[index] : []
        let selection = state.facetSelections[index]
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                ForEach(SmartFacetField.allCases, id: \.self) { candidate in
                    Button {
                        var fields = state.facetFields
                        // 同じ欄を 2 つの列に置かない(入れ替える)。
                        if let other = fields.firstIndex(of: candidate), other != index { fields[other] = fields[index] }
                        fields[index] = candidate
                        state.facetFields = fields
                    } label: {
                        if candidate == field {
                            Label(LocalizedStringKey(candidate.titleKey), systemImage: "checkmark")
                        } else {
                            Text(LocalizedStringKey(candidate.titleKey))
                        }
                    }
                }
            } label: {
                Text(verbatim: String(localized: String.LocalizationValue(field.titleKey), language: locale))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.callout.weight(.medium))
            .panelOutlinedContent()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    row(title: String(format: String(localized: "All (%lld)", language: locale), values.count),
                        count: nil, isSelected: selection == nil) { state.selectFacet(nil, at: index) }
                    ForEach(values, id: \.value) { entry in
                        row(title: label(for: entry.value, field: field), count: entry.count,
                            isSelected: selection == entry.value) { state.selectFacet(entry.value, at: index) }
                    }
                }
            }
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    private func label(for value: SmartFacetValue, field: SmartFacetField) -> String {
        switch value {
        case .empty: return String(localized: "(empty)", language: locale)
        case .value(let v):
            if field == .kind, let kind = SmartBookKind(rawValue: v) {
                return String(localized: String.LocalizationValue(kind.titleKey), language: locale)
            }
            return v
        }
    }

    /// 1 行。地は不透明なリストの地(textBackgroundColor)なので、輪郭は掛けない。
    private func row(title: String, count: Int?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let count {
                Text(verbatim: "\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? AnyShapeStyle(SelectionEmphasis.foreground(isActive: appearsActive)) : AnyShapeStyle(.secondary))
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(isSelected ? SelectionEmphasis.foreground(isActive: appearsActive) : Color.primary)
        .background(isSelected ? SelectionEmphasis.fill(isActive: appearsActive) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(title)
    }
}

// MARK: - 右ペイン

/// 右: 見出し(棚の名前・検索・並べ替え・大きさ)と表紙のグリッド。
struct SmartLibraryContent: View {
    @ObservedObject var home: WelcomeLibraryState
    @ObservedObject var state: SmartLibraryViewState
    let allowsEditing: Bool

    @EnvironmentObject private var catalog: SmartLibraryCatalog
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.revealInFileBrowser) private var revealInFileBrowser
    @Environment(\.locale) private var locale
    @FocusState private var isSearchFocused: Bool

    @State private var missingBook: String?
    @State private var metadataTarget: SmartMetadataTarget?

    private static let spacing: CGFloat = 16
    private static let gridPadding: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            WelcomeSeparator(axis: .horizontal)
            if catalog.isLoading, catalog.books.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.visibleBooks.isEmpty {
                emptyMessage
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
    }

    private var header: some View {
        WelcomePaneHeaderLayout {
            HStack(spacing: 8) {
                Text(verbatim: state.selectedShelf?.name ?? String(localized: "All Books", language: locale))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
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
                sortMenu
                Slider(value: $state.coverSize, in: SmartLibraryViewState.coverSizeRange)
                    .frame(width: 110)
                    .panelControlWell()
                    .help("Cover Size")
            }
        }
    }

    private var countText: String {
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
                 ? "Books in your libraries, in Favorite Locations and in the folders you add on the left appear here."
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

    private var grid: some View {
        GeometryReader { proxy in
            let columns = WelcomeGridColumns(
                availableWidth: proxy.size.width, itemWidth: state.coverSize,
                spacing: Self.spacing, padding: Self.gridPadding
            )
            ScrollView {
                LazyVGrid(columns: columns.gridItems(alignment: .top), spacing: Self.spacing) {
                    ForEach(state.visibleBooks) { book in
                        SmartBookCell(book: book, width: state.coverSize)
                            .onTapGesture { open(book) }
                            .contextMenu { contextMenu(for: book) }
                    }
                }
                .frame(width: columns.contentWidth)
                .frame(maxWidth: .infinity)
                .padding(Self.gridPadding)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for book: SmartBook) -> some View {
        BookOpenContextMenuItems(
            onOpen: { open(book) },
            onOpenIn: { destination in
                guard let url = resolvedURL(for: book) else { return }
                BookWindowOpener.open(
                    BookOpenRequest(url), to: destination, from: appState,
                    launchCoordinator: launchCoordinator, openWindow: openWindow
                )
            }
        )
        Divider()
        Button("Show in Finder") {
            guard let url = resolvedURL(for: book) else { return }
            FinderReveal.reveal(url)
        }
        if revealInFileBrowser.isFeatureEnabled {
            Button("Show in File Browser") {
                guard let url = resolvedURL(for: book) else { return }
                revealInFileBrowser(url)
            }
        }
        if allowsEditing {
            Divider()
            Button("Edit Metadata…") {
                guard let url = resolvedURL(for: book) else { return }
                metadataTarget = SmartMetadataTarget(entry: FileBrowserEntry(
                    url: url, displayName: book.fileName, isDirectory: book.kind == .folder, isPackage: false,
                    isSymbolicLink: false, isVolume: false, fileSize: book.fileSize, typeDescription: nil,
                    creationDate: book.creationDate, modificationDate: book.modificationDate))
            }
        }
    }

    /// 本の実体の URL。ライブラリの本はコレクションのブックマークから(権限もそこにある)、フォルダの本はパスそのもの
    /// (FolderAccessStore が許可した場所の中)。見つからなければ「本が見つかりません」。
    private func resolvedURL(for book: SmartBook) -> URL? {
        if let itemID = book.collectionItemID, let item = collectionStore.item(withID: itemID),
           let url = collectionStore.resolvedExistingURL(for: item) {
            return url
        }
        let url = URL(fileURLWithPath: book.id, isDirectory: book.kind == .folder)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        missingBook = book.id
        return nil
    }

    private func open(_ book: SmartBook) {
        guard let url = resolvedURL(for: book) else { return }
        appState.open(url: url)
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

    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var coverExtractor: CollectionCoverExtractor
    @EnvironmentObject private var layoutStore: LayoutStore

    /// 表紙の枠の比(2:3)。コレクションの表紙もこの枠の中に収める(ライブラリごとの比の違いで行の高さが揃わないため)。
    static let heightRatio: CGFloat = 1.5

    var body: some View {
        VStack(spacing: 4) {
            cover
                .frame(width: width, height: width * Self.heightRatio, alignment: .bottom)
            VStack(spacing: 1) {
                Text(verbatim: book.displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let author = book.metadata.authors.first {
                    Text(verbatim: author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width)
            .panelOutlinedContent()
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

    @ViewBuilder
    private var cover: some View {
        if let itemID = book.collectionItemID, let item = collectionStore.item(withID: itemID),
           let library = item.collection?.library {
            CollectionCoverThumbnail(
                item: item, coverStore: collectionStore.coverStore, aspectRatio: library.coverAspectRatio,
                anchor: layoutStore.bookLayoutSettings(forBookID: item.bookID)?.coverCropAnchor ?? library.coverCropAnchor,
                displayWidth: min(width, width * Self.heightRatio * library.coverAspectRatio.value),
                exists: collectionStore.cachedFileExists(for: item),
                isExtracting: coverExtractor.inFlightItemIDs.contains(item.id),
                coverRevision: collectionStore.coverRevision(for: item)
            )
        } else {
            SmartBookThumbnail(book: book, width: width, height: width * Self.heightRatio)
        }
    }
}

/// ライブラリに無い本の表紙(ファイルブラウザのアイコン表示と同じ提供役から引く。FileBrowserCoverArea と同じ)。
private struct SmartBookThumbnail: View {
    let book: SmartBook
    let width: CGFloat
    let height: CGFloat

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
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            } else {
                shape.fill(Color.secondary.opacity(0.15))
                    .panelOutlinedFrame(in: shape)
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
        .task(id: "\(book.id)|\(Int(width))|\(thumbnails.revision)") { await load() }
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
        let pixelSize = FileBrowserThumbnailProvider.pixelTier(forDisplaySize: max(width, height), scale: displayScale)
        let buffer = await thumbnails.thumbnail(for: entry, kind: kind, pixelSize: pixelSize)
        guard !Task.isCancelled else { return }
        guard let made = buffer?.makeImage() else {
            didFail = image == nil
            return
        }
        didFail = false
        image = made
    }
}

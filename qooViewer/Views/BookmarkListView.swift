import SwiftUI
import AppKit

/// 左ペイン(4.1節)の絞り込みドロップダウン。
enum EditorBookFilter: String, CaseIterable, Identifiable {
    case all
    case hasBookmarks
    case hasLayout

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .hasBookmarks: return "Has Bookmarks"
        case .hasLayout: return "Has Layout Info"
        }
    }
}

/// 右ペイン(4.2節)の絞り込みドロップダウン。
enum EditorPageFilter: String, CaseIterable, Identifiable {
    case all
    case hasBookmarks

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .hasBookmarks: return "Has Bookmarks"
        }
    }
}

/// 左ペインの1行分。ブックマーク・レイアウトいずれか(または両方)のデータを持つ本の和集合。
/// 以前のBookmarkBookGroupは「ブックマークを持つ本」だけを表していたが、レイアウト情報のみ
/// 持つ本(ブックマークは1件も無い本)も一覧に含める必要があるため、bookmarkStore.groupsと
/// layoutStore.layoutBookIDsをマージしてこの行を組み立てる(BookmarkEditorView.mergedRows参照)。
private struct EditorBookRow: Identifiable {
    let bookID: String
    let bookmarkCount: Int
    let hasLayoutData: Bool
    /// 並び替え基準「追加日時」に使う代表日時。レイアウトのみの本には「追加日時」に相当する
    /// 概念が無いため、BookLayoutSettings.updatedAtで代用する(created/updated the same value)。
    let earliestDate: Date
    /// 並び替え基準「更新日時」に使う代表日時。
    let latestDate: Date

    var id: String { bookID }

    var displayName: String {
        URL(fileURLWithPath: bookID).deletingPathExtension().lastPathComponent
    }
}

/// 「ブックマーク・レイアウトの編集」ウインドウ(独立ウインドウ。Window(id: "editBookmarks")、
/// QooViewerApp.swift参照)の実際のコンテンツ。
///
/// 以前は「ブックマークの編集」専用だったが、設計コンセプト4節により、EPUB以外の全形式に対する
/// ページレイアウト制御(BookLayoutSettings/PageLayoutOverride)の編集も同じウインドウで
/// 行えるように拡張した。左ペイン(本の一覧)はブックマーク・レイアウトいずれかのデータを持つ
/// 本の和集合を表示し、右ペイン(選択中の本の詳細)は「ページ一覧」ベースに作り直し、
/// サムネイル・レイアウト状態・ブックマークを1行にまとめて表示する(BookmarkDetailPane参照)。
///
/// 呼び出し元(「ブックマークの編集」/「レイアウトの編集」のどちらのメニュー項目から開いたか)に
/// よって初期フィルタを変える(4.5節)。この値はlaunchCoordinator.pendingEditorInitialFocus
/// 経由で伝わる(詳細はLaunchCoordinator.swiftのコメント参照)。
struct BookmarkEditorView: View {
    @ObservedObject var bookmarkStore: BookmarkStore
    @ObservedObject var layoutStore: LayoutStore
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @EnvironmentObject private var preferences: AppPreferences

    @State private var selectedBookID: String?
    @State private var renamingBookmark: Bookmark?
    @State private var renameText = ""

    @State private var bookFilter: EditorBookFilter = .all
    @State private var searchText = ""

    /// 4.4節「一括リネーム」から開く一括リネームウインドウの対象bookID。
    @State private var pendingBulkRenameBookID: String?
    /// 4.4節「ブックマークを全削除」の確認ダイアログの対象bookID。
    @State private var pendingDeleteBookmarksBookID: String?
    /// 4.4節「レイアウトを全削除」の確認ダイアログの対象bookID。
    @State private var pendingDeleteLayoutBookID: String?

    @Environment(\.openWindow) private var openWindow

    /// 左ペイン(サイドバー)の幅。ウインドウを開いた時点で登録されている本の名前の長さに応じて
    /// onAppearで一度だけ計算する(SidebarWidthEstimator参照)。既定値220は、名前が無い/短い場合の
    /// フォールバック。
    @State private var sidebarWidth: CGFloat = 220
    @State private var hasComputedSidebarWidth = false

    /// applyInitialFocusが実際に呼ばれた回数(呼ばれるたびに1増える)。
    ///
    /// ユーザー報告: お気に入りメニューから「ブックマークの編集」を呼び出すと、左ペインは
    /// 「ブックマークがある」で絞り込まれるのに右ペインが「すべて」のままだった(先に一度
    /// initialPageFilter: .hasBookmarksを渡すよう修正したが、それでも再現した)。
    ///
    /// 原因: effectiveSelectedBookIDが「今開いている本」への自動フォールバックを持つため、
    /// このウインドウの最初の描画の時点(bookFilterがまだ既定値の.allのまま、onAppearの
    /// applyInitialFocusがまだ実行される前)で、detail:のBookmarkDetailPane(.id(bookID))が
    /// 既に一度作られてしまう。SwiftUIの@Stateは同じidを持つビューに対しては最初の1回しか
    /// initialValueを反映しないため、その直後にonAppearがbookFilterを.hasBookmarksへ書き換えて
    /// 新しいinitialPageFilterを渡し直しても、既に生成済みのBookmarkDetailPane自身の
    /// pageFilter(@State)は変わらない(idがbookIDのまま変化していないため、SwiftUIは
    /// 同一ビューとみなし作り直さない)。
    ///
    /// 対策として、.id()にこのgenerationも含めることで、applyInitialFocusが呼ばれるたびに
    /// (呼び出し元メニュー種別に関わらず、確実に)BookmarkDetailPaneを作り直させ、
    /// 常に最新のinitialPageFilterでpageFilterを初期化させる。selectedBookID(左ペインの
    /// 選択自体)には影響しないため、表示中の本が意図せず切り替わることはない。
    @State private var initialFocusGeneration = 0

    /// bookmarkStore.groups(ブックマークを持つ本)とlayoutStore.layoutBookIDs(レイアウト情報を
    /// 持つ本)をbookIDでマージした一覧。どちらか一方にしか無い本もここに含まれる。
    ///
    /// 加えて、今読んでいる本(launchCoordinator.activeBookAppState)がブックマーク・
    /// レイアウトのどちらも1件も持たない場合でも、その本自体はここに含める。以前は
    /// ブックマーク・レイアウトいずれかのデータを持つ本だけがこの一覧に載る仕組みだったため、
    /// 「今開いている本にまだ何も設定していない状態で編集ウインドウを呼び出す」と、その本が
    /// 一覧にそもそも現れず(選ぶことも編集することもできず)、押した意味が無いという不具合が
    /// あった(ユーザー要望)。
    private var mergedRows: [EditorBookRow] {
        var byID: [String: EditorBookRow] = [:]
        for group in bookmarkStore.groups {
            byID[group.bookID] = EditorBookRow(
                bookID: group.bookID,
                bookmarkCount: group.count,
                hasLayoutData: layoutStore.layoutBookIDs.contains(group.bookID),
                earliestDate: group.earliestCreatedAt,
                latestDate: group.latestUpdatedAt
            )
        }
        for bookID in layoutStore.layoutBookIDs where byID[bookID] == nil {
            let updatedAt = layoutStore.bookLayoutSettings(forBookID: bookID)?.updatedAt ?? Date()
            byID[bookID] = EditorBookRow(
                bookID: bookID,
                bookmarkCount: 0,
                hasLayoutData: true,
                earliestDate: updatedAt,
                latestDate: updatedAt
            )
        }
        if let activeBook = launchCoordinator.activeBookAppState?.currentBook, byID[activeBook.id] == nil {
            let now = Date()
            byID[activeBook.id] = EditorBookRow(
                bookID: activeBook.id,
                bookmarkCount: 0,
                hasLayoutData: false,
                earliestDate: now,
                latestDate: now
            )
        }
        return Array(byID.values)
    }

    /// bookFilter・searchTextを適用し、bookmarkStore.bookSortOptionに従って並べた最終的な行一覧。
    private var filteredSortedRows: [EditorBookRow] {
        var rows = mergedRows
        switch bookFilter {
        case .all:
            break
        case .hasBookmarks:
            rows = rows.filter { $0.bookmarkCount > 0 }
        case .hasLayout:
            rows = rows.filter { $0.hasLayoutData }
        }
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            rows = rows.filter { $0.displayName.localizedCaseInsensitiveContains(trimmedSearch) }
        }
        switch bookmarkStore.bookSortOption {
        case .nameAscending:
            rows.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .nameDescending:
            rows.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedDescending }
        case .dateAddedAscending:
            rows.sort { $0.earliestDate < $1.earliestDate }
        case .dateAddedDescending:
            rows.sort { $0.earliestDate > $1.earliestDate }
        case .dateUpdatedAscending:
            rows.sort { $0.latestDate < $1.latestDate }
        case .dateUpdatedDescending:
            rows.sort { $0.latestDate > $1.latestDate }
        }
        return rows
    }

    /// 実際に使う選択中のbookID。selectedBookIDが未選択(nil)、またはフィルタ/削除で一覧から
    /// 消えてしまった場合は、以下の優先順でフォールバックする。
    /// 1. 今読んでいる本(launchCoordinator.activeBookAppState)が一覧にあれば、それを自動選択する。
    /// 2. 無ければ、一覧の先頭の本(現在の並び順で先頭)。
    /// rowsは呼び出し側(body)が既に計算済みのfilteredSortedRowsをそのまま渡す。
    /// 以前はこのメソッドが計算プロパティ(filteredSortedRowsを自前で呼び直す)だったため、
    /// ForEachの各行のlistRowBackground判定のたびにfilteredSortedRows(内部でmergedRowsの
    /// マージ・フィルタ・ソートを毎回やり直す)が再評価され、行数のぶんだけ計算量が膨らんでいた
    /// (体感の一覧描画のもたつきにつながる)。呼び出し側でrowsを1回だけ計算して渡すことで、
    /// bodyの評価1回につきこの判定自体もO(1)になる(結果は従来と同一)。
    private func effectiveSelectedBookID(in rows: [EditorBookRow]) -> String? {
        if let selectedBookID, rows.contains(where: { $0.bookID == selectedBookID }) {
            return selectedBookID
        }
        if let activeBookID = launchCoordinator.activeBookAppState?.currentBook?.id,
           rows.contains(where: { $0.bookID == activeBookID }) {
            return activeBookID
        }
        return rows.first?.bookID
    }

    var body: some View {
        if mergedRows.isEmpty {
            // ブックマーク・レイアウトいずれのデータも1件も無い場合の案内画面。
            ContentUnavailableView {
                Label("No Bookmarks Yet", systemImage: "bookmark.slash")
            } description: {
                Text("Bookmarks you add to any book will appear here.")
            } actions: {
                Button("Add Current Page to Bookmarks") {
                    launchCoordinator.activeBookAppState?.addBookmarkAction?()
                }
                .disabled(launchCoordinator.activeBookAppState?.currentBook == nil)
            }
            .frame(minWidth: 640, minHeight: 420)
        } else {
            // filteredSortedRows/effectiveSelectedBookIDはbodyの評価ごとに1回だけ計算し、
            // ForEachの各行やdetail:側で使い回す(繰り返し呼び直すとO(行数)倍の計算になるため)。
            let rows = filteredSortedRows
            let selectedID = effectiveSelectedBookID(in: rows)
            NavigationSplitView {
                List {
                    ForEach(rows) { row in
                        let isOpen = launchCoordinator.openAppState(forBookID: row.bookID) != nil
                        HStack {
                            Image(systemName: isOpen ? "book.fill" : "book.closed")
                                .foregroundStyle(isOpen ? Color.accentColor : Color.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(row.displayName)
                                        .fontWeight(isOpen ? .semibold : .regular)
                                    FormatBadgeView(bookID: row.bookID)
                                    if isOpen {
                                        Text("Now Reading")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.15))
                                            .foregroundStyle(Color.accentColor)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            Spacer()
                            if row.bookmarkCount > 0 {
                                HStack(spacing: 2) {
                                    Image(systemName: "bookmark.fill")
                                        .font(.caption2)
                                    Text("\(row.bookmarkCount)")
                                        .font(.caption)
                                }
                                .foregroundStyle(.secondary)
                            }
                            if row.hasLayoutData {
                                Image(systemName: "rectangle.split.2x1")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("Has Layout Info")
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedBookID = row.bookID
                        }
                        .help(row.displayName)
                        .listRowBackground(
                            selectedID == row.bookID
                                ? Color.accentColor.opacity(0.15) : Color.clear
                        )
                        // 4.4節: 左ペインの本を右クリックしたメニューにも、下部ボタンと同じ3項目を
                        // 追加する(その本を選択した状態で実行したのと同じ扱い。現在の選択状態を
                        // 変えずに、行ったbookIDへ直接作用させる)。
                        .contextMenu {
                            Button("Bulk Rename Bookmarks…") {
                                pendingBulkRenameBookID = row.bookID
                            }
                            .disabled(row.bookmarkCount == 0)
                            Button("Delete All Bookmarks…", role: .destructive) {
                                pendingDeleteBookmarksBookID = row.bookID
                            }
                            .disabled(row.bookmarkCount == 0)
                            Button("Delete All Layout Info…", role: .destructive) {
                                pendingDeleteLayoutBookID = row.bookID
                            }
                            .disabled(!row.hasLayoutData)
                        }
                    }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 6) {
                        HStack {
                            Picker(selection: $bookFilter) {
                                ForEach(EditorBookFilter.allCases) { filter in
                                    Text(filter.titleKey).tag(filter)
                                }
                            } label: {
                                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                            }
                            .pickerStyle(.menu)
                            .fixedSize()

                            Spacer()

                            Picker(selection: $bookmarkStore.bookSortOption) {
                                ForEach(FavoritesSortOption.allCases) { option in
                                    Label {
                                        Text(option.titleKey)
                                    } icon: {
                                        Image(systemName: option.systemImage)
                                    }
                                    .tag(option)
                                }
                            } label: {
                                Label("Sort By", systemImage: "arrow.up.arrow.down")
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                        }

                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search", text: $searchText)
                                .textFieldStyle(.plain)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
                .navigationTitle("Bookmarks & Layout")
                .navigationSplitViewColumnWidth(min: 220, ideal: sidebarWidth, max: 560)
                .onAppear {
                    guard !hasComputedSidebarWidth else { return }
                    hasComputedSidebarWidth = true
                    sidebarWidth = SidebarWidthEstimator.idealWidth(
                        forNames: mergedRows.map(\.displayName)
                    )
                    applyInitialFocus(launchCoordinator.pendingEditorInitialFocus)
                }
                .onChange(of: launchCoordinator.pendingEditorInitialFocus) { _, newValue in
                    applyInitialFocus(newValue)
                }
            } detail: {
                if let bookID = selectedID {
                    BookmarkDetailPane(
                        bookID: bookID,
                        bookmarkStore: bookmarkStore,
                        layoutStore: layoutStore,
                        preferences: preferences,
                        // 左ペインの絞り込み(bookFilter)と一致させる(applyInitialFocus参照。
                        // ユーザー報告: お気に入りメニューから「ブックマークの編集」を呼び出すと
                        // 左ペインは「ブックマークがある」で絞り込まれるのに右ペインが「すべて」の
                        // ままだった)。右ペインには「レイアウトがある」に相当する絞り込みが
                        // 存在しない(EditorPageFilter参照)ため、bookFilter == .hasLayoutの
                        // 場合はそのまま.allにする。
                        initialPageFilter: bookFilter == .hasBookmarks ? .hasBookmarks : .all,
                        renamingBookmark: $renamingBookmark,
                        renameText: $renameText,
                        pendingBulkRenameBookID: $pendingBulkRenameBookID,
                        pendingDeleteBookmarksBookID: $pendingDeleteBookmarksBookID,
                        pendingDeleteLayoutBookID: $pendingDeleteLayoutBookID
                    )
                    // bookIDだけでなくinitialFocusGenerationも識別子に含める理由は
                    // initialFocusGenerationのコメント参照(右ペインのpageFilter初期値が
                    // 反映されない不具合の対策)。
                    .id("\(bookID)#\(initialFocusGeneration)")
                } else {
                    ContentUnavailableView(
                        "Select a Book",
                        systemImage: "book",
                        description: Text("Choose a book on the left to see its bookmarks.")
                    )
                }
            }
            .frame(minWidth: max(640, sidebarWidth + 400), minHeight: 420)
            .alert(
                "Rename Bookmark",
                isPresented: Binding(
                    get: { renamingBookmark != nil },
                    set: { isPresented in if !isPresented { renamingBookmark = nil } }
                )
            ) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let bookmark = renamingBookmark {
                        bookmarkStore.rename(bookmark, to: renameText)
                    }
                    renamingBookmark = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingBookmark = nil
                }
            }
            // 4.4節「ブックマークを全削除」の確認。
            .alert(
                "Delete All Bookmarks?",
                isPresented: Binding(
                    get: { pendingDeleteBookmarksBookID != nil },
                    set: { isPresented in if !isPresented { pendingDeleteBookmarksBookID = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { pendingDeleteBookmarksBookID = nil }
                Button("Delete", role: .destructive) {
                    if let bookID = pendingDeleteBookmarksBookID {
                        bookmarkStore.deleteAllBookmarks(forBookID: bookID)
                    }
                    pendingDeleteBookmarksBookID = nil
                    // 全削除の結果、左ペインの絞り込みが「ブックマークあり」「レイアウトあり」の
                    // いずれかのままだと、編集中だった本が一覧から消えて選択・編集できなくなる
                    // ことがある(ユーザー要望)。「すべて」に戻すことで常に編集中の本が
                    // 見え続けるようにする。
                    bookFilter = .all
                }
            } message: {
                Text("This permanently deletes every bookmark in this book. This cannot be undone.")
            }
            // 4.4節「レイアウトを全削除」の確認。
            .alert(
                "Delete All Layout Info?",
                isPresented: Binding(
                    get: { pendingDeleteLayoutBookID != nil },
                    set: { isPresented in if !isPresented { pendingDeleteLayoutBookID = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { pendingDeleteLayoutBookID = nil }
                Button("Delete", role: .destructive) {
                    if let bookID = pendingDeleteLayoutBookID {
                        layoutStore.discardLayoutData(forBookID: bookID)
                    }
                    pendingDeleteLayoutBookID = nil
                    // 上のブックマーク全削除と同じ理由(ユーザー要望)。
                    bookFilter = .all
                }
            } message: {
                Text("This permanently deletes every layout setting (reading direction, page order, single/spread page settings) in this book. This cannot be undone.")
            }
            // 4.4節「一括リネーム」。5節の一括リネームウインドウを開く。
            .onChange(of: pendingBulkRenameBookID) { _, newValue in
                guard let bookID = newValue else { return }
                launchCoordinator.pendingBulkRenameBookID = bookID
                openWindow(id: "bulkRenameBookmarks")
                pendingBulkRenameBookID = nil
            }
        }
    }

    /// 呼び出し元(「ブックマークの編集」/「レイアウトの編集」)に応じた初期フィルタを適用する
    /// (4.5節)。
    ///
    /// ただし、今開いている本(あれば)がブックマーク・レイアウトのどちらも1件も持たない場合は、
    /// どちらのメニュー項目から呼ばれたかに関わらず絞り込みを「すべて」にする。「hasBookmarks」
    /// 「hasLayout」のどちらの絞り込みも、まだ何も設定していないその本を一覧から除外して
    /// しまい(mergedRowsには含まれていても表示上絞り込まれてしまい)、その本を選ぶことも
    /// 編集することもできなくなってしまうため(ユーザー要望: ブックマークもレイアウトも
    /// 未設定の本を開いている状態で編集ウインドウを呼び出した場合、その本を編集できる状態にする)。
    ///
    /// ここで設定したbookFilterは、BookmarkDetailPane生成時にinitialPageFilterとしてそのまま
    /// 渡され、右ペインの絞り込みにも反映される(bookFilter == .hasBookmarksの場合のみ。
    /// .hasLayoutに相当する右ペインの絞り込みは存在しないため.allのまま。ユーザー報告:
    /// お気に入りメニューから「ブックマークの編集」を呼び出すと、左ペインは「ブックマークが
    /// ある」で絞り込まれるのに右ペインが「すべて」のままだった)。
    private func applyInitialFocus(_ focus: EditorInitialFocus?) {
        // このメソッドが呼ばれるたびに必ずインクリメントする(bookFilterの値が結果的に
        // 変わらない場合も含む)。detail:側の.id()にこの値を含めることで、呼び出しのたびに
        // BookmarkDetailPaneを確実に作り直させ、右ペインのpageFilter(@State)を
        // 新しいinitialPageFilterで初期化し直させるため(initialFocusGenerationのコメント参照)。
        initialFocusGeneration += 1
        if let activeBookID = launchCoordinator.activeBookAppState?.currentBook?.id {
            let hasBookmarks = !bookmarkStore.bookmarks(forBookID: activeBookID).isEmpty
            let hasLayout = layoutStore.layoutBookIDs.contains(activeBookID)
            // 呼び出し元のフォーカス種別ごとの絞り込みをそのまま適用すると、今開いている本が
            // その種類のデータを1件も持たない場合に一覧から除外され、選ぶことも編集することも
            // できなくなってしまう(ユーザー要望: レイアウトの無い本を開いている状態で
            // 「レイアウトの編集」を呼び出しても、その本を編集できる状態にする。以前は
            // 「ブックマーク・レイアウトどちらも無い場合だけ」を見ていたため、例えば
            // ブックマークはあるがレイアウトが無い本で「レイアウトの編集」を呼び出すケースを
            // 見逃していた)。
            let wouldHideActiveBook: Bool
            switch focus {
            case .bookmarks: wouldHideActiveBook = !hasBookmarks
            case .layout: wouldHideActiveBook = !hasLayout
            case nil: wouldHideActiveBook = !hasBookmarks && !hasLayout
            }
            if wouldHideActiveBook {
                bookFilter = .all
                return
            }
        }
        switch focus {
        case .bookmarks:
            bookFilter = .hasBookmarks
        case .layout:
            bookFilter = .hasLayout
        case nil:
            break
        }
    }
}

/// 右ペイン(ページ一覧)の各列の幅。ユーザー要望により、ドラッグハンドル列を除く4列
/// (ページ・サムネイル・レイアウト・ブックマーク)に「スクロールしないタイトル行」を追加し、
/// 各列の間に区切り線を表示し、その区切り線をドラッグして幅を変えられるようにした。
///
/// ブックマーク列は元から.frame(maxWidth: .infinity)で残り幅いっぱいに広がる設計のため、
/// 幅を個別に持たせていない(常に「他の3列を引いた残り」になる)。この構造体自体は
/// BookmarkDetailPane.columnWidths(@State)として1つだけ保持し、ヘッダー行(columnHeaderRow)と
/// 各行(PageRowView)の両方へBindingとして配って共有する(どちらか一方でドラッグして
/// 変更すれば、もう一方にも即座に反映される)。
private struct PageListColumnWidths {
    var pageNumber: CGFloat = 32
    var thumbnail: CGFloat = 44
    var layout: CGFloat = 140

    /// サムネイル列の高さ。幅(thumbnail)がドラッグで変わっても、元の縦横比(44×60)を
    /// 保ったまま拡大・縮小されるようにする。
    var thumbnailHeight: CGFloat { thumbnail * 60 / 44 }
}

/// 区切り線をドラッグして、隣り合う列の幅(width)を変更するためのハンドル
/// (ユーザー要望: 各列の幅を可変にしたい)。列ヘッダー行(columnHeaderRow)でだけ使い、
/// 各行(PageRowView)側の区切り線はドラッグ操作を持たない見た目だけのColumnDividerLine()にしている
/// (行を選択するタップ・並べ替えのドラッグなど、既にこの行には複数のジェスチャーが
/// 綿密に調整された形で共存しており、そこにさらにドラッグ操作を増やすとジェスチャー同士が
/// 干渉する余地が生まれるため。列幅の変更操作自体は、Finderのリスト表示など一般的な
/// macOSアプリと同じく、ヘッダー行からだけ行える形に統一した)。
///
/// DragGestureのtranslationはジェスチャー開始位置からの累積値であり、.onChangedのたびに
/// 「前回からの差分」ではなく「開始位置からの絶対量」が渡される。そのため、ドラッグ開始時点の
/// widthをwidthAtDragStartに保持しておき、そこへ都度のtranslationを足す形で計算する
/// (開始時点の値を保持せずwidthへ直接足し込むと、1フレームごとに実際のドラッグ量より
/// 大きく反映されてしまう)。
/// 列の区切り線の「見た目」だけを描画する最小のView。ResizableColumnDivider(ヘッダー行、
/// ドラッグで幅変更可能)と、PageRowView側の各行に表示する区切り線(見た目だけ、ドラッグ不可)の
/// 両方から、全く同じインスタンスを使う。
///
/// バグ修正: 以前はヘッダー行がこのRectangle、各行はSwiftUI標準のDivider()という別々の
/// ビュー種別を混在させていた。標準のDivider()は内部的に余白を持つなど、見た目の1pt線の
/// 実際の位置がRectangle(width: 1)と厳密には一致しないことがあり、ヘッダー行と各行とで
/// 区切り線の位置が数ピクセルずれて見えていた(ユーザー報告)。両方でこの同じViewを使うことで、
/// 描画のされ方自体を完全に一致させる。
/// タイトル行(List外)/各行(List内)、双方の区切り線が実際に描画されたx座標を集める
/// PreferenceKey。"header:0"〜"header:2"/"row:0"〜"row:2"のキーで区別する
/// (0=ページ/サムネイル境界、1=サムネイル/レイアウト境界、2=レイアウト/ブックマーク境界。
/// BookmarkDetailPane.columnDividerCorrections参照)。
///
/// 独自の名前付き座標空間(.coordinateSpace(name:))ではなく.globalを使っている
/// (バグ修正: List(NSTableView backed)の内側と外側という、SwiftUI-AppKit間の描画境界を
/// またぐ位置合わせでは、独自の名前付き座標空間がNSScrollViewの内部変換を正しく反映しない
/// ことがあり、実測に基づく補正のはずが効いていなかった。.globalは画面上の実際の描画位置を
/// 表す座標空間で、Listの内部実装に依存しないため、より確実に機能する)。
private struct ColumnDividerXPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct ColumnDividerLine: View {
    /// 非nilの場合、このViewが実際に描画されたx座標をColumnDividerXPreferenceKey経由で
    /// 報告する(BookmarkDetailPane.measuredDividerXs参照)。
    var measurementKey: String?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: ResizableColumnDivider.height)
            .background(
                Group {
                    if let measurementKey {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ColumnDividerXPreferenceKey.self,
                                value: [measurementKey: proxy.frame(in: .global).midX]
                            )
                        }
                    }
                }
            )
    }
}

private struct ResizableColumnDivider: View {
    @Binding var width: CGFloat
    var minWidth: CGFloat = 28
    var maxWidth: CGFloat = 400
    /// タイトル行側の実測位置報告用("header:0"など。ColumnDividerLine.measurementKey参照)。
    var measurementKey: String?

    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        // バグ修正(区切り線が右に行くほどヘッダー行だけずれていく件、ユーザー報告):
        // 以前はColumnDividerLine(見た目の1pt線)と、掴みやすくするための8pt幅の
        // Color.clearをZStackで重ねていた。ZStackは「子のうち最も大きいサイズ」を自分自身の
        // レイアウトサイズとして親のHStackへ報告するため、見た目は1ptのつもりでも、実際には
        // HStack上で8pt分の幅を占めてしまっていた。ヘッダー行はこのResizableColumnDividerを
        // 3箇所(ページ/サムネイル/レイアウトそれぞれの右側)で使うのに対し、各行(PageRowView)
        // 側は同じ3箇所とも1pt固定のColumnDividerLineをそのまま使っているため、1箇所につき
        // 約7pt(8pt-1pt)、ヘッダー行の方が後続の列を右へ押し出してしまい、しかもそれが
        // 3箇所分累積するため、右へ行くほど(特にレイアウト/ブックマーク間で最大に)ずれて
        // 見えていた。
        //
        // ここでは「レイアウト上の幅」をColumnDividerLine自身(1pt)だけに限定し、掴みやすくする
        // ための広い判定領域は.overlayとして重ねる(overlayの内容は親のレイアウトサイズ計算に
        // 影響しない)ことで、見た目の1pt線とレイアウト上の幅を完全に一致させる。
        ColumnDividerLine(measurementKey: measurementKey)
            .overlay(
                // 実際に掴める判定領域は、見た目の線(1pt)より広めに取っておく
                // (細い線そのものを正確に掴むのは難しいため)。
                Color.clear
                    .frame(width: 8, height: Self.height)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if widthAtDragStart == nil {
                                    widthAtDragStart = width
                                }
                                let proposed = (widthAtDragStart ?? width) + value.translation.width
                                width = min(max(proposed, minWidth), maxWidth)
                            }
                            .onEnded { _ in
                                widthAtDragStart = nil
                            }
                    )
            )
    }

    /// columnHeaderRowの高さ(固定値)に合わせる。columnHeaderRow側の.frame(height:)と
    /// 同じ値を共有する。
    static let height: CGFloat = 20
}

/// 選択中の本1冊分のページ一覧(右ペイン、4.2節)。
///
/// 以前は「ブックマーク一覧」だけを表示するフラットなListだったが、レイアウト編集を統合するため
/// 「ページ一覧」ベースに作り直した。各行はサムネイル・レイアウト・ブックマークの3列を持つ
/// (行内にブックマークが無いページも含め、本の全ページを常に表示する)。
///
/// ページの読み込み(BookLoader経由)・並べ替え・レイアウト変更はBookLayoutEditorViewModelが
/// 担当する。bookIDが変わるたびに親(BookmarkEditorView)側で.id(bookID)を付けて
/// このView自体を作り直しているため、@StateObjectも本を切り替えるたびに正しく再生成される。
private struct BookmarkDetailPane: View {
    let bookID: String
    @ObservedObject var bookmarkStore: BookmarkStore
    @ObservedObject var layoutStore: LayoutStore
    let preferences: AppPreferences
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @Environment(\.openWindow) private var openWindow

    @Binding var renamingBookmark: Bookmark?
    @Binding var renameText: String
    @Binding var pendingBulkRenameBookID: String?
    @Binding var pendingDeleteBookmarksBookID: String?
    @Binding var pendingDeleteLayoutBookID: String?

    @StateObject private var viewModel: BookLayoutEditorViewModel

    // 既定値は無くしてある(initで必ずinitialPageFilterから明示的に初期化するため)。
    @State private var pageFilter: EditorPageFilter
    @State private var selectedPageKey: String?
    @State private var openErrorBookName: String?
    @State private var editorWindow: NSWindow?
    /// 列ヘッダー行(columnHeaderRow)・各行(PageRowView)で共有する列幅
    /// (ユーザー要望: 列タイトル行・区切り線・可変幅。PageListColumnWidths参照)。
    @State private var columnWidths = PageListColumnWidths()
    /// タイトル行(List外)と各行(List内)、両方の区切り線の実測x座標("header:0"〜"header:2"/
    /// "row:0"〜"row:2"。ColumnDividerXPreferenceKey参照)。バグ修正: 余白・幅の指定を
    /// 両者で厳密に一致させても、Listの内と外という描画パイプラインの違いにより、
    /// 区切り線の位置がわずかにずれたまま残ることがあった(ユーザー報告、複数回)。
    /// 指定値を揃える方針では解消しきれなかったため、実際に描画された位置を測定し、
    /// 各行の区切り線をタイトル行の実測位置に追従させる(columnDividerCorrections参照)ことで、
    /// 原因を問わず確実に位置を一致させる。
    @State private var measuredDividerXs: [String: CGFloat] = [:]

    /// 各行の区切り線(row:0〜2)を、タイトル行の対応する区切り線(header:0〜2)の実測位置へ
    /// 追従させるための補正量。両方の実測値がまだ揃っていない間は補正しない(0)。
    private var columnDividerCorrections: [Int: CGFloat] {
        var result: [Int: CGFloat] = [:]
        for index in 0..<3 {
            if let headerX = measuredDividerXs["header:\(index)"], let rowX = measuredDividerXs["row:\(index)"] {
                result[index] = headerX - rowX
            }
        }
        return result
    }

    /// レイアウト変更(3.2節)を選んだ後、伝播範囲(3.3節)を確認するダイアログ用の保留中の操作。
    /// ビューア(ViewerView)と全く同じ仕組み・同じダイアログ文言を使う。
    @State private var pendingLayoutChange: PendingPageLayoutChange?

    private struct PendingPageLayoutChange: Identifiable {
        let id = UUID()
        let pageKey: String
        let state: PageLayoutState
    }

    init(
        bookID: String,
        bookmarkStore: BookmarkStore,
        layoutStore: LayoutStore,
        preferences: AppPreferences,
        initialPageFilter: EditorPageFilter,
        renamingBookmark: Binding<Bookmark?>,
        renameText: Binding<String>,
        pendingBulkRenameBookID: Binding<String?>,
        pendingDeleteBookmarksBookID: Binding<String?>,
        pendingDeleteLayoutBookID: Binding<String?>
    ) {
        self.bookID = bookID
        self.bookmarkStore = bookmarkStore
        self.layoutStore = layoutStore
        self.preferences = preferences
        _renamingBookmark = renamingBookmark
        _renameText = renameText
        _pendingBulkRenameBookID = pendingBulkRenameBookID
        _pendingDeleteBookmarksBookID = pendingDeleteBookmarksBookID
        _pendingDeleteLayoutBookID = pendingDeleteLayoutBookID
        // 呼び出し元(「ブックマークの編集」/「レイアウトの編集」)に応じた左ペインの初期絞り込み
        // (BookmarkEditorView.applyInitialFocus)と、右ペインのこの初期絞り込みを一致させる
        // (ユーザー報告: お気に入りメニューから「ブックマークの編集」を呼び出すと、左ペインは
        // 「ブックマークがある」で絞り込まれるのに右ペインが「すべて」のままだった)。
        // このView自体は親側で.id(bookID)により本を切り替えるたびに作り直されるため、
        // @Stateの初期値をここで都度変えても問題ない(本を切り替えるたびに正しく再適用される)。
        _pageFilter = State(initialValue: initialPageFilter)
        _viewModel = StateObject(
            wrappedValue: BookLayoutEditorViewModel(
                bookID: bookID, layoutStore: layoutStore, preferences: preferences, bookmarkStore: bookmarkStore
            )
        )
    }

    /// 実際にList/ForEachへ渡す、表示用の並び順。
    ///
    /// pageFilterによる絞り込み(「ブックマークがあるページのみ」)を適用したうえで、除外
    /// (非表示)ページを一覧の最後尾へまとめて回し、複数ある場合はファイル名の自然順で
    /// 並べる(ユーザー要望: 除外ページが読書順の並びに混ざっていると分かりづらいため)。
    ///
    /// これはあくまで「この右ペインにどう表示するか」という見た目だけの並べ替えであり、
    /// viewModel.rows自体(pageOrderOverrideとして永続化される「真の」読書順)は変更しない。
    /// 除外を解除したとき、そのページが除外される前の位置(本来の読書順)へ正しく戻れるように
    /// するため(もし真の順序自体を書き換えてしまうと、除外→解除しただけで本の最後の方の
    /// ページとして復活してしまう、という別の不具合を生む)。
    ///
    /// 表示順と真の順序(viewModel.rows)が食い違いうるため、ドラッグ&ドロップ並べ替え
    /// (.onMove)はpageFilter != .allの間は無効化する(pageListContentのForEach.moveDisabled
    /// 参照)。除外ページが1件でもある場合は、以前はここも一緒に無効化していたが、
    /// viewModel.movePages(displayedPageKeys:fromOffsets:toOffset:)側でこのインデックス空間の
    /// 食い違いを吸収するようにしたため、除外ページがあっても並べ替えできる
    /// (上下ボタン(movePageUp/movePageDown)はviewModel.rows自体をpageKeyで直接操作するため、
    /// もともとこの表示専用の並べ替えの影響を受けない)。
    private var displayedRows: [BookLayoutEditorViewModel.Row] {
        let base: [BookLayoutEditorViewModel.Row]
        if pageFilter == .hasBookmarks {
            let bookmarkedIndices = Set(bookmarkStore.bookmarks(forBookID: bookID).map(\.pageIndex))
            base = viewModel.rows.filter { row in
                guard let index = row.effectiveReadingIndex else { return false }
                return bookmarkedIndices.contains(index)
            }
        } else {
            base = viewModel.rows
        }
        let included = base.filter { $0.effectiveReadingIndex != nil }
        let excluded = base.filter { $0.effectiveReadingIndex == nil }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return included + excluded
    }

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ContentUnavailableView(
                    "Could Not Open Book",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The file or folder for this book could not be found. It may have been moved or deleted.")
                )
            case .loaded:
                pageListContent
            }
        }
        .task(id: bookID) {
            await viewModel.load()
        }
        .navigationTitle("Bookmarks & Layout")
        .background(WindowAccessor { window in
            editorWindow = window
        })
        .alert(
            "Could Not Open Book",
            isPresented: Binding(
                get: { openErrorBookName != nil },
                set: { isPresented in if !isPresented { openErrorBookName = nil } }
            )
        ) {
            Button("OK") { openErrorBookName = nil }
        } message: {
            Text("The file or folder for “") + Text(openErrorBookName ?? "")
                + Text("” could not be found. It may have been moved or deleted.")
        }
        // 3.3節の伝播範囲選択ダイアログ。ViewerView.swiftと全く同じ文言・選択肢を使う。
        .confirmationDialog(
            "Apply Layout Change To…",
            isPresented: Binding(
                get: { pendingLayoutChange != nil },
                set: { isPresented in
                    if !isPresented { pendingLayoutChange = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let pending = pendingLayoutChange {
                ForEach(availableScopes(forPageKey: pending.pageKey)) { scope in
                    Button(scope.titleKey) {
                        pendingLayoutChange = nil
                        Task {
                            await viewModel.setPageLayout(pageKey: pending.pageKey, to: pending.state, scope: scope)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingLayoutChange = nil
            }
        } message: {
            Text("Choose how far this layout change should apply.")
        }
    }

    /// pageKeyの読書順上の位置(除外ページを除いた空間、viewModel.rows[].effectiveReadingIndex)に
    /// 応じて、意味のある伝播範囲(3.3節)だけに絞り込む(ユーザー報告: 先頭ページなのに
    /// 「このページより前のページ全体」が選択肢に出てしまうのはおかしい)。
    ///
    /// - 読書順で先頭のページには「このページより前」を出さない(対象になるページが存在しないため)。
    /// - 読書順で末尾のページには「このページより後」を出さない(同上)。
    /// - 対象ページが除外(非表示)中で、まだeffectiveReadingIndexを持たない場合は、変更後に
    ///   どの位置へ入るか事前には分からないため、判定を省略してすべての選択肢を出す
    ///   (安全側に倒す。実害は「前/後を選んでも対象が0件」程度に留まる)。
    private func availableScopes(forPageKey pageKey: String) -> [LayoutPropagationScope] {
        guard let targetIndex = viewModel.rows.first(where: { $0.pageKey == pageKey })?.effectiveReadingIndex else {
            return LayoutPropagationScope.allCases
        }
        let maxIndex = viewModel.rows.compactMap(\.effectiveReadingIndex).max()
        return LayoutPropagationScope.allCases.filter { scope in
            switch scope {
            case .thisPageOnly, .wholeBook:
                return true
            case .beforeThisPage:
                return targetIndex > 0
            case .afterThisPage:
                return maxIndex.map { targetIndex < $0 } ?? false
            }
        }
    }

    private var pageListContent: some View {
        List {
            ForEach(displayedRows) { row in
                PageRowView(
                    row: row,
                    viewModel: viewModel,
                    bookID: bookID,
                    bookmark: row.effectiveReadingIndex.flatMap { index in
                        bookmarkStore.bookmarks(forBookID: bookID).first { $0.pageIndex == index }
                    },
                    isSelected: selectedPageKey == row.pageKey,
                    isLayoutLocked: viewModel.hasAuthoritativeEpubLayout,
                    columnWidths: columnWidths,
                    columnDividerCorrections: columnDividerCorrections,
                    isMoveEnabled: !viewModel.hasAuthoritativeEpubLayout && pageFilter == .all,
                    onSelect: { selectedPageKey = row.pageKey },
                    onJump: { openBookAndJump(toPageIndex: row.effectiveReadingIndex) },
                    onAddBookmark: { addBookmark(atPageIndex: row.effectiveReadingIndex) },
                    onRenameBookmark: { bookmark in
                        // 同じブックマークを続けてリネームすると100%再現する不具合(ユーザー報告:
                        // 別のブックマークを一度挟んでから開き直すと正しく表示される)への対策。
                        //
                        // 原因: SwiftUIの@Stateは、代入する値が現在保持している値と等しい場合、
                        // 実際の再描画(および.alert内のTextFieldへの値の反映)を省略する。
                        // 直前にこのブックマークをリネームした場合、renameTextは既にその新しい
                        // 名前(=bookmark.name)を保持したままになっているため、
                        // 「renameText = bookmark.name」は値として変化が無く、TextField側には
                        // 何も反映されない。一方、直前のアラートを閉じた時点でAppKit側の
                        // (NSAlertが内部で使う)テキストフィールド自体は空にリセットされてしまって
                        // いるため、見た目だけ空欄のまま新しいアラートが表示される。
                        // 別のブックマークを挟むと直るのは、そのときはrenameTextの値が実際に
                        // 変化するため。
                        //
                        // 対策として、必ず一度renameTextを(現在の値と異なりうる)空文字へ変えてから
                        // アラートを表示し、その次の実行ループであらためて本来の名前を設定する。
                        // こうすることで、SwiftUIから見て必ず「値が変化した」とみなされ、
                        // TextFieldに正しく反映される。
                        renameText = ""
                        renamingBookmark = bookmark
                        DispatchQueue.main.async {
                            renameText = bookmark.name
                        }
                    },
                    onDeleteBookmark: { bookmark in bookmarkStore.delete(bookmark) },
                    onLayoutStateChange: { newState in
                        if let newState {
                            pendingLayoutChange = PendingPageLayoutChange(pageKey: row.pageKey, state: newState)
                        } else {
                            viewModel.clearPageLayout(pageKey: row.pageKey)
                        }
                    }
                )
                // バグ修正: Listの既定の行インセットに頼ると、リストスタイルやonMoveの有無に
                // よって実際の余白がcolumnHeaderRow側の.paddingと微妙に食い違うことがあり、
                // 区切り線が揃わなかった(ユーザー報告)。ここではList側の余白を完全にゼロにし、
                // 代わりにPageRowView自身がcolumnHeaderRowと全く同じ書き方
                // (.padding(.horizontal, 12).padding(.vertical, 4))で余白を付けるようにして、
                // 両者の余白計算の仕組みそのものを揃えている。
                .listRowInsets(EdgeInsets())
                // 行と行の間の区切り線は、Listが自動で出す区切り線(内側の余白の影響を受けて
                // 半端な位置で途切れて見えていた。ユーザー報告)を使わず、PageRowView側で
                // 行の全幅にわたる区切り線を自前で描画する(bodyの.overlay(alignment: .bottom)
                // 参照)ため、ここでは非表示にする。
                .listRowSeparator(.hidden)
            }
            .onMove { source, destination in
                viewModel.movePages(
                    displayedPageKeys: displayedRows.map(\.pageKey), fromOffsets: source, toOffset: destination
                )
            }
            // .onMoveがSwiftUIから受け取るIndexSet/destinationは、常に「今実際にList/ForEachへ
            // 渡している配列(displayedRows)」内での位置を指す。pageFilterで絞り込んでいる間は
            // displayedRowsがviewModel.rows(並べ替えの実体、常に全ページ)の部分集合になり、
            // インデックス空間が食い違うため、そのまま渡すと誤った位置に並べ替えてしまう。
            // そのため絞り込み中は引き続きドラッグ&ドロップ自体を無効化する。
            //
            // 除外ページが1件でもある場合は、以前はここも一緒に無効化していた(除外ページは
            // displayedRowsで最後尾へファイル名順に回すため、rowsとのインデックス空間が
            // 食い違うため)が、上下矢印ボタン(movePageUp/movePageDown)はpageKeyでrows自体を
            // 直接操作するため除外ページがあっても問題なく動作しており、ドラッグだけ使えないのは
            // 不自然だというユーザー報告を受けて、movePages(displayedPageKeys:fromOffsets:
            // toOffset:)側でインデックス空間の変換を行うように修正し、この制限を外した。
            .moveDisabled(viewModel.hasAuthoritativeEpubLayout || pageFilter != .all)
        }
        // バグ修正: 既定のList見た目(inset系)は、タイトル行(columnHeaderRow)との間に
        // 余分な上下の余白を持ち込み、隙間が広く見えていた(ユーザー報告)。.plainにすることで
        // 余白を最小限にし、タイトル行と1行目の間隔を詰める。
        .listStyle(.plain)
        // ユーザー要望: スクロールしない列タイトル行を追加してほしい。.safeAreaInset(edge: .top)を
        // 複数回チェインすると、先に適用したもの(この行)がListの行に近い側(すぐ上)に、後から
        // 適用したもの(この下のツールバー)がさらにその上に積み重なる。そのため、ここで
        // columnHeaderRowを先に挿入しておくことで、「ツールバー→列タイトル行→実際の行」という
        // 意図した並びになる。
        .safeAreaInset(edge: .top) {
            columnHeaderRowContainer
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 6) {
                // 最上段: 「ページ上下ボタン」「読み方向」「絞り込み」の順で1列に並べる
                // (ユーザー要望)。以前は読み方向+上下ボタン+表示順初期化ボタンの行と、
                // 絞り込みだけの行の2段に分かれていたが、1段にまとめた。表示順初期化ボタンは
                // 使用頻度が低いため下部の「一括操作…」メニューへ移した(movePageUp/
                // movePageDown/resetOrderの呼び出し先自体は変更していない)。
                HStack {
                    Button {
                        movePageUp()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(viewModel.hasAuthoritativeEpubLayout || selectedPageKey == nil)
                    .help("Move Selected Page Earlier")

                    Button {
                        movePageDown()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(viewModel.hasAuthoritativeEpubLayout || selectedPageKey == nil)
                    .help("Move Selected Page Later")

                    if !viewModel.hasAuthoritativeEpubLayout {
                        Text("Reading Direction")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // ユーザー報告: 上書き未設定のとき「Default」とだけ表示され、実際にこの本が
                        // どちら向きで開かれるのか分からなかった。「既定」という選択肢自体を無くし、
                        // 常に「右開き」「左開き」のどちらかで、実際に適用される値
                        // (readingDirectionBinding参照)を表示するようにした。
                        Picker(selection: readingDirectionBinding) {
                            Text("Right-to-Left").tag(ReadingDirection.rightToLeft)
                            Text("Left-to-Right").tag(ReadingDirection.leftToRight)
                        } label: {
                            EmptyView()
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }

                    // 4.4節: 「一括リネーム」「表示順を初期化」「ブックマークを全削除」
                    // 「レイアウトを全削除」は、以前は右ペイン下部に独立したボタン/メニューとして
                    // 常時表示していたが、読み方向・絞り込みと同じ最上段の1列にまとめてほしい
                    // という要望により、この位置(読み方向と絞り込みの間)へ移動した。
                    Menu {
                        Button("Bulk Rename Bookmarks…") {
                            pendingBulkRenameBookID = bookID
                        }
                        .disabled(bookmarkStore.bookmarks(forBookID: bookID).isEmpty)

                        Button("Delete All Bookmarks…", role: .destructive) {
                            pendingDeleteBookmarksBookID = bookID
                        }
                        .disabled(bookmarkStore.bookmarks(forBookID: bookID).isEmpty)

                        Button("Delete All Layout Info…", role: .destructive) {
                            pendingDeleteLayoutBookID = bookID
                        }
                        .disabled(!layoutStore.layoutBookIDs.contains(bookID))

                        // 4.3節「表示順を初期化する」。使用頻度が低い操作のため、このメニューの
                        // 最後尾に置いている(ユーザー要望)。カスタム並び替え(pageOrderOverride)が
                        // 無い(既に自然順のまま)場合は押しても意味が無いため無効化する。
                        Button("Reset Page Order") {
                            viewModel.resetOrder()
                        }
                        .disabled(
                            viewModel.hasAuthoritativeEpubLayout
                                || layoutStore.bookLayoutSettings(forBookID: bookID)?.pageOrderOverride == nil
                        )
                    } label: {
                        Label("Bulk Operations…", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.button)

                    Spacer()

                    Picker(selection: $pageFilter) {
                        ForEach(EditorPageFilter.allCases) { filter in
                            Text(filter.titleKey).tag(filter)
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                if viewModel.hasAuthoritativeEpubLayout {
                    // EPUB由来の権威的なレイアウト指定がある本では、読み方向・並べ替え・
                    // レイアウト列すべてを無効化する(2.4節: OPF側の指定が優先されるため)。
                    Text("This book's page layout is defined by its EPUB file and cannot be edited here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let warning = viewModel.reorderWarningMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.caption)
                        Spacer()
                        Button {
                            viewModel.dismissReorderWarning()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        // ユーザー報告により、以前ここ(下部)にあった「現在のページを追加」ボタンは削除し
        // (ビューアの「現在のページ」とこのウインドウで選択中の行が必ずしも一致せず、紛らわしい
        // ため)、「一括操作」メニューは上部ツールバー(読み方向と絞り込みの間)へ移動した
        // (safeAreaInset(edge: .top)側のMenu("Bulk Operations…")参照)。そのため、この
        // safeAreaInset(edge: .bottom)自体が不要になったので削除した。
        //
        // バグ修正: タイトル行(List外、safeAreaInset)と各行(List内)の区切り線を、余白や幅の
        // 指定を揃えるだけでは正確に一致させられなかった(ユーザー報告、複数回)。
        // columnHeaderRow・PageRowViewの各区切り線が、実際に画面上へ描画されたx座標(.global
        // 座標空間。ColumnDividerXPreferenceKey参照)を報告し、ここで集計してmeasuredDividerXsに
        // 反映する。columnDividerCorrectionsが、その実測値の差分を各行の区切り線への補正量として
        // 計算し、行側がタイトル行の実測位置へ確実に追従するようにする(指定値の一致に頼らず、
        // 実測ベースで原因を問わず揃える)。
        .onPreferenceChange(ColumnDividerXPreferenceKey.self) { newValue in
            measuredDividerXs = newValue
        }
    }

    /// 右ペインの列タイトル行(ユーザー要望: スクロールしないタイトル行を追加してほしい)。
    /// 各行(PageRowView)と同じHStack構造(spacing: 10、ドラッグハンドル列相当の余白+Divider+
    /// 4列+区切り線)を再現することで、列の位置がぴったり揃うようにしている。ドラッグハンドル列
    /// 自体は「掴んで並べ替える」ためのアイコンで、対応する見出しの概念が無いため、ラベルを
    /// 付けない(ユーザーの要望通り)。実際のドラッグハンドルアイコンと全く同じビューを
    /// 不透明度0で置くことで、数値の決め打ちに頼らず正確に横位置を揃えている。
    ///
    /// ページ・サムネイル・レイアウトの3つの区切り線はResizableColumnDividerにしており、
    /// ドラッグすると対応する列の幅(columnWidths、各行と共有)が変わる(ユーザー要望:
    /// 列の幅を可変にしたい)。ブックマーク列は元から残り幅いっぱいに広がる設計のため、
    /// その手前の区切り線までがドラッグ対象で、ブックマーク列自体に対応する区切り線は無い。
    private var columnHeaderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .opacity(0)

            Divider()

            Text("Page")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.pageNumber, alignment: .trailing)

            ResizableColumnDivider(width: $columnWidths.pageNumber, measurementKey: "header:0")

            Text("Thumbnail")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: columnWidths.thumbnail)

            ResizableColumnDivider(width: $columnWidths.thumbnail, measurementKey: "header:1")

            Text("Layout")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.layout, alignment: .leading)

            ResizableColumnDivider(width: $columnWidths.layout, measurementKey: "header:2")

            Text("Bookmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // バグ修正: HStackに明示的な高さが無いと、内部のDivider()やResizableColumnDividerの
        // Rectangle()が縦方向に無制限に広がろうとし、.safeAreaInset(edge: .top)がペイン全体の
        // 高さを確保してしまって、その下のList行が表示されなくなっていた。行の高さを固定して
        // タイトル行だけがコンパクトに収まるようにする。
        .frame(height: ResizableColumnDivider.height)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// columnHeaderRowの高さ(.frame(height: ResizableColumnDivider.height)に上下の
    /// .padding(.vertical, 4)を加えたもの)。columnHeaderRowContainer側でListの高さを
    /// ぴったり合わせるのに使う。
    private var columnHeaderRowHeight: CGFloat {
        ResizableColumnDivider.height + 4 * 2
    }

    /// columnHeaderRowを、実際のページ行(PageRowView)と全く同じ「List行」として描画するための
    /// 入れ物。
    ///
    /// バグ修正: 以前はcolumnHeaderRowを素のHStack(List外、.safeAreaInset経由)として描画し、
    /// 各行(List内)側の余白・幅の指定をどれだけ厳密に一致させても、区切り線の位置が
    /// わずかにずれたまま残った(ユーザー報告、複数回)。GeometryReader/PreferenceKeyによる
    /// 実測補正も試したが、List内の行から実測値を報告できていない可能性が高く、改善しなかった。
    /// 根本原因は「Listの内側」と「Listの外側」とでAppKit側の描画パイプラインそのものが違う
    /// ことにあると考えられるため、タイトル行もこの通り小さな1行だけの非スクロールListに
    /// 収め、PageRowViewと全く同じ.listRowInsets(EdgeInsets())/.listRowSeparator(.hidden)の
    /// 組み合わせを使うことで、両者を文字通り同じ描画パイプライン(Listの行)に乗せる。
    /// これにより、値を揃えるだけでも実測で補正するだけでもなく、そもそも仕組みそのものを
    /// 一致させて解決する。
    private var columnHeaderRowContainer: some View {
        List {
            columnHeaderRow
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .frame(height: columnHeaderRowHeight)
    }

    /// ユーザー報告: 上書き未設定のときに「既定」とだけ表示され、実際にこの本がどちら向きで
    /// 開かれるのか分からなかった。上書きが無い間はviewModel.effectiveReadingDirection
    /// (EPUB由来 > DB保存値 > 環境設定の既定値、の優先順位で解決した実際の値)を表示し、
    /// ユーザーが選んだ値はこれまで通り明示的な上書きとして保存する(「既定に戻す」選択肢は
    /// 無いままにしている。既存の「レイアウトを全削除」で上書き自体を消せるため)。
    private var readingDirectionBinding: Binding<ReadingDirection> {
        Binding(
            get: {
                layoutStore.bookLayoutSettings(forBookID: bookID)?.readingDirectionOverride
                    ?? viewModel.effectiveReadingDirection
            },
            set: { viewModel.setReadingDirectionOverride($0) }
        )
    }

    private func movePageUp() {
        guard let selectedPageKey, let index = viewModel.rows.firstIndex(where: { $0.pageKey == selectedPageKey }) else { return }
        viewModel.movePageUp(at: index)
    }

    private func movePageDown() {
        guard let selectedPageKey, let index = viewModel.rows.firstIndex(where: { $0.pageKey == selectedPageKey }) else { return }
        viewModel.movePageDown(at: index)
    }

    /// 行(ページ)ごとの「+」ボタンから、そのページへ直接ブックマークを追加する。
    /// effectiveReadingIndexがnil(除外ページ)の場合は追加できない(通常の読書フローに
    /// 存在しないページのため)。
    ///
    /// 以前はopenAppState(この本を今開いているウインドウ/タブ)のaddBookmarkActionを
    /// 呼び出していたが、それはビューアの「現在表示中のページ」にブックマークを追加する
    /// アクションであり、(1)この本を今開いていなければopenAppStateがnilになり常に無反応、
    /// (2)開いていても、クリックした行のページとビューアの現在ページが一致しない限り
    /// 別のページに追加されてしまう、という2つの不具合があった(ユーザー報告により発覚)。
    /// bookmarkStore.addBookmark(bookID:pageIndex:name:)は本を開いているかどうかに関わらず
    /// 直接SwiftDataへ書き込めるため、ここではそちらを使い、指定したpageIndexへ確実に
    /// 追加する。ブックマークの命名規則(「Page N」+作成時点の表示言語)はViewerViewModel.
    /// addBookmark()と同じものをそろえる。
    private func addBookmark(atPageIndex pageIndex: Int?) {
        guard let pageIndex else { return }
        let pagePrefix = String(localized: "Page", locale: preferences.effectiveLocale)
        // ユーザー要望: ここで新規作成するブックマークにもファイルノード識別子(iノード番号)を
        // 記録したい。この本を今開いているとは限らないため、ViewerViewModel.addBookmarkのように
        // 既に読み込み済みのbook.sourceURLを使うことはできず、layoutStore.resolvedURL(forBookID:)で
        // 都度解決する(openBookAndJumpと同じ解決手段。解決できなければnilのままでよく、従来通り
        // inode無しで作成される)。
        var fileNodeIdentifier: FileNodeIdentifier?
        if let url = layoutStore.resolvedURL(forBookID: bookID) {
            let didAccess = url.startAccessingSecurityScopedResource()
            fileNodeIdentifier = FileNodeIdentifier.current(for: url)
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        bookmarkStore.addBookmark(
            bookID: bookID, pageIndex: pageIndex, name: "\(pagePrefix) \(pageIndex + 1)",
            fileNodeIdentifier: fileNodeIdentifier
        )
    }

    /// サムネイルのダブルクリックでそのページへジャンプする(4.2節)。
    /// BookmarkStore版のopenBookAndJump(to:)と同じ「既存/新規ウインドウ/置き換え」の
    /// 3通りの分岐を踏襲するが、対象はBookmarkではなくページ番号のため、簡略化した
    /// 専用のジャンプ処理をここに持つ。除外ページ(effectiveReadingIndexがnil)は
    /// 通常の読書フローに存在しないため、ジャンプ自体を行わない。
    private func openBookAndJump(toPageIndex pageIndex: Int?) {
        guard let pageIndex else { return }

        if let existingAppState = launchCoordinator.openAppState(forBookID: bookID) {
            // ページ番号を直接指定してジャンプする手段がperformViewerAction(ViewerActionは
            // 相対移動のみ)経由には無いため、AppState.jumpToPageIndexという専用の橋渡しを使う
            // (jumpToBookmarkと同じ仕組み。詳細はAppState.swiftのコメント参照)。
            existingAppState.jumpToPageIndex?(pageIndex)
            existingAppState.hostWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            closeEditorWindow()
            return
        }

        guard let url = layoutStore.resolvedURL(forBookID: bookID) else {
            openErrorBookName = URL(fileURLWithPath: bookID).deletingPathExtension().lastPathComponent
            return
        }
        _ = url.startAccessingSecurityScopedResource()

        if let targetAppState = launchCoordinator.frontmostContentAppState() {
            targetAppState.open(url: url)
            waitAndJump(appState: targetAppState, toPageIndex: pageIndex)
        } else {
            openWindow(id: "book", value: url)
            Task { @MainActor in
                for _ in 0..<200 {
                    if let newAppState = launchCoordinator.openAppState(forBookID: bookID) {
                        waitAndJump(appState: newAppState, toPageIndex: pageIndex)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
            }
        }
    }

    private func waitAndJump(appState: AppState, toPageIndex pageIndex: Int) {
        Task { @MainActor in
            for _ in 0..<200 {
                if appState.currentBook?.id == bookID, appState.jumpToPageIndex != nil {
                    appState.jumpToPageIndex?(pageIndex)
                    appState.hostWindow?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    closeEditorWindow()
                    return
                }
                if appState.currentBook == nil, appState.errorMessage != nil {
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    private func closeEditorWindow() {
        editorWindow?.close()
    }
}

/// 右ペインの1ページ分の行。サムネイル(サムネイル列)・レイアウト(レイアウト列)・
/// ブックマーク(ブックマーク列)の3列を横に並べる(4.2節)。
private struct PageRowView: View {
    let row: BookLayoutEditorViewModel.Row
    @ObservedObject var viewModel: BookLayoutEditorViewModel
    let bookID: String
    let bookmark: Bookmark?
    let isSelected: Bool
    let isLayoutLocked: Bool
    /// 列ヘッダー行(columnHeaderRow)と共有する列幅。ヘッダー側でドラッグして幅を変えると、
    /// 同じBindingを通じてすべての行に即座に反映される(PageListColumnWidths参照)。
    let columnWidths: PageListColumnWidths
    /// 各区切り線(0=ページ/サムネイル境界、1=サムネイル/レイアウト境界、
    /// 2=レイアウト/ブックマーク境界)を、タイトル行の実測位置へ追従させるための補正量
    /// (BookmarkDetailPane.columnDividerCorrections参照)。
    let columnDividerCorrections: [Int: CGFloat]
    /// ドラッグハンドルを実際に使える見た目にするかどうか。呼び出し元
    /// (BookmarkDetailPane.pageListContent)のForEach.moveDisabledと同じ条件
    /// (!isLayoutLocked && pageFilter == .all)を渡す。
    let isMoveEnabled: Bool
    let onSelect: () -> Void
    let onJump: () -> Void
    let onAddBookmark: () -> Void
    let onRenameBookmark: (Bookmark) -> Void
    let onDeleteBookmark: (Bookmark) -> Void
    /// nilを渡すと「レイアウトなし」(=削除)、値を渡すと3.3節の伝播範囲ダイアログを呼び出す
    /// (呼び出し元のBookmarkDetailPaneが実際の分岐を行う)。
    let onLayoutStateChange: (PageLayoutState?) -> Void

    @State private var thumbnail: CGImage?
    /// カーソルが小さいサムネイルの上にあるかどうか。拡大プレビュー用のpopoverの表示制御に使う
    /// (thumbnailPreviewContent参照)。
    @State private var isHoveringThumbnail = false
    /// 拡大プレビュー用のフル解像度画像。一度読み込めば、同じ行を何度ホバーしても読み込み直さない
    /// よう@Stateにキャッシュしておく(素早くホバーを出し入れしたときのちらつき防止)。
    @State private var previewImage: CGImage?
    /// ホバー開始から実際にpopoverを出すまでの遅延用タスク(bodyの.onHoverのコメント参照)。
    @State private var hoverPreviewTask: Task<Void, Never>?
    /// ホバー開始から実際にpopoverを出すまでの遅延(ナノ秒)。
    private static let hoverPreviewDelayNanoseconds: UInt64 = 350_000_000

    /// viewModel.pageLayoutStates(BookLayoutEditorViewModelが確定させたスナップショット)を
    /// 参照する。以前はここでlayoutStore.pageOverride(forBookID:pageKey:)を直接呼び、
    /// 行が再描画されるたびにSwiftDataへ都度フェッチしていたが、それが原因と思われる
    /// 不具合(ユーザー報告: あるページのレイアウトを変更すると無関係な他のページまで
    /// 変わって見える/レイアウトなしに戻って見える)があったため、BookLayoutEditorViewModel.
    /// pageLayoutStatesのコメントで説明している設計に変更した。
    private var currentLayoutState: PageLayoutState? {
        viewModel.pageLayoutStates[row.pageKey]
    }

    /// 一番左に表示するページ番号(1始まり)。row.effectiveReadingIndexは、除外(非表示)ページを
    /// 除いた実際の読書順でのインデックス(nilなら除外ページ自身)。BookLayoutEditorViewModel.
    /// recomputeEffectiveIndicesが除外・並べ替えのどちらの操作の後にも必ず呼ばれ、常に先頭
    /// (除外ページを除く)から連番で振り直しているため、この表示は特別な更新処理を挟まずとも
    /// 常に最新の状態を反映する(rows(@Published)が変わるたびにこのView自体が再描画されるため)。
    /// 除外ページには番号を振らず、代わりに「非表示」ラベルを表示する(ユーザー要望)。
    /// Text("Hidden")は文字列リテラルとしてLocalizedStringKeyに解釈されるため、
    /// Localizable.xcstringsのローカライズが自動的に適用される(Text(String)は
    /// ローカライズされないため、戻り値をTextそのものにしている)。
    private var pageNumberLabel: Text {
        if let index = row.effectiveReadingIndex {
            return Text("\(index + 1)")
        }
        return Text("Hidden")
    }

    var body: some View {
        HStack(spacing: 10) {
            // ドラッグハンドル列(4.3節: 行のドラッグ&ドロップによる並べ替え)。
            // 絞り込み中(pageFilter != .all)・EPUB由来の権威的なレイアウト指定がある本では
            // 並べ替え自体が無効(呼び出し元のForEach.moveDisabled参照)なため、掴んでも意味が
            // ないことが分かるよう半透明にしておく。
            //
            // あえてこのアイコンだけを、下の.contentShape(Rectangle())/.simultaneousGesture
            // (行の選択用タップジェスチャー)が掛かっている範囲の外(このHStackの直接の子として、
            // 内側のグループHStackより前)に置いている。List+ForEach.onMoveの並べ替えドラッグは
            // NSTableView側のネイティブなドラッグ認識に依存しており、SwiftUI側のジェスチャー
            // 認識器(このアイコンの真上にTapGestureがかぶっていること自体)が、掴み始めの
            // 一瞬を先取りしてドラッグの認識を妨げることがある(ユーザー報告: 3本線マークを
            // 掴んでドラッグしても並べ替えが始まらない)。ドラッグの掴み始めとして最も自然な
            // このアイコンの領域だけは、SwiftUI側のジェスチャーを一切持たない「素の」ビューに
            // しておくことで、NSTableViewのドラッグ認識を妨げないようにする。
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .opacity(isMoveEnabled ? 1 : 0.3)
                .help(isMoveEnabled ? "Drag to Reorder" : "")

            // ドラッグハンドル列と、そこから先の列群(selectableContent)の間の区切り線
            // (ユーザー要望: 各列に区切り線を表示してほしい)。ヘッダー行(columnHeaderRow)側の
            // 対応する区切り線と違い、ここは見た目だけでドラッグでの幅変更は持たない
            // (PageListColumnWidths/ResizableColumnDividerのコメント参照。列幅の変更は
            // ヘッダー行からだけ行える)。
            Divider()

            selectableContent
        }
        // バグ修正: columnHeaderRow(タイトル行)と全く同じ余白の付け方(.padding(.horizontal, 12)/
        // .padding(.vertical, 4))にすることで、列の区切り線がタイトル行と正確に揃うようにする
        // (呼び出し元のpageListContentで.listRowInsets(EdgeInsets())によりListの既定余白を
        // ゼロにし、代わりにここで余白を付けている)。
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        // バグ修正: Listが自動で出す行区切り線は、上記の余白変更の影響で行の途中で切れて
        // 見えていた(ユーザー報告)。呼び出し元で.listRowSeparator(.hidden)にした代わりに、
        // ここで行の全幅にわたる区切り線を自前で描画する。
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// ドラッグハンドル(line.3.horizontal)を除いた、行の残り全体。ページ番号・サムネイル・
    /// レイアウト・ブックマークの各列をまとめ、この範囲にだけ行選択用のタップジェスチャーを
    /// 掛ける(bodyのドラッグハンドルのコメント参照。ドラッグハンドルの掴み始めを妨げないため、
    /// あえてドラッグハンドルをこの範囲から除外している)。列と列の間にはDivider()を挟み、
    /// 各列の幅は共有のcolumnWidths(ヘッダー行と同じ値)を参照する(ユーザー要望: 区切り線・
    /// 可変幅)。
    private var selectableContent: some View {
        HStack(spacing: 10) {
            // ページ番号列。除外ページは「非表示」ラベル。
            pageNumberLabel
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: columnWidths.pageNumber, alignment: .trailing)

            ColumnDividerLine(measurementKey: "row:0")
                .offset(x: columnDividerCorrections[0] ?? 0)

            // サムネイル列。
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: columnWidths.thumbnail, height: columnWidths.thumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help(row.displayName)
            .onTapGesture(count: 2) { onJump() }
            .task(id: row.pageKey) {
                thumbnail = await viewModel.thumbnail(rawIndex: row.rawIndex)
            }
            // カーソルをホバーしている間、大きなプレビューとファイル名を表示する(ユーザー要望)。
            // 一覧に常時並ぶ小さいサムネイル(44x60、進捗バー用の軽量な解像度)だけでは
            // ファイル名も読みづらく、絵柄の確認もしづらいための補助。
            //
            // ホバーした瞬間に即座にpopoverを出さず、一定時間(hoverPreviewDelayNanoseconds)
            // ホバーし続けた場合にだけ表示するようにしている。ドラッグ&ドロップ並べ替え
            // (List.onMove)の掴み始めの位置がこのサムネイル・ドラッグハンドル付近になりやすく、
            // 即座にホバー判定・popover表示が走ると、ドラッグでの並べ替え操作が意図せず妨げられる
            // (ユーザー報告)ため。ドラッグ操作では指を置いてすぐ動かすため、この遅延の間に
            // カーソルが離れてタスクがキャンセルされ、popoverは表示されない。意図的に静止して
            // 見るホバープレビューの用途では、この程度の遅延は体感上問題にならない。
            .onHover { hovering in
                hoverPreviewTask?.cancel()
                if hovering {
                    hoverPreviewTask = Task {
                        try? await Task.sleep(nanoseconds: Self.hoverPreviewDelayNanoseconds)
                        guard !Task.isCancelled else { return }
                        isHoveringThumbnail = true
                    }
                } else {
                    hoverPreviewTask = nil
                    isHoveringThumbnail = false
                }
            }
            .popover(isPresented: $isHoveringThumbnail, arrowEdge: .trailing) {
                thumbnailPreviewContent
            }

            ColumnDividerLine(measurementKey: "row:1")
                .offset(x: columnDividerCorrections[1] ?? 0)

            // レイアウト列。
            //
            // .id(...)で、行のpageKeyと現在の値の両方を識別子に含めている。以前はこの識別子が
            // 無く、List(NSTableView backed)がこのMenuスタイルPicker(内部的にはNSPopUpButton)の
            // ビューを行の再利用時に使い回すことがあり、「あるページのレイアウトを変更すると
            // 別のページ(多くは直後の行)の表示だけが変化したように見え、対象のページ自身の
            // 表示は変わらない。レイアウト削除しても表示が更新されない」という不具合が報告された
            // (ユーザー報告)。書き込み先(layoutStore.setPageLayoutState等)のロジック自体は
            // pageKeyを直接指定しており正しいことを確認済みのため、これはAppKit側のビュー再利用に
            // よる表示のstale化が疑わしい。識別子に値まで含めることで、値が変わるたびにこの
            // Pickerを実体ごと作り直させ、再利用によるstale表示の余地を無くす。
            // バグ修正: メニュースタイルのPicker(内部的にはNSPopUpButton)は、項目文字列の
            // 長さによっては.frame(width:)で指定した幅より広い実効幅で描画されることがあり、
            // その分だけ後ろの区切り線・ブックマーク列がタイトル行(columnHeaderRow)とずれて
            // 見えていた(ユーザー報告)。ここでは「HStackのレイアウト計算に使われる幅」を
            // Color.clearの.frame(width:)で厳密にcolumnWidths.layoutへ固定し、実際に見える
            // Pickerはその上に.overlay(alignment: .leading)で重ねることで、Pickerの見た目の
            // 幅がどうであれ、後続の区切り線の位置には一切影響しないようにしている。
            Color.clear
                .frame(width: columnWidths.layout, height: 1)
                .overlay(alignment: .leading) {
                    Picker(
                        selection: Binding<PageLayoutState?>(
                            get: { currentLayoutState },
                            set: { onLayoutStateChange($0) }
                        )
                    ) {
                        Text("No Layout").tag(PageLayoutState?.none)
                        ForEach(PageLayoutState.allCases) { state in
                            Text(state.titleKey).tag(PageLayoutState?.some(state))
                        }
                    } label: {
                        EmptyView()
                    }
                    .id("\(row.pageKey)#\(currentLayoutState?.rawValue ?? "none")")
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(isLayoutLocked)
                }

            ColumnDividerLine(measurementKey: "row:2")
                .offset(x: columnDividerCorrections[2] ?? 0)

            // ブックマーク列。
            if let bookmark {
                HStack(spacing: 4) {
                    Text(bookmark.name)
                        .onTapGesture(count: 2) { onJump() }
                        .onTapGesture(count: 1) { onRenameBookmark(bookmark) }
                    Button {
                        onDeleteBookmark(bookmark)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove Bookmark")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if row.effectiveReadingIndex != nil {
                Button {
                    onAddBookmark()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add Bookmark")
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // 除外ページ(通常の読書フローに存在しないため、ブックマークは追加できない)。
                Text("Excluded (Hidden)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        // 4.3節: 行のドラッグ&ドロップ並べ替え(ForEach.onMove、呼び出し元のpageListContent参照)は、
        // 行のどこを掴んでもSwiftUI/AppKit標準の並べ替えドラッグとして開始できる。以前はここが
        // 単純な.onTapGesture(排他的なジェスチャーとして行全体のヒットテスト領域を占有する)
        // だったため、並べ替えのための掴み始めのドラッグをこのタップジェスチャーが先取りしてしまい、
        // 並べ替え自体が実質的に動作しない不具合があった(ユーザー報告により発覚)。
        // .simultaneousGestureに変更することで、行の選択(タップ)と並べ替え(ドラッグ)の
        // 両方のジェスチャー認識を並行して許可し、実際に動きが伴った場合は並べ替え側が
        // 優先されるようにする。なお.listRowBackground(選択中のハイライト表示)は、この
        // selectableContentではなく呼び出し元(body)の行全体のHStackに掛けている
        // (ドラッグハンドル部分もハイライトの対象に含めるため)。
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
    }

    /// サムネイルをホバーしたときのpopoverの中身。フル解像度画像(previewImage)とファイル名を
    /// 縦に並べる。popoverが実際に画面へ表示されるたびに.taskが実行される(SwiftUIのpopoverは
    /// 表示のたびにコンテンツビューを作り直すため)ので、まだ読み込んでいなければそこで
    /// 読み込む。previewImageは@Stateとして親(PageRowView)側に持たせているため、閉じて
    /// 再度ホバーしても読み込み直さない。
    private var thumbnailPreviewContent: some View {
        VStack(spacing: 8) {
            Group {
                if let previewImage {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            // ユーザー要望により、以前(280x280)よりひとまわり…もうふたまわりほど大きくした。
            .frame(width: 440, height: 440)

            Text(row.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(12)
        .task {
            guard previewImage == nil else { return }
            previewImage = await viewModel.pageImage(rawIndex: row.rawIndex)
        }
    }
}

/// 「ブックマークの編集」ウインドウのトップレベルのコンテンツ。QooViewerApp.swiftの
/// Window("Edit Bookmarks & Layout", id: "editBookmarks")から引数なしで呼ばれるため、
/// 実際に必要なBookmarkStore/LayoutStore/AppPreferencesは環境値経由で受け取る。
struct BookmarkEditorWindow: View {
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore

    var body: some View {
        BookmarkEditorView(bookmarkStore: bookmarkStore, layoutStore: layoutStore)
    }
}

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

/// 値の変更をアニメーション無しで反映するようにラップしたBindingを返す。
///
/// 経緯(ユーザー報告): 並べ替え・絞り込みのドロップダウンで項目を選ぶと、「もたつく」というより
/// 「何かアニメーション的な効果がわずかに入っている」ように見える、との指摘。
/// これらのドロップダウンを操作すると一覧の行の順序や件数が変わるが、SwiftUIのListは行の
/// 移動・挿入・削除を既定でアニメーションする(内部のNSTableViewのアニメーション付き行操作)。
/// メニューが閉じた直後に行が動くため、メニューが尾を引いて残っているようにも見えていた。
///
/// 並べ替え・絞り込みは結果を即座に見たい操作で、行が動く様子を見せる必要は無いため、
/// この変更に限ってアニメーションを止める(明示的な.animation()指定はこのウインドウには
/// 元々無く、SwiftUIの既定動作を抑えるだけ)。
@MainActor
private func withoutAnimation<Value>(_ binding: Binding<Value>) -> Binding<Value> {
    Binding(
        get: { binding.wrappedValue },
        set: { newValue in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                binding.wrappedValue = newValue
            }
        }
    )
}

/// 左ペインの一覧が画面上のどの矩形を占めているかを知るための、透明なNSView1枚の入れ物。
/// ダブルクリック検知(BookmarkEditorViewのinstallDoubleClickMonitor)が、「そのクリックが
/// 左ペインの一覧の中で起きたのか」を判定するために使う。
///
/// 当初はこのビューのenclosingScrollViewから一覧のNSScrollViewを取ろうとしたが、
/// `.background()`で付けたビューはListの内側(スクロールビューの中)ではなく外側に載るため
/// 常にnilになり、ダブルクリックが一度も成立しなかった(ユーザー報告)。スクロールビューに
/// 頼らず、このビュー自身のウインドウ座標での矩形と、クリック位置を突き合わせる方式にしてある。
@MainActor
private final class ListAnchorBox {
    weak var view: NSView?

    /// この一覧がウインドウ座標系で占めている矩形(取得できなければnil)。
    var frameInWindow: NSRect? {
        guard let view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }
}

/// 上のListAnchorBoxへ、実際に配置されたNSViewを渡すためだけのNSViewRepresentable。
///
/// 行ごとではなくList全体に1枚だけ置くので、コストは無視できる(かつて右ペインのレイアウト列で
/// 行ごとにNSViewRepresentableを敷いてしまい、レイアウトコストが問題になったことがある。
/// PageLayoutStateMenuButtonのコメント参照)。
private struct ListAnchorAccessor: NSViewRepresentable {
    let box: ListAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

/// カーソルキーの上下で一覧の選択を1つ動かすときの、移動先のインデックスを求める。
/// 左ペイン(本の一覧)と右ペイン(ページの一覧)の両方から使う共通処理。
///
/// - 何も選択していない状態で↓なら先頭、↑なら末尾を選ぶ(macOSの一般的な一覧の挙動)。
/// - 端に達している場合はnilを返し、呼び出し側は何もしない(反対側へは回り込まない)。
///
/// ユーザー要望: 左右ペインで本・ページを選択している状態から、カーソルキーの上下で選択を
/// 移動できるようにしたい(マウスのクリック処理が遅いのか、選択の切り替え自体が遅いのかを
/// 切り分けたいという目的も含む)。
private func nextSelectionIndex(
    for direction: MoveCommandDirection, currentIndex: Int?, count: Int
) -> Int? {
    guard count > 0 else { return nil }
    switch direction {
    case .up:
        guard let currentIndex else { return count - 1 }
        return currentIndex > 0 ? currentIndex - 1 : nil
    case .down:
        guard let currentIndex else { return 0 }
        return currentIndex < count - 1 ? currentIndex + 1 : nil
    default:
        // 左右方向はこの一覧では使わない(将来SwiftUIが他の方向を追加した場合も無視する)。
        return nil
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

    /// 表示用の本の名前(BookmarkBookGroup.displayNameと同じ生成規則)。
    /// あちらと同じ理由で、参照のたびに生成する計算プロパティではなく、行を作る時点で1回だけ
    /// 計算して保持する(この値はfilteredSortedRowsの絞り込み・並べ替えの比較関数から読まれる
    /// ため、計算プロパティのままだと1回のソートでO(N log N)回ぶんのURL構築が発生していた)。
    let displayName: String

    var id: String { bookID }

    init(bookID: String, bookmarkCount: Int, hasLayoutData: Bool, earliestDate: Date, latestDate: Date) {
        self.bookID = bookID
        self.bookmarkCount = bookmarkCount
        self.hasLayoutData = hasLayoutData
        self.earliestDate = earliestDate
        self.latestDate = latestDate
        self.displayName = URL(fileURLWithPath: bookID).deletingPathExtension().lastPathComponent
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
    /// ファイル名のダブルクリックで本を開く機能(ユーザー要望)のための、NSEventローカルモニタの
    /// トークン。なぜSwiftUIのジェスチャーではなくこの方式なのかは、installDoubleClickMonitor()の
    /// コメント参照。
    @State private var doubleClickMonitor: Any?
    /// 上のモニタが「この一覧の中で起きたクリックか」を判定するために使う、一覧の矩形。
    @State private var listAnchorBox = ListAnchorBox()
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
    /// ユーザー要望: 左ペインの右クリックメニューにあった「ブックマークを全削除」
    /// 「レイアウトを全削除」は別々の2項目に見えて分かりづらい・押し間違えやすいとのことで、
    /// 「ブックマークおよびレイアウトを全削除」の1項目に統合した(右ペインの「一括操作…」
    /// メニューには、既存の個別2項目に加えてこの統合版も追加した)。この確認ダイアログの対象bookID。
    @State private var pendingDeleteBookmarksAndLayoutBookID: String?

    /// ユーザー要望: 左ペインでファイル名をダブルクリックしたら、その本を開く。
    /// BookmarkDetailPane.editorWindow/openErrorBookNameと同じ役割・同じ仕組み(このView自身も
    /// 同じNSWindow上にあるため、独自にWindowAccessorで取得する)。
    /// 予防: NSWindowは強参照で持たない(ViewerView.WeakWindowBoxのコメント参照)。
    @State private var editorWindowBox = WeakWindowBox()
    private var editorWindow: NSWindow? { editorWindowBox.window }
    @State private var openErrorBookName: String?

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

    /// ユーザー要望「左ペインでファイル名をダブルクリックしたら、その本を開く」を、SwiftUIの
    /// ジェスチャーを一切使わずに実現する。
    ///
    /// 経緯(ユーザー報告「左ペインのクリックが、たまに・ランダムに反応しない」の真因と対策):
    /// 行(セル)の中にSwiftUIのジェスチャーを置くと、そのジェスチャーがマウスダウンを掴んでしまい、
    /// 下にあるNSTableViewが行選択のトラッキングを開始できなくなる。ファイル名の文字幅は本ごとに
    /// 違うため、クリックが文字の上に乗ったときだけ選択が効かず「ランダムに反応しない」ように
    /// 見えていた。
    ///
    /// 計装して切り分けた結果は明確だった(成功時はマウスアップがローカルモニタを素通りしない=
    /// テーブルがトラッキングに入って消費している。失敗時は素通りする=入っていない)。
    /// ジェスチャーの種類の問題ではなく、セル内にジェスチャーが在ること自体が原因で、
    /// TapGesture→DragGesture(minimumDistance: 0)→onTapGesture(count: 2)のいずれでも再現した。
    /// 最終的にセル内のジェスチャーを完全に取り除いたところ、取りこぼしはゼロになった
    /// (実測: 18回クリックして取りこぼし0回。それ以前は34回中15回が取りこぼし)。
    ///
    /// そのため、ダブルクリックの検知はSwiftUIの外(NSEventのローカルモニタ)で行う。
    /// 開く対象は「今選択されている本」でよい。ダブルクリックの1回目のクリックで、
    /// NSTableViewが既にその行を選択し終えているため。
    private func installDoubleClickMonitor() {
        guard doubleClickMonitor == nil else { return }
        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard event.clickCount == 2,
                  let listFrame = listAnchorBox.frameInWindow,
                  listAnchorBox.view?.window === event.window,
                  listFrame.contains(event.locationInWindow),
                  let hitView = event.window?.contentView?.hitTest(event.locationInWindow)
            else { return event }
            // 行の無い余白をダブルクリックしただけで開いてしまわないよう、実際に行の上かを
            // 確かめる。SwiftUIのListの実体はNSTableViewのサブクラス(公開API)なので、
            // クリック位置の祖先をたどって見つけ、row(at:)で判定できる(行の上でなければ-1)。
            var tableView: NSTableView?
            var current: NSView? = hitView
            while let view = current {
                if let table = view as? NSTableView {
                    tableView = table
                    break
                }
                current = view.superview
            }
            guard let tableView else { return event }
            let pointInTable = tableView.convert(event.locationInWindow, from: nil)
            guard tableView.row(at: pointInTable) >= 0 else { return event }
            if let bookID = selectedBookID {
                openBook(bookID: bookID)
            }
            return event
        }
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
                Button("Add This Page to Bookmarks") {
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
                // バグ修正(ユーザー報告: 左ペインのクリックが、たまに・ランダムに反応しない):
                // 以前この一覧は、Listのネイティブな選択を使わず、各行に付けた自前の
                // .simultaneousGesture(TapGesture)でselectedBookIDを書き換え、ハイライトも
                // .listRowBackgroundで自前に描いていた。SwiftUIのジェスチャーは成立条件
                // (押してから離すまでの移動量など)や他のジェスチャー(ファイル名の
                // ダブルクリック検知・.contextMenu)との調停に左右されるため、取りこぼしが起きる。
                // TapGestureをDragGesture(minimumDistance: 0)へ変えても解消しなかったため、
                // 自前のジェスチャーによる選択自体をやめ、List(selection:)へ移した。
                // NSTableViewがマウスダウンの時点で選択を確定するため、構造的に取りこぼしが
                // 起きなくなる(カーソルキーでの移動もネイティブに付いてくる)。
                //
                // selectionには、素のselectedBookIDではなくeffectiveSelectedBookID
                // (フィルタで消えた場合や未選択時に「今開いている本」「先頭の行」へ
                // フォールバックする)を読ませ、書き込みだけをselectedBookIDへ返す。
                // これにより、右ペインに表示している本と左ペインのハイライトが常に一致する
                // (自前の.listRowBackgroundで実現していたのと同じ挙動)。
                // バグ修正(ユーザー報告): 選択(selectedBookID)は今読んでいる本へ正しく
                // 再同期されるようになったが、一覧をスクロールして既に別の位置を見ている場合、
                // その選択された行が画面外のままだった。ScrollViewReaderで囲み、選択が
                // 変わるたびに該当行までスクロールする。
                ScrollViewReader { proxy in
                List(selection: Binding(
                    get: { selectedID },
                    set: { newValue in
                        // 空白部分のクリックなどで選択が外れた場合(nil)は、直前の選択を
                        // 保持したままにする(右ペインの表示が消えてしまうのを避けるため)。
                        guard let newValue else { return }
                        selectedBookID = newValue
                    }
                )) {
                    ForEach(rows) { row in
                        let isOpen = launchCoordinator.openAppState(forBookID: row.bookID) != nil
                        HStack {
                            Image(systemName: isOpen ? "book.fill" : "book.closed")
                                .foregroundStyle(isOpen ? Color.accentColor : Color.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(row.displayName)
                                        .fontWeight(isOpen ? .semibold : .regular)
                                        // ユーザー要望: ファイル名をダブルクリックしたら、その本を開く。
                                        //
                                        // 経緯(ユーザー報告「左ペインのクリックが、たまに・ランダムに
                                        // 反応しない」の真因): かつてここは.onTapGesture(count: 2)
                                        // だったが、当時は行の選択も自前のクリック回数1の
                                        // ジェスチャーで行っており、クリック回数の異なるジェスチャーが
                                        // 同居すると選択のハイライトがダブルクリック間隔だけ遅延した。
                                        // そのため「クリック回数1のジェスチャー+自前の時刻比較」で
                                        // ダブルクリックを判定する方式に変えていた。
                                        //
                                        // しかしこの方式(TapGesture、のちにDragGesture(minimumDistance: 0))は
                                        // セル内のSwiftUIビューでマウスダウンを掴んでしまうため、
                                        // その下にあるNSTableViewが行選択のトラッキングを開始できなく
                                        // なる。ファイル名の文字幅は行ごとに違うので、クリック位置が
                                        // 文字の上に乗ったときだけ選択が効かず、「ランダムに反応しない」
                                        // ように見えていた(計装して実測: 失敗した回はマウスアップが
                                        // ローカルモニタを素通りする=テーブルがトラッキングに入って
                                        // いない。成功した回はテーブルがマウスアップを消費するため
                                        // 素通りしない、という違いで判別できた)。
                                        //
                                        // 選択をList(selection:)のネイティブ実装へ移した結果、
                                        // ハイライトはマウスダウンの時点でNSTableViewが確定させるように
                                        // なり、上記「遅延する」という当初の問題は起きなくなった。
                                        // そのため素直な.onTapGesture(count: 2)へ戻せる。
                                        // ここには絶対にジェスチャー(.onTapGesture/.gesture/
                                        // .simultaneousGesture)を付けないこと。セル内にSwiftUIの
                                        // ジェスチャーがあると、それがマウスダウンを掴んでしまい、
                                        // 下のNSTableViewが行選択を開始できなくなる(クリックが
                                        // ランダムに効かなくなる)。ファイル名のダブルクリックで
                                        // 本を開く機能は、SwiftUIの外(installDoubleClickMonitor)で
                                        // 実装してある。詳細はそちらのコメント参照。
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
                        // List(selection:)にこの行を識別させる。選択・ハイライト・カーソルキーでの
                        // 移動はすべてListがネイティブに面倒を見る(上のList(selection:)のコメント参照)。
                        .tag(row.bookID)
                        .help(row.displayName)
                        // 4.4節: 左ペインの本を右クリックしたメニュー(その本を選択した状態で
                        // 実行したのと同じ扱い。現在の選択状態を変えずに、右クリックしたbookIDへ
                        // 直接作用させる)。
                        //
                        // ユーザー要望: 以前はここに「一括リネーム」「ブックマークを全削除」
                        // 「レイアウトを全削除」の3項目があったが、
                        // 1. 「一括リネーム」はこのメニューでは使用頻度が低く、右ペイン上部の
                        //    「一括操作…」メニュー(Menu("Bulk Operations…"))から呼べれば十分、
                        // 2. 「ブックマークを全削除」「レイアウトを全削除」は別々の2項目に
                        //    分かれていると分かりづらい・押し間違えやすい、
                        // との報告を受け、このメニューからは「一括リネーム」を削除し、削除系の
                        // 2項目は「ブックマークおよびレイアウトを全削除」の1項目へ統合した。
                        .contextMenu {
                            Button("Delete All Bookmarks and Layouts…", role: .destructive) {
                                pendingDeleteBookmarksAndLayoutBookID = row.bookID
                            }
                            .disabled(row.bookmarkCount == 0 && !row.hasLayoutData)
                        }
                    }
                }
                // 一覧のNSScrollViewを掴むための土台(List全体に1枚だけ。
                // installDoubleClickMonitor()が「このクリックは一覧の中か」を判定するのに使う)。
                .background(ListAnchorAccessor(box: listAnchorBox))
                .listStyle(.sidebar)
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 6) {
                        HStack {
                            Picker(selection: withoutAnimation($bookFilter)) {
                                ForEach(EditorBookFilter.allCases) { filter in
                                    Text(filter.titleKey).tag(filter)
                                }
                            } label: {
                                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                            }
                            .pickerStyle(.menu)
                            .fixedSize()

                            Spacer()

                            Picker(selection: withoutAnimation($bookmarkStore.bookSortOption)) {
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
                // カーソルキーの上下での選択移動(ユーザー要望)は、List(selection:)へ移した
                // 時点でListがネイティブに面倒を見るようになったため、以前ここにあった
                // .focusable()/.focused()/.onMoveCommandの自前実装は取り除いた
                // (Listに.focusable()を重ねると、List自身のフォーカス処理と競合しうる。
                // 右ペインのページ一覧は選択がネイティブではないため、あちらには自前の
                // 実装が残っている。pageListContentのコメント参照)。
                .navigationTitle("Bookmarks & Layout")
                .navigationSplitViewColumnWidth(min: 220, ideal: sidebarWidth, max: 560)
                .onAppear {
                    installDoubleClickMonitor()
                    guard !hasComputedSidebarWidth else { return }
                    hasComputedSidebarWidth = true
                    sidebarWidth = SidebarWidthEstimator.idealWidth(
                        forNames: mergedRows.map(\.displayName)
                    )
                    applyInitialFocus(launchCoordinator.pendingEditorInitialFocus)
                    // ウインドウを初めて開いたときも、既に選択されている行(今読んでいる本)まで
                    // スクロールしておく。Listの行がまだ実際に配置される前のタイミングでは
                    // scrollTo(_:)が効かないことがあるため、次のランループまで待つ
                    // (WindowAccessorなど、このファイルの他の箇所と同じ理由)。
                    if let selectedID {
                        DispatchQueue.main.async {
                            proxy.scrollTo(selectedID, anchor: .center)
                        }
                    }
                }
                .onDisappear {
                    if let doubleClickMonitor {
                        NSEvent.removeMonitor(doubleClickMonitor)
                    }
                    doubleClickMonitor = nil
                }
                .onChange(of: launchCoordinator.pendingEditorInitialFocus) { _, newValue in
                    // applyInitialFocus自身が末尾でpendingEditorInitialFocusをnilへ戻すため
                    // (次回も確実に変化として検知させるため。applyInitialFocusのコメント参照)、
                    // そのnilへの遷移自体でこのonChangeが再度呼ばれてしまう。newValueがnilの
                    // ときは「applyInitialFocusが今まさに戻した直後」であり、新しい呼び出し
                    // 要求ではないため、ここで無視する。
                    guard let newValue else { return }
                    applyInitialFocus(newValue)
                }
                .onChange(of: selectedID) { _, newValue in
                    // selectedBookIDがapplyInitialFocusなどで書き換わり、結果としてこの一覧の
                    // 選択行(ハイライト)が変わったときに、その行までスクロールする
                    // (withoutAnimationと同じ理由で、行が動く様子を見せる必要は無いため
                    // アニメーションは付けない)。
                    guard let newValue else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
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
                        pendingDeleteLayoutBookID: $pendingDeleteLayoutBookID,
                        pendingDeleteBookmarksAndLayoutBookID: $pendingDeleteBookmarksAndLayoutBookID
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
            // バグ修正: 右ペインの「読み方向」ピッカー・「一括操作…」ボタン・絞り込みピッカーなど、
            // 上段に横並びになる項目が、以前の右ペイン最小幅(400)だと窮屈になり、環境によっては
            // ラベルが省略記号で切れて見えることがあった(ユーザー報告)。480へ広げることで
            // 余裕を持たせる。
            .frame(minWidth: max(640, sidebarWidth + 480), minHeight: 420)
            // バグ修正: 以前は.alert + TextField(NSAlertが内部で使うテキストフィールド)だったが、
            // 開いた瞬間に既存の名前が全選択された状態になるかどうかが不安定だった
            // (ユーザー報告)。加えて、同じブックマークを続けてリネームすると入力欄が空のまま
            // 表示される不具合もあった(onRenameBookmarkのコメント参照。以前はrenameTextを
            // 一度空文字にしてから設定し直す、という回避策で対応していた)。
            // .sheetは表示のたびにコンテンツビュー階層(=SelectAllTextFieldが包むNSTextFieldも
            // 含む)を新規に作り直すため、どちらの問題も構造的に解消できる
            // (SelectAllTextField.makeNSViewが呼ばれるたびに、そのときのrenameTextの値で
            // 新しいNSTextFieldが作られ、必ず全選択状態でフォーカスされる)。
            .sheet(
                isPresented: Binding(
                    get: { renamingBookmark != nil },
                    set: { isPresented in if !isPresented { renamingBookmark = nil } }
                )
            ) {
                BookmarkRenameSheet(
                    text: $renameText,
                    onSave: {
                        if let bookmark = renamingBookmark {
                            bookmarkStore.rename(bookmark, to: renameText)
                        }
                        renamingBookmark = nil
                    },
                    onCancel: {
                        renamingBookmark = nil
                    }
                )
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
            // ユーザー要望「ブックマークおよびレイアウトを全削除」の確認。左ペインの
            // 右クリックメニュー、右ペインの「一括操作…」メニューの両方から呼ばれる
            // (pendingDeleteBookmarksAndLayoutBookIDのコメント参照)。実行内容は、上の
            // 「ブックマークを全削除」「レイアウトを全削除」それぞれの削除ロジックを
            // そのまま両方呼ぶだけ(新しい削除ロジック自体は追加していない)。
            .alert(
                "Delete All Bookmarks and Layouts?",
                isPresented: Binding(
                    get: { pendingDeleteBookmarksAndLayoutBookID != nil },
                    set: { isPresented in if !isPresented { pendingDeleteBookmarksAndLayoutBookID = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { pendingDeleteBookmarksAndLayoutBookID = nil }
                Button("Delete", role: .destructive) {
                    if let bookID = pendingDeleteBookmarksAndLayoutBookID {
                        bookmarkStore.deleteAllBookmarks(forBookID: bookID)
                        layoutStore.discardLayoutData(forBookID: bookID)
                    }
                    pendingDeleteBookmarksAndLayoutBookID = nil
                    // 上のブックマーク全削除・レイアウト全削除と同じ理由(ユーザー要望)。
                    bookFilter = .all
                }
            } message: {
                Text("This permanently deletes every bookmark and every layout setting (reading direction, page order, single/spread page settings) in this book. This cannot be undone.")
            }
            // 4.4節「一括リネーム」。5節の一括リネームウインドウを開く。
            .onChange(of: pendingBulkRenameBookID) { _, newValue in
                guard let bookID = newValue else { return }
                launchCoordinator.pendingBulkRenameBookID = bookID
                openWindow(id: "bulkRenameBookmarks")
                pendingBulkRenameBookID = nil
            }
            // ユーザー要望: 左ペインでファイル名をダブルクリックしたら、その本を開く(openBook参照)。
            // BookmarkDetailPaneの同種のWindowAccessor/アラートと同じ仕組み。
            .background(WindowAccessor { window in
                editorWindowBox.window = window
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
            } else {
                switch focus {
                case .bookmarks: bookFilter = .hasBookmarks
                case .layout: bookFilter = .hasLayout
                case nil: break
                }
            }
            // バグ修正(ユーザー報告): ブックマークがある本を表示している状態で「ブックマークの
            // 編集」を呼び出しても、開いている本が選択された状態にならなかった。selectedBookIDは
            // このウインドウを閉じても(単一インスタンスのWindowシーンのため)保持され続けるため、
            // 以前別の本を選んでいた場合はそのまま残ってしまっていた。呼び出しのたびに、今
            // 読んでいる本へ選択を明示的に合わせ直す(mergedRowsはactiveBookAppStateの本を
            // 常に含めるため、フィルタが.hasBookmarks/.hasLayoutのどちらであっても行は必ず存在する)。
            selectedBookID = activeBookID
        } else {
            switch focus {
            case .bookmarks:
                bookFilter = .hasBookmarks
            case .layout:
                bookFilter = .hasLayout
            case nil:
                break
            }
        }
        // pendingEditorInitialFocusを都度nilへ戻す。Windowシーンは単一インスタンスのため
        // 値渡しではなくこの共有オブジェクト経由で伝えている都合上(EditorInitialFocusの
        // コメント参照)、同じ種類(例: 連続して2回「ブックマークの編集」を呼び出す)だと
        // SwiftUIの.onChangeが値の変化を検知できず、2回目以降はこのメソッド自体が
        // 呼ばれなくなってしまう(上のselectedBookID再同期が効かなくなる、まさに今回の不具合の
        // 原因の一つ)。都度nilに戻しておくことで、次にどの値が来ても必ず変化として検知される。
        launchCoordinator.pendingEditorInitialFocus = nil
    }

    /// ユーザー要望: 左ペインでファイル名をダブルクリックしたら、その本を開く。
    /// BookmarkDetailPane.openBookAndJump(toPageIndex:)と同じ「既存のウインドウ/タブがあれば
    /// それを前面に出す・無ければ既存のフロントウインドウで開くか新規ウインドウを作る」という
    /// 分岐を踏襲するが、こちらは特定のページへジャンプする必要が無いぶん単純になっている。
    private func openBook(bookID: String) {
        if let existingAppState = launchCoordinator.openAppState(forBookID: bookID) {
            existingAppState.hostWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            closeEditorWindow()
            return
        }

        guard let url = bookmarkStore.resolvedURLFromBookmarkData(forBookID: bookID)
            ?? layoutStore.resolvedURL(forBookID: bookID)
        else {
            openErrorBookName = URL(fileURLWithPath: bookID).deletingPathExtension().lastPathComponent
            return
        }
        _ = url.startAccessingSecurityScopedResource()

        if let targetAppState = launchCoordinator.frontmostContentAppState() {
            targetAppState.open(url: url)
        } else {
            openWindow(id: "book", value: url)
        }
        closeEditorWindow()
    }

    private func closeEditorWindow() {
        editorWindow?.close()
    }
}

/// ブックマークのリネーム用シート(bodyの.sheetのコメント参照)。
/// 既存の名前が入った状態で開き、SelectAllTextField(下記)により必ず全選択状態で
/// フォーカスされる。ユーザーはそのまま打ち直すか、Backspaceで消してからCmd+Vで
/// ペーストする、といった操作をすぐに行える(ユーザー要望)。
private struct BookmarkRenameSheet: View {
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Bookmark")
                .font(.headline)
            SelectAllTextField(text: $text, onSubmit: onSave)
                .frame(height: 22)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// NSTextFieldをラップし、表示開始時に必ず内容を全選択した状態でフォーカスを当てる
/// テキストフィールド(BookmarkRenameSheet専用)。
///
/// SwiftUIの`TextField`には「表示時に内容を全選択状態にする」ための標準APIが無く、
/// `.alert`内の`TextField`(NSAlertが内部で使うテキストフィールド)は特に選択状態の
/// 制御が効かないことがある(ユーザー報告: 開いたときに全選択されていたりされて
/// いなかったりする)。AppKitの`NSTextField`を直接ラップし、
/// `currentEditor()?.selectAll(nil)`を呼ぶことで確実に全選択状態にする。
private struct SelectAllTextField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingTail
        // WindowAccessor(ViewerView.swift)と同じ理由: このNSViewがまだウインドウに
        // 追加される前のタイミングではfield.windowがnilなので、次のランループまで待ってから
        // ファーストレスポンダにする。selectAll(nil)は「テキスト編集中の選択範囲」を操作する
        // APIのため、先にcurrentEditor()が存在する状態(=ファーストレスポンダになった状態)を
        // 作ってから呼ぶ必要がある。
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: SelectAllTextField
        init(_ parent: SelectAllTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Return(改行)キーで確定(Save)できるようにする。TextField(SwiftUI)の
        /// .onSubmitに相当する挙動をNSTextFieldDelegate経由で実現する。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
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
    @Binding var pendingDeleteBookmarksAndLayoutBookID: String?

    @StateObject private var viewModel: BookLayoutEditorViewModel

    // 既定値は無くしてある(initで必ずinitialPageFilterから明示的に初期化するため)。
    @State private var pageFilter: EditorPageFilter
    @State private var selectedPageKey: String?
    /// カーソルキーの上下を受け取るために、この一覧自身がフォーカスを持っているかどうか。
    /// 行をクリックしたとき(List(selection:)のsetter)にも明示的にtrueにして、
    /// クリック→そのままキー操作、と続けられるようにする。
    @FocusState private var isPageListFocused: Bool
    /// ダブルクリックでのジャンプ用のNSEventローカルモニタ(installDoubleClickMonitor参照)と、
    /// 「そのクリックがこの一覧の中か」を判定するための一覧の矩形。
    @State private var doubleClickMonitor: Any?
    @State private var listAnchorBox = ListAnchorBox()
    @State private var openErrorBookName: String?
    /// 予防: NSWindowは強参照で持たない(ViewerView.WeakWindowBoxのコメント参照)。
    @State private var editorWindowBox = WeakWindowBox()
    private var editorWindow: NSWindow? { editorWindowBox.window }
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
        pendingDeleteLayoutBookID: Binding<String?>,
        pendingDeleteBookmarksAndLayoutBookID: Binding<String?>
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
        _pendingDeleteBookmarksAndLayoutBookID = pendingDeleteBookmarksAndLayoutBookID
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
        .onAppear {
            installDoubleClickMonitor()
        }
        .onDisappear {
            if let doubleClickMonitor {
                NSEvent.removeMonitor(doubleClickMonitor)
            }
            doubleClickMonitor = nil
        }
        .navigationTitle("Bookmarks & Layout")
        .background(WindowAccessor { window in
            editorWindowBox.window = window
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

    /// ページ行のダブルクリックで、その本を開いてそのページへジャンプする(ユーザー要望)。
    /// 左ペインのBookmarkEditorView.installDoubleClickMonitor()と同じ方式・同じ理由
    /// (セル内にSwiftUIのジェスチャーを置けないため、SwiftUIの外で検知する)。
    /// ジャンプ先は「今選択されているページ」でよい。ダブルクリックの1回目のクリックで、
    /// NSTableViewが既にその行を選択し終えているため。
    private func installDoubleClickMonitor() {
        guard doubleClickMonitor == nil else { return }
        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard event.clickCount == 2,
                  let listFrame = listAnchorBox.frameInWindow,
                  listAnchorBox.view?.window === event.window,
                  listFrame.contains(event.locationInWindow),
                  let hitView = event.window?.contentView?.hitTest(event.locationInWindow)
            else { return event }
            var tableView: NSTableView?
            var current: NSView? = hitView
            while let view = current {
                if let table = view as? NSTableView {
                    tableView = table
                    break
                }
                current = view.superview
            }
            guard let tableView else { return event }
            let pointInTable = tableView.convert(event.locationInWindow, from: nil)
            guard tableView.row(at: pointInTable) >= 0 else { return event }
            if let selectedPageKey,
               let row = displayedRows.first(where: { $0.pageKey == selectedPageKey }) {
                openBookAndJump(toPageIndex: row.effectiveReadingIndex)
            }
            return event
        }
    }

    /// カーソルキーの上下で、右ペインのページ選択を1つ動かす(nextSelectionIndexのコメント参照)。
    /// 移動先が画面外にある場合に備えてスクロールも追従させる。
    private func movePageSelection(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let rows = displayedRows
        let currentIndex = selectedPageKey.flatMap { key in rows.firstIndex { $0.pageKey == key } }
        guard let target = nextSelectionIndex(
            for: direction, currentIndex: currentIndex, count: rows.count
        ) else { return }
        selectedPageKey = rows[target].pageKey
        proxy.scrollTo(rows[target].pageKey)
    }

    /// カーソルキーの上下で選択を移動できるようにするための包み。実体は下のpageList。
    /// ScrollViewReaderは、選択が画面外へ出たときに追従させるために必要
    /// (この一覧はListなので、行のIDはRow.id = pageKey)。
    private var pageListContent: some View {
        ScrollViewReader { proxy in
            pageList
                // 一覧の矩形を掴むための土台(List全体に1枚だけ)。installDoubleClickMonitor()が
                // 「このクリックは一覧の中か」を判定するのに使う。
                .background(ListAnchorAccessor(box: listAnchorBox))
                .focusable()
                .focused($isPageListFocused)
                // 左ペイン(moveBookSelection)は.onMoveCommandで動作するが、こちらは動作しない
                // (ユーザー報告: 右ペインだけカーソルキーで移動できない)。右ペインの行には
                // ボタン(レイアウト列のメニュー、ブックマークの追加・削除)が含まれており、
                // フォーカスが行内のボタン側にあると、一覧側の.onMoveCommandまで届かないため。
                // キー入力はフォーカスされたビューから親へ伝播するので、.onKeyPressなら
                // 行内のボタンにフォーカスがあっても受け取れる。
                .onKeyPress(.upArrow) {
                    movePageSelection(.up, proxy: proxy)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    movePageSelection(.down, proxy: proxy)
                    return .handled
                }
        }
    }

    private var pageList: some View {
        // この本のブックマークを、ページ番号(Bookmark.pageIndex)で引ける辞書としてbodyの評価ごとに
        // 1回だけ用意する(左ペインのfilteredSortedRows/effectiveSelectedBookIDと同じ考え方。
        // bodyのコメント参照)。
        //
        // 経緯(ユーザー報告 + sampleによる実測): 以前はForEachの各行の中で
        // bookmarkStore.bookmarks(forBookID:)を直接呼び、その結果を.first{ $0.pageIndex == index }で
        // 線形探索していた。bookmarks(forBookID:)は呼ばれるたびにこの本のブックマーク全件の
        // 絞り込みとソートを行い、しかも既定の並び(名前順)ではlocalizedStandardCompare
        // (ロケール照合。単純な文字列比較よりはるかに重い)を使う。これがページ数ぶん繰り返される
        // ため、ページ数×ブックマーク数のコストが「この一覧が再描画されるたび」に丸ごと
        // メインスレッドへ乗っていた(左ペインで本を選んだ直後に、すぐ別の本へ切り替えられない
        // 症状の主因。sampleで採取したメインスレッドのスタックで、アプリ側の処理として最大の
        // 山になっていた)。
        //
        // uniquingKeysWithで先勝ちにしているのは、同じpageIndexに複数のブックマークがある
        // (通常は重複防止されるが、JSONインポート等で生じうる)場合に、従来の
        // 「ソート済み配列の.first」と同じものを選ぶため。
        let bookmarksByPageIndex = Dictionary(
            bookmarkStore.bookmarks(forBookID: bookID).map { ($0.pageIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // 左ペインと同じ理由(セル内のSwiftUIジェスチャーがマウスダウンを掴み、NSTableViewが
        // 行選択を開始できなくなる。PageRowView.selectableContentのコメント参照)で、選択は
        // List(selection:)のネイティブ実装に任せる。
        return List(selection: Binding(
            get: { selectedPageKey },
            set: { newValue in
                // 余白のクリックなどで選択が外れた場合(nil)は、直前の選択を保持する
                // (ページ一覧下部のボタンがselectedPageKey != nilを前提に有効化されるため)。
                guard let newValue else { return }
                selectedPageKey = newValue
                isPageListFocused = true
            }
        )) {
            ForEach(displayedRows) { row in
                PageRowView(
                    row: row,
                    viewModel: viewModel,
                    bookID: bookID,
                    bookmark: row.effectiveReadingIndex.flatMap { bookmarksByPageIndex[$0] },
                    columnWidths: columnWidths,
                    columnDividerCorrections: columnDividerCorrections,
                    isMoveEnabled: pageFilter == .all,
                    onJump: { openBookAndJump(toPageIndex: row.effectiveReadingIndex) },
                    onAddBookmark: { addBookmark(atPageIndex: row.effectiveReadingIndex) },
                    onRenameBookmark: { bookmark in
                        // バグ修正: 以前は.alert + TextField(NSAlertが内部で使うテキストフィールド)
                        // 実装だったため、SwiftUIの@Stateが「代入する値が現在の値と同じ場合は
                        // 再描画・反映を省略する」性質と衝突し、同じブックマークを続けてリネーム
                        // すると入力欄が空のまま表示される不具合があった(ユーザー報告。renameTextを
                        // 一度空文字にしてから設定し直す、という回避策で対応していた)。
                        // 呼び出し先が.sheet(BookmarkRenameSheet、bodyのコメント参照)に変わり、
                        // 表示のたびにNSTextFieldそのものを新規に作り直すようになったため、
                        // この回避策は不要になった(renameTextの値が前回と同じであっても、
                        // SelectAllTextField.makeNSViewがそのときの値でNSTextFieldを作るため、
                        // 常に正しい名前が表示・全選択される)。
                        renameText = bookmark.name
                        renamingBookmark = bookmark
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
            .moveDisabled(pageFilter != .all)
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
                    .disabled(selectedPageKey == nil)
                    .help("Move Selected Page Earlier")

                    Button {
                        movePageDown()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(selectedPageKey == nil)
                    .help("Move Selected Page Later")

                    Group {
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

                        // ユーザー要望: 「一括リネーム」と「ブックマークを全削除」の間に
                        // 区切り線を追加(リネーム系と削除系のグループを視覚的に分ける)。
                        Divider()

                        Button("Delete All Bookmarks…", role: .destructive) {
                            pendingDeleteBookmarksBookID = bookID
                        }
                        .disabled(bookmarkStore.bookmarks(forBookID: bookID).isEmpty)

                        Button("Delete All Layout Info…", role: .destructive) {
                            pendingDeleteLayoutBookID = bookID
                        }
                        .disabled(!layoutStore.layoutBookIDs.contains(bookID))

                        // ユーザー要望: 左ペインの右クリックメニューに追加した「ブックマークおよび
                        // レイアウトを全削除」(pendingDeleteBookmarksAndLayoutBookIDのコメント参照)を、
                        // こちらの「一括操作…」メニューにも追加してほしいとのことで追加した。
                        // 上の個別2項目(ブックマークのみ/レイアウトのみを削除)はそのまま残している。
                        Button("Delete All Bookmarks and Layouts…", role: .destructive) {
                            pendingDeleteBookmarksAndLayoutBookID = bookID
                        }
                        .disabled(bookmarkStore.bookmarks(forBookID: bookID).isEmpty && !layoutStore.layoutBookIDs.contains(bookID))

                        // ユーザー要望: 区切り線は削除系3項目(ブックマークを全削除/レイアウトを
                        // 全削除/ブックマークおよびレイアウトを全削除)の直後、「表示順(ページ順)を
                        // 初期化する」の直前へ移動(以前は削除系の1項目目と2項目目の間にあった)。
                        Divider()

                        // 4.3節「ページ順を初期化する」。使用頻度が低い操作のため、このメニューの
                        // 最後尾に置いている(ユーザー要望)。カスタム並び替え(pageOrderOverride)が
                        // 無い(既に自然順のまま)場合は押しても意味が無いため無効化する。
                        Button("Reset Page Order") {
                            viewModel.resetOrder()
                        }
                        .disabled(layoutStore.bookLayoutSettings(forBookID: bookID)?.pageOrderOverride == nil)
                    } label: {
                        Label("Bulk Operations…", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.button)

                    Spacer()

                    Picker(selection: withoutAnimation($pageFilter)) {
                        ForEach(EditorPageFilter.allCases) { filter in
                            Text(filter.titleKey).tag(filter)
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
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

/// レイアウト列のプルダウン。見た目(現在の状態の名前 + 上下向きの矢印)はSwiftUIで静的に描き、
/// 実際のメニューはクリックされて初めてAppKitのNSMenuとして組み立てて表示する。
///
/// 経緯(ユーザー報告「表示の更新が全体的にもたつく」+ sampleによる実測): 以前ここは
/// メニュースタイルのPicker(`.pickerStyle(.menu)`、内部的にはNSPopUpButton)だった。
/// SwiftUIのMenu/Pickerは、その項目をPlatformItemListというPreferenceKeyとしてビュー階層へ流し、
/// レイアウトパスのたびに集約し直す仕組みになっている。そのため「行の数だけPickerがある」この
/// 一覧では、メニューを一度も開かなくても、スクロール・ウインドウのリサイズ・本の切り替えの
/// たびに、表示中の全行ぶんのメニュー項目生成が走っていた。
///
/// 操作条件を揃えて実測したところ(sample、ドロップダウンを開かない状態で比較)、この列を
/// ただのTextに差し替えるだけでメインスレッドのレイアウト時間(CA transaction flush配下)が
/// 1514サンプル→181サンプルへ8.4倍減った。NSMenuはクリックされるまで存在しないため、
/// この常時コストが無くなる。
///
/// 副次的な効果として、以前あった「NSTableViewの行再利用でNSPopUpButtonの表示がstaleになり、
/// 別のページのレイアウトが変わったように見える」不具合(ユーザー報告)への回避策として
/// 付けていた`.id(pageKey + 現在の値)`(値が変わるたびにPickerを実体ごと作り直させるもの)も
/// 不要になった。stale化の原因だったNSPopUpButton自体がもう存在しないため。
private struct PageLayoutStateMenuButton: View {
    let currentState: PageLayoutState?
    let width: CGFloat
    let onChange: (PageLayoutState?) -> Void

    /// アプリ内表示言語。NSMenuItemのタイトルはSwiftUIが解決してくれないため、
    /// PageLayoutState.title(locale:)へ明示的に渡す必要がある。
    @Environment(\.locale) private var locale

    var body: some View {
        Button {
            showMenu()
        } label: {
            HStack(spacing: 3) {
                Text(currentState?.titleKey ?? "No Layout")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            // Buttonのクリック判定を、テキストの実際の幅ではなく列の幅いっぱいに広げる
            // (以前のNSPopUpButtonと同じ感覚で押せるようにするため)。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
    }

    private func showMenu() {
        // NSMenuItem.targetは強参照ではないため、メニューが出ている間ハンドラを生かしておく
        // 必要がある。popUp(positioning:at:in:)はメニューが閉じるまで戻らない(モーダル)ので、
        // このローカル変数の寿命でちょうど足りる。
        let handler = PageLayoutMenuHandler(onChange: onChange)
        let menu = NSMenu()
        menu.autoenablesItems = false

        let noLayoutItem = NSMenuItem(
            title: String(localized: "No Layout", locale: locale),
            action: #selector(PageLayoutMenuHandler.selectState(_:)),
            keyEquivalent: ""
        )
        noLayoutItem.target = handler
        // representedObjectがnil = 「レイアウトなし」(PageLayoutStateにはこの状態を表す
        // ケースが無い。PageLayoutState.swiftのコメント参照)。
        noLayoutItem.representedObject = nil
        noLayoutItem.state = currentState == nil ? .on : .off
        menu.addItem(noLayoutItem)

        for state in PageLayoutState.allCases {
            let item = NSMenuItem(
                title: state.title(locale: locale),
                action: #selector(PageLayoutMenuHandler.selectState(_:)),
                keyEquivalent: ""
            )
            item.target = handler
            item.representedObject = state.rawValue
            item.state = state == currentState ? .on : .off
            menu.addItem(item)
        }

        // 表示位置はクリックしたイベントの位置から決める。
        //
        // 最初の実装では、行ごとに透明なNSView(NSViewRepresentable)を敷いて、そのビューの下端を
        // 基準に出していた。しかし「行の数だけAppKitのビューをSwiftUIへ橋渡しする」こと自体の
        // レイアウトコストが実測で無視できず、NSPopUpButtonを取り除いて得た改善をかなりの部分
        // 食い潰していた(せっかくPickerを外したのに、代わりに別のAppKitビューを毎行置いていては
        // 意味がない)。イベント位置から出せば、行側にはAppKitの実体を一切持たせずに済む。
        if let event = NSApp.currentEvent, let contentView = event.window?.contentView {
            menu.popUp(
                positioning: nil,
                at: contentView.convert(event.locationInWindow, from: nil),
                in: contentView
            )
        } else {
            // キーボード操作などでNSApp.currentEventが取れない場合のフォールバック
            // (in: nilのときatはスクリーン座標)。
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

/// NSMenuItemのaction(セレクタ)を、SwiftUI側のクロージャへ橋渡しするだけの受け皿。
/// NSMenuItemはブロックを直接受け取れないため、target/action用のNSObjectが必要になる。
@MainActor
private final class PageLayoutMenuHandler: NSObject {
    private let onChange: (PageLayoutState?) -> Void

    init(onChange: @escaping (PageLayoutState?) -> Void) {
        self.onChange = onChange
    }

    @objc func selectState(_ sender: NSMenuItem) {
        let rawValue = sender.representedObject as? String
        onChange(rawValue.flatMap(PageLayoutState.init(rawValue:)))
    }
}

/// 右ペインの1ページ分の行。サムネイル(サムネイル列)・レイアウト(レイアウト列)・
/// ブックマーク(ブックマーク列)の3列を横に並べる(4.2節)。
private struct PageRowView: View {
    let row: BookLayoutEditorViewModel.Row
    @ObservedObject var viewModel: BookLayoutEditorViewModel
    let bookID: String
    let bookmark: Bookmark?
    /// 列ヘッダー行(columnHeaderRow)と共有する列幅。ヘッダー側でドラッグして幅を変えると、
    /// 同じBindingを通じてすべての行に即座に反映される(PageListColumnWidths参照)。
    let columnWidths: PageListColumnWidths
    /// 各区切り線(0=ページ/サムネイル境界、1=サムネイル/レイアウト境界、
    /// 2=レイアウト/ブックマーク境界)を、タイトル行の実測位置へ追従させるための補正量
    /// (BookmarkDetailPane.columnDividerCorrections参照)。
    let columnDividerCorrections: [Int: CGFloat]
    /// ドラッグハンドルを実際に使える見た目にするかどうか。呼び出し元
    /// (BookmarkDetailPane.pageListContent)のForEach.moveDisabledと同じ条件
    /// (pageFilter == .all)を渡す。
    let isMoveEnabled: Bool
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
    /// ブックマーク名のシングル/ダブルクリック識別(自前実装)用、直近のクリック時刻。
    /// selectableContent内のブックマーク列のコメント参照。
    @State private var lastBookmarkNameTapDate: Date?
    /// ブックマーク名をシングルクリックしたときの、リネーム開始を遅らせるためのタスク
    /// (ダブルクリックだと判明したら取り消す)。
    @State private var renameTask: Task<Void, Never>?

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
        // 選択中のハイライトはList(selection:)がネイティブに描く(以前はここで
        // .listRowBackground(isSelected ? ... : .clear)と自前に描いていた)。
        .tag(row.pageKey)
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
            // ユーザー報告(ラグの原因調査): 以前はここに専用の.onTapGesture(count: 2){ onJump() }を
            // 付けていたが、行全体(selectableContent末尾の.simultaneousGesture)が同じクリックを
            // 既に検知してonJump()を呼ぶため、実質的に不要な重複だった。この位置にクリック回数2の
            // ジェスチャーが同居しているだけで、行選択(onSelect)のハイライト表示にもラグが
            // 生じていたため削除した(ジャンプ自体は行全体側の判定で引き続き機能する)。
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
            // かつてここはメニュースタイルのPicker(NSPopUpButton)だったが、行の数だけ存在する
            // ことによる常時のレイアウトコストが実測で問題になったため、クリックされて初めて
            // NSMenuを組み立てる自前のコントロールへ置き換えた(詳細と実測値は
            // PageLayoutStateMenuButtonのコメント参照)。
            //
            // 以前ここには、NSTableViewの行再利用でNSPopUpButtonの表示がstaleになる不具合
            // (ユーザー報告)への回避策として`.id(pageKey + 現在の値)`を付けていたが、原因だった
            // NSPopUpButtonが無くなったため取り除いた。現在の表示はcurrentLayoutState
            // (viewModel.pageLayoutStatesのスナップショット)から素直に導かれるTextであり、
            // AppKit側に作り置きされて使い回される実体を持たない。
            //
            // バグ修正(この構造自体は維持): メニュースタイルのPickerは、項目文字列の長さに
            // よっては.frame(width:)で指定した幅より広い実効幅で描画されることがあり、その分だけ
            // 後ろの区切り線・ブックマーク列がタイトル行(columnHeaderRow)とずれて見えていた
            // (ユーザー報告)。「HStackのレイアウト計算に使われる幅」をColor.clearの
            // .frame(width:)で厳密にcolumnWidths.layoutへ固定し、実際に見えるコントロールは
            // その上に.overlay(alignment: .leading)で重ねることで、見た目の幅がどうであれ
            // 後続の区切り線の位置には影響しないようにしている。
            Color.clear
                .frame(width: columnWidths.layout, height: 1)
                .overlay(alignment: .leading) {
                    PageLayoutStateMenuButton(
                        currentState: currentLayoutState,
                        width: columnWidths.layout,
                        onChange: { onLayoutStateChange($0) }
                    )
                }

            ColumnDividerLine(measurementKey: "row:2")
                .offset(x: columnDividerCorrections[2] ?? 0)

            // ブックマーク列。
            if let bookmark {
                HStack(spacing: 4) {
                    Text(bookmark.name)
                        // ユーザー報告(ラグの原因調査): 以前はここに.onTapGesture(count: 2){ onJump() }と
                        // .onTapGesture(count: 1){ onRenameBookmark(bookmark) }を同じビューに
                        // 両方付けていた。クリック回数の異なるジェスチャーが同居すると、
                        // シングルクリックの確定自体がシステムのダブルクリック間隔だけ遅延する
                        // (selectableContent末尾の.simultaneousGestureのコメント参照)。
                        // ここではクリック回数1のジェスチャーだけを使い、自前でリネーム開始を
                        // ダブルクリック間隔だけ遅らせて予約し、その間に2回目のクリックが来たら
                        // リネームを取り消す(ジャンプ自体は行全体側の.simultaneousGestureが
                        // 同じクリックを検知して実行するため、ここでは呼ばない)。
                        // なお、Finderの「選択中のアイコン名を単独クリックするとリネームになる」
                        // 挙動も同様にダブルクリックと区別するための遅延を伴っており、これは
                        // 単純化のための妥協ではなく、この種の識別に本質的に伴う遅延。
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                let now = Date()
                                if let lastBookmarkNameTapDate,
                                   now.timeIntervalSince(lastBookmarkNameTapDate) <= NSEvent.doubleClickInterval {
                                    self.lastBookmarkNameTapDate = nil
                                    renameTask?.cancel()
                                    renameTask = nil
                                } else {
                                    lastBookmarkNameTapDate = now
                                    renameTask?.cancel()
                                    renameTask = Task {
                                        try? await Task.sleep(
                                            nanoseconds: UInt64(NSEvent.doubleClickInterval * 1_000_000_000)
                                        )
                                        guard !Task.isCancelled else { return }
                                        onRenameBookmark(bookmark)
                                    }
                                }
                            }
                        )
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
        // ここには絶対にジェスチャー(.onTapGesture/.gesture/.simultaneousGesture)を付けないこと。
        //
        // 経緯(ユーザー報告「クリックがたまに・ランダムに反応しない」の真因。左ペインで先に
        // 判明し、同じ原因がこちらにもあった): セル内にSwiftUIのジェスチャーがあると、それが
        // マウスダウンを掴んでしまい、下のNSTableViewが行選択のトラッキングを開始できなくなる。
        // ジェスチャーの種類は無関係で、TapGesture/DragGesture/onTapGesture(count:)のいずれでも
        // 再現する。左ペインで計測したところ、セル内のジェスチャーを完全に取り除いた時だけ
        // 取りこぼしがゼロになった(それ以前は34回中15回が取りこぼし)。
        //
        // そのため、行の選択はList(selection:)のネイティブ実装に任せ(呼び出し元のpageList参照)、
        // ダブルクリックでのジャンプはSwiftUIの外(BookmarkDetailPane.installDoubleClickMonitor)で
        // 実装している。
        //
        // 副次的な効果として、以前ここに書かれていた次の2つの回避策も不要になった:
        // ・並べ替えドラッグの掴み始めをタップジェスチャーが先取りしてしまう問題への
        //   .simultaneousGesture化(ユーザー報告)
        // ・クリック回数の異なるジェスチャーの同居によるハイライトの遅延を避けるための、
        //   自前のNSEvent.doubleClickInterval比較(ユーザー報告)
        // どちらもセル内にジェスチャーが在ることに起因していた問題であり、ネイティブ選択では
        // ハイライトがマウスダウンで確定し、並べ替えドラッグとも競合しない。
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

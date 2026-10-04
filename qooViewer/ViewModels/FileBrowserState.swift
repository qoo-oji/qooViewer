import AppKit
import Combine
import CoreServices
import Foundation

/// ウェルカム画面のファイルブラウザの閲覧状態(改善要望7 段階3、2026-09-13)。
///
/// ContentViewが`@StateObject`で**ウインドウに1つ**持つ(サイドパネルのSidePanelBrowserStateと
/// 同じ形)。本を開いて「ウェルカム画面へ戻る」で帰ってきたときは、離れたときのフォルダ・選択・
/// 戻る/進むの履歴のまま。
///
/// ■ 一覧の読み込みは`FileIO`の上
/// `DirectoryBrowser.listingAsync`(`Task.detached`)を流用しない。応答しない共有のフォルダを1つ
/// 開いただけで協調プールが塞がり、アプリの async 処理が全部止まりうる(FileIOの型コメント)。
/// 速く移動したときに前のフォルダの結果が後から届くことがあるので、**世代番号で古い結果を捨てる**。
///
/// ■ 選択・スクロール先は「パス」で持つ
/// 列挙はフォルダのURLを末尾`/`付きで返し、外から渡されるURLには付いていないことが多い。
/// URLの`==`で比べると同じ項目が別物になるので、`FileBrowserEntry.id`(= `url.path`)で持つ。
///
/// ■ 何を保存するか
/// 表示形式・並べ替えの基準と向き・アイコンの大きさ・左の幅は`qooViewer.fileBrowser.*`へ
/// (環境設定の画面に並ばない値なので`qooViewer.pref.*`にしない。WelcomeLibraryStateと同じ理由)。
/// 最後に表示したフォルダは**シークレットウインドウでは書かない**(決定事項 Q8)。
/// 検索欄の文字列は保存せず、フォルダを移ったら空にする。
@MainActor
final class FileBrowserState: ObservableObject {
    private enum Keys {
        static let viewMode = "qooViewer.fileBrowser.viewMode"
        static let hiddenListColumns = "qooViewer.fileBrowser.hiddenListColumns"
        static let iconSize = "qooViewer.fileBrowser.iconSize"
        static let treeWidth = "qooViewer.fileBrowser.treeWidth"
        static let lastFolderPath = "qooViewer.fileBrowser.lastFolderPath"
        static let bulkRename = "qooViewer.fileBrowser.bulkRename"
        static let showsHiddenFiles = "qooViewer.fileBrowser.showsHiddenFiles"
    }

    /// 保存が無いときに隠す列。作成日は既定で出さない(2026-09-14、ユーザーの判断)。
    static let defaultHiddenListColumns: Set<String> = ["created"]
    /// アイコンの大きさ。上限の 450 は、コレクションの中のカバーの最大(幅 300pt、既定の 2:3 で高さ 450pt。
    /// WelcomeLibraryState.coverSizeRange)と同じ見た目になる大きさ ―― アイコンは正方形の枠に長辺を合わせて描くので、
    /// カバーの長辺に揃える(2026-09-16、ユーザー要望)。絵は最大でも長辺 512px(FileBrowserThumbnailProvider.pixelTiers)
    /// なので 256pt を超えると Retina では引き伸ばしになるが、カバーの側も最大付近では保存した 768px を引き伸ばしており
    /// (CollectionCoverStore.maxPixelSize)、アイコン表示のためだけに大きい段を足すことはしない(ユーザーの判断)。
    static let iconSizeRange: ClosedRange<CGFloat> = 48...450
    static let defaultIconSize: CGFloat = 96
    static let treeWidthRange: ClosedRange<CGFloat> = 160...480
    static let defaultTreeWidth: CGFloat = 220
    /// 戻る/進むの履歴の上限。古いものから捨てる。
    static let historyDepth = 100

    /// いま表示しているフォルダ。nil は「コンピュータ」(ボリュームの一覧)**または「最近の項目」**(`isShowingRecents`。
    /// FileBrowserLocation の型コメント ―― 実フォルダが無いことに頼る判断は、どちらにも同じに効く)。
    @Published private(set) var currentFolder: URL?
    /// 「最近の項目」(最近開いた本の一覧)を表示しているか(2026-09-28)。この間 `currentFolder` は nil。
    @Published private(set) var isShowingRecents = false
    /// 表示している場所(`currentFolder` と `isShowingRecents` を 1 つの値にしたもの)。
    var location: FileBrowserLocation {
        if isShowingRecents { return .recents }
        return currentFolder.map { .folder($0) } ?? .computer
    }
    /// 並べ替え・絞り込み後の一覧。
    @Published private(set) var entries: [FileBrowserEntry] = []
    /// `entries`を差し替えるたびに進む番号。AppKitの一覧(NSTableView)が`reloadData`の要否を
    /// 配列の比較なしで判断するために使う。
    @Published private(set) var entriesRevision = 0
    /// 選んでいる項目の id(`FileBrowserEntry.id`)。
    @Published var selection: Set<String> = [] {
        didSet {
            if selection != oldValue {
                Self.selectionRevisionCounter &+= 1
                selectionRevision = Self.selectionRevisionCounter
            }
        }
    }
    /// `selection` の中身が変わるたびに変わる番号(publish しない)。メニューバーの値と `selectedEntries` の覚え書きの鍵
    /// (2026-09-15 の 4 回目の監査。選択の id の配列を毎回作って比べていたのをやめた)。**アプリ全体で通しの番号**にして、
    /// 別のウインドウの選択と同じ値にならないようにする(メニューバーのサブメニューはこの値が同じなら前の中身を使い回す)。
    /// 何も選んでいない間は 0 のことがある(そのときサブメニューは中身を作らない)。
    private(set) var selectionRevision = 0
    private static var selectionRevisionCounter = 0
    @Published private(set) var loadError: FileBrowserLoadError?
    @Published private(set) var isLoading = false
    /// 表示中のフォルダの中身を変えられるか(`access(W_OK)` と読み取り専用のボリューム。`FileOperationPreflight.checkWritable`)。読み込むたびに
    /// 一緒に求める(FileIO の上)。**false の間、その中の項目のカット・ゴミ箱・すぐに削除・名前の変更は淡色**(`FileBrowserActions.canChange`。
    /// 2026-10-04 の監査 FBA-11: 親に書けない項目の「すぐに削除…」が中身を全部消してから失敗していた)。「コンピュータ」「最近の項目」では true
    /// (項目ごとの親は見ない ―― 断るのは入口とエンジン)。
    @Published private(set) var isCurrentFolderWritable = true
    /// 一覧に、この項目が見える位置までスクロールしてほしい(上へ移動・戻る・reveal のあと)。
    /// `serial`は同じ項目への2回目の依頼を別物にするため。
    @Published private(set) var scrollRequest: ScrollRequest?

    struct ScrollRequest: Equatable {
        let id: String
        let serial: Int
    }

    /// 一覧(リスト・アイコン)のスクロール位置の控え(表示形式ごと。publish しない)。一覧は、本を開いてホームへ戻る・表示形式を
    /// 切り替えて戻すたびに**作り直される**。選択はこの状態が持っているので戻るが、スクロールは一覧の `NSScrollView` にしか
    /// 無く、先頭から見せ直していた(2026-09-27、利用者の報告)。一覧が捨てられるときに控え、同じフォルダのまま作り直されたら
    /// そこから見せる(`HomeWheelScrollView.restoreScrollOrigin`)。控えは一度使ったら捨てる。
    ///
    /// 控えには、その時点のスクロールの依頼の通し番号と選択の版も入れる(2026-10-04 の監査 FBU-8)。表示形式を切り替えて
    /// もう一方で選択を動かしてから戻ると、以前は古い位置へ戻ったうえで新しい依頼を「済んだ」扱いにし、選んだ項目が見えなかった。
    private var savedScrollOrigins: [FileBrowserViewMode: SavedScrollOrigin] = [:]

    private struct SavedScrollOrigin {
        let folder: URL?
        let origin: CGPoint
        let scrollSerial: Int?
        let selectionRevision: Int
    }

    /// 作り直した一覧が、捨てる前の位置へどう戻るか(`takeSavedScrollRestoration(for:)`)。
    enum SavedScrollRestoration: Equatable {
        /// 控えた位置へ戻す(残っている古いスクロールの依頼は済んだことにする)。
        case origin(CGPoint)
        /// 控えた後に選択だけが変わった(クリック)。古い依頼は済んだことにして、この項目を見える位置へ。
        case reveal(id: String)
    }

    /// 左のツリーの開き具合と位置の控え(ツリーを作り直しても残す。FileBrowserTreeView の型コメント)。publish しない。
    struct SavedTreeState {
        /// 開いていた行の鍵(上から。親が先)。
        var expandedKeys: [String]
        var scrollOrigin: CGPoint
    }

    private var savedTreeState: SavedTreeState?

    /// 捨てるツリーの開き具合と位置を控える。
    func saveTreeState(_ saved: SavedTreeState) {
        savedTreeState = saved
    }

    /// 作ったツリーが戻す開き具合と位置(一度使ったら捨てる)。
    func takeSavedTreeState() -> SavedTreeState? {
        defer { savedTreeState = nil }
        return savedTreeState
    }

    /// 捨てる一覧のスクロール位置を控える(`dismantleNSView` から)。
    func saveScrollOrigin(_ origin: CGPoint, for mode: FileBrowserViewMode, folder: URL?) {
        savedScrollOrigins[mode] = SavedScrollOrigin(
            folder: folder, origin: origin, scrollSerial: scrollRequest?.serial, selectionRevision: selectionRevision
        )
    }

    /// 作り直した一覧の戻り方(控えはどちらにしても捨てる)。nil なら控えを使わない ―― 一覧は残っている依頼をふつうに拾う。
    ///
    /// - 控えたときと違うフォルダ → nil。
    /// - 控えた後にスクロールの依頼が来た(もう一方の表示での矢印キー・reveal・ペースト)→ nil。その依頼のほうが新しい(監査 FBU-8)。
    /// - 控えた後に選択だけが変わった(クリック)→ 選んだ最初の項目を見せる(`.reveal`)。選択が空になったなら位置へ戻す。
    /// - どれでもない → 控えた位置へ(`.origin`)。
    func takeSavedScrollRestoration(for mode: FileBrowserViewMode) -> SavedScrollRestoration? {
        guard let saved = savedScrollOrigins.removeValue(forKey: mode), saved.folder == currentFolder else { return nil }
        guard saved.scrollSerial == scrollRequest?.serial else { return nil }
        if saved.selectionRevision != selectionRevision,
           let first = entries.first(where: { selection.contains($0.id) }) {
            return .reveal(id: first.id)
        }
        return .origin(saved.origin)
    }

    @Published var viewMode: FileBrowserViewMode {
        didSet {
            guard viewMode != oldValue else { return }
            defaults.set(viewMode.rawValue, forKey: Keys.viewMode)
        }
    }

    /// 隠しファイル(名前が`.`で始まる・`UF_HIDDEN`)も出すか(2026-09-27、利用者の指示)。表示メニュー「隠しファイルを表示」
    /// ⇧⌘. で切り替える(Finder と同じキー。環境設定には置かない)。表示形式と同じくウインドウごとの値で、最後に選んだ値を
    /// 次に開くウインドウが引き継ぐ。変えたら今のフォルダを読み直す(ツリーは`FileBrowserTreeView`が自分で読み直す)。
    @Published var showsHiddenFiles: Bool {
        didSet {
            guard showsHiddenFiles != oldValue else { return }
            defaults.set(showsHiddenFiles, forKey: Keys.showsHiddenFiles)
            reload()
        }
    }

    /// 並べ替えの基準。**サイドパネルのフォルダブラウザと同じ 1 つの設定**(`AppPreferences.folderBrowserSortKey`)を
    /// 読み書きする(2026-09-14、ユーザー要望)。以前は`qooViewer.fileBrowser.sortKey`に別に持っていて、片方で変えても
    /// もう片方は変わらなかった。すべてのウインドウのファイルブラウザとサイドパネルが同じ値を見るので、どこで変えても
    /// 全部が並べ替わる(`observePreferences`)。「フォルダを上に」は別の設定のまま(`fileBrowserFoldersFirst`のコメント)。
    ///
    /// `preferences` が無い間(つながる前・テスト)は手元の値を使う。
    var sortKey: FolderBrowserSortKey {
        get { preferences?.folderBrowserSortKey ?? localSortKey }
        set {
            guard newValue != sortKey else { return }
            objectWillChange.send()
            if let preferences {
                preferences.folderBrowserSortKey = newValue
            } else {
                localSortKey = newValue
            }
            resort()
        }
    }

    /// 並べ替えの向き。`sortKey`と同じく`AppPreferences.folderBrowserSortDirection`を読み書きする。
    var sortDirection: FolderBrowserSortDirection {
        get { preferences?.folderBrowserSortDirection ?? localSortDirection }
        set {
            guard newValue != sortDirection else { return }
            objectWillChange.send()
            if let preferences {
                preferences.folderBrowserSortDirection = newValue
            } else {
                localSortDirection = newValue
            }
            resort()
        }
    }

    private var localSortKey: FolderBrowserSortKey = FolderBrowserSort.default.key
    private var localSortDirection: FolderBrowserSortDirection = FolderBrowserSort.default.direction

    /// リスト表示で隠している列(`FileBrowserListView.Column.rawValue`。2026-09-14、ユーザー要望)。見出しの右クリックで切り替える。
    /// 名前の列は隠せない(Finder と同じ)。列の並びと幅は`NSTableView`の`autosaveName`が保存する。
    @Published var hiddenListColumns: Set<String> {
        didSet {
            guard hiddenListColumns != oldValue else { return }
            defaults.set(hiddenListColumns.sorted(), forKey: Keys.hiddenListColumns)
        }
    }

    @Published var iconSize: CGFloat {
        didSet {
            guard iconSize != oldValue else { return }
            defaults.set(Double(iconSize), forKey: Keys.iconSize)
        }
    }

    @Published var treeWidth: CGFloat {
        didSet {
            guard treeWidth != oldValue else { return }
            defaults.set(Double(treeWidth), forKey: Keys.treeWidth)
        }
    }

    /// 検索欄(現フォルダの絞り込みだけ。決定事項 Q9)。**変わったら、見えなくなった項目を選択から外す**
    /// (見えていないものに後段の操作が効くのを防ぐ。WelcomeLibraryState.searchTextと同じ決まり)。
    @Published var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            applyFilter()
        }
    }

    /// 取り消し・やり直しの積み場所(ウインドウごと。FileCommandStackの型コメント)。
    let commandStack = FileCommandStack()
    /// 書く操作の窓口(段階4)。
    let operations = FileBrowserOperations()

    /// ⌘X で覚えた項目のパス(`FileBrowserOperations.paths(of:)`の規則)。一覧で淡く描き、ペーストで一致すれば移動。
    /// **アプリで 1 つの記憶(`cutClipboard`)の写し**(どのウインドウでカットしても、全部のウインドウで淡くなる。FileCutClipboard の型コメント)。
    @Published private(set) var cutPaths: Set<String> = []
    /// カットの記憶。書き換えは `FileBrowserOperations` がここへ。
    let cutClipboard: FileCutClipboard
    private var cutObservation: AnyCancellable?
    /// 名前の編集を始めてほしい項目(新規フォルダの直後・右クリックの「名前を変更」)。
    /// 一覧はこの項目が見えるようになった時点で編集を始める。
    @Published private(set) var renameRequest: ScrollRequest?
    /// 名前の編集を取りやめてほしい(読み取り専用モードを ON にした・ファイルブラウザ機能を OFF にした)。値は増えるだけの通し番号で、
    /// リストとアイコン表示が変化を拾って、編集中なら打った名前を捨てて終える(2026-09-23、利用者の決定。以前は編集の欄が残り、Return で
    /// 確定すると入口が黙って断って元の名前に戻った)。
    @Published private(set) var nameEditingCancelSerial = 0
    /// 「移動」メニューの「フォルダへ移動…」のシートを出しているか。
    @Published var isShowingGoToFolder = false
    /// 右クリックの「メタデータの編集…」「本の書き出し」のシート(段階 8)。nil なら出していない。
    @Published var bookSheet: FileBrowserBookSheet?
    /// 自分の操作でファイルが変わったフォルダ(ツリーが開いている行を読み直す)。
    @Published private(set) var fileSystemChange: TreeReloadRequest?
    /// 右ペインの下に短い間だけ浮かべる知らせ(OverlayToast)。nil なら出していない。`showToast(_:)` で出す。
    @Published private(set) var toastMessage: String?
    /// 検索欄を広げて焦点を入れてほしい(メニューバーの「検索」⌘F。2026-09-15)。値は増えるだけの通し番号で、ペインが変化を拾う。
    @Published private(set) var searchFocusRequest = 0
    /// よく使う項目の「＋」で最後に足したフォルダと、パネルを閉じた時点で見ていた場所(`NSOpenPanel.directoryURL`)。
    /// 足した直後は一覧がそのフォルダの中へ移動するので、次の「＋」を今のフォルダから始めると「中に入った状態」で
    /// パネルが開いてしまう(2026-09-15、ユーザー指摘)。一覧がまだそのフォルダにいる間だけ親から始める。表示には使わないので
    /// @Published にしない。
    var lastAddedFavoriteLocation: (added: URL, panelDirectory: URL)?

    func requestSearchFocus() {
        searchFocusRequest &+= 1
    }

    /// Tab で焦点を移す先(2026-09-30、ユーザー要望。docs/15「Tab でのペインの行き来」)。
    enum FocusPane: Equatable {
        /// 左のツリー。現在のフォルダの行が見えていなければ、そこまで開いてから選ぶ(FileBrowserTreeView の Coordinator)。
        case tree
        /// 右のリスト・アイコン表示。
        case content
    }

    struct FocusRequest: Equatable {
        let pane: FocusPane
        let serial: Int
    }

    /// 焦点を移してほしい(Tab / ⇧Tab。AppKit の一覧が `update` で変化を拾い、`makeFirstResponder` する)。
    @Published private(set) var focusRequest: FocusRequest?
    private var focusSerial = 0

    /// 焦点をもう一方のペインへ移す。右ペインへ移すとき何も選ばれていなければ先頭の項目を選ぶ ―― 焦点が移ったことが
    /// 見えるように(ツリーへ移すときは現在のフォルダの行が選ばれる)。
    func requestFocus(_ pane: FocusPane) {
        if pane == .content, selection.isEmpty, let first = entries.first {
            selection = [first.id]
            selectionRangeOrigin = nil
            selectionAnchor = first.id
            scrollSerial += 1
            scrollRequest = ScrollRequest(id: first.id, serial: scrollSerial)
        }
        focusSerial += 1
        focusRequest = FocusRequest(pane: pane, serial: focusSerial)
    }

    struct QuickLookRequest: Equatable {
        /// 出ていれば閉じる(メニューバーの ⌘Y。右クリックは閉じずに出す)。
        let toggles: Bool
        let serial: Int
    }

    /// クイックルックを出してほしい(右クリック・メニューバーの「クイックルック」。2026-10-01)。パネルの受け手は一覧(リスト・アイコン)の
    /// AppKit のビューなので、一覧が `update` で変化を拾って出す(FileBrowserQuickLook.show)。見せるのはいまの選択。
    @Published private(set) var quickLookRequest: QuickLookRequest?
    private var quickLookSerial = 0

    func requestQuickLook(toggles: Bool) {
        quickLookSerial += 1
        quickLookRequest = QuickLookRequest(toggles: toggles, serial: quickLookSerial)
    }

    /// アイコンの大きさを 1 段変える(メニューバーの「拡大」「縮小」。2026-09-15)。
    func stepIconSize(larger: Bool) {
        let next = Self.clamp(iconSize * (larger ? 1.25 : 0.8), to: Self.iconSizeRange)
        if next != iconSize { iconSize = next }
    }

    struct TreeReloadRequest: Equatable {
        let serial: Int
        /// 変わったフォルダの id(`FileBrowserState.id(for:)`)。
        let folderIDs: Set<String>
        /// どのフォルダが変わったか分からない(取り消し・やり直し)。ツリーは開いている行と三角を全部見直す。
        var isUnknownScope = false
    }

    /// 「フォルダを上に」を読む。差し替えたら購読し直す。
    weak var preferences: AppPreferences? {
        didSet {
            guard preferences !== oldValue else { return }
            observePreferences()
            // 画面に出たのがつながる前だった(activate のコメント)。ここで始める。
            if isAwaitingConnection, preferences != nil { activate() }
        }
    }
    /// 起動時のフォルダが「よく使う項目」のときに引く。
    weak var favoriteLocations: FavoriteLocationStore?
    /// フォルダの許可(ContentView がつなぐ)。付与・取り消しを受けて「アクセスを許可…」の案内を読み直す(`handleFolderAccessChange`)。
    weak var folderAccess: FolderAccessStore? {
        didSet {
            guard folderAccess !== oldValue else { return }
            folderAccessObservation = folderAccess?.accessChanged.sink { [weak self] in
                MainActor.assumeIsolated { self?.handleFolderAccessChange() }
            }
        }
    }
    private var folderAccessObservation: AnyCancellable?
    /// フォルダの許可が変わった回数。ツリー(FileBrowserTreeView)がこれを見て、開いているのに空の行を読み直す。
    @Published private(set) var folderAccessRevision = 0

    /// フォルダの許可が付いた・外れた(どのウインドウ・環境設定・よく使う項目の「＋」からでも。2026-10-04 の監査 FBU-5)。
    ///
    /// 以前はどの状態も許可の一覧を購読せず、鍵窓の切り替えではペーストボードしか確かめなかったので、ほかの窓で許可を付けても
    /// 「アクセスを許可…」の案内がフォルダを移り直すまで残り、ツリーの開いた行は空のままだった(アプリは前面のままなので、
    /// アクティブ化の読み直しも起きない)。案内を出している(読めなかった)ときだけ読み直す。
    func handleFolderAccessChange() {
        folderAccessRevision &+= 1
        if loadError == .needsAccess { reload() }
    }
    /// 「最近の項目」の中身(FileBrowserLocation の型コメント)。ContentView がつなぐ。履歴が変われば読み直す。
    weak var recentFiles: RecentFilesStore? {
        didSet {
            guard recentFiles !== oldValue else { return }
            observeRecentFiles()
        }
    }
    private var recentFilesObservation: AnyCancellable?
    /// 「最近の項目」を出せるか: 環境設定「ツリーの先頭に「最近の項目」を表示」が ON で、シークレットウインドウでない
    /// (履歴を見せない約束。AppState.isPrivateWindow)。
    var canShowRecents: Bool { (preferences?.fileBrowserShowsRecents ?? false) && !isPrivate }
    /// シークレットウインドウか(最後に表示したフォルダ・一括リネームの前回の入力を書かない。アイコン表示の絵をディスクへ書かない)。
    /// **ContentView が `@StateObject` を作る時点で渡す**(2026-09-23 の監査): ContentView が店や環境設定をつなぐより先に
    /// ペインが出て動き始めることがあり(タブバーの「＋」のタブは、つなぐのが正当なタブと分かった後)、つないだ時点で
    /// 渡すのでは、それまでの記録をシークレットウインドウでも書いていた。テストは作った後で書き換える。
    var isPrivate = false
    /// 画面に出た(`activate`)のが、ContentView が環境設定をつなぐより前だった。つながった時点(`preferences` の didSet)で始める。
    private var isAwaitingConnection = false

    var sort: FolderBrowserSort {
        FolderBrowserSort(
            grouping: (preferences?.fileBrowserFoldersFirst ?? true) ? .foldersFirst : .mixedByName,
            key: sortKey, direction: sortDirection
        )
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    /// 「コンピュータ」「最近の項目」より上は無い。
    var canGoUp: Bool { currentFolder != nil }

    /// 読み込みの待ち合わせ口。**テストのための口**で、アプリ側は触らない(SidePanelBrowserState.
    /// reloadTaskと同じ)。退避(消えたフォルダ → 祖先)で読み込みが続けて起きるので、
    /// 待つ側は`settle()`を使う。
    private(set) var loadTask: Task<Void, Never>?

    // MARK: - 記号リンク・エイリアスの先(2026-09-29)

    /// 一覧の記号リンク・エイリアスの先(鍵は `linkKey`: 項目の id と更新日時)。一覧を読んだ後に FileIO で解く(`resolveLinkTargets`。
    /// 触ってよい先だけ ―― `FileBrowserLinkResolver.backgroundTargetInfo`)。開く・新規タブ・コレクション・メタデータ・書き出し・展開・
    /// 「このアプリケーションで開く」・ドロップ先の判定が `effective(_:)` で**先の項目として**見る(Finder と同じ扱い。
    /// docs/15「記号リンクとエイリアスの先」)。解けていない(断られた・まだ)リンクは自分自身として扱われる。開くときは控えを使わず、
    /// `FileBrowserActions.openLink` がいつも場所を選ばずに解き直す(控えは読み直しのたびにも解き直す。2026-10-04、監査 FBU-2)。
    private var linkTargets: [String: FileBrowserLinkResolver.Target] = [:] {
        didSet {
            // 中身が変わったときだけ進める(読み直しのたびに解き直すので、同じ答えで publish しない)。
            if linkTargets != oldValue { linkTargetsRevision &+= 1 }
        }
    }
    /// `linkTargets` の中身が変わるたびに進む番号。メニューバーの「選んだ項目で押せるか」の覚え書きの鍵に入れる(ContentView の
    /// `fileBrowserMenuSelection`)。控えは publish しないので、以前はフォルダへ入った直後(先を解く前)に作った覚え書きが残り、
    /// Finder エイリアスを選ぶとメニューバーの「展開」が淡色のままだった(2026-10-04 の監査 X-2、実測)。
    @Published private(set) var linkTargetsRevision = 0
    private var linkTargetsTask: Task<Void, Never>?
    private static let linkTargetsLimit = 2000
    /// 先を読んでよいかの規則(`DirectoryProbe`)。**テストは空を渡す**(テストホストの一時フォルダはコンテナ = `~/Library/Containers` の中で、
    /// 既定の一覧では保護下)。
    var linkTargetProtectedPrefixes: [String] = DirectoryProbe.protectedPrefixes
    var linkTargetCategoryPrefixes: Set<String> = DirectoryProbe.categoryProtectedPrefixes
    /// リンクの先を解くときのマウント表(**テストのための口**: 作業フォルダをネットワーク越しに見立てる)。
    var linkTargetMountTable: () -> MountTable = MountTable.current

    /// 開くときに解き直した先を控えに入れる(`FileBrowserActions.openLink`。淡色の判定を今の先に合わせる。監査 FBU-2)。
    func noteLinkTarget(_ target: FileBrowserLinkResolver.Target?, for entry: FileBrowserEntry) {
        guard entry.isLink, allEntries.contains(where: { $0.id == entry.id }) else { return }
        linkTargets[Self.linkKey(for: entry)] = target
    }

    /// 記号リンク・エイリアスの解けている先(在るもの)。それ以外・まだ解けていないものは nil。
    func target(of entry: FileBrowserEntry) -> FileBrowserEntry? {
        guard entry.isLink, let target = linkTargets[Self.linkKey(for: entry)], target.exists else { return nil }
        return target.entry
    }

    /// 操作の相手として見る項目: 記号リンク・エイリアスなら解けている先、それ以外(と解けていないリンク)はそのまま。
    func effective(_ entry: FileBrowserEntry) -> FileBrowserEntry {
        target(of: entry) ?? entry
    }

    private static func linkKey(for entry: FileBrowserEntry) -> String { entry.identityKey }

    /// 一覧のリンクの先を解く(`apply` で読み直したとき)。消えた項目の分は捨て、残っているリンクは**解けている鍵も解き直す**
    /// (解き終わるまでは前の控えを使う)。
    ///
    /// **ネットワーク越しのボリュームにあるリンクは解かない**(2026-09-29 の監査)。先の場所は `backgroundTargetInfo` が段ごとに
    /// 確かめるが、リンク自身の readlink とエイリアスファイルの読み取りはその前に起きるので、共有上のフォルダではリンクの数だけ
    /// 往復していた(絵・アイコンが「見ているフォルダがネットワーク越しなら読まない」としているのと同じ規則に揃える)。解けていない
    /// リンクは自分自身として扱われ、開くときだけ `FileBrowserActions.openLink` が解く。
    ///
    /// **鍵はリンク自身のパスと更新日時**なので、先が動いても消えても鍵は変わらない。以前は一覧が変わったときに知らない鍵だけを
    /// 解いていたので、同じフォルダに居続ける間は、Finder で先を動かして戻っても(アクティブ化の読み直しは一覧が同じなら `apply` で
    /// 早く抜ける)古い先の控えが残り、ダブルクリックで消えた先へ移ろうとして無関係な祖先のフォルダが出た・古い先へ落とそうとした
    /// (2026-10-04、監査 FBU-2)。いまは読み直しのたびに(一覧が同じでも)解き直す。開くときは控えを使わずに解く
    /// (`FileBrowserActions.openLink`)。
    private func resolveLinkTargets() {
        linkTargetsTask?.cancel()
        linkTargetsTask = nil
        let links = Array(allEntries.lazy.filter(\.isLink).prefix(Self.linkTargetsLimit))
        let keys = Set(links.map(Self.linkKey(for:)))
        linkTargets = linkTargets.filter { keys.contains($0.key) }
        let mountTable = linkTargetMountTable()
        // FileIO の閉包へ渡すので配列にする(lazy の列は閉包を抱える。レビュー 2026-09-29)。
        let pending: [(key: String, url: URL)] = links.compactMap {
            let key = Self.linkKey(for: $0)
            guard !mountTable.isRemote($0.url) else { return nil }
            return (key, $0.url)
        }
        guard !pending.isEmpty else { return }
        let folder = currentFolder
        let (protectedPrefixes, categoryPrefixes) = (linkTargetProtectedPrefixes, linkTargetCategoryPrefixes)
        linkTargetsTask = Task { [weak self] in
            let resolved = await FileIO.perform { () -> [(key: String, target: FileBrowserLinkResolver.Target?)] in
                pending.map { item in
                    guard !Cancellation.isRequestedInCurrentScope else { return (item.key, nil) }
                    return (item.key, FileBrowserLinkResolver.backgroundTargetInfo(
                        of: item.url, currentFolder: folder, mountTable: mountTable,
                        protectedPrefixes: protectedPrefixes, categoryPrefixes: categoryPrefixes
                    ))
                }
            }
            guard let self, !Task.isCancelled else { return }
            // まとめて書き換える(項目ごとに書くと、変わるたびに番号が進んで publish が続く)。
            var targets = self.linkTargets
            for item in resolved {
                // 解き直して解けなかった(断った・読めない)なら、前の控えも捨てる(古い先を使い続けない)。
                targets[item.key] = item.target
            }
            self.linkTargets = targets
            self.linkTargetsTask = nil
        }
    }

    /// リンクの先を解き終わるまで待つ(**テストのための口**)。
    func waitForLinkTargets() async {
        await linkTargetsTask?.value
    }

    private var allEntries: [FileBrowserEntry] = [] {
        didSet { normalizedNamesCache = nil }
    }
    /// `allEntries` の名前を照合用に畳んだもの(同じ並び)。絞り込みを始めたときに 1 度だけ作る(`filteredAllEntries`)。
    private var normalizedNamesCache: [String]?

    /// `allEntries` を今の絞り込みの文字で絞ったもの。
    private func filteredAllEntries() -> [FileBrowserEntry] {
        guard LibrarySearchQuery(filterText) != nil else { return allEntries }
        let names = normalizedNamesCache ?? allEntries.map { LibrarySearchQuery.normalized($0.displayName) }
        normalizedNamesCache = names
        return FileBrowserListing.filtered(allEntries, normalizedNames: names, by: filterText)
    }
    private var backStack: [FileBrowserLocation] = []
    private var forwardStack: [FileBrowserLocation] = []
    private var generation = 0
    private var hasStarted = false
    /// 次に画面に出たときの行き先(prepare / show)。
    private var pendingDestination: Destination?
    private(set) var isVisible = false
    /// 読み込みが終わったら選んでスクロールする項目(上へ・戻る・reveal)。
    private var pendingReveal: String?
    /// 読み込みが終わったら選ぶ項目(ペーストで運んだもの)。
    private var pendingSelection: Set<String>?
    /// 上の 2 つの依頼を、読み直しを待つために 1 度持ち越したか。**持ち越すのは 1 度だけ**(2026-09-15 の 3 回目の監査。書き込みの続くフォルダでは
    /// 読み込むたびに読み直しの旗が立つので、以前は依頼をいつまでも持ち越し、静かになった後で利用者が選び直した選択を上書きした)。
    private var didDeferPendingRequests = false
    private var changeSerial = 0
    private var renameSerial = 0
    private var sessionBulkRenameSettings: BulkRenameSettings?
    private var stackObservation: AnyCancellable?
    /// 矢印キーと type-select の起点(最後にクリック・矢印・type-select で選んだ項目)。
    private var selectionAnchor: String?
    /// ⇧矢印で範囲を伸ばす起点(アイコン表示。2026-09-27、ホームの操作の統一 ―― それまでは ⇧矢印でも 1 件選び直していた)。
    /// ⇧ を付けずに動く・クリックで起点を置き直すと捨てる。
    private var selectionRangeOrigin: String?
    /// type-select で溜めている文字と、最後に打った時刻。
    private var typeSelectBuffer = ""
    private var typeSelectLastInput: Date?
    private var scrollSerial = 0
    private var watcher: FolderChangeWatcher?
    /// 見張っているフォルダを FSEvents が知らせてくる書き方で(`watchedFolderSpellings`)。
    private var watchedFolderIDs: Set<String> = []
    /// 読み込みの最中に FSEvents が変更を知らせた。読み終えたらもう一度読む(`handleChangedPaths` のコメント)。
    private var needsReloadAfterLoad = false
    private var preferenceObservation: AnyCancellable?
    /// 環境設定「ツリーの先頭に「最近の項目」を表示」の購読(OFF にされたら最近の項目から離れる)。
    private var recentsPreferenceObservation: AnyCancellable?
    /// 読み取り専用モード・ファイルブラウザ機能の切り替えの購読(`nameEditingCancelSerial`)。
    private var fileChangePermissionObservation: AnyCancellable?
    private var systemObservations: [AnyCancellable] = []
    /// ペーストボードにファイルがあるか(メニューバーの「ここに項目を移動」⌥⌘V を淡色にするための写し。2026-09-19 の総点検)。
    ///
    /// ペーストボードの変化は購読できないので、**アプリ・ウインドウが前に来たとき**(ほかのアプリでコピーして戻ってきた)と
    /// **このアプリがファイルを書いたとき**(`FileBrowserOperations.write`)に`changeCount`で確かめ直す。それ以外(このアプリの
    /// テキスト欄で文字をコピーした)で古くなることはあるが、そのときは押した時点で確かめて鳴らす(`FileBrowserActions.perform`)。
    /// 右クリックと一覧のキー(⌥⌘V)は押す・開くたびにペーストボードを直に読むので、これを使わない。
    @Published private(set) var pasteboardHasFiles = false
    private var pasteboardChangeCount: Int?
    private var toastDismissTask: Task<Void, Never>?
    private let defaults: UserDefaults
    /// アプリ自身がファイルを動かした知らせ(`FileSystemChange` の型コメント)。操作の側(`FileBrowserOperations`)も、済んだ直後に
    /// ここへ溜まった知らせを配らせる。
    let changeCenter: FileSystemChangeCenter
    private var changeObservation: AnyCancellable?

    /// 知らせを出しておく時間(ビューアのトーストと同じ 2 秒。ViewerView.showToast)。
    static let toastDuration: Duration = .seconds(2)

    /// - Parameter changeCenter: nil なら既定(アプリでは全体で 1 つ、テストの中ではこの状態だけのもの。`FileSystemChangeCenter` の型コメント)。
    /// - Parameter cutClipboard: nil なら既定(アプリでは全体で 1 つ、テストの中ではこの状態だけのもの)。
    init(defaults: UserDefaults = .standard, changeCenter: FileSystemChangeCenter? = nil, cutClipboard: FileCutClipboard? = nil) {
        self.defaults = defaults
        self.changeCenter = changeCenter ?? .defaultForState()
        self.cutClipboard = cutClipboard ?? .defaultForState()
        viewMode = FileBrowserViewMode(rawValue: defaults.string(forKey: Keys.viewMode) ?? "") ?? .list
        showsHiddenFiles = defaults.bool(forKey: Keys.showsHiddenFiles)
        hiddenListColumns = defaults.stringArray(forKey: Keys.hiddenListColumns).map(Set.init)
            ?? Self.defaultHiddenListColumns
        iconSize = (defaults.object(forKey: Keys.iconSize) as? Double)
            .map { Self.clamp(CGFloat($0), to: Self.iconSizeRange) } ?? Self.defaultIconSize
        treeWidth = (defaults.object(forKey: Keys.treeWidth) as? Double)
            .map { Self.clamp(CGFloat($0), to: Self.treeWidthRange) } ?? Self.defaultTreeWidth
        watcher = FolderChangeWatcher(onEvents: { [weak self] events in
            // FSEvents 自身のキューから呼ばれる(FolderChangeWatcher.init のコメント)。
            Task { @MainActor [weak self] in self?.handleChangedPaths(events) }
        })
        observeSystem()
        changeObservation = self.changeCenter.changes.sink { [weak self] change in
            MainActor.assumeIsolated { self?.handleFileSystemChange(change) }
        }
        cutObservation = self.cutClipboard.$paths.sink { [weak self] paths in
            MainActor.assumeIsolated {
                guard let self, self.cutPaths != paths else { return }
                self.cutPaths = paths
            }
        }
        operations.state = self
        // 取り消しの題が変わったら、メニューバーの値(ContentViewのMenuCheckmarkState)を作り直してもらう。
        stackObservation = commandStack.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: - 表示の出入り

    /// ファイルブラウザが画面に出たとき。初回は起動時のフォルダ(環境設定)へ、2回目以降は
    /// いた場所を読み直す(本を読んでいる間に変わっているかもしれない)。
    ///
    /// - Parameter folder: 「新規タブで開く」などで渡されたフォルダ。あれば起動時のフォルダより優先。
    func activate(showing folder: URL? = nil) {
        // 環境設定がまだ届いていない(タブバーの「＋」のタブは、正当なタブと分かるまでつながない ―― ContentView.resolveAmbiguousNewMainWindow)。
        // この時点で始めると、起動時のフォルダの設定を読めずにホームから始まり、それを「最後に表示したフォルダ」として書いていた
        // (2026-09-23 の監査)。画面に出ていない扱いのまま待つ(その間の「ファイルブラウザで表示」は予約に回る)。
        guard preferences != nil else {
            if let folder { pendingDestination = .folder(folder) }
            isAwaitingConnection = true
            return
        }
        isAwaitingConnection = false
        isVisible = true
        if let folder {
            pendingDestination = nil
            hasStarted = true
            navigate(to: folder)
        } else if let pending = pendingDestination {
            pendingDestination = nil
            hasStarted = true
            go(to: pending)
        } else if !hasStarted {
            hasStarted = true
            move(to: startupLocation(), selecting: nil)
        } else {
            reload()
            updateWatcher()
        }
    }

    /// 次に画面に出たときに表示するフォルダを予約する(新しいタブ/ウインドウで開いたフォルダ。
    /// ウインドウの中身がまだ出ていない時点で受け取るので、その場では読み込まない)。
    ///
    /// - Parameter item: そのフォルダの中で選ぶ項目(「ファイルブラウザで開く」でファイルを示すとき)。
    func prepare(showing folder: URL, selecting item: URL? = nil) {
        pendingDestination = item.map(Destination.item) ?? .folder(folder)
    }

    /// 「ファイルブラウザで開く」(段階 8)。フォルダはその中を、ファイルは入っているフォルダでその項目を選んで見せる
    /// (「Finder で開く」と同じ規則。FinderReveal)。**画面に出ていれば今すぐ、出ていなければ次に出たときに**
    /// (本棚から切り替えた直後は、ペインの onAppear が activate を呼ぶまで見えていない)。
    func show(_ url: URL, isDirectory: Bool) {
        let destination: Destination = isDirectory ? .folder(url) : .item(url)
        guard isVisible else {
            pendingDestination = destination
            return
        }
        hasStarted = true
        go(to: destination)
    }

    /// 入っているフォルダで**この項目を選んで**見せる(フォルダの本でも中へは入らない)。ホームへ戻ったときに直前に開いていた本を
    /// 選ぶため(`WelcomeLibraryState.revealsLastBookInFileBrowser`、2026-09-28)。`show(_:isDirectory:)` と同じく、出ていなければ
    /// 次に出たときに。見える位置へのスクロールは `reveal` が頼む(`scrollRequest`)。
    func show(selecting url: URL) {
        guard isVisible else {
            pendingDestination = .item(url)
            return
        }
        hasStarted = true
        go(to: .item(url))
    }

    /// 予約・「ファイルブラウザで開く」の行き先。
    enum Destination: Equatable {
        /// このフォルダの中を見せる。
        case folder(URL)
        /// この項目の入っているフォルダで、この項目を選ぶ。
        case item(URL)
    }

    private func go(to destination: Destination) {
        switch destination {
        case .folder(let folder): navigate(to: folder)
        case .item(let item): reveal(item)
        }
    }

    /// 見えていることにする(FSEvents は張らない)。**テストのための口** ―― アプリ自身の変更の知らせ(`handleFileSystemChange`)だけで
    /// 読み直すことを確かめる。
    func makeVisibleWithoutWatching() {
        isVisible = true
    }

    /// ファイルブラウザが画面から消えたとき(本を開いた・本棚へ切り替えた)。監視を止める。
    /// `pasteboardHasFiles` を確かめ直す(変わっていなければ何もしない)。
    func refreshPasteboardState() {
        let count = operations.pasteboard.changeCount
        guard count != pasteboardChangeCount else { return }
        pasteboardChangeCount = count
        // ペーストボードが替わっていたら、カットの淡色も確かめ直す(2026-10-04 の監査 FBA-8)。以前はアクティブ化・FSEvents・
        // ペーストの入口でしか確かめず、アプリの中で文字をコピーしてウインドウを切り替えても淡色(カット済み)が残った ―― ⌘V の判定は
        // 正しく「コピー」なので、見た目だけが食い違っていた。カットを書いた直後に呼ばれても、記憶はそのときの changeCount を
        // 持っているので下ろさない(FileCutClipboard.validate)。
        cutClipboard.validate(against: operations.pasteboard)
        let hasFiles = operations.canPaste
        if hasFiles != pasteboardHasFiles { pasteboardHasFiles = hasFiles }
    }

    func deactivate() {
        isAwaitingConnection = false
        isVisible = false
        updateWatcher()
    }

    /// ウインドウを閉じるとき。FSEvents のストリームと購読を手放す(ARC任せにすると、閉じた
    /// ウインドウのぶんの監視が次のイベントまで残る)。
    func releaseResources() {
        isVisible = false
        loadTask?.cancel()
        loadTask = nil
        linkTargetsTask?.cancel()
        linkTargetsTask = nil
        watcher?.tearDown()
        systemObservations.removeAll()
        changeObservation = nil
        cutObservation = nil
        preferenceObservation = nil
        fileChangePermissionObservation = nil
        recentsPreferenceObservation = nil
        recentFilesObservation = nil
        stackObservation = nil
        // 走っている操作の報告は捨てない(確認は断る側で答える。FileBrowserOperations.detachFromWindow)。
        operations.detachFromWindow()
        // 書き出しの同名確認を待ったままウインドウが閉じると、書き出しの Task が答えを待ち続ける
        // (ViewerView.cancelOpenBookExportIfNeeded と同じ)。
        bookSheet?.cancelExport()
        bookSheet = nil
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastMessage = nil
    }

    // MARK: - 知らせ

    /// 操作の結果を右ペインの下に `toastDuration` だけ出す(ユーザー要望 2026-09-14: 右クリックから
    /// コレクションに登録したとき)。出している間に次が来たら差し替えて数え直す(ViewerView.showToast と同じ)。
    func showToast(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    // MARK: - 移動

    /// フォルダへ移動する(nil はコンピュータ)。戻るの履歴に積む。
    func navigate(to folder: URL?) {
        navigate(to: Self.location(of: folder))
    }

    /// 場所へ移動する。戻るの履歴に積む。
    ///
    /// **今いる場所へ移動し直したときは読み直すだけ**(選択・ペーストした項目を選ぶ依頼は残す。2026-10-04 の監査 FBU-7)。パスバーの
    /// 末尾・移動メニューの今の場所・「ファイルブラウザで表示」で今のフォルダを指したときに、以前は `move` を通って選択が消えた。
    /// 読み直しは残す(再読み込みのつもりで押す人がいる)。許可を付けた直後にも通るので、監視も張り直す(`activate` の読み直しと同じ)。
    func navigate(to location: FileBrowserLocation) {
        let target = Self.normalized(location)
        guard target.selectionKey != self.location.selectionKey else {
            reload()
            updateWatcher()
            return
        }
        pushBack(self.location)
        forwardStack.removeAll()
        move(to: target, selecting: nil)
    }

    /// 「最近の項目」へ(ツリーの先頭の行。FileBrowserLocation の型コメント)。出せない設定・シークレットウインドウでは何もしない。
    func showRecents() {
        guard canShowRecents else { return }
        navigate(to: .recents)
    }

    /// 1階層上へ。ボリュームのルートならコンピュータへ。元いたフォルダを選んで見える位置へ
    /// スクロールする(サイドパネルのgoUpと同じ)。
    func goUp() {
        guard let leaving = currentFolder else { return }
        pushBack(location)
        forwardStack.removeAll()
        move(to: Self.location(of: Self.parent(of: leaving)), selecting: Self.id(for: leaving))
    }

    /// 戻る/進むの履歴から「最近の項目」を外す(設定を OFF にしたとき)。外した跡で同じ場所が続く(`[A, 最近, A]`)・いま居る場所が隣に
    /// 来る(最近の項目に居てホームへ離れたとき、直前がホーム)と、押せる「戻る」「進む」が何もしないので、それも畳む(レビュー 2026-09-29)。
    private func removeRecentsFromHistory() {
        // 比べるのは `FileBrowserLocation` そのもの(`selectionKey` はコンピュータが nil で、空の履歴の `last` と区別がつかない ――
        // 2026-09-29 のテストで空の履歴から removeLast してクラッシュした)。
        func pruned(_ stack: [FileBrowserLocation]) -> [FileBrowserLocation] {
            var result: [FileBrowserLocation] = []
            for entry in stack where !entry.isRecents {
                if result.last != entry { result.append(entry) }
            }
            return result
        }
        let current = location
        backStack = pruned(backStack)
        forwardStack = pruned(forwardStack)
        while let last = backStack.last, last == current { backStack.removeLast() }
        while let last = forwardStack.last, last == current { forwardStack.removeLast() }
    }

    /// 戻る・進むの履歴に残った場所のうち、いまは出せない「最近の項目」はホームフォルダに読み替える(`startupLocation` の「最後に表示した
    /// フォルダ」と同じ。2026-09-29 の監査)。設定を OFF にしたときに履歴から外す(`observePreferences`)ので、ふつうは残っていない
    /// (シークレットウインドウでは積まれない)。念のための読み替え。
    private func reachable(_ location: FileBrowserLocation) -> FileBrowserLocation {
        location.isRecents && !canShowRecents ? .folder(FileBrowserListing.realHomeDirectory()) : location
    }

    /// 戻る。**戻り先が直前のフォルダの親なら、そのフォルダを選ぶ**(上へ移動したのと同じ見え方にする)。
    func goBack() {
        guard let previous = backStack.popLast().map(reachable) else { return }
        let leaving = currentFolder
        forwardStack.append(location)
        var highlight: String?
        if let leaving, Self.id(of: Self.parent(of: leaving)) == previous.folder.map(Self.id(for:)),
           !previous.isRecents {
            highlight = Self.id(for: leaving)
        }
        move(to: previous, selecting: highlight)
    }

    func goForward() {
        guard let next = forwardStack.popLast().map(reachable) else { return }
        pushBack(location)
        move(to: next, selecting: nil)
    }

    /// 項目の入っているフォルダへ移動して、その項目を選んでスクロールする。
    func reveal(_ url: URL) {
        let parent = Self.location(of: Self.parent(of: url))
        if parent.selectionKey != location.selectionKey {
            pushBack(location)
            forwardStack.removeAll()
        }
        move(to: parent, selecting: Self.id(for: url))
    }

    /// `URL?`(nil はコンピュータ)を場所へ。
    nonisolated static func location(of folder: URL?) -> FileBrowserLocation {
        folder.map { .folder(folderURL($0)) } ?? .computer
    }

    /// フォルダの綴りをそろえる(`folderURL`)。
    nonisolated static func normalized(_ location: FileBrowserLocation) -> FileBrowserLocation {
        if case .folder(let url) = location { return .folder(folderURL(url)) }
        return location
    }

    /// 今のフォルダを読み直し、読み終わったら `ids` を選んで最初の1件を見える位置へ(自分の操作で作ったもの)。
    func reload(selecting ids: Set<String>?) {
        if let ids {
            pendingSelection = ids
            didDeferPendingRequests = false
        }
        reload()
    }

    /// 読み込み中の場所の鍵(`FileBrowserLocation.selectionKey`。`.some(nil)` はコンピュータ)。読んでいなければ nil。
    private var inFlightFolderID: String??

    /// 今のフォルダを読み直す(選択は、残っている項目のぶんだけ保つ)。
    ///
    /// **同じフォルダを読んでいる最中なら重ねない**(読み終えてから 1 回だけ読み直す。2026-09-14 の 2 回目の監査 18)。
    /// `loadTask?.cancel()` は FileIO の上の列挙を止められないので、以前はアクティブ化・ボリュームの着脱のたびに、応答しない共有の
    /// 列挙で塞がったスレッドが 1 本ずつ積もった。
    func reload() {
        if let inFlight = inFlightFolderID, inFlight == location.selectionKey {
            needsReloadAfterLoad = true
            return
        }
        generation &+= 1
        let mine = generation
        loadTask?.cancel()
        let folder = currentFolder
        // 「最近の項目」の中身は履歴の写し(新しい順のまま。FileBrowserLocation の型コメント)。項目の属性はここで読む(FileIO の上)。
        let recentEntries: [RecentFilesStore.Entry]? = isShowingRecents ? (recentFiles?.entries ?? []) : nil
        // 並べ替えも読み込みと一緒に FileIO の上で(2026-09-25 の監査)。`localizedStandardCompare` の比較は数万件で数百ミリ秒に
        // なり、以前はメインで、アクティブ化・ホームへ戻る・FSEvents のたびに走っていた。読んでいる間に並びの設定が変わっていたら、
        // `apply` がメインで並べ直す。
        let sort = self.sort
        let includesHidden = showsHiddenFiles
        isLoading = true
        needsReloadAfterLoad = false
        inFlightFolderID = .some(location.selectionKey)
        loadTask = Task { [weak self] in
            defer {
                if let self, self.generation == mine { self.inFlightFolderID = nil }
                // 読んでいる間に届いた変更を、読み終えてから 1 回だけ拾う(同じ世代のままなら ―― 別の読み込みが
                // 始まっていれば、そちらが最新を読む)。
                if let self, self.generation == mine, self.needsReloadAfterLoad {
                    self.needsReloadAfterLoad = false
                    self.reload()
                }
            }
            let outcome: Result<[FileBrowserEntry], FileBrowserLoadError>
            var isWritable = true
            if let recentEntries {
                let mountTable = MountTable.current()
                outcome = .success(await FileIO.perform { FileBrowserListing.recentEntries(from: recentEntries, mountTable: mountTable) })
            } else if let folder {
                do {
                    let listed = try await FileIO.perform { () -> ([FileBrowserEntry], Bool) in
                        let entries = sort.sorted(try FileBrowserListing.entries(in: folder, includesHidden: includesHidden))
                        return (entries, (try? FileOperationPreflight.checkWritable(folder)) != nil)
                    }
                    outcome = .success(listed.0)
                    isWritable = listed.1
                } catch is CancellationError {
                    return
                } catch {
                    outcome = .failure(FileBrowserLoadError.classify(error, folder: folder))
                }
            } else {
                outcome = .success(await FileIO.perform { sort.sorted(FileBrowserListing.volumeEntries(mountTable: .current())) })
            }
            guard let self, self.generation == mine else { return }
            switch outcome {
            case .success(let list):
                if self.isCurrentFolderWritable != isWritable { self.isCurrentFolderWritable = isWritable }
                self.apply(list, sortedWith: sort)
            case .failure(.notFound), .failure(.volumeUnavailable):
                // 表示していたフォルダが消えた(移動・削除・ボリュームを外した)。空の一覧に
                // 「見つかりません」を出して止まるより、残っている祖先へ移るほうが次の操作に進める。
                guard let folder else { return }
                let ancestor = await FileIO.perform { FileBrowserListing.nearestExistingAncestor(of: folder) }
                guard self.generation == mine else { return }
                self.move(to: Self.location(of: ancestor), selecting: nil)
            case .failure(let error):
                self.isLoading = false
                self.allEntries = []
                self.loadError = error
                self.applyFilter()
            }
        }
    }

    /// 読み込みが(退避による読み直しを含めて)片付くまで待つ。**テストのための口。**
    func settle() async {
        while let task = loadTask {
            let before = generation
            await task.value
            if generation == before { return }
        }
    }

    // MARK: - 選択

    /// 矢印キー(アイコン表示)。起点は最後にクリック・移動した項目、無ければ選択の先頭。
    /// 移動先を1件だけ選んで、見える位置へスクロールする。
    ///
    /// `NSCollectionView` の標準の矢印キーを使わないのは、独自のレイアウト(`FileBrowserIconLayout`)では右矢印で真下へ移り、
    /// 下矢印で動かなかったため(2026-09-15 の実機検証)。
    ///
    /// `extending`(⇧)なら、起点(⇧ を付けずに最後に選んだ項目)から移動先までを選ぶ(Finder・スマートライブラリと同じ)。
    func moveSelection(_ direction: GridKeyboardNavigation.Direction, columns: Int, extending: Bool = false) {
        let current = selectionAnchor.flatMap { anchor in
            selection.contains(anchor) ? entries.firstIndex(where: { $0.id == anchor }) : nil
        } ?? entries.firstIndex(where: { selection.contains($0.id) })
        guard let target = GridKeyboardNavigation.target(
            from: current, count: entries.count, columns: columns, direction: direction
        ) else { return }
        let id = entries[target].id
        if extending, let current {
            let originID = selectionRangeOrigin.flatMap { selection.contains($0) ? $0 : nil } ?? entries[current].id
            if let origin = entries.firstIndex(where: { $0.id == originID }) {
                selection = Set(entries[min(origin, target)...max(origin, target)].map(\.id))
                selectionRangeOrigin = originID
            } else {
                selection = [id]
                selectionRangeOrigin = nil
            }
        } else {
            selection = [id]
            selectionRangeOrigin = nil
        }
        selectionAnchor = id
        scrollSerial += 1
        scrollRequest = ScrollRequest(id: id, serial: scrollSerial)
    }

    /// 矢印キーと type-select の起点を置く(アイコン表示でクリックして選んだ項目)。
    func setSelectionAnchor(_ id: String?) {
        selectionAnchor = id
        selectionRangeOrigin = nil
    }

    /// type-select(アイコン表示。リスト表示は`NSTableView`の標準)。打った文字を名前の先頭に持つ項目を1件だけ選んで、
    /// 見える位置へスクロールする。見つからなければ選択は変えない。
    ///
    /// - 前の入力から`typeSelectResetInterval`が過ぎたら打ち直し(溜めた文字を捨てる)。
    /// - **1文字のとき(同じ文字の連打を含む)は、いま選んでいる項目の次から**探して一巡する ―― 同じ頭文字の項目を
    ///   順に渡り歩ける。**2文字以上は先頭から**(打ち足すたびに選択が先へ逃げない)。
    /// - 比べ方は大小文字・濁点の有無・全角半角を区別しない、先頭一致(表示名)。
    ///
    /// - Returns: 選び直したか(テストのための戻り値。キーは見つからなくても受けたことにする)。
    @discardableResult
    func typeSelect(_ characters: String, now: Date = Date()) -> Bool {
        guard !characters.isEmpty else { return false }
        if let last = typeSelectLastInput, now.timeIntervalSince(last) < Self.typeSelectResetInterval {
            typeSelectBuffer += characters
        } else {
            typeSelectBuffer = characters
        }
        typeSelectLastInput = now
        guard !entries.isEmpty else { return false }

        let buffer = typeSelectBuffer
        let isSingleCharacter = Set(buffer.lowercased()).count == 1
        let needle = isSingleCharacter ? String(buffer.prefix(1)) : buffer
        let current = selectionAnchor.flatMap { anchor in
            selection.contains(anchor) ? entries.firstIndex(where: { $0.id == anchor }) : nil
        } ?? entries.firstIndex(where: { selection.contains($0.id) })
        let start = isSingleCharacter ? ((current ?? -1) + 1) : 0
        let options: String.CompareOptions = [.anchored, .caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        for offset in 0..<entries.count {
            let index = (start + offset) % entries.count
            guard entries[index].displayName.range(of: needle, options: options) != nil else { continue }
            let id = entries[index].id
            selection = [id]
            selectionAnchor = id
            scrollSerial += 1
            scrollRequest = ScrollRequest(id: id, serial: scrollSerial)
            return true
        }
        return false
    }

    /// type-select の打ち直しまでの間隔(秒)。
    static let typeSelectResetInterval: TimeInterval = 1

    /// 選んでいる項目(表示順)。**選択と一覧が変わるまでは作り直さない**(2026-09-15 の 4 回目の監査)。ContentView はこの状態の
    /// publish のたび(ピンチ・ツリーの幅のドラッグの 1 イベントごと)にメニューバーの値を作り、メニューバーも評価のたびに読むので、
    /// 以前は 10 万件のフォルダで毎回全件を絞り込んでいた。
    var selectedEntries: [FileBrowserEntry] {
        if let cache = selectedEntriesCache, cache.selection == selectionRevision, cache.entries == entriesRevision {
            return cache.value
        }
        let value = entries.filter { selection.contains($0.id) }
        selectedEntriesCache = (selectionRevision, entriesRevision, value)
        return value
    }

    private var selectedEntriesCache: (selection: Int, entries: Int, value: [FileBrowserEntry])?

    func entry(withID id: String) -> FileBrowserEntry? {
        entries.first { $0.id == id }
    }

    // MARK: - 読み込み結果の適用

    /// - Parameter sortedWith: `list` を並べた設定(`reload` が読み込みと一緒に並べる)。今の設定と違えば並べ直す。
    private func apply(_ list: [FileBrowserEntry], sortedWith: FolderBrowserSort) {
        if isLoading { isLoading = false }
        if loadError != nil { loadError = nil }
        let sorted = sortedWith == sort ? list : sort.sorted(list)
        // 読み直しても中身が同じ(アクティブ化・ホームへ戻る・関係の無い FSEvents のほとんど)なら差し替えない。差し替えは
        // `applyFilter` の比較で一覧の作り直し(reloadData と見えているセルの絵の頼み直し)を呼ばない。
        if sorted != allEntries {
            allEntries = sorted
            resolveLinkTargets()
        } else if allEntries.contains(where: \.isLink) {
            // 一覧は同じでも、リンクの先は動いたかもしれない(resolveLinkTargets のコメント。監査 FBU-2)。
            resolveLinkTargets()
        }
        settleRenameRequest()
        // 読んでいる最中に読み直しを頼まれていたら(`reload` のコメント)、この一覧は頼まれる前の姿かもしれない。選ぶ・見せる項目の依頼は
        // 次の読み直しまで取っておく(操作で作った項目がまだ無い一覧で依頼を使い切らない)。
        if needsReloadAfterLoad, !didDeferPendingRequests, pendingReveal != nil || pendingSelection != nil {
            didDeferPendingRequests = true
            applyFilter()
            return
        }
        didDeferPendingRequests = false
        if let reveal = pendingReveal {
            pendingReveal = nil
            // 絞り込みで隠れていたら出す(選んだのに見えない、を作らない)。移動の直後は空なので、
            // ここで効くのは同じフォルダの中の項目を reveal したときだけ。
            if !filteredAllEntries().contains(where: { $0.id == reveal }) {
                filterText = ""
            }
            selection = [reveal]
            applyFilter()
            scrollSerial += 1
            scrollRequest = ScrollRequest(id: reveal, serial: scrollSerial)
        } else if let wanted = pendingSelection {
            pendingSelection = nil
            // 集合で引く(2026-09-14 の 2 回目の監査 16。以前は選ぶ項目ごとに一覧を端から探し、2 万件のフォルダへ 1000 件を
            // 貼ると 3.4 秒メインを止めた)。
            let presentIDs = Set(allEntries.map(\.id))
            let present = wanted.filter(presentIDs.contains)
            // 置いた項目が絞り込みで 1 つも見えないなら、絞り込みを解く(reveal と同じ「選んだのに見えない、を作らない」。2026-09-19 の
            // 監査の L5: 以前は効果音だけ鳴って一覧が何も変わらなかった)。
            if !present.isEmpty, !filterText.isEmpty,
               !filteredAllEntries().contains(where: { present.contains($0.id) }) {
                filterText = ""
            }
            applyFilter()
            let visible = entries.filter { present.contains($0.id) }
            if !visible.isEmpty {
                selection = Set(visible.map(\.id))
                selectionAnchor = visible[0].id
                scrollSerial += 1
                scrollRequest = ScrollRequest(id: visible[0].id, serial: scrollSerial)
            }
        } else {
            applyFilter()
        }
    }

    /// 名前の編集の依頼に終わりを付ける(2026-09-19 の監査の M3)。読み終えた一覧に相手が無ければ依頼を捨て、絞り込みで隠れているなら
    /// 絞り込みを解く(reveal と同じ)。以前は「その id が一覧に現れるまで」残り続けたので、絞り込み中に新規フォルダを作ると、
    /// **後で絞り込みを解いた時点で名前の編集が始まった**(実測)。読み直しが控えている間は待つ(作った項目がまだ無い一覧かもしれない)。
    private func settleRenameRequest() {
        guard let request = renameRequest, !needsReloadAfterLoad else { return }
        guard allEntries.contains(where: { $0.id == request.id }) else {
            renameRequest = nil
            return
        }
        if !filterText.isEmpty, !filteredAllEntries().contains(where: { $0.id == request.id }) {
            filterText = ""
        }
    }

    // MARK: - 書く操作の補助(段階4)


    /// 項目がカット済みか(淡く描く)。
    func isCut(_ entry: FileBrowserEntry) -> Bool {
        !cutPaths.isEmpty && cutPaths.contains(MountTable.normalized(entry.url.standardizedFileURL.path))
    }

    func requestRename(_ id: String) {
        // 絞り込みで隠れている項目なら、絞り込みを解いてから頼む。一覧にまだ無い項目(作った直後)は、読み直して確かめる
        // (`settleRenameRequest` が、無ければ捨てる)。
        if allEntries.contains(where: { $0.id == id }) {
            if !filterText.isEmpty, !entries.contains(where: { $0.id == id }) { filterText = "" }
        } else if !isLoading {
            reload()
        }
        renameSerial += 1
        renameRequest = ScrollRequest(id: id, serial: renameSerial)
        selection = [id]
        selectionAnchor = id
        scrollSerial += 1
        scrollRequest = ScrollRequest(id: id, serial: scrollSerial)
    }

    /// 一覧が名前の編集を始めたら返してもらう。**残しておくと、表示形式を切り替えて作り直された一覧が
    /// 古い依頼をもう一度拾って、頼んでもいない編集を始める**(一覧は作り直すと「済んだ依頼」を覚えていない)。
    /// 一覧の更新の最中に呼ばれうるので、次のランループで下ろす。
    func finishRenameRequest(_ request: ScrollRequest) {
        Task { @MainActor [weak self] in
            guard let self, self.renameRequest == request else { return }
            self.renameRequest = nil
        }
    }

    /// どこが変わったか分からない変更(取り消し・やり直し。コマンドは何を戻したかを場所で返さない)。
    func noteFileSystemChangeInUnknownScope() {
        changeSerial += 1
        fileSystemChange = TreeReloadRequest(serial: changeSerial, folderIDs: [], isUnknownScope: true)
    }

    func noteFileSystemChange(in folders: [URL]) {
        guard !folders.isEmpty else { return }
        changeSerial += 1
        fileSystemChange = TreeReloadRequest(serial: changeSerial, folderIDs: Set(folders.map { Self.id(for: $0) }))
    }

    /// 並べ直す。**並びが変わらなければ一覧を差し替えない**(同じ変更を、自分で書いたときと購読の両方から受けるため)。
    /// 「最近の項目」は新しい順のまま(FileBrowserLocation の型コメント)。
    private func resort() {
        guard !allEntries.isEmpty, !isShowingRecents else { return }
        let sorted = sort.sorted(allEntries)
        guard sorted.map(\.id) != allEntries.map(\.id) else { return }
        allEntries = sorted
        applyFilter()
    }

    private func applyFilter() {
        // 同じ一覧なら差し替えない(2026-09-25 の監査)。`entriesRevision` はリスト・アイコン表示の `reloadData`(と見えているセルの
        // 絵の頼み直し)の合図なので、読み直しても何も変わっていない回に進めると、見た目の変わらない作り直しが走っていた。
        let filtered = filteredAllEntries()
        if filtered != entries {
            entries = filtered
            entriesRevision &+= 1
        }
        // 見えなくなった項目を選択から外す(filterTextのコメント)。
        let visible = Set(entries.map(\.id))
        let kept = selection.intersection(visible)
        if kept != selection { selection = kept }
    }

    /// 表示する場所を差し替えて読み込む。履歴は触らない(呼び出し側が積む)。
    private func move(to location: FileBrowserLocation, selecting reveal: String?) {
        let target = Self.normalized(location)
        if target.selectionKey != self.location.selectionKey {
            isShowingRecents = target.isRecents
            currentFolder = target.folder
            // 前のフォルダの中身を新しい場所の中身として見せない。
            allEntries = []
            filterText = ""
            applyFilter()
            loadError = nil
            // 前のフォルダの項目への名前の編集の依頼は、もう叶わない(finishRenameRequest のコメント)。
            renameRequest = nil
        }
        // ペーストした項目を選ぶ依頼は、移動・reveal の依頼が上書きする(フォルダが変わったときは 3 回目の監査 ―― 戻ってきたときに勝手に選ばない。
        // **同じフォルダの reveal でも捨てる**(4 回目の監査。reveal の依頼だけを使い、選ぶ依頼は残っていたので、後の読み直しで利用者が
        // 選び直した項目をペーストした項目で上書きしえた)。
        pendingSelection = nil
        selection = reveal.map { [$0] } ?? []
        pendingReveal = reveal
        didDeferPendingRequests = false
        rememberLastFolder()
        reload()
        updateWatcher()
    }

    private func pushBack(_ location: FileBrowserLocation) {
        backStack.append(location)
        if backStack.count > Self.historyDepth { backStack.removeFirst() }
    }

    // MARK: - 起動時のフォルダ

    /// 環境設定「起動時に表示するフォルダ」を解決する(実フォルダ。コンピュータ・最近の項目は nil)。`startupLocation` の
    /// 読み替え。
    func startupFolder() -> URL? {
        startupLocation().folder
    }

    /// 環境設定「起動時に表示するフォルダ」を解決する。見つからない指定はホームへ読み替える。「最後に表示したフォルダ」が
    /// 最近の項目で、いまは出せない(設定 OFF・シークレット)ならホーム。
    func startupLocation() -> FileBrowserLocation {
        let home = FileBrowserListing.realHomeDirectory()
        switch preferences?.fileBrowserStartupLocation ?? .home {
        case .home:
            return .folder(home)
        case .favorite:
            guard let id = UUID(uuidString: preferences?.fileBrowserStartupFavoriteID ?? ""),
                  let item = favoriteLocations?.item(withID: id)
            else { return .folder(home) }
            return .folder(item.url)
        case .lastFolder:
            guard let path = defaults.string(forKey: Keys.lastFolderPath) else { return .folder(home) }
            // 空文字はコンピュータにいた、の記録。
            if path.isEmpty { return .computer }
            if path == FileBrowserLocation.recentsSelectionKey { return canShowRecents ? .recents : .folder(home) }
            return .folder(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    // MARK: - 一括リネームの前回の入力(段階 5)

    /// 一括リネームのシートに出す前回の入力。**シークレットウインドウでは保存しない**(決定事項 Q8。打った文字に
    /// 蔵書の名前が入りうる)が、そのウインドウの間は覚えておく。
    var bulkRenameSettings: BulkRenameSettings {
        get {
            if let sessionBulkRenameSettings { return sessionBulkRenameSettings }
            guard let data = defaults.data(forKey: Keys.bulkRename),
                  let saved = try? JSONDecoder().decode(BulkRenameSettings.self, from: data)
            else { return BulkRenameSettings() }
            return saved
        }
        set {
            sessionBulkRenameSettings = newValue
            guard !isPrivate, let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.bulkRename)
        }
    }

    private func rememberLastFolder() {
        guard !isPrivate else { return }
        // 空文字はコンピュータ、`<recents>` は最近の項目(FileBrowserLocation.recentsSelectionKey)。
        defaults.set(isShowingRecents ? FileBrowserLocation.recentsSelectionKey : currentFolder?.path ?? "", forKey: Keys.lastFolderPath)
    }

    // MARK: - 変更の追従

    /// アプリ自身がファイルを動かした(このウインドウの操作・別のウインドウの操作・取り消し・自動リネーム)。
    ///
    /// 1. **パスで覚えているものを付け替える**: 表示中のフォルダ(自身か祖先の名前が変わった・移ったなら、退避せずに付いていく ――
    ///    FSEvents は祖先の変化を知らせないので、以前はもう無いフォルダの一覧を出し続けた)、戻る/進むの履歴、選択。
    /// 2. 表示中のフォルダの中身が変わっていたら読み直し、ツリーにも知らせる。**ネットワーク上のフォルダはこれが唯一の知らせ**。
    ///    このウインドウの操作が走っている最中は読み直さない(操作が済んだ時点で `didChangeFileSystem` が読み直す)。
    func handleFileSystemChange(_ change: FileSystemChange) {
        func relocated(_ location: FileBrowserLocation) -> FileBrowserLocation {
            guard let folder = location.folder, let path = change.relocatedPath(for: folder.path) else { return location }
            return .folder(Self.folderURL(URL(fileURLWithPath: path, isDirectory: true)))
        }
        backStack = backStack.map(relocated)
        forwardStack = forwardStack.map(relocated)
        let relocatedSelection = Set(selection.map { change.relocatedPath(for: $0) ?? $0 })
        if relocatedSelection != selection { selection = relocatedSelection }
        if let request = renameRequest, change.displaces(request.id) { renameRequest = nil }
        cutClipboard.forget(displacedBy: change)

        if let folder = currentFolder, let path = change.relocatedPath(for: folder.path) {
            let kept = selection
            move(to: .folder(URL(fileURLWithPath: path, isDirectory: true)), selecting: nil)
            selection = kept
        } else if let folder = currentFolder, change.requiresReload(ofFolderAt: folder.path), isVisible, !operations.isBusy {
            reload()
        }
        if isVisible {
            noteFileSystemChange(in: change.affectedFolderPaths.map { URL(fileURLWithPath: $0, isDirectory: true) })
        }
    }

    private func handleFolderChanged() {
        // ほかのアプリでコピーしてペーストボードが替わっていたら、カットの淡色を下ろす(FileCutClipboard の型コメント)。
        cutClipboard.validate(against: operations.pasteboard)
        guard isVisible else { return }
        reload()
    }

    /// FSEvents が知らせたパス(ファイル単位)。**表示中のフォルダ自身か、その直下の項目が変わったときだけ**読み直す
    /// (2026-09-14 の監査の 4)。
    ///
    /// FSEvents は渡したパスの**階層全体**のイベントを返す。以前はパスを見ずに読み直していたので、ホーム(既定の起動フォルダ)や
    /// `/` を表示している間は `~/Library` の下の書き込みで 0.3 秒ごとに再列挙が走り続けた。しかも `reload()` は前の列挙を
    /// 取り消すので、列挙に 0.3 秒以上かかるフォルダの配下でダウンロードやコピーが続く間は**一覧が永遠に出なかった**。
    /// そこで (1) 直下だけを見る(ツリーの `handleExternalChange` と同じ形)、(2) 読み込み中に届いたら取り消さずに
    /// 読み終えてからもう 1 回だけ読む。
    ///
    /// 2026-09-19 の監査で 2 つ足した(`eventsRequireReload`): **直下のフォルダの中で項目が増えた・減った・名前が変わった**ときも読み直す
    /// (そのフォルダの変更日が変わる。以前は日付と変更日順の並びが古いままだった ―― 実測。ツリーは 2026-09-17 に同じ件を直してある)。
    /// 中身の書き換えだけ(ダウンロードの途中など)では読み直さない。**イベントがあふれた知らせ**(`MustScanSubDirs`・取りこぼし)は、
    /// 表示中のフォルダの上でも下でも読み直す(個別のイベントが省かれているので、直下が変わっていないとは言えない)。
    private func handleChangedPaths(_ events: [FolderChangeWatcher.Event]) {
        guard isVisible, Self.eventsRequireReload(events, ofFolderSpelledAs: watchedFolderIDs) else { return }
        if loadTask != nil, isLoading {
            needsReloadAfterLoad = true
        } else {
            reload()
        }
    }

    /// FSEvents の知らせが、そのフォルダの一覧の読み直しを要るものか(`handleChangedPaths` のコメント)。
    nonisolated static func eventsRequireReload(_ events: [FolderChangeWatcher.Event], ofFolderSpelledAs spellings: Set<String>) -> Bool {
        guard !spellings.isEmpty else { return false }
        return events.contains { event in
            let path = MountTable.normalized(pathOutsideDataVolume(event.path))
            let parent = (path as NSString).deletingLastPathComponent
            if spellings.contains(path) || spellings.contains(parent) { return true }
            if event.isStructuralChange, spellings.contains((parent as NSString).deletingLastPathComponent) { return true }
            guard event.mustScanSubdirectories else { return false }
            return spellings.contains { MountTable.path($0, isAtOrUnder: path) || MountTable.path(path, isAtOrUnder: $0) }
        }
    }

    /// FSEvents が知らせたパスのどれかが、そのフォルダ自身か直下の項目か(`spellings` は `watchedFolderSpellings`)。
    nonisolated static func changedPaths(_ paths: [String], touchFolderSpelledAs spellings: Set<String>) -> Bool {
        guard !spellings.isEmpty else { return false }
        return paths.contains { raw in
            let path = MountTable.normalized(pathOutsideDataVolume(raw))
            return spellings.contains(path) || spellings.contains((path as NSString).deletingLastPathComponent)
        }
    }

    /// 起動ボリュームの利用者のデータは `/System/Volumes/Data` の上にあり、FSEvents がその頭を付けて知らせることがある
    /// (`/` を見張ったとき)。一覧・ツリーの行は頭の無いパスなので揃える。
    nonisolated static let dataVolumePrefix = "/System/Volumes/Data"

    nonisolated static func pathOutsideDataVolume(_ path: String) -> String {
        guard path.hasPrefix(dataVolumePrefix + "/") else { return path }
        return String(path.dropFirst(dataVolumePrefix.count))
    }

    /// FSEvents はリンクを解いた実際のパスで知らせる(`/var/…` は `/private/var/…`)。表示中のフォルダを両方の書き方で持つ。
    /// ブロッキングしうる問い合わせ(リンクの解決)をするので、ネットワーク上のフォルダには使わない(そもそも見張らない)。
    nonisolated static func watchedFolderSpellings(of folder: URL) -> Set<String> {
        let path = MountTable.normalized(folder.path)
        var spellings: Set<String> = [path]
        let resolved = MountTable.normalized(folder.resolvingSymlinksInPath().path)
        spellings.insert(resolved)
        // resolvingSymlinksInPath は頭の /private を外す(MountTable.normalized のコメント)ので、付けた形も足す。
        for candidate in [path, resolved] {
            let isUnderPrivateLink = ["/var", "/tmp", "/etc"].contains { MountTable.path(candidate, isAtOrUnder: $0) }
            if isUnderPrivateLink { spellings.insert("/private" + candidate) }
        }
        return spellings
    }

    /// FSEvents で今のフォルダを見張る。**見えている間だけ**(本を読んでいる間に見張っても、
    /// 戻ってきたときに読み直すので要らない)。
    ///
    /// **ネットワーク上のフォルダは見張らない**(FSEvents はそこでは飛ばず、応答しない共有では `FSEventStreamCreate` が
    /// 30 秒塞ぐ ―― FolderChangeWatcher の型コメント)。その代わりはアクティブ化とボリュームの着脱での読み直し。
    private func updateWatcher() {
        var paths: Set<String> = []
        if isVisible, let currentFolder, !MountTable.current().isRemote(currentFolder) {
            paths = [currentFolder.path]
            watchedFolderIDs = Self.watchedFolderSpellings(of: currentFolder)
        } else {
            watchedFolderIDs = []
        }
        guard let watcher else { return }
        // 一覧を読み始める前のイベント ID を起点に渡す(`FolderChangeWatcher.watch` のコメント。`move` / `activate` は読み込みを頼んだ
        // 同じ流れの中でここを呼ぶので、列挙はまだ始まっていない)。
        let startingAt = paths.isEmpty ? nil : FSEventsGetCurrentEventId()
        Task { await watcher.watch(paths, startingAt: startingAt) }
    }

    /// FSEvents はネットワークボリュームでは飛ばず、アプリが止められている間の変更も取りこぼしうる
    /// (FolderChangeWatcherの型コメント)。アクティブになったときと、ボリュームの着脱でも読み直す。
    private func observeSystem() {
        let appActive = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.handleFolderChanged()
                self?.refreshPasteboardState()
            }
        // ペーストボードの中身は購読できないので、ほかのアプリ・ほかのウインドウから戻ってきたときに確かめ直す
        // (`pasteboardHasFiles` のコメント)。
        let windowKey = NotificationCenter.default
            .publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in self?.refreshPasteboardState() }
        let workspace = NSWorkspace.shared.notificationCenter
        let volumes = Publishers.MergeMany(
            workspace.publisher(for: NSWorkspace.didMountNotification),
            workspace.publisher(for: NSWorkspace.didUnmountNotification),
            workspace.publisher(for: NSWorkspace.didRenameVolumeNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.handleFolderChanged() }
        systemObservations = [appActive, windowKey, volumes]
        refreshPasteboardState()
    }

    /// 履歴が変わったら「最近の項目」を読み直す(表示している間だけ。FileBrowserLocation の型コメント)。
    private func observeRecentFiles() {
        guard let recentFiles else {
            recentFilesObservation = nil
            return
        }
        recentFilesObservation = recentFiles.$entries
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isShowingRecents, self.isVisible else { return }
                    self.reload()
                }
            }
    }

    /// 「フォルダを上に」と、並べ替えの基準・向き(サイドパネルや他のウインドウで変わる。`sortKey`のコメント)を購読する。
    private func observePreferences() {
        guard let preferences else {
            preferenceObservation = nil
            fileChangePermissionObservation = nil
            recentsPreferenceObservation = nil
            return
        }
        // 「最近の項目」を OFF にされたら、戻る/進むの履歴から外し(残すと、押せる「戻る」が何もしないことになる ―― レビュー
        // 2026-09-29)、表示していた場合はホームフォルダへ(出せない場所に居続けない。履歴には積まない: 積むと最近の項目が戻り先になる)。
        recentsPreferenceObservation = preferences.$fileBrowserShowsRecents
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    guard let self, !enabled else { return }
                    if self.isShowingRecents {
                        self.move(to: .folder(FileBrowserListing.realHomeDirectory()), selecting: nil)
                    }
                    self.removeRecentsFromHistory()
                }
            }
        // ファイルを変えられなくなった瞬間(`FileBrowserOperations.isReadOnly` と同じ条件)に、名前の編集を取りやめてもらう。
        fileChangePermissionObservation = Publishers.CombineLatest(
            preferences.$fileBrowserReadOnly, preferences.$fileBrowserFeatureEnabled
        )
        .map { readOnly, enabled in readOnly || !enabled }
        .removeDuplicates()
        .dropFirst()
        .filter { $0 }
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.nameEditingCancelSerial &+= 1 }
        }
        preferenceObservation = Publishers.Merge3(
            preferences.$fileBrowserFoldersFirst.dropFirst().removeDuplicates().map { _ in () },
            preferences.$folderBrowserSortKey.dropFirst().removeDuplicates().map { _ in () },
            preferences.$folderBrowserSortDirection.dropFirst().removeDuplicates().map { _ in () }
        )
        // @Published は値が入る前に流れるので、1回待ってから読む(sort が新しい値を見るように)。
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            // メニューのチェックと列の見出しの矢印を描き直してもらう(並べ替わる項目が無くても)。
            self?.objectWillChange.send()
            self?.resort()
        }
        // つながった時点の設定で並べ直す(つながる前に読み込んだ一覧があれば)。
        resort()
    }

    // MARK: - パスの扱い

    /// 項目の id(`FileBrowserEntry.id`と同じ規則)。
    nonisolated static func id(for url: URL) -> String {
        url.path
    }

    nonisolated static func id(of folder: URL?) -> String? {
        folder.map(id(for:))
    }

    /// フォルダとして扱う URL にそろえる(末尾の`/`の有無で`==`が外れないように)。
    nonisolated static func folderURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: true)
    }

    /// 親フォルダ。ボリュームのルート(と`/`)の親はコンピュータ(nil)。
    nonisolated static func parent(of url: URL, mountTable: MountTable = .current()) -> URL? {
        let path = MountTable.normalized(url.path)
        if path == "/" || mountTable.entries.contains(where: { !$0.isHiddenFromBrowsing && $0.mountPoint == path }) {
            return nil
        }
        return folderURL(url.deletingLastPathComponent())
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

/// ファイルブラウザの右クリックから出す本のシート(改善要望7 段階 8、2026-09-14)。
///
/// 「メタデータの編集…」のシート(`BookMetadataSheet`)は 2026-09-30 に廃止した(ホームのインスペクタで直す。
/// FileBrowserActions.editMetadata)。残るのは「本の書き出し」だけ。
struct FileBrowserBookSheet: Identifiable {
    enum Kind {
        /// 「本の書き出し」。ビューアの右クリックと同じシート(OpenBookExportSheet)を、本を開かずに出す。
        case export(Export)
    }

    /// 書き出しの材料(ViewerView.OpenBookExportRequest と同じもの)。
    struct Export {
        let format: BookExportFormat
        let viewModel: BookExportViewModel
        /// 書き出す本。**ページは読まない**(`pages` は空): シートが使うのは id と場所だけで、書き出しは
        /// `BookLoader.load` で読み直す(BookExportViewModel.exportOne)。先に読むと大きな書庫を 2 回読むことになる。
        let book: MangaBook
        let destination: OpenBookExportSheet.Destination
        let asksBeforeExporting: Bool
    }

    let id = UUID()
    let kind: Kind

    func cancelExport() {
        if case .export(let export) = kind { export.viewModel.cancel() }
    }
}

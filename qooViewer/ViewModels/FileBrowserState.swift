import AppKit
import Combine
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

    /// いま表示しているフォルダ。nil は「コンピュータ」(ボリュームの一覧)。
    @Published private(set) var currentFolder: URL?
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
    /// 一覧に、この項目が見える位置までスクロールしてほしい(上へ移動・戻る・reveal のあと)。
    /// `serial`は同じ項目への2回目の依頼を別物にするため。
    @Published private(set) var scrollRequest: ScrollRequest?

    struct ScrollRequest: Equatable {
        let id: String
        let serial: Int
    }

    @Published var viewMode: FileBrowserViewMode {
        didSet {
            guard viewMode != oldValue else { return }
            defaults.set(viewMode.rawValue, forKey: Keys.viewMode)
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
    @Published private(set) var cutPaths: Set<String> = []
    /// 名前の編集を始めてほしい項目(新規フォルダの直後・右クリックの「名前を変更」)。
    /// 一覧はこの項目が見えるようになった時点で編集を始める。
    @Published private(set) var renameRequest: ScrollRequest?
    /// 「移動」メニューの「フォルダへ移動…」のシートを出しているか。
    @Published var isShowingGoToFolder = false
    /// 右クリックの「メタデータの編集…」「本の書き出し」のシート(段階 8)。nil なら出していない。
    @Published var bookSheet: FileBrowserBookSheet?
    /// 自分の操作でファイルが変わったフォルダ(ツリーが開いている行を読み直す)。
    @Published private(set) var fileSystemChange: FileSystemChange?
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

    /// アイコンの大きさを 1 段変える(メニューバーの「拡大」「縮小」。2026-09-15)。
    func stepIconSize(larger: Bool) {
        let next = Self.clamp(iconSize * (larger ? 1.25 : 0.8), to: Self.iconSizeRange)
        if next != iconSize { iconSize = next }
    }

    struct FileSystemChange: Equatable {
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
        }
    }
    /// 起動時のフォルダが「よく使う項目」のときに引く。
    weak var favoriteLocations: FavoriteLocationStore?
    /// シークレットウインドウか(最後に表示したフォルダを書かない)。ContentViewが渡す。
    var isPrivate = false

    var sort: FolderBrowserSort {
        FolderBrowserSort(
            grouping: (preferences?.fileBrowserFoldersFirst ?? true) ? .foldersFirst : .mixedByName,
            key: sortKey, direction: sortDirection
        )
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    /// 「コンピュータ」より上は無い。
    var canGoUp: Bool { currentFolder != nil }

    /// 読み込みの待ち合わせ口。**テストのための口**で、アプリ側は触らない(SidePanelBrowserState.
    /// reloadTaskと同じ)。退避(消えたフォルダ → 祖先)で読み込みが続けて起きるので、
    /// 待つ側は`settle()`を使う。
    private(set) var loadTask: Task<Void, Never>?

    private var allEntries: [FileBrowserEntry] = []
    private var backStack: [URL?] = []
    private var forwardStack: [URL?] = []
    private var generation = 0
    private var hasStarted = false
    /// 次に画面に出たときの行き先(prepare / show)。
    private var pendingDestination: Destination?
    private var isVisible = false
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
    private var systemObservations: [AnyCancellable] = []
    private var toastDismissTask: Task<Void, Never>?
    private let defaults: UserDefaults

    /// 知らせを出しておく時間(ビューアのトーストと同じ 2 秒。ViewerView.showToast)。
    static let toastDuration: Duration = .seconds(2)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        viewMode = FileBrowserViewMode(rawValue: defaults.string(forKey: Keys.viewMode) ?? "") ?? .list
        hiddenListColumns = defaults.stringArray(forKey: Keys.hiddenListColumns).map(Set.init)
            ?? Self.defaultHiddenListColumns
        iconSize = (defaults.object(forKey: Keys.iconSize) as? Double)
            .map { Self.clamp(CGFloat($0), to: Self.iconSizeRange) } ?? Self.defaultIconSize
        treeWidth = (defaults.object(forKey: Keys.treeWidth) as? Double)
            .map { Self.clamp(CGFloat($0), to: Self.treeWidthRange) } ?? Self.defaultTreeWidth
        watcher = FolderChangeWatcher(onChangedPaths: { [weak self] paths in
            // FSEvents 自身のキューから呼ばれる(FolderChangeWatcher.init のコメント)。
            Task { @MainActor [weak self] in self?.handleChangedPaths(paths) }
        })
        observeSystem()
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
            move(to: startupFolder(), selecting: nil)
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

    /// ファイルブラウザが画面から消えたとき(本を開いた・本棚へ切り替えた)。監視を止める。
    func deactivate() {
        isVisible = false
        updateWatcher()
    }

    /// ウインドウを閉じるとき。FSEvents のストリームと購読を手放す(ARC任せにすると、閉じた
    /// ウインドウのぶんの監視が次のイベントまで残る)。
    func releaseResources() {
        isVisible = false
        loadTask?.cancel()
        loadTask = nil
        watcher?.tearDown()
        systemObservations.removeAll()
        preferenceObservation = nil
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
        let target = folder.map(Self.folderURL(_:))
        if Self.id(of: target) != Self.id(of: currentFolder) {
            pushBack(currentFolder)
            forwardStack.removeAll()
        }
        move(to: target, selecting: nil)
    }

    /// 1階層上へ。ボリュームのルートならコンピュータへ。元いたフォルダを選んで見える位置へ
    /// スクロールする(サイドパネルのgoUpと同じ)。
    func goUp() {
        guard let leaving = currentFolder else { return }
        pushBack(currentFolder)
        forwardStack.removeAll()
        move(to: Self.parent(of: leaving), selecting: Self.id(for: leaving))
    }

    /// 戻る。**戻り先が直前のフォルダの親なら、そのフォルダを選ぶ**(上へ移動したのと同じ見え方にする)。
    func goBack() {
        guard let previous = backStack.popLast() else { return }
        let leaving = currentFolder
        forwardStack.append(leaving)
        var highlight: String?
        if let leaving, Self.id(of: Self.parent(of: leaving)) == Self.id(of: previous) {
            highlight = Self.id(for: leaving)
        }
        move(to: previous, selecting: highlight)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        pushBack(currentFolder)
        move(to: next, selecting: nil)
    }

    /// 項目の入っているフォルダへ移動して、その項目を選んでスクロールする。
    func reveal(_ url: URL) {
        let parent = Self.parent(of: url)
        if Self.id(of: parent) != Self.id(of: currentFolder) {
            pushBack(currentFolder)
            forwardStack.removeAll()
        }
        move(to: parent, selecting: Self.id(for: url))
    }

    /// 今のフォルダを読み直し、読み終わったら `ids` を選んで最初の1件を見える位置へ(自分の操作で作ったもの)。
    func reload(selecting ids: Set<String>?) {
        if let ids {
            pendingSelection = ids
            didDeferPendingRequests = false
        }
        reload()
    }

    /// 読み込み中のフォルダの id(`.some(nil)` はコンピュータ)。読んでいなければ nil。
    private var inFlightFolderID: String??

    /// 今のフォルダを読み直す(選択は、残っている項目のぶんだけ保つ)。
    ///
    /// **同じフォルダを読んでいる最中なら重ねない**(読み終えてから 1 回だけ読み直す。2026-09-14 の 2 回目の監査 18)。
    /// `loadTask?.cancel()` は FileIO の上の列挙を止められないので、以前はアクティブ化・ボリュームの着脱のたびに、応答しない共有の
    /// 列挙で塞がったスレッドが 1 本ずつ積もった。
    func reload() {
        if let inFlight = inFlightFolderID, inFlight == Self.id(of: currentFolder) {
            needsReloadAfterLoad = true
            return
        }
        generation &+= 1
        let mine = generation
        loadTask?.cancel()
        let folder = currentFolder
        isLoading = true
        needsReloadAfterLoad = false
        inFlightFolderID = .some(Self.id(of: folder))
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
            if let folder {
                do {
                    outcome = .success(try await FileIO.perform { try FileBrowserListing.entries(in: folder) })
                } catch is CancellationError {
                    return
                } catch {
                    outcome = .failure(FileBrowserLoadError.classify(error, folder: folder))
                }
            } else {
                outcome = .success(await FileIO.perform { FileBrowserListing.volumeEntries(mountTable: .current()) })
            }
            guard let self, self.generation == mine else { return }
            switch outcome {
            case .success(let list):
                self.apply(list)
            case .failure(.notFound), .failure(.volumeUnavailable):
                // 表示していたフォルダが消えた(移動・削除・ボリュームを外した)。空の一覧に
                // 「見つかりません」を出して止まるより、残っている祖先へ移るほうが次の操作に進める。
                guard let folder else { return }
                let ancestor = await FileIO.perform { FileBrowserListing.nearestExistingAncestor(of: folder) }
                guard self.generation == mine else { return }
                self.move(to: ancestor, selecting: nil)
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
    func moveSelection(_ direction: GridKeyboardNavigation.Direction, columns: Int) {
        let current = selectionAnchor.flatMap { anchor in
            selection.contains(anchor) ? entries.firstIndex(where: { $0.id == anchor }) : nil
        } ?? entries.firstIndex(where: { selection.contains($0.id) })
        guard let target = GridKeyboardNavigation.target(
            from: current, count: entries.count, columns: columns, direction: direction
        ) else { return }
        let id = entries[target].id
        selection = [id]
        selectionAnchor = id
        scrollSerial += 1
        scrollRequest = ScrollRequest(id: id, serial: scrollSerial)
    }

    /// 矢印キーと type-select の起点を置く(アイコン表示でクリックして選んだ項目)。
    func setSelectionAnchor(_ id: String?) {
        selectionAnchor = id
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

    private func apply(_ list: [FileBrowserEntry]) {
        isLoading = false
        loadError = nil
        allEntries = sort.sorted(list)
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
            if !FileBrowserListing.filtered(allEntries, by: filterText).contains(where: { $0.id == reveal }) {
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

    // MARK: - 書く操作の補助(段階4)

    func setCutPaths(_ paths: Set<String>) {
        if cutPaths != paths { cutPaths = paths }
    }

    /// 項目がカット済みか(淡く描く)。
    func isCut(_ entry: FileBrowserEntry) -> Bool {
        !cutPaths.isEmpty && cutPaths.contains(MountTable.normalized(entry.url.standardizedFileURL.path))
    }

    func requestRename(_ id: String) {
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
        fileSystemChange = FileSystemChange(serial: changeSerial, folderIDs: [], isUnknownScope: true)
    }

    func noteFileSystemChange(in folders: [URL]) {
        guard !folders.isEmpty else { return }
        changeSerial += 1
        fileSystemChange = FileSystemChange(serial: changeSerial, folderIDs: Set(folders.map { Self.id(for: $0) }))
    }

    /// 並べ直す。**並びが変わらなければ一覧を差し替えない**(同じ変更を、自分で書いたときと購読の両方から受けるため)。
    private func resort() {
        guard !allEntries.isEmpty else { return }
        let sorted = sort.sorted(allEntries)
        guard sorted.map(\.id) != allEntries.map(\.id) else { return }
        allEntries = sorted
        applyFilter()
    }

    private func applyFilter() {
        entries = FileBrowserListing.filtered(allEntries, by: filterText)
        entriesRevision &+= 1
        // 見えなくなった項目を選択から外す(filterTextのコメント)。
        let visible = Set(entries.map(\.id))
        let kept = selection.intersection(visible)
        if kept != selection { selection = kept }
    }

    /// 表示するフォルダを差し替えて読み込む。履歴は触らない(呼び出し側が積む)。
    private func move(to folder: URL?, selecting reveal: String?) {
        let target = folder.map(Self.folderURL(_:))
        if Self.id(of: target) != Self.id(of: currentFolder) {
            currentFolder = target
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

    private func pushBack(_ folder: URL?) {
        backStack.append(folder)
        if backStack.count > Self.historyDepth { backStack.removeFirst() }
    }

    // MARK: - 起動時のフォルダ

    /// 環境設定「起動時に表示するフォルダ」を解決する。見つからない指定はホームへ読み替える。
    func startupFolder() -> URL? {
        let home = FileBrowserListing.realHomeDirectory()
        switch preferences?.fileBrowserStartupLocation ?? .home {
        case .home:
            return home
        case .favorite:
            guard let id = UUID(uuidString: preferences?.fileBrowserStartupFavoriteID ?? ""),
                  let item = favoriteLocations?.item(withID: id)
            else { return home }
            return item.url
        case .lastFolder:
            guard let path = defaults.string(forKey: Keys.lastFolderPath) else { return home }
            // 空文字はコンピュータにいた、の記録。
            return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
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
        defaults.set(currentFolder?.path ?? "", forKey: Keys.lastFolderPath)
    }

    // MARK: - 変更の追従

    private func handleFolderChanged() {
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
    private func handleChangedPaths(_ paths: [String]) {
        guard isVisible, Self.changedPaths(paths, touchFolderSpelledAs: watchedFolderIDs) else { return }
        if loadTask != nil, isLoading {
            needsReloadAfterLoad = true
        } else {
            reload()
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
        Task { await watcher.watch(paths) }
    }

    /// FSEvents はネットワークボリュームでは飛ばず、アプリが止められている間の変更も取りこぼしうる
    /// (FolderChangeWatcherの型コメント)。アクティブになったときと、ボリュームの着脱でも読み直す。
    private func observeSystem() {
        let appActive = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.handleFolderChanged() }
        let workspace = NSWorkspace.shared.notificationCenter
        let volumes = Publishers.MergeMany(
            workspace.publisher(for: NSWorkspace.didMountNotification),
            workspace.publisher(for: NSWorkspace.didUnmountNotification),
            workspace.publisher(for: NSWorkspace.didRenameVolumeNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.handleFolderChanged() }
        systemObservations = [appActive, volumes]
    }

    /// 「フォルダを上に」と、並べ替えの基準・向き(サイドパネルや他のウインドウで変わる。`sortKey`のコメント)を購読する。
    private func observePreferences() {
        guard let preferences else {
            preferenceObservation = nil
            return
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
struct FileBrowserBookSheet: Identifiable {
    enum Kind {
        /// 「メタデータの編集…」。コレクションの外の本でも編集できる版(BookMetadataSheet.init(fileBrowserEntry:))。
        /// 項目ごと渡す(カバーの面の絵をアイコン表示と同じ提供役から引く。鍵に更新日時・サイズ、種類に「フォルダか」が要る)。
        case metadata(FileBrowserEntry)
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

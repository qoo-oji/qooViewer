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
        static let sortKey = "qooViewer.fileBrowser.sortKey"
        static let sortDirection = "qooViewer.fileBrowser.sortDirection"
        static let iconSize = "qooViewer.fileBrowser.iconSize"
        static let treeWidth = "qooViewer.fileBrowser.treeWidth"
        static let lastFolderPath = "qooViewer.fileBrowser.lastFolderPath"
    }

    static let iconSizeRange: ClosedRange<CGFloat> = 48...256
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
    @Published var selection: Set<String> = []
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

    @Published var sortKey: FolderBrowserSortKey {
        didSet {
            guard sortKey != oldValue else { return }
            defaults.set(sortKey.rawValue, forKey: Keys.sortKey)
            resort()
        }
    }

    @Published var sortDirection: FolderBrowserSortDirection {
        didSet {
            guard sortDirection != oldValue else { return }
            defaults.set(sortDirection.rawValue, forKey: Keys.sortDirection)
            resort()
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
    /// 自分の操作でファイルが変わったフォルダ(ツリーが開いている行を読み直す)。
    @Published private(set) var fileSystemChange: FileSystemChange?

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
    private var pendingFolder: URL?
    private var isVisible = false
    /// 読み込みが終わったら選んでスクロールする項目(上へ・戻る・reveal)。
    private var pendingReveal: String?
    /// 読み込みが終わったら選ぶ項目(ペーストで運んだもの)。
    private var pendingSelection: Set<String>?
    private var changeSerial = 0
    private var renameSerial = 0
    private var stackObservation: AnyCancellable?
    /// ⇧クリックと矢印キーの起点。
    private var selectionAnchor: String?
    private var scrollSerial = 0
    private var watcher: FolderChangeWatcher?
    private var preferenceObservation: AnyCancellable?
    private var systemObservations: [AnyCancellable] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        viewMode = FileBrowserViewMode(rawValue: defaults.string(forKey: Keys.viewMode) ?? "") ?? .list
        sortKey = FolderBrowserSortKey(rawValue: defaults.string(forKey: Keys.sortKey) ?? "") ?? .name
        sortDirection = FolderBrowserSortDirection(
            rawValue: defaults.string(forKey: Keys.sortDirection) ?? ""
        ) ?? .ascending
        iconSize = (defaults.object(forKey: Keys.iconSize) as? Double)
            .map { Self.clamp(CGFloat($0), to: Self.iconSizeRange) } ?? Self.defaultIconSize
        treeWidth = (defaults.object(forKey: Keys.treeWidth) as? Double)
            .map { Self.clamp(CGFloat($0), to: Self.treeWidthRange) } ?? Self.defaultTreeWidth
        watcher = FolderChangeWatcher { [weak self] in
            // FSEvents 自身のキューから呼ばれる(FolderChangeWatcher.init のコメント)。
            Task { @MainActor [weak self] in self?.handleFolderChanged() }
        }
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
        if let folder = folder ?? pendingFolder {
            pendingFolder = nil
            hasStarted = true
            navigate(to: folder)
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
    func prepare(showing folder: URL) {
        pendingFolder = folder
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
        operations.presenter = nil
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
        if let ids { pendingSelection = ids }
        reload()
    }

    /// 今のフォルダを読み直す(選択は、残っている項目のぶんだけ保つ)。
    func reload() {
        generation &+= 1
        let mine = generation
        loadTask?.cancel()
        let folder = currentFolder
        isLoading = true
        loadTask = Task { [weak self] in
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

    /// クリックの修飾(アイコン表示で使う。リスト表示は`NSTableView`が自前で同じことをする)。
    enum ClickModifier {
        /// その1件だけを選ぶ。
        case none
        /// ⌘: その1件の選択を反転する。
        case toggle
        /// ⇧: 起点からその1件までを選ぶ。
        case range
    }

    /// 項目をクリックした(Finderのアイコン表示と同じ規則)。
    func click(_ id: String, modifier: ClickModifier) {
        switch modifier {
        case .none:
            selection = [id]
            selectionAnchor = id
        case .toggle:
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        case .range:
            guard let anchor = selectionAnchor, let from = entries.firstIndex(where: { $0.id == anchor }),
                  let to = entries.firstIndex(where: { $0.id == id })
            else {
                selection = [id]
                selectionAnchor = id
                return
            }
            selection = Set(entries[min(from, to)...max(from, to)].map(\.id))
        }
    }

    /// 矢印キー(アイコン表示)。起点は最後にクリック・移動した項目、無ければ選択の先頭。
    /// 移動先を1件だけ選んで、見える位置へスクロールする。
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

    /// 選んでいる項目(表示順)。
    var selectedEntries: [FileBrowserEntry] {
        entries.filter { selection.contains($0.id) }
    }

    func entry(withID id: String) -> FileBrowserEntry? {
        entries.first { $0.id == id }
    }

    // MARK: - 読み込み結果の適用

    private func apply(_ list: [FileBrowserEntry]) {
        isLoading = false
        loadError = nil
        allEntries = sort.sorted(list)
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
            let present = wanted.filter { id in allEntries.contains { $0.id == id } }
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

    private func resort() {
        guard !allEntries.isEmpty else { return }
        allEntries = sort.sorted(allEntries)
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
        }
        selection = reveal.map { [$0] } ?? []
        pendingReveal = reveal
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

    private func rememberLastFolder() {
        guard !isPrivate else { return }
        defaults.set(currentFolder?.path ?? "", forKey: Keys.lastFolderPath)
    }

    // MARK: - 変更の追従

    private func handleFolderChanged() {
        guard isVisible else { return }
        reload()
    }

    /// FSEvents で今のフォルダを見張る。**見えている間だけ**(本を読んでいる間に見張っても、
    /// 戻ってきたときに読み直すので要らない)。
    private func updateWatcher() {
        let paths: Set<String> = if isVisible, let currentFolder { [currentFolder.path] } else { [] }
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

    private func observePreferences() {
        preferenceObservation = preferences?.$fileBrowserFoldersFirst
            .dropFirst()
            .removeDuplicates()
            // @Published は値が入る前に流れるので、1回待ってから読む(sort が新しい値を見るように)。
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resort() }
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

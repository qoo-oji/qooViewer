import AppKit
import SwiftUI

/// ファイルブラウザの左のツリー(改善要望7 段階3、2026-09-13)。`NSOutlineView`を包む。
///
/// 3つのグループ: **ボリューム**(マウント表から。着脱で作り直す)/ **ホーム**(実際のホーム1行)/
/// **よく使う項目**(FavoriteLocationStore。見出しの右に「＋」)。
///
/// ■ 子は開いたときだけ読み、たたんだら捨てる
/// 子を読むとき、**それぞれの子に直下のサブフォルダがあるかも 1 回だけ調べ**、無ければその行に三角を出さない
/// (2026-09-13、ユーザー要望。qooLibrary と同じ。`DirectoryProbe`)。段階3では TCC と往復を理由に調べていなかったが、
/// TCC の保護下の場所はパスだけで除外し、ネットワーク越しの場所はマウント表で除外すれば避けられる。
/// 調べていない・調べられない行(ボリューム・ホーム・よく使う項目の根、保護下、ネットワーク、読めない)は
/// 今までどおり三角を出す(`Node.hasSubfolders` が nil)。
/// **起動時はボリュームもホームも閉じている**(要望)。展開の状態は保存しない。
///
/// ■ クリック
/// 行を選ぶと右ペインがそのフォルダへ移る。右ペインで移動したら、そのフォルダの行が見えていれば
/// 選んだ状態にする(見えていなければ選択を外す ―― 違う行が選ばれたまま残らないように)。
///
/// ■ 現在のフォルダまで開く(環境設定、既定OFF。2026-09-14、ユーザー要望)
/// ON なら右ペインで移動するたびに、現在のフォルダを含む根(ボリューム・ホーム・よく使う項目)のうち**いちばん深いもの**
/// から、現在のフォルダの親までの行を 1 段ずつ開き、現在のフォルダの行を選んで見える位置へスクロールする
/// (道筋は FileBrowserTreePath)。約束事:
/// - **右ペインがそのフォルダを読み終えてから始める**(読めなかったら開かない)。道筋の階層はどれも現在のフォルダの
///   祖先なので、右ペインが読めた以上 TCC の確認をここで新しく出すことはない。
/// - 子は開いたときに `FileIO` で読む非同期なので、**1 段ずつ読み終わるのを待って**次を開く。途中で別のフォルダへ
///   移った・ツリーの行をクリックした・設定を OFF にしたら、世代番号で残りをやめる。
/// - ツリーの行をクリックして移動したときは何もしない(その行はもう見えている)。開いたほかの行はたたまない。
/// - 隠しフォルダ・パッケージ・リンクの先など、ツリーに出ない階層で道筋が切れたら、**その展開で開いた行をたたみ直す**
///   (2026-09-14。以前はそこまで開いたまま残り、現在のフォルダが見えないのに途中の行だけが開いていた ―― 計画 §4.13)。
///   前から開いていた行はたたまない。
///
/// ■ 外での変更(2026-09-14)
/// Finder など外でフォルダを作った・消した・名前を変えたときも、**開いている行を FSEvents で見張って**読み直す
/// (それまでは親をたたんで開き直すまで反映されなかった ―― 計画 §4.9)。見張るのは開いている行のうちいちばん上のものだけ
/// (FSEvents は配下も知らせる)。変わった項目の**親の行**だけを読み直し、閉じている行は三角の有無だけ調べ直す。
/// FSEvents はネットワークの共有では当てにならないので、アプリがアクティブになったときに共有の上の開いている行も読み直す。
///
/// ■ 子の並び(環境設定、既定OFF。2026-09-14、ユーザー要望)
/// 開いた行の子(サブフォルダ)は、既定では名前の昇順。「サブフォルダを右と同じ順に並べる」が ON なら、右ペインと同じ
/// 並べ替えの基準・向き(`FileBrowserState.sort`。比較は `FolderBrowserSort.sorted` を共有するので、右ペインに並ぶフォルダ
/// 同士の前後とツリーの並びは必ず一致する。子はフォルダだけなので「フォルダを上に」は効かない)。
/// **根(ボリューム・ホーム・よく使う項目)の並びは変えない**(ボリュームは起動ボリュームが先頭、よく使う項目は並べ替えた順)。
/// 並べ替えに要る値(サイズ・種類・日付)は子を読むときの `FileBrowserEntry` を行に持たせておき、基準が変わったら
/// **読み直さずに**読み込み済みの子を並べ直す(同じ Node を使い回すので、開いている孫の行は閉じない)。
///
/// ■ ドラッグ&ドロップ(段階4b)
/// どの行(ボリューム・ホーム・よく使う項目・フォルダ)の上にも落とせる。行の間へ落とそうとしたら、
/// その行の親のフォルダの上へ落とす形に直す(グループの見出しの中なら断る)。掴んで運べるのは
/// **ふつうのフォルダの行だけ** ―― ボリューム・ホーム・よく使う項目の行を動かすと、ツリーの根そのものが
/// 消える(よく使う項目は登録したパスを失う)。
///
/// ■ よく使う項目の並べ替え(2026-09-14、ユーザー要望)
/// よく使う項目の行は**並べ替えのためだけに**掴める。運ぶのは項目の id だけ(`fileBrowserFavoriteLocationPasteboardType`。
/// ファイルの URL は書かないので、フォルダの行・リスト・Finder へ落としても何も起きない)。落とせるのはよく使う項目の
/// 行の間だけで、行の上へ落とそうとしたら、その行の上半分なら前・下半分なら後ろへ入れる形に直す。
/// 並びは保存されるので、シークレットウインドウでは掴めない(「＋」「削除」と同じ)。
struct FileBrowserTreeView: NSViewRepresentable {
    @ObservedObject var state: FileBrowserState
    @ObservedObject var favoriteLocations: FavoriteLocationStore
    let actions: FileBrowserActions
    let outlineWidth: CGFloat
    let locale: Locale
    /// よく使う項目の「＋」と「削除」を許すか(シークレットウインドウでは false)。
    let allowsEditingFavorites: Bool
    /// 右ペインで移動するたびに現在のフォルダまで開くか(型コメント「現在のフォルダまで開く」)。
    let expandsToCurrentFolder: Bool
    /// 開いた行の子を並べる順(型コメント「子の並び」)。
    let childSort: FolderBrowserSort

    /// 「右と同じ順」が OFF のときの子の並び(従来の名前の昇順と同じ)。
    static let nameSort = FolderBrowserSort(grouping: .mixedByName, key: .name, direction: .ascending)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let outline = FileBrowserOutlineView()
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.focusRingType = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        outline.dataSource = coordinator
        outline.delegate = coordinator
        configureFileBrowserDragSource(outline)
        outline.registerForDraggedTypes([.fileURL, fileBrowserFavoriteLocationPasteboardType])
        outline.editResponder = actions
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        coordinator.outline = outline
        coordinator.update(from: self)
        coordinator.start()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
        if let outline = coordinator.outline {
            outline.dataSource = nil
            outline.delegate = nil
            outline.unregisterDraggedTypes()
            outline.editResponder = nil
            outline.menu?.delegate = nil
            outline.menu = nil
        }
        coordinator.outline = nil
        coordinator.state = nil
        coordinator.actions = nil
    }

    // MARK: - 行

    @MainActor
    final class Node: NSObject {
        enum Kind: Equatable {
            case group(Group)
            case volume
            case home
            case favorite(UUID)
            case folder
        }

        enum Group: CaseIterable {
            case volumes, home, favorites

            var title: String.LocalizationValue {
                switch self {
                case .volumes: "Volumes"
                case .home: "Home"
                case .favorites: "Favorite Locations"
                }
            }
        }

        let kind: Kind
        let url: URL?
        let name: String
        /// nil = まだ読んでいない(または、たたんで捨てた)。
        var children: [Node]?
        /// 読み込みの世代(たたんでから開き直したとき、前の読み込みの結果を捨てる)。
        var loadGeneration = 0
        /// 直下にツリーに出るサブフォルダがあるか。**false のときだけ三角を消す**。nil は調べていない・調べられない
        /// (三角を出す。誤って消すと行き止まりになるが、誤って出しても「開いたら空」で済む)。
        var hasSubfolders: Bool?
        /// いちばん新しい子の読み込み。「現在のフォルダまで開く」が読み終わりを待つ。
        var childrenTask: Task<Void, Never>?
        /// 子を読んでいる最中か(`loadChildren` のコメント)。
        var isLoadingChildren = false
        /// 読んでいる最中に読み直しを頼まれた(読み終えたら 1 回だけ読み直す)。
        var needsReloadAfterLoad = false
        /// 読み込んだときの一覧の行(フォルダの行だけ)。子の並べ替えに使う(型コメント「子の並び」)。
        var listing: FileBrowserEntry?

        init(
            kind: Kind, url: URL?, name: String, children: [Node]? = nil, hasSubfolders: Bool? = nil,
            listing: FileBrowserEntry? = nil
        ) {
            self.kind = kind
            self.url = url
            self.name = name
            self.children = children
            self.hasSubfolders = hasSubfolders
            self.listing = listing
        }

        var isGroup: Bool {
            if case .group = kind { return true }
            return false
        }

        /// 読み込んで子を出す行か(グループは自前で持つ)。
        var loadsChildren: Bool { !isGroup }

        var entry: FileBrowserEntry? {
            guard let url else { return nil }
            return FileBrowserEntry(
                url: url, displayName: name, isDirectory: true, isPackage: false, isSymbolicLink: false,
                isVolume: kind == .volume, fileSize: nil, typeDescription: nil, creationDate: nil,
                modificationDate: nil
            )
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        weak var outline: FileBrowserOutlineView?
        var state: FileBrowserState?
        var actions: FileBrowserActions?
        private weak var favoriteLocations: FavoriteLocationStore?
        private var outlineWidth: CGFloat = 0
        private var locale = Locale.current
        private var allowsEditingFavorites = false
        private var appliedFavorites: [FavoriteLocationStore.Item] = []
        private var appliedFolderID: String??
        private var appliedChange: FileBrowserState.FileSystemChange?
        private var isApplyingSelection = false
        private let menuBuilder = FileBrowserMenuBuilder()
        private var volumeObservers: [NSObjectProtocol] = []
        private var volumeLoadGeneration = 0
        /// ボリュームの一覧を 1 度読み終えたか(それまではボリュームの配下へ開けない)。
        private var hasLoadedVolumes = false
        private var expandsToCurrentFolder = false
        private var childSort = FileBrowserTreeView.nameSort
        /// 右ペインが読み終わったら開く、現在のフォルダの id。
        private var pendingRevealFolderID: String?
        /// 「現在のフォルダまで開く」の世代(型コメントの「途中でやめる」)。
        private var revealGeneration = 0
        /// 開いている行の見張り(型コメント「外での変更」)。
        private var watcher: FolderChangeWatcher?
        private var watchUpdateScheduled = false
        private var activationObserver: NSObjectProtocol?

        private let volumesGroup = Node(kind: .group(.volumes), url: nil, name: "", children: [])
        private let homeGroup: Node = {
            let home = FileBrowserListing.realHomeDirectory()
            return Node(
                kind: .group(.home), url: nil, name: "",
                children: [Node(kind: .home, url: home, name: home.lastPathComponent)]
            )
        }()
        private let favoritesGroup = Node(kind: .group(.favorites), url: nil, name: "", children: [])
        private var groups: [Node] { [volumesGroup, homeGroup, favoritesGroup] }

        func start() {
            guard let outline else { return }
            outline.reloadData()
            // グループの見出しは開いた状態で始める(中の行は閉じている ―― 型コメント)。
            for group in groups { outline.expandItem(group) }
            reloadVolumes()
            watcher = FolderChangeWatcher(onChangedPaths: { [weak self] paths in
                // FSEvents 自身のキューから呼ばれる(FolderChangeWatcher.init のコメント)。
                Task { @MainActor [weak self] in self?.handleExternalChange(paths) }
            })
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadRemoteExpandedRows() }
            }
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                         NSWorkspace.didRenameVolumeNotification] {
                volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reloadVolumes() }
                })
            }
        }

        func stop() {
            let center = NSWorkspace.shared.notificationCenter
            volumeObservers.forEach(center.removeObserver)
            volumeObservers.removeAll()
            if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
            activationObserver = nil
            watcher?.tearDown()
            watcher = nil
        }

        // MARK: 外での変更

        /// 開いている行が変わったら、見張るフォルダを入れ替える。開閉が続いても 1 回にまとめる(次のランループで)。
        private func scheduleWatchUpdate() {
            guard !watchUpdateScheduled else { return }
            watchUpdateScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.watchUpdateScheduled = false
                guard let watcher = self.watcher else { return }
                await watcher.watch(self.watchedRoots())
            }
        }

        /// 開いている(子を読む)行のパスのうち、ほかの開いている行の配下に無いもの。
        /// **ネットワーク上の行は含めない**(FSEvents はそこでは飛ばず、応答しない共有では生成が 30 秒塞ぐ。
        /// そちらはアクティブ化の `reloadRemoteExpandedRows` が追いつかせる。2026-09-14 の監査の 4)。
        private func watchedRoots() -> Set<String> {
            guard let outline else { return [] }
            let mounts = MountTable.current()
            var paths: [String] = []
            for row in 0..<outline.numberOfRows {
                guard let node = outline.item(atRow: row) as? Node, node.loadsChildren, let url = node.url,
                      outline.isItemExpanded(node), !mounts.isRemote(url)
                else { continue }
                paths.append(FileBrowserState.id(for: url))
            }
            var roots: [String] = []
            for path in paths.sorted() where !roots.contains(where: { MountTable.path(path, isAtOrUnder: $0) }) {
                roots.append(path)
            }
            return Set(roots)
        }

        /// FSEvents が知らせたパス(ファイル単位)の親と、そのもの(フォルダ自身の中身の変化)の行を読み直す。
        private func handleExternalChange(_ paths: [String]) {
            guard !paths.isEmpty else { return }
            var ids = Set<String>()
            for raw in paths {
                // **URL を作らずに文字列で親を求める**(2026-09-14 の 2 回目の監査 17)。`URL(fileURLWithPath:)` は `isDirectory:` を
                // 渡さないとパスを stat するので、ダウンロードが続くフォルダでは FSEvents のパスごとにメインの上で stat が走っていた。
                // 行の id は末尾の / を持たないパス(FileBrowserState.id(for:))なので、揃えて比べられる。
                let path = MountTable.normalized(FileBrowserState.pathOutsideDataVolume(raw))
                ids.insert(path)
                ids.insert((path as NSString).deletingLastPathComponent)
            }
            reloadExpandedRows(in: ids)
        }

        /// 共有の上の開いている行を読み直す(FSEvents が当てにならない。型コメント「外での変更」)。
        private func reloadRemoteExpandedRows() {
            guard let outline else { return }
            let mounts = MountTable.current()
            var ids = Set<String>()
            for row in 0..<outline.numberOfRows {
                guard let node = outline.item(atRow: row) as? Node, node.loadsChildren, let url = node.url,
                      outline.isItemExpanded(node), mounts.isRemote(url)
                else { continue }
                ids.insert(FileBrowserState.id(for: url))
            }
            if !ids.isEmpty { reloadExpandedRows(in: ids) }
        }

        func update(from view: FileBrowserTreeView) {
            guard let outline else { return }
            state = view.state
            actions = view.actions
            favoriteLocations = view.favoriteLocations
            var needsRedraw = false
            if view.outlineWidth != outlineWidth || view.locale != locale
                || view.allowsEditingFavorites != allowsEditingFavorites {
                outlineWidth = view.outlineWidth
                locale = view.locale
                allowsEditingFavorites = view.allowsEditingFavorites
                outline.outlineWidth = outlineWidth
                needsRedraw = true
            }
            if view.childSort != childSort {
                childSort = view.childSort
                resortLoadedChildren()
            }
            if view.favoriteLocations.items != appliedFavorites {
                appliedFavorites = view.favoriteLocations.items
                favoritesGroup.children = appliedFavorites.map {
                    Node(kind: .favorite($0.id), url: $0.url, name: $0.url.lastPathComponent)
                }
                outline.reloadItem(favoritesGroup, reloadChildren: true)
                outline.expandItem(favoritesGroup)
                scheduleWatchUpdate()
                // 行を作り直すと選択が外れる。いまのフォルダの行を選び直す(2026-09-14 の実機検証で発見。並べ替えで、表示中の
                // よく使う項目の行の選択が消えた)。下の `folderID != appliedFolderID` はフォルダが変わらないと通らない。
                applySelection(folderID: appliedFolderID ?? nil)
            }
            if needsRedraw {
                outline.reloadData()
                for group in groups { outline.expandItem(group) }
            }
            if let change = view.state.fileSystemChange, change != appliedChange {
                appliedChange = change
                reloadExpandedRows(in: change.isUnknownScope ? nil : change.folderIDs)
            }
            let folderID = FileBrowserState.id(of: view.state.currentFolder)
            if view.expandsToCurrentFolder != expandsToCurrentFolder {
                // ON にしたら、いまのフォルダまで開く。OFF にしたら走っている展開をやめる。
                expandsToCurrentFolder = view.expandsToCurrentFolder
                revealGeneration += 1
                pendingRevealFolderID = expandsToCurrentFolder ? folderID : nil
            }
            if folderID != appliedFolderID || needsRedraw {
                if folderID != appliedFolderID {
                    revealGeneration += 1
                    pendingRevealFolderID = expandsToCurrentFolder ? folderID : nil
                }
                appliedFolderID = folderID
                applySelection(folderID: folderID)
            }
            startPendingRevealIfReady()
        }

        // MARK: 子の並び

        /// 行の子を今の並びで並べる。読み込んだ値を持たない行が混じっていたら(来ないはず)名前順にする。
        private func sortedChildren(_ nodes: [Node]) -> [Node] {
            let pairs = nodes.compactMap { node in node.listing.map { ($0, node) } }
            guard pairs.count == nodes.count else {
                return nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            let byID = Dictionary(pairs.map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
            return childSort.sorted(pairs.map(\.0)).compactMap { byID[$0.id] }
        }

        /// 並べ替えの基準が変わったら、読み込み済みの子を読み直さずに並べ直す(型コメント「子の並び」)。
        /// 上の行から順に見て、並びが変わった行だけ描き直す(同じ Node を使うので開閉はそのまま残る)。
        private func resortLoadedChildren() {
            guard let outline else { return }
            var stack = groups.flatMap { $0.children ?? [] }
            var changed = false
            while let node = stack.popLast() {
                guard let children = node.children, !children.isEmpty else { continue }
                let sorted = sortedChildren(children)
                if !zip(sorted, children).allSatisfy({ $0 === $1 }) {
                    node.children = sorted
                    outline.reloadItem(node, reloadChildren: true)
                    changed = true
                }
                stack.append(contentsOf: sorted)
            }
            if changed { applySelection(folderID: appliedFolderID ?? nil) }
        }

        // MARK: 現在のフォルダまで開く

        /// 右ペインが現在のフォルダを読み終えていれば開き始める(型コメント)。まだ読んでいる間は待つ
        /// (読み終わりの `isLoading` の変化でまた `update` が呼ばれる)。
        private func startPendingRevealIfReady() {
            guard let target = pendingRevealFolderID, let state else { return }
            guard FileBrowserState.id(of: state.currentFolder) == target, state.loadError == nil else {
                pendingRevealFolderID = nil
                return
            }
            guard !state.isLoading, hasLoadedVolumes else { return }
            pendingRevealFolderID = nil
            let mine = revealGeneration
            Task { [weak self] in await self?.reveal(target, generation: mine) }
        }

        private func reveal(_ target: String, generation: Int) async {
            let roots = groups.flatMap { $0.children ?? [] }.compactMap { node in node.url.map { (node, $0.path) } }
            guard let plan = FileBrowserTreePath.plan(to: target, roots: roots.map(\.1)) else { return }
            var node = roots[plan.rootIndex].0
            var reachedTarget = plan.steps.isEmpty
            /// この展開で開いた行(道筋が切れたらたたみ直す)。
            var opened: [Node] = []
            for (offset, step) in plan.steps.enumerated() {
                let wasExpanded = outline?.isItemExpanded(node) ?? true
                guard let children = await expandedChildren(of: node, generation: generation) else { break }
                if !wasExpanded { opened.append(node) }
                guard let index = FileBrowserTreePath.index(of: step, in: children.map { $0.url?.path ?? "" }) else { break }
                node = children[index]
                reachedTarget = offset == plan.steps.count - 1
            }
            guard revealGeneration == generation, let outline else { return }
            if !reachedTarget {
                for item in opened.reversed() { outline.collapseItem(item) }
                applySelection(folderID: appliedFolderID ?? nil)
                return
            }
            applySelection(folderID: appliedFolderID ?? nil)
            let row = outline.row(forItem: node)
            if row >= 0 { outline.scrollRowToVisible(row) }
        }

        /// 行を開いて、子を読み終えるまで待つ。開けなかった・途中でやめたら nil。
        private func expandedChildren(of node: Node, generation: Int) async -> [Node]? {
            guard revealGeneration == generation, let outline else { return nil }
            if !outline.isItemExpanded(node) {
                if node.hasSubfolders == false {
                    // 三角を消した後で(Finder などで)サブフォルダができている。右ペインがその配下を読めた以上、ある。
                    node.hasSubfolders = nil
                    outline.reloadItem(node, reloadChildren: false)
                }
                outline.expandItem(node)
                // ドラッグ中は開かない(shouldExpandItem)。
                guard outline.isItemExpanded(node) else { return nil }
            }
            // 読み直しが重なったら、いちばん新しい読み込みまで待つ。
            while let task = node.childrenTask {
                await task.value
                if node.childrenTask == task { break }
            }
            guard revealGeneration == generation, let outline = self.outline, outline.isItemExpanded(node) else {
                return nil
            }
            return node.children
        }

        /// 右ペインのフォルダの行を選ぶ(見えていなければ選択を外す)。
        private func applySelection(folderID: String?) {
            guard let outline else { return }
            var target = -1
            if let folderID {
                for row in 0..<outline.numberOfRows {
                    if let node = outline.item(atRow: row) as? Node, let url = node.url,
                       FileBrowserState.id(for: url) == folderID {
                        target = row
                        break
                    }
                }
            }
            let indexes = target >= 0 ? IndexSet(integer: target) : IndexSet()
            guard indexes != outline.selectedRowIndexes else { return }
            isApplyingSelection = true
            outline.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }

        private func reloadVolumes() {
            volumeLoadGeneration += 1
            let mine = volumeLoadGeneration
            Task { [weak self] in
                let volumes = await FileIO.perform { FileBrowserListing.volumeEntries(mountTable: .current()) }
                guard let self, let outline = self.outline, self.volumeLoadGeneration == mine else { return }
                let sorted = volumes.sorted { lhs, rhs in
                    // 起動ボリュームを先頭に、残りは名前順(Finderのサイドバーと同じ)。
                    if (lhs.url.path == "/") != (rhs.url.path == "/") { return lhs.url.path == "/" }
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
                self.volumesGroup.children = sorted.map { Node(kind: .volume, url: $0.url, name: $0.displayName) }
                outline.reloadItem(self.volumesGroup, reloadChildren: true)
                outline.expandItem(self.volumesGroup)
                self.scheduleWatchUpdate()
                self.applySelection(folderID: self.appliedFolderID ?? nil)
                self.hasLoadedVolumes = true
                self.startPendingRevealIfReady()
            }
        }

        /// 自分の操作で中身が変わったフォルダのうち、**開いていて子を読み終えている行だけ**を読み直す
        /// (段階3の既知の制限「たたんで開き直すまで反映されない」の手当て。閉じた行は次に開いたときに読む)。
        /// - Parameter folderIDs: nil はどこが変わったか分からない(取り消し・やり直し)。見えている行を全部見直す。
        private func reloadExpandedRows(in folderIDs: Set<String>?) {
            guard let outline else { return }
            var collapsed: [Node] = []
            for row in 0..<outline.numberOfRows {
                guard let node = outline.item(atRow: row) as? Node, node.loadsChildren,
                      let url = node.url, folderIDs?.contains(FileBrowserState.id(for: url)) ?? true
                else { continue }
                if outline.isItemExpanded(node) {
                    if node.children != nil { loadChildren(of: node) }
                } else if node.hasSubfolders != nil {
                    // 閉じている行も、中でフォルダを作った・運び込んだ・運び出したなら三角の有無が変わる。
                    collapsed.append(node)
                }
            }
            reprobe(collapsed)
        }

        /// 閉じている行の「サブフォルダがあるか」を調べ直し、変わっていれば行を描き直す。
        ///
        /// **まとめて 1 本の FileIO で順に調べる**(2026-09-14 の監査)。FileIO は投げるたびに新しいスレッドを起こすので、
        /// 1 行ずつ投げると、取り消し・やり直し(どこが変わったか分からないので見えている行を全部見直す)のたびに閉じた行の数だけ
        /// スレッドが同時に立った。
        private func reprobe(_ nodes: [Node]) {
            let targets = nodes.compactMap { node in node.url.map { (WeakNode(node: node), $0) } }
            guard !targets.isEmpty else { return }
            let weakNodes = targets.map(\.0)
            let urls = targets.map(\.1)
            Task { [weak self] in
                let results = await FileIO.perform { urls.map { DirectoryProbe.hasSubdirectory(at: $0) } }
                guard let self, let outline = self.outline else { return }
                for (weakNode, result) in zip(weakNodes, results) {
                    guard let node = weakNode.node, node.hasSubfolders != result, !outline.isItemExpanded(node) else { continue }
                    node.hasSubfolders = result
                    outline.reloadItem(node, reloadChildren: false)
                }
            }
        }

        private struct WeakNode {
            weak var node: Node?
        }

        /// 行の子を読む。**読んでいる最中なら重ねずに、読み終えてから 1 回だけ読み直す**(2026-09-14 の 2 回目の監査 17)。
        /// 以前は前の読み込みを残したまま新しい読み込みを始めたので、開いたダウンロードフォルダの中でダウンロードが続くと
        /// 0.3 秒ごとに FileIO のスレッドが 1 本ずつ立ち(応答しない共有なら戻らないまま積もる)、いちばん新しい読み込みが
        /// 次々に差し替わるので「現在のフォルダまで開く」の待ちも終わらなかった。
        private func loadChildren(of node: Node) {
            guard node.url != nil else { return }
            if node.isLoadingChildren {
                node.needsReloadAfterLoad = true
                return
            }
            startLoadingChildren(of: node)
        }

        private func startLoadingChildren(of node: Node) {
            guard let url = node.url else { return }
            node.isLoadingChildren = true
            node.needsReloadAfterLoad = false
            // 世代は、たたんだ(`outlineViewItemDidCollapse`)ときにだけ進む。読み直しの頼みでは進めない(進めると、読み直しが
            // 続く間ずっと結果を捨て続ける)。
            let mine = node.loadGeneration
            node.childrenTask = Task { [weak self, weak node] in
                let folders: [(FileBrowserEntry, Bool?)]
                do {
                    folders = try await FileIO.perform {
                        // 三角のための問い合わせは、子を読むこの 1 回にまとめる(行を描くたびに調べない)。
                        // **ネットワーク越しでは調べない**(子の数だけ往復する)。マウント表はファイルシステムに触らない。
                        let probes = !MountTable.current().isRemote(url)
                        return try FileBrowserListing.entries(in: url)
                            .filter(\.isNavigableFolder)
                            .map { ($0, probes ? DirectoryProbe.hasSubdirectory(at: $0.url) : nil) }
                    }
                } catch {
                    folders = []
                }
                guard let self, let node else { return }
                node.isLoadingChildren = false
                defer {
                    // 読んでいる間に頼まれた読み直し(またはたたんで開き直した行)を、ここで 1 回だけ。
                    if node.needsReloadAfterLoad, let outline = self.outline, outline.isItemExpanded(node) {
                        self.startLoadingChildren(of: node)
                    }
                }
                guard let outline = self.outline, node.loadGeneration == mine, outline.isItemExpanded(node) else { return }
                // 読み直し(reloadExpandedRows)で開いている孫の行が閉じないよう、同じパスの行は同じ Node を使い回す
                // (NSOutlineView は開閉を項目の同一性で覚えている)。
                let previous = Dictionary(
                    (node.children ?? []).compactMap { child in child.url.map { (FileBrowserState.id(for: $0), child) } },
                    uniquingKeysWith: { first, _ in first }
                )
                let children = folders.map { entry, hasSubfolders in
                    let child = previous[FileBrowserState.id(for: entry.url)]
                        ?? Node(kind: .folder, url: entry.url, name: entry.displayName)
                    // 並べ替えの値(日付など)は読み直すたびに新しくする。
                    child.listing = entry
                    // 開いている孫の行は、読み直しの一瞬の判定で三角を消さない(開いたまま展開できない行になる)。
                    if !(outline.isItemExpanded(child) && hasSubfolders == false) { child.hasSubfolders = hasSubfolders }
                    return child
                }
                // 並べるのは結果を受け取ったこの時点の並び(読んでいる間に基準が変わっても古い順で入らない)。
                node.children = self.sortedChildren(children)
                outline.reloadItem(node, reloadChildren: true)
                self.applySelection(folderID: self.appliedFolderID ?? nil)
                // 開いていた子が消えた(外で消された)なら、見張るフォルダも変わる。
                self.scheduleWatchUpdate()
            }
        }

        // MARK: データ

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return groups.count }
            return node.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? Node else { return groups[index] }
            return node.children?[index] ?? Node(kind: .folder, url: nil, name: "")
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            // サブフォルダが無いと分かった行だけ三角を消す(型コメント)。
            (item as? Node)?.hasSubfolders != false
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? Node)?.isGroup ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            !((item as? Node)?.isGroup ?? true)
        }

        /// グループの見出し(ボリューム・ホーム・よく使う項目)には開閉の印を出さない(2026-09-14、ユーザー報告)。
        /// `.sourceList` のグループ行は、カーソルを乗せると右端に開閉の印(下向きの矢印)を出し、そのぶんセルが縮む。
        /// よく使う項目の見出しでは、右端の「＋」に合わせようとすると矢印が出て「＋」が左へずれ、押しにくかった。
        /// グループは常に開いておく(`expandItem(group)`)ので、たたむ手段は要らない。
        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            !((item as? Node)?.isGroup ?? false)
        }

        /// **ドラッグ中は行を開かない**(スプリングローデッドを止める)。`NSOutlineView` はドラッグで静止した行を
        /// 自動で開くが、開いた直後はその行が受け口から外れ、マウスを動かさずに離したドロップが黙って断られた
        /// (ツリーの行へ落としたのに何も起きず、絵が元へ戻る。静止 1.2〜1.7 秒で開いた回は 5 回とも失敗、開いていない回は
        /// 成功。実機 2026-09-13。子の入れ方を `reloadItem` から `insertItems` に変えても同じ)。検討メモ §9 の
        /// 「スプリングローデッドは最初は入れない」にも合う。
        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            !((outlineView as? FileBrowserOutlineView)?.isReceivingDrag ?? false)
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? Node, node.loadsChildren,
                  node.children == nil
            else { return }
            node.children = []
            loadChildren(of: node)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            scheduleWatchUpdate()
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? Node, node.loadsChildren else { return }
            // たたんだら子を捨てる(型コメント)。次に開いたときに読み直す。
            node.children = nil
            node.loadGeneration += 1
            outline?.reloadItem(node, reloadChildren: true)
            scheduleWatchUpdate()
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            if case .group(let group) = node.kind {
                let identifier = NSUserInterfaceItemIdentifier("tree.group")
                let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? GroupCellView)
                    ?? GroupCellView(identifier: identifier)
                cell.configure(
                    title: String(localized: group.title, language: locale),
                    outlineWidth: outlineWidth,
                    showsAddButton: group == .favorites,
                    isAddEnabled: allowsEditingFavorites,
                    addHelp: String(localized: "Add Folder to Favorite Locations…", language: locale),
                    target: self, action: #selector(addFavorite(_:))
                )
                return cell
            }
            let identifier = NSUserInterfaceItemIdentifier("tree.row")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileBrowserCellView)
                ?? FileBrowserCellView(identifier: identifier, showsIcon: true)
            cell.icon?.image = node.kind == .volume ? FileBrowserIconProvider.volumeIcon : FileBrowserIconProvider.folderIcon
            cell.configure(text: node.name, outlineWidth: outlineWidth)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let view = FileBrowserRowView()
            view.outlineWidth = outlineWidth
            return view
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            (item as? Node)?.isGroup == true ? 26 : 24
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let outline, outline.selectedRow >= 0,
                  let node = outline.item(atRow: outline.selectedRow) as? Node, let url = node.url
            else { return }
            let id = FileBrowserState.id(for: url)
            appliedFolderID = id
            // 行をクリックして移ったときは開かない(型コメント)。走っている展開もやめる。
            revealGeneration += 1
            pendingRevealFolderID = nil
            state?.navigate(to: url)
        }

        // MARK: ドラッグ&ドロップ

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node else { return nil }
            if case .favorite(let id) = node.kind {
                // 並べ替えだけ(型コメント)。並べる相手が無い・保存できないウインドウでは掴ませない。
                guard allowsEditingFavorites, (favoritesGroup.children?.count ?? 0) > 1 else { return nil }
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(id.uuidString, forType: fileBrowserFavoriteLocationPasteboardType)
                return pasteboardItem
            }
            guard node.kind == .folder, let url = node.url else { return nil }
            return url as NSURL
        }

        func outlineView(
            _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
            forItems draggedItems: [Any]
        ) {
            // よく使う項目の並べ替えはファイルのドラッグではない(アプリの中のファイルのドラッグとして数えない)。
            let folders = draggedItems.compactMap { $0 as? Node }.filter { $0.kind == .folder }
            guard !folders.isEmpty else { return }
            FileBrowserDragTracker.begin(folders.compactMap(\.url))
        }

        func outlineView(
            _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            FileBrowserDragTracker.end()
        }

        func outlineView(
            _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            if draggedFavoriteID(info) != nil {
                guard let destination = favoriteDropIndex(for: info, proposedItem: item, proposedChildIndex: index)
                else { return [] }
                // 動かない位置(自分の前後)でも線は出す。落としても何も変わらないだけ。
                outlineView.setDropItem(favoritesGroup, dropChildIndex: destination)
                return .move
            }
            guard let actions, let node = item as? Node, !node.isGroup, let url = node.url else { return [] }
            if index != NSOutlineViewDropOnItemIndex {
                // 行の間 → その親の行の上へ(型コメント)。
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            let (decision, _) = actions.dropDecision(for: info, into: url)
            return decision.dragOperation(sourceMask: info.draggingSourceOperationMask)
        }

        func outlineView(
            _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
        ) -> Bool {
            (outlineView as? FileBrowserOutlineView)?.noteDropAccepted()
            if let id = draggedFavoriteID(info) {
                guard (item as? Node) === favoritesGroup, index != NSOutlineViewDropOnItemIndex else { return false }
                actions?.moveFavoriteLocation(id: id, to: index)
                return true
            }
            guard let actions, let node = item as? Node, !node.isGroup, let url = node.url else { return false }
            let (decision, urls) = actions.dropDecision(for: info, into: url)
            actions.performDrop(decision, urls: urls)
            return decision.isAccepted
        }

        /// このツリーから始まった、よく使う項目の並べ替えのドラッグなら、その項目の id(型コメント)。
        /// ほかのウインドウのツリーから来たものも受ける(並びはアプリで 1 つ)。
        private func draggedFavoriteID(_ info: NSDraggingInfo) -> UUID? {
            guard info.draggingSource is FileBrowserOutlineView,
                  let string = info.draggingPasteboard.string(forType: fileBrowserFavoriteLocationPasteboardType)
            else { return nil }
            return UUID(uuidString: string)
        }

        /// よく使う項目を落とす位置(よく使う項目の中の子の添字)。落とせない場所なら nil。
        /// 行の上 → カーソルが行の上半分なら前、下半分なら後ろ。グループの見出しの上 → 先頭。
        private func favoriteDropIndex(for info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> Int? {
            guard allowsEditingFavorites, let outline, let node = item as? Node else { return nil }
            let children = favoritesGroup.children ?? []
            if node === favoritesGroup {
                return index == NSOutlineViewDropOnItemIndex ? 0 : index
            }
            guard case .favorite = node.kind, let position = children.firstIndex(where: { $0 === node }) else { return nil }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return nil }
            let point = outline.convert(info.draggingLocation, from: nil)
            let rect = outline.rect(ofRow: row)
            // NSOutlineView は上から下へ座標が増える(isFlipped)。
            return point.y < rect.midY ? position : position + 1
        }

        @objc private func addFavorite(_ sender: Any?) {
            actions?.addFavoriteLocation()
        }

        // MARK: 右クリック

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let outline else { return }
            let row = outline.clickedRow
            guard row >= 0, let node = outline.item(atRow: row) as? Node, let entry = node.entry else {
                menu.removeAllItems()
                return
            }
            menuBuilder.rebuild(
                menu, for: FileBrowserMenuContext(kind: .tree, entries: [entry], folder: node.url),
                actions: actions, locale: locale
            )
            if case .favorite(let id) = node.kind {
                menu.addItem(.separator())
                let item = NSMenuItem(
                    title: String(localized: "Remove from Favorite Locations", language: locale),
                    action: #selector(removeFavorite(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = id
                item.isEnabled = allowsEditingFavorites
                menu.addItem(item)
            }
        }

        @objc private func removeFavorite(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            actions?.removeFavoriteLocation(id: id)
        }
    }

    /// グループの見出し(「ボリューム」「ホーム」「よく使う項目 ＋」)。
    final class GroupCellView: NSTableCellView {
        private let label: NSTextField
        private let addButton: FileBrowserOutlinedIconButton

        init(identifier: NSUserInterfaceItemIdentifier) {
            let cell = FileBrowserOutlinedTextFieldCell(textCell: "")
            cell.lineBreakMode = .byTruncatingTail
            let field = NSTextField(frame: .zero)
            field.cell = cell
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = false
            field.font = .systemFont(ofSize: 11, weight: .semibold)
            field.textColor = .secondaryLabelColor
            field.translatesAutoresizingMaskIntoConstraints = false
            label = field
            let button = FileBrowserOutlinedIconButton(frame: .zero)
            button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.translatesAutoresizingMaskIntoConstraints = false
            addButton = button
            super.init(frame: .zero)
            self.identifier = identifier
            textField = field
            addSubview(field)
            addSubview(button)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                field.centerYAnchor.constraint(equalTo: centerYAnchor),
                field.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -4),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 18),
                button.heightAnchor.constraint(equalToConstant: 18),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func configure(
            title: String, outlineWidth: CGFloat, showsAddButton: Bool, isAddEnabled: Bool, addHelp: String,
            target: AnyObject, action: Selector
        ) {
            label.stringValue = title
            (label.cell as? FileBrowserOutlinedTextFieldCell)?.outlineWidth = outlineWidth
            label.needsDisplay = true
            addButton.outlineWidth = outlineWidth
            addButton.isHidden = !showsAddButton
            addButton.isEnabled = isAddEnabled
            addButton.toolTip = addHelp
            addButton.target = target
            addButton.action = action
        }
    }
}

import AppKit
import SwiftUI

/// ファイルブラウザの左のツリー(改善要望7 段階3、2026-09-13)。`NSOutlineView`を包む。
///
/// 3つのグループ: **ボリューム**(マウント表から。着脱で作り直す)/ **ホーム**(実際のホーム1行)/
/// **よく使う項目**(FavoriteLocationStore。見出しの右に「＋」)。
///
/// ■ 子は開いたときだけ読み、たたんだら捨てる
/// 行が展開できるかは「フォルダである」だけで決め、**サブフォルダがあるかは調べない**
/// (TCC と往復の両方の理由。FileBrowserEntryの型コメント)。開いてみて空なら空と分かる。
/// **起動時はボリュームもホームも閉じている**(要望)。展開の状態は保存しない。
///
/// ■ クリック
/// 行を選ぶと右ペインがそのフォルダへ移る。右ペインで移動したら、そのフォルダの行が見えていれば
/// 選んだ状態にする(見えていなければ選択を外す ―― 違う行が選ばれたまま残らないように)。
struct FileBrowserTreeView: NSViewRepresentable {
    @ObservedObject var state: FileBrowserState
    @ObservedObject var favoriteLocations: FavoriteLocationStore
    let actions: FileBrowserActions
    let outlineWidth: CGFloat
    let locale: Locale
    /// よく使う項目の「＋」と「削除」を許すか(シークレットウインドウでは false)。
    let allowsEditingFavorites: Bool

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

        init(kind: Kind, url: URL?, name: String, children: [Node]? = nil) {
            self.kind = kind
            self.url = url
            self.name = name
            self.children = children
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
            if view.favoriteLocations.items != appliedFavorites {
                appliedFavorites = view.favoriteLocations.items
                favoritesGroup.children = appliedFavorites.map {
                    Node(kind: .favorite($0.id), url: $0.url, name: $0.url.lastPathComponent)
                }
                outline.reloadItem(favoritesGroup, reloadChildren: true)
                outline.expandItem(favoritesGroup)
            }
            if needsRedraw {
                outline.reloadData()
                for group in groups { outline.expandItem(group) }
            }
            if let change = view.state.fileSystemChange, change != appliedChange {
                appliedChange = change
                reloadExpandedRows(in: change.folderIDs)
            }
            let folderID = FileBrowserState.id(of: view.state.currentFolder)
            if folderID != appliedFolderID || needsRedraw {
                appliedFolderID = folderID
                applySelection(folderID: folderID)
            }
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
                self.applySelection(folderID: self.appliedFolderID ?? nil)
            }
        }

        /// 自分の操作で中身が変わったフォルダのうち、**開いていて子を読み終えている行だけ**を読み直す
        /// (段階3の既知の制限「たたんで開き直すまで反映されない」の手当て。閉じた行は次に開いたときに読む)。
        private func reloadExpandedRows(in folderIDs: Set<String>) {
            guard let outline else { return }
            for row in 0..<outline.numberOfRows {
                guard let node = outline.item(atRow: row) as? Node, node.loadsChildren, node.children != nil,
                      let url = node.url, folderIDs.contains(FileBrowserState.id(for: url)),
                      outline.isItemExpanded(node)
                else { continue }
                loadChildren(of: node)
            }
        }

        private func loadChildren(of node: Node) {
            guard let url = node.url else { return }
            node.loadGeneration += 1
            let mine = node.loadGeneration
            Task { [weak self, weak node] in
                let folders: [(URL, String)]
                do {
                    folders = try await FileIO.perform {
                        try FileBrowserListing.entries(in: url)
                            .filter(\.isNavigableFolder)
                            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                            .map { ($0.url, $0.displayName) }
                    }
                } catch {
                    folders = []
                }
                guard let self, let node, let outline = self.outline, node.loadGeneration == mine,
                      outline.isItemExpanded(node)
                else { return }
                // 読み直し(reloadExpandedRows)で開いている孫の行が閉じないよう、同じパスの行は同じ Node を使い回す
                // (NSOutlineView は開閉を項目の同一性で覚えている)。
                let previous = Dictionary(
                    (node.children ?? []).compactMap { child in child.url.map { (FileBrowserState.id(for: $0), child) } },
                    uniquingKeysWith: { first, _ in first }
                )
                node.children = folders.map { previous[FileBrowserState.id(for: $0.0)] ?? Node(kind: .folder, url: $0.0, name: $0.1) }
                outline.reloadItem(node, reloadChildren: true)
                self.applySelection(folderID: self.appliedFolderID ?? nil)
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
            // フォルダである、だけで決める(サブフォルダの有無を調べない。型コメント)。
            true
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? Node)?.isGroup ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            !((item as? Node)?.isGroup ?? true)
        }

        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            true
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? Node, node.loadsChildren,
                  node.children == nil
            else { return }
            node.children = []
            loadChildren(of: node)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? Node, node.loadsChildren else { return }
            // たたんだら子を捨てる(型コメント)。次に開いたときに読み直す。
            node.children = nil
            node.loadGeneration += 1
            outline?.reloadItem(node, reloadChildren: true)
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
            state?.navigate(to: url)
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

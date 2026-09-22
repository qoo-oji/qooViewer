import AppKit
import SwiftUI

/// スマートライブラリのリスト表示(2026-09-22、利用者の指示。StackNest の一覧を参考に、ファイルブラウザのリストと同じ部品で)。
///
/// **AppKit の `NSOutlineView`**(SwiftUI の `Table` は使わない ―― メタデータの編集ウインドウで、見せた行のセルを手放さず
/// 1.6 GB になった。`MetadataBookTable` の型コメント)。見えている行のセルだけを持ち、使い回す。
///
/// ■ 束は疑似的なフォルダ(利用者の指示「まとめるは擬似的にフォルダのように扱えないか」)
/// 「まとめる」で作った束(シリーズ / 著者)は、**フォルダのアイコンの行**になる。Finder のリスト表示のフォルダと同じく、
/// - 左の三角(または → / ←)でその場に中の本を開く / 閉じる(開いている束は並び替え・絞り込みの後も開いたまま)
/// - ダブルクリック・Return・⌘↓ で**束の中へ入る**(グリッドで束を開くのと同じ `openedGroup`。見出しの「<」・Esc・⌘↑ で戻る)
///
/// ■ そのほか
/// - 列: 題(隠せない)・著者・シリーズ・巻・ジャンル・原作・イベント・形式・読んだ割合・読書の状態・追加日・最後に読んだ日・
///   変更日・ファイル名。見出しの右クリックで出す・隠す、ドラッグで並べ替え、幅も変えられ、**並び・幅・表示は保存**
///   (`autosaveName`)。見出しを押すと並べ替え(並べ替えのメニューと同じ `SmartSortKey` の列だけ。もう一度押すと向きが変わる)
/// - 選択は画面の選択(`SmartLibraryViewState.selection`)と同じもの ―― グリッドとリストを切り替えても残る
/// - 文字を打つと頭文字の行へ(`NSOutlineView` の type-select)、⌘A ですべて
/// - 右クリック: 右クリックした行が選択に入っていれば選択の全部が相手(グリッドと同じ。中身は画面が組む `menu`)
///
/// ■ すりガラス面の決まりごと
/// ファイルブラウザのリストと同じ部品: 文字は `FileBrowserCellView`(輪郭を焼く)、行の地と選択は `FileBrowserRowView`
/// (`SelectionEmphasis` + 反対色の縁)、見出しは不透明な地の `FileBrowserTableHeaderView`、三角は `FileBrowserOutlineView`
/// (反対色の輪郭を焼く)。アイコンは色の付いた種類のアイコン(本)とフォルダのアイコン(束)なので輪郭は掛けない。
///
/// ■ リーク
/// 閉包・delegate・メニューは `dismantleNSView` で切る(CLAUDE.md「NSViewRepresentable の callbacks」)。
struct SmartLibraryListView: NSViewRepresentable {
    /// 右クリックのメニューの項目(画面が組む)。
    struct MenuItem {
        var title: String
        var isEnabled = true
        var action: (() -> Void)?
        var isSeparator = false

        static var separator: MenuItem { MenuItem(title: "", isSeparator: true) }
    }

    let items: [SmartGridItem]
    let selection: SmartGridSelection
    let sortKey: SmartSortKey
    let sortAscending: Bool
    let revealRequest: SmartLibraryViewState.RevealRequest?
    let scrollResetSerial: Int
    /// 文字の輪郭の太さ(すりガラス面の決まりごと。画面が環境値から渡す)。
    let outlineWidth: CGFloat
    let locale: Locale
    var onSelectionChange: (Set<String>, String?) -> Void
    var onSort: (SmartSortKey, Bool) -> Void
    /// 行を開く(本は開き、束は中へ)。
    var onActivate: (SmartGridItem) -> Void
    /// ⌘↑(束から出る)。出られなければ false。
    var onLeaveGroup: () -> Bool
    /// 右クリックした行と、相手にする行(選択に入っていれば選択の全部)。
    var menu: (_ clicked: SmartGridItem, _ targets: [SmartGridItem]) -> [MenuItem]

    /// 列の並び・幅・表示を覚えておく名前。
    static let autosaveName = "qooViewer.smartLibrary.list"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let outline = SmartLibraryOutlineView()
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.usesAlternatingRowBackgroundColors = false
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.rowHeight = 22
        outline.intercellSpacing = NSSize(width: 6, height: 0)
        outline.gridStyleMask = []
        outline.focusRingType = .none
        outline.indentationPerLevel = 14
        // 不透明な地を持つ見出しに差し替える(FileBrowserTableHeaderView のコメント)。
        let headerHeight = outline.headerView?.frame.height ?? 28
        outline.headerView = FileBrowserTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: headerHeight))

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = String(localized: String.LocalizationValue(column.titleKey), language: locale)
            tableColumn.width = column.defaultWidth
            tableColumn.minWidth = column.minWidth
            tableColumn.isHidden = column.isHiddenByDefault
            if let key = column.sortKey {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: key.defaultAscending)
            }
            if column == .title { tableColumn.resizingMask = [.autoresizingMask, .userResizingMask] }
            outline.addTableColumn(tableColumn)
            if column == .title { outline.outlineTableColumn = tableColumn }
        }
        // 列を足してから名前を付ける(覚えてある並び・幅・表示が、ここで戻る)。
        outline.autosaveName = Self.autosaveName
        outline.autosaveTableColumns = true
        // 題の列は先頭から動かさない(三角と名前の列。ファイルブラウザのリストの名前の列と同じ)。
        let titleIndex = outline.column(withIdentifier: Column.title.identifier)
        if titleIndex > 0 { outline.moveColumn(titleIndex, toColumn: 0) }

        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.onOpenSelection = { [weak coordinator] in coordinator?.openSelection() }
        outline.onLeaveGroup = { [weak coordinator] in coordinator?.parent?.onLeaveGroup() ?? false }

        let rowMenu = NSMenu()
        rowMenu.delegate = coordinator
        rowMenu.autoenablesItems = false
        outline.menu = rowMenu
        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        outline.headerView?.menu = headerMenu
        coordinator.headerMenu = headerMenu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        coordinator.outline = outline
        coordinator.apply(self, initial: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self, initial: false)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let outline = coordinator.outline {
            outline.dataSource = nil
            outline.delegate = nil
            outline.target = nil
            outline.doubleAction = nil
            outline.onOpenSelection = nil
            outline.onLeaveGroup = nil
            outline.menu?.delegate = nil
            outline.menu = nil
            outline.headerView?.menu?.delegate = nil
            outline.headerView?.menu = nil
        }
        coordinator.headerMenu = nil
        coordinator.outline = nil
        coordinator.parent = nil
    }

    // MARK: - 列

    enum Column: String, CaseIterable {
        case title, authors, series, volume, genre, source, event, kind, progress, readState
        case dateAdded, lastRead, dateModified, fileName

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        /// 見出しの言葉の鍵(条件の欄・並べ替えのメニューと同じ言葉)。
        var titleKey: String {
            switch self {
            case .title: "Title"
            case .authors: "Authors"
            case .series: "Series"
            case .volume: "Volume"
            case .genre: "Genre"
            case .source: "Source work"
            case .event: "Event"
            case .kind: "Book Format"
            case .progress: "Progress (%)"
            case .readState: "Reading Status"
            case .dateAdded: "Date Added"
            case .lastRead: "Last Read"
            case .dateModified: "Date Modified"
            case .fileName: "File name"
            }
        }

        /// 見出しを押したときの並べ替え(並べ替えのメニューにある基準の列だけ)。
        var sortKey: SmartSortKey? {
            switch self {
            case .title: .title
            case .authors: .authors
            case .series: .series
            case .dateAdded: .dateAdded
            case .lastRead: .lastRead
            case .dateModified: .dateModified
            case .fileName: .fileName
            default: nil
            }
        }

        var defaultWidth: CGFloat {
            switch self {
            case .title: 300
            case .authors, .series, .fileName: 160
            case .volume, .progress: 64
            case .genre, .source, .event: 120
            case .kind, .readState: 90
            case .dateAdded, .lastRead, .dateModified: 140
            }
        }

        var minWidth: CGFloat { self == .title ? 140 : 40 }

        /// 最初は隠しておく列(見出しの右クリックで出す)。
        var isHiddenByDefault: Bool {
            switch self {
            case .source, .event, .readState, .dateModified, .fileName: true
            default: false
            }
        }

        var isHideable: Bool { self != .title }
    }

    // MARK: - 行

    /// 行の中身(`NSOutlineView` は行を参照で見分けるので、並びが変わっても同じ行には同じものを返す ―― 開いた束が閉じない)。
    final class Node: NSObject {
        let id: String
        var item: SmartGridItem
        var children: [Node] = []

        init(item: SmartGridItem) {
            id = item.id
            self.item = item
        }

        var isGroup: Bool {
            if case .group = item { return true }
            return false
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: SmartLibraryListView?
        weak var outline: SmartLibraryOutlineView?
        weak var headerMenu: NSMenu?

        private var items: [SmartGridItem] = []
        private var roots: [Node] = []
        private var nodeByID: [String: Node] = [:]
        /// 開いている束(並べ直しても開いたまま)。
        private var expandedIDs: Set<String> = []
        /// 表のほうを書き換えている最中(その結果として届く知らせで、画面の値を書き戻さない)。
        private var isApplying = false
        private var outlineWidth: CGFloat = 0
        private var locale: Locale?
        private var lastRevealSerial: Int?
        private var lastScrollResetSerial: Int?
        private var dateFormatter = DateFormatter()

        func apply(_ parent: SmartLibraryListView, initial: Bool) {
            self.parent = parent
            guard let outline else { return }
            isApplying = true
            defer { isApplying = false }
            var needsReload = false
            if locale != parent.locale {
                locale = parent.locale
                dateFormatter = DateFormatter()
                dateFormatter.locale = parent.locale
                dateFormatter.dateStyle = .medium
                dateFormatter.timeStyle = .short
                for column in Column.allCases {
                    outline.tableColumn(withIdentifier: column.identifier)?.title =
                        String(localized: String.LocalizationValue(column.titleKey), language: parent.locale)
                }
                needsReload = true
            }
            if outlineWidth != parent.outlineWidth {
                outlineWidth = parent.outlineWidth
                outline.outlineWidth = parent.outlineWidth
                needsReload = true
            }
            if items != parent.items {
                items = parent.items
                rebuildNodes()
                needsReload = true
            }
            if needsReload {
                outline.reloadData()
                for node in roots where node.isGroup && expandedIDs.contains(node.id) {
                    outline.expandItem(node)
                }
            }
            applySortDescriptor(parent, to: outline)
            applySelection(parent.selection, to: outline)
            if !initial, lastScrollResetSerial != parent.scrollResetSerial, outline.numberOfRows > 0 {
                outline.scrollRowToVisible(0)
            }
            lastScrollResetSerial = parent.scrollResetSerial
            if let request = parent.revealRequest, request.serial != lastRevealSerial {
                lastRevealSerial = request.serial
                if let node = nodeByID[request.id], case let row = outline.row(forItem: node), row >= 0 {
                    outline.scrollRowToVisible(row)
                }
            }
        }

        /// 並びから行を作り直す(同じ識別子の行は使い回す)。
        private func rebuildNodes() {
            var next: [String: Node] = [:]
            func node(for item: SmartGridItem) -> Node {
                let made = nodeByID[item.id] ?? Node(item: item)
                made.item = item
                next[item.id] = made
                return made
            }
            roots = items.map { item in
                let root = node(for: item)
                if case .group(_, _, let books) = item {
                    root.children = books.map { node(for: .book($0)) }
                } else {
                    root.children = []
                }
                return root
            }
            nodeByID = next
            expandedIDs.formIntersection(next.keys)
        }

        private func applySortDescriptor(_ parent: SmartLibraryListView, to outline: NSOutlineView) {
            let hasColumn = Column.allCases.contains { $0.sortKey == parent.sortKey }
            let wanted = hasColumn ? [NSSortDescriptor(key: parent.sortKey.rawValue, ascending: parent.sortAscending)] : []
            if outline.sortDescriptors != wanted { outline.sortDescriptors = wanted }
        }

        private func applySelection(_ selection: SmartGridSelection, to outline: NSOutlineView) {
            let wanted = IndexSet(selection.ids.compactMap { id -> Int? in
                guard let node = nodeByID[id] else { return nil }
                let row = outline.row(forItem: node)
                return row >= 0 ? row : nil
            })
            if outline.selectedRowIndexes != wanted { outline.selectRowIndexes(wanted, byExtendingSelection: false) }
        }

        private func node(atRow row: Int) -> Node? {
            outline?.item(atRow: row) as? Node
        }

        // MARK: 中身

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return roots.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? Node else { return roots[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Node)?.isGroup ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
                  let node = item as? Node else { return nil }
            let cell = (outlineView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? FileBrowserCellView)
                ?? FileBrowserCellView(identifier: tableColumn.identifier, showsIcon: column == .title)
            cell.configure(
                text: text(of: node.item, column: column),
                color: column == .title ? .labelColor : .secondaryLabelColor,
                outlineWidth: outlineWidth
            )
            if column == .title {
                cell.icon?.image = icon(of: node.item)
                cell.toolTip = toolTip(of: node.item)
            }
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let rowView = (outlineView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? FileBrowserRowView)
                ?? {
                    let view = FileBrowserRowView()
                    view.identifier = Self.rowIdentifier
                    return view
                }()
            rowView.outlineWidth = outlineWidth
            let row = outlineView.row(forItem: item)
            rowView.isStriped = row >= 0 && row % 2 == 1
            return rowView
        }

        private static let rowIdentifier = NSUserInterfaceItemIdentifier("smartLibrary.row")

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            guard tableColumn?.identifier == Column.title.identifier, let node = item as? Node else { return nil }
            return text(of: node.item, column: .title)
        }

        /// 行を開閉すると縞の位置がずれるので、見えている行の縞を塗り直す。
        func outlineViewItemDidExpand(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? Node { expandedIDs.insert(node.id) }
            restripe()
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if !isApplying, let node = notification.userInfo?["NSObject"] as? Node { expandedIDs.remove(node.id) }
            restripe()
        }

        private func restripe() {
            outline?.enumerateAvailableRowViews { rowView, row in
                (rowView as? FileBrowserRowView)?.isStriped = row % 2 == 1
            }
        }

        // MARK: 文字

        private func text(of item: SmartGridItem, column: Column) -> String {
            switch item {
            case .book(let book):
                return text(of: book, column: column)
            case .group(let grouping, let name, let books):
                switch column {
                case .title: return "\(name) (\(books.count))"
                case .authors: return grouping == .author ? name : (books.first?.metadata.authors.first ?? "")
                case .series:
                    if grouping == .series { return name }
                    let series = Set(books.compactMap { SmartGrouping.series.key(of: $0) })
                    if series.count == 1 { return series.first ?? "" }
                    if series.count > 1 {
                        return String(format: String(localized: "%lld series", language: locale ?? .current), series.count)
                    }
                    return ""
                default: return ""
                }
            }
        }

        private func text(of book: SmartBook, column: Column) -> String {
            let locale = locale ?? .current
            let metadata = book.metadata
            switch column {
            case .title: return book.displayTitle
            case .authors: return metadata.authors.joined(separator: ", ")
            case .series: return metadata.series
            case .volume: return metadata.volume
            case .genre: return metadata.genre
            case .source: return metadata.source
            case .event: return metadata.event
            case .kind: return String(localized: String.LocalizationValue(book.kind.titleKey), language: locale)
            case .progress: return book.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
            case .readState: return String(localized: String.LocalizationValue(book.readState.titleKey), language: locale)
            case .dateAdded: return book.dateAdded.map(dateFormatter.string(from:)) ?? ""
            case .lastRead: return book.lastRead.map(dateFormatter.string(from:)) ?? ""
            case .dateModified: return book.modificationDate.map(dateFormatter.string(from:)) ?? ""
            case .fileName: return book.fileName
            }
        }

        private func icon(of item: SmartGridItem) -> NSImage {
            switch item {
            case .group:
                // 束は疑似的なフォルダ(型コメント)。
                return FileBrowserIconProvider.folderIcon
            case .book(let book):
                return FileBrowserIconProvider.icon(for: FileBrowserEntry(
                    url: URL(fileURLWithPath: book.id, isDirectory: book.kind == .folder), displayName: book.fileName,
                    isDirectory: book.kind == .folder, isPackage: false, isSymbolicLink: false, isVolume: false,
                    fileSize: book.fileSize, typeDescription: nil, creationDate: book.creationDate,
                    modificationDate: book.modificationDate
                ))
            }
        }

        private func toolTip(of item: SmartGridItem) -> String {
            switch item {
            case .book(let book): return book.id
            case .group(_, let name, _): return name
            }
        }

        // MARK: 選ぶ・並べ替える・開く

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let outline, let parent else { return }
            let ids = Set(outline.selectedRowIndexes.compactMap { node(atRow: $0)?.id })
            let cursor = outline.selectedRow >= 0 ? node(atRow: outline.selectedRow)?.id : nil
            parent.onSelectionChange(ids, cursor)
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplying, let parent, let descriptor = outlineView.sortDescriptors.first,
                  let raw = descriptor.key, let key = SmartSortKey(rawValue: raw) else { return }
            parent.onSort(key, descriptor.ascending)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0, let node = node(atRow: outline.clickedRow) else { return }
            parent?.onActivate(node.item)
        }

        /// Return / ⌘↓。開けるのは 1 つだけ選んでいるとき(グリッドと同じ)。
        func openSelection() {
            guard let outline else { return }
            let nodes = outline.selectedRowIndexes.compactMap(node(atRow:))
            guard !nodes.isEmpty else { return }
            guard nodes.count == 1, let node = nodes.first else {
                NSSound.beep()
                return
            }
            parent?.onActivate(node.item)
        }

        // MARK: メニュー

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let outline else { return }
            menu.removeAllItems()
            if menu === headerMenu {
                // 列を出す・隠す(題の列は隠せない)。
                for tableColumn in outline.tableColumns {
                    guard let column = Column(rawValue: tableColumn.identifier.rawValue), column.isHideable else { continue }
                    let item = NSMenuItem(title: tableColumn.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = tableColumn
                    item.state = tableColumn.isHidden ? .off : .on
                    menu.addItem(item)
                }
                return
            }
            let clicked = outline.clickedRow
            guard clicked >= 0, let clickedNode = node(atRow: clicked), let parent else { return }
            let targets: [SmartGridItem] = outline.selectedRowIndexes.contains(clicked)
                ? outline.selectedRowIndexes.compactMap { node(atRow: $0)?.item }
                : [clickedNode.item]
            for item in parent.menu(clickedNode.item, targets) { menu.addItem(makeItem(item)) }
        }

        private func makeItem(_ item: MenuItem) -> NSMenuItem {
            if item.isSeparator { return .separator() }
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            menuItem.isEnabled = item.isEnabled
            if let action = item.action {
                menuItem.target = self
                menuItem.action = #selector(runMenuItem(_:))
                menuItem.representedObject = ActionBox(action)
            }
            return menuItem
        }

        /// メニューの項目に持たせる閉包(**名前を `perform(_:)` にしない** ―― NSObject の `performSelector:` に化ける。CLAUDE.md)。
        private final class ActionBox: NSObject {
            let run: () -> Void
            init(_ run: @escaping () -> Void) { self.run = run }
        }

        @objc func runMenuItem(_ sender: NSMenuItem) {
            (sender.representedObject as? ActionBox)?.run()
        }

        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let tableColumn = sender.representedObject as? NSTableColumn else { return }
            tableColumn.isHidden.toggle()
        }
    }
}

/// スマートライブラリのリストの `NSOutlineView`。三角の輪郭と当たり判定はファイルブラウザのツリーのもの
/// (`FileBrowserOutlineView`)を受け継ぎ、開く・束から出るキーを足す。
final class SmartLibraryOutlineView: FileBrowserOutlineView {
    var onOpenSelection: (() -> Void)?
    var onLeaveGroup: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Return / Enter、⌘↓(Finder の「開く」)。
        if (event.keyCode == 36 || event.keyCode == 76) && flags.subtracting([.numericPad, .function]).isEmpty
            || (event.keyCode == 125 && flags.contains(.command)) {
            onOpenSelection?()
            return
        }
        // ⌘↑: 束から出る(出られなければふつうのキーとして渡す)。
        if event.keyCode == 126, flags.contains(.command), onLeaveGroup?() == true {
            return
        }
        super.keyDown(with: event)
    }
}


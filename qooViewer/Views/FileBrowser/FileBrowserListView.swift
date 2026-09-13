import AppKit
import SwiftUI

/// ファイルブラウザのリスト表示(改善要望7 段階3、2026-09-13)。`NSTableView`を包む。
///
/// ■ なぜSwiftUIの`Table`ではないのか(決定事項 Q3、検討メモ §12.1)
/// `Table`は macOS 15.5 でスクロールが退行して 26 でも残り、1000行で選択に3.5秒かかった事例がある。
/// `NSTableView`なら1万行でも`body`が走らず、列幅の保存(`autosaveName`)・type-select・
/// レスポンダチェーンの`copy:`などが標準で付いてくる(段階4で使う)。
///
/// ■ データの受け渡し
/// `FileBrowserState.entries`の写しを`entriesRevision`が進んだときだけ受け取り、`reloadData`する
/// (配列を毎回比べない)。選択は双方向: 表での選択を`state.selection`へ書き、状態の選択が表と
/// 違えば表へ反映する(反映中の通知は書き戻さない)。
///
/// ■ リーク
/// 閉包・delegate・メニューの対象は`dismantleNSView`で切る(CLAUDE.md)。`NSTrackingArea`は使わない。
struct FileBrowserListView: NSViewRepresentable {
    @ObservedObject var state: FileBrowserState
    let actions: FileBrowserActions
    /// 文字の輪郭の太さ(すりガラス面の決まりごと。ペインが環境値から渡す)。
    let outlineWidth: CGFloat
    let locale: Locale

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = FileBrowserTableView()
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.gridStyleMask = []
        table.focusRingType = .none
        // 不透明な地を持つ見出しに差し替える(FileBrowserTableHeaderViewのコメント)。高さは既定のものを引き継ぐ。
        let headerHeight = table.headerView?.frame.height ?? 28
        table.headerView = FileBrowserTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: headerHeight))

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = String(localized: column.title, language: locale)
            tableColumn.width = column.defaultWidth
            tableColumn.minWidth = column.minWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey.rawValue, ascending: true)
            if column == .name { tableColumn.resizingMask = [.autoresizingMask, .userResizingMask] }
            table.addTableColumn(tableColumn)
        }
        // 列の幅と並びを保存する(Tableの columnCustomization の代わり)。**列を足してから**設定する。
        table.autosaveName = "qooViewer.fileBrowser.list"
        table.autosaveTableColumns = true

        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        table.onReturn = { [weak coordinator] in coordinator?.openSelection() }

        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        coordinator.table = table
        coordinator.update(from: self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let table = coordinator.table {
            table.dataSource = nil
            table.delegate = nil
            table.target = nil
            table.doubleAction = nil
            table.onReturn = nil
            table.menu?.delegate = nil
            table.menu = nil
        }
        coordinator.table = nil
        coordinator.state = nil
        coordinator.actions = nil
    }

    // MARK: - 列

    enum Column: String, CaseIterable {
        case name, modified, size, kind, created

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        var title: String.LocalizationValue {
            switch self {
            case .name: "Name"
            case .modified: "Date Modified"
            case .size: "Size"
            case .kind: "Kind"
            case .created: "Date Created"
            }
        }

        var sortKey: FolderBrowserSortKey {
            switch self {
            case .name: .name
            case .modified: .modificationDate
            case .size: .size
            case .kind: .kind
            case .created: .creationDate
            }
        }

        var defaultWidth: CGFloat {
            switch self {
            case .name: 280
            case .modified, .created: 160
            case .size: 80
            case .kind: 140
            }
        }

        var minWidth: CGFloat {
            self == .name ? 120 : 50
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var table: FileBrowserTableView?
        var state: FileBrowserState?
        var actions: FileBrowserActions?
        private var entries: [FileBrowserEntry] = []
        private var revision = -1
        private var outlineWidth: CGFloat = 0
        private var locale = Locale.current
        private var appliedScroll: FileBrowserState.ScrollRequest?
        /// 状態から表へ選択を写している最中(その通知を状態へ書き戻さない)。
        private var isApplyingSelection = false
        private var isApplyingSort = false
        private let menuBuilder = FileBrowserMenuBuilder()
        private lazy var dateFormatter: DateFormatter = makeDateFormatter()
        private let sizeFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()

        func update(from view: FileBrowserListView) {
            guard let table else { return }
            state = view.state
            actions = view.actions
            var needsReload = false
            if view.locale != locale {
                locale = view.locale
                dateFormatter = makeDateFormatter()
                sizeFormatter.formattingContext = .standalone
                for column in Column.allCases {
                    table.tableColumn(withIdentifier: column.identifier)?.title =
                        String(localized: column.title, language: locale)
                }
                needsReload = true
            }
            if view.outlineWidth != outlineWidth {
                outlineWidth = view.outlineWidth
                needsReload = true
            }
            if view.state.entriesRevision != revision {
                revision = view.state.entriesRevision
                entries = view.state.entries
                needsReload = true
            }
            if needsReload {
                isApplyingSelection = true
                table.reloadData()
                isApplyingSelection = false
            }
            applySortDescriptors(from: view.state)
            applySelection(from: view.state)
            if let request = view.state.scrollRequest, request != appliedScroll {
                appliedScroll = request
                if let row = entries.firstIndex(where: { $0.id == request.id }) {
                    table.scrollRowToVisible(row)
                }
            }
        }

        private func makeDateFormatter() -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
            return formatter
        }

        private func applySelection(from state: FileBrowserState) {
            guard let table else { return }
            var indexes = IndexSet()
            for (row, entry) in entries.enumerated() where state.selection.contains(entry.id) {
                indexes.insert(row)
            }
            guard indexes != table.selectedRowIndexes else { return }
            isApplyingSelection = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }

        private func applySortDescriptors(from state: FileBrowserState) {
            guard let table else { return }
            let wanted = [NSSortDescriptor(key: state.sortKey.rawValue, ascending: state.sortDirection == .ascending)]
            guard table.sortDescriptors.first?.key != wanted.first?.key
                    || table.sortDescriptors.first?.ascending != wanted.first?.ascending
            else { return }
            isApplyingSort = true
            table.sortDescriptors = wanted
            isApplyingSort = false
        }

        // MARK: データ

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
                  entries.indices.contains(row)
            else { return nil }
            let entry = entries[row]
            let identifier = NSUserInterfaceItemIdentifier("cell." + column.rawValue)
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? FileBrowserCellView)
                ?? FileBrowserCellView(identifier: identifier, showsIcon: column == .name)
            switch column {
            case .name:
                cell.icon?.image = FileBrowserIconProvider.icon(for: entry)
                cell.configure(text: entry.displayName, outlineWidth: outlineWidth)
            case .modified:
                cell.configure(text: entry.modificationDate.map(dateFormatter.string(from:)) ?? "--",
                               color: .secondaryLabelColor, outlineWidth: outlineWidth)
            case .created:
                cell.configure(text: entry.creationDate.map(dateFormatter.string(from:)) ?? "--",
                               color: .secondaryLabelColor, outlineWidth: outlineWidth)
            case .size:
                cell.configure(text: entry.fileSize.map(sizeFormatter.string(fromByteCount:)) ?? "--",
                               color: .secondaryLabelColor, outlineWidth: outlineWidth)
                cell.label.alignment = .right
            case .kind:
                cell.configure(text: entry.typeDescription ?? "--", color: .secondaryLabelColor,
                               outlineWidth: outlineWidth)
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = (tableView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? FileBrowserRowView)
                ?? {
                    let view = FileBrowserRowView()
                    view.identifier = Self.rowIdentifier
                    return view
                }()
            rowView.outlineWidth = outlineWidth
            rowView.isStriped = row % 2 == 1
            return rowView
        }

        private static let rowIdentifier = NSUserInterfaceItemIdentifier("fileBrowser.row")

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard tableColumn?.identifier == Column.name.identifier, entries.indices.contains(row) else { return nil }
            return entries[row].displayName
        }

        // MARK: 操作

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let table, let state else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].id : nil })
            if ids != state.selection { state.selection = ids }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplyingSort, let state, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key.flatMap(FolderBrowserSortKey.init(rawValue:))
            else { return }
            state.sortKey = key
            state.sortDirection = descriptor.ascending ? .ascending : .descending
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let table, table.clickedRow >= 0 else { return }
            openSelection()
        }

        func openSelection() {
            guard let table, let actions else { return }
            let targets = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
            guard !targets.isEmpty else { return }
            actions.open(targets)
        }

        /// 右クリック: 選択に含まれる行ならその全部、外ならその1行だけ(選択は変えない。Finderと同じ)。
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table else { return }
            let clicked = table.clickedRow
            var targets: [FileBrowserEntry] = []
            if clicked >= 0, entries.indices.contains(clicked) {
                if table.selectedRowIndexes.contains(clicked) {
                    targets = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
                } else {
                    targets = [entries[clicked]]
                }
            }
            menuBuilder.rebuild(menu, for: targets, actions: actions, locale: locale)
        }
    }
}

/// Return で開く(`NSTableView`の既定では Return は何もしない)。
final class FileBrowserTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Return / Enter、⌘↓(Finderの「開く」)。
        if (event.keyCode == 36 || event.keyCode == 76) && flags.subtracting([.numericPad, .function]).isEmpty
            || (event.keyCode == 125 && flags.contains(.command)) {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

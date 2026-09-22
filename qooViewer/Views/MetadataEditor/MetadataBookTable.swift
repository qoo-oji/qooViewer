import AppKit
import QooMetaKit
import SwiftUI

/// メタデータの編集ウインドウの一覧の表(qooMeta のアプリの `BookTable` を移したもの)。
/// **AppKit の `NSTableView` をそのまま使う**(SwiftUI の `Table` は使わない)。
///
/// SwiftUI の `Table` は、セル 1 つずつに `NSHostingView` を作り、いちど見せた行を手放さない。1,836 冊の一覧を
/// 眺めただけで、行のビューが 1,202 行ぶん・セルのビューが 1.2 万個残り、メモリは 1.6 GB になった(2026-09-21、
/// 利用者の報告。止まったプロセスを `heap` で数えた)。しかも、どのセルも同じ窓に監視(KVO)を付けるので、付ける・外すが
/// 1 回ごとに「いまある監視の数」に比例し、全体ではセルの数の 2 乗になる ―― 窓を閉じると全部を外すので、そこで固まる。
/// スクロールするほど重くなるのも、列を組み替えると固まるのも同じ根。セルの中身を軽くしても数は減らないので、表ごと替えた。
///
/// `NSTableView` は見えている行のセルだけを持ち、使い回す。1 万冊でもセルは数百のまま。
///
/// 振る舞いは前の表と同じにしてある: 見出しを押して並べ替え、列の並べ替え・幅・表示は利用者が変えられ(覚えておく)、
/// **1 回押しは行を選ぶだけ、2 回押しでそのセルを書き換える**(Return とほかへ移ったときに入り、Esc で元へ戻る)。
///
/// ■ qooViewer で足したもの(2026-09-21、利用者の指示。右の詳細を無くした代わり)
/// - 左端の鍵の列(本ごとのロック = 登録。押すと切り替わる)と、右端のコレクションの表紙の列(以前の窓と同じ ―― 表紙の名前を出し、
///   押すと選ぶ面が開く。SwiftUI の `ExportCoverCell` を `NSHostingView` で載せる。見えている行のぶんだけ)。
/// - 右クリックのメニューは画面の側が組む(`contextMenu`)。まとめて直す操作(連番・シリーズ・欄・スタンプ・表紙・ロック・登録・
///   保存データの削除)はすべてここから。
/// - 実体の無い本は灰色、ファイル名フォーマットと合致しなかった本はファイル名をオレンジで出す(合致しなかった本は上にまとめる)。
struct MetadataBookTable: NSViewRepresentable {
    /// 列。欄の列のほかに、鍵・ファイル名・巻数(並べ替え用)・コレクションの表紙がある。
    enum Column: Hashable {
        case lock
        case fileName
        case field(QMBookMetadata.Field)
        case volumeSort
        case cover

        /// 左からの既定の並び(`MetadataBookTableView.columns` の説明)。
        static let all: [Column] = [.lock, .fileName] + MetadataBookTableView.columns.map(Column.field) + [.volumeSort]
            + MetadataBookTableView.columnsAfterVolume.map(Column.field) + [.cover]

        var identifier: NSUserInterfaceItemIdentifier {
            switch self {
            case .lock: .init("lock")
            case .fileName: .init("fileName")
            case .field(let field): .init(field.rawValue)
            case .volumeSort: .init("volumeSort")
            case .cover: .init("cover")
            }
        }

        init?(_ identifier: NSUserInterfaceItemIdentifier) {
            guard let column = Self.all.first(where: { $0.identifier == identifier }) else { return nil }
            self = column
        }

        /// 見出しの言葉の鍵(英語)。
        var titleKey: String {
            switch self {
            case .lock: ""
            case .fileName: "File name"
            case .field(let field): field.labelKey
            case .volumeSort: "Volume (for sorting)"
            case .cover: "Collection Cover"
            }
        }

        var width: (min: CGFloat, ideal: CGFloat, max: CGFloat?) {
            switch self {
            case .lock: (26, 26, 26)
            case .fileName: (160, 360, nil)
            case .field(let field): MetadataBookTableView.width(field)
            case .volumeSort: (50, 72, 110)
            case .cover: (80, 120, 260)
            }
        }

        /// 隠せない列(どの本の行か分からなくなる・ロックの切り替えが無くなる)。
        var isHideable: Bool { self != .fileName && self != .lock }

        func text(of book: MetadataBookRow) -> String {
            switch self {
            case .fileName: book.fileName
            case .field(let field): book[text: field]
            case .volumeSort: book.volumeSortText
            case .lock, .cover: ""
            }
        }

        /// 並べ替えの比べ方(鍵は `MetadataBookRow` が 1 冊につき 1 度だけ作ってある)。鍵と表紙の列は並べ替えない。
        func comparator(_ order: SortOrder) -> KeyPathComparator<MetadataBookRow>? {
            switch self {
            // 名前そのものではなく、開いたときに決めた順位で比べる(理由は `MetadataBookRow.fileRank`)。
            case .fileName: KeyPathComparator(\MetadataBookRow.fileRank, order: order)
            case .field(let field): KeyPathComparator(\MetadataBookRow[sortKey: field], order: order)
            case .volumeSort: KeyPathComparator(\MetadataBookRow[sortKey: .volume], order: order)
            case .lock, .cover: nil
            }
        }
    }

    /// 右クリックのメニューの項目(画面の側が組む)。`children` があればサブメニュー。
    struct MenuItem {
        var title: String
        var isEnabled = true
        var state: NSControl.StateValue = .off
        var children: [MenuItem]?
        var action: (() -> Void)?
        var isSeparator = false

        static var separator: MenuItem { MenuItem(title: "", isSeparator: true) }
    }

    /// 本の全体と、そのうち一覧に出す本の位置(並べ替え・絞り込み済み)。**行の写しは受け取らない**
    /// (全冊ぶんの行をもう 1 組作らないため。`MetadataWorkspace.visiblePositions`)。
    var books: [MetadataBookRow]
    var positions: [Int]
    @Binding var selection: Set<MetadataBookRow.ID>
    @Binding var sortOrder: [KeyPathComparator<MetadataBookRow>]
    var canEdit: (QMBookMetadata.Field, MetadataBookRow) -> Bool
    /// 利用者が直した(確定した)欄か。提案のままの値と色で見分ける。
    var isEdited: (QMBookMetadata.Field, MetadataBookRow) -> Bool
    var help: (QMBookMetadata.Field, MetadataBookRow) -> String
    var commit: (QMBookMetadata.Field, String, MetadataBookRow) -> Void
    /// 右クリックのメニュー(右クリックした本、または選んだ本すべてについて)。
    var contextMenu: (Set<MetadataBookRow.ID>) -> [MenuItem]
    /// 鍵の列を押した(その本のロックを切り替える)。
    var toggleLock: (MetadataBookRow.ID) -> Void
    /// 表紙の列のセルの中身(SwiftUI)。
    var coverView: (MetadataBookRow.ID) -> AnyView

    /// 列の並び・幅・表示を覚えておく名前。列を足したので名前も変えた(前の並びを当てると新しい列が隠れる)。
    static let autosaveName = "qooViewer.metadataEditor.bookTable.v2"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .custom
        table.rowHeight = 24
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for column in Column.all {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            let size = column.width
            tableColumn.minWidth = size.min
            tableColumn.width = size.ideal
            if let max = size.max { tableColumn.maxWidth = max }
            tableColumn.resizingMask = column == .lock ? [] : [.autoresizingMask, .userResizingMask]
            if column.comparator(.forward) != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
            }
            if column == .lock {
                tableColumn.headerCell.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
                tableColumn.headerToolTip = "Lock".ui
            }
            table.addTableColumn(tableColumn)
        }
        // 列を足してから名前を付ける(覚えてある並び・幅・表示が、ここで戻る)。
        table.autosaveName = Self.autosaveName
        table.autosaveTableColumns = true

        let coordinator = context.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = coordinator
        table.headerView?.menu = menu
        // 行の右クリック。中身は開くときに作る。
        let rowMenu = NSMenu()
        rowMenu.delegate = coordinator
        rowMenu.autoenablesItems = false
        table.menu = rowMenu
        coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        coordinator.apply(self, initial: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self, initial: false)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        // AppKit の部品が窓より長く生きても、画面の閉包を握り続けない(CLAUDE.md「NSViewRepresentable の callbacks」)。
        coordinator.release()
    }

    // MARK: - セル

    /// セル 1 つ(文字だけ)。使い回す。
    final class CellView: NSTableCellView {
        let label = NSTextField(labelWithString: "")
        /// 利用者が直した欄(色を変える)。
        var isEditedValue = false { didSet { updateColor() } }
        /// 本の実体が無い(灰色にする)。
        var isMissing = false { didSet { updateColor() } }
        /// ファイル名フォーマットと合致しなかった本のファイル名(オレンジにする)。
        var isUnmatchedName = false { didSet { updateColor() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            label.cell?.isScrollable = true
            // 切れて見えない名前は、指したときに全体を出す。
            label.allowsExpansionToolTips = true
            addSubview(label)
            textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("コードで組み立てる") }

        /// 選んだ行(強調の地)では、直した欄の色も地に合わせる(色のままだと、選んだ行の上で読めない)。
        override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColor() } }

        func updateColor() {
            guard !label.isEditable else { return }
            label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor
                : isMissing ? .tertiaryLabelColor
                : isUnmatchedName ? .systemOrange
                : isEditedValue ? .controlAccentColor : .labelColor
        }

        /// 書き換えに入る・出るときの見た目(入っているあいだは、ふつうの入力欄の色)。
        func setEditing(_ editing: Bool) {
            label.isEditable = editing
            label.isSelectable = editing
            label.drawsBackground = editing
            label.backgroundColor = editing ? .textBackgroundColor : .clear
            if editing { label.textColor = .textColor } else { updateColor() }
        }
    }

    /// 鍵の列のセル(押すとその本のロックが切り替わる)。
    final class LockCellView: NSTableCellView {
        let button = NSButton()

        override init(frame: NSRect) {
            super.init(frame: frame)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.setButtonType(.momentaryChange)
            addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: centerXAnchor),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("コードで組み立てる") }

        func show(locked: Bool) {
            button.image = NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open",
                                   accessibilityDescription: locked ? "Locked".ui : "Unlocked".ui)
            button.contentTintColor = locked ? .labelColor : .tertiaryLabelColor
            button.toolTip = locked ? "Locked. Click to unlock".ui : "Click to lock the metadata of this book".ui
        }
    }

    /// 表紙の列のセル(SwiftUI の中身を載せる)。
    final class HostingCellView: NSTableCellView {
        let host = NSHostingView(rootView: AnyView(EmptyView()))

        override init(frame: NSRect) {
            super.init(frame: frame)
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                host.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("コードで組み立てる") }
    }

    // MARK: - 仲立ち

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var parent: MetadataBookTable?
        weak var table: NSTableView?
        private var books: [MetadataBookRow] = []
        private var positions: [Int] = []
        private func book(_ row: Int) -> MetadataBookRow { books[positions[row]] }
        private var rowCount: Int { positions.count }
        /// 表のほうを書き換えている最中(その結果として届く知らせで、持ちものを書き戻さない)。
        private var isApplying = false
        /// 書き換えの最中のセル。
        private(set) var editing: (bookID: String, field: QMBookMetadata.Field, original: String, cell: CellView)?
        /// 書き換えの最中に届いた中身(入力を途中で消さないよう、終わってから入れる)。
        private var pendingRows: (books: [MetadataBookRow], positions: [Int])?

        init(_ parent: MetadataBookTable) { self.parent = parent }

        /// 画面の閉包を手放す(dismantleNSView)。
        func release() {
            parent = nil
            table?.menu = nil
            table?.headerView?.menu = nil
        }

        /// 画面の側の値を表へ入れる。
        func apply(_ parent: MetadataBookTable, initial: Bool) {
            self.parent = parent
            guard let table else { return }
            isApplying = true
            defer { isApplying = false }
            // 見出しは毎回付け直す(言語を変えたときに変わる。列は十数なので軽い)。
            for tableColumn in table.tableColumns {
                guard let column = Column(tableColumn.identifier), column != .lock else { continue }
                let title = column.titleKey.ui
                if tableColumn.title != title { tableColumn.title = title }
            }
            if initial {
                table.sortDescriptors = [NSSortDescriptor(key: Column.fileName.identifier.rawValue, ascending: true)]
            }
            if editing != nil {
                pendingRows = (parent.books, parent.positions)
            } else {
                setRows(parent.books, parent.positions, in: table)
            }
            select(parent.selection, in: table)
        }

        /// 行を入れ替える。**並びが同じなら、変わった行だけを描き直す**(1 冊直すたびに 1 万行を読み直さない)。
        private func setRows(_ newBooks: [MetadataBookRow], _ newPositions: [Int], in table: NSTableView) {
            let sameOrder = newPositions == positions
            // 配列の == は、同じ中身を指していればすぐ終わる(選択が変わっただけのとき)。
            guard !(sameOrder && newBooks == books) else { return }
            let oldBooks = books
            books = newBooks
            positions = newPositions
            indexByID = nil
            if sameOrder, oldBooks.count == newBooks.count {
                let changed = IndexSet(newPositions.indices.filter { oldBooks[newPositions[$0]] != newBooks[newPositions[$0]] })
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            } else {
                table.reloadData()
            }
        }

        private var indexByID: [String: Int]?

        private func index(of id: String) -> Int? {
            if indexByID == nil {
                indexByID = Dictionary(positions.enumerated().map { (books[$0.element].id, $0.offset) }, uniquingKeysWith: { a, _ in a })
            }
            return indexByID?[id]
        }

        private func select(_ ids: Set<String>, in table: NSTableView) {
            let wanted = IndexSet(ids.compactMap(index(of:)))
            if table.selectedRowIndexes != wanted { table.selectRowIndexes(wanted, byExtendingSelection: false) }
        }

        // MARK: 中身

        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent, let tableColumn, let column = Column(tableColumn.identifier), row >= 0, row < rowCount else { return nil }
            let book = book(row)
            switch column {
            case .lock:
                let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? LockCellView) ?? {
                    let made = LockCellView(frame: .zero)
                    made.identifier = tableColumn.identifier
                    made.button.target = self
                    made.button.action = #selector(lockClicked(_:))
                    return made
                }()
                cell.show(locked: book.isLocked)
                cell.button.identifier = NSUserInterfaceItemIdentifier(book.id)
                return cell
            case .cover:
                let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? HostingCellView) ?? {
                    let made = HostingCellView(frame: .zero)
                    made.identifier = tableColumn.identifier
                    return made
                }()
                cell.host.rootView = parent.coverView(book.id)
                return cell
            default:
                break
            }
            let cell: CellView
            if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? CellView {
                cell = reused
            } else {
                cell = CellView(frame: .zero)
                cell.identifier = tableColumn.identifier
            }
            cell.isMissing = book.isMissing
            cell.isUnmatchedName = column == .fileName && !book.matchedFormat
            cell.setEditing(false)
            cell.label.stringValue = column.text(of: book)
            switch column {
            case .fileName:
                cell.isEditedValue = false
                // どの本かはフルパスで分かる(同じ名前の本が別のフォルダにあることがある)。
                var tip = book.id
                if !book.matchedFormat { tip += "\n" + "This file name matched no file name format of its rule set".ui }
                if book.isMissing { tip += "\n" + "The book itself can't be found".ui }
                cell.toolTip = tip
            case .volumeSort:
                cell.isEditedValue = false
                cell.toolTip = "Derived from the volume as written, by the rules for reading a volume".ui
            case .field(let field):
                cell.isEditedValue = parent.isEdited(field, book)
                cell.toolTip = parent.help(field, book)
            case .lock, .cover:
                break
            }
            return cell
        }

        @objc func lockClicked(_ sender: NSButton) {
            guard let id = sender.identifier?.rawValue else { return }
            parent?.toggleLock(id)
        }

        // MARK: 選ぶ・並べ替える

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table, let parent else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < rowCount ? book($0).id : nil })
            if parent.selection != ids { parent.selection = ids }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplying, let parent else { return }
            let order = tableView.sortDescriptors.compactMap { descriptor -> KeyPathComparator<MetadataBookRow>? in
                guard let key = descriptor.key, let column = Column(.init(key)) else { return nil }
                return column.comparator(descriptor.ascending ? .forward : .reverse)
            }
            if !order.isEmpty { parent.sortOrder = order }
        }

        // MARK: 書き換える

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, table.clickedColumn >= 0 else { return }
            beginEditing(row: table.clickedRow, column: table.clickedColumn)
        }

        /// そのセルの書き換えに入る。読むだけの列(ファイル名・巻数の並べ替え用)と、いまは直せない欄では何もしない。
        @discardableResult
        func beginEditing(row: Int, column: Int) -> Bool {
            guard let parent, let table, editing == nil, row >= 0, row < rowCount, table.tableColumns.indices.contains(column),
                  case .field(let field)? = Column(table.tableColumns[column].identifier),
                  parent.canEdit(field, book(row)),
                  let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? CellView else { return false }
            editing = (book(row).id, field, cell.label.stringValue, cell)
            cell.setEditing(true)
            cell.label.delegate = self
            guard table.window?.makeFirstResponder(cell.label) == true else {
                finishEditing(keeping: false)
                return false
            }
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            let movement = notification.userInfo?["NSTextMovement"] as? Int
            finishEditing(keeping: true)
            // Return で入れたときは、表へ戻る(矢印で次の行へ行ける)。ほかを押して抜けたときは、押した先を邪魔しない。
            if movement == NSTextMovement.return.rawValue, let table { table.window?.makeFirstResponder(table) }
        }

        /// Esc は、元の値へ戻して抜ける。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), editing != nil else { return false }
            control.abortEditing()
            finishEditing(keeping: false)
            if let table { table.window?.makeFirstResponder(table) }
            return true
        }

        private func finishEditing(keeping: Bool) {
            guard let edit = editing else { return }
            editing = nil
            let value = edit.cell.label.stringValue
            edit.cell.label.delegate = nil
            edit.cell.setEditing(false)
            // 表に出すのは、いつも持ちものの値(入れた値は、計算し直しが済んでから行として届く)。
            edit.cell.label.stringValue = edit.original
            if keeping, value.trimmingCharacters(in: .whitespaces) != edit.original,
               let row = index(of: edit.bookID) {
                parent?.commit(edit.field, value, book(row))
            }
            if let pending = pendingRows, let table {
                pendingRows = nil
                isApplying = true
                setRows(pending.books, pending.positions, in: table)
                if let parent { select(parent.selection, in: table) }
                isApplying = false
            }
        }

        // MARK: メニュー

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table else { return }
            menu.removeAllItems()
            if menu === table.menu { return fillRowMenu(menu, in: table) }
            // 列を出す・隠す(見出しの上で右クリック)。ファイル名と鍵の列は隠せない。
            for tableColumn in table.tableColumns {
                guard let column = Column(tableColumn.identifier), column.isHideable else { continue }
                let item = NSMenuItem(title: column.titleKey.ui, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tableColumn
                item.state = tableColumn.isHidden ? .off : .on
                menu.addItem(item)
            }
        }

        /// 右クリックした行が選んだ本のうちにあれば、選んだ本すべて。なければ、その行の本だけ(Finder と同じ)。
        private func clickedIDs(in table: NSTableView) -> Set<String> {
            let clicked = table.clickedRow
            guard clicked >= 0, clicked < rowCount else { return [] }
            if table.selectedRowIndexes.contains(clicked) {
                return Set(table.selectedRowIndexes.compactMap { $0 < rowCount ? book($0).id : nil })
            }
            return [book(clicked).id]
        }

        private func fillRowMenu(_ menu: NSMenu, in table: NSTableView) {
            let ids = clickedIDs(in: table)
            guard !ids.isEmpty, let parent else { return }
            for item in parent.contextMenu(ids) { menu.addItem(makeItem(item)) }
        }

        private func makeItem(_ item: MenuItem) -> NSMenuItem {
            if item.isSeparator { return .separator() }
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            menuItem.isEnabled = item.isEnabled
            menuItem.state = item.state
            if let children = item.children {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for child in children { submenu.addItem(makeItem(child)) }
                menuItem.submenu = submenu
            } else if let action = item.action {
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

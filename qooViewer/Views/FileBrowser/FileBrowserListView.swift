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
/// ■ 名前の変更(段階4)
/// 名前の欄は編集できるセル。**選ばれている1行をもう一度クリックすると、ダブルクリックの間隔を待って
/// 編集が始まる**(`NSTableView`の標準。複数選択中は始めない ―― `FileBrowserTableView`)。編集中に一覧が
/// 読み直されると編集が消えるので、編集が終わるまで`reloadData`を待たせる。
///
/// ■ ドラッグ&ドロップ(段階4b)
/// 行は出し口(ファイルの URL を運ぶ)で、受け口でもある。フォルダの行の上ならそのフォルダへ、
/// それ以外(ファイルの行・行の間・空きスペース)なら表示中のフォルダへ落とす(Finder と同じ)。
/// 何をするかは`FileBrowserDropDecision`(FileBrowserDragAndDrop.swift)が決める。
///
/// ■ 列(2026-09-14、ユーザー要望)
/// 見出しの右クリックで、名前以外の列を出す・隠す(Finder と同じ。隠している列は`FileBrowserState.hiddenListColumns`)。
/// 見出しのドラッグで列を並べ替えられるが、**名前の列は先頭から動かさない**(Finder と同じ。`shouldReorderColumn`)。
/// 並びと幅は`autosaveName`が保存する。
///
/// ■ リーク
/// 閉包・delegate・メニューの対象は`dismantleNSView`で切る(CLAUDE.md)。`NSTrackingArea`は使わない。
struct FileBrowserListView: NSViewRepresentable {
    @ObservedObject var state: FileBrowserState
    let actions: FileBrowserActions
    /// 文字の輪郭の太さ(すりガラス面の決まりごと。ペインが環境値から渡す)。
    let outlineWidth: CGFloat
    let locale: Locale
    /// 表全体(表示中のフォルダ)がドロップの受け口になった・外れた。ペインがアイコン表示の余白と同じ枠を出す
    /// (2026-09-14。AppKit 標準の表全体の強調は細い線で、すりガラス 2 条件では薄かった ―― 計画 §4.9)。
    let onWholeListDropTargetChange: (Bool) -> Void

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
        table.editResponder = actions
        table.onWholeTableDropTargetChange = onWholeListDropTargetChange
        configureFileBrowserDragSource(table)

        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu
        // 見出しの右クリック: 列の表示/非表示。行のメニューとは別の NSMenu(delegate で見分ける)。
        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        table.headerView?.menu = headerMenu
        coordinator.headerMenu = headerMenu
        // 保存された並びで名前の列が先頭でなくなっていたら戻す(以前は名前の列も動かせた)。
        let nameIndex = table.column(withIdentifier: Column.name.identifier)
        if nameIndex > 0 { table.moveColumn(nameIndex, toColumn: 0) }

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
        context.coordinator.table?.onWholeTableDropTargetChange = onWholeListDropTargetChange
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let table = coordinator.table {
            table.dataSource = nil
            table.delegate = nil
            table.target = nil
            table.doubleAction = nil
            table.onReturn = nil
            table.editResponder = nil
            // 閉包を先に切る(SwiftUI の更新の最中に @State を書かない)。
            table.onWholeTableDropTargetChange = nil
            table.isWholeTableDropTarget = false
            table.unregisterDraggedTypes()
            table.menu?.delegate = nil
            table.menu = nil
            table.headerView?.menu?.delegate = nil
            table.headerView?.menu = nil
        }
        coordinator.headerMenu = nil
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

        /// 見出しの右クリックで隠せるか(名前の列だけは隠せない)。
        var isHideable: Bool { self != .name }

        var minWidth: CGFloat {
            self == .name ? 120 : 50
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        weak var table: FileBrowserTableView?
        /// 見出しの右クリックのメニュー(`menuNeedsUpdate`で行のメニューと見分ける)。
        weak var headerMenu: NSMenu?
        var state: FileBrowserState?
        var actions: FileBrowserActions?
        private var entries: [FileBrowserEntry] = []
        private var revision = -1
        private var outlineWidth: CGFloat = 0
        private var locale = Locale.current
        private var appliedScroll: FileBrowserState.ScrollRequest?
        private var appliedRename: FileBrowserState.ScrollRequest?
        private var appliedCutPaths: Set<String> = []
        /// 名前の編集中に表の描き直しを待たせた(編集が終わったら取り込んで描き直す)。
        private var needsReloadAfterEditing = false
        /// Esc で編集を取りやめた(確定の通知を名前の変更として扱わない)。
        private var isCancellingEdit = false
        /// 編集の後始末の最中(`finishEditing` が欄を表示名へ戻してから焦点を表へ返すので、そこで届く 2 度目の
        /// 「編集が終わった」を名前の変更として扱わない ―― 表示名と実名の違う項目を表示名へ改名しうる。監査の 9)。
        private var isFinishingEdit = false
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
            applySortDescriptors(from: view.state)
            applyHiddenColumns(from: view.state)
            // **名前の編集中は一覧を取り込まない**(2026-09-14 の監査の 5)。以前は描き直しだけを待たせて `entries` は
            // 差し替えていたので、編集中に一覧が読み直される(FSEvents・アプリの再アクティブ化・ボリュームの着脱・他の
            // ウインドウの操作)と、確定の `table.row(for:)`(表に出ている古い行番号)で新しい `entries` を引き、**別の
            // ファイルの名前を変えた**。選択・スクロールの反映も同じ添字ずれを起こすので、まとめて `finishEditing` まで待たせる。
            if isEditingName {
                if needsReload || view.state.entriesRevision != revision || view.state.cutPaths != appliedCutPaths {
                    needsReloadAfterEditing = true
                }
                return
            }
            syncWithState(view.state, forcingReload: needsReload)
        }

        /// 状態の一覧・カット・選択・スクロール・名前の編集の依頼を表へ写す(編集中でないときだけ呼ぶ)。
        private func syncWithState(_ state: FileBrowserState, forcingReload: Bool) {
            guard let table else { return }
            var needsReload = forcingReload
            if state.cutPaths != appliedCutPaths {
                appliedCutPaths = state.cutPaths
                needsReload = true
            }
            if state.entriesRevision != revision {
                revision = state.entriesRevision
                entries = state.entries
                needsReload = true
            }
            if needsReload {
                isApplyingSelection = true
                table.reloadData()
                isApplyingSelection = false
            }
            applySelection(from: state)
            if let request = state.scrollRequest, request != appliedScroll {
                appliedScroll = request
                if let row = entries.firstIndex(where: { $0.id == request.id }) {
                    table.scrollRowToVisible(row)
                }
            }
            if let request = state.renameRequest, request != appliedRename,
               let row = entries.firstIndex(where: { $0.id == request.id }) {
                appliedRename = request
                state.finishRenameRequest(request)
                beginEditingName(row: row)
            }
        }

        // MARK: 名前の変更

        /// 名前の欄が編集中か(フィールドエディタがこの表の中の欄を編集している)。
        private var isEditingName: Bool {
            guard let table, let editor = table.window?.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSTextField
            else { return false }
            return field.isDescendant(of: table)
        }

        private func beginEditingName(row: Int) {
            guard let table, entries.indices.contains(row), !entries[row].isVolume else { return }
            let column = table.column(withIdentifier: Column.name.identifier)
            guard column >= 0 else { return }
            table.scrollRowToVisible(row)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.editColumn(column, row: row, with: nil, select: true)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField else {
                return false
            }
            // Esc: 取りやめて元の名前に戻す。
            isCancellingEdit = true
            field.abortEditing()
            isCancellingEdit = false
            finishEditing(restoring: field)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !isCancellingEdit, !isFinishingEdit, let table, let field = notification.object as? FileBrowserNameField else { return }
            let row = table.row(for: field)
            let newName = field.stringValue
            // 編集中は `entries` を差し替えないので、表の行番号と `entries` は揃っている。念のため欄が覚えている実名とも突き合わせる
            // (揃っていなければ、どの項目の名前を変えるつもりだったのか分からないので何もしない)。
            if entries.indices.contains(row), let state, field.editingName == entries[row].url.lastPathComponent {
                let entry = entries[row]
                if newName != entry.url.lastPathComponent {
                    state.operations.rename(entry, to: newName)
                }
            }
            finishEditing(restoring: field)
        }

        /// 編集の後始末: 欄の文字を表示名へ戻し(変更が済めば読み直しで新しい名前になる)、表へ焦点を返し、
        /// 待たせていた読み直しを行う。
        private func finishEditing(restoring field: NSTextField) {
            guard let table, !isFinishingEdit else { return }
            isFinishingEdit = true
            defer { isFinishingEdit = false }
            let row = table.row(for: field)
            if entries.indices.contains(row) { field.stringValue = entries[row].displayName }
            table.window?.makeFirstResponder(table)
            if needsReloadAfterEditing {
                needsReloadAfterEditing = false
                // 待たせていた一覧・選択・スクロールをまとめて取り込む(update のコメント)。
                if let state { syncWithState(state, forcingReload: true) }
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

        private func applyHiddenColumns(from state: FileBrowserState) {
            guard let table else { return }
            for column in Column.allCases where column.isHideable {
                guard let tableColumn = table.tableColumn(withIdentifier: column.identifier) else { continue }
                let hidden = state.hiddenListColumns.contains(column.rawValue)
                if tableColumn.isHidden != hidden { tableColumn.isHidden = hidden }
            }
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
            // カットした項目は淡く(Finder と同じ)。
            cell.alphaValue = state?.isCut(entry) == true ? 0.5 : 1
            switch column {
            case .name:
                cell.icon?.image = icon(for: entry)
                cell.configure(text: entry.displayName, outlineWidth: outlineWidth)
                cell.nameField.editingName = entry.isVolume ? nil : entry.url.lastPathComponent
                cell.nameField.selectsWholeName = entry.isDirectory && !entry.isPackage
                cell.label.delegate = self
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

        /// 名前の列のアイコン。アプリケーションは、読めていればそのアプリのアイコン、まだなら種類のアイコンを出して
        /// 読み終わったら差し替える(FileBrowserApplicationIcon。2026-09-14、ユーザー要望)。読む場所の判断はアイコン表示と同じ。
        private func icon(for entry: FileBrowserEntry) -> NSImage {
            let typeIcon = FileBrowserIconProvider.icon(for: entry)
            guard FileBrowserApplicationIcon.isApplication(
                name: entry.url.lastPathComponent, isPackage: entry.isPackage, isSymbolicLink: entry.isSymbolicLink
            ) else { return typeIcon }
            let icons = FileBrowserListApplicationIcons.shared
            if let cached = icons.cachedIcon(for: entry) { return cached }
            guard FileBrowserThumbnailProvider.kind(
                for: entry, currentFolder: state?.currentFolder, mountTable: .current()
            ) == .application else { return typeIcon }
            let id = entry.id
            icons.load(entry) { [weak self] image in
                // 読んでいる間に一覧が変わっていてもよいように、行はパスで引き直す。見えていない行は作らない。
                guard let self, let table = self.table, let row = self.entries.firstIndex(where: { $0.id == id }) else { return }
                let column = table.column(withIdentifier: Column.name.identifier)
                guard column >= 0,
                      let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? FileBrowserCellView
                else { return }
                cell.icon?.image = image
            }
            return typeIcon
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

        // MARK: ドラッグ&ドロップ

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard entries.indices.contains(row), !isEditingName else { return nil }
            return FileBrowserActions.pasteboardWriter(for: entries[row])
        }

        func tableView(
            _ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            FileBrowserDragTracker.begin(rowIndexes.compactMap { row in
                entries.indices.contains(row) && !entries[row].isVolume ? entries[row].url : nil
            })
        }

        func tableView(
            _ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            FileBrowserDragTracker.end()
        }

        func tableView(
            _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard let actions else { return [] }
            let folder = dropFolder(row: row, operation: dropOperation)
            if folder == nil {
                // フォルダの行の上でなければ、表全体(表示中のフォルダ)を受け口として強調する。
                tableView.setDropRow(-1, dropOperation: .on)
            }
            let (decision, _) = actions.dropDecision(for: info, into: folder ?? state?.currentFolder)
            let operation = decision.dragOperation(sourceMask: info.draggingSourceOperationMask)
            (tableView as? FileBrowserTableView)?.isWholeTableDropTarget = folder == nil && !operation.isEmpty
            return operation
        }

        func tableView(
            _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            (tableView as? FileBrowserTableView)?.isWholeTableDropTarget = false
            guard let actions else { return false }
            let destination = dropFolder(row: row, operation: dropOperation) ?? state?.currentFolder
            let (decision, urls) = actions.dropDecision(for: info, into: destination)
            actions.performDrop(decision, urls: urls)
            return decision.isAccepted
        }

        /// 行の上へのドロップで、その行がフォルダ(パッケージでない)ならそのフォルダ。
        private func dropFolder(row: Int, operation: NSTableView.DropOperation) -> URL? {
            guard operation == .on, entries.indices.contains(row), entries[row].isNavigableFolder else { return nil }
            return entries[row].url
        }

        // MARK: 操作

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let table, let state else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].id : nil })
            if ids != state.selection { state.selection = ids }
        }

        /// 名前の列は先頭から動かさず、ほかの列も名前の列より前へは入れない(Finder と同じ)。
        func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            guard tableView.tableColumns.indices.contains(columnIndex) else { return false }
            if tableView.tableColumns[columnIndex].identifier == Column.name.identifier { return false }
            return newColumnIndex != 0
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
        /// 行の外(空きスペース)ならペースト・新規フォルダ・表示・表示順序。
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table else { return }
            if menu === headerMenu {
                rebuildHeaderMenu(menu)
                return
            }
            let clicked = table.clickedRow
            let folder = state?.currentFolder
            guard clicked >= 0, entries.indices.contains(clicked) else {
                menuBuilder.rebuild(
                    menu, for: FileBrowserMenuContext(kind: .background, entries: [], folder: folder),
                    actions: actions, locale: locale
                )
                return
            }
            let targets: [FileBrowserEntry]
            if table.selectedRowIndexes.contains(clicked) {
                targets = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
            } else {
                targets = [entries[clicked]]
            }
            menuBuilder.rebuild(
                menu, for: FileBrowserMenuContext(kind: .of(entries[clicked]), entries: targets, folder: folder),
                actions: actions, locale: locale
            )
        }

        /// 見出しの右クリック: 列を並んでいる順に、表示中はチェック付きで。名前の列は淡色(隠せない)。
        private func rebuildHeaderMenu(_ menu: NSMenu) {
            guard let table else { return }
            menu.removeAllItems()
            menu.autoenablesItems = false
            for tableColumn in table.tableColumns {
                guard let column = Column(rawValue: tableColumn.identifier.rawValue) else { continue }
                let item = NSMenuItem(
                    title: String(localized: column.title, language: locale),
                    action: #selector(toggleColumn(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = column.rawValue
                item.state = tableColumn.isHidden ? .off : .on
                item.isEnabled = column.isHideable
                menu.addItem(item)
            }
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let state, let raw = sender.representedObject as? String,
                  let column = Column(rawValue: raw), column.isHideable
            else { return }
            if state.hiddenListColumns.contains(raw) {
                state.hiddenListColumns.remove(raw)
            } else {
                state.hiddenListColumns.insert(raw)
            }
            applyHiddenColumns(from: state)
        }
    }
}

/// Return で開く(`NSTableView`の既定では Return は何もしない)。編集メニューのコピー・カット・ペーストと、
/// ファイルブラウザのキー(⌘⌫ / ⌥⌘V / ⌘[ / ⌘] / ⌘↑)を`editResponder`へ渡す(段階4)。
final class FileBrowserTableView: NSTableView, NSMenuItemValidation {
    var onReturn: (() -> Void)?
    weak var editResponder: (any FileBrowserEditResponding)?
    var onWholeTableDropTargetChange: ((Bool) -> Void)?
    /// 表全体が受け口になっているか(FileBrowserListView.onWholeListDropTargetChange)。出たとき・落とされたときに下ろす。
    /// **`draggingEnded` / `concludeDragOperation` は上書きしない**(FileBrowserOutlineView のコメント: ドラッグ元の終わりの通知が止まる)。
    var isWholeTableDropTarget = false {
        didSet {
            guard isWholeTableDropTarget != oldValue else { return }
            onWholeTableDropTargetChange?(isWholeTableDropTarget)
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isWholeTableDropTarget = false
        super.draggingExited(sender)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Return / Enter、⌘↓(Finderの「開く」)。
        if (event.keyCode == 36 || event.keyCode == 76) && flags.subtracting([.numericPad, .function]).isEmpty
            || (event.keyCode == 125 && flags.contains(.command)) {
            onReturn?()
            return
        }
        if let command = FileBrowserEditCommand.forKey(event), let editResponder {
            if editResponder.canPerform(command) { editResponder.perform(command) }
            return
        }
        super.keyDown(with: event)
    }

    /// 名前の欄を当たり先にするのは、`validateProposedFirstResponder` が許すときだけ(2026-09-14、段階 8.5 の実機)。
    ///
    /// 通常は NSTableView の `hitTest` 自身がこの判定を尋ね、断られた欄の代わりに表を返すので、クリックは表の `mouseDown`
    /// (選択)・右クリックは `menu(for:)` へ届く。ところが**アイコン表示の右クリックでサブメニューを開いて Esc で閉じたあと、
    /// その尋ね方が飛ばされる状態になった**(ログで実測: `hitTest` が判定を呼ばずに名前の欄を返し、ウインドウが欄をそのまま
    /// ファーストレスポンダにしてから判定が呼ばれた。ウインドウはキーのまま、アプリも前面のまま)。その間、右クリックのメニューが
    /// 開かず、選ばれていない行のクリックで(読み取り専用モードでも)名前の編集が始まった。タイトルバーを 1 回クリックすると戻る。
    /// AppKit の内側の状態は見えないので、当たり先の側で同じ判定を確かめ直す。
    override func hitTest(_ point: NSPoint) -> NSView? {
        resolvedHit(super.hitTest(point), event: NSApp.currentEvent)
    }

    /// `hitTest` の結果を確かめ直す(テストはここを直に呼ぶ ―― AppKit が判定を飛ばす状態はテストでは作れない)。
    func resolvedHit(_ hit: NSView?, event: NSEvent?) -> NSView? {
        if let field = hit as? FileBrowserNameField, field.currentEditor() == nil,
           !validateProposedFirstResponder(field, for: event) {
            return self
        }
        return hit
    }

    /// 選ばれている行をもう一度クリックして名前の編集を始めるのは、**1行だけを選んでいるときだけ**
    /// (複数選択中のクリックは選択を1件に絞る操作。Finder と同じ)。読み取り専用モードの間は始めない(段階 8.5)。
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is FileBrowserNameField,
           selectedRowIndexes.count != 1 || !(editResponder?.allowsFileChanges ?? false) { return false }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        fileBrowserDragSourceMask(allowsFileChanges: editResponder?.allowsFileChanges ?? false)
    }

    @objc func copy(_ sender: Any?) { editResponder?.perform(.copy) }
    @objc func cut(_ sender: Any?) { editResponder?.perform(.cut) }
    @objc func paste(_ sender: Any?) { editResponder?.perform(.paste) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): editResponder?.canPerform(.copy) ?? false
        case #selector(cut(_:)): editResponder?.canPerform(.cut) ?? false
        case #selector(paste(_:)): editResponder?.canPerform(.paste) ?? false
        case #selector(selectAll(_:)): numberOfRows > 0
        default: true
        }
    }
}

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
///
/// ■ 1 つの欄の値を 1 段ずつ(qooMeta 0.3.0 の `BookTable` から移した。2026-10-01、利用者の指示)
/// 値をいくつも持つ欄(qooViewer では著者・原作・情報だけ。`holdsSeveralInQooViewer`)は、値ごとに段を分けて縦に並べ、**行の高さを段の数
/// だけ伸ばす**(列を横に増やすと読みにくいので)。qooMeta の「足したシリーズ」(シリーズ・巻数の列の 2 段目から)は持たない
/// (シリーズは巻数と同じく 1 つ。利用者の判断 2026-10-01)。
/// - 段を押すとその段が選ばれ(枠が付く)、絞り込みの帯の「上へ」「下へ」でその本の中で動かせる。
/// - 2 回押しでその段だけを書き換える。空にして確定するとその段が消える。
/// - 書き換えの最中の **Option+Return** で、その下に空の段を足してそのまま書ける(右クリックの「段を足す」でも)。
/// - Tab / ⇧Tab は、同じ欄の次 / 前の段、端まで来たら隣の欄へ。
/// ほかの列の文字・鍵・表紙は、各行の上端に揃える(1 段目と同じ高さに並ぶ)。
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

        /// ダブルクリックで直せる列(直せるかどうかは本ごとに `canEdit` で決める)。
        var isEditable: Bool {
            switch self {
            case .field, .volumeSort: true
            case .lock, .fileName, .cover: false
            }
        }

        /// 隠せない列(どの本の行か分からなくなる・ロックの切り替えが無くなる)。
        var isHideable: Bool { self != .fileName && self != .lock }

        /// 段を持つ欄としての見分け(段の選択と「上へ」「下へ」に使う)。値をいくつも持てる欄(著者・原作・情報)だけ。
        var lineColumn: MetadataWorkspace.LineColumn? {
            if case .field(let field) = self, field.holdsSeveralInQooViewer { return .field(field) }
            return nil
        }

        /// セルに出す段(上から)。値の無い欄も空の 1 段。段を持たない欄は 1 段(先頭の値)。
        func lines(of book: MetadataBookRow) -> [String] {
            switch self {
            case .fileName: return [book.fileName]
            case .volumeSort: return [book.volumeSortText]
            case .field(let field) where field.holdsSeveralInQooViewer:
                let values = book.metadata.values(field)
                return values.isEmpty ? [""] : values
            case .field(let field): return [book.metadata[field]]
            case .lock, .cover: return [""]
            }
        }

        /// 段の数(行の高さを決める。値を組み立てずに、行が作り置いた数から引く)。
        func lineCount(of book: MetadataBookRow) -> Int {
            guard case .field(let field) = self else { return 1 }
            return book.tallFields[field] ?? 1
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
    /// 「この本を見える位置へ」の頼み(編集メニューから本を指して窓を開いたとき。`MetadataWorkspace.reveal`)。
    /// 通し番号が前と変わったときだけスクロールする。
    var revealRequest: MetadataWorkspace.RevealRequest?
    /// 選んだ段(`MetadataWorkspace.lineSelection`)。
    @Binding var lineSelection: MetadataWorkspace.LineSelection?
    /// その段を直せるか(段の番号つき)。直せる列は欄の列と巻数(並べ替え用)の列(2026-09-22、利用者の要望で巻数(並べ替え用)も
    /// 直せるようにした)。
    var canEdit: (Column, MetadataBookRow, Int) -> Bool
    /// 利用者が直した(確定した)段か。提案のままの値と色で見分ける。
    var isEdited: (Column, MetadataBookRow, Int) -> Bool
    var help: (Column, MetadataBookRow) -> String
    /// 段を書き換えた(段の番号・書いた文字)。
    var commit: (Column, Int, String, MetadataBookRow) -> Void
    /// 段を足した(足した位置・書いた文字)。空の文字では呼ばない。
    var insert: (Column, Int, String, MetadataBookRow) -> Void
    /// 右クリックのメニュー(右クリックした本、または選んだ本すべてについて)。
    var contextMenu: (Set<MetadataBookRow.ID>) -> [MenuItem]
    /// 鍵の列を押した(その本のロックを切り替える)。
    var toggleLock: (MetadataBookRow.ID) -> Void
    /// 表紙の列のセルの中身(SwiftUI)。
    var coverView: (MetadataBookRow.ID) -> AnyView

    /// 列の並び・幅・表示を覚えておく名前。列を足したので名前も変えた(前の並びを当てると新しい列が隠れる)。
    static let autosaveName = "qooViewer.metadataEditor.bookTable.v2"

    /// 段の高さと、行の上下の余白。1 段の行は前と同じ 24 の高さ。
    static let lineHeight: CGFloat = 18
    static let verticalPadding: CGFloat = 3

    static func rowHeight(lines: Int) -> CGFloat { verticalPadding * 2 + lineHeight * CGFloat(max(1, lines)) }

    /// 1 段目の真ん中の高さ(セルの上端から。鍵・表紙を 1 段目に揃える)。
    static var firstLineCenter: CGFloat { verticalPadding + lineHeight / 2 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .custom
        table.rowHeight = Self.rowHeight(lines: 1)
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
        table.action = #selector(Coordinator.clicked(_:))
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
        coordinator.refreshVisibleColumns()

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

    /// セル 1 つ。段ごとの文字を上から並べる(1 段なら前と同じ見た目)。使い回す。
    final class CellView: NSTableCellView {
        private(set) var labels: [NSTextField] = []
        /// 段ごとの、利用者が直した値か(色を変える)。
        private var editedLines: [Bool] = []
        /// 本の実体が無い(灰色にする)。
        var isMissing = false { didSet { updateColors() } }
        /// ファイル名フォーマットと合致しなかった本のファイル名(オレンジにする)。
        var isUnmatchedName = false { didSet { updateColors() } }
        /// ロックした本の行(文字を黄色にする。2026-09-22、利用者の要望 ―― 鍵の列だけでは、ロックした本が一覧のどこに
        /// あるか見分けにくい。最初は行の地を黄色にしたが、望まれていたのは文字の色だった)。
        var isLockedRow = false { didSet { updateColors() } }
        /// 選んだ段(枠を付ける)。2 段以上あるセルだけに付ける ―― 1 段のセルに枠を付けても、動かす先が無い。
        var selectedLine: Int? { didSet { if selectedLine != oldValue { updateColors() } } }
        /// 書き換えの最中の段。
        private(set) var editingLine: Int?

        /// ロックした行の文字の色。明るい外観の systemYellow は白い地の上で読めないので、明るい外観では暗めの黄色にする。
        static let lockedTextColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .systemYellow : NSColor(srgbRed: 0.66, green: 0.49, blue: 0.0, alpha: 1)
        }

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("コードで組み立てる") }

        private func makeLabel() -> NSTextField {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            label.cell?.isScrollable = true
            // 切れて見えない名前は、指したときに全体を出す。
            label.allowsExpansionToolTips = true
            label.wantsLayer = true
            label.layer?.cornerRadius = 3
            return label
        }

        /// 段を入れ替える(書き換えの最中なら、入力を途中で消さないよう何もしない)。
        func setLines(_ lines: [String], edited: [Bool]) {
            guard editingLine == nil else { return }
            while labels.count < lines.count {
                let label = makeLabel()
                addSubview(label)
                labels.append(label)
            }
            for (i, label) in labels.enumerated() {
                label.isHidden = i >= lines.count
                if i < lines.count, label.stringValue != lines[i] { label.stringValue = lines[i] }
            }
            editedLines = edited
            textField = labels.first
            needsLayout = true
            updateColors()
        }

        /// 見えている段の数。
        var lineCount: Int { labels.filter { !$0.isHidden }.count }

        func label(at line: Int) -> NSTextField? { labels.indices.contains(line) && !labels[line].isHidden ? labels[line] : nil }

        override func layout() {
            super.layout()
            for (i, label) in labels.enumerated() {
                let height = min(MetadataBookTable.lineHeight, label.intrinsicContentSize.height)
                label.frame = NSRect(x: 2, y: MetadataBookTable.verticalPadding + MetadataBookTable.lineHeight * CGFloat(i)
                                         + (MetadataBookTable.lineHeight - height) / 2,
                                     width: max(0, bounds.width - 4), height: height)
            }
        }

        /// 選んだ行(強調の地)では、直した欄の色も地に合わせる(色のままだと、選んだ行の上で読めない)。
        override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }

        func updateColors() {
            let emphasized = backgroundStyle == .emphasized
            let framesLine = lineCount > 1 ? selectedLine : nil
            for (i, label) in labels.enumerated() {
                label.layer?.borderWidth = i == framesLine ? 1.5 : 0
                label.layer?.borderColor = (emphasized ? NSColor.alternateSelectedControlTextColor : .controlAccentColor).cgColor
                guard i != editingLine else { continue }
                let edited = editedLines.indices.contains(i) && editedLines[i]
                label.textColor = emphasized ? .alternateSelectedControlTextColor
                    : isMissing ? .tertiaryLabelColor
                    : isUnmatchedName ? .systemOrange
                    : isLockedRow ? Self.lockedTextColor
                    : edited ? .controlAccentColor : .labelColor
            }
        }

        /// 段の書き換えに入る・出るときの見た目(入っているあいだは、ふつうの入力欄の色)。
        func setEditing(_ line: Int?) {
            if let previous = editingLine, let label = label(at: previous) { style(label, editing: false) }
            editingLine = line
            if let line, let label = label(at: line) { style(label, editing: true) }
            updateColors()
        }

        private func style(_ label: NSTextField, editing: Bool) {
            label.isEditable = editing
            label.isSelectable = editing
            label.drawsBackground = editing
            label.backgroundColor = editing ? .textBackgroundColor : .clear
            if editing { label.textColor = .textColor }
        }

        /// 押した位置(セルの中の座標)にある段。
        func line(at point: NSPoint) -> Int {
            let index = Int(((point.y - MetadataBookTable.verticalPadding) / MetadataBookTable.lineHeight).rounded(.down))
            return min(max(index, 0), max(0, lineCount - 1))
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
                // 何段もある行でも 1 段目の高さに置く(欄の文字は上端に揃う)。
                button.centerYAnchor.constraint(equalTo: topAnchor, constant: MetadataBookTable.firstLineCenter),
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
                host.centerYAnchor.constraint(equalTo: topAnchor, constant: MetadataBookTable.firstLineCenter),
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
        /// 書き換えの最中の段。`inserting` は、足した(まだ値の無い)段。
        private(set) var editing: (bookID: String, column: Column, line: Int, original: String, cell: CellView, inserting: Bool)?
        /// 足している最中の段(その本・その列の、その位置に空の段を 1 つ見せる)。`lines` は足したあとの段の並び。
        private var insertion: (bookID: String, column: Column, lines: [String])?
        /// 書き換えの最中に届いた中身(入力を途中で消さないよう、終わってから入れる)。
        private var pendingRows: (books: [MetadataBookRow], positions: [Int])?
        /// 見えている列(行の高さは、見えている列の段の数で決める。隠した列の段で行を伸ばさない)。
        private var visibleColumns: [Column] = Column.all
        /// 最後に表へ入れた、選んだ段(変わったら、前と今の行を描き直す)。
        private var shownLineSelection: MetadataWorkspace.LineSelection?

        init(_ parent: MetadataBookTable) { self.parent = parent }

        /// 画面の閉包を手放す(dismantleNSView)。
        func release() {
            parent = nil
            table?.menu = nil
            table?.headerView?.menu = nil
        }

        func refreshVisibleColumns() {
            guard let table else { return }
            visibleColumns = table.tableColumns.filter { !$0.isHidden }.compactMap { Column($0.identifier) }
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
            // 書き換えの最中は描き直さない(入力を消さない)。終わってからの次の回で描き直す。
            if editing == nil, parent.lineSelection != shownLineSelection {
                let rows = [shownLineSelection?.id, parent.lineSelection?.id].compactMap { $0 }.compactMap(index(of:))
                shownLineSelection = parent.lineSelection
                reload(IndexSet(rows))
            }
            if let request = parent.revealRequest, request.serial != lastRevealSerial {
                lastRevealSerial = request.serial
                // 運ぶのは次の回しで。窓を開いた直後は、表の大きさがまだ決まっていないことがあり、
                // 行の位置は「見えている範囲」から計るので、その場で運ぶと外れる。
                let id = request.id
                DispatchQueue.main.async { [weak self] in
                    guard let self, let table = self.table, let row = self.index(of: id) else { return }
                    table.scrollRowToVisible(row)
                }
            }
        }

        /// 最後に応えた「見える位置へ」の通し番号(`MetadataBookTable.revealRequest`)。
        private var lastRevealSerial = 0

        /// 行を描き直す(段の数が変わりうるので、高さも取り直す)。
        private func reload(_ rows: IndexSet) {
            guard let table, !rows.isEmpty else { return }
            table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            noteHeights(rows)
        }

        /// 行の高さを取り直す。高さが動くときに行が滑らないよう、動きは付けない。
        private func noteHeights(_ rows: IndexSet) {
            guard let table, !rows.isEmpty else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: rows)
            }
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
                reload(IndexSet(newPositions.indices.filter { oldBooks[newPositions[$0]] != newBooks[newPositions[$0]] }))
            } else {
                // 高さはすべての行で取り直される(`reloadData` が聞き直す)。
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

        /// 行の高さ: 見えている列のうち、いちばん段の多い列に合わせる。**段の数は行が作り置いた数から引く**
        /// (`reloadData` はすべての行の高さを聞くので、ここで欄の値を組み立てない)。
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0, row < rowCount else { return MetadataBookTable.rowHeight(lines: 1) }
            let book = book(row)
            var lines = 1
            if !book.tallFields.isEmpty {
                for column in visibleColumns { lines = max(lines, column.lineCount(of: book)) }
            }
            if let insertion, insertion.bookID == book.id, visibleColumns.contains(insertion.column) {
                lines = max(lines, insertion.lines.count)
            }
            return MetadataBookTable.rowHeight(lines: lines)
        }

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
            cell.setEditing(nil)
            let lines: [String]
            if let insertion, insertion.bookID == book.id, insertion.column == column {
                lines = insertion.lines
            } else {
                lines = column.lines(of: book)
            }
            cell.isMissing = book.isMissing
            cell.isUnmatchedName = column == .fileName && !book.matchedFormat
            cell.isLockedRow = book.isLocked
            cell.setLines(lines, edited: lines.indices.map { column != .fileName && parent.isEdited(column, book, $0) })
            if let selected = parent.lineSelection, selected.id == book.id, selected.column == column.lineColumn {
                cell.selectedLine = selected.index
            } else {
                cell.selectedLine = nil
            }
            switch column {
            case .fileName:
                // どの本かはフルパスで分かる(同じ名前の本が別のフォルダにあることがある)。
                var tip = book.id
                if !book.matchedFormat { tip += "\n" + "This file name matched no file name format of its rule set".ui }
                if book.isMissing { tip += "\n" + "The book itself can't be found".ui }
                cell.toolTip = tip
            case .volumeSort, .field:
                cell.toolTip = parent.help(column, book)
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

        /// 押した所のセルと段(押していなければ nil)。
        private func clickedLine(in table: NSTableView) -> (row: Int, column: Int, line: Int)? {
            let row = table.clickedRow, column = table.clickedColumn
            guard row >= 0, row < rowCount, column >= 0,
                  let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? CellView,
                  let event = NSApp.currentEvent else { return nil }
            return (row, column, cell.line(at: cell.convert(event.locationInWindow, from: nil)))
        }

        /// 1 回押し: 行を選ぶ(表がする)のに加えて、押した段を選ぶ。
        @objc func clicked(_ sender: Any?) {
            guard let table, let parent else { return }
            guard let clicked = clickedLine(in: table),
                  let lineColumn = Column(table.tableColumns[clicked.column].identifier)?.lineColumn else {
                if parent.lineSelection != nil { parent.lineSelection = nil }
                return
            }
            let selection = MetadataWorkspace.LineSelection(id: book(clicked.row).id, column: lineColumn, index: clicked.line)
            if parent.lineSelection != selection { parent.lineSelection = selection }
        }

        // MARK: 書き換える

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, let clicked = clickedLine(in: table) else { return }
            beginEditing(row: clicked.row, column: clicked.column, line: clicked.line)
        }

        /// その段の書き換えに入る。読むだけの列(ファイル名・鍵・表紙)と、いまは直せない段では何もしない。
        @discardableResult
        func beginEditing(row: Int, column: Int, line: Int, inserting: Bool = false) -> Bool {
            guard let parent, let table, editing == nil, row >= 0, row < rowCount, table.tableColumns.indices.contains(column),
                  let target = Column(table.tableColumns[column].identifier), target.isEditable,
                  inserting || parent.canEdit(target, book(row), line) else { return false }
            // 行き先の欄が横にはみ出していれば見える所まで送る(送らないと、見えない欄で書き換えが始まる。実機で確認)。
            table.scrollColumnToVisible(column)
            guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? CellView,
                  let label = cell.label(at: line) else { return false }
            editing = (book(row).id, target, line, label.stringValue, cell, inserting)
            cell.setEditing(line)
            label.delegate = self
            guard table.window?.makeFirstResponder(label) == true else {
                finishEditing(keeping: false)
                return false
            }
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            let movement = notification.userInfo?["NSTextMovement"] as? Int
            let edited = editing.map { (bookID: $0.bookID, column: $0.column, line: $0.line) }
            finishEditing(keeping: true)
            // Return で入れたときは、表へ戻る(矢印で次の行へ行ける)。ほかを押して抜けたときは、押した先を邪魔しない。
            if movement == NSTextMovement.return.rawValue, let table { table.window?.makeFirstResponder(table) }
            // Tab / ⇧Tab は、同じ欄の次 / 前の段、端まで来たら隣の欄へ(2026-09-27、監査 38。表計算・Finder の一覧と同じ。
            // 以前は Tab でも書き換えを終えるだけだった)。並びは見えている列の並び(利用者が並べ替えた順)。入れた値の計算し直しで
            // 行が並び直すことがあるので、本の id で行を引き直し、書き換えを終えた後の次の回で入る。
            if let edited, movement == NSTextMovement.tab.rawValue || movement == NSTextMovement.backtab.rawValue {
                let forward = movement == NSTextMovement.tab.rawValue
                DispatchQueue.main.async { [weak self] in
                    self?.moveEditing(from: edited.column, line: edited.line, of: edited.bookID, forward: forward)
                }
            }
        }

        /// Tab / ⇧Tab の行き先へ書き換えを移す。行き先の候補は、同じ欄の残りの段、その先の列の段(前へ戻るときは下の段から)。
        /// 直せない段は飛ばし、直せる段が端まで無ければ表へ戻る。
        private func moveEditing(from column: Column, line: Int, of bookID: String, forward: Bool) {
            guard let table, editing == nil, let row = index(of: bookID) else { return }
            let visible = table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
            guard let start = visible.firstIndex(where: { Column(table.tableColumns[$0].identifier) == column }) else { return }
            let book = book(row)
            var candidates: [(column: Int, line: Int)] = []
            for position in forward ? Array(start..<visible.count) : Array((0...start).reversed()) {
                let columnIndex = visible[position]
                let target = Column(table.tableColumns[columnIndex].identifier)
                let count = target?.lines(of: book).count ?? 1
                var lines = forward ? Array(0..<count) : Array((0..<count).reversed())
                if position == start {
                    lines = lines.filter { forward ? $0 > line : $0 < line }
                }
                candidates += lines.map { (columnIndex, $0) }
            }
            for candidate in candidates where beginEditing(row: row, column: candidate.column, line: candidate.line) { return }
            table.window?.makeFirstResponder(table)
        }

        /// Esc は、元の値へ戻して抜ける。Option+Return は、書いた値を入れて、その下に段を足す。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), let edit = editing {
                let value = edit.cell.label(at: edit.line)?.stringValue ?? ""
                let lines = edit.cell.labels.prefix(edit.cell.lineCount).map(\.stringValue)
                // 書いた値を先に入れる(書き換えを終える)。
                (control.window ?? table?.window)?.makeFirstResponder(table)
                if editing != nil { finishEditing(keeping: true) }
                startInsertion(after: edit.line, of: edit.bookID, column: edit.column, currentLines: lines, value: value)
                return true
            }
            guard selector == #selector(NSResponder.cancelOperation(_:)), editing != nil else { return false }
            control.abortEditing()
            finishEditing(keeping: false)
            if let table { table.window?.makeFirstResponder(table) }
            return true
        }

        /// 段を足して、そのまま書き換えに入る(値をいくつも持てる欄 ―― 著者・原作・情報 ―― だけ)。
        /// - Parameters:
        ///   - line: この段の下に足す(nil なら一番下に)。
        ///   - currentLines: いま見えている段(直したばかりの値を含む。計算し直しが届く前でも、見た目を合わせるため)。
        ///   - value: 直したばかりの段の値(著者を「、」で分けたときは、分けた数だけ下に足す)。
        func startInsertion(after line: Int?, of bookID: String, column: Column, currentLines: [String]? = nil,
                            value: String? = nil) {
            guard let table, editing == nil, let row = index(of: bookID), column.lineColumn != nil else { return }
            let target = column
            var lines = target.lines(of: book(row))
            var at = line.map { $0 + 1 } ?? lines.count
            if let currentLines, let line, currentLines.indices.contains(line) {
                // 直したばかりの段を、書いた値で見せる(著者は分けた数だけ段が増え、空にした段は消える)。
                lines = currentLines
                let text = (value ?? "").trimmingCharacters(in: .whitespaces)
                switch column.lineColumn {
                case .field(let field)?:
                    let pieces = MetadataWorkspace.linePieces(field, text)
                    if pieces.isEmpty {
                        lines.remove(at: line)
                        at = line
                    } else {
                        lines.replaceSubrange(line...line, with: pieces)
                        at = line + pieces.count
                    }
                case nil:
                    break
                }
            }
            // 値の無い欄(空の 1 段)に足すときは、その空の段に書く。
            if lines == [""] { lines = [] }
            at = min(at, lines.count)
            lines.insert("", at: at)
            insertion = (bookID, target, lines)
            guard let columnIndex = table.tableColumns.firstIndex(where: { $0.identifier == target.identifier }),
                  !table.tableColumns[columnIndex].isHidden else {
                insertion = nil
                return NSSound.beep()
            }
            reload(IndexSet(integer: row))
            DispatchQueue.main.async { [weak self] in
                guard let self, let row = self.index(of: bookID) else { return }
                if !self.beginEditing(row: row, column: columnIndex, line: at, inserting: true) { self.endInsertion() }
            }
        }

        /// 足している最中の段を片付ける(見せていた空の段を消す)。
        private func endInsertion() {
            guard let insertion else { return }
            self.insertion = nil
            if let row = index(of: insertion.bookID) { reload(IndexSet(integer: row)) }
        }

        private func finishEditing(keeping: Bool) {
            guard let edit = editing else { return }
            editing = nil
            let label = edit.cell.label(at: edit.line)
            let value = label?.stringValue ?? ""
            label?.delegate = nil
            edit.cell.setEditing(nil)
            // 表に出すのは、いつも持ちものの値(入れた値は、計算し直しが済んでから行として届く)。
            label?.stringValue = edit.original
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if keeping, let row = index(of: edit.bookID) {
                if edit.inserting {
                    if !trimmed.isEmpty { parent?.insert(edit.column, edit.line, value, book(row)) }
                } else if trimmed != edit.original {
                    parent?.commit(edit.column, edit.line, value, book(row))
                }
            }
            if edit.inserting { endInsertion() }
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
            // 押した列に段を足す(値をいくつも持てる欄 ―― 著者・原作・情報 ―― で、1 冊だけ、直せる本のとき)。
            if table.clickedColumn >= 0, let column = Column(table.tableColumns[table.clickedColumn].identifier),
               column.lineColumn != nil {
                let book = book(table.clickedRow)
                let bookID = book.id
                let item = MenuItem(title: "Add a Line to “%@”".ui(column.titleKey.ui),
                                    isEnabled: ids.count == 1 && parent.canEdit(column, book, 1)) { [weak self] in
                    self?.startInsertion(after: nil, of: bookID, column: column)
                }
                menu.addItem(makeItem(item))
                menu.addItem(.separator())
            }
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
            refreshVisibleColumns()
            // 隠した列の段で伸びていた行は縮み、出した列の段で伸びる。
            noteHeights(IndexSet(integersIn: 0..<rowCount))
        }
    }
}

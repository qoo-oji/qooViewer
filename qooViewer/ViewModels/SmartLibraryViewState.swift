import Combine
import Foundation

/// スマートライブラリの画面の状態(ウインドウごと。画面が持つ)。2026-09-21。
///
/// 選んだスマートシェルフ・左ペインのブラウザと絞り込み・検索・並べ替えを持ち、それらと本の一覧から
/// **並べる本を作り置きする**(`visibleBooks`)。描き直しのたびに数千冊を絞り込み直さないため(メタデータの編集ウインドウの
/// 一覧と同じ考え方)。作り直すのは中身が変わったときだけで、同じランループの中の変更は 1 回にまとめる。
///
/// 絞り込みの重なり方: **スマートシェルフ → 絞り込み → ブラウザ → 検索**。すべて AND。ブラウザは欄ごとに複数の値を選べ、
/// 同じ欄の中は「いずれか」(`SmartFacetSelection`)。ブラウザの欄の候補と冊数は、**ほかの欄**の選択で絞った本から数える
/// (自分の欄で 2 つ目を選ぼうとしたら候補が消えていた、とならないように)。
///
/// 保存するもの(次に開いたときも同じ所から): 選んだスマートシェルフ・ブラウザのボタンの並び・並べ替え・表紙の大きさ・
/// 左ペインの幅。絞り込み・ブラウザで選んだ値・検索は保存しない(StackNest のフィルタと同じく、いまの作業のための一時的なもの)。
/// ピン留めはアプリで共有(`SmartLibraryStore.pins`)。
@MainActor
final class SmartLibraryViewState: ObservableObject {
    private enum Keys {
        static let selectedShelf = "qooViewer.smartLibrary.selectedShelf"
        /// ブラウザのボタンの並び(2026-09-22 から数が変えられる。以前の 3 列固定の鍵とは別)。
        static let facetFields = "qooViewer.smartLibrary.browserFields"
        static let sortKey = "qooViewer.smartLibrary.sortKey"
        static let sortAscending = "qooViewer.smartLibrary.sortAscending"
        static let coverSize = "qooViewer.smartLibrary.coverSize"
        static let sidebarWidth = "qooViewer.smartLibrary.sidebarWidth"
        static let grouping = "qooViewer.smartLibrary.grouping"
        static let viewMode = "qooViewer.smartLibrary.viewMode"
        /// 束ねる設定が「シリーズでまとめる」の ON/OFF だった頃の鍵(読むだけ。`grouping` が無いときの初期値に使う)。
        static let legacyGroupsBySeries = "qooViewer.smartLibrary.groupsBySeries"
    }

    static let coverSizeRange: ClosedRange<CGFloat> = 80...300
    static let defaultCoverSize: CGFloat = 130
    static let sidebarWidthRange: ClosedRange<CGFloat> = 200...460
    static let defaultSidebarWidth: CGFloat = 270
    /// ブラウザのボタンの最初の並び(利用者の指示 2026-09-22: ジャンル・著者・シリーズ)。
    static let defaultFacetFields: [SmartFacetField] = [.genre, .authors, .series]

    /// 選んだスマートシェルフ(nil は「すべての本」)。
    @Published var selectedShelfID: UUID? {
        didSet {
            guard selectedShelfID != oldValue else { return }
            defaults.set(selectedShelfID?.uuidString, forKey: Keys.selectedShelf)
            // 棚が変わったら、ブラウザで選んだ値は外す(前の棚に無い値で空になるため)。開いていたシリーズからも出る。
            facetSelection = SmartFacetSelection()
            openedGroup = nil
            narrowingChanged()
        }
    }
    @Published var quickFilter = SmartQuickFilter() { didSet { if quickFilter != oldValue { narrowingChanged() } } }
    /// ブラウザのボタンの並び(同じ欄は 1 度だけ)。
    @Published var facetFields: [SmartFacetField] {
        didSet {
            guard facetFields != oldValue else { return }
            defaults.set(facetFields.map(\.rawValue), forKey: Keys.facetFields)
            // 並びから消えた欄の選択は外す(見えない所で絞り込みが残らないように)。
            for field in SmartFacetField.allCases where !facetFields.contains(field) { facetSelection[field] = [] }
            narrowingChanged()
        }
    }
    @Published var facetSelection = SmartFacetSelection() {
        didSet { if facetSelection != oldValue { narrowingChanged() } }
    }
    @Published var searchText = "" { didSet { if searchText != oldValue { narrowingChanged() } } }
    @Published var sortKey: SmartSortKey {
        didSet {
            guard sortKey != oldValue else { return }
            defaults.set(sortKey.rawValue, forKey: Keys.sortKey)
            narrowingChanged()
        }
    }
    @Published var sortAscending: Bool {
        didSet {
            guard sortAscending != oldValue else { return }
            defaults.set(sortAscending, forKey: Keys.sortAscending)
            narrowingChanged()
        }
    }
    /// 同じシリーズ / 同じ著者の本を 1 つの束にまとめて並べるか(2026-09-22、利用者の指示。`SmartGrouping`)。保存する。
    @Published var grouping: SmartGrouping {
        didSet {
            guard grouping != oldValue else { return }
            defaults.set(grouping.rawValue, forKey: Keys.grouping)
            // 束ね方を変えたら、開いていた束からは出る(その束はもう無い。出た束を選び直すこともしない)。
            openedGroup = nil
            pendingSelectionID = nil
            narrowingChanged()
        }
    }
    /// 開いている束の名前(シリーズ名 / 著者名。nil なら束の一覧)。束を押すと入り、見出しの戻るで出る。保存しない。
    @Published var openedGroup: String? {
        didSet {
            guard openedGroup != oldValue else { return }
            // 束から出たら、出てきた束を選んでおく(Finder で上のフォルダへ戻ったときと同じ。矢印キーの続きがそこから)。
            if let oldValue, openedGroup == nil {
                pendingSelectionID = SmartGridItem.groupID(grouping, name: oldValue)
                setNeedsRecompute()
            } else {
                // 束へ入ったら先頭から(出たときは、出てきた束が見える位置へ ―― `revealRequest`)。
                narrowingChanged()
            }
        }
    }
    /// リスト表示でその場に開いている束(`SmartGridItem.groupID`)。保存しないが、状態はウインドウが持つので、本を開いて
    /// 戻ってきたときも開いたまま(2026-09-24。リストの表は戻るたびに作り直される)。表が書き換えるだけで、画面は描き直さない。
    var expandedListGroupIDs: Set<String> = []
    /// 表紙のグリッドかリストか(2026-09-22、利用者の指示)。保存する。選択・絞り込み・束はどちらでも同じものを使う。
    @Published var viewMode: SmartLibraryViewMode {
        didSet {
            guard viewMode != oldValue else { return }
            defaults.set(viewMode.rawValue, forKey: Keys.viewMode)
        }
    }
    /// 環境設定「スマートライブラリ」→「先頭の著者だけを使う」(2026-09-23、利用者の要望。
    /// `AppPreferences.smartLibraryUsesFirstAuthorOnly` ―― 画面が渡す)。
    ///
    /// ON の間は、著者が複数ある本を**先頭の著者だけの本として受け取る**(`update(books:shelves:)` で写しを作る)。
    /// 著者を見る所 ―― ブラウザの「著者」のボタン(値と冊数・ピン留め)、スマートコレクションの条件と冊数、検索、
    /// 著者での並べ替え、リストの著者の列 ―― が、どれも同じ本を見るようにするため。所ごとに判定を足すと、
    /// ボタンでは消えた共著者が検索では当たる、といった食い違いが残る。**著者でまとめる**のは、もとから筆頭の著者で束ねる
    /// (`SmartGrouping.key`)ので変わらない。写しはこの画面の中だけのもので、DB のメタデータには触れない
    /// (スマートライブラリは読むだけ。SmartLibraryCatalog の型コメント)。
    ///
    /// 切り替えたら、ブラウザの「著者」で選んでいた値は外す(OFF → ON で共著者を選んでいたら、その値はボタンから消え、
    /// 見えない所で「0 冊」に絞り込んだままになる)。
    @Published var usesFirstAuthorOnly = false {
        didSet {
            guard usesFirstAuthorOnly != oldValue else { return }
            books = Self.applyingAuthorSetting(sourceBooks, firstAuthorOnly: usesFirstAuthorOnly)
            facetSelection[.authors] = []
            narrowingChanged()
        }
    }
    @Published var coverSize: CGFloat { didSet { defaults.set(Double(coverSize), forKey: Keys.coverSize) } }
    @Published var sidebarWidth: CGFloat { didSet { defaults.set(Double(sidebarWidth), forKey: Keys.sidebarWidth) } }

    // MARK: 作り置き

    /// 棚の条件に合う本(絞り込み・ブラウザ・検索の前)。
    @Published private(set) var shelfBookCount = 0
    /// 並べる本(すべての絞り込みと並べ替えの後)。
    @Published private(set) var visibleBooks: [SmartBook] = []
    /// グリッドの枠(束ねていなければ 1 冊ずつ、束ねていれば束と 1 冊、シリーズを開いていればその中の本)。
    @Published private(set) var gridItems: [SmartGridItem] = []
    /// ブラウザの欄ごとの、値と冊数(ほかの欄の選択で絞った本から数える)。
    @Published private(set) var facetValues: [SmartFacetField: [(value: SmartFacetValue, count: Int)]] = [:]
    /// スマートシェルフごとの冊数(左ペインに出す)。nil のキーは「すべての本」。
    @Published private(set) var shelfCounts: [UUID?: Int] = [:]

    // MARK: 選択(2026-09-22。`SmartGridSelection`。保存しない)

    /// グリッドで選んでいる枠。並びが変わるたびに、並びから消えたものを外す(`recompute`)。
    @Published private(set) var selection = SmartGridSelection()
    /// 「この枠を見える位置へ」の頼み(画面が受けてスクロールする)。キー操作の移動は画面がその場でスクロールするので、
    /// これは画面の外から選び直したとき(束から出た)だけ。同じ枠へ 2 度頼めるよう通し番号を持つ。
    @Published private(set) var revealRequest: RevealRequest?
    struct RevealRequest: Equatable {
        let id: String
        let serial: Int
    }
    /// 次に並べ直したときに選ぶ枠(束から出たときの、その束)。
    private var pendingSelectionID: String?
    /// 「一覧を先頭へ戻して」の合図(通し番号。画面が受けてスクロールする)。**絞り込み・検索・並べ替え・棚・束ね方を
    /// 利用者が変えたときだけ**進め、裏で集め直した結果が届いただけのとき(`update(books:shelves:)`)は進めない
    /// (StackNest と同じ区別。深く流した所で検索すると結果の途中から見える・空に見える、を防ぎ、読み込み直しで
    /// 位置が飛ぶのは防ぐ)。
    @Published private(set) var scrollResetSerial = 0
    private var pendingScrollReset = false
    /// type-select の溜めた文字と、最後に打った時刻(ファイルブラウザのアイコン表示と同じ規則。`typeSelect`)。
    private var typeSelectBuffer = ""
    private var typeSelectLastInput: Date?
    private var revealSerial = 0

    private let defaults: UserDefaults
    /// 画面から渡された本の一覧(集めたまま)。
    private var sourceBooks: [SmartBook] = []
    /// 絞り込み・並べ替えに使う本(`sourceBooks` に著者の設定を当てたもの。`usesFirstAuthorOnly`)。
    private var books: [SmartBook] = [] {
        didSet {
            // 本が変われば、棚の数え・検索の文字列の控えは作り直す(`shelfResults` / `searchHaystacks`)。
            shelfResults = nil
            searchHaystacks = nil
        }
    }
    private var shelves: [SmartShelf] = [] {
        didSet { if shelves != oldValue { shelfResults = nil } }
    }
    private var recomputeTask: Task<Void, Never>?

    /// スマートシェルフごとの数と、選んでいるシェルフの本(`recompute`。2026-09-25 の監査)。本・シェルフ・時刻(分)が同じ間は数え直さない。
    /// 検索の 1 文字・ボタンの 1 つ・並べ方を変えるたびに、全シェルフの条件を全冊に当て直していた(条件の文字は本ごとに畳み直す)。
    /// 「何日以内」の条件があるので、分が変われば数え直す。
    private var shelfResults: (minute: Int, selectedShelfID: UUID?, counts: [UUID?: Int], selectedBooks: [SmartBook])?
    /// 検索に当てる文字列(本ごと。`recompute`)。本が変わるまで使い回す(打つたびに全冊の欄を畳み直していた)。
    private var searchHaystacks: [String: String]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedShelfID = defaults.string(forKey: Keys.selectedShelf).flatMap(UUID.init(uuidString:))
        if let stored = defaults.stringArray(forKey: Keys.facetFields) {
            var fields: [SmartFacetField] = []
            for field in stored.compactMap(SmartFacetField.init(rawValue:)) where !fields.contains(field) { fields.append(field) }
            facetFields = fields
        } else {
            facetFields = Self.defaultFacetFields
        }
        sortKey = SmartSortKey(rawValue: defaults.string(forKey: Keys.sortKey) ?? "") ?? .title
        sortAscending = defaults.object(forKey: Keys.sortAscending) as? Bool ?? true
        grouping = SmartGrouping(rawValue: defaults.string(forKey: Keys.grouping) ?? "")
            ?? (defaults.bool(forKey: Keys.legacyGroupsBySeries) ? .series : .none)
        viewMode = SmartLibraryViewMode(rawValue: defaults.string(forKey: Keys.viewMode) ?? "") ?? .grid
        coverSize = (defaults.object(forKey: Keys.coverSize) as? Double)
            .map { Self.coverSizeRange.clamping(CGFloat($0)) } ?? Self.defaultCoverSize
        sidebarWidth = (defaults.object(forKey: Keys.sidebarWidth) as? Double)
            .map { Self.sidebarWidthRange.clamping(CGFloat($0)) } ?? Self.defaultSidebarWidth
    }

    /// 本の一覧・保存したスマートシェルフが変わった(画面から渡す)。
    func update(books: [SmartBook], shelves: [SmartShelf]) {
        sourceBooks = books
        self.books = Self.applyingAuthorSetting(books, firstAuthorOnly: usesFirstAuthorOnly)
        self.shelves = shelves
        // 消されたスマートシェルフを選んでいたら「すべての本」へ。
        if let id = selectedShelfID, !shelves.contains(where: { $0.id == id }) { selectedShelfID = nil }
        // 本の一覧が届いたら**その場で**作り直す(次のコマへ回すと、本はあるのに並べる本がまだ空のコマができ、
        // 「条件に合う本がありません」が一瞬出る)。絞り込みの操作のほうは今までどおり 1 コマにまとめる。
        recompute()
    }

    var selectedShelf: SmartShelf? { selectedShelfID.flatMap { id in shelves.first { $0.id == id } } }

    /// 絞り込み・ブラウザ・検索のどれかが効いているか(「すべて解除」を出すか)。
    var isNarrowing: Bool {
        quickFilter.isActive || facetSelection.isActive || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func clearNarrowing() {
        quickFilter = SmartQuickFilter()
        facetSelection = SmartFacetSelection()
        searchText = ""
    }

    // MARK: ブラウザのボタン

    func toggleFacet(_ value: SmartFacetValue, in field: SmartFacetField) {
        facetSelection.toggle(value, in: field)
    }

    func clearFacet(_ field: SmartFacetField) {
        facetSelection[field] = []
    }

    /// ボタンを足す(並びの最後へ)。
    func addFacetField(_ field: SmartFacetField) {
        guard !facetFields.contains(field) else { return }
        facetFields.append(field)
    }

    func removeFacetField(_ field: SmartFacetField) {
        facetFields.removeAll { $0 == field }
    }

    /// ボタンの欄を替える(替えた先の欄が別のボタンにあれば、2 つを入れ替える)。
    func replaceFacetField(_ old: SmartFacetField, with new: SmartFacetField) {
        guard old != new, let index = facetFields.firstIndex(of: old) else { return }
        var fields = facetFields
        if let other = fields.firstIndex(of: new) { fields[other] = old }
        fields[index] = new
        facetSelection[old] = []
        facetSelection[new] = []
        facetFields = fields
    }

    // MARK: 選択

    /// 並びの識別子(選択の計算に渡す順)。
    var gridItemIDs: [String] { gridItems.map(\.id) }

    /// 選んでいる本のパス(束は含めない。リストで開いた束の中の本は含める)。メニューバーの項目の相手
    /// (WelcomeLibraryState.smartSelectedBookPaths。2026-09-23)。
    ///
    /// **多くても 2 つ**(2026-09-23 の 3 回目の監査の低)。メニューバーが見るのは「1 冊だけか」(`HomeMenuState.singleSmartBookTarget`)
    /// だけで、画面を描き直すたびに `onChange` がこれを読むので、以前は「すべて選択」の数千冊を描き直しのたびに並べ替え、その全部を
    /// メニューの値として比べていた。2 冊以上のときは「複数」を表す 2 つだけを返す(小さい順で固定 ―― 値が揺れないように)。
    var selectedBookPaths: [String] {
        let prefix = SmartGridItem.bookIDPrefix
        var found: [String] = []
        for id in selection.ids where id.hasPrefix(prefix) {
            let path = String(id.dropFirst(prefix.count))
            found.append(path)
            found.sort()
            if found.count > 2 { found.removeLast() }
        }
        return found
    }

    /// 選んでいる枠(並びの順)。
    var selectedItems: [SmartGridItem] {
        selection.isEmpty ? [] : gridItems.filter { selection.contains($0.id) }
    }

    func click(_ id: String, _ click: SmartGridSelection.Click) {
        selection.click(id, click, order: gridItemIDs)
    }

    /// 矢印キー。動いた先(画面がスクロールする相手)を返す。
    func moveSelection(_ direction: GridKeyboardNavigation.Direction, extending: Bool, columns: Int) -> String? {
        selection.move(direction, extending: extending, order: gridItemIDs, columns: columns)
    }

    /// Home / End / PageUp / PageDown。動いた先を返す。
    func jumpSelection(_ jump: SmartGridSelection.Jump, extending: Bool) -> String? {
        selection.jump(jump, extending: extending, order: gridItemIDs)
    }

    func selectAll() {
        selection.selectAll(order: gridItemIDs)
    }

    /// リスト表示が選んだもの(束の中の本の行も入る ―― その識別子は並び `gridItems` には無いので、並びが変わると外れる)。
    func setSelection(_ ids: Set<String>, cursor: String?) {
        guard ids != selection.ids || cursor != selection.cursor else { return }
        selection.set(ids, cursor: cursor)
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection.clear()
    }

    /// type-select(2026-09-22)。打った文字を表示名の先頭に持つ枠を 1 つだけ選び、その枠を返す(画面がスクロールする)。
    /// 見つからなければ選択は変えず nil。規則はファイルブラウザのアイコン表示と同じ(`FileBrowserState.typeSelect`):
    /// 前の入力から `FileBrowserState.typeSelectResetInterval` 過ぎたら打ち直し、1 文字(同じ文字の連打を含む)は今の選択の
    /// 次から一巡、2 文字以上は先頭から。大小文字・濁点の有無・全角半角は区別しない。表示名は表紙の下の 1 行目
    /// (本は題 ―― 著者でまとめた一覧では著者名、束は束の名前)。
    func typeSelect(_ characters: String, now: Date = Date()) -> String? {
        guard !characters.isEmpty else { return nil }
        if let last = typeSelectLastInput, now.timeIntervalSince(last) < FileBrowserState.typeSelectResetInterval {
            typeSelectBuffer += characters
        } else {
            typeSelectBuffer = characters
        }
        typeSelectLastInput = now
        guard !gridItems.isEmpty else { return nil }
        let buffer = typeSelectBuffer
        let isSingleCharacter = Set(buffer.lowercased()).count == 1
        let needle = isSingleCharacter ? String(buffer.prefix(1)) : buffer
        let current = selection.cursor.flatMap { cursor in
            selection.contains(cursor) ? gridItems.firstIndex(where: { $0.id == cursor }) : nil
        } ?? gridItems.firstIndex(where: { selection.contains($0.id) })
        let start = isSingleCharacter ? ((current ?? -1) + 1) : 0
        let options: String.CompareOptions = [.anchored, .caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let authorOnly = grouping == .author && openedGroup == nil
        for offset in 0..<gridItems.count {
            let item = gridItems[(start + offset) % gridItems.count]
            guard displayName(of: item, authorOnly: authorOnly).range(of: needle, options: options) != nil else { continue }
            selection.select(item.id)
            return item.id
        }
        return nil
    }

    /// 表紙の下の 1 行目(`SmartBookCell` / `SmartGroupCell` と同じ決め方)。
    private func displayName(of item: SmartGridItem, authorOnly: Bool) -> String {
        switch item {
        case .book(let book):
            if authorOnly, let author = book.metadata.authors.first, !author.isEmpty { return author }
            return book.displayTitle
        case .group(_, let name, _):
            return name
        }
    }

    /// 本を開くときに渡す一覧の並び(`BookSequence`。2026-09-22、利用者の指示)。**いま見えている並び**(絞り込み・検索・
    /// 並べ替えの後)で、束はその位置に中の本を巻の順に並べて展開する(束の中を開いているときはその中の本だけ)。
    /// 「次の本へ」「前の本へ」がこの並びをたどる。`book` が並びに無ければ nil(同じフォルダの本をたどる従来の動き)。
    func sequence(opening book: SmartBook) -> BookSequence? {
        var paths: [String] = []
        for item in gridItems {
            switch item {
            case .book(let book): paths.append(book.id)
            case .group(_, _, let books): paths.append(contentsOf: books.map(\.id))
            }
        }
        guard let position = paths.firstIndex(of: book.id) else { return nil }
        return BookSequence(entries: paths.map { .file(path: $0) }, position: position)
    }

    /// 右クリックした枠を相手にする操作の対象。**右クリックした枠が選択に入っていれば選択の全部、入っていなければ
    /// その枠だけ**(Finder と同じ。コレクションの中のカバーの `contextTargets` とも同じ)。
    func contextTargets(for item: SmartGridItem) -> [SmartGridItem] {
        guard selection.contains(item.id), selection.ids.count > 1 else { return [item] }
        return selectedItems
    }

    func resizeCovers(byMagnification magnification: CGFloat) {
        coverSize = Self.coverSizeRange.clamping(coverSize * magnification)
    }

    /// 利用者が絞り込み・並べ方を変えた(並べ直しと、一覧を先頭へ戻す合図)。
    private func narrowingChanged() {
        pendingScrollReset = true
        setNeedsRecompute()
    }

    private func setNeedsRecompute() {
        guard recomputeTask == nil else { return }
        recomputeTask = Task { @MainActor [weak self] in
            self?.recomputeTask = nil
            self?.recompute()
        }
    }

    /// 検索に当てる、この本の文字列(ファイル名と主な欄を畳んで改行でつないだもの)。
    private static func searchHaystack(of book: SmartBook) -> String {
        LibrarySearchQuery.normalized(
            ([book.fileName, book.metadata.title] + book.metadata.authors
                + [book.metadata.series, book.metadata.genre, book.metadata.source, book.metadata.event,
                   book.metadata.info])
                .filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// 著者の設定を当てた本の一覧(`usesFirstAuthorOnly`)。OFF なら渡されたまま、ON なら著者が 2 人以上の本だけ先頭の 1 人にする。
    nonisolated static func applyingAuthorSetting(_ books: [SmartBook], firstAuthorOnly: Bool) -> [SmartBook] {
        guard firstAuthorOnly else { return books }
        return books.map { book in
            guard book.metadata.authors.count > 1 else { return book }
            var copy = book
            copy.metadata.authors = Array(book.metadata.authors.prefix(1))
            return copy
        }
    }

    /// 並べる本を作り直す(型コメントの順に絞る)。
    func recompute(now: Date = Date()) {
        let minute = Int((now.timeIntervalSinceReferenceDate / 60).rounded(.down))
        var current: [SmartBook]
        if let cached = shelfResults, cached.minute == minute, cached.selectedShelfID == selectedShelfID {
            current = cached.selectedBooks
        } else {
            var counts: [UUID?: Int] = [nil: books.count]
            for shelf in shelves { counts[shelf.id] = books.lazy.filter { shelf.conditions.matches($0, now: now) }.count }
            if counts != shelfCounts { shelfCounts = counts }
            current = selectedShelf.map { shelf in books.filter { shelf.conditions.matches($0, now: now) } } ?? books
            shelfResults = (minute, selectedShelfID, counts, current)
        }
        shelfBookCount = current.count
        if quickFilter.isActive { current = current.filter { quickFilter.matches($0, now: now) } }
        let selection = facetSelection
        var values: [SmartFacetField: [(value: SmartFacetValue, count: Int)]] = [:]
        for field in facetFields {
            values[field] = SmartFacets.counts(current.filter { selection.matches($0, except: field) }, field: field)
        }
        facetValues = values
        if selection.isActive { current = current.filter { selection.matches($0) } }
        if let query = LibrarySearchQuery(searchText) {
            var haystacks = searchHaystacks ?? [:]
            current = current.filter { book in
                let haystack = haystacks[book.id] ?? Self.searchHaystack(of: book)
                haystacks[book.id] = haystack
                return query.matches(normalized: haystack)
            }
            searchHaystacks = haystacks
        }
        visibleBooks = SmartSort.sorted(current, by: sortKey, ascending: sortAscending)
        if let openedGroup {
            // 束の中は シリーズ → 巻 の順(束の並びと同じ)。絞り込みで 1 冊も残らなければ空のまま(戻れば束の一覧)。
            gridItems = SmartSort.sorted(visibleBooks.filter { grouping.key(of: $0) == openedGroup },
                                         by: .series, ascending: true).map(SmartGridItem.book)
        } else {
            gridItems = grouping.grouped(visibleBooks)
        }
        if pendingScrollReset {
            pendingScrollReset = false
            scrollResetSerial += 1
        }
        let order = gridItemIDs
        // 上の `selection` は絞り込みの写し(ローカル)。グリッドの選択は self の。リスト表示では束の中の本の行も選べるので、
        // その識別子も残す。
        var known = order
        for case .group(_, _, let books) in gridItems { known.append(contentsOf: books.map { SmartGridItem.book($0).id }) }
        self.selection.prune(to: known)
        if let pending = pendingSelectionID {
            pendingSelectionID = nil
            if order.contains(pending) {
                self.selection.select(pending)
                revealSerial += 1
                revealRequest = RevealRequest(id: pending, serial: revealSerial)
            }
        }
    }
}

private extension ClosedRange where Bound == CGFloat {
    func clamping(_ value: CGFloat) -> CGFloat { Swift.min(upperBound, Swift.max(lowerBound, value)) }
}

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
            setNeedsRecompute()
        }
    }
    @Published var quickFilter = SmartQuickFilter() { didSet { if quickFilter != oldValue { setNeedsRecompute() } } }
    /// ブラウザのボタンの並び(同じ欄は 1 度だけ)。
    @Published var facetFields: [SmartFacetField] {
        didSet {
            guard facetFields != oldValue else { return }
            defaults.set(facetFields.map(\.rawValue), forKey: Keys.facetFields)
            // 並びから消えた欄の選択は外す(見えない所で絞り込みが残らないように)。
            for field in SmartFacetField.allCases where !facetFields.contains(field) { facetSelection[field] = [] }
            setNeedsRecompute()
        }
    }
    @Published var facetSelection = SmartFacetSelection() {
        didSet { if facetSelection != oldValue { setNeedsRecompute() } }
    }
    @Published var searchText = "" { didSet { if searchText != oldValue { setNeedsRecompute() } } }
    @Published var sortKey: SmartSortKey {
        didSet {
            guard sortKey != oldValue else { return }
            defaults.set(sortKey.rawValue, forKey: Keys.sortKey)
            setNeedsRecompute()
        }
    }
    @Published var sortAscending: Bool {
        didSet {
            guard sortAscending != oldValue else { return }
            defaults.set(sortAscending, forKey: Keys.sortAscending)
            setNeedsRecompute()
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
            setNeedsRecompute()
        }
    }
    /// 開いている束の名前(シリーズ名 / 著者名。nil なら束の一覧)。束を押すと入り、見出しの戻るで出る。保存しない。
    @Published var openedGroup: String? {
        didSet {
            guard openedGroup != oldValue else { return }
            // 束から出たら、出てきた束を選んでおく(Finder で上のフォルダへ戻ったときと同じ。矢印キーの続きがそこから)。
            if let oldValue, openedGroup == nil {
                pendingSelectionID = SmartGridItem.groupID(grouping, name: oldValue)
            }
            setNeedsRecompute()
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
    private var revealSerial = 0

    private let defaults: UserDefaults
    private var books: [SmartBook] = []
    private var shelves: [SmartShelf] = []
    private var recomputeTask: Task<Void, Never>?

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
        coverSize = (defaults.object(forKey: Keys.coverSize) as? Double)
            .map { Self.coverSizeRange.clamping(CGFloat($0)) } ?? Self.defaultCoverSize
        sidebarWidth = (defaults.object(forKey: Keys.sidebarWidth) as? Double)
            .map { Self.sidebarWidthRange.clamping(CGFloat($0)) } ?? Self.defaultSidebarWidth
    }

    /// 本の一覧・保存したスマートシェルフが変わった(画面から渡す)。
    func update(books: [SmartBook], shelves: [SmartShelf]) {
        self.books = books
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

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection.clear()
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

    private func setNeedsRecompute() {
        guard recomputeTask == nil else { return }
        recomputeTask = Task { @MainActor [weak self] in
            self?.recomputeTask = nil
            self?.recompute()
        }
    }

    /// 並べる本を作り直す(型コメントの順に絞る)。
    func recompute(now: Date = Date()) {
        var counts: [UUID?: Int] = [nil: books.count]
        for shelf in shelves { counts[shelf.id] = books.lazy.filter { shelf.conditions.matches($0, now: now) }.count }
        shelfCounts = counts

        var current = selectedShelf.map { shelf in books.filter { shelf.conditions.matches($0, now: now) } } ?? books
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
            current = current.filter { book in
                let haystack = LibrarySearchQuery.normalized(
                    ([book.fileName, book.metadata.title] + book.metadata.authors
                        + [book.metadata.series, book.metadata.genre, book.metadata.source, book.metadata.event,
                           book.metadata.info])
                        .filter { !$0.isEmpty }.joined(separator: "\n"))
                return query.matches(normalized: haystack)
            }
        }
        visibleBooks = SmartSort.sorted(current, by: sortKey, ascending: sortAscending)
        if let openedGroup {
            // 束の中は シリーズ → 巻 の順(束の並びと同じ)。絞り込みで 1 冊も残らなければ空のまま(戻れば束の一覧)。
            gridItems = SmartSort.sorted(visibleBooks.filter { grouping.key(of: $0) == openedGroup },
                                         by: .series, ascending: true).map(SmartGridItem.book)
        } else {
            gridItems = grouping.grouped(visibleBooks)
        }
        let order = gridItemIDs
        // 上の `selection` は絞り込みの写し(ローカル)。グリッドの選択は self の。
        self.selection.prune(to: order)
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

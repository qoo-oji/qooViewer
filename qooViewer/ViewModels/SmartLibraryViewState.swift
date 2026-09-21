import Combine
import Foundation

/// スマートライブラリの画面の状態(ウインドウごと。画面が持つ)。2026-09-21。
///
/// 選んだスマートシェルフ・左ペインの絞り込み・ブラウザ列・検索・並べ替えを持ち、それらと本の一覧から
/// **並べる本を作り置きする**(`visibleBooks`)。描き直しのたびに数千冊を絞り込み直さないため(メタデータの編集ウインドウの
/// 一覧と同じ考え方)。作り直すのは中身が変わったときだけで、同じランループの中の変更は 1 回にまとめる。
///
/// 絞り込みの重なり方は StackNest と同じ: **スマートシェルフ → 絞り込み → ブラウザ列(左から順に) → 検索**。すべて AND。
/// ブラウザ列の値の候補は、それより上(左)の列で選んだ値で絞られる。
///
/// 保存するもの(次に開いたときも同じ所から): 選んだスマートシェルフ・ブラウザ列の欄・並べ替え・表紙の大きさ・左ペインの幅。
/// 絞り込み・ブラウザ列で選んだ値・検索は保存しない(StackNest のフィルタと同じく、いまの作業のための一時的なもの)。
@MainActor
final class SmartLibraryViewState: ObservableObject {
    private enum Keys {
        static let selectedShelf = "qooViewer.smartLibrary.selectedShelf"
        static let facetFields = "qooViewer.smartLibrary.facetFields"
        static let sortKey = "qooViewer.smartLibrary.sortKey"
        static let sortAscending = "qooViewer.smartLibrary.sortAscending"
        static let coverSize = "qooViewer.smartLibrary.coverSize"
        static let sidebarWidth = "qooViewer.smartLibrary.sidebarWidth"
    }

    static let coverSizeRange: ClosedRange<CGFloat> = 80...300
    static let defaultCoverSize: CGFloat = 130
    static let sidebarWidthRange: ClosedRange<CGFloat> = 200...460
    static let defaultSidebarWidth: CGFloat = 270
    /// ブラウザ列の数。
    static let facetCount = 3

    /// 選んだスマートシェルフ(nil は「すべての本」)。
    @Published var selectedShelfID: UUID? {
        didSet {
            guard selectedShelfID != oldValue else { return }
            defaults.set(selectedShelfID?.uuidString, forKey: Keys.selectedShelf)
            // 棚が変わったら、ブラウザ列で選んだ値は外す(前の棚に無い値で空になるため)。
            facetSelections = Array(repeating: nil, count: Self.facetCount)
            setNeedsRecompute()
        }
    }
    @Published var quickFilter = SmartQuickFilter() { didSet { if quickFilter != oldValue { setNeedsRecompute() } } }
    @Published var facetFields: [SmartFacetField] {
        didSet {
            guard facetFields != oldValue else { return }
            defaults.set(facetFields.map(\.rawValue), forKey: Keys.facetFields)
            // 欄を替えた列と、それより右の列の選択は外す(StackNest と同じ)。
            if let changed = zip(facetFields, oldValue).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                for index in changed..<facetSelections.count { facetSelections[index] = nil }
            }
            setNeedsRecompute()
        }
    }
    @Published var facetSelections: [SmartFacetValue?] {
        didSet { if facetSelections != oldValue { setNeedsRecompute() } }
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
    @Published var coverSize: CGFloat { didSet { defaults.set(Double(coverSize), forKey: Keys.coverSize) } }
    @Published var sidebarWidth: CGFloat { didSet { defaults.set(Double(sidebarWidth), forKey: Keys.sidebarWidth) } }

    // MARK: 作り置き

    /// 棚の条件に合う本(絞り込み・ブラウザ列・検索の前)。
    @Published private(set) var shelfBookCount = 0
    /// 並べる本(すべての絞り込みと並べ替えの後)。
    @Published private(set) var visibleBooks: [SmartBook] = []
    /// ブラウザ列ごとの、値と冊数。
    @Published private(set) var facetValues: [[(value: SmartFacetValue, count: Int)]] = []
    /// スマートシェルフごとの冊数(左ペインに出す)。nil のキーは「すべての本」。
    @Published private(set) var shelfCounts: [UUID?: Int] = [:]

    private let defaults: UserDefaults
    private var books: [SmartBook] = []
    private var shelves: [SmartShelf] = []
    private var recomputeTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedShelfID = defaults.string(forKey: Keys.selectedShelf).flatMap(UUID.init(uuidString:))
        let storedFields = (defaults.stringArray(forKey: Keys.facetFields) ?? []).compactMap(SmartFacetField.init(rawValue:))
        facetFields = storedFields.count == Self.facetCount ? storedFields : [.genre, .authors, .series]
        facetSelections = Array(repeating: nil, count: Self.facetCount)
        sortKey = SmartSortKey(rawValue: defaults.string(forKey: Keys.sortKey) ?? "") ?? .title
        sortAscending = defaults.object(forKey: Keys.sortAscending) as? Bool ?? true
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
        setNeedsRecompute()
    }

    var selectedShelf: SmartShelf? { selectedShelfID.flatMap { id in shelves.first { $0.id == id } } }

    /// 絞り込み・ブラウザ列・検索のどれかが効いているか(「すべて外す」を出すか)。
    var isNarrowing: Bool {
        quickFilter.isActive || facetSelections.contains { $0 != nil } || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func clearNarrowing() {
        quickFilter = SmartQuickFilter()
        facetSelections = Array(repeating: nil, count: Self.facetCount)
        searchText = ""
    }

    /// ブラウザ列の値を選ぶ(nil は「すべて」)。右の列の選択は外す(左の選び直しで候補が変わるため)。
    func selectFacet(_ value: SmartFacetValue?, at index: Int) {
        var next = facetSelections
        next[index] = value
        for right in (index + 1)..<Self.facetCount { next[right] = nil }
        facetSelections = next
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
        var columns: [[(value: SmartFacetValue, count: Int)]] = []
        for (index, field) in facetFields.enumerated() {
            columns.append(SmartFacets.counts(current, field: field))
            if let selection = facetSelections[safe: index] ?? nil {
                current = current.filter { SmartFacets.matches($0, field: field, value: selection) }
            }
        }
        facetValues = columns
        if let query = LibrarySearchQuery(searchText) {
            current = current.filter { book in
                let haystack = LibrarySearchQuery.normalized(
                    ([book.fileName, book.metadata.title] + book.metadata.authors
                        + [book.metadata.series, book.metadata.genre, book.metadata.source, book.metadata.event,
                           book.metadata.info] + book.collectionNames)
                        .filter { !$0.isEmpty }.joined(separator: "\n"))
                return query.matches(normalized: haystack)
            }
        }
        visibleBooks = SmartSort.sorted(current, by: sortKey, ascending: sortAscending)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension ClosedRange where Bound == CGFloat {
    func clamping(_ value: CGFloat) -> CGFloat { Swift.min(upperBound, Swift.max(lowerBound, value)) }
}

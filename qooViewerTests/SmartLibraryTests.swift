import Foundation
import QooMetaKit
import QooMetaRules
import Testing

@testable import qooViewer

/// スマートライブラリ(2026-09-21)の値の計算: 条件・絞り込み・ブラウザ列・並べ替え・保存・フォルダの探し方・本の組み立て。
/// 本の名前はすべて架空(docs/02「個人情報の流出防止」)。
@MainActor
struct SmartLibraryTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func book(_ path: String, title: String = "", authors: [String] = [], genre: String = "", series: String = "",
                      volume: String = "", kind: SmartBookKind? = nil, added: Double? = nil, read: Double? = nil,
                      progress: Double? = nil, registered: Bool = false) -> SmartBook {
        let name = (path as NSString).lastPathComponent
        var book = SmartBook(id: path, fileName: name, kind: kind ?? SmartBookKind(fileName: name, isFolder: false),
                             metadata: BookMetadataValues(title: title, authors: authors, genre: genre, series: series,
                                                          volume: volume),
                             isRegistered: registered)
        book.dateAdded = added.map { now.addingTimeInterval(-$0 * 86_400) }
        book.lastRead = read.map { now.addingTimeInterval(-$0 * 86_400) }
        book.progress = progress
        return book
    }

    // MARK: 条件

    @Test("「すべて」は全部の条件、「いずれか」はどれか 1 つ")
    func matchAllAndAny() {
        let target = book("/b/1.zip", title: "月の庭", genre: "架空ジャンル")
        var conditions = SmartShelfConditions(match: .all, rules: [
            SmartShelfRule(field: .genre, op: .equals, text: "架空ジャンル"),
            SmartShelfRule(field: .title, op: .contains, text: "星"),
        ])
        #expect(!conditions.matches(target, now: now))
        conditions.match = .any
        #expect(conditions.matches(target, now: now))
    }

    @Test("空の「含む」は数えない(全部に当たらないように)、条件が無ければ全部")
    func emptyTextRulesAreIgnored() {
        let rule = SmartShelfRule(field: .title, op: .contains, text: "  ")
        #expect(!rule.isUsable)
        let conditions = SmartShelfConditions(match: .all, rules: [rule])
        #expect(conditions.matches(book("/b/x.zip"), now: now))
    }

    @Test("文字の比べ方は大文字小文字・全角半角を区別しない")
    func textComparisonIsFolded() {
        let target = book("/b/1.zip", authors: ["ＡＢＣ工房"])
        #expect(SmartShelfRule(field: .authors, op: .beginsWith, text: "abc").matches(target, now: now))
        #expect(SmartShelfRule(field: .authors, op: .equals, text: "abc工房").matches(target, now: now))
        #expect(!SmartShelfRule(field: .authors, op: .notContains, text: "工房").matches(target, now: now))
    }

    @Test("日付は「N 日以内」「N 日より前」、一度も読んでいない本は「より前」に入る")
    func dayRules() {
        let recent = book("/b/1.zip", added: 3, read: 1)
        let old = book("/b/2.zip", added: 100)
        let within = SmartShelfRule(field: .dateAdded, op: .within, number: 30)
        #expect(within.matches(recent, now: now))
        #expect(!within.matches(old, now: now))
        let notRecentlyRead = SmartShelfRule(field: .lastRead, op: .olderThan, number: 30)
        #expect(notRecentlyRead.matches(old, now: now))
        #expect(!notRecentlyRead.matches(recent, now: now))
    }

    @Test("読んだかどうか・種類・登録の有無")
    func choiceAndFlagRules() {
        let finished = book("/b/1.pdf", read: 1, progress: 1)
        let reading = book("/b/2.cbz", read: 1, progress: 0.3, registered: true)
        let unread = book("/b/3.rar")
        let rule = SmartShelfRule(field: .readState, op: .is, text: SmartReadState.finished.rawValue)
        #expect(rule.matches(finished, now: now))
        #expect(!rule.matches(reading, now: now))
        #expect(unread.readState == .unread)
        // 見開きの最後の画面(先のページは 90%)で閉じても、最後のページが写っていれば読み終えた。
        var lastSpread = book("/b/4.zip", read: 1, progress: 0.9)
        #expect(lastSpread.readState == .reading)
        lastSpread.isAtLastPage = true
        #expect(lastSpread.readState == .finished)
        #expect(SmartShelfRule(field: .kind, op: .is, text: SmartBookKind.rar.rawValue).matches(unread, now: now))
    }

    @Test("条件は JSON を往復する")
    func conditionsRoundTrip() throws {
        let shelf = SmartShelf(name: "架空の棚", conditions: SmartShelfConditions(match: .any, rules: [
            SmartShelfRule(field: .genre, op: .contains, text: "架空"),
            SmartShelfRule(field: .dateAdded, op: .within, number: 7),
        ]))
        let decoded = try JSONDecoder().decode(SmartShelf.self, from: JSONEncoder().encode(shelf))
        #expect(decoded == shelf)
    }

    // MARK: 絞り込み・ブラウザ列・並べ替え

    @Test("ブラウザは値ごとの冊数と「(空)」を返し、候補はほかの欄の選択で絞られる(自分の欄の選択では減らない)")
    func facetsCountFromOtherSelections() async throws {
        let suite = TestDefaultsPool.checkout()
        let defaults = suite.defaults
        defer { suite.release() }
        let state = SmartLibraryViewState(defaults: defaults)
        #expect(state.facetFields == [.genre, .authors, .series])
        state.update(books: [
            book("/b/1.zip", authors: ["著者A"], genre: "ジャンル1"),
            book("/b/2.zip", authors: ["著者B"], genre: "ジャンル1"),
            book("/b/3.zip", authors: ["著者C"], genre: "ジャンル2"),
            book("/b/4.zip", authors: ["著者C"]),
        ], shelves: [])
        state.recompute(now: now)
        #expect(state.facetValues[.genre]?.map(\.count) == [2, 1, 1])
        #expect(state.facetValues[.genre]?.last?.value == .empty)

        state.toggleFacet(.value("ジャンル1"), in: .genre)
        state.recompute(now: now)
        #expect(state.facetValues[.authors]?.map(\.value) == [.value("著者A"), .value("著者B")])
        // 自分の欄の候補は、自分の選択では減らない(2 つ目を選べる)。
        #expect(state.facetValues[.genre]?.count == 3)
        #expect(state.visibleBooks.map(\.id) == ["/b/1.zip", "/b/2.zip"])
    }

    @Test("同じ欄の中は「いずれか」、欄どうしは「すべて」")
    func facetSelectionsCombine() {
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let state = SmartLibraryViewState(defaults: suite.defaults)
        state.update(books: [
            book("/b/1.zip", authors: ["著者A"], genre: "ジャンル1"),
            book("/b/2.zip", authors: ["著者B"], genre: "ジャンル2"),
            book("/b/3.zip", authors: ["著者A"], genre: "ジャンル3"),
        ], shelves: [])
        state.toggleFacet(.value("ジャンル1"), in: .genre)
        state.toggleFacet(.value("ジャンル2"), in: .genre)
        state.recompute(now: now)
        #expect(state.visibleBooks.map(\.id) == ["/b/1.zip", "/b/2.zip"])
        state.toggleFacet(.value("著者A"), in: .authors)
        state.recompute(now: now)
        #expect(state.visibleBooks.map(\.id) == ["/b/1.zip"])
        // ボタンを外すと、その欄の選択も外れる。
        state.removeFacetField(.authors)
        #expect(state.facetSelection[.authors].isEmpty)
        #expect(SmartLibraryViewState(defaults: suite.defaults).facetFields == [.genre, .series])
    }

    @Test("シリーズでまとめると、2 冊以上のシリーズは最初に出てきた位置で束になり、束の中は巻の順。開くとその中の本だけ")
    func groupsBySeries() {
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let state = SmartLibraryViewState(defaults: suite.defaults)
        state.sortKey = .fileName
        state.update(books: [
            book("/b/a.zip", series: "月の庭", volume: "2"),
            book("/b/b.zip", title: "星の庭"),
            book("/b/c.zip", series: "月の庭", volume: "1"),
            book("/b/d.zip", series: "一冊だけ", volume: "1"),
        ], shelves: [])
        state.groupsBySeries = true
        state.recompute(now: now)
        #expect(state.gridItems.map(\.id) == ["series|月の庭", "book|/b/b.zip", "book|/b/d.zip"])
        if case .series(_, let books) = state.gridItems.first {
            #expect(books.map(\.id) == ["/b/c.zip", "/b/a.zip"])
        } else {
            Issue.record("先頭が束になっていない")
        }
        state.openedSeries = "月の庭"
        state.recompute(now: now)
        #expect(state.gridItems.map(\.id) == ["book|/b/c.zip", "book|/b/a.zip"])
        // まとめるのをやめると、開いていたシリーズからも出る。設定は保存される。
        state.groupsBySeries = false
        #expect(state.openedSeries == nil)
        state.groupsBySeries = true
        #expect(SmartLibraryViewState(defaults: suite.defaults).groupsBySeries)
    }

    @Test("シリーズで並べると シリーズ名 → 巻 の順")
    func sortBySeriesThenVolume() {
        let books = [
            book("/b/c.zip", series: "月の庭", volume: "10"),
            book("/b/a.zip", series: "月の庭", volume: "2"),
            book("/b/b.zip", title: "星の庭"),
        ]
        let sorted = SmartSort.sorted(books, by: .series, ascending: true)
        #expect(sorted.map(\.id) == ["/b/a.zip", "/b/c.zip", "/b/b.zip"])
    }

    @Test("日付の無い本は、向きに関わらず後ろ")
    func booksWithoutDatesGoLast() {
        let books = [book("/b/none.zip"), book("/b/old.zip", read: 10), book("/b/new.zip", read: 1)]
        #expect(SmartSort.sorted(books, by: .lastRead, ascending: false).map(\.id) == ["/b/new.zip", "/b/old.zip", "/b/none.zip"])
        #expect(SmartSort.sorted(books, by: .lastRead, ascending: true).map(\.id) == ["/b/old.zip", "/b/new.zip", "/b/none.zip"])
    }

    // MARK: 保存

    @Test("スマートシェルフ・対象フォルダ・ピン留めは保存され、フォルダはアプリ自身の移動に付いていく")
    func storePersistsAndRelocates() throws {
        let suite = TestDefaultsPool.checkout()
        let defaults = suite.defaults
        defer { suite.release() }
        let store = SmartLibraryStore(defaults: defaults)
        let shelf = store.add(SmartShelf(name: "架空の棚", conditions: SmartShelfConditions()))
        store.addFolder(URL(fileURLWithPath: "/架空/本棚"))
        store.togglePin(.value("架空ジャンル"), in: .genre)
        store.togglePin(.empty, in: .authors)
        store.togglePin(.empty, in: .authors)

        var change = FileSystemChange()
        change.relocations = [.init(from: URL(fileURLWithPath: "/架空"), to: URL(fileURLWithPath: "/別の架空"))]
        #expect(store.relocate(using: change))

        let reopened = SmartLibraryStore(defaults: defaults)
        #expect(reopened.shelves.map(\.id) == [shelf.id])
        #expect(reopened.folders.map(\.path) == ["/別の架空/本棚"])
        #expect(reopened.pins == [.genre: [.value("架空ジャンル")]])
    }

    // MARK: フォルダを探す

    @Test("フォルダの中の書庫・PDF と画像フォルダを本として数え、画像フォルダの中のフォルダは数えない")
    func scannerFindsBooks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qooViewerTests.smartScan.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("棚/画像の本/章1"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("棚/本1.cbz"))
        try Data().write(to: root.appendingPathComponent("棚/本2.pdf"))
        try Data().write(to: root.appendingPathComponent("棚/メモ.txt"))
        try Data().write(to: root.appendingPathComponent("棚/画像の本/001.jpg"))
        try Data().write(to: root.appendingPathComponent("棚/画像の本/章1/002.jpg"))

        let result = SmartLibraryScanner.scan(roots: [root.path], protectedPrefixes: [])
        let names = Set(result.books.map { ($0.path as NSString).lastPathComponent })
        #expect(names == ["本1.cbz", "本2.pdf", "画像の本"])
        #expect(result.books.first { $0.path.hasSuffix("画像の本") }?.isFolder == true)
    }

    // MARK: 本の組み立て

    @Test("未登録の本は qooMeta の提案、登録済みの本は DB の値で並び、読書位置と追加日を持つ")
    func assembleUsesMetadataAndReading() {
        var snapshot = SmartLibraryCatalog.Snapshot()
        snapshot.registered = ["/棚/手で直した本.zip": BookMetadataValues(title: "手で直した題", genre: "登録したジャンル")]
        snapshot.readings = ["/棚/[架空工房] 月の庭 1.zip": .init(updatedAt: now, progress: 0.5)]
        var scan = SmartLibraryScanner.Result()
        scan.books = [
            .init(path: "/棚/[架空工房] 月の庭 1.zip", isFolder: false, creationDate: nil, modificationDate: nil, fileSize: 1,
                  addedDate: now),
            .init(path: "/棚/[架空工房] 月の庭 2.zip", isFolder: false, creationDate: now, modificationDate: nil, fileSize: 1),
            .init(path: "/棚/手で直した本.zip", isFolder: false, creationDate: nil, modificationDate: nil, fileSize: 1),
        ]

        let books = SmartLibraryCatalog.assemble(snapshot: snapshot, scan: scan, rules: .builtin)
        #expect(books.count == 3)
        let first = books.first { $0.id == "/棚/[架空工房] 月の庭 1.zip" }
        #expect(first?.metadata.series == "月の庭")
        #expect(first?.readState == .reading)
        #expect(first?.dateAdded == now)
        // 追加日が取れないボリュームでは作成日。
        #expect(books.first { $0.id == "/棚/[架空工房] 月の庭 2.zip" }?.dateAdded == now)
        let registered = books.first { $0.id == "/棚/手で直した本.zip" }
        #expect(registered?.isRegistered == true)
        #expect(registered?.metadata.genre == "登録したジャンル")
    }
}

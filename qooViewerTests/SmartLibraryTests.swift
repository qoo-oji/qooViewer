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
        state.grouping = .series
        state.recompute(now: now)
        #expect(state.gridItems.map(\.id) == ["series|月の庭", "book|/b/b.zip", "book|/b/d.zip"])
        if case .group(_, _, let books) = state.gridItems.first {
            #expect(books.map(\.id) == ["/b/c.zip", "/b/a.zip"])
        } else {
            Issue.record("先頭が束になっていない")
        }
        state.openedGroup = "月の庭"
        state.recompute(now: now)
        #expect(state.gridItems.map(\.id) == ["book|/b/c.zip", "book|/b/a.zip"])
        // まとめるのをやめると、開いていたシリーズからも出る。設定は保存される。
        state.grouping = .none
        #expect(state.openedGroup == nil)
        state.grouping = .series
        #expect(SmartLibraryViewState(defaults: suite.defaults).grouping == .series)
    }

    @Test("著者でまとめると筆頭の著者で束になり、束の中はシリーズ → 巻の順")
    func groupsByAuthor() {
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let state = SmartLibraryViewState(defaults: suite.defaults)
        state.sortKey = .fileName
        state.update(books: [
            book("/b/a.zip", authors: ["著者A", "著者B"], series: "星の庭", volume: "1"),
            book("/b/b.zip", authors: ["著者B"]),
            book("/b/c.zip", authors: ["著者A"], series: "月の庭", volume: "2"),
            book("/b/d.zip", authors: ["著者A"], series: "月の庭", volume: "1"),
        ], shelves: [])
        state.grouping = .author
        state.recompute(now: now)
        // 著者B は筆頭では 1 冊だけなので束にならない(合作の本は筆頭の著者の束へ)。
        #expect(state.gridItems.map(\.id) == ["author|著者A", "book|/b/b.zip"])
        state.openedGroup = "著者A"
        state.recompute(now: now)
        #expect(state.gridItems.map(\.id) == ["book|/b/d.zip", "book|/b/c.zip", "book|/b/a.zip"])
    }

    @Test("「シリーズでまとめる」の ON/OFF だった頃の保存値は、シリーズで束ねる設定として読む")
    func legacyGroupingIsRead() {
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        suite.defaults.set(true, forKey: "qooViewer.smartLibrary.groupsBySeries")
        #expect(SmartLibraryViewState(defaults: suite.defaults).grouping == .series)
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

    // MARK: 選択(2026-09-22)

    @Test("クリックは 1 つ、⌘ で足す/外す、⇧ で起点からの範囲(前の範囲は置き換える)")
    func gridSelectionClicks() {
        let order = ["a", "b", "c", "d", "e"]
        var selection = SmartGridSelection()
        selection.click("b", .plain, order: order)
        #expect(selection.ids == ["b"])
        selection.click("d", .extend, order: order)
        #expect(selection.ids == ["b", "c", "d"])
        selection.click("a", .extend, order: order)
        #expect(selection.ids == ["a", "b"])
        selection.click("e", .toggle, order: order)
        #expect(selection.ids == ["a", "b", "e"])
        selection.click("e", .toggle, order: order)
        #expect(selection.ids == ["a", "b"])
        // 起点を外した後の ⇧ はふつうのクリック。
        selection.click("c", .plain, order: order)
        selection.click("c", .toggle, order: order)
        selection.click("d", .extend, order: order)
        #expect(selection.ids == ["d"])
    }

    @Test("矢印キーは未選択なら先頭、⇧ で起点からの範囲。Home / End / PageUp / PageDown")
    func gridSelectionKeys() {
        let order = (0..<10).map { "i\($0)" }
        var selection = SmartGridSelection()
        #expect(selection.move(.down, extending: false, order: order, columns: 3) == "i0")
        #expect(selection.move(.down, extending: false, order: order, columns: 3) == "i3")
        #expect(selection.move(.right, extending: true, order: order, columns: 3) == "i4")
        #expect(selection.move(.down, extending: true, order: order, columns: 3) == "i7")
        #expect(selection.ids == Set(["i3", "i4", "i5", "i6", "i7"]))
        // ⇧ を離して動くと、動いた先だけ。
        #expect(selection.move(.left, extending: false, order: order, columns: 3) == "i6")
        #expect(selection.ids == ["i6"])
        #expect(selection.jump(.pageDown(6), extending: false, order: order) == "i9")
        #expect(selection.jump(.pageUp(6), extending: true, order: order) == "i3")
        #expect(selection.ids == Set(["i3", "i4", "i5", "i6", "i7", "i8", "i9"]))
        #expect(selection.jump(.first, extending: false, order: order) == "i0")
        #expect(selection.jump(.last, extending: false, order: order) == "i9")
        var empty = SmartGridSelection()
        #expect(empty.move(.up, extending: false, order: [], columns: 3) == nil)
        var all = SmartGridSelection()
        all.selectAll(order: order)
        #expect(all.ids.count == 10)
        #expect(all.move(.right, extending: false, order: order, columns: 3) == "i1")
    }

    @Test("並びから消えた枠を選択から外す(束の中の本は残す)。束から出るとその束を選ぶ。右クリックの相手は選択に入っているときだけ全部")
    func gridSelectionFollowsTheGrid() {
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let state = SmartLibraryViewState(defaults: suite.defaults)
        state.sortKey = .fileName
        state.update(books: [
            book("/b/a.zip", series: "月の庭", volume: "1"),
            book("/b/b.zip", title: "星の庭"),
            book("/b/c.zip", series: "月の庭", volume: "2"),
        ], shelves: [])
        state.click("book|/b/a.zip", .plain)
        state.click("book|/b/b.zip", .toggle)
        #expect(state.selectedItems.map(\.id) == ["book|/b/a.zip", "book|/b/b.zip"])
        let unselected = state.gridItems[2]
        #expect(state.contextTargets(for: unselected).map(\.id) == [unselected.id])
        #expect(state.contextTargets(for: state.gridItems[0]).count == 2)

        state.grouping = .series
        state.recompute(now: now)
        #expect(state.selectedItems.map(\.id) == ["book|/b/b.zip"])
        // 束の中の本は、束に入っても選ばれたまま(リスト表示では束の中の行も選べるので、束へ隠れただけでは外さない)。
        state.openedGroup = "月の庭"
        state.recompute(now: now)
        #expect(state.selectedItems.map(\.id) == ["book|/b/a.zip"])
        state.clearSelection()
        state.openedGroup = nil
        state.recompute(now: now)
        #expect(state.selectedItems.map(\.id) == ["series|月の庭"])
        #expect(state.revealRequest?.id == "series|月の庭")
    }

    @Test("type-select: 1 文字は今の選択の次から一巡、2 文字以上は先頭から。束は名前で当たる")
    func typeSelectFindsByDisplayName() {
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let state = SmartLibraryViewState(defaults: suite.defaults)
        state.sortKey = .fileName
        state.update(books: [
            book("/b/1.zip", title: "Alpha"),
            book("/b/2.zip", title: "Beta"),
            book("/b/3.zip", title: "Alps"),
        ], shelves: [])
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(state.typeSelect("a", now: t0) == "book|/b/1.zip")
        #expect(state.typeSelect("a", now: t0.addingTimeInterval(2)) == "book|/b/3.zip")
        #expect(state.typeSelect("a", now: t0.addingTimeInterval(4)) == "book|/b/1.zip")
        // 続けて打った 2 文字は先頭から探す。
        #expect(state.typeSelect("b", now: t0.addingTimeInterval(6)) == "book|/b/2.zip")
        #expect(state.typeSelect("ALP", now: t0.addingTimeInterval(8)) == "book|/b/1.zip")
        #expect(state.typeSelect("s", now: t0.addingTimeInterval(8.2)) == "book|/b/3.zip")
        #expect(state.typeSelect("zz", now: t0.addingTimeInterval(10)) == nil)
        #expect(state.selectedItems.map(\.id) == ["book|/b/3.zip"])
    }

    @Test("絞り込み・並べ替えを変えると先頭へ戻す合図が進み、本の一覧が届いただけでは進まない")
    func narrowingResetsTheScroll() {
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let state = SmartLibraryViewState(defaults: suite.defaults)
        let books = [book("/b/1.zip", title: "月の庭"), book("/b/2.zip", title: "星の庭")]
        state.update(books: books, shelves: [])
        let start = state.scrollResetSerial
        state.update(books: books, shelves: [])
        #expect(state.scrollResetSerial == start)
        state.searchText = "星"
        state.recompute(now: now)
        #expect(state.scrollResetSerial == start + 1)
        state.sortAscending.toggle()
        state.recompute(now: now)
        #expect(state.scrollResetSerial == start + 2)
    }

    @Test("本を開くときの並びは見えている並びで、束はその位置に中の本を巻の順に展開する")
    func sequenceFlattensGroups() throws {
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let state = SmartLibraryViewState(defaults: suite.defaults)
        state.sortKey = .fileName
        let second = book("/b/b.zip", title: "星の庭")
        state.update(books: [
            book("/b/a.zip", series: "月の庭", volume: "2"),
            second,
            book("/b/c.zip", series: "月の庭", volume: "1"),
        ], shelves: [])
        state.grouping = .series
        state.recompute(now: now)
        let sequence = try #require(state.sequence(opening: second))
        #expect(sequence.entries.map(\.path) == ["/b/c.zip", "/b/a.zip", "/b/b.zip"])
        #expect(sequence.position == 2)
        #expect(sequence.candidatePositions(forward: false) == [1, 0])
        #expect(sequence.candidatePositions(forward: true).isEmpty)
    }

    @Test("一覧の並びは開く要求に載って JSON を往復する(新しいウインドウへ渡る)")
    func sequenceTravelsWithTheRequest() throws {
        let entries: [BookSequence.Entry] = [.file(path: "/b/1.zip"), .collectionItem(id: UUID(), path: "/b/2.zip")]
        let request = BookOpenRequest(URL(fileURLWithPath: "/b/2.zip"),
                                      sequence: BookSequence(entries: entries, position: 1))
        let decoded = try JSONDecoder().decode(BookOpenRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
        #expect(BookSequence(entries: entries, position: 2) == nil)
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
        // 表紙の鍵は、ファイルブラウザが項目から作る鍵と同じ(保存した一覧から引いても同じキャッシュに当たる)。
        let mountTable = MountTable.current()
        for book in result.books {
            let url = URL(fileURLWithPath: book.path, isDirectory: book.isFolder)
            #expect(book.thumbnailKey == FileBrowserThumbnailKey.of(url, mountTable: mountTable))
            #expect(book.thumbnailKey != nil)
        }
    }

    @Test("章ごとに画像フォルダを分けた本は 1 冊、本のフォルダの中の書庫は別の本にしない(ほかの所と同じ決まり。2026-09-22 の監査)")
    func scannerFollowsTheAppWideBookRules() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qooViewerTests.smartScanRules.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for folder in ["棚/章の本/章1", "棚/章の本/章2", "棚/混ざった本"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("棚/章の本/章1/001.jpg"))
        try Data().write(to: root.appendingPathComponent("棚/章の本/章2/001.jpg"))
        try Data().write(to: root.appendingPathComponent("棚/混ざった本/000.jpg"))
        try Data().write(to: root.appendingPathComponent("棚/混ざった本/01.cbz"))
        try Data().write(to: root.appendingPathComponent("棚/単独.cbz"))

        let result = SmartLibraryScanner.scan(roots: [root.path], protectedPrefixes: [])
        let names = Set(result.books.map { ($0.path as NSString).lastPathComponent })
        #expect(names == ["章の本", "混ざった本", "単独.cbz"])
    }

    // MARK: 本の組み立て

    @Test("ロックしていない本は qooMeta の読み、ロックした本は DB の値で並び、読書位置と追加日を持つ")
    func assembleUsesMetadataAndReading() {
        var snapshot = SmartLibraryCatalog.Snapshot()
        snapshot.records = [
            "/棚/手で直した本.zip": BookMetadataRecord(
                values: BookMetadataValues(title: "手で直した題", genre: "登録したジャンル"), isLocked: true),
            // ロックしていない行は、DB の値ではなく読み直した値(DB へもこの値を書く)。
            "/棚/[架空工房] 月の庭 2.zip": BookMetadataRecord(values: BookMetadataValues(title: "古い読み"), isLocked: false),
        ]
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
        #expect(books.first { $0.id == "/棚/[架空工房] 月の庭 2.zip" }?.metadata.title == "月の庭 2")
        let registered = books.first { $0.id == "/棚/手で直した本.zip" }
        #expect(registered?.isRegistered == true)
        #expect(registered?.metadata.genre == "登録したジャンル")
    }

    // MARK: 速さ(前回の一覧・変わった本だけ読む)

    @Test("qooMeta へ渡す本の差: 足した・登録を変えた本は upsert、無くなった本は remove、同じ本は渡さない")
    func changesOnlyCarryWhatChanged() {
        let rules = CompiledRules.builtin
        let before = SmartLibraryCatalog.inputs(for: ["/棚/a.zip", "/棚/b.zip", "/棚/c.zip"], records: [:],
                                                reusing: [:], rules: rules)
        let after = SmartLibraryCatalog.inputs(
            for: ["/棚/a.zip", "/棚/b.zip", "/棚/d.zip"],
            records: ["/棚/b.zip": BookMetadataRecord(values: BookMetadataValues(title: "登録した題"), isLocked: true)],
            reusing: before.byID, rules: rules)
        let changes = SmartLibraryCatalog.changes(from: before.byID, to: after)
        let upserted = changes.compactMap { if case .upsert(let input) = $0 { input.id } else { nil } }
        let removed = changes.compactMap { if case .remove(let id) = $0 { id } else { nil } }
        #expect(upserted == ["/棚/b.zip", "/棚/d.zip"])
        #expect(removed == ["/棚/c.zip"])
        #expect(SmartLibraryCatalog.changes(from: after.byID, to: after).isEmpty)
    }

    @Test("索引に変わった本だけ渡した結果は、全冊を読み直した結果と同じ")
    func incrementalProposalsMatchAFullRead() async throws {
        let rules = CompiledRules.builtin
        let first = SmartLibraryCatalog.inputs(
            for: ["/棚/[架空工房] 月の庭 1.zip", "/棚/[架空工房] 月の庭 2.zip", "/棚/星の本.zip"],
            records: [:], reusing: [:], rules: rules)
        let index = ProposalIndex(rules: rules, dictionaries: MetadataRulesStore.dictionaries)
        try await index.load(first.ordered)
        var proposals = Dictionary(await index.snapshot().proposals.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let second = SmartLibraryCatalog.inputs(
            for: ["/棚/[架空工房] 月の庭 1.zip", "/棚/[架空工房] 月の庭 2.zip", "/棚/[架空工房] 月の庭 3.zip"],
            records: [:], reusing: first.byID, rules: rules)
        let delta = try await index.apply(SmartLibraryCatalog.changes(from: first.byID, to: second))
        for proposal in delta.changed { proposals[proposal.id] = proposal }
        for id in delta.removedBooks { proposals[id] = nil }
        let full = proposeSync(second.ordered, rules: rules, dictionaries: MetadataRulesStore.dictionaries)
        #expect(Set(proposals.keys) == Set(full.proposals.map(\.id)))
        for proposal in full.proposals {
            #expect(proposals[proposal.id]?.metadata == proposal.metadata)
        }
    }

    @Test("保存した前回の一覧は JSON を往復する")
    func cachedCatalogRoundTrips() throws {
        var sample = book("/棚/本.zip", title: "題", authors: ["著者"], series: "月の庭", volume: "1", read: 1, progress: 0.5)
        sample.isAtLastPage = true
        sample.thumbnailKey = FileBrowserThumbnailKey(volume: "vol", inode: 42, modified: 1_000_000_123, size: 99)
        let cached = SmartLibraryCatalog.CachedCatalog(roots: ["/棚"], books: [sample], isTruncated: false)
        let decoded = try JSONDecoder().decode(SmartLibraryCatalog.CachedCatalog.self, from: JSONEncoder().encode(cached))
        #expect(decoded.books == [sample])
        #expect(decoded.roots == ["/棚"])
    }

    // MARK: 環境設定で OFF にしたとき

    /// 条件が満たされるまで待つ(本当の集め直しは FileIO と qooMeta を通るので、回数ではなく状態で待つ)。
    /// 上限を長めにしてあるのは、全体を流すと同じテストホストで並列に走るほかのテストに押されて、単独では 1 秒の集め直しが
    /// 12 秒ほどかかったため(止まってはいない。2026-09-22 に実測)。
    private func wait(_ timeout: Duration = .seconds(60), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test("OFF にすると集めた一覧・索引を手放し、入り口は何もしない。ON へ戻して画面を出せば集め直す")
    func featureSwitchStopsAndRestarts() async throws {
        let library = try InMemoryLibrary(label: "smart-switch")
        defer { library.close() }
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qooViewerTests.smartSwitch.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["[架空工房] 月の庭 1.zip", "[架空工房] 月の庭 2.zip", "星の本.pdf"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let store = SmartLibraryStore(defaults: suite.defaults)
        store.addFolder(root)
        let catalog = SmartLibraryCatalog(metadataStore: library.metadata, store: store, rulesStore: library.metadataRules,
                                          modelContext: library.context)

        catalog.activate()
        #expect(await wait { catalog.hasLoaded })
        #expect(catalog.books.count == 3)
        #expect(await catalog.folderBookIDs().count == 3)

        catalog.setFeatureEnabled(false)
        #expect(catalog.books.isEmpty)
        #expect(!catalog.hasLoaded && !catalog.isLoading)
        #expect(await catalog.folderBookIDs().isEmpty)
        // 画面が消える(deactivate)・出ようとしても(activate)、何も始まらない。
        catalog.deactivate()
        catalog.activate()
        try await Task.sleep(for: .milliseconds(300))
        #expect(catalog.books.isEmpty && !catalog.isLoading)

        catalog.setFeatureEnabled(true)
        catalog.activate()
        #expect(await wait { catalog.hasLoaded })
        #expect(catalog.books.count == 3)
        catalog.deactivate()
    }

    @Test("対象フォルダのボリュームが繋がっていない回は、保存した一覧を空で上書きしない(2026-09-22 の監査)")
    func anUnmountedRootDoesNotOverwriteTheSavedList() async throws {
        let library = try InMemoryLibrary(label: "smart-unmounted")
        defer { library.close() }
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let temporary = try TemporaryDirectory("smart-unmounted")
        let cacheURL = temporary.file("catalog.json")
        try Data("saved".utf8).write(to: cacheURL)
        let store = SmartLibraryStore(defaults: suite.defaults)
        store.addFolder(URL(fileURLWithPath: "/Volumes/qooViewer-no-such-volume-\(UUID().uuidString)", isDirectory: true))
        let catalog = SmartLibraryCatalog(metadataStore: library.metadata, store: store, rulesStore: library.metadataRules,
                                          modelContext: library.context, cacheURL: cacheURL)

        catalog.activate()
        #expect(await wait { catalog.hasLoaded })
        try await Task.sleep(for: .milliseconds(200))
        #expect(try Data(contentsOf: cacheURL) == Data("saved".utf8))
        catalog.deactivate()
    }

    @Test("集め直しの最中に OFF にすると、その集め直しは一覧を出さない")
    func switchingOffMidRebuildPublishesNothing() async throws {
        let library = try InMemoryLibrary(label: "smart-switch-mid")
        defer { library.close() }
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qooViewerTests.smartSwitchMid.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<200 { try Data().write(to: root.appendingPathComponent("架空の本 \(index).zip")) }
        let store = SmartLibraryStore(defaults: suite.defaults)
        store.addFolder(root)
        let catalog = SmartLibraryCatalog(metadataStore: library.metadata, store: store, rulesStore: library.metadataRules,
                                          modelContext: library.context)
        catalog.activate()
        #expect(catalog.isLoading)
        catalog.setFeatureEnabled(false)
        try await Task.sleep(for: .seconds(1))
        #expect(catalog.books.isEmpty)
        #expect(!catalog.hasLoaded)
    }
}

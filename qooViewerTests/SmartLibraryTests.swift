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
                             sources: [.library],
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
        #expect(SmartShelfRule(field: .kind, op: .is, text: SmartBookKind.rar.rawValue).matches(unread, now: now))
        #expect(SmartShelfRule(field: .registered, op: .is).matches(reading, now: now))
        #expect(SmartShelfRule(field: .registered, op: .isNot).matches(unread, now: now))
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

    @Test("ブラウザ列は値ごとの冊数と「(空)」を返し、左の列で選んだ値で右の列の候補が絞られる")
    func facetsCascade() async throws {
        let suite = TestDefaultsPool.checkout()
        let defaults = suite.defaults
        defer { suite.release() }
        let state = SmartLibraryViewState(defaults: defaults)
        state.facetFields = [.genre, .authors, .series]
        state.update(books: [
            book("/b/1.zip", authors: ["著者A"], genre: "ジャンル1"),
            book("/b/2.zip", authors: ["著者B"], genre: "ジャンル1"),
            book("/b/3.zip", authors: ["著者C"], genre: "ジャンル2"),
            book("/b/4.zip", authors: ["著者C"]),
        ], shelves: [])
        state.recompute(now: now)
        #expect(state.facetValues[0].map(\.count) == [2, 1, 1])
        #expect(state.facetValues[0].last?.value == .empty)

        state.selectFacet(.value("ジャンル1"), at: 0)
        state.recompute(now: now)
        #expect(state.facetValues[1].map(\.value) == [.value("著者A"), .value("著者B")])
        #expect(state.visibleBooks.map(\.id) == ["/b/1.zip", "/b/2.zip"])
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

    @Test("スマートシェルフ・対象フォルダ・対象の設定は保存され、フォルダはアプリ自身の移動に付いていく")
    func storePersistsAndRelocates() throws {
        let suite = TestDefaultsPool.checkout()
        let defaults = suite.defaults
        defer { suite.release() }
        let store = SmartLibraryStore(defaults: defaults)
        let shelf = store.add(SmartShelf(name: "架空の棚", conditions: SmartShelfConditions()))
        store.addFolder(URL(fileURLWithPath: "/架空/本棚"))
        store.sources.favoriteLocations = false

        var change = FileSystemChange()
        change.relocations = [.init(from: URL(fileURLWithPath: "/架空"), to: URL(fileURLWithPath: "/別の架空"))]
        #expect(store.relocate(using: change))

        let reopened = SmartLibraryStore(defaults: defaults)
        #expect(reopened.shelves.map(\.id) == [shelf.id])
        #expect(reopened.folders.map(\.path) == ["/別の架空/本棚"])
        #expect(!reopened.sources.favoriteLocations)
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

    @Test("未登録の本は qooMeta の提案、登録済みの本は DB の値で並び、ライブラリとフォルダの同じ本は 1 冊になる")
    func assembleMergesSourcesAndMetadata() {
        var snapshot = SmartLibraryCatalog.Snapshot()
        let itemID = UUID()
        snapshot.libraryBooks = [.init(bookID: "/棚/[架空工房] 月の庭 1.zip", itemID: itemID, addedAt: now,
                                       libraryName: "架空ライブラリ", collectionName: "架空コレクション",
                                       created: nil, modified: nil)]
        snapshot.registered = ["/棚/手で直した本.zip": BookMetadataValues(title: "手で直した題", genre: "登録したジャンル")]
        snapshot.readings = ["/棚/[架空工房] 月の庭 1.zip": .init(updatedAt: now, progress: 0.5)]
        var scan = SmartLibraryScanner.Result()
        scan.books = [
            .init(path: "/棚/[架空工房] 月の庭 1.zip", isFolder: false, creationDate: nil, modificationDate: nil, fileSize: 1),
            .init(path: "/棚/[架空工房] 月の庭 2.zip", isFolder: false, creationDate: nil, modificationDate: nil, fileSize: 1),
            .init(path: "/棚/手で直した本.zip", isFolder: false, creationDate: nil, modificationDate: nil, fileSize: 1),
        ]

        let books = SmartLibraryCatalog.assemble(snapshot: snapshot, scan: scan, rules: .builtin)
        #expect(books.count == 3)
        let first = books.first { $0.id == "/棚/[架空工房] 月の庭 1.zip" }
        #expect(first?.sources == [.library, .folders])
        #expect(first?.collectionItemID == itemID)
        #expect(first?.metadata.series == "月の庭")
        #expect(first?.readState == .reading)
        let registered = books.first { $0.id == "/棚/手で直した本.zip" }
        #expect(registered?.isRegistered == true)
        #expect(registered?.metadata.genre == "登録したジャンル")
    }
}

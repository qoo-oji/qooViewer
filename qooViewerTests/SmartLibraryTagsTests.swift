import Foundation
import Testing

@testable import qooViewer

/// スマートライブラリのタグの絞り込み(2026-11-03)。タグは探したときと「タグを更新」のときだけ読む(利用者の決定)。
@MainActor
struct SmartLibraryTagsTests {
    private func book(_ name: String, tags: [String]?) -> SmartBook {
        var book = SmartBook(id: "/架空/\(name)", fileName: name, kind: .zip, metadata: BookMetadataValues(), isRegistered: false)
        book.tags = tags
        return book
    }

    private func setTags(_ raw: [String], at url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
        let result = data.withUnsafeBytes { setxattr(url.path, FinderTagStore.tagsAttribute, $0.baseAddress, $0.count, 0, 0) }
        #expect(result == 0)
    }

    @Test("条件: 複数のタグのどれかに当たる。空はタグ無しだけで、読めていない本はどの条件にも合わない")
    func rules() {
        let red = book("a.zip", tags: ["レッド", "自作"])
        let none = book("b.zip", tags: [])
        let unknown = book("c.zip", tags: nil)
        func matches(_ op: SmartOperator, _ text: String = "", _ book: SmartBook) -> Bool {
            SmartShelfRule(field: .tags, op: op, text: text).matches(book, now: Date())
        }
        #expect(matches(.equals, "自作", red))
        #expect(matches(.contains, "レッ", red))
        #expect(!matches(.equals, "自", red))
        #expect(!matches(.notContains, "レッ", red))
        #expect(matches(.notContains, "レッ", none))
        #expect(matches(.isEmpty, "", none))
        #expect(!matches(.isEmpty, "", red))
        #expect(matches(.isNotEmpty, "", red))
        for op in [SmartOperator.equals, .contains, .notContains, .notEquals, .isEmpty, .isNotEmpty] {
            #expect(!matches(op, "レッド", unknown), "\(op)")
        }
        #expect(SmartField.tags.valueType == .text)
    }

    @Test("「すべて」で 2 つのタグを両方持つ本だけに絞れる")
    func allOfTwoTags() {
        let both = book("a.zip", tags: ["A", "B"])
        let one = book("b.zip", tags: ["A"])
        let conditions = SmartShelfConditions(match: .all, rules: [
            SmartShelfRule(field: .tags, op: .equals, text: "A"), SmartShelfRule(field: .tags, op: .equals, text: "B"),
        ])
        #expect(conditions.matches(both))
        #expect(!conditions.matches(one))
    }

    @Test("メタデータのボタン: タグごとの冊数。(空)はタグ無しの本だけで、読めていない本は数えない")
    func facets() {
        let books = [book("a.zip", tags: ["A", "B"]), book("b.zip", tags: ["A"]), book("c.zip", tags: []), book("d.zip", tags: nil)]
        let counts = SmartFacets.counts(books, field: .tags)
        #expect(counts.map(\.value) == [.value("A"), .value("B"), .empty])
        #expect(counts.map(\.count) == [2, 1, 1])
        #expect(SmartFacets.matches(books[2], field: .tags, value: .empty))
        #expect(!SmartFacets.matches(books[3], field: .tags, value: .empty))
        #expect(!SmartFacets.matches(books[3], field: .tags, value: .value("A")))
        #expect(SmartFacetField.allCases.contains(.tags))
    }

    @Test("タグのボタンは「タグ」の節に固定: メタデータの節の足す・替えるの相手にせず、並びが変わっても選択は残る")
    func tagFacetIsStandalone() {
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        // 前の試作の設定に入っていても並びには戻さない。
        suite.defaults.set(["genre", "tags"], forKey: "qooViewer.smartLibrary.browserFields")
        let state = SmartLibraryViewState(defaults: suite.defaults)
        #expect(state.facetFields == [.genre])
        #expect(!SmartFacetField.arrangeable.contains(.tags))
        state.addFacetField(.tags)
        #expect(state.facetFields == [.genre])
        state.replaceFacetField(.genre, with: .tags)
        #expect(state.facetFields == [.genre])

        state.update(books: [book("a.zip", tags: ["A"]), book("b.zip", tags: [])], shelves: [])
        // 並びに無くても冊数は数える。
        #expect(state.facetValues[.tags]?.map(\.value) == [.value("A"), .empty])
        state.toggleFacet(.value("A"), in: .tags)
        state.addFacetField(.authors)
        state.removeFacetField(.authors)
        #expect(state.facetSelection[.tags] == [.value("A")])
        state.clearNarrowing()
        #expect(state.facetSelection[.tags].isEmpty)
    }

    @Test("タグを持たない前の版の catalog.json も読める(読めていない本になる)")
    func oldCatalogDecodes() throws {
        let encoded = try JSONEncoder().encode(book("a.zip", tags: nil))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "tags")
        let decoded = try JSONDecoder().decode(SmartBook.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.tags == nil)
        let tagged = try JSONDecoder().decode(SmartBook.self, from: JSONEncoder().encode(book("b.zip", tags: ["A"])))
        #expect(tagged.tags == ["A"])
    }

    @Test("探すときにタグを読む(書庫・フォルダの本・タグ無し。ネットワークボリュームも同じ扱い)")
    func scannerReadsTags() throws {
        for isRemote in [false, true] {
            let folder = try TemporaryDirectory("smart-tags")
            if isRemote { NetworkVolumeReading.treatAsRemoteForTesting(folder.url) }
            defer { NetworkVolumeReading.endTreatingAsRemoteForTesting(folder.url) }
            let tagged = folder.url.appendingPathComponent("tagged.zip")
            let plain = folder.url.appendingPathComponent("plain.zip")
            let label = folder.url.appendingPathComponent("label.zip")
            let bookFolder = folder.url.appendingPathComponent("folder-book", isDirectory: true)
            try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: false)
            for file in [tagged, plain, label, bookFolder.appendingPathComponent("001.png")] {
                try Data().write(to: file)
            }
            try setTags(["レッド\n6", "自作"], at: tagged)
            try setTags(["フォルダ\n2"], at: bookFolder)
            var info = [UInt8](repeating: 0, count: 32)
            info[9] = 4 << 1
            #expect(setxattr(label.path, FinderTagStore.finderInfoAttribute, info, 32, 0, 0) == 0)

            let result = SmartLibraryScanner.scan(roots: [folder.url.path], protectedPrefixes: [])
            let byName = Dictionary(uniqueKeysWithValues: result.books.map { (($0.path as NSString).lastPathComponent, $0.tags) })
            #expect(byName["tagged.zip"] == .some(["レッド", "自作"]))
            #expect(byName["plain.zip"] == .some([]))
            #expect(byName["folder-book"] == .some(["フォルダ"]))
            // 古いラベルだけの本もインスペクタと同じくタグとして読む(名前は OS の言語なので色の数だけ見る)。
            #expect(byName["label.zip"]??.count == 1)
        }
    }

    @Test("タグは自動では更新しない。「タグを更新」で読み直し、探し直さない")
    func refreshIsExplicit() async throws {
        let library = try InMemoryLibrary(label: "smart-tags")
        defer { library.close() }
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let folder = try TemporaryDirectory("smart-tags")
        let temporary = try TemporaryDirectory("smart-tags-cache")
        let file = folder.url.appendingPathComponent("架空の本.zip")
        try Data().write(to: file)
        try setTags(["A"], at: file)
        let store = SmartLibraryStore(defaults: suite.defaults)
        store.addFolder(folder.url)
        let catalog = SmartLibraryCatalog(metadataStore: library.metadata, store: store, rulesStore: library.metadataRules,
                                          modelContext: library.context, cacheURL: temporary.file("catalog.json"))
        catalog.activate()
        #expect(await eventuallyHere { catalog.hasLoaded && catalog.books.count == 1 })
        #expect(catalog.books.first?.tags == ["A"])

        // アプリの外で変える。画面を出し直しても(探した結果を使う)古いまま。
        try setTags(["B"], at: file)
        let added = folder.url.appendingPathComponent("あとから足した本.zip")
        try Data().write(to: added)
        catalog.deactivate()
        catalog.activate()
        #expect(await eventuallyHere { !catalog.isLoading })
        #expect(catalog.books.first?.tags == ["A"])

        await catalog.refreshTags()?.value
        #expect(!catalog.isRefreshingTags)
        #expect(await eventuallyHere { !catalog.isLoading && catalog.books.first?.tags == ["B"] })
        // フォルダの中は探し直していない(足した本は並ばない)。
        #expect(catalog.books.count == 1)

        // 「本を探し直す」でもタグを読む。
        try setTags(["C"], at: file)
        catalog.reload()
        #expect(await eventuallyHere { catalog.books.count == 2 && catalog.books.contains { $0.tags == ["C"] } })
        catalog.deactivate()
    }

    @Test("タグの読みの取り消しは 1 冊ごとに見る(応答しない共有で読み続けない)")
    func readTagsChecksCancellationPerBook() {
        var books = (0..<5).map {
            SmartLibraryScanner.ScannedBook(path: "/架空/\($0).zip", isFolder: false, creationDate: nil, modificationDate: nil, fileSize: nil)
        }
        let scope = Cancellation()
        var reads = 0
        Cancellation.withScope(scope) {
            SmartLibraryScanner.readTags(of: &books) { _, _ in
                reads += 1
                if reads == 2 { scope.request() }
                return .tags([FinderTag(rawValue: "A")])
            }
        }
        #expect(reads == 2)
        #expect(books.map(\.tags) == [["A"], ["A"], nil, nil, nil])
    }

    /// 読みを止めておける箱(応答しない共有の代わり)。
    nonisolated private final class StuckReads: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let gates = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]

        func read() {
            let index = lock.withLock {
                calls += 1
                return calls - 1
            }
            gates[index].wait()
        }
        var callCount: Int { lock.withLock { calls } }
        func open(_ index: Int) { gates[index].signal() }
    }

    @Test("読み直し中に探し直しを頼むとボタンはすぐ戻る。古い読みが後で返っても、新しい読み直しの状態を壊さない")
    func invalidationReleasesTheRefreshButton() async throws {
        let library = try InMemoryLibrary(label: "smart-tags")
        defer { library.close() }
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let folder = try TemporaryDirectory("smart-tags")
        let temporary = try TemporaryDirectory("smart-tags-cache")
        let file = folder.url.appendingPathComponent("架空の本.zip")
        try Data().write(to: file)
        try setTags(["A"], at: file)
        let store = SmartLibraryStore(defaults: suite.defaults)
        store.addFolder(folder.url)
        let catalog = SmartLibraryCatalog(metadataStore: library.metadata, store: store, rulesStore: library.metadataRules,
                                          modelContext: library.context, cacheURL: temporary.file("catalog.json"))
        let stuck = StuckReads()
        catalog.tagRefreshReader = { _ in stuck.read() }
        catalog.activate()
        #expect(await eventuallyHere { catalog.hasLoaded && !catalog.isLoading && catalog.books.count == 1 })

        let firstRefresh = try #require(catalog.refreshTags())
        #expect(catalog.isRefreshingTags)
        #expect(await eventuallyHere { stuck.callCount == 1 })

        // 読みが返らなくても、探し直しを頼めばすぐ押せるようになる。
        try setTags(["B"], at: file)
        catalog.reload()
        #expect(!catalog.isRefreshingTags)
        // 探し直しが終わった(探した結果の新しいタグが並んだ)ところで次を押す。
        #expect(await eventuallyHere { !catalog.isLoading && catalog.books.first?.tags == ["B"] })

        let secondRefresh = try #require(catalog.refreshTags())
        #expect(await eventuallyHere { stuck.callCount == 2 })

        // 古い読みが返っても、走っている新しい読み直しの旗は落とさない。
        stuck.open(0)
        await firstRefresh.value
        #expect(catalog.isRefreshingTags)

        stuck.open(1)
        await secondRefresh.value
        #expect(!catalog.isRefreshingTags)
        catalog.deactivate()
    }

    @Test("探す前に押されたら探し直しになる。機能を切ると結果を捨てる")
    func refreshBeforeScanAndWhileOff() async throws {
        let library = try InMemoryLibrary(label: "smart-tags")
        defer { library.close() }
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let folder = try TemporaryDirectory("smart-tags")
        let temporary = try TemporaryDirectory("smart-tags-cache")
        let file = folder.url.appendingPathComponent("架空の本.zip")
        try Data().write(to: file)
        try setTags(["A"], at: file)
        let store = SmartLibraryStore(defaults: suite.defaults)
        store.addFolder(folder.url)
        let catalog = SmartLibraryCatalog(metadataStore: library.metadata, store: store, rulesStore: library.metadataRules,
                                          modelContext: library.context, cacheURL: temporary.file("catalog.json"))
        #expect(catalog.refreshTags() == nil)
        #expect(await eventuallyHere { catalog.hasLoaded && catalog.books.first?.tags == ["A"] })

        catalog.setFeatureEnabled(false)
        #expect(catalog.refreshTags() == nil)
        #expect(!catalog.isRefreshingTags)
        #expect(catalog.books.isEmpty)
    }
}

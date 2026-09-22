import Combine
import Foundation
import QooMetaKit
import Testing

@testable import qooViewer

/// メタデータ生成(`MetadataGenerator`)と、その母体の記録(`MetadataCorpusStore`)。2026-09-22、
/// docs/plans/metadata-generator-plan.md。ファイル名からメタデータを作って DB へ書くのはメタデータ生成だけで、機能は本の一覧を
/// 記録するだけ・画面は読むだけ、を確かめる。
///
/// 本の名前はすべて架空(docs/02「個人情報の流出防止」)。
@MainActor
struct MetadataGeneratorTests {
    private let first = "/書庫/[架空工房] 月の庭 1.zip"
    private let second = "/書庫/[架空工房] 月の庭 2.zip"
    private let third = "/書庫/[架空工房] 月の庭 3.zip"

    @Test("記録した本の一覧(スマートライブラリ・コレクション)は、確かめずに並べて登録する。機能の ON/OFF に関わらない")
    func recordedBooksAreRegistered() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let corpus = MetadataCorpusStore(url: nil)
        corpus.recordSmartLibraryScan(roots: ["/書庫"], bookIDs: [first, second], isTruncated: false)
        corpus.recordCollectionBooks([third])
        // 閉包から書き換える値は箱に入れる(捕まえた変数の書き換えは、古いコンパイラの CI だけ落ちる)。
        let probed = Box<[String]>([])
        let generator = MetadataGenerator(metadataStore: library.metadata, rulesStore: library.metadataRules,
                                          corpusStore: corpus, knownBooks: { [] },
                                          probe: { ids in probed.value += ids; return Set(ids) })
        await generator.update()

        #expect(generator.listedBookIDs == [first, second, third])
        #expect(library.metadata.registeredBookIDs == [first, second, third])
        #expect(library.metadata.record(forBookID: second)?.values.series == "月の庭")
        #expect(library.metadata.record(forBookID: second)?.isLocked == false)
        // スマートライブラリの本は探したときに確かめ済み。コレクションの本は確かめる。
        #expect(probed.value == [third])
    }

    @Test("行の無い知っている本は、記録どおりの場所にあると確かめられた本だけを並べる(1 冊につき 1 度だけ確かめる)")
    func knownBooksAreProbedOnce() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let probes = Box(0)
        let first = first
        let generator = MetadataGenerator(metadataStore: library.metadata, rulesStore: library.metadataRules,
                                          corpusStore: MetadataCorpusStore(url: nil), knownBooks: { [first, second] },
                                          probe: { ids in probes.value += 1; return Set(ids.filter { $0 == first }) })
        await generator.update()
        #expect(generator.listedBookIDs == [first])
        #expect(library.metadata.registeredBookIDs == [first])
        await generator.update()
        #expect(probes.value == 1)
        // 開いた本は確かめ済み。
        generator.noteBookOpened(second)
        await generator.update()
        #expect(generator.listedBookIDs == [first, second])
        #expect(probes.value == 1)
    }

    @Test("ロックした行・直した欄・ルールセットは書かない。ロックしていない行の値だけを読みに揃える")
    func writesOnlyUnlockedValues() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let edits = Confirmation.fields(ConfirmedFields([.info: ["直した付記"]]))
        library.metadata.upsertAll([
            .init(bookID: first, values: BookMetadataValues(title: "古い読み"),
                  state: BookMetadataRowState(isLocked: false, edits: edits, ruleSet: "選んだ規則")),
            .init(bookID: second, values: BookMetadataValues(title: "ロックした題"), state: .locked),
        ])
        await library.makeMetadataGenerator().update()

        let unlocked = try #require(library.metadata.record(forBookID: first))
        #expect(unlocked.values.title != "古い読み")
        #expect(unlocked.values.info == "直した付記")
        #expect(unlocked.edits == edits)
        #expect(unlocked.ruleSet == "選んだ規則")
        #expect(library.metadata.record(forBookID: second)?.values.title == "ロックした題")
        #expect(library.metadata.record(forBookID: second)?.isLocked == true)
    }

    @Test("対象外のフォルダの本は並べない。消した本は作り直さず、開き直す・窓を開き直すと登録し直す")
    func excludedAndDeletedBooks() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let generator = library.makeMetadataGenerator(books: [first, "/対象外/[架空工房] 星の本.zip"])
        library.metadataRules.addExcludedFolder(URL(fileURLWithPath: "/対象外"))
        await generator.update()
        #expect(generator.listedBookIDs == [first])

        library.metadata.delete(forBookID: first)
        await generator.update()
        #expect(library.metadata.record(forBookID: first) == nil)
        #expect(generator.listedBookIDs.isEmpty)

        generator.reregisterDeletedBooks()
        await generator.update()
        #expect(library.metadata.record(forBookID: first) != nil)
    }

    @Test("全冊を 1 つの索引で読む: 直した本の変化は、ほかの本の提案と DB の値にも届き、変わった本を知らせる")
    func anchorsReachOtherBooks() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let generator = library.makeMetadataGenerator(books: [first, second])
        await generator.update()
        let updates = Box<[MetadataGenerator.Update]>([])
        let subscription = generator.updates.sink { updates.value.append($0) }
        defer { subscription.cancel() }

        library.metadata.upsertAll([.init(bookID: first, values: try #require(library.metadata.record(forBookID: first)).values,
                                          state: BookMetadataRowState(isLocked: false,
                                                                      edits: .series(name: "庭の本", volume: nil)))])
        await generator.update()
        #expect(library.metadata.record(forBookID: first)?.values.series == "庭の本")
        #expect(library.metadata.record(forBookID: second)?.values.series == "庭の本")
        #expect(updates.value.last?.changedIDs.isSuperset(of: [first, second]) == true)
    }

    @Test("スマートライブラリは読むだけ: 探した本を記録し、メタデータの行は作らない")
    func smartLibraryOnlyRecords() async throws {
        let library = try InMemoryLibrary(label: "smart-records")
        defer { library.close() }
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qooViewerTests.smartRecords.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["[架空工房] 月の庭 1.zip", "[架空工房] 月の庭 2.zip"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let store = SmartLibraryStore(defaults: suite.defaults)
        store.addFolder(root)
        let corpus = MetadataCorpusStore(url: nil)
        let catalog = SmartLibraryCatalog(metadataStore: library.metadata, store: store, rulesStore: library.metadataRules,
                                          modelContext: library.context, corpusStore: corpus)
        catalog.activate()
        defer { catalog.deactivate() }
        #expect(await wait { catalog.hasLoaded })
        #expect(corpus.smartLibraryBookIDs.count == 2)
        #expect(library.metadata.registeredBookIDs.isEmpty)

        // メタデータ生成が記録を読んで登録する。
        await library.makeMetadataGenerator(corpus: corpus).update()
        #expect(library.metadata.registeredBookIDs.count == 2)
    }

    private func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

/// 閉包から書き換える値の箱。
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
struct MetadataCorpusStoreTests {
    @Test("対象フォルダごとに記録し、打ち切った回は足すだけ、外した対象フォルダは外す")
    func smartLibraryRecords() {
        let corpus = MetadataCorpusStore(url: nil)
        corpus.recordSmartLibraryScan(roots: ["/a", "/b"], bookIDs: ["/a/1.zip", "/a/2.zip", "/b/3.zip"], isTruncated: false)
        #expect(corpus.smartLibraryBookIDs == ["/a/1.zip", "/a/2.zip", "/b/3.zip"])
        corpus.recordSmartLibraryScan(roots: ["/a"], bookIDs: ["/a/4.zip"], isTruncated: true)
        #expect(corpus.smartLibraryBookIDs == ["/a/1.zip", "/a/2.zip", "/a/4.zip", "/b/3.zip"])
        corpus.recordSmartLibraryScan(roots: ["/a"], bookIDs: ["/a/4.zip"], isTruncated: false)
        #expect(corpus.smartLibraryBookIDs == ["/a/4.zip", "/b/3.zip"])
        corpus.keepSmartLibraryRoots(["/b"])
        #expect(corpus.smartLibraryBookIDs == ["/b/3.zip"])
    }

    @Test("アプリ自身の移動に付いていき、消えた本は外す。保存して読み直せる")
    func relocatesAndPersists() async throws {
        let temporary = try TemporaryDirectory("metadata-corpus")
        let url = temporary.url.appendingPathComponent("corpus.json")
        let corpus = MetadataCorpusStore(url: url)
        corpus.recordCollectionBooks(["/a/1.zip", "/a/2.zip"])
        corpus.recordSmartLibraryScan(roots: ["/b"], bookIDs: ["/b/3.zip"], isTruncated: false)
        var change = FileSystemChange(relocations: [.init(from: URL(fileURLWithPath: "/a/1.zip"),
                                                          to: URL(fileURLWithPath: "/a/10.zip")),
                                                    .init(from: URL(fileURLWithPath: "/b"), to: URL(fileURLWithPath: "/c"))])
        change.removed = [URL(fileURLWithPath: "/a/2.zip")]
        corpus.relocate(using: change)
        #expect(corpus.collectionBookIDs == ["/a/10.zip"])
        #expect(corpus.record.smartLibrary == ["/c": ["/c/3.zip"]])
        // 保存は画面の外で。書き終わるのを待って読み直す。
        var reloaded = MetadataCorpusStore(url: url).record
        for _ in 0..<100 where reloaded != corpus.record {
            try await Task.sleep(for: .milliseconds(20))
            reloaded = MetadataCorpusStore(url: url).record
        }
        #expect(reloaded == corpus.record)
    }
}

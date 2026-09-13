import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// 古いアプリが新しいストアを開くのを止める番人(App/StoreSchemaGuard.swift)。
///
/// 2026-09-11、1.55で足したコレクション表紙の3列が、1つ前のqooViewerで開いただけで中身ごと
/// 消えた。SwiftDataは古いモデルへの「移行」も黙って行うため、開く前に止めるしかない。
/// ここで押さえるのは、止める判定そのものと、判定の前提(世代の表とSwiftDataが書く指紋)。
@MainActor
struct StoreSchemaGuardTests {
    /// 1.54のスキーマの指紋。2026-09-11のバックアップ(1.54時代の実物のストア)のメタデータから
    /// 計算した値。
    static let fingerprint1_54 = "2ca9c83ed26e5d94111a305c4421e1730ada3a875a05c679be55c1cc3f166e21"

    @Test("いまのモデルの指紋が、世代の表の最新の行と一致する(モデルを変えたら世代を1つ足すこと)")
    func currentSchemaIsTheLatestRecordedGeneration() throws {
        let hashes = StoreSchemaGuard.currentHashes(for: QooViewerApp.modelTypes)
        try #require(!hashes.isEmpty)
        let fingerprint = StoreSchemaGuard.fingerprint(of: hashes)
        #expect(
            fingerprint == StoreSchemaGuard.generations[StoreSchemaGuard.currentGeneration],
            """
            モデル(QooViewerApp.modelTypes)が変わっています。StoreSchemaGuard.generations に \
            \(StoreSchemaGuard.currentGeneration + 1): "\(fingerprint)" を足してください \
            (既存の行は書き換えない)。
            """
        )
    }

    @Test("世代の表は1から隙間なく並び、同じ指紋が2度出てこない")
    func generationTableIsContiguous() {
        let keys = StoreSchemaGuard.generations.keys.sorted()
        #expect(keys == Array(1...StoreSchemaGuard.currentGeneration))
        #expect(Set(StoreSchemaGuard.generations.values).count == StoreSchemaGuard.generations.count)
        #expect(!StoreSchemaGuard.generations.values.contains(Self.fingerprint1_54))
    }

    @Test("SwiftDataがストアへ書く指紋と、番人がモデルから計算する指紋は同じもの")
    func swiftDataWritesTheHashesTheGuardComputes() throws {
        let store = try DisposableStore("hashes")
        do {
            let container = try store.openCurrent()
            container.mainContext.insert(BookLayoutSettings(bookID: "/books/a"))
            try container.mainContext.save()
        }
        let written = try #require(StoreSchemaGuard.storeHashes(at: store.url))
        #expect(written == StoreSchemaGuard.currentHashes(for: QooViewerApp.modelTypes))
    }

    // MARK: - 判定

    private let current: [String: Data] = ["A": Data([1]), "B": Data([2])]

    @Test("ストアが無い・いまのモデルと同じなら、開いてよい")
    func proceedsWithoutAStoreOrWithTheSameModel() {
        #expect(
            StoreSchemaGuard.verdict(storeHashes: nil, currentHashes: current, recordedGeneration: 9,
                                     currentGeneration: 1) == .proceed
        )
        // 新しいアプリが使った記録があっても、モデルが同じなら移行は起きない。
        #expect(
            StoreSchemaGuard.verdict(storeHashes: current, currentHashes: current, recordedGeneration: 9,
                                     currentGeneration: 1) == .proceed
        )
    }

    @Test("古いストアからの移行(記録が自分以下・記録なし)は、開いてよい")
    func proceedsWhenUpgradingAnOlderStore() {
        let older: [String: Data] = ["A": Data([0]), "B": Data([2])]
        #expect(
            StoreSchemaGuard.verdict(storeHashes: older, currentHashes: current, recordedGeneration: 1,
                                     currentGeneration: 2) == .proceed
        )
        #expect(
            StoreSchemaGuard.verdict(storeHashes: older, currentHashes: current, recordedGeneration: nil,
                                     currentGeneration: 2) == .proceed
        )
    }

    @Test("新しいアプリが使った記録があれば、止める")
    func stopsWhenANewerAppHasUsedTheStore() {
        let newer: [String: Data] = ["A": Data([3]), "B": Data([2])]
        #expect(
            StoreSchemaGuard.verdict(storeHashes: newer, currentHashes: current, recordedGeneration: 2,
                                     currentGeneration: 1) == .newerStore
        )
    }

    @Test("記録が消えていても、知らないエンティティを持つストアは止める")
    func stopsOnUnknownEntitiesEvenWithoutARecord() {
        let newer: [String: Data] = ["A": Data([1]), "B": Data([2]), "C": Data([4])]
        #expect(
            StoreSchemaGuard.verdict(storeHashes: newer, currentHashes: current, recordedGeneration: nil,
                                     currentGeneration: 1) == .newerStore
        )
    }

    @Test("記録は大きいほうを残す(古いアプリで開いても、新しいアプリが使った事実は消えない)")
    func recordKeepsTheHighestGeneration() {
        let suite = PreferencesSuite(label: "schema-generation")
        defer { withExtendedLifetime(suite) {} }
        #expect(StoreSchemaGuard.recordedGeneration(in: suite.defaults) == nil)
        StoreSchemaGuard.recordOpened(in: suite.defaults, generation: 3)
        StoreSchemaGuard.recordOpened(in: suite.defaults, generation: 2)
        #expect(StoreSchemaGuard.recordedGeneration(in: suite.defaults) == 3)
    }

    // MARK: - 実際のストアで(使い捨て)

    @Test("前提の確認: 古いモデルで開くと、SwiftDataは新しい列を黙って消す(だから開く前に止める)")
    func olderModelSilentlyDropsNewerColumns() throws {
        let store = try DisposableStore("downgrade")
        do {
            let container = try store.openCurrent()
            let settings = BookLayoutSettings(bookID: "/books/a")
            settings.coverPageKey = "001.jpg"
            settings.shelfCoverImageFileName = "cover.jpg"
            container.mainContext.insert(settings)
            try container.mainContext.save()
        }
        // 1.55と同じ世代を記録してある環境で、1.54のアプリがこのストアを開こうとした。
        #expect(
            StoreSchemaGuard.verdict(
                storeHashes: StoreSchemaGuard.storeHashes(at: store.url),
                currentHashes: StoreSchemaGuard.currentHashes(for: SchemaSnapshot_1_54.types),
                recordedGeneration: 1, currentGeneration: 0
            ) == .newerStore
        )
        // 止めずに開くと、エラーも出ずに開けてしまう。
        do {
            let container = try store.open(SchemaSnapshot_1_54.types)
            let rows = try container.mainContext.fetch(FetchDescriptor<SchemaSnapshot_1_54.BookLayoutSettings>())
            #expect(rows.first?.coverPageKey == "001.jpg")
        }
        // 新しいアプリで開き直すと、1.54が知らない列だけが空になっている。
        let container = try store.openCurrent()
        let row = try #require(try container.mainContext.fetch(FetchDescriptor<BookLayoutSettings>()).first)
        #expect(row.coverPageKey == "001.jpg")
        #expect(row.shelfCoverImageFileName == nil)
    }
}

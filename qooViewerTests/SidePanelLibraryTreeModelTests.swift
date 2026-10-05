import Combine
import Foundation
import Testing

@testable import qooViewer

/// サイドパネルのライブラリのツリーの値の写し(ViewModels/SidePanelLibraryTreeModel.swift。2026-10-04 の監査 §2-4・SP-9)。
///
/// - ツリーは CollectionStore を購読せず、この写しから描く。表紙の抽出のように行の見た目に関わらない変化では publish しない
/// - 本の行の名前は、ホームのカバーの下の文字の設定(「表示しない」なら並び順)に揃える
///
/// 本の名前はすべて架空(docs/02「個人情報の流出防止」)。
@MainActor
struct SidePanelLibraryTreeModelTests {
    private func makeBookFolder(_ temporary: TemporaryDirectory, named name: String) throws -> URL {
        let directory = temporary.file(name)
        try FixtureFolder.make(at: directory, pages: [.init("001.jpg", number: 1)])
        return directory
    }

    /// 写しの作り直しは 1 ランループ待ってから。時間ではなく条件で待つ。
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("条件が満たされない")
    }

    /// 後から来る知らせが無いことを確かめるために、少しだけ待つ(知らせからの作り直しは前の作り直しから間を空ける ――
    /// `minimumRebuildInterval`。2026-10-05 の監査 A7-1 ―― ので、その分も待つ)。
    private func settle() async {
        try? await Task.sleep(for: SidePanelLibraryTreeModel.minimumRebuildInterval + .milliseconds(50))
    }

    private func inputs(
        libraries: Set<UUID> = [], collections: Set<UUID> = [], itemSort: FavoritesSortOption = .nameAscending,
        caption: CollectionCoverCaptionStyle = .none
    ) -> SidePanelLibraryTreeModel.Inputs {
        SidePanelLibraryTreeModel.Inputs(
            expandedLibraryIDs: libraries, expandedCollectionIDs: collections,
            collectionSort: .nameAscending, itemSort: itemSort, captionStyle: caption,
            language: Locale(identifier: "en"), rulesHash: ""
        )
    }

    @Test("開いた行だけを並べ、表紙の状態の変化では publish しない。本が増えたら作り直す")
    func theTreeIsAValueCopyThatIgnoresCoverChanges() async throws {
        let library = try InMemoryLibrary(label: "side-panel-tree")
        defer { library.close() }
        let temporary = try TemporaryDirectory("side-panel-tree")
        let shelf = try #require(library.collections.libraries.first)
        let first = try #require(CollectionStore.makePendingItem(for: try makeBookFolder(temporary, named: "b-book")))
        let second = try #require(CollectionStore.makePendingItem(for: try makeBookFolder(temporary, named: "a-book")))
        let collection = try #require(library.collections.createCollection(name: "Shelf", in: shelf, items: [first, second]))

        let model = SidePanelLibraryTreeModel()
        model.attach(to: library.collections, inputs: inputs())
        // 閉じている間はライブラリの行だけ。
        #expect(model.rows.map(\.objectID) == [shelf.id])

        model.update(inputs(libraries: [shelf.id], collections: [collection.id]))
        #expect(model.rows.map(\.depth) == [0, 1, 2, 2])
        #expect(model.rows.suffix(2).map(\.title) == ["a-book", "b-book"])

        var publishCount = 0
        let subscription = model.objectWillChange.sink { publishCount += 1 }
        defer { subscription.cancel() }
        let item = try #require(collection.items.first)
        library.collections.setCoverStatus(.ready, aspect: 1.5, for: item)
        await settle()
        #expect(publishCount == 0, "表紙の状態だけで行を作り直して知らせた")

        // 続けて来る知らせは間を空けてまとめて作り直す(2026-10-05 の監査 A7-1。以前は知らせの数だけ作り直した)。
        let rebuildsBefore = model.rebuildCount
        for _ in 0..<20 {
            library.collections.setCoverStatus(.ready, aspect: 1.5, for: item)
            try? await Task.sleep(for: .milliseconds(5))
        }
        await settle()
        #expect(model.rebuildCount - rebuildsBefore <= 5, "知らせのたびに作り直した")

        let third = try #require(CollectionStore.makePendingItem(for: try makeBookFolder(temporary, named: "c-book")))
        _ = library.collections.add([third], to: collection)
        await waitUntil { model.rows.count == 5 }
        #expect(model.rows.last?.title == "c-book")
    }

    @Test("本の行の名前はカバーの下の文字の設定に従い、「表示しない」のときは並び順に合わせる(2026-10-04 の監査 SP-9)")
    func bookNamesFollowTheCaptionSetting() {
        #expect(SidePanelLibraryTreeModel.showsMetadataTitle(captionStyle: .title, itemSort: .nameAscending))
        #expect(!SidePanelLibraryTreeModel.showsMetadataTitle(captionStyle: .fileName, itemSort: .titleAscending))
        #expect(SidePanelLibraryTreeModel.showsMetadataTitle(captionStyle: .none, itemSort: .titleDescending))
        #expect(!SidePanelLibraryTreeModel.showsMetadataTitle(captionStyle: .none, itemSort: .dateAddedAscending))
    }
}

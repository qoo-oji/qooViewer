import Combine
import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// アプリ全体の入れ物(App/AppStores.swift)の**配線**。部品(BookRecordRelocator・FavoriteLocationStore.relocate …)は
/// それぞれのテストが確かめている。ここで見るのは、AppStores がそれらを正しくつないでいるか ―― 2026-10-11 まではテストホストの
/// 中で配線ごと外していたので、一度も確かめられていなかった。組み立ては `AppStoresHarness`(このテストの置き場所と知らせの箱)。
@MainActor
struct AppStoresWiringTests {
    private func makeBookFolder(at url: URL) throws {
        try FixtureFolder.make(at: url, pages: [.init("001.jpg", number: 1)])
    }

    // MARK: - アプリの値

    @Test("テストホストとして起動したアプリの選択は、共有の状態に触る配線をすべて外している")
    func liveDependenciesUnderTestsStayOffSharedState() {
        let live = AppStores.Dependencies.live()
        #expect(live.changeCenter == nil)
        #expect(live.runsLaunchSweeps == false)
        #expect(live.startsMetadataGeneration == false)
        #expect(live.startsBackgroundServices == false)
        #expect(live.metadataDraftStore == nil)
        #expect(live.metadataCorpusURL == nil)
        #expect(live.smartLibraryCatalogURL == nil)
        #expect(live.secretFolderDefaults == nil)
        // 規則は使い捨ての場所(利用者の settings.json ではない)。
        #expect(live.metadataRulesURL?.path.hasPrefix(FileManager.default.temporaryDirectory.path) == true)
    }

    // MARK: - アプリ自身がファイルを動かした知らせ

    @Test("ファイルの変化の知らせは、保存データ・よく使う項目・シークレットフォルダ・スマートライブラリの対象へ届く")
    func fileSystemChangeReachesEveryConsumer() async throws {
        let harness = try AppStoresHarness(label: "wiring-change")
        defer { harness.close() }
        let stores = harness.stores
        let shelf = try harness.temporary.directory("shelf")
        let book = shelf.appendingPathComponent("book-a", isDirectory: true)
        try makeBookFolder(at: book)

        #expect(stores.bookmarkStore.addBookmark(
            bookID: book.path, pageIndex: 0, name: "p1", fileNodeIdentifier: FileNodeIdentifier.current(for: book)
        ))
        _ = stores.metadataStore.upsert(bookID: book.path, author: "A", title: "T", series: "", seriesIndex: "", sourceURL: book)
        stores.favoriteLocations.add(shelf)
        stores.secretFolderStore.add(shelf)
        _ = stores.smartLibraryStore.addFolder(shelf)

        let renamed = harness.temporary.file("shelf-renamed")
        try FileManager.default.moveItem(at: shelf, to: renamed)
        let newBookPath = renamed.appendingPathComponent("book-a").path
        await harness.report(FileSystemChange(relocations: [.init(from: shelf, to: renamed)]))
        await stores.lastFileSystemChangeHandling?.value

        #expect(stores.bookmarkStore.bookmarks(forBookID: newBookPath).count == 1)
        #expect(stores.bookmarkStore.bookmarks(forBookID: book.path).isEmpty)
        #expect(stores.metadataStore.metadata(forBookID: newBookPath)?.author == "A")
        #expect(stores.favoriteLocations.items.map(\.path) == [renamed.path])
        #expect(stores.secretFolderStore.folders.map(MountTable.normalized) == [MountTable.normalized(renamed.path)])
        #expect(stores.smartLibraryStore.folders.map(\.path) == [renamed.path])
    }

    @Test("知らせの箱を渡さなければ購読しない(テストホストとして起動したアプリの形)")
    func withoutChangeCenterNothingFollows() async throws {
        let unsubscribedCenter = FileSystemChangeCenter()
        let harness = try AppStoresHarness(label: "wiring-unsubscribed") { $0.changeCenter = nil }
        defer { harness.close() }
        let folder = try harness.temporary.directory("favorite")
        harness.stores.favoriteLocations.add(folder)

        let renamed = harness.temporary.file("favorite-renamed")
        try FileManager.default.moveItem(at: folder, to: renamed)
        // 箱は誰も購読していない(ハーネスの箱にも、別の箱にも入れてみる)。
        await harness.report(FileSystemChange(relocations: [.init(from: folder, to: renamed)]))
        unsubscribedCenter.report(FileSystemChange(relocations: [.init(from: folder, to: renamed)]))

        #expect(harness.stores.lastFileSystemChangeHandling == nil)
        #expect(harness.stores.favoriteLocations.items.map(\.path) == [folder.path])
    }

    @Test("自動リネームのファイル操作の知らせも、渡した箱を通って保存データへ届く")
    func fileOperationsReportThroughTheSameCenter() async throws {
        let harness = try AppStoresHarness(label: "wiring-file-ops")
        defer { harness.close() }
        let stores = harness.stores
        let book = harness.temporary.file("book-a")
        try makeBookFolder(at: book)
        #expect(stores.bookmarkStore.addBookmark(
            bookID: book.path, pageIndex: 0, name: "p1", fileNodeIdentifier: FileNodeIdentifier.current(for: book)
        ))

        let delivered = OneShotSignal()
        let subscription = harness.changeCenter.changes.sink { _ in delivered.fire() }
        defer { subscription.cancel() }
        let renamed = try await harness.fileOperations.rename(book, to: "book-b").renamed
        #expect(await delivered.wait())
        await stores.lastFileSystemChangeHandling?.value

        #expect(stores.bookmarkStore.bookmarks(forBookID: renamed.path).count == 1)
        #expect(stores.bookmarkStore.bookmarks(forBookID: book.path).isEmpty)
    }

    // MARK: - 機能の ON/OFF

    @Test("「ライブラリを有効にする」の切り替えは、ライブラリのためだけの仕事へ伝わる")
    func libraryFeatureToggleReachesLibraryWork() async throws {
        let harness = try AppStoresHarness(label: "wiring-library-toggle")
        defer { harness.close() }
        let stores = harness.stores
        #expect(stores.collectionStore.isLibraryFeatureEnabled)
        #expect(stores.collectionCoverExtractor.isLibraryFeatureEnabled)
        #expect(stores.collectionAutoFolderScanner.isLibraryFeatureEnabled)

        stores.preferences.libraryFeatureEnabled = false
        #expect(stores.collectionStore.isLibraryFeatureEnabled == false)
        #expect(stores.collectionCoverExtractor.isLibraryFeatureEnabled == false)
        #expect(stores.collectionAutoFolderScanner.isLibraryFeatureEnabled == false)

        stores.preferences.libraryFeatureEnabled = true
        #expect(stores.collectionStore.isLibraryFeatureEnabled)
        #expect(stores.collectionCoverExtractor.isLibraryFeatureEnabled)
        #expect(stores.collectionAutoFolderScanner.isLibraryFeatureEnabled)
    }

    @Test("ライブラリ機能を OFF にして作ると、ライブラリの仕事は起動の時点から止まっている")
    func libraryWorkStartsStoppedWhenTheFeatureIsOff() throws {
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        AppPreferences(defaults: suite.defaults).libraryFeatureEnabled = false
        let harness = try AppStoresHarness(label: "wiring-library-off") { $0.defaults = suite.defaults }
        defer { harness.close() }
        #expect(harness.stores.collectionStore.isLibraryFeatureEnabled == false)
        #expect(harness.stores.collectionCoverExtractor.isLibraryFeatureEnabled == false)
        #expect(harness.stores.collectionAutoFolderScanner.isLibraryFeatureEnabled == false)
    }

    // MARK: - メタデータ生成の母体

    @Test("メタデータ生成を始めると、コレクションの本が母体へ記録される(シークレットフォルダの本は除く)")
    func metadataGenerationRecordsCollectionBooks() async throws {
        let harness = try AppStoresHarness(label: "wiring-corpus") { $0.startsMetadataGeneration = true }
        defer { harness.close() }
        let stores = harness.stores
        let visible = harness.temporary.file("visible")
        let secretRoot = try harness.temporary.directory("secret")
        let hidden = secretRoot.appendingPathComponent("hidden", isDirectory: true)
        try makeBookFolder(at: visible)
        try makeBookFolder(at: hidden)
        let previousAppWide = MetadataGenerator.appWide

        let library = try #require(stores.collectionStore.libraries.first)
        let pending = [visible, hidden].compactMap { CollectionStore.makePendingItem(for: $0) }
        #expect(pending.count == 2)
        _ = try #require(stores.collectionStore.createCollection(name: "Series", in: library, items: pending))
        stores.secretFolderStore.add(secretRoot)

        #expect(await eventually { @MainActor in stores.metadataCorpusStore.collectionBookIDs == [visible.path] })
        // アプリで 1 つの生成役は差し替えない(isAppWide: false)。
        #expect(MetadataGenerator.appWide === previousAppWide)
    }

    // MARK: - 在るかの確かめ

    @Test("在るかの確かめは、記録どおりの場所にある本だけを返す")
    func probeExistenceReturnsBooksAtTheirRecordedPaths() async throws {
        let harness = try AppStoresHarness(label: "wiring-probe")
        defer { harness.close() }
        let stores = harness.stores
        let present = harness.temporary.file("present")
        try makeBookFolder(at: present)
        let missing = harness.temporary.file("missing")
        let probes = [present, missing].map {
            BookExistenceProbe.make(
                bookID: $0.path, metadataStore: stores.metadataStore, layoutStore: stores.layoutStore,
                bookmarkStore: stores.bookmarkStore, favoritesStore: stores.favoritesStore, collectionStore: nil,
                folderAccess: stores.folderAccess
            )
        }
        let existing = await AppStores.probeExistence(probes, mounts: MountTable.current())
        #expect(existing == [present.path])
    }
}

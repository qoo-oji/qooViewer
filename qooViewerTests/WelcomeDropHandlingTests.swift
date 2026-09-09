import Foundation
import Testing

@testable import qooViewer

/// ウェルカム画面へのドロップの振り分け(Views/Welcome/WelcomeView.swift の
/// `WelcomeDropHandling`)。画面の値を捕まえずに済むよう View の外へ出してある部分で、
/// 状態(WelcomeLibraryState)とストアだけで動く。
///
/// 押さえるのは:
/// - 編集モードの外では引き受けない(本を開く経路へ回す)
/// - 一覧へのドロップは名前の入力待ち(`pendingCreations`)へ積む ―― ばらの本は 1 つに
///   まとめ、棚はフォルダ名を既定の名前に。自動登録フォルダの初期値は「全部が同じフォルダ」のときだけ
/// - コレクションの中へのドロップは、そのコレクションへ本を足す(棚は中の本へ展開する)
///
/// 振り分けはフォルダの列挙を伴うためメインアクターの外で走る。待ち合わせは
/// `onFinished`(テストのための口)で行い、時間では待たない。
@MainActor
struct WelcomeDropHandlingTests {
    private struct Harness {
        let library: InMemoryLibrary
        let suite: PreferencesSuite
        let state: WelcomeLibraryState
        let preferences: AppPreferences
        let extractor: CollectionCoverExtractor

        init(_ label: String) throws {
            library = try InMemoryLibrary(label: label)
            suite = PreferencesSuite(label: label)
            state = WelcomeLibraryState(defaults: suite.defaults)
            preferences = suite.makePreferences()
            extractor = CollectionCoverExtractor(
                collectionStore: library.collections, coverStore: library.collectionCovers,
                layoutStore: library.layouts, cachesPageList: false, defaults: suite.defaults
            )
        }

        func close() {
            extractor.releaseResources()
            library.close()
        }

        /// 振り分けが終わるまで待って、引き受けたかどうかを返す。
        func drop(_ urls: [URL]) async -> Bool {
            await withCheckedContinuation { continuation in
                let accepted = WelcomeDropHandling.handle(
                    urls, allowsEditing: true, state: state,
                    collectionStore: library.collections, coverExtractor: extractor,
                    preferences: preferences, onFinished: { continuation.resume(returning: true) }
                )
                if !accepted { continuation.resume(returning: false) }
            }
        }
    }

    private func makeArchive(_ url: URL, number: UInt8) throws {
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: number))
        try builder.write(to: url)
    }

    @Test("編集モードの外では引き受けない(本を開く経路へ回す)")
    func dropsOutsideEditModeAreNotHandled() async throws {
        let harness = try Harness("welcome-drop-not-editing")
        defer { harness.close() }
        let temporary = try TemporaryDirectory("welcome-drop-not-editing")
        let book = temporary.file("01.cbz")
        try makeArchive(book, number: 1)

        #expect(await harness.drop([book]) == false)
        #expect(harness.state.pendingCreations.isEmpty)

        // シークレットウインドウ(allowsEditing == false)も同じ。
        harness.state.isEditing = true
        #expect(
            WelcomeDropHandling.handle(
                [book], allowsEditing: false, state: harness.state,
                collectionStore: harness.library.collections, coverExtractor: harness.extractor,
                preferences: harness.preferences
            ) == false
        )
    }

    @Test("一覧へ落としたばらの本は 1 つの作成待ちにまとまり、同じフォルダなら自動登録フォルダの初期値になる")
    func looseBooksBecomeOnePendingCreation() async throws {
        let harness = try Harness("welcome-drop-loose")
        defer { harness.close() }
        let temporary = try TemporaryDirectory("welcome-drop-loose")
        let folder = try temporary.directory("downloads")
        let first = folder.appendingPathComponent("01.cbz")
        let second = folder.appendingPathComponent("02.cbz")
        try makeArchive(first, number: 1)
        try makeArchive(second, number: 2)
        // 対象外のものは黙って落とす。
        let note = folder.appendingPathComponent("readme.txt")
        try Data("memo".utf8).write(to: note)
        harness.state.isEditing = true

        #expect(await harness.drop([first, note, second]))

        let creation = try #require(harness.state.pendingCreations.first)
        #expect(harness.state.pendingCreations.count == 1)
        #expect(creation.books == [first, second])
        #expect(creation.defaultName.isEmpty)
        #expect(creation.fromShelf == false)
        #expect(creation.autoFolder?.path == folder.path)
        // ドロップ由来なので、名前を決めたあとに「本を追加」パネルは出さない
        // (WelcomeView.finishCreation参照)。
        #expect(creation.fromDrop)
    }

    @Test("別々のフォルダから集めた本には自動登録フォルダの初期値を付けない")
    func booksFromDifferentFoldersGetNoAutoFolder() async throws {
        let harness = try Harness("welcome-drop-mixed-folders")
        defer { harness.close() }
        let temporary = try TemporaryDirectory("welcome-drop-mixed-folders")
        let first = try temporary.directory("a").appendingPathComponent("01.cbz")
        let second = try temporary.directory("b").appendingPathComponent("02.cbz")
        try makeArchive(first, number: 1)
        try makeArchive(second, number: 2)
        harness.state.isEditing = true

        #expect(await harness.drop([first, second]))

        let creation = try #require(harness.state.pendingCreations.first)
        #expect(creation.books == [first, second])
        #expect(creation.autoFolder == nil)
    }

    @Test("棚はフォルダ名を既定の名前にした作成待ちになり、ばらの本の後ろに並ぶ")
    func aShelfBecomesItsOwnPendingCreation() async throws {
        let harness = try Harness("welcome-drop-shelf")
        defer { harness.close() }
        let temporary = try TemporaryDirectory("welcome-drop-shelf")
        let shelf = try temporary.directory("Comics")
        let shelfBook = shelf.appendingPathComponent("01.cbz")
        try makeArchive(shelfBook, number: 1)
        let loose = temporary.file("loose.cbz")
        try makeArchive(loose, number: 2)
        harness.state.isEditing = true

        #expect(await harness.drop([shelf, loose]))

        #expect(harness.state.pendingCreations.count == 2)
        let looseCreation = try #require(harness.state.pendingCreations.first)
        #expect(looseCreation.books == [loose])
        #expect(looseCreation.fromShelf == false)
        let shelfCreation = try #require(harness.state.pendingCreations.last)
        #expect(shelfCreation.defaultName == "Comics")
        #expect(shelfCreation.books == [shelfBook])
        #expect(shelfCreation.fromShelf)
        #expect(shelfCreation.autoFolder?.path == shelf.path)
        // 棚もばらの本も、ドロップから来たことは同じ(looseCreation.fromDropも真)。
        #expect(looseCreation.fromDrop)
        #expect(shelfCreation.fromDrop)
    }

    @Test("コレクションの中へ落とすと、そのコレクションへ本が足される(棚は中の本へ展開する)")
    func dropsInsideACollectionAddBooksToIt() async throws {
        let harness = try Harness("welcome-drop-into-collection")
        defer { harness.close() }
        let temporary = try TemporaryDirectory("welcome-drop-into-collection")
        let seed = temporary.file("seed.cbz")
        try makeArchive(seed, number: 1)
        let shelfLibrary = try #require(harness.library.collections.libraries.first)
        let pending = try #require(CollectionStore.makePendingItem(for: seed))
        let collection = try #require(
            harness.library.collections.createCollection(name: "Shelf", in: shelfLibrary, items: [pending])
        )
        let shelf = try temporary.directory("more")
        let shelfBook = shelf.appendingPathComponent("02.cbz")
        try makeArchive(shelfBook, number: 2)
        // 中へ入ると編集モードは解除されるので、入ってから編集モードにする。
        harness.state.openedCollectionID = collection.id
        harness.state.isEditing = true

        #expect(await harness.drop([shelf, seed]))
        await harness.extractor.waitUntilIdle()

        // 棚の中の本が足され、既に入っている本は二重にならない。作成待ちには積まない。
        #expect(Set(collection.items.map(\.bookID)) == [seed.path, shelfBook.path])
        #expect(harness.state.pendingCreations.isEmpty)
    }
}

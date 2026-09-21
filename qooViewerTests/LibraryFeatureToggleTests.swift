import AppKit
import Foundation
import Testing

@testable import qooViewer

/// 環境設定「ライブラリを有効にする」(AppPreferences.libraryFeatureEnabled。2026-09-21)。
///
/// 押さえるのは 2 つ:
/// - OFFの間、ライブラリのためだけの仕事(存在確認・表紙の抽出・「ホーム」メニューの写し)が**走らない**こと
/// - ONへ戻したら**元どおり動き出し、取りこぼしが無い**こと(OFFの間に表紙の指定が変わった本を含む)
/// 画面の側は、ホームがファイルブラウザに固定されることと、右クリックからコレクションの項目が消えること。
@MainActor
struct LibraryFeatureToggleTests {
    private func makeFolderBook(_ temporary: TemporaryDirectory, named name: String) throws -> URL {
        let directory = temporary.file(name)
        try FixtureFolder.make(at: directory, pages: [.init("001.png", number: 1), .init("002.png", number: 2)])
        return directory
    }

    private func register(_ url: URL, in library: InMemoryLibrary, collection name: String = "Shelf") throws -> CollectionItem {
        let shelf = try #require(library.collections.libraries.first)
        let pending = try #require(CollectionStore.makePendingItem(for: url))
        let collection = try #require(library.collections.createCollection(name: name, in: shelf, items: [pending]))
        return try #require(collection.items.first)
    }

    private func coverNumber(of item: CollectionItem, in library: InMemoryLibrary) async -> Int? {
        guard let image = await library.collectionCovers.image(for: item.id) else { return nil }
        return PageColorReader.number(in: image)
    }

    // MARK: - ホームの状態

    @Test("OFFの間はファイルブラウザに固定され、保存したモードは書き換えない。ONへ戻すと前に見ていたほうへ戻る")
    func homeIsPinnedToTheFileBrowserWhileOff() {
        let suite = PreferencesSuite(label: "library-toggle-home")
        defer { withExtendedLifetime(suite) {} }
        let state = WelcomeLibraryState(defaults: suite.defaults)
        #expect(state.isLibraryFeatureEnabled)
        #expect(state.mode == .shelf)
        state.isEditing = true

        state.isLibraryFeatureEnabled = false
        #expect(state.mode == .browser)
        #expect(!state.isEditing)
        // 本棚へは切り替えられない。
        state.mode = .shelf
        #expect(state.mode == .browser)
        // 次に開くウインドウは、設定を保存先から読んで最初からファイルブラウザで始まる。
        let preferences = suite.makePreferences()
        preferences.libraryFeatureEnabled = false
        #expect(WelcomeLibraryState(defaults: suite.defaults).mode == .browser)
        #expect(!WelcomeLibraryState(defaults: suite.defaults).isLibraryFeatureEnabled)
        // テストホストのウインドウ(restoresMode == false)は、設定に関わらず本棚のまま。
        #expect(WelcomeLibraryState(defaults: suite.defaults, restoresMode: false).mode == .shelf)

        state.isLibraryFeatureEnabled = true
        #expect(state.mode == .shelf)
    }

    @Test("ホームの形は2つの設定の組で決まる: 両方ONなら選んだほう、片方なら残ったほう、両方OFFなら本棚を足す前のウェルカム画面")
    func theHomeModeFollowsBothFeatureFlags() {
        for wanted in [WelcomeMode.shelf, .browser] {
            #expect(WelcomeLibraryState.constrained(wanted, library: true, fileBrowser: true) == wanted)
            #expect(WelcomeLibraryState.constrained(wanted, library: true, fileBrowser: false) == .shelf)
            #expect(WelcomeLibraryState.constrained(wanted, library: false, fileBrowser: true) == .browser)
            #expect(WelcomeLibraryState.constrained(wanted, library: false, fileBrowser: false) == .classic)
        }
        // `.classic` は選べるモードではない(両方ONへ戻ったら本棚)。
        #expect(WelcomeLibraryState.constrained(.classic, library: true, fileBrowser: true) == .shelf)

        let suite = PreferencesSuite(label: "home-feature-flags")
        defer { withExtendedLifetime(suite) {} }
        let state = WelcomeLibraryState(defaults: suite.defaults)
        state.mode = .browser
        #expect(suite.defaults.string(forKey: "qooViewer.welcome.mode") == "browser")

        // ファイルブラウザをOFF: 本棚に固定され、ファイルブラウザへは切り替えられない。
        state.isFileBrowserFeatureEnabled = false
        #expect(state.mode == .shelf)
        state.mode = .browser
        #expect(state.mode == .shelf)
        // 両方OFF: 本棚を足す前のウェルカム画面。
        state.isLibraryFeatureEnabled = false
        #expect(state.mode == .classic)
        // ファイルブラウザだけON。
        state.isFileBrowserFeatureEnabled = true
        #expect(state.mode == .browser)
        // 押し込まれたモードは保存していないので、両方ONへ戻すと前に見ていたほう(ファイルブラウザ)へ戻る。
        state.isFileBrowserFeatureEnabled = false
        state.isLibraryFeatureEnabled = true
        #expect(state.mode == .shelf)
        #expect(suite.defaults.string(forKey: "qooViewer.welcome.mode") == "browser")
        state.isFileBrowserFeatureEnabled = true
        #expect(state.mode == .browser)

        // 次に開くウインドウは、保存先の設定から最初の形を決める。
        let preferences = suite.makePreferences()
        preferences.libraryFeatureEnabled = false
        preferences.fileBrowserFeatureEnabled = false
        #expect(WelcomeLibraryState(defaults: suite.defaults).mode == .classic)
        preferences.libraryFeatureEnabled = true
        #expect(WelcomeLibraryState(defaults: suite.defaults).mode == .shelf)
        #expect(WindowTitle.welcome(mode: .classic, folderName: "Folder", libraryName: "Library", collectionName: nil)
                == WindowTitle.appName)
    }

    // MARK: - 裏の仕事

    @Test("OFFの間は登録した本の存在確認をしない。ONへ戻すとその場で確かめる")
    func existenceIsNotCheckedWhileOff() async throws {
        let library = try InMemoryLibrary(label: "library-toggle-existence")
        defer { library.close() }
        let temporary = try TemporaryDirectory("library-toggle-existence")
        let item = try register(try makeFolderBook(temporary, named: "book"), in: library)
        await library.collections.settleExistenceRefresh()

        library.collections.setLibraryFeatureEnabled(false)
        try FileManager.default.removeItem(atPath: item.bookID)
        library.collections.scheduleExistenceRefresh()
        await library.collections.settleExistenceRefresh()
        // 確かめていないので、消えたことをまだ知らない。
        #expect(library.collections.missingBookSweep().isEmpty)

        library.collections.setLibraryFeatureEnabled(true)
        await library.collections.settleExistenceRefresh()
        #expect(library.collections.missingBookSweep().books.map(\.title) == ["book"])
    }

    @Test("OFFで始めた抽出役は何も抽出せず、ONへ戻すと待っていた本の表紙を作る")
    func coversAreNotExtractedWhileOff() async throws {
        let library = try InMemoryLibrary(label: "library-toggle-covers")
        defer { library.close() }
        let suite = PreferencesSuite(label: "library-toggle-covers")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("library-toggle-covers")
        let item = try register(try makeFolderBook(temporary, named: "book"), in: library)
        let extractor = CollectionCoverExtractor(
            collectionStore: library.collections, coverStore: library.collectionCovers,
            layoutStore: library.layouts, cachesPageList: false, defaults: suite.defaults,
            isLibraryFeatureEnabled: false
        )
        defer { extractor.releaseResources() }

        extractor.enqueue([item])
        extractor.refill()
        await extractor.waitUntilIdle()
        #expect(extractor.extractionAttemptCount == 0)
        #expect(item.coverState == .pending)

        extractor.setLibraryFeatureEnabled(true)
        await extractor.waitUntilIdle()
        #expect(item.coverState == .ready)
        #expect(await coverNumber(of: item, in: library) == 1)

        // OFFにすると、積んであるぶんも捨てる。
        extractor.setLibraryFeatureEnabled(false)
        extractor.enqueue([item])
        await extractor.waitUntilIdle()
        #expect(extractor.extractionAttemptCount == 1)
    }

    @Test("OFFの間に表紙の指定を変えた本は、ONへ戻したとき(アプリを起動し直した後でも)表紙を作り直す")
    func coversChangedWhileOffAreRedone() async throws {
        let library = try InMemoryLibrary(label: "library-toggle-redo")
        defer { library.close() }
        let suite = PreferencesSuite(label: "library-toggle-redo")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("library-toggle-redo")
        let url = try makeFolderBook(temporary, named: "book")
        let item = try register(url, in: library)
        let untouched = try register(try makeFolderBook(temporary, named: "other"), in: library, collection: "Other")
        func makeExtractor(enabled: Bool) -> CollectionCoverExtractor {
            CollectionCoverExtractor(
                collectionStore: library.collections, coverStore: library.collectionCovers,
                layoutStore: library.layouts, cachesPageList: false, defaults: suite.defaults,
                isLibraryFeatureEnabled: enabled
            )
        }
        let first = makeExtractor(enabled: true)
        first.refill()
        await first.waitUntilIdle()
        #expect(await coverNumber(of: item, in: library) == 1)

        first.setLibraryFeatureEnabled(false)
        library.layouts.setShelfCoverPageKey(
            forBookID: item.bookID, sourceURL: url,
            pageKey: url.appendingPathComponent("002.png").path, displayName: "002.png"
        )
        await first.waitUntilIdle()
        #expect(await coverNumber(of: item, in: library) == 1)
        // 通知はアプリ全体に飛ぶ(並行して走るほかのテストの本が混ざりうる)ので、含まれていることだけを見る。
        let remembered = suite.defaults.stringArray(forKey: CollectionCoverExtractor.booksChangedWhileDisabledKey) ?? []
        #expect(remembered.contains(item.bookID))
        first.releaseResources()

        // 起動し直した(OFFのまま)あとでONへ戻す。
        let second = makeExtractor(enabled: false)
        defer { second.releaseResources() }
        second.setLibraryFeatureEnabled(true)
        await second.waitUntilIdle()
        #expect(await coverNumber(of: item, in: library) == 2)
        // 変えていない本は作り直さない。覚えは消えている。
        #expect(second.extractionAttemptCount == 1)
        #expect(untouched.coverState == .ready)
        #expect(suite.defaults.stringArray(forKey: CollectionCoverExtractor.booksChangedWhileDisabledKey) == nil)
    }

    @Test("OFFの間、「ホーム」メニューの名前の写しは空のまま。ONへ戻すと作られる")
    func theHomeMenuDirectoryStaysEmptyWhileOff() async throws {
        let library = try InMemoryLibrary(label: "library-toggle-directory")
        defer { library.close() }
        let temporary = try TemporaryDirectory("library-toggle-directory")
        let store = HomeMenuDirectoryStore(collectionStore: library.collections, isLibraryFeatureEnabled: false)
        _ = try register(try makeFolderBook(temporary, named: "book"), in: library)
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(store.directory.libraries.isEmpty)
        #expect(store.rebuildCount == 0)

        store.setLibraryFeatureEnabled(true)
        for _ in 0..<200 where store.directory.libraries.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(store.directory.libraries.first?.collections.map(\.name) == ["Shelf"])
    }

    // MARK: - 右クリック

    @Test("OFFの間、右クリックの並びから「コレクションを作成」「コレクションに登録」の群が消える(空の群も残さない)")
    func collectionItemsLeaveTheContextMenu() {
        for kind in [FileBrowserMenuKind.folder, .file, .tree, .background] {
            // 式を小分けにして型を書く(1 つの `#expect` に詰めると、CI の Xcode 26.6 が「時間内に型チェックできない」で落とす)。
            let all: [FileBrowserMenuCommand] = FileBrowserMenuCommand.groups(for: kind).flatMap { $0 }
            let without: [[FileBrowserMenuCommand]] = FileBrowserMenuCommand.groups(for: kind, includesLibrary: false)
            let flattened: [FileBrowserMenuCommand] = without.flatMap { $0 }
            let library: Set<FileBrowserMenuCommand> = [.createCollection, .addToCollection]
            let expected: [FileBrowserMenuCommand] = all.filter { !library.contains($0) }
            let hasLibraryItem: Bool = flattened.contains { library.contains($0) }
            let hasEmptyGroup: Bool = without.contains { $0.isEmpty }
            #expect(!hasLibraryItem)
            #expect(!hasEmptyGroup)
            #expect(flattened == expected)
        }
        #expect(FileBrowserMenuCommand.groups(for: .file).flatMap { $0 }.contains(.createCollection))
    }
}

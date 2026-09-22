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
    /// 表紙の読み込みを数える箱(`redoInterruptedByTurningOffKeepsTheRest`)。
    private final class LoadCounter {
        var count = 0
    }

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

    @Test("3 つの設定の 8 通りすべてで、出せるモード・帯の有無・切り替えの行き先が揃う")
    func everyCombinationOfTheThreeFlags() {
        for library in [false, true] {
            for fileBrowser in [false, true] {
                for smart in [false, true] {
                    let allowed = [library ? WelcomeMode.shelf : nil, fileBrowser ? .browser : nil, smart ? .smart : nil]
                        .compactMap { $0 }
                    let label = "L=\(library) F=\(fileBrowser) S=\(smart)"
                    // 出せるモードはそのまま、出せないモードは出せるものへ(何も無ければ本棚を足す前の画面)。
                    for wanted in WelcomeMode.allCases {
                        let result = WelcomeLibraryState.constrained(wanted, library: library, fileBrowser: fileBrowser, smart: smart)
                        if allowed.isEmpty {
                            #expect(result == .classic, "\(label)")
                        } else {
                            #expect(allowed.contains(result), "\(label)")
                            if allowed.contains(wanted) { #expect(result == wanted, "\(label)") }
                        }
                    }
                    // 実際の状態でも同じ(ON/OFF を変えるたびに押し込まれ、帯はライブラリかスマートライブラリがあるときだけ)。
                    let suite = TestDefaultsPool.checkout()
                    let state = WelcomeLibraryState(defaults: suite.defaults)
                    state.isLibraryFeatureEnabled = library
                    state.isFileBrowserFeatureEnabled = fileBrowser
                    state.isSmartLibraryFeatureEnabled = smart
                    #expect(allowed.isEmpty ? state.mode == .classic : allowed.contains(state.mode), "\(label)")
                    #expect(state.showsTopBar == (library || smart), "\(label)")
                    // 帯・メニューの切り替え: 出せないモードへは行かない。いまのモードをもう一度押すと、ほかに出せるものがあればそちらへ。
                    for target in [WelcomeMode.shelf, .browser, .smart] {
                        let before = state.mode
                        state.toggleMode(target)
                        #expect(allowed.isEmpty ? state.mode == .classic : allowed.contains(state.mode), "\(label) → \(target)")
                        if before == target, allowed.count >= 2 { #expect(state.mode != target, "\(label) → \(target)") }
                    }
                    suite.release()
                }
            }
        }
    }

    @Test("スマートライブラリの設定も別に効き、帯のボタンでいまのモードをもう一度押すと出せるほかのモードへ戻る")
    func smartLibraryFlagAndToggle() {
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let state = WelcomeLibraryState(defaults: suite.defaults)
        state.mode = .smart
        #expect(state.mode == .smart)
        // ライブラリを OFF にしてもスマートライブラリのまま(帯は残る)。
        state.isLibraryFeatureEnabled = false
        #expect(state.mode == .smart)
        #expect(state.showsTopBar)
        // もう一度押すと、本棚が無いのでファイルブラウザへ。
        state.toggleMode(.smart)
        #expect(state.mode == .browser)
        state.toggleMode(.smart)
        // スマートライブラリを OFF にすると押し出され、ON へ戻すと保存してあったスマートライブラリへ戻る。
        state.isSmartLibraryFeatureEnabled = false
        #expect(state.mode == .browser)
        #expect(!state.showsTopBar)
        state.isSmartLibraryFeatureEnabled = true
        #expect(state.mode == .smart)
    }

    @Test("ホームの形は2つの設定の組で決まる: 両方ONなら選んだほう、片方なら残ったほう、両方OFFなら本棚を足す前のウェルカム画面")
    func theHomeModeFollowsBothFeatureFlags() {
        for wanted in [WelcomeMode.shelf, .browser] {
            #expect(WelcomeLibraryState.constrained(wanted, library: true, fileBrowser: true, smart: false) == wanted)
            #expect(WelcomeLibraryState.constrained(wanted, library: true, fileBrowser: false, smart: false) == .shelf)
            #expect(WelcomeLibraryState.constrained(wanted, library: false, fileBrowser: true, smart: false) == .browser)
            #expect(WelcomeLibraryState.constrained(wanted, library: false, fileBrowser: false, smart: false) == .classic)
        }
        // `.classic` は選べるモードではない(両方ONへ戻ったら本棚)。
        #expect(WelcomeLibraryState.constrained(.classic, library: true, fileBrowser: true, smart: true) == .shelf)
        // スマートライブラリは自分の設定だけで決まる(2026-09-22 からライブラリとは別。ライブラリが OFF でも選べる)。
        #expect(WelcomeLibraryState.constrained(.smart, library: true, fileBrowser: true, smart: true) == .smart)
        #expect(WelcomeLibraryState.constrained(.smart, library: false, fileBrowser: false, smart: true) == .smart)
        #expect(WelcomeLibraryState.constrained(.smart, library: true, fileBrowser: true, smart: false) == .shelf)
        #expect(WelcomeLibraryState.constrained(.smart, library: false, fileBrowser: true, smart: false) == .browser)
        // 出せないモードは 本棚 → ファイルブラウザ → スマートライブラリ の順で読み替える。
        #expect(WelcomeLibraryState.constrained(.shelf, library: false, fileBrowser: false, smart: true) == .smart)
        #expect(WelcomeLibraryState.constrained(.browser, library: false, fileBrowser: true, smart: true) == .browser)

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
        // 両方OFF(スマートライブラリも OFF): 本棚を足す前のウェルカム画面。
        state.isSmartLibraryFeatureEnabled = false
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
        preferences.smartLibraryFeatureEnabled = false
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

    /// 2026-09-21 の監査(docs/plans/feature-toggle-audit.md の L1)。取り消しは本の読み込みの中まで伝わって nil を返させるので、
    /// 以前はそれを「本を開けなかった」と取り違えて`.failed`にし、表紙の指定を変えるまで灰色のままになった。
    @Test("抽出の最中にOFFにした本は失敗にせず待ちのまま残し、ONへ戻すと表紙を作る")
    func extractionInterruptedByTurningOffStaysPending() async throws {
        let library = try InMemoryLibrary(label: "library-toggle-interrupted")
        defer { library.close() }
        let suite = PreferencesSuite(label: "library-toggle-interrupted")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("library-toggle-interrupted")
        let item = try register(try makeFolderBook(temporary, named: "book"), in: library)
        let extractor = CollectionCoverExtractor(
            collectionStore: library.collections, coverStore: library.collectionCovers,
            layoutStore: library.layouts, cachesPageList: false, defaults: suite.defaults
        )
        defer { extractor.releaseResources() }

        // 読み込みを始める直前にOFFにする(走っているループが取り消された状態で、本の読み込みへ入る)。
        extractor.willLoadCoverImageForTesting = { [weak extractor] in extractor?.setLibraryFeatureEnabled(false) }
        extractor.enqueue([item])
        await extractor.waitUntilIdle()
        #expect(extractor.extractionAttemptCount == 1)
        #expect(item.coverState == .pending)
        #expect(extractor.inFlightItemIDs.isEmpty)
        #expect(await library.collectionCovers.image(for: item.id) == nil)

        extractor.willLoadCoverImageForTesting = nil
        extractor.setLibraryFeatureEnabled(true)
        await extractor.waitUntilIdle()
        #expect(item.coverState == .ready)
        #expect(await coverNumber(of: item, in: library) == 1)
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

    /// 2026-09-21 の監査の L1(2 回目)。最初の版は ON へ戻した時点で控えを消していたので、作り直しの途中でもう一度 OFF にすると
    /// 残りの本は古い表紙のまま二度と拾われず、抽出に失敗していた本は指定を直しても灰色のままだった。
    @Test("OFFの間に変えた本の作り直しを途中でOFFにしても、残りの本は控えに残り、次にONへ戻したとき作り直す。失敗していた本も試し直す")
    func redoInterruptedByTurningOffKeepsTheRest() async throws {
        let library = try InMemoryLibrary(label: "library-toggle-redo-interrupted")
        defer { library.close() }
        let suite = PreferencesSuite(label: "library-toggle-redo-interrupted")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("library-toggle-redo-interrupted")
        let firstURL = try makeFolderBook(temporary, named: "book-1")
        let secondURL = try makeFolderBook(temporary, named: "book-2")
        let failedURL = try makeFolderBook(temporary, named: "book-3")
        let first = try register(firstURL, in: library)
        let second = try register(secondURL, in: library, collection: "Second")
        let failed = try register(failedURL, in: library, collection: "Third")
        let extractor = CollectionCoverExtractor(
            collectionStore: library.collections, coverStore: library.collectionCovers,
            layoutStore: library.layouts, cachesPageList: false, defaults: suite.defaults
        )
        defer { extractor.releaseResources() }
        extractor.refill()
        await extractor.waitUntilIdle()
        #expect(first.coverState == .ready)
        #expect(second.coverState == .ready)
        library.collections.setCoverStatus(.failed, aspect: 0, for: failed)

        extractor.setLibraryFeatureEnabled(false)
        for url in [firstURL, secondURL, failedURL] {
            library.layouts.setShelfCoverPageKey(
                forBookID: url.path, sourceURL: url, pageKey: url.appendingPathComponent("002.png").path, displayName: "002.png"
            )
        }
        let remembered = suite.defaults.stringArray(forKey: CollectionCoverExtractor.booksChangedWhileDisabledKey) ?? []
        #expect([first.bookID, second.bookID, failed.bookID].allSatisfy(remembered.contains))

        // ONへ戻し、2 冊目の読み込みを始める直前にもう一度 OFF にする。
        // 数は箱に入れる(Sendable な閉包が捕まえた変数を書き換えると、CI のコンパイラが断る。docs/02)。
        let loads = LoadCounter()
        extractor.willLoadCoverImageForTesting = { [weak extractor, loads] in
            loads.count += 1
            if loads.count == 2 { extractor?.setLibraryFeatureEnabled(false) }
        }
        extractor.setLibraryFeatureEnabled(true)
        await extractor.waitUntilIdle()
        #expect(await coverNumber(of: first, in: library) == 2)
        #expect(await coverNumber(of: second, in: library) == 1)
        let afterInterruption = suite.defaults.stringArray(forKey: CollectionCoverExtractor.booksChangedWhileDisabledKey) ?? []
        #expect(!afterInterruption.contains(first.bookID), "作り直しを終えた本は控えから外れる")
        #expect(afterInterruption.contains(second.bookID))
        #expect(afterInterruption.contains(failed.bookID))

        extractor.willLoadCoverImageForTesting = nil
        extractor.setLibraryFeatureEnabled(true)
        await extractor.waitUntilIdle()
        #expect(await coverNumber(of: second, in: library) == 2)
        #expect(failed.coverState == .ready)
        #expect(await coverNumber(of: failed, in: library) == 2)
        #expect(suite.defaults.stringArray(forKey: CollectionCoverExtractor.booksChangedWhileDisabledKey) == nil)
    }

    /// 2026-09-21 の監査の D2。控えの中身はパスなので、本が移ったら一緒に付け替えないと、ONへ戻したときの作り直しから漏れる。
    @Test("OFFの間に表紙の指定を変えた本をアプリが移したら、控えも新しいパスへ付け替わり、ONへ戻すとその本の表紙を作り直す")
    func rememberedChangesFollowABookTheAppMoved() async throws {
        let library = try InMemoryLibrary(label: "library-toggle-relocate")
        defer { library.close() }
        let suite = PreferencesSuite(label: "library-toggle-relocate")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("library-toggle-relocate")
        // 書庫の本にする(ページの鍵が書庫の中のパスなので、本が移っても指定が生きる。フォルダの本の鍵は絶対パス)。
        let url = temporary.file("book.zip")
        var zip = ZipFixtureBuilder()
        zip.add("001.png", PageImageFactory.png(number: 1))
        zip.add("002.png", PageImageFactory.png(number: 2))
        try zip.write(to: url)
        let item = try register(url, in: library)
        let extractor = CollectionCoverExtractor(
            collectionStore: library.collections, coverStore: library.collectionCovers,
            layoutStore: library.layouts, cachesPageList: false, defaults: suite.defaults
        )
        defer { extractor.releaseResources() }
        extractor.refill()
        await extractor.waitUntilIdle()
        #expect(await coverNumber(of: item, in: library) == 1)

        extractor.setLibraryFeatureEnabled(false)
        library.layouts.setShelfCoverPageKey(
            forBookID: item.bookID, sourceURL: url, pageKey: "002.png", displayName: "002.png"
        )
        // アプリ自身が本の名前を変えた(ファイルブラウザの操作)。保存データと一緒に控えも付け替わる。
        let moved = temporary.file("renamed.zip")
        try FileManager.default.moveItem(at: url, to: moved)
        let relocator = BookRecordRelocator(
            favoritesStore: library.favorites, bookmarkStore: library.bookmarks, layoutStore: library.layouts,
            metadataStore: library.metadata, collectionStore: library.collections, modelContext: library.context,
            coverExtractor: extractor
        )
        await relocator.apply(FileSystemChange(relocations: [.init(from: url, to: moved)])).value
        #expect(item.bookID == moved.path)
        let remembered = suite.defaults.stringArray(forKey: CollectionCoverExtractor.booksChangedWhileDisabledKey) ?? []
        #expect(remembered.contains(moved.path))
        #expect(!remembered.contains(url.path))

        extractor.setLibraryFeatureEnabled(true)
        await library.collections.settleExistenceRefresh()
        await extractor.waitUntilIdle()
        #expect(await coverNumber(of: item, in: library) == 2)
    }

    /// 2026-09-21 の監査の D2。以前はOFFの間コレクションの行だけ付け替えず、ほかの4つのストアと食い違った。
    @Test("OFFの間に開いた本が移動・リネームされていたら、コレクションの行もほかの保存データと一緒に追従する")
    func openingAMovedBookWhileOffReconcilesTheCollectionRow() async throws {
        let library = try InMemoryLibrary(label: "library-toggle-reconcile")
        defer { library.close() }
        let suite = PreferencesSuite(label: "library-toggle-reconcile")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("library-toggle-reconcile")
        let original = try makeFolderBook(temporary, named: "before")
        let item = try register(original, in: library)
        library.metadata.upsert(
            bookID: original.path, author: "a", title: "t", series: "", seriesIndex: "", sourceURL: original
        )
        let moved = temporary.file("after")
        try FileManager.default.moveItem(at: original, to: moved)

        let preferences = suite.makePreferences()
        preferences.libraryFeatureEnabled = false
        library.collections.setLibraryFeatureEnabled(false)
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        state.preferences = preferences
        state.favoritesStore = library.favorites
        state.bookmarkStore = library.bookmarks
        state.layoutStore = library.layouts
        state.metadataStore = library.metadata
        state.collectionStore = library.collections
        let recentFiles = RecentFilesStore(defaults: suite.defaults)
        state.recentFiles = recentFiles
        state.open(request: BookOpenRequest(moved))
        await state.openTask?.value

        #expect(library.metadata.isRegistered(bookID: moved.path))
        #expect(item.bookID == moved.path)
        #expect(item.title == "after")
        withExtendedLifetime(recentFiles) {}
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

import Foundation
import Testing

@testable import qooViewer

/// 2026-10-11 に足した口(ディスクキャッシュの差し替え・シートに答える役・ビープの記録・AppStores の組み立て)を使って、
/// それまで GUI でしか通らなかった流れを最後まで通す。口そのものの確かめは DiskCacheInjectionTests・SheetAndFeedbackPortTests・
/// AppStoresWiringTests にある。ここは「その口があれば確かめられるようになった振る舞い」。
@MainActor
struct PortDrivenFlowTests {
    private func makeZipBook(at url: URL, pageCount: Int = 3) throws {
        var builder = ZipFixtureBuilder()
        for number in 1...pageCount {
            builder.add(String(format: "p%02d.png", number), PageImageFactory.png(number: UInt8(number)))
        }
        try builder.write(to: url)
    }

    // MARK: - フォルダの許可のパネル

    @Test("「同じフォルダのファイルを開くための許可」: パネルで親フォルダを選ぶと許可に足され、パネルはそのフォルダから始まる")
    func grantingAccessToTheCurrentFolderAddsTheChosenFolder() async throws {
        let library = try InMemoryLibrary(label: "flow-grant-access")
        defer { library.close() }
        let temporary = try TemporaryDirectory("flow-grant-access")
        let shelf = try temporary.directory("shelf")
        let book = shelf.appendingPathComponent("book.cbz")
        try makeZipBook(at: book)
        let suite = PreferencesSuite(label: "flow-grant-access")
        let folderAccess = FolderAccessStore(defaults: suite.defaults)
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        state.preferences = library.preferences
        state.bookmarkStore = library.bookmarks
        state.layoutStore = library.layouts
        state.metadataStore = library.metadata
        state.favoritesStore = library.favorites
        state.folderAccess = folderAccess
        state.open(request: BookOpenRequest(book))
        await state.openTask?.value
        try #require(state.currentBook?.id == book.path)
        #expect(folderAccess.isPathCovered(shelf) == false)

        let responder = ScriptedSheetResponder(replies: [.choose([shelf])])
        SheetScripting.$responder.withValue(responder) {
            state.grantAccessToCurrentFolder()
        }

        #expect(await eventually { @MainActor in folderAccess.isPathCovered(shelf) })
        let panel = try #require(responder.presentations.first)
        #expect(panel.kind == .openPanel)
        #expect(panel.directoryURL?.standardizedFileURL.path == shelf.standardizedFileURL.path)
        state.closeBook()
    }

    @Test("許可のパネルを取り消すと、何も足さない")
    func cancellingTheAccessPanelAddsNothing() async throws {
        let library = try InMemoryLibrary(label: "flow-grant-cancel")
        defer { library.close() }
        let temporary = try TemporaryDirectory("flow-grant-cancel")
        let shelf = try temporary.directory("shelf")
        let book = shelf.appendingPathComponent("book.cbz")
        try makeZipBook(at: book)
        let suite = PreferencesSuite(label: "flow-grant-cancel")
        let folderAccess = FolderAccessStore(defaults: suite.defaults)
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        state.preferences = library.preferences
        state.folderAccess = folderAccess
        state.open(request: BookOpenRequest(book))
        await state.openTask?.value
        let responder = ScriptedSheetResponder(replies: [.cancel])

        SheetScripting.$responder.withValue(responder) {
            state.grantAccessToCurrentFolder()
        }

        #expect(await eventually { @MainActor in responder.presentations.count == 1 })
        #expect(folderAccess.isPathCovered(shelf) == false)
        #expect(folderAccess.entries.isEmpty)
        state.closeBook()
    }

    // MARK: - 「ブックマーク・レイアウトの編集」の右ペイン

    @Test("右ペインは前回のページ一覧(キャッシュ)から先に行を組み、本体を読み終えたら使えるようになる")
    func layoutEditorBuildsRowsFromTheCachedPageList() async throws {
        let harness = try ViewerHarness(label: "flow-layout-editor")
        defer { harness.close() }
        let url = harness.temporary.file("book.cbz")
        try makeZipBook(at: url, pageCount: 4)
        let book = try await harness.loadBookCachingPageList(url)
        let editor = BookLayoutEditorViewModel(
            bookID: book.id, layoutStore: harness.library.layouts, preferences: harness.preferences,
            bookmarkStore: harness.library.bookmarks, diskCaches: harness.diskCaches
        )

        await editor.load()

        #expect(editor.loadState == .loaded)
        #expect(editor.isBookReady)
        #expect(editor.rows.map(\.pageKey) == book.pages.map(\.sortKey))
        editor.releaseResources()
    }

    @Test("本体が見つからなくても、キャッシュにあった行は組まれたうえで「見つからない」になる")
    func layoutEditorShowsCachedRowsThenFailsForAMissingBook() async throws {
        let harness = try ViewerHarness(label: "flow-layout-editor-missing")
        defer { harness.close() }
        let url = harness.temporary.file("book.cbz")
        try makeZipBook(at: url, pageCount: 3)
        let book = try await harness.loadBookCachingPageList(url)
        try FileManager.default.removeItem(at: url)
        let editor = BookLayoutEditorViewModel(
            bookID: book.id, layoutStore: harness.library.layouts, preferences: harness.preferences,
            bookmarkStore: harness.library.bookmarks, diskCaches: harness.diskCaches
        )

        await editor.load()

        #expect(editor.loadState == .failed)
        #expect(editor.rows.count == 3)
        #expect(editor.isBookReady == false)
        editor.releaseResources()
    }

    // MARK: - 1 冊の書き出し

    @Test("1 冊の書き出しは本を読み込み、そのページ一覧を渡したキャッシュへ書き戻す(シークレットからの書き出しは書かない)")
    func exportingABookWritesItsPageListOnlyWhenRecording() async throws {
        let library = try InMemoryLibrary(label: "flow-export-cache")
        defer { library.close() }
        let temporary = try TemporaryDirectory("flow-export-cache")
        let caches = BookDiskCaches(directory: temporary.file("caches"))
        let output = try temporary.directory("out")
        let suite = PreferencesSuite(label: "flow-export-cache")
        let preferences = suite.makePreferences()

        for records in [true, false] {
            let source = try FixtureFolder.make(
                at: temporary.file("book-\(records)"), pages: [.init("p01.png", number: 1), .init("p02.png", number: 2)]
            )
            let viewModel = CbzExportViewModel(
                bookmarkStore: library.bookmarks, layoutStore: library.layouts, metadataStore: library.metadata,
                preferences: preferences, loadsEligibleRows: false
            )
            viewModel.diskCaches = caches
            viewModel.usesPageListCache = records
            let book = MangaBook(id: source.path, title: "book-\(records)", sourceURL: source, pages: [])

            let failure = await viewModel.exportOpenBook(book, displayState: nil, to: output)

            #expect(failure == nil, "records=\(records)")
            #expect(viewModel.successCount == 1, "records=\(records)")
            let pageLists = caches.pageLists
            if records {
                #expect(await eventually { await pageLists.pageList(forBookID: source.path) != nil })
            } else {
                #expect(await pageLists.pageList(forBookID: source.path) == nil)
            }
        }
    }
}

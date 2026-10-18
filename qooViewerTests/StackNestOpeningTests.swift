import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting
import SwiftData
import Testing

@testable import qooViewer

/// 参照ファイルの本を開く流れ。受け付け・本の組み立て(manifest が正・ID は参照ファイルのパス)・期限切れ・
/// `startPage` からの着地・書き直された参照ファイルを同じ本とみなすこと・開いた時に本全体を走査しないことを固定する。
@MainActor
struct StackNestOpeningTests {
    @Test("Finder・Dock・ドロップで渡された参照ファイルを、本として開く要求にする")
    func externalOpenAcceptsReferenceFiles() throws {
        let fixture = try StackNestTestBook()
        defer { fixture.close() }
        let prepared = ExternalOpenPreparation.prepare([fixture.referenceURL], order: .byName)
        #expect(prepared.request?.primaryURL == fixture.referenceURL)
        #expect(prepared.skipped == 0)
        let other = fixture.temporary.file("notes.txt")
        try Data("x".utf8).write(to: other)
        let dropped = DroppedBooks.multiple([fixture.referenceURL, other], order: .byName)
        #expect(dropped.books == [fixture.referenceURL])
        #expect(dropped.skipped == 1)
    }

    @Test("参照ファイルの本: ページは manifest の数、名前は StackNest の番号、ID は参照ファイルのパス、題名は title")
    func loadsPagesFromManifest() async throws {
        let fixture = try StackNestTestBook(pageCount: 5)
        defer { fixture.close() }
        fixture.setPageCount(7)
        let book = try await FixtureBook.load(fixture.referenceURL)
        #expect(book.id == fixture.referenceURL.path)
        #expect(book.sourceURL == fixture.referenceURL)
        #expect(book.title == "Reference Title")
        #expect(book.pages.map(\.sortKey) == (0..<7).map(StackNestPageNaming.entryName(forPage:)))
        #expect(book.pages.map(\.id) == (0..<7).map { "\(fixture.referenceURL.path)#\(StackNestPageNaming.entryName(forPage: $0))" })
        #expect(book.stackNestReference?.token == StackNestTestBook.token)
        // 本を文字列にしても鍵は出ない(入れ子の値は debugDescription で出る = <redacted>。将来 MangaBook に description が
        // 付いても守れるように固定しておく)。
        #expect(!String(describing: book).contains(StackNestTestBook.token))
        #expect(!String(reflecting: book).contains(StackNestTestBook.token))
        // 開くだけではページを取らない(manifest の 1 往復だけ)。
        #expect(fixture.manifestRequestCount == 1)
        #expect(fixture.pageRequestIndices.isEmpty)
    }

    @Test("期限切れの参照ファイルは、通信せずに失敗する")
    func expiredReferenceFailsWithoutRequests() async throws {
        let fixture = try StackNestTestBook(expiresAt: Date().addingTimeInterval(-60))
        defer { fixture.close() }
        await #expect(throws: StackNestOpenError(error: StackNestViewerError(.expired))) {
            try await FixtureBook.load(fixture.referenceURL)
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test("本を開くたびに manifest を問い合わせる(同じセッションを使い回しても、覚えた manifest で済ませない = StackNest への「読み込まれた」の合図)")
    func everyOpenAsksForAFreshManifest() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        // 開いている本のビューアが持つ reader の役(セッションの表は弱い参照なので、持つものが無いと2度目は作り直しになる)。
        let holder = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        defer { withExtendedLifetime(holder) {} }
        let first = try await FixtureBook.load(fixture.referenceURL)
        #expect(first.pages.count == 3)
        #expect(fixture.manifestRequestCount == 1)
        fixture.setPageCount(5)
        let second = try await FixtureBook.load(fixture.referenceURL)
        #expect(second.pages.count == 5)
        #expect(fixture.manifestRequestCount == 2)
    }

    @Test("127.0.0.1・::1 の字面でない宛先(localhost を含む)の参照ファイルは、開く時点で断り、要求を 1 件も出さない")
    func localhostReferenceIsRefusedAtOpen() async throws {
        let fixture = try StackNestTestBook()
        defer { fixture.close() }
        // 見立ては宛先のホストを見ずに道で応えるので、部品が通してしまえばこの要求は記録に残る。
        var components = try #require(URLComponents(url: fixture.server.bookURL, resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let localhostURL: URL = try #require(components.url)
        try fixture.writeReference(pageCount: 6, startPage: 0, bookURL: localhostURL)
        await #expect(throws: StackNestOpenError(error: StackNestViewerError(.hostNotAllowed))) {
            try await FixtureBook.load(fixture.referenceURL)
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test("401 で開けなかったときに出る文言は、期限切れと同じ「StackNest から開き直して」")
    func unauthorizedMessageMatchesExpiry() async throws {
        let fixture = try StackNestTestBook()
        defer { fixture.close() }
        fixture.server.respond(.manifest, with: .status(401))
        do {
            _ = try await FixtureBook.load(fixture.referenceURL)
            Issue.record("401 なのに開けてしまった")
        } catch {
            // AppState.open はこの errorDescription をアラートに出す。
            #expect(
                (error as? LocalizedError)?.errorDescription
                    == StackNestOpenError(error: StackNestViewerError(.expired)).errorDescription
            )
        }
    }

    @Test("開くページの ID は startPage の名前のページ。範囲外なら最後のページ、参照ファイルの本でなければ nil")
    func startPageID() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 9)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        #expect(ViewerViewModel.stackNestStartPageID(for: book) == "\(fixture.referenceURL.path)#000005.jpg")
        var plain = book
        plain.stackNestReference = nil
        #expect(ViewerViewModel.stackNestStartPageID(for: plain) == nil)
    }

    @Test("StackNest の本は、いつも StackNest が渡したページ(startPage)から開き、再開の確認は出さない(qooViewer に読書位置を残さない)")
    func opensAtStartPage() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.reopenBehavior = .ask
        let first = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        #expect(first.book.pages[first.currentIndex].sortKey == "000000.jpg")
        first.jump(toPageIndex: 3)
        await first.settle()
        first.flushPendingSave()
        harness.close()
        // 参照ファイルが書き直されていなければ、qooViewer で読んだ位置(3)ではなく StackNest が渡した位置(0)から。
        let again = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        #expect(again.book.pages[again.currentIndex].sortKey == "000000.jpg")
        #expect(!again.needsResumeConfirmation)
        harness.close()
        // StackNest がほかで読み進めた位置(4)で参照ファイルを書き直した。
        try fixture.writeReference(pageCount: 6, startPage: 4)
        let reopened = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        #expect(reopened.book.pages[reopened.currentIndex].sortKey == "000004.jpg")
        #expect(!reopened.needsResumeConfirmation)
    }

    @Test("StackNest の本はどの窓でも記録を残さない(読書位置・ブックマーク・レイアウト・メタデータ)が、普通の窓では StackNest へ位置を返す")
    func leavesNoRecordButWritesBack() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        #expect(book.leavesNoRecord)
        #expect(!book.hasBrowsableLocation)
        let rule = ViewerViewModel.recordingRule(bookLeavesNoRecord: book.leavesNoRecord, isPrivateWindow: false)
        #expect(rule.skipsPersistence)
        #expect(rule.writesBackToStackNest)
        let viewer = await harness.openInWindow(book)
        #expect(viewer.skipsPersistence)
        viewer.jump(toPageIndex: 2)
        await viewer.settle()
        viewer.addBookmark()
        viewer.toggleReadingDirection()
        await viewer.autoLayoutFromCurrentView()
        await viewer.settle()
        viewer.flushPendingSave()
        await viewer.stackNestProgress?.waitUntilIdle()
        // StackNest へは返す。
        #expect(fixture.progressPages == [2])
        harness.close()
        let context = harness.library.context
        let path = fixture.referenceURL.path
        #expect(((try? context.fetch(FetchDescriptor<BookReadingState>())) ?? []).filter { $0.bookID == path }.isEmpty)
        #expect(((try? context.fetch(FetchDescriptor<Bookmark>())) ?? []).filter { $0.bookID == path }.isEmpty)
        #expect(((try? context.fetch(FetchDescriptor<BookLayoutSettings>())) ?? []).filter { $0.bookID == path }.isEmpty)
        #expect(((try? context.fetch(FetchDescriptor<PageLayoutOverride>())) ?? []).filter { $0.bookID == path }.isEmpty)
        #expect(((try? context.fetch(FetchDescriptor<BookMetadata>())) ?? []).filter { $0.bookID == path }.isEmpty)
    }

    @Test("除外の行が残っている本(以前のビルド・手で作った保存データ)を読み込んで並びを組み直しても、参照ファイルの中身を落とさない")
    func preparedBookKeepsReference() async throws {
        let fixture = try StackNestTestBook(pageCount: 6)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        harness.library.layouts.setPageLayoutState(for: book, pageKey: book.pages[1].sortKey, state: .excluded)
        let viewer = await harness.open(book)
        #expect(viewer.book.pages.count == 5)
        #expect(viewer.book.stackNestReference?.bookURL == fixture.server.bookURL)
    }

    @Test(
        "manifest の読み方向で開く。利用者が切り替えた向きはその場だけで、開き直すと manifest の向き(記録を残さない)",
        arguments: ["ltr", "rtl"]
    )
    func directionComesFromTheManifest(direction: String) async throws {
        let fixture = try StackNestTestBook(pageCount: 4, direction: direction)
        defer { fixture.close() }
        let expected: ReadingDirection = direction == "ltr" ? .leftToRight : .rightToLeft
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        #expect(book.sourceLayoutHint?.pageProgressionDirection == expected)
        let first = await harness.openInWindow(book)
        #expect(first.readingDirection == expected)
        first.toggleReadingDirection()
        await first.settle()
        #expect(first.readingDirection != expected)
        harness.close()
        let reopened = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        #expect(reopened.readingDirection == expected)
    }

    @Test("読み方向の写し: rtl・ltr だけを読み、ほかは使わない")
    func directionMapping() {
        #expect(BookLoader.layoutHint(forStackNestDirection: .rightToLeft)?.pageProgressionDirection == .rightToLeft)
        #expect(BookLoader.layoutHint(forStackNestDirection: .leftToRight)?.pageProgressionDirection == .leftToRight)
        #expect(BookLoader.layoutHint(forStackNestDirection: StackNestReadingDirection(rawValue: "ttb")) == nil)
        #expect(BookLoader.layoutHint(forStackNestDirection: nil) == nil)
    }

    @Test("参照ファイルの本では「コレクションに登録」「本の書き出し」を出さず、メタデータにも登録しない")
    func libraryActionsAreDisabled() async throws {
        let fixture = try StackNestTestBook()
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        #expect(book.isStackNestReference)
        #expect(!book.canBeExported)
        #expect(!ViewerViewModel.registersMetadata(for: book, skipsPersistence: false))
        let suite = PreferencesSuite(label: "stacknest-actions")
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        let preferences = suite.makePreferences()
        // ライブラリ機能が OFF だと、参照ファイルの本でなくても登録できない(対照が空振りになる)ので ON にする。
        preferences.libraryFeatureEnabled = true
        state.preferences = preferences
        // AppState.preferences は weak なので、最後まで強く持っておく。
        withExtendedLifetime(preferences) {
            state.currentBook = book
            #expect(!state.canAddCurrentBookToCollection)
            // 対照: 参照ファイルでない同じ本は、登録できる・書き出せる・メタデータに登録する。
            var plain = book
            plain.stackNestReference = nil
            state.currentBook = plain
            #expect(state.canAddCurrentBookToCollection)
            #expect(plain.canBeExported)
            #expect(ViewerViewModel.registersMetadata(for: plain, skipsPersistence: false))
            state.currentBook = nil
        }
    }

    @Test("開いたときに本全体を走査しない(下調べ・レイアウトの自動計算のどちらでも、ページ数ぶんの往復をしない)")
    func noWholeBookScan() async throws {
        let fixture = try StackNestTestBook(pageCount: 40, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.prefetchPageCount = 2
        harness.preferences.missingLayoutAutoLayout = .firstPageSingle
        let book = try await FixtureBook.load(fixture.referenceURL)
        #expect(!ViewerViewModel.scansWholeBook(book))
        _ = await harness.openInWindow(book)
        let requested = Set(fixture.pageRequestIndices)
        #expect(!requested.isEmpty)
        // 表示したページの近傍(先読み 2 枚・横長の判定の半径 2)だけ。
        #expect(requested.allSatisfy { $0 < 10 }, "\(requested.sorted())")
    }

    @Test("メタデータ生成の母体に、参照ファイルの本は入らない(知っている本・開いた本・既存の行のどこから来ても)")
    func metadataGeneratorSkipsReferenceBooks() async throws {
        let library = try InMemoryLibrary(label: "stacknest-metadata")
        defer { library.close() }
        let reference = "/架空の置き場/Sample Book.stacknestbook"
        let plain = "/架空の書庫/[架空工房] 月の庭 1.zip"
        let generator = library.makeMetadataGenerator(books: [reference, plain], knownBooks: [reference, plain])
        await generator.update()
        #expect(library.metadata.registeredBookIDs == [plain])
        #expect(generator.listedBookIDs == [plain])
    }

    @Test("書き出しウインドウの一覧に参照ファイルの本は載らず、書き出しも失敗にする")
    func exportExcludesReferenceBooks() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        let viewModel = ExportListViewModel(
            bookmarkStore: harness.library.bookmarks, layoutStore: harness.library.layouts,
            metadataStore: harness.library.metadata, preferences: harness.preferences, loadsEligibleRows: false
        )
        let plain = harness.temporary.file("plain.cbz").path
        viewModel.applyEligibleBookIDs(
            [fixture.referenceURL.path, plain], generation: viewModel.reloadGeneration
        )
        #expect(viewModel.rows.map(\.bookID) == [plain])
        let book = try await FixtureBook.load(fixture.referenceURL)
        let message = await viewModel.exportOpenBook(book, displayState: nil, to: harness.temporary.url)
        #expect(message != nil)
        #expect(viewModel.writtenCount == 0)
        #expect(fixture.pageRequestIndices.isEmpty)
    }

    @Test("お気に入りには参照ファイルの本を登録しない(どの登録口でも)")
    func favoritesRefuseReferenceBooks() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let library = try InMemoryLibrary(label: "stacknest-favorites")
        defer { library.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        for outcome in [library.favorites.addFavorite(book: book, to: nil), library.favorites.forceAddFavorite(book: book, to: nil)] {
            if case .failed = outcome {} else { Issue.record("登録できてしまった: \(outcome)") }
        }
        let bulk = library.favorites.forceAddFavorites([.init(book: book, folder: nil)])
        #expect(bulk.count == 1)
        if case .failed = bulk[0] {} else { Issue.record("一括で登録できてしまった") }
        #expect(library.favorites.totalFavoritesCount() == 0)
    }

    @Test("お気に入り: 参照ファイルの本の判定はパスでも行う(保存データの取り込みが作る本は参照を持たない)")
    func favoritesRefuseReferenceBooksByPath() throws {
        let library = try InMemoryLibrary(label: "stacknest-favorites-path")
        defer { library.close() }
        let temporary = try TemporaryDirectory("stacknest-favorites-path")
        let url = temporary.file("Imported.stacknestbook")
        try Data("{}".utf8).write(to: url)
        // 参照(stackNestReference)を持たず、パスだけが参照ファイルの本。
        let book = MangaBook(id: url.path, title: "Imported", sourceURL: url, pages: [])
        #expect(!book.isStackNestReference)
        for outcome in [library.favorites.addFavorite(book: book, to: nil), library.favorites.forceAddFavorite(book: book, to: nil)] {
            if case .failed = outcome {} else { Issue.record("登録できてしまった: \(outcome)") }
        }
        let bulk = library.favorites.forceAddFavorites([.init(book: book, folder: nil)])
        if case .failed = bulk.first {} else { Issue.record("一括で登録できてしまった") }
        #expect(library.favorites.totalFavoritesCount() == 0)
    }

    @Test("お気に入り: 参照ファイルの本でも、すでにある登録の削除は通る(追加だけを断る)")
    func existingReferenceFavoriteCanBeRemoved() throws {
        let library = try InMemoryLibrary(label: "stacknest-favorites-remove")
        defer { library.close() }
        let temporary = try TemporaryDirectory("stacknest-favorites-remove")
        let url = temporary.file("Old.stacknestbook")
        try Data("{}".utf8).write(to: url)
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        library.context.insert(FavoriteBook(bookID: url.path, bookmarkData: bookmark, title: "Old", folder: nil))
        try library.context.save()
        library.favorites.reload()
        #expect(library.favorites.isFavorited(bookID: url.path))
        library.favorites.removeFavorites(forBookID: url.path)
        #expect(!library.favorites.isFavorited(bookID: url.path))
        #expect(library.favorites.totalFavoritesCount() == 0)
    }

    @Test("参照ファイルの本の振り分け(実ファイルかの確認)は、メインアクターの上で行わない")
    func referenceRoutingCheckRunsOffTheMainActor() async throws {
        let fixture = try StackNestTestBook(pageCount: 2)
        defer { fixture.close() }
        let recorded = ProbeRecord()
        let target = fixture.referenceURL.path
        BookLoader.observeReferenceRoutingForTesting(under: fixture.temporary.url) { url in
            if url.path == target { recorded.note(onMain: Thread.isMainThread) }
        }
        defer { BookLoader.endObservingReferenceRoutingForTesting(under: fixture.temporary.url) }
        // このテストは MainActor の上: 呼び出し側の actor を引き継ぐ BookLoader.load の確認が、ここで走ってしまえば true になる。
        _ = try await BookLoader.load(from: fixture.referenceURL, cachesPageList: false)
        #expect(recorded.count == 1)
        #expect(recorded.onMainCount == 0)
    }

    @Test("参照ファイルと同じ名前のフォルダは、従来どおりフォルダの本として開く")
    func directoryNamedLikeAReferenceOpensAsFolder() async throws {
        let temporary = try TemporaryDirectory("stacknest-folder")
        let folder = temporary.file("Looks Like.stacknestbook")
        try FixtureFolder.make(at: folder, pages: [.init("001.png", number: 1), .init("002.png", number: 2)])
        let book = try await FixtureBook.load(folder)
        #expect(book.stackNestReference == nil)
        #expect(book.pages.count == 2)
    }

    @Test("コレクションへの登録は、参照ファイルを自分でも落とす(呼び出し側の分類に頼らない)")
    func collectionAddingDropsReferenceFiles() async throws {
        let fixture = try StackNestTestBook()
        defer { fixture.close() }
        let library = try InMemoryLibrary(label: "stacknest-collection")
        defer { library.close() }
        let folder = fixture.temporary.file("Plain Book")
        try FixtureFolder.make(at: folder, pages: [.init("001.png", number: 1)])
        let target = try #require(library.collections.libraries.first)
        let collection = try #require(library.collections.createCollection(
            name: "Shelf", in: target, items: await CollectionStore.makePendingItems(for: [folder])
        ))
        let result = await CollectionBookAdding.add(
            [fixture.referenceURL], to: collection.id, collectionStore: library.collections, coverExtractor: nil
        )
        #expect(result == nil)
        #expect(collection.items.count == 1)
        // 対照: 参照ファイルと普通の本が混ざっていても、普通の本だけが数えられる。
        let other = fixture.temporary.file("Other Book")
        try FixtureFolder.make(at: other, pages: [.init("001.png", number: 1)])
        let mixed = await CollectionBookAdding.add(
            [fixture.referenceURL, other], to: collection.id, collectionStore: library.collections, coverExtractor: nil
        )
        #expect(mixed?.requestedCount == 1)
        #expect(collection.items.count == 2)
    }

    // MARK: - 同じ本を表示しているウインドウを前へ出すとき

    @Test("同じパスの参照ファイルを読み直した中身が表示中の本と違うとき(StackNest が新しい鍵で書き直した)だけ、読み込み直す。開く位置・題名だけの違いでは読み込み直さない")
    func rewrittenReferenceNeedsReload() async throws {
        let fixture = try StackNestTestBook(pageCount: 6)
        defer { fixture.close() }
        let shown = try await FixtureBook.load(fixture.referenceURL)
        let unchanged = try StackNestBookReference.load(contentsOf: fixture.referenceURL)
        #expect(!AppState.reloadsForStackNestReference(showing: shown, read: unchanged))
        try fixture.writeReference(pageCount: 6, startPage: 4, title: "Renamed Title")
        let movedOnly = try StackNestBookReference.load(contentsOf: fixture.referenceURL)
        #expect(movedOnly.startPage == 4)
        #expect(!AppState.reloadsForStackNestReference(showing: shown, read: movedOnly))
        try fixture.writeReference(token: "renewed-token-0123456789", pageCount: 6, startPage: 2)
        let rewritten = try StackNestBookReference.load(contentsOf: fixture.referenceURL)
        #expect(AppState.reloadsForStackNestReference(showing: shown, read: rewritten))
    }

    @Test("同じ本を表示しているほかのウインドウを前へ出すとき: StackNest が参照ファイルを書き直していれば、そのウインドウで新しい鍵の本を読み込み直す。中身が同じ本・参照ファイルでない本は読み込み直さない")
    func existingWindowReloadsARewrittenReference() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let library = try InMemoryLibrary(label: "stacknest-reopen")
        defer { library.close() }
        let suite = PreferencesSuite(label: "stacknest-reopen")
        let preferences = suite.makePreferences()
        let recentFiles = RecentFilesStore(defaults: suite.defaults)
        // 同じ本を表示しているほかのウインドウ(LaunchCoordinator.openAppState(forBookAt:) が見つけるもの)の AppState。
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        state.preferences = preferences
        state.favoritesStore = library.favorites
        state.bookmarkStore = library.bookmarks
        state.layoutStore = library.layouts
        state.metadataStore = library.metadata
        state.recentFiles = recentFiles
        let request = BookOpenRequest(fixture.referenceURL)
        state.open(request: request)
        await state.openTask?.value
        let opened = try #require(state.currentBook)
        #expect(opened.stackNestReference?.token == StackNestTestBook.token)
        // 「直前の本へ戻る」は淡色(開き直すのは StackNest から)。置き場所の無い本なので、前後の本へは進まず理由を知らせ、
        // 同じフォルダの本も探さない。
        #expect(state.lastOpenedBook?.comesFromStackNest == true)
        #expect(!state.canReopenLastBook)
        #expect(state.takeLastBookForHomeSelection() == nil)
        // 前へ・次へのどちらも、それぞれ理由を知らせる(片方が黙って何もしない形を見逃さないよう、1 回ずつ確かめる)。
        let expectedNotice = AppState.noBrowsableLocationNotice(locale: preferences.effectiveLocale)
        state.openSibling(after: fixture.referenceURL)
        let afterNotice = try #require(state.viewerNotice)
        #expect(afterNotice.message == expectedNotice)
        state.openSibling(before: fixture.referenceURL)
        let beforeNotice = try #require(state.viewerNotice)
        #expect(beforeNotice.message == expectedNotice)
        #expect(beforeNotice.id != afterNotice.id)
        #expect(state.siblingBooks.isEmpty)
        #expect(state.currentBook?.viewerIdentity == opened.viewerIdentity)

        // 中身が同じ(同じ鍵): 今までどおり前へ出すだけ。開き直すと manifest を問い合わせるので、その数で見る。
        let manifestsBefore = fixture.manifestRequestCount
        await state.reloadIfStackNestReferenceChanged(request)?.value
        await state.openTask?.value
        #expect(fixture.manifestRequestCount == manifestsBefore)
        #expect(state.currentBook?.viewerIdentity == opened.viewerIdentity)

        // StackNest が同じパスへ新しい鍵で書き直した(施錠を変えた後に StackNest から開き直した): そのウインドウで読み込み直す。
        try fixture.writeReference(token: "renewed-token-0123456789", pageCount: 6, startPage: 3)
        await state.reloadIfStackNestReferenceChanged(request)?.value
        await state.openTask?.value
        #expect(state.currentBook?.id == opened.id)
        #expect(state.currentBook?.stackNestReference?.token == "renewed-token-0123456789")
        #expect(state.currentBook?.viewerIdentity != opened.viewerIdentity)
        #expect(fixture.manifestRequestCount == manifestsBefore + 1)

        // 参照ファイルでない本は、今までどおり前へ出すだけ(参照ファイルを読みにも行かない)。
        let folder = fixture.temporary.file("Plain Book")
        try FixtureFolder.make(at: folder, pages: [.init("001.png", number: 1)])
        let plainRequest = BookOpenRequest(folder)
        state.open(request: plainRequest)
        await state.openTask?.value
        #expect(state.currentBook?.sourceURL.path == folder.path)
        #expect(state.reloadIfStackNestReferenceChanged(plainRequest) == nil)
        // 履歴に残るのはフォルダの本だけ(StackNest の本は記録を残さない ―― MangaBook.leavesNoRecord)。
        await recentFiles.waitForPendingRecords()
        #expect(recentFiles.entries.map(\.path) == [folder.path])
        // 「直前の本へ戻る」: StackNest の本の後は淡色、フォルダの本の後は押せる。
        #expect(state.canReopenLastBook)
        withExtendedLifetime((preferences, recentFiles)) {}
    }

    @Test("参照ファイルを読んでいる間に、このウインドウで後から頼まれた本が勝つ: 読み終えても古い本を読み込み直さず、後の本を取り消さない")
    func laterOpenWinsOverAPendingReferenceReload() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let library = try InMemoryLibrary(label: "stacknest-reopen-order")
        defer { library.close() }
        let suite = PreferencesSuite(label: "stacknest-reopen-order")
        let preferences = suite.makePreferences()
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        state.preferences = preferences
        state.favoritesStore = library.favorites
        state.bookmarkStore = library.bookmarks
        state.layoutStore = library.layouts
        state.metadataStore = library.metadata
        let recentFiles = RecentFilesStore(defaults: suite.defaults)
        state.recentFiles = recentFiles
        let request = BookOpenRequest(fixture.referenceURL)
        state.open(request: request)
        await state.openTask?.value
        #expect(state.currentBook?.stackNestReference?.token == StackNestTestBook.token)
        let folder = fixture.temporary.file("Plain Book")
        try FixtureFolder.make(at: folder, pages: [.init("001.png", number: 1)])

        // StackNest が書き直した参照ファイルを読みに行く。読み終える前に(Task はまだ動いていない)、このウインドウで
        // 待ってから開く入口が別の本を頼む。
        try fixture.writeReference(token: "renewed-token-0123456789", pageCount: 6, startPage: 3)
        let manifestsBefore = fixture.manifestRequestCount
        let reload = state.reloadIfStackNestReferenceChanged(request)
        let newer = state.beginOpenIntent()
        await reload?.value
        await state.openTask?.value
        // 読み終えた後で古い本を読み込み直さない。
        #expect(fixture.manifestRequestCount == manifestsBefore)
        #expect(state.currentBook?.stackNestReference?.token == StackNestTestBook.token)

        // 後から頼まれた本は、読み込み直しに取り消されずに開く。
        state.open(request: BookOpenRequest(folder), intent: newer)
        await state.openTask?.value
        #expect(state.currentBook?.sourceURL.path == folder.path)
        withExtendedLifetime((preferences, recentFiles)) {}
    }

    @Test("読み込み直しが要らない(参照ファイルが同じ)ときは、このウインドウで先に待っていた「開く」を捨てさせない")
    func unchangedReferenceDoesNotDropAPendingOpen() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let library = try InMemoryLibrary(label: "stacknest-reopen-pending")
        defer { library.close() }
        let suite = PreferencesSuite(label: "stacknest-reopen-pending")
        let preferences = suite.makePreferences()
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        state.preferences = preferences
        state.favoritesStore = library.favorites
        state.bookmarkStore = library.bookmarks
        state.layoutStore = library.layouts
        state.metadataStore = library.metadata
        let recentFiles = RecentFilesStore(defaults: suite.defaults)
        state.recentFiles = recentFiles
        let request = BookOpenRequest(fixture.referenceURL)
        state.open(request: request)
        await state.openTask?.value
        // このウインドウで、待ってから開く入口が先に待ち始めている(兄弟の探索など)。
        let pending = state.beginOpenIntent()
        // その間に、同じ本を開く別の要求が来た(参照ファイルは書き直されていない)。
        await state.reloadIfStackNestReferenceChanged(request)?.value
        await state.openTask?.value
        // 先に待っていた入口は、まだ開いてよい。
        #expect(state.isStillWanted(pending))
        withExtendedLifetime((preferences, recentFiles)) {}
    }

    @Test("読み込み直しは、頼んだ側の一覧の並びを持ち込まない(このウインドウの並びのまま)")
    func reloadKeepsThisWindowsSequence() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let library = try InMemoryLibrary(label: "stacknest-reopen-sequence")
        defer { library.close() }
        let suite = PreferencesSuite(label: "stacknest-reopen-sequence")
        let preferences = suite.makePreferences()
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        state.preferences = preferences
        state.favoritesStore = library.favorites
        state.bookmarkStore = library.bookmarks
        state.layoutStore = library.layouts
        state.metadataStore = library.metadata
        let recentFiles = RecentFilesStore(defaults: suite.defaults)
        state.recentFiles = recentFiles
        state.open(request: BookOpenRequest(fixture.referenceURL))
        await state.openTask?.value
        #expect(state.bookSequence == nil)
        // 別のウインドウの一覧(並び)から同じ本が頼まれ、StackNest は参照ファイルを書き直していた。
        let sequence = try #require(BookSequence(
            entries: [.file(path: fixture.referenceURL.path), .file(path: fixture.temporary.file("Other.cbz").path)], position: 0
        ))
        let foreign = BookOpenRequest(fixture.referenceURL, sequence: sequence)
        try fixture.writeReference(token: "renewed-token-0123456789", pageCount: 6, startPage: 2)
        await state.reloadIfStackNestReferenceChanged(foreign)?.value
        await state.openTask?.value
        #expect(state.currentBook?.stackNestReference?.token == "renewed-token-0123456789")
        #expect(state.bookSequence == nil)
        withExtendedLifetime((preferences, recentFiles)) {}
    }

    @Test("保存データの取り込みは、参照ファイルの本の行を作らず、StackNest にも問い合わせない(記録を残さない本)")
    func importSkipsReferenceBooks() async throws {
        let fixture = try StackNestTestBook(pageCount: 5)
        defer { fixture.close() }
        let library = try InMemoryLibrary(label: "stacknest-import")
        defer { library.close() }
        let path = fixture.referenceURL.path
        var file = QooLibraryExportFile(
            bookmarks: [ExportedBookmarkEntry(bookID: path, bookmarks: [ExportedBookmark(page: "000001.jpg", name: "x")])]
        )
        // 読書位置とメタデータも(本を読み込まずに行を書くカテゴリ)。
        file.readingStates = [ExportedBookReadingState(
            bookID: path, inodeNumber: nil, volumeDeviceNumber: nil, volumeUUID: nil, lastPageIndex: 2, lastPageKey: "000002.jpg",
            displayMode: DisplayMode.spread.rawValue, readingDirection: ReadingDirection.rightToLeft.rawValue,
            scalingMode: ScalingMode.fitWidth.rawValue, updatedAt: Date(), recordedPageCount: 5,
            recordedSourceModificationDate: nil, recordedSourceFileSize: nil, isAtLastPage: false
        )]
        file.metadata = [ExportedBookMetadataEntry(
            bookID: path, author: "著者", title: "題名", series: "シリーズ", seriesIndex: "1"
        )]
        let summary = await library.apply(file, policies: .all(.merge))
        // 見つからなかった本としては数えず、StackNest の本として 1 冊数える。
        #expect(summary.bookmarksSkippedBookIDs.isEmpty)
        #expect(summary.stackNestSkippedBooks == 1)
        #expect(library.bookmarkRows(forBookID: path).isEmpty)
        let states = (try? library.context.fetch(FetchDescriptor<BookReadingState>())) ?? []
        #expect(!states.contains { $0.bookID == path })
        #expect(library.metadata.metadata(forBookID: path) == nil)
        #expect(fixture.requests.isEmpty)
    }

    @Test("サイドパネルの本の中身ブラウザは、StackNest の本のページを平坦な 1 階層で並べ、押すとそのページへ(StackNest へは問い合わせない)")
    func bookContentsListsThePages() async throws {
        let fixture = try StackNestTestBook(pageCount: 4, startPage: 0)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let requestsAfterLoad = fixture.requests.count
        let state = try #require(await BookContentsBrowserState.make(book: book))
        defer { state.releaseResources() }
        await state.waitUntilListed()
        #expect(state.entries.map(\.matchKey) == book.pages.map(\.sortKey))
        #expect(state.entries.allSatisfy { $0.isImage && $0.navigateTarget == nil })
        #expect(state.currentLocationName == nil)
        if case .jumpToPage(let index) = state.resolveImageClick(on: state.entries[2], bookPages: book.pages) {
            #expect(index == 2)
        } else {
            Issue.record("ページへ移らなかった")
        }
        #expect(fixture.requests.count == requestsAfterLoad)
    }

    @Test("コレクションの登録の要(makePendingItem)は、実ファイルの参照ファイルを断る(同じ名前のフォルダは本として通す)")
    func pendingItemRefusesReferenceFiles() throws {
        let fixture = try StackNestTestBook()
        defer { fixture.close() }
        #expect(CollectionStore.makePendingItem(for: fixture.referenceURL) == nil)
        let folder = fixture.temporary.file("Looks Like.stacknestbook")
        try FixtureFolder.make(at: folder, pages: [.init("001.png", number: 1)])
        #expect(CollectionStore.makePendingItem(for: folder) != nil)
    }

    @Test("起動時の掃除は参照ファイルの本を見ない(フォルダでありうる本の候補に入れない)")
    func sweepersSkipReferenceBooks() {
        let reference = "/架空の置き場/Sample Book.stacknestbook"
        let folder = "/架空の棚/月の庭"
        #expect(NonBookFolderSweeper.candidates(in: [reference, folder]) == [folder])
    }
}

/// 書き出しの 1 冊が実際に書かれたかを数える(書き込みは差し替え)。
private final class ExportListViewModel: BookExportViewModel {
    override var format: BookExportFormat { .cbz }
    private(set) var writtenCount = 0
    override func export(_ prepared: PreparedBook, to destinationURL: URL) async throws { writtenCount += 1 }
}

/// 覗き窓が呼ばれたスレッドの記録。
private nonisolated final class ProbeRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Bool] = []

    func note(onMain: Bool) { lock.withLock { calls.append(onMain) } }
    var count: Int { lock.withLock { calls.count } }
    var onMainCount: Int { lock.withLock { calls.filter { $0 }.count } }
}

import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting
import Testing

@testable import qooViewer

/// StackNest が manifest で返すページの名前(`?pageNames=1`)と本の同一性(`bookIdentity`)。名前はエントリのパス・ページの鍵・
/// 中身ブラウザのフォルダになり、ページを取る番号・書き戻す番号は名前から引く(StackNestPageMap)。
@MainActor
struct StackNestPageNamesTests {
    /// StackNest の番号の順の名前(書庫の中のパス。StackNest は書庫の中のパスを自然順に並べる)。
    static let names = ["第1話/001.jpg", "第1話/002.png", "第2話/001.jpg", "第2話/002.jpg", "あとがき.jpg"]

    @Test("名前を返す StackNest: ページの名前・鍵・表示名は実際の名前、並びは StackNest の番号順、同一性も持つ")
    func pagesUseTheRealNames() async throws {
        let fixture = try StackNestTestBook(pageCount: 5, pageNames: Self.names, bookIdentity: "sn1-fixture")
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        #expect(book.pages.map(\.sortKey) == Self.names)
        #expect(book.pages.map(\.displayName) == ["001.jpg", "002.png", "001.jpg", "002.jpg", "あとがき.jpg"])
        #expect(book.pageOrderSource == .document)
        #expect(book.stackNestPages?.usesRealNames == true)
        #expect(book.stackNestBookIdentity == "sn1-fixture")
        #expect(book.stackNestPageIndex(forKey: "第2話/001.jpg") == 2)
        #expect(book.stackNestPageKey(forPage: 4) == "あとがき.jpg")
        // manifest は名前を頼む形で 1 回だけ。
        let manifest = try #require(fixture.requests.first { $0.route == .manifest })
        #expect(manifest.url.query == "pageNames=1")
        #expect(fixture.manifestRequestCount == 1)
        // 場所は書庫の中のフォルダ(PageRef.location)。
        #expect(book.pages[2].location(inBookAt: book.sourceURL).folderPath == "第2話")
    }

    @Test("名前を返さない StackNest(古い版)では、これまでどおり番号の仮の名前")
    func olderStackNestKeepsSyntheticNames() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        #expect(book.pages.map(\.sortKey) == (0..<3).map(StackNestPageNaming.entryName(forPage:)))
        #expect(book.stackNestPages?.usesRealNames == false)
        #expect(book.stackNestBookIdentity == nil)
    }

    @Test("ページは名前から引いた番号で取る(仮の名前と同じ形の実際の名前でも、名前の番号では読まない)")
    func pagesAreFetchedByTheNumberLookedUpFromTheName() async throws {
        // 書庫の中の名前が仮の名前と同じ形で、番号がずれている本(000001.jpg が 0 番)。
        let tricky = ["000001.jpg", "000002.jpg", "000003.jpg"]
        let fixture = try StackNestTestBook(pageCount: 3, pageNames: tricky)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let reader = try StackNestReferenceReader(
            reference: try #require(book.stackNestReference), at: fixture.referenceURL, pageMap: book.stackNestPages)
        let data = try await reader.pageData(at: "000001.jpg", priority: .display)
        #expect(PageColorReader.matches(data, number: 1), "0 番(R = 番号 + 1)")
        #expect(fixture.pageRequestIndices == [0])
        await #expect(throws: ArchiveReaderError.self) { try await reader.pageData(at: "000000.jpg", priority: .display) }
        // 表を持たない reader(サムネイルの下調べなど)は、一覧を取った後はセッションの manifest の表で引く(同期の口は FileIO の上で)。
        let url = fixture.referenceURL
        let (listed, third) = try await FileIO.perform {
            let plain = try StackNestReferenceReader(referenceFileURL: url)
            return (try plain.listFilePaths(), try plain.data(at: "000003.jpg"))
        }
        #expect(listed == tricky)
        #expect(PageColorReader.matches(third, number: 3))
    }

    @Test("書き戻す番号は名前から引く(除外・並べ替えの後の位置ではない)")
    func progressUsesTheNumberOfTheName() async throws {
        let fixture = try StackNestTestBook(pageCount: 5, startPage: 2, pageNames: Self.names)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        harness.library.layouts.setPageLayoutState(for: book, pageKey: book.pages[0].sortKey, state: .excluded)
        let viewer = await harness.openInWindow(book)
        // 開くページは参照ファイルの startPage(StackNest の 2 番 = 第2話/001.jpg)。
        #expect(viewer.book.pages[viewer.currentIndex].sortKey == "第2話/001.jpg")
        viewer.jump(toPageIndex: 0)
        await viewer.settle()
        viewer.flushPendingSave()
        await viewer.stackNestProgress?.waitUntilIdle()
        #expect(fixture.progressPages == [1], "今の並びの 0 番目は StackNest の 1 番(第1話/002.png)")
    }

    @Test("中身ブラウザは書庫の中のフォルダを辿れ、押すとそのページへ(StackNest へは問い合わせない)。今のページのフォルダへ追従する")
    func bookContentsBrowsesTheFolders() async throws {
        let fixture = try StackNestTestBook(pageCount: 5, pageNames: Self.names)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let requestsAfterLoad = fixture.requests.count
        let state = try #require(await BookContentsBrowserState.make(book: book))
        defer { state.releaseResources() }
        // 並びはビューアのページ順(サイドパネルが流し込む)。
        state.pageOrder = Dictionary(uniqueKeysWithValues: book.pages.enumerated().map { ($1.sortKey, $0) })
        await state.waitUntilListed()
        #expect(state.entries.map(\.displayName) == ["第1話", "第2話", "あとがき.jpg"])
        #expect(state.entries[0].isContainer)
        state.navigate(state.entries[1])
        await state.waitUntilListed()
        #expect(state.currentLocationName == "第2話")
        #expect(state.entries.map(\.matchKey) == ["第2話/001.jpg", "第2話/002.jpg"])
        if case .jumpToPage(let index) = state.resolveImageClick(on: state.entries[1], bookPages: book.pages) {
            #expect(index == 3)
        } else {
            Issue.record("ページへ移らなかった")
        }
        state.goBack()
        await state.waitUntilListed()
        #expect(state.currentLocationName == nil)
        // 今のページ(第1話/002.png)を見せると、そのフォルダへ入る。
        state.revealCurrentPage(sortKeys: ["第1話/002.png"])
        await state.waitUntilListed()
        #expect(state.currentLocationName == "第1話")
        #expect(state.highlightedMatchKeys == ["第1話/002.png"])
        #expect(fixture.requests.count == requestsAfterLoad)
    }

    @Test(
        "使えない名前の一覧は、一覧ごと仮の名前に戻す(.. を含む・揃えると重なる)。./ と先頭の / は落とす",
        arguments: [
            (["a/../b.jpg", "c.jpg"], nil),
            (["./a.jpg", "a.jpg"], nil),
            (["/a.jpg", "a.jpg"], nil),
            (["./a.jpg", "/x//b.jpg"], ["a.jpg", "x/b.jpg"]),
            ([".", "b.jpg"], nil),
        ] as [([String], [String]?)]
    )
    func namesAreNormalizedOrDropped(names: [String], expected: [String]?) {
        #expect(StackNestPageMap.normalizedEntryNames(names, pageCount: names.count) == expected)
        let map = StackNestPageMap(names: names, pageCount: names.count)
        #expect(map.usesRealNames == (expected != nil))
        #expect(map.entryNames == (expected ?? StackNestPageNaming.entryNames(pageCount: names.count)))
    }
}

/// StackNest でいっしょに渡された本(参照ファイルの handoff → AppDelegate が並びにする)。置き場所の無い本でも、並びがあれば
/// 前の本・次の本をたどれる(AppState.hasAdjacentBooks・openSibling)。
@MainActor
struct StackNestHandoffSequenceTests {
    @Test("並びのある StackNest の本は「次の本へ」で並びの次の参照ファイルを開き、並びの無い本は今までどおり断る")
    func nextBookFollowsTheSequence() async throws {
        let first = try StackNestTestBook(pageCount: 3, label: "stacknest-seq-1", pageNames: ["a.jpg", "b.jpg", "c.jpg"])
        defer { first.close() }
        let second = try StackNestTestBook(pageCount: 2, label: "stacknest-seq-2", fileName: "Second Book.stacknestbook")
        defer { second.close() }
        let library = try InMemoryLibrary(label: "stacknest-sequence")
        defer { library.close() }
        let suite = PreferencesSuite(label: "stacknest-sequence")
        let preferences = suite.makePreferences()
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        state.preferences = preferences
        state.favoritesStore = library.favorites
        state.bookmarkStore = library.bookmarks
        state.layoutStore = library.layouts
        state.metadataStore = library.metadata
        let recentFiles = RecentFilesStore(defaults: suite.defaults)
        state.recentFiles = recentFiles

        // 並びの無い本: 前後の本は無い。
        state.open(request: BookOpenRequest(first.referenceURL))
        await state.openTask?.value
        #expect(state.bookSequence == nil)
        #expect(!state.hasAdjacentBooks)

        // 組で渡された本(先頭を開き、2 冊を並びにする)。
        let sequence = try #require(BookSequence(
            entries: [.file(path: first.referenceURL.path), .file(path: second.referenceURL.path)], position: 0))
        state.open(request: BookOpenRequest(first.referenceURL, sequence: sequence))
        await state.openTask?.value
        #expect(state.bookSequence == sequence)
        #expect(state.hasAdjacentBooks)
        state.openSibling(after: first.referenceURL)
        let deadline = ContinuousClock.now + .seconds(20)
        while state.currentBook?.sourceURL != second.referenceURL, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            await state.openTask?.value
        }
        #expect(state.currentBook?.sourceURL == second.referenceURL)
        #expect(state.bookSequence?.position == 1)
        #expect(second.manifestRequestCount == 1)
        withExtendedLifetime((preferences, recentFiles)) {}
    }

    private func makeState(label: String) throws -> (AppState, InMemoryLibrary, AnyObject) {
        let library = try InMemoryLibrary(label: label)
        let suite = PreferencesSuite(label: label)
        let preferences = suite.makePreferences()
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        state.preferences = preferences
        state.favoritesStore = library.favorites
        state.bookmarkStore = library.bookmarks
        state.layoutStore = library.layouts
        state.metadataStore = library.metadata
        let recentFiles = RecentFilesStore(defaults: suite.defaults)
        state.recentFiles = recentFiles
        return (state, library, [preferences, recentFiles] as NSArray)
    }

    @Test("並びの途中の StackNest の本が開けなければ(StackNest が断る)、飛ばして次の本を開く")
    func nextBookSkipsAStackNestBookThatFails() async throws {
        let first = try StackNestTestBook(pageCount: 2, label: "stacknest-skip-1")
        defer { first.close() }
        let broken = try StackNestTestBook(pageCount: 2, label: "stacknest-skip-2", fileName: "Broken.stacknestbook")
        defer { broken.close() }
        let third = try StackNestTestBook(pageCount: 2, label: "stacknest-skip-3", fileName: "Third.stacknestbook")
        defer { third.close() }
        broken.server.respond(.manifest, with: .status(404))
        let (state, library, keep) = try makeState(label: "stacknest-skip")
        defer { library.close() }
        let sequence = try #require(BookSequence(
            entries: [first, broken, third].map { .file(path: $0.referenceURL.path) }, position: 0))
        state.open(request: BookOpenRequest(first.referenceURL, sequence: sequence))
        await state.openTask?.value
        #expect(state.currentBook?.sourceURL == first.referenceURL)

        state.openSibling(after: first.referenceURL)
        let deadline = ContinuousClock.now + .seconds(20)
        while state.currentBook?.sourceURL != third.referenceURL, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            await state.openTask?.value
        }
        #expect(state.currentBook?.sourceURL == third.referenceURL)
        #expect(state.bookSequence?.position == 2)
        withExtendedLifetime(keep) {}
    }

    @Test("組の先頭が開けなければ、組の次の本を開く(先頭も並びをたどる一歩として開く)")
    func aFailingFirstBookOfAGroupFallsThroughToTheNext() async throws {
        let broken = try StackNestTestBook(pageCount: 2, label: "stacknest-head-1", fileName: "Broken.stacknestbook")
        defer { broken.close() }
        let second = try StackNestTestBook(pageCount: 2, label: "stacknest-head-2", fileName: "Second.stacknestbook")
        defer { second.close() }
        broken.server.respond(.manifest, with: .status(404))
        let (state, library, keep) = try makeState(label: "stacknest-head")
        defer { library.close() }
        let sequence = try #require(BookSequence(
            entries: [broken, second].map { .file(path: $0.referenceURL.path) }, position: 0, title: .openedTogether))
        var request = BookOpenRequest(broken.referenceURL, sequence: sequence)
        request.adoptsSequenceInOpenWindow = true
        state.open(request: request)
        await state.openTask?.value
        #expect(state.currentBook?.sourceURL == second.referenceURL)
        #expect(state.bookSequence?.position == 1)
        // ふつうの並び(組でない)の先頭は、これまでどおり飛ばさない(開けなければ知らせて止まる)。
        let (plainState, plainLibrary, plainKeep) = try makeState(label: "stacknest-head-plain")
        defer { plainLibrary.close() }
        plainState.open(request: BookOpenRequest(broken.referenceURL, sequence: sequence))
        await plainState.openTask?.value
        #expect(plainState.currentBook == nil)
        withExtendedLifetime((keep, plainKeep)) {}
    }

    @Test(
        "並びをたどるときに飛ばすのは、その本だけの失敗(StackNest 全体の失敗では止まる)",
        arguments: [
            (StackNestViewerError.Code.bookNotFound, true), (.expired, true), (.unauthorized, true), (.invalidResponse, true),
            (.cannotConnect, false), (.libraryLocked, false), (.hostNotAllowed, false), (.remoteUnavailable, false),
        ] as [(StackNestViewerError.Code, Bool)])
    func skipsOnlyPerBookFailures(code: StackNestViewerError.Code, skips: Bool) {
        let reference = URL(fileURLWithPath: "/tmp/x/Book.stacknestbook")
        let error = StackNestOpenError(error: StackNestViewerError(code))
        #expect(AppState.skipsWhileStepping(error, book: reference, inSequence: true) == skips)
        #expect(!AppState.skipsWhileStepping(error, book: reference, inSequence: false))
        #expect(!AppState.skipsWhileStepping(CancellationError(), book: reference, inSequence: true))
        #expect(!AppState.skipsWhileStepping(error, book: URL(fileURLWithPath: "/tmp/x/Book.cbz"), inSequence: true))
    }

    @Test("組の先頭がもうこのウインドウで開いていれば、前へ出すときにこのウインドウの並びを組に替える(ふつうの一覧の並びは替えない)")
    func anOpenWindowTakesTheGroupsSequence() async throws {
        let first = try StackNestTestBook(pageCount: 2, label: "stacknest-adopt-1")
        defer { first.close() }
        let second = try StackNestTestBook(pageCount: 2, label: "stacknest-adopt-2", fileName: "Second.stacknestbook")
        defer { second.close() }
        let (state, library, keep) = try makeState(label: "stacknest-adopt")
        defer { library.close() }
        state.open(request: BookOpenRequest(first.referenceURL))
        await state.openTask?.value
        #expect(state.bookSequence == nil)
        let sequence = try #require(BookSequence(
            entries: [first, second].map { .file(path: $0.referenceURL.path) }, position: 0))

        // ふつうの一覧の並び(よそのウインドウのもの)は持ち込まない。
        await state.reloadIfStackNestReferenceChanged(BookOpenRequest(first.referenceURL, sequence: sequence))?.value
        #expect(state.bookSequence == nil)
        // 組の並びは持ち込む(参照ファイルは同じなので読み込み直さない)。
        var grouped = BookOpenRequest(first.referenceURL, sequence: sequence)
        grouped.adoptsSequenceInOpenWindow = true
        await state.reloadIfStackNestReferenceChanged(grouped)?.value
        #expect(state.bookSequence == sequence)
        #expect(state.hasAdjacentBooks)
        withExtendedLifetime(keep) {}
    }
}

/// StackNest の本の履歴(2026-10-19、案 A): 参照ファイルではなく「もう一度渡してもらう頼み」(stacknest://viewer/reopen)を残し、
/// 開くと StackNest へ頼む(本はその後 StackNest から届く)。
@MainActor
struct StackNestHistoryTests {
    private func makeState(label: String, isPrivate: Bool = false)
        throws -> (AppState, RecentFilesStore, InMemoryLibrary, AnyObject)
    {
        let library = try InMemoryLibrary(label: label)
        let suite = PreferencesSuite(label: label)
        let preferences = suite.makePreferences()
        let state = AppState(isPrivateWindow: isPrivate, usesPageListCache: false)
        state.preferences = preferences
        state.favoritesStore = library.favorites
        state.bookmarkStore = library.bookmarks
        state.layoutStore = library.layouts
        state.metadataStore = library.metadata
        let recentFiles = RecentFilesStore(defaults: suite.defaults)
        state.recentFiles = recentFiles
        return (state, recentFiles, library, [preferences, suite] as NSArray)
    }

    @Test("同一性のある StackNest の本は、頼みの URL と題名で履歴に残る(参照ファイルのパスは残さない)")
    func recordsTheReopenRequest() async throws {
        let fixture = try StackNestTestBook(pageCount: 2, title: "Synthetic Title", label: "stacknest-history",
                                            bookIdentity: "sn1-history-fixture")
        defer { fixture.close() }
        let (state, recentFiles, library, keep) = try makeState(label: "stacknest-history")
        defer { library.close() }
        state.open(request: BookOpenRequest(fixture.referenceURL))
        await state.openTask?.value
        await recentFiles.waitForPendingRecords()
        let entry = try #require(recentFiles.entries.first)
        #expect(recentFiles.entries.count == 1)
        let request = try #require(entry.stackNestReopen)
        #expect(request.bookIdentity == "sn1-history-fixture")
        #expect(entry.path == request.url.absoluteString)
        #expect(entry.displayName == "Synthetic Title")
        #expect(!entry.hasFileLocation)
        #expect(entry.locationText == "StackNest/Synthetic Title")
        // 開き直しても 1 行のまま(同じ本は同じ頼み)。
        state.open(request: BookOpenRequest(fixture.referenceURL))
        await state.openTask?.value
        await recentFiles.waitForPendingRecords()
        #expect(recentFiles.entries.count == 1)
        withExtendedLifetime(keep) {}
    }

    @Test("同一性の無い StackNest の本・シークレットウインドウでは履歴に残さない")
    func doesNotRecordWithoutIdentityOrInPrivateWindows() async throws {
        let plain = try StackNestTestBook(pageCount: 2, label: "stacknest-history-plain")
        defer { plain.close() }
        let (state, recentFiles, library, keep) = try makeState(label: "stacknest-history-plain")
        defer { library.close() }
        state.open(request: BookOpenRequest(plain.referenceURL))
        await state.openTask?.value
        await recentFiles.waitForPendingRecords()
        #expect(recentFiles.entries.isEmpty)

        let identified = try StackNestTestBook(pageCount: 2, label: "stacknest-history-private", bookIdentity: "sn1-private")
        defer { identified.close() }
        let (privateState, privateRecents, privateLibrary, keepPrivate) = try makeState(
            label: "stacknest-history-private", isPrivate: true)
        defer { privateLibrary.close() }
        privateState.open(request: BookOpenRequest(identified.referenceURL))
        await privateState.openTask?.value
        await privateRecents.waitForPendingRecords()
        #expect(privateRecents.entries.isEmpty)
        withExtendedLifetime((keep, keepPrivate)) {}
    }

    @Test("履歴から開くと StackNest へ頼みの URL を出して知らせ、行は残す。再検証でも消えず、削除はその行だけ")
    func openingAsksStackNest() async throws {
        let suite = PreferencesSuite(label: "stacknest-history-open")
        let recentFiles = RecentFilesStore(defaults: suite.defaults)
        let request = try StackNestReopenRequest(
            libraryUUID: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", bookID: 3, bookIdentity: "sn1-open")
        let other = try StackNestReopenRequest(
            libraryUUID: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", bookID: 4, bookIdentity: "sn1-other")
        await recentFiles.recordStackNestBook(other, title: "Other").value
        await recentFiles.recordStackNestBook(request, title: "Asked").value
        final class Opened { var urls: [URL] = [] }
        let opened = Opened()
        recentFiles.openStackNestRequest = { url in opened.urls.append(url); return true }
        let entry = try #require(recentFiles.entries.first)
        var reports: [String] = []
        var bodyCalled = false
        await recentFiles.resolveForOpening(entry, locale: Locale(identifier: "en"), report: { reports.append($0) }) { _ in
            bodyCalled = true
        }.value
        #expect(opened.urls == [request.url])
        #expect(!bodyCalled, "本は StackNest から届く(ここでは開かない)")
        #expect(reports.count == 1 && reports[0].contains("Asked"))
        #expect(await recentFiles.resolveForOpening(entry) == .failure(.handledByStackNest))
        #expect(recentFiles.entries.count == 2)

        // 開けない(StackNest が無い・古い)ときはそう知らせる。
        recentFiles.openStackNestRequest = { _ in false }
        reports = []
        await recentFiles.resolveForOpening(entry, locale: Locale(identifier: "en"), report: { reports.append($0) }) { _ in }
            .value
        #expect(reports.count == 1 && reports[0].contains("StackNest"))

        recentFiles.remove(entry)
        #expect(recentFiles.entries.map(\.displayName) == ["Other"])
        withExtendedLifetime(suite) {}
    }
}

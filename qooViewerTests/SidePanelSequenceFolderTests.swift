import Foundation
import Testing

@testable import qooViewer

/// サイドパネルのフォルダブラウザが、画面に出ている本の並び(`BookSequence`)を仮想のフォルダとして出す(2026-10-19)。
///
/// 見るのは 3 つ: 並びの値(見出し・行の名前)、`SidePanelBrowserState` の仮想のフォルダ(行・今の行・移動の淡色・実のフォルダへの
/// 戻り)、`AppState` の画面の並び(`shownBookSequence` ―― 本が画面に出たときだけ変わる)と行を押したとき(`openSequenceEntry(at:)`)。
/// ビューアの受け渡し(ViewerHandoff)は画面の側なので、ここでは ContentView の代わりに `noteShownBook` を呼ぶ。
///
/// 名前はすべて合成のもの(CLAUDE.md の個人情報の約束)。待ち合わせは `sequenceTask` / `openTask`(時間で待たない)。
@MainActor
struct SidePanelSequenceFolderTests {
    private struct Environment {
        let library: InMemoryLibrary
        let suite: PreferencesSuite
        let preferences: AppPreferences
        let recentFiles: RecentFilesStore
        let temporary: TemporaryDirectory

        init(_ label: String) throws {
            library = try InMemoryLibrary(label: label)
            suite = PreferencesSuite(label: label)
            preferences = suite.makePreferences()
            recentFiles = RecentFilesStore(defaults: suite.defaults)
            temporary = try TemporaryDirectory(label)
        }

        func close() { library.close() }

        func makeAppState() -> AppState {
            let state = AppState(isPrivateWindow: false, usesPageListCache: false)
            state.preferences = preferences
            state.favoritesStore = library.favorites
            state.bookmarkStore = library.bookmarks
            state.layoutStore = library.layouts
            state.metadataStore = library.metadata
            state.recentFiles = recentFiles
            return state
        }

        func makeBrowser() -> SidePanelBrowserState {
            let browser = SidePanelBrowserState(changeCenter: FileSystemChangeCenter(), observesSystem: false)
            browser.preferences = preferences
            return browser
        }

        /// 画像を並べたフォルダの本。
        func makeFolder(_ name: String) throws -> URL {
            let directory = temporary.file(name)
            try FixtureFolder.make(at: directory, pages: [.init("p01.png", number: 1), .init("p02.png", number: 2)])
            return directory
        }
    }

    /// 本を開いて読み込みを待ち、ContentView の代わりに「画面に出た」と知らせる。
    private func openAndShow(_ request: BookOpenRequest, in state: AppState) async {
        state.open(request: request)
        await state.openTask?.value
        state.noteShownBook(state.currentBook)
    }

    // MARK: - 並びの値

    @Test("行の名前は記録してあるパスの最後の成分で、StackNest の参照ファイルは拡張子を外す")
    func entryNames() {
        #expect(BookSequence.displayName(of: .file(path: "/tmp/shelf/Sample Book 01")) == "Sample Book 01")
        #expect(BookSequence.displayName(of: .file(path: "/tmp/shelf/Sample Book 02.cbz")) == "Sample Book 02.cbz")
        #expect(BookSequence.displayName(of: .file(path: "/tmp/handoff/Sample Remote.stacknestbook")) == "Sample Remote")
        #expect(BookSequence.displayName(of: .collectionItem(id: UUID(), path: "/tmp/shelf/Sample Book 03.pdf"))
            == "Sample Book 03.pdf")
    }

    @Test("見出しは出どころから組み、位置を動かしても出どころは同じ")
    func titles() throws {
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")
        let entries: [BookSequence.Entry] = [.file(path: "/tmp/a"), .file(path: "/tmp/b")]
        let together = try #require(BookSequence(entries: entries, position: 0, title: .openedTogether))
        #expect(together.displayName(locale: english) == "Books Opened Together")
        #expect(together.displayName(locale: japanese) == "まとめて開いた本")
        #expect(together.moved(to: 1)?.title == .openedTogether)
        // 出どころの無い並びは「まとめて開いた本」と同じに扱う。
        #expect(try #require(BookSequence(entries: entries, position: 0)).displayName(locale: english) == "Books Opened Together")
        let collection = try #require(BookSequence(entries: entries, position: 0, title: .collection(name: "Sample Collection")))
        #expect(collection.displayName(locale: japanese) == "Sample Collection")
        let smart = try #require(BookSequence(entries: entries, position: 1, title: .smartLibrary(name: nil)))
        #expect(smart.displayName(locale: english) == "Smart Library")
        #expect(smart.displayName(locale: japanese) == "スマートライブラリ")
        let group = try #require(BookSequence(entries: entries, position: 1, title: .smartLibrary(name: "Sample Series")))
        #expect(group.displayName(locale: english) == "Sample Series")
        // 同じ選択からは同じ値(BookOpenRequest は WindowGroup の値 ―― 毎回変わる値を入れない)。
        #expect(group == BookSequence(entries: entries, position: 1, title: .smartLibrary(name: "Sample Series")))
    }

    // MARK: - 仮想のフォルダ(SidePanelBrowserState)

    @Test("並びを渡すと、並びの順の行・今の本の行で仮想のフォルダになり、移動はできない。nil で実のフォルダへ戻る")
    func browserShowsAndLeavesTheSequence() async throws {
        let env = try Environment("sequence-folder-browser")
        defer { env.close() }
        let book = try env.makeFolder("shelf/Sample Book B")
        let loaded = try await FixtureBook.load(book)
        let browser = env.makeBrowser()
        browser.handlePanelRevealed(currentBook: loaded)
        await browser.settle()
        let shelf = book.deletingLastPathComponent()
        #expect(browser.currentDirectory?.path == shelf.path)
        #expect(browser.canGoUp)

        // 並び替えの設定には従わない(名前順なら A・B・C だが、並びの順のまま)。
        let entries: [BookSequence.Entry] = [
            .file(path: "/tmp/elsewhere/Sample Book C.cbz"),
            .file(path: book.path),
            .file(path: "/tmp/handoff/Sample Remote A.stacknestbook"),
        ]
        let sequence = try #require(BookSequence(entries: entries, position: 1, title: .openedTogether))
        browser.showSequence(sequence)
        let folder = try #require(browser.sequenceFolder)
        #expect(folder.rows.map(\.name) == ["Sample Book C.cbz", "Sample Book B", "Sample Remote A"])
        #expect(folder.rows.map(\.position) == [0, 1, 2])
        #expect(folder.rows.map(\.iconName) == ["doc.zipper", "folder", "book.closed"])
        #expect(folder.currentPosition == 1)
        // 外へは出られない。
        #expect(!browser.canGoUp)
        #expect(!browser.canGoBack)
        browser.goUp()
        #expect(browser.currentDirectory?.path == shelf.path)

        // 並びの中で本を替えた: 今の行だけが動き、行はそのまま。
        browser.showSequence(sequence.moved(to: 2))
        #expect(browser.sequenceFolder?.currentPosition == 2)
        #expect(browser.sequenceFolder?.rows == folder.rows)

        // 並びが消えた(並びの外の本を開いた): 実のフォルダへ戻る。
        browser.showSequence(nil)
        #expect(browser.sequenceFolder == nil)
        #expect(browser.currentDirectory?.path == shelf.path)
        #expect(browser.canGoUp)
    }

    @Test("並びのある本を開いて画面に出るとパネルは仮想のフォルダに、並びの外の本を開くとその本のフォルダへ戻る")
    func openingABookOutsideTheSequenceReturnsToItsFolder() async throws {
        let env = try Environment("sequence-folder-flow")
        defer { env.close() }
        let first = try env.makeFolder("shelf-1/Sample Book A")
        let second = try env.makeFolder("shelf-1/Sample Book B")
        let outside = try env.makeFolder("shelf-2/Sample Book Z")
        let entries = [first, second].map { BookSequence.Entry.file(path: $0.path) }
        let state = env.makeAppState()
        let browser = env.makeBrowser()
        // ContentView と同じつなぎ方(本が替わったら再アンカー、画面の並びをパネルへ)。
        func sync() {
            browser.handlePanelRevealed(currentBook: state.currentBook)
            browser.showSequence(state.shownBookSequence)
        }

        await openAndShow(BookOpenRequest(first, sequence: BookSequence(entries: entries, position: 0, title: .openedTogether)),
                          in: state)
        sync()
        #expect(browser.sequenceFolder?.rows.map(\.name) == ["Sample Book A", "Sample Book B"])
        #expect(browser.sequenceFolder?.currentPosition == 0)

        await openAndShow(BookOpenRequest(outside), in: state)
        sync()
        await browser.settle()
        #expect(browser.sequenceFolder == nil)
        #expect(browser.currentDirectory?.path == outside.deletingLastPathComponent().path)
        #expect(browser.currentBookRowURL?.path == outside.path)

        // 本を閉じても並びは無い。
        state.closeBook()
        state.noteShownBook(nil)
        #expect(state.shownBookSequence == nil)
        withExtendedLifetime(env.recentFiles) {}
    }

    // MARK: - 画面の並び(AppState.shownBookSequence)

    @Test("画面の並びは本が画面に出たときだけ変わる ―― 読み込みの途中・失敗では前の本の並びのまま")
    func shownSequenceFollowsTheShownBook() async throws {
        let env = try Environment("sequence-folder-shown")
        defer { env.close() }
        let first = try env.makeFolder("Sample Book A")
        let missing = env.temporary.file("Sample Book B (missing)")
        let third = try env.makeFolder("Sample Book C")
        let entries = [first, missing, third].map { BookSequence.Entry.file(path: $0.path) }
        let state = env.makeAppState()

        await openAndShow(BookOpenRequest(first, sequence: BookSequence(entries: entries, position: 0)), in: state)
        #expect(state.shownBookSequence?.position == 0)

        // 開けない本: 読み込みを始めた時点で bookSequence は替わるが、画面の並びは替わらず、失敗の後もそのまま。
        state.open(request: BookOpenRequest(missing, sequence: BookSequence(entries: entries, position: 1)))
        #expect(state.bookSequence?.position == 1)
        #expect(state.shownBookSequence?.position == 0)
        await state.openTask?.value
        #expect(state.currentBook?.id == first.path)
        #expect(state.shownBookSequence?.position == 0)

        // 開けた本: 読み込みが済んでも、画面に出るまでは前の本の並び。
        state.open(request: BookOpenRequest(third, sequence: BookSequence(entries: entries, position: 2)))
        await state.openTask?.value
        #expect(state.currentBook?.id == third.path)
        #expect(state.shownBookSequence?.position == 0)
        state.noteShownBook(state.currentBook)
        #expect(state.shownBookSequence?.position == 2)

        // 同じ本を別の並びで開き直した(ビューアは作り直さないので受け渡しは起きない): その場で替わる。
        let other = try #require(BookSequence(entries: [.file(path: third.path), .file(path: first.path)], position: 0))
        state.open(request: BookOpenRequest(third, sequence: other))
        await state.openTask?.value
        #expect(state.shownBookSequence == other)

        // 並びの外の本: 画面に出たら消える。
        state.open(request: BookOpenRequest(first))
        await state.openTask?.value
        #expect(state.shownBookSequence == other)
        state.noteShownBook(state.currentBook)
        #expect(state.shownBookSequence == nil)
        withExtendedLifetime(env.recentFiles) {}
    }

    // MARK: - 行を押す(AppState.openSequenceEntry)

    @Test("行を押すと並びの中でその本へ動き、見つからない本は知らせて開かない(隣の本へ飛ばさない)")
    func openingAnEntryMovesWithinTheSequence() async throws {
        let env = try Environment("sequence-folder-open")
        defer { env.close() }
        let first = try env.makeFolder("Sample Book A")
        let missing = env.temporary.file("Sample Book B (missing)")
        let third = try env.makeFolder("Sample Book C")
        let fourth = try env.makeFolder("Sample Book D")
        let entries = [first, missing, third, fourth].map { BookSequence.Entry.file(path: $0.path) }
        let state = env.makeAppState()
        await openAndShow(BookOpenRequest(first, sequence: BookSequence(entries: entries, position: 0, title: .openedTogether)),
                          in: state)

        // 離れた行へ(間の本は確かめない)。
        state.openSequenceEntry(at: 3)
        await state.sequenceTask?.value
        await state.openTask?.value
        #expect(state.currentBook?.id == fourth.path)
        #expect(state.bookSequence?.position == 3)
        #expect(state.bookSequence?.title == .openedTogether)
        state.noteShownBook(state.currentBook)
        #expect(state.shownBookSequence?.position == 3)
        #expect(state.viewerNotice == nil)

        // 見つからない本: 知らせて、今の本のまま(隣の本 ―― 位置 0・2 ―― へは飛ばない)。
        state.openSequenceEntry(at: 1)
        await state.sequenceTask?.value
        await state.openTask?.value
        #expect(state.currentBook?.id == fourth.path)
        #expect(state.bookSequence?.position == 3)
        #expect(state.shownBookSequence?.position == 3)
        let notice = try #require(state.viewerNotice?.message)
        #expect(notice.contains("Sample Book B (missing)"))
        #expect(state.loadingProgress == nil)
        #expect(!state.isWaitingToOpen)

        // 今の本の行は何もしない。範囲の外は鳴らす。
        let recorder = FeedbackRecorder()
        UserFeedback.$recorder.withValue(recorder) {
            state.openSequenceEntry(at: 3)
            state.openSequenceEntry(at: 9)
        }
        await state.sequenceTask?.value
        await state.openTask?.value
        #expect(state.currentBook?.id == fourth.path)
        #expect(recorder.beeps.count == 1)

        // 前の行へも動ける。
        state.openSequenceEntry(at: 2)
        await state.sequenceTask?.value
        await state.openTask?.value
        #expect(state.currentBook?.id == third.path)
        #expect(state.bookSequence?.position == 2)
        withExtendedLifetime(env.recentFiles) {}
    }

    @Test("繋がっていないボリュームの上の本は、触らずにそう知らせる")
    func anEntryOnAnUnmountedVolumeSaysSo() async throws {
        let env = try Environment("sequence-folder-unmounted")
        defer { env.close() }
        let first = try env.makeFolder("Sample Book A")
        let unmounted = "/Volumes/qooViewer-test-not-mounted-\(UUID().uuidString)/Sample Book E.cbz"
        let entries: [BookSequence.Entry] = [.file(path: first.path), .file(path: unmounted)]
        let state = env.makeAppState()
        await openAndShow(BookOpenRequest(first, sequence: BookSequence(entries: entries, position: 0)), in: state)

        state.openSequenceEntry(at: 1)
        await state.sequenceTask?.value
        await state.openTask?.value
        #expect(state.currentBook?.id == first.path)
        let locale = env.preferences.effectiveLocale
        #expect(state.viewerNotice?.message
            == AppState.sequenceEntryFailureMessage(.volumeNotConnected, name: "Sample Book E.cbz", locale: locale))
        withExtendedLifetime(env.recentFiles) {}
    }

    @Test("仮想のフォルダの絞り込みは、同じ行・同じ文字なら控えを返し、行が替われば作り直す")
    func filteredRowsAreMemoizedPerRows() throws {
        let browser = SidePanelBrowserState(changeCenter: FileSystemChangeCenter(), observesSystem: false)
        let first = try #require(BookSequence(
            entries: ["/v/Alpha.cbz", "/v/Beta.cbz", "/v/Alpine.cbz"].map { .file(path: $0) }, position: 0))
        browser.showSequence(first)
        #expect(browser.filteredSequenceRows(matching: "al").map(\.name) == ["Alpha.cbz", "Alpine.cbz"])
        #expect(browser.filteredSequenceRows(matching: " al ").map(\.name) == ["Alpha.cbz", "Alpine.cbz"])
        #expect(browser.filteredSequenceRows(matching: "").count == 3)
        let rowsID = try #require(browser.sequenceFolder?.rowsID)
        // 同じ並びで位置だけ動いても、行(と番号)は作り直さない。
        browser.showSequence(first.moved(to: 1))
        #expect(browser.sequenceFolder?.rowsID == rowsID)
        let second = try #require(BookSequence(entries: [.file(path: "/v/Alto.cbz")], position: 0))
        browser.showSequence(second)
        #expect(browser.sequenceFolder?.rowsID != rowsID)
        #expect(browser.filteredSequenceRows(matching: "al").map(\.name) == ["Alto.cbz"])
    }
}


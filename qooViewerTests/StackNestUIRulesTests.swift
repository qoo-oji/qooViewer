import Foundation
import StackNestViewerKit
import Testing

@testable import qooViewer

/// StackNest の本の画面の決まり(タイトル・知らせ・置き場所の無い本の淡色・端のページのシート・終了時の送り切り)。
/// 見た目そのものは実機で確かめる(docs/12「StackNest の本の実機の確かめ方」)。ここは、画面が使う判定を押さえる。
@MainActor
struct StackNestUIRulesTests {
    @Test("タイトル: StackNest の本は「(StackNest) 題名」、シークレットウインドウでは「(シークレット) (StackNest) 題名」、ふつうの本はそのまま")
    func windowTitle() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let suite = PreferencesSuite(label: "stacknest-title")
        let preferences = suite.makePreferences()
        let book = try await FixtureBook.load(fixture.referenceURL)
        let stackNest = String(localized: "(StackNest) \("Base")", language: preferences.effectiveLocale)
        #expect(ContentView.bookWindowTitle(base: "Base", book: book, isPrivateWindow: false, preferences: preferences) == stackNest)
        #expect(stackNest.hasSuffix("Base") && stackNest.contains("StackNest"))
        // シークレットの印が外側(先頭)、StackNest の印がその内側。
        #expect(ContentView.bookWindowTitle(base: "Base", book: book, isPrivateWindow: true, preferences: preferences)
            == preferences.privateWindowTitle(for: stackNest))
        var plain = book
        plain.stackNestReference = nil
        #expect(ContentView.bookWindowTitle(base: "Base", book: plain, isPrivateWindow: false, preferences: preferences) == "Base")
        #expect(ContentView.bookWindowTitle(base: "Base", book: nil, isPrivateWindow: false, preferences: preferences) == "Base")
        withExtendedLifetime(preferences) {}
    }

    @Test("出たときの知らせの理由: StackNest の本はシークレットフォルダの中にあっても StackNest として、ふつうの本・本が無いときは知らせない")
    func noRecordReason() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        #expect(NoRecordReason(shown: book) == .stackNest)
        var secretStackNest = book
        secretStackNest.isInSecretFolder = true
        #expect(NoRecordReason(shown: secretStackNest) == .stackNest)
        var secret = book
        secret.stackNestReference = nil
        secret.isInSecretFolder = true
        #expect(NoRecordReason(shown: secret) == .secretFolder)
        var plain = book
        plain.stackNestReference = nil
        #expect(NoRecordReason(shown: plain) == nil)
        #expect(NoRecordReason(shown: nil) == nil)
    }

    @Test("記録しない操作の知らせ: StackNest の本はその本の文言、シークレットウインドウではシークレットウインドウの文言")
    func nothingIsRecordedNotice() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let locale = Locale(identifier: "en")
        #expect(ViewerView.nothingIsRecordedNotice(isPrivateWindow: false, book: book, locale: locale)
            == String(localized: "Nothing is saved for books from StackNest.", language: locale))
        #expect(ViewerView.nothingIsRecordedNotice(isPrivateWindow: true, book: book, locale: locale)
            == String(localized: "Nothing is saved in a private window.", language: locale))
    }

    @Test("置き場所の無い本か: 本の受け渡しの間は、画面に出ている本(menuShownBook)で答える")
    func lacksBrowsableLocationFollowsTheShownBook() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        #expect(!state.lacksBrowsableLocation())
        // 画面にはまだ StackNest の本が出ている(currentBook は替わっていない・次の本の読み込み中)。
        state.setMenuShownBook(MenuShownBook(book))
        #expect(state.lacksBrowsableLocation())
        #expect(state.lacksBrowsableLocation(fixture.referenceURL))
        // ほかの本の URL を名指ししたら、その本ではない。
        #expect(!state.lacksBrowsableLocation(fixture.temporary.file("Other.cbz")))
        #expect(!book.hasBrowsableLocation)
    }

    @Test("端のページの「毎回確認」: 前の本・次の本へ移る選択肢だけが、置き場所の無い本で淡色になる")
    func boundaryChoicesThatOpenAdjacentBooks() {
        #expect(FirstPageBehavior.promptChoices.filter(\.opensAdjacentBook) == [.previousBookLastPage, .previousBook])
        #expect(LastPageBehavior.promptChoices.filter(\.opensAdjacentBook) == [.nextBookFirstPage, .nextBook])
        #expect(!FirstPageBehavior.loop.opensAdjacentBook)
        #expect(!LastPageBehavior.returnToWelcome.opensAdjacentBook)
    }

    @Test("終了時の送り切り: 本を閉じた直後で、閉じたときの送信がまだ済んでいなければ、終了でも送り切る")
    func quitFlushCoversJustClosedBooks() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        let viewer = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        let progress = try #require(viewer.stackNestProgress)
        let session = try #require(viewer.stackNestBook?.session)
        let flush = StackNestQuitFlush()
        flush.register(owner: viewer, reporter: progress, session: session) { 4 }
        viewer.jump(toPageIndex: 4)
        await viewer.settle()
        #expect(progress.hasUnsentWork)
        // 閉じた(控えから外す)が、まだ送っていない。
        flush.unregister(owner: viewer)
        #expect(flush.flushBlocking(timeout: 2) == 1)
        #expect(fixture.progressPages.contains(4))
        progress.close()
        await progress.waitUntilIdle()
        // 送り終えたら控えに残らない。
        #expect(flush.flushBlocking(timeout: 2) == 0)
    }
}

import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting
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

    @Test("終了時の送り切り: 本を閉じた直後で、閉じたときの送信がまだ届いていなければ、終了でもその送信を待つ")
    func quitFlushCoversJustClosedBooks() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        let viewer = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        viewer.jump(toPageIndex: 4)
        await viewer.settle()
        // 役は試験の側で持たない(閉じた後に役を生かしているのが役自身であることも見るため)。
        #expect(viewer.stackNestProgress?.hasUnsentWork == true)
        // 書き戻しの応答を止めたまま本を閉じる(閉じたときの送信が飛んだまま。役は送り終えるまで自分を保ち、登録簿に残る)。
        let held = fixture.server.gate(.progress)
        viewer.releaseResources()
        #expect(await FileIO.perform { held.waitForArrival() })
        // 応答は少し後に流す(送り切りはメインで待つので、流すのはメインの外から)。
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { held.open() }
        let started = ContinuousClock.now
        #expect(harness.stackNestProgressRegistry.flushAllBlocking(timeout: TestPatience.condition) == 1)
        let waited = ContinuousClock.now - started
        // 飛んでいた送信の終わり(応答を流した 0.3 秒後)まで待った。
        #expect(waited >= .milliseconds(250) && waited < .seconds(3))
        #expect(fixture.progressPages == [4])
    }
}

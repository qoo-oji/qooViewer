import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// 本を開いてから閉じるまで(ViewModels/ViewerViewModel.swift)。
///
/// 「実機でしか確かめられない」と扱ってきた領域だが、画面の都合ではなく**共有の保存先に
/// 直結している**のが理由だった。`ViewerHarness` がその 4 つ(SwiftData・`UserDefaults`・
/// ディスクキャッシュ・開いている本の登録簿)を塞ぐ。
///
/// 待ち合わせは `settle()`。**時間で待たないこと**(段階 2 の実測。docs/13)。
@MainActor
struct ViewerViewModelTests {

    // MARK: - 開始ページの決定

    @Test("「前回の続きから」は、保存された読書位置から始める")
    func resumeStartsFromTheStoredPage() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.reopenBehavior = .resume
        let book = try await harness.makeBook(pageCount: 6)

        let first = await harness.open(book)
        first.jump(toPageIndex: 4)
        await first.settle()
        harness.close()

        let reopened = await harness.open(book)
        #expect(reopened.currentIndex == 4)
        #expect(reopened.needsResumeConfirmation == false)
    }

    @Test("「いつも最初から」は、保存された読書位置を無視する")
    func alwaysFromStartIgnoresTheStoredPage() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)

        let first = await harness.open(book)
        first.jump(toPageIndex: 4)
        await first.settle()
        harness.close()

        harness.preferences.reopenBehavior = .alwaysFromStart
        let reopened = await harness.open(book)
        #expect(reopened.currentIndex == 0)
        // 読書位置そのものは残る(次に「前回の続きから」へ戻せば効く)。
        #expect(harness.readingState(for: book)?.lastPageKey == book.pages[4].sortKey)
    }

    @Test("「最後まで読んでいたら最初から」は、最終ページのときだけ先頭へ戻す")
    func fromStartIfFinishedLastTimeLooksAtTheLastPage() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.reopenBehavior = .fromStartIfFinishedLastTime
        let book = try await harness.makeBook(pageCount: 6)

        let first = await harness.open(book)
        first.jump(toPageIndex: 5)
        await first.settle()
        harness.close()
        let afterFinishing = await harness.open(book)
        #expect(afterFinishing.currentIndex == 0)

        afterFinishing.jump(toPageIndex: 2)
        await afterFinishing.settle()
        harness.close()
        let afterStoppingMidway = await harness.open(book)
        #expect(afterStoppingMidway.currentIndex == 2)
    }

    @Test("「毎回確認」は、前回位置が先頭でないときだけ尋ねる")
    func askConfirmsOnlyWhenThereIsSomewhereToResume() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.reopenBehavior = .ask
        let book = try await harness.makeBook(pageCount: 6)

        // 初めて開く本には尋ねない(復元するものが無い)。
        let first = await harness.open(book)
        #expect(first.needsResumeConfirmation == false)
        first.jump(toPageIndex: 3)
        await first.settle()
        harness.close()

        let reopened = await harness.open(book)
        #expect(reopened.needsResumeConfirmation)
        // 尋ねている間も、表示自体は前回位置に置いてある(「はい」が既定の答え)。
        #expect(reopened.currentIndex == 3)
        reopened.confirmResumeFromLastPage(false)
        await reopened.settle()
        #expect(reopened.currentIndex == 0)
        #expect(reopened.needsResumeConfirmation == false)
    }

    @Test("開くページの指定は、開始ページの設定より優先し、確認も出さない")
    func anExplicitInitialPageWins() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.reopenBehavior = .ask
        let book = try await harness.makeBook(pageCount: 6)

        let first = await harness.open(book)
        first.jump(toPageIndex: 3)
        await first.settle()
        harness.close()

        let reopened = await harness.open(book, initialPageID: book.pages[1].id)
        #expect(reopened.currentIndex == 1)
        #expect(reopened.needsResumeConfirmation == false)
        harness.close()

        // 見つからない指定(除外されたページなど)は、無指定と同じ扱いに落ちる。
        let withUnknownID = await harness.open(book, initialPageID: "no-such-page")
        #expect(withUnknownID.currentIndex == 3)
    }

    @Test("端の指定で開くと、末尾は「最後の見開き」の先頭に着地する")
    func theInitialEdgeLandsOnTheLastSpread() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.reopenBehavior = .resume
        let book = try await harness.makeBook(pageCount: 6)

        let first = await harness.open(book)
        first.jump(toPageIndex: 3)
        await first.settle()
        harness.close()

        let atFirstEdge = await harness.open(book, initialEdge: .first)
        #expect(atFirstEdge.currentIndex == 0)
        harness.close()

        // 見開き表示(既定)なら、最終ページ単体ではなく組の先頭へ ―― 相方の無い1枚だけが
        // 出るのを避けるため。
        let atLastEdge = await harness.open(book, initialEdge: .last)
        #expect(atLastEdge.displayMode == .spread)
        #expect(atLastEdge.currentIndex == 4)
        harness.close()

        atLastEdge.toggleDisplayMode()
        await atLastEdge.settle()
        harness.close()
        let atLastEdgeInSinglePage = await harness.open(book, initialEdge: .last)
        #expect(atLastEdgeInSinglePage.displayMode == .single)
        #expect(atLastEdgeInSinglePage.currentIndex == 5)
    }

    // MARK: - 中身の差し替え

    @Test("中身が差し替わった本は、古い読書位置とブックマークを捨てて開き直す")
    func replacedContentDropsTheStaleRows() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)

        let first = await harness.open(book)
        first.jump(toPageIndex: 4)
        first.addBookmark()
        await first.settle()
        #expect(harness.bookmarks(for: book).count == 1)
        harness.close()

        // 同じ名前のまま中身を入れ替える(ページ数が変わるので指紋が食い違う)。
        try FileManager.default.removeItem(at: harness.temporary.file("book/p06.png"))
        let replaced = try await harness.reloadBook()
        #expect(replaced.id == book.id)

        let reopened = await harness.open(replaced)
        #expect(reopened.currentIndex == 0)
        // 古い行は消えて、作りたての行に置き換わっている(初めて開く本と同じ扱い)。
        #expect(harness.readingState(for: replaced)?.lastPageIndex == 0)
        #expect(harness.bookmarks(for: replaced).isEmpty)
    }

    // MARK: - ブックマークの鍵

    @Test("番号しか持たない古いブックマークには、開いた時点で鍵が入る")
    func legacyBookmarksGetTheirPageKey() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)
        // 1.36 以前に保存された行。番号は当時の並び(従来順)で記録されている。
        harness.library.context.insert(
            Bookmark(bookID: book.id, pageIndex: 2, pageKey: nil, name: "old")
        )
        try harness.library.context.save()

        let viewer = await harness.open(book)
        #expect(viewer.bookmarks.count == 1)
        #expect(harness.bookmarks(for: book).first?.pageKey == book.pages[2].sortKey)
    }

    // MARK: - ページ送り

    @Test("見開き表示は2ページずつ進み、単ページ表示は1ページずつ進む")
    func theStepFollowsTheDisplayMode() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)
        let viewer = await harness.open(book)

        #expect(viewer.displayMode == .spread)
        #expect(viewer.currentImages.count == 2)
        viewer.advance(forward: true)
        await viewer.settle()
        #expect(viewer.currentIndex == 2)
        viewer.advance(forward: false)
        await viewer.settle()
        #expect(viewer.currentIndex == 0)

        viewer.toggleDisplayMode()
        await viewer.settle()
        viewer.advance(forward: true)
        await viewer.settle()
        #expect(viewer.currentIndex == 1)
    }

    @Test("両端では、境界の設定が「何もしない」なら動かない")
    func thePageBoundariesHoldStill() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.firstPageBehavior = .none
        harness.preferences.lastPageBehavior = .none
        let book = try await harness.makeBook(pageCount: 6)
        let viewer = await harness.open(book)

        viewer.advance(forward: false)
        await viewer.settle()
        #expect(viewer.currentIndex == 0)

        viewer.jump(toPageIndex: 4)
        await viewer.settle()
        viewer.advance(forward: true)
        await viewer.settle()
        #expect(viewer.currentIndex == 4)
    }

    // MARK: - ブックマークの追加

    @Test("同じページのブックマークは重複して増えない")
    func addingABookmarkTwiceOnTheSamePageDoesNothing() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)
        let viewer = await harness.open(book)

        viewer.addBookmark()
        viewer.addBookmark()
        #expect(viewer.bookmarks.count == 1)

        viewer.jump(toPageIndex: 2)
        await viewer.settle()
        viewer.addBookmark()
        #expect(viewer.bookmarks.count == 2)
        #expect(harness.bookmarks(for: book).map(\.pageIndex) == [0, 2])
        // 鍵も一緒に入る(並びが変わっても同じ画像を指し続けるため)。
        #expect(harness.bookmarks(for: book).map(\.pageKey)
            == [book.pages[0].sortKey, book.pages[2].sortKey])
    }

    // MARK: - 表示モードの書き戻し先

    @Test("見開き/単ページの切り替えは、強制指定がある本ならそちらへ書き戻す")
    func togglingTheDisplayModeWritesBackToTheRightRow() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)

        // 強制指定が無い本: 読書状態の行にだけ残る。
        let plain = await harness.open(book)
        plain.toggleDisplayMode()
        await plain.settle()
        #expect(harness.readingState(for: book)?.displayMode == .single)
        #expect(harness.library.layouts.bookLayoutSettings(forBookID: book.id)?.forcedDisplayMode == nil)
        harness.close()

        // 強制指定がある本: そちらも一緒に書き換える(書き戻さないと開き直すたびに元へ戻る)。
        harness.library.layouts.setForcedDisplayMode(for: book, .spread)
        let forced = await harness.open(book)
        #expect(forced.displayMode == .spread)
        forced.toggleDisplayMode()
        await forced.settle()
        #expect(harness.library.layouts.bookLayoutSettings(forBookID: book.id)?.forcedDisplayMode == .single)
    }

    // MARK: - シークレットウインドウの契約

    @Test("シークレットウインドウは、保存データを1行も作らない")
    func aPrivateWindowWritesNothing() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)

        let viewer = await harness.open(book, skipsPersistence: true)
        viewer.jump(toPageIndex: 3)
        viewer.addBookmark()
        viewer.toggleDisplayMode()
        viewer.toggleReadingDirection()
        await viewer.settle()

        #expect(harness.readingState(for: book) == nil)
        #expect(harness.bookmarks(for: book).isEmpty)
        #expect(harness.library.layouts.bookLayoutSettings(forBookID: book.id) == nil)
        // 画面の上では普通に動く(保存しないだけ)。
        #expect(viewer.currentIndex == 3)
        #expect(viewer.displayMode == .single)
    }

    @Test("シークレットウインドウでも、保存済みの読書位置は読んで再開する")
    func aPrivateWindowStillResumesFromWhatWasSaved() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.reopenBehavior = .resume
        let book = try await harness.makeBook(pageCount: 6)

        let normal = await harness.open(book)
        normal.jump(toPageIndex: 4)
        await normal.settle()
        harness.close()

        let priv = await harness.open(book, skipsPersistence: true)
        #expect(priv.currentIndex == 4)
        priv.jump(toPageIndex: 1)
        await priv.settle()
        // シークレット側での移動は、保存済みの位置を上書きしない。
        #expect(harness.readingState(for: book)?.lastPageKey == book.pages[4].sortKey)
    }
}

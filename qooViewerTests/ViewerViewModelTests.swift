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

    @Test("最後のページが写った画面で閉じると「最後のページまで表示した」が残り、戻れば外れる")
    func recordsWhetherTheLastPageWasOnScreen() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)

        let viewer = await harness.open(book)
        viewer.jump(toPageIndex: 4)
        await viewer.settle()
        #expect(harness.readingState(for: book)?.isAtLastPage == true)
        viewer.jump(toPageIndex: 1)
        await viewer.settle()
        #expect(harness.readingState(for: book)?.isAtLastPage == false)
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

    @Test("「最後まで読んでいたら最初から」は、見開きの最後の画面で閉じた本も先頭へ戻す")
    func fromStartIfFinishedLastTimeCountsTheLastSpread() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.reopenBehavior = .fromStartIfFinishedLastTime
        let book = try await harness.makeBook(pageCount: 6)

        // 見開きの最後の画面(5–6 ページ)。記録される読書位置は先の 5 ページ(番号 4)で、最終ページ(番号 5)ではない。
        let first = await harness.open(book)
        #expect(first.displayMode == .spread)
        first.jump(toPageIndex: 4)
        await first.settle()
        #expect(first.currentImages.count == 2)
        harness.close()
        #expect(harness.readingState(for: book)?.lastPageKey == book.pages[4].sortKey)

        let reopened = await harness.open(book)
        #expect(reopened.currentIndex == 0)
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

    @Test("中身が差し替わった本は、古い読書位置を捨てて開き直す(ブックマークは、指すページが残っていれば残す)")
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
        // 古い行は消えて、作りたての行に置き換わっている(読書位置は先頭から)。
        #expect(harness.readingState(for: replaced)?.lastPageIndex == 0)
        // ブックマークを付けた 5 ページ目(p05)は残っているので、ブックマークも残す(2026-09-25。以前はすべて捨てていた。
        // ReadingStateReplacementTests)。
        #expect(harness.bookmarks(for: replaced).count == 1)
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

    // MARK: - スライドショーの末尾

    @Test("スライドショーが最後のページに達したら、環境設定「最後のページで」に従う(cooViewer と同じ)",
          arguments: [LastPageBehavior.loop, .nextBook, .nextBookFirstPage, .returnToWelcome, .closeTab, .closeWindow, .none, .ask])
    func theSlideshowFollowsTheLastPageBehavior(behavior: LastPageBehavior) async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.lastPageBehavior = behavior
        let book = try await harness.makeBook(pageCount: 6)
        let viewer = await harness.open(book)
        var requests: [PageBoundaryRequest] = []
        viewer.onPageBoundaryRequest = { requests.append($0) }
        viewer.jump(toPageIndex: 4)
        await viewer.settle()
        viewer.startSlideshow()
        defer { viewer.stopSlideshow() }

        viewer.handleSlideshowReachedEnd()
        await viewer.settle()

        switch behavior {
        case .loop:
            // 先頭へ戻って続ける。
            #expect(viewer.currentIndex == 0)
            #expect(viewer.isSlideshowActive)
            #expect(requests.isEmpty)
        case .nextBook, .nextBookFirstPage:
            // ここでは止め、次の本で始め直してもらう(AppState.pendingStartsSlideshow)。
            #expect(!viewer.isSlideshowActive)
            #expect(requests == [.openSiblingBook(forward: true, landsOnEdge: behavior == .nextBookFirstPage,
                                                  continuesSlideshow: true)])
        case .returnToWelcome:
            #expect(!viewer.isSlideshowActive)
            #expect(requests == [.returnToWelcome])
        case .closeTab:
            #expect(!viewer.isSlideshowActive)
            #expect(requests == [.closeTab])
        case .closeWindow:
            #expect(!viewer.isSlideshowActive)
            #expect(requests == [.closeWindow])
        case .none:
            #expect(!viewer.isSlideshowActive)
            #expect(requests.isEmpty)
            #expect(viewer.currentIndex == 4)
        case .ask:
            // 止めてから、手で送ったときと同じシートを出す。
            #expect(!viewer.isSlideshowActive)
            #expect(viewer.pendingBoundaryPrompt == .forward)
            #expect(requests.isEmpty)
        }
    }

    @Test("手で最後のページから送ったときの「次の本へ」は、スライドショーを引き継がない")
    func aManualTurnDoesNotStartTheSlideshowInTheNextBook() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.lastPageBehavior = .nextBook
        let book = try await harness.makeBook(pageCount: 6)
        let viewer = await harness.open(book)
        var requests: [PageBoundaryRequest] = []
        viewer.onPageBoundaryRequest = { requests.append($0) }
        viewer.jump(toPageIndex: 4)
        await viewer.settle()

        viewer.advance(forward: true)
        await viewer.settle()
        #expect(requests == [.openSiblingBook(forward: true, landsOnEdge: false, continuesSlideshow: false)])
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

    @Test("除外したページのブックマークは隣のページに付いて見えない。そのページでの追加・次のブックマークも別のページを見ない(2026-10-04、監査 V-4)")
    func bookmarksOfExcludedPagesAreNotShownOnTheirNeighbors() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)
        let keys = book.pages.map(\.sortKey)
        let viewer = await harness.open(book)
        viewer.jump(toPageIndex: 4)
        await viewer.settle()
        viewer.addBookmark()
        #expect(viewer.bookmarks.map(\.pageKey) == [keys[4]])

        // 5 ページ目を除外する(別のウインドウ・編集ウインドウからでも同じ知らせで届く)。
        harness.library.layouts.setPageLayoutState(for: book, pageKey: keys[4], state: .excluded)
        await viewer.settle()
        // 以前は番号 4 のまま残り、詰まった並びの番号 4(6 ページ目)に印・一覧・トグルが出た。
        #expect(viewer.bookmarks.isEmpty)
        #expect(harness.bookmarks(for: book).count == 1)

        // 6 ページ目(今の番号 4)には足せる(以前は番号の重複で黙って何もしなかった)。
        viewer.jump(toPageIndex: 4)
        await viewer.settle()
        viewer.addBookmark()
        #expect(viewer.bookmarks.map(\.pageKey) == [keys[5]])
        #expect(harness.bookmarks(for: book).count == 2)

        // 除外を解けば元のブックマークも戻る(行は消していない)。
        harness.library.layouts.setPageLayoutState(for: book, pageKey: keys[4], state: nil)
        await viewer.settle()
        #expect(Set(viewer.bookmarks.compactMap(\.pageKey)) == [keys[4], keys[5]])
    }

    @Test("「見開きの2枚目」指定のページへは、単ページでは寄せずに着地し、見開きへ切り替えたら組の起点へ寄せる。次のブックマークは相方を越える(2026-10-04 の監査 V-5・V-10・V-6)")
    func secondOfPairPagesAreReachableInSinglePageMode() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)
        let viewer = await harness.open(book)
        #expect(viewer.displayMode == .spread)
        // 3 ページ目(番号 2)と 4 ページ目(番号 3)を明示の見開きにする(自動レイアウトの本・EPUB と同じ形)。
        let first = PageLayoutState(epubSpreadPosition: SpreadPairing.firstOfPairPosition(viewer.readingDirection))
        let second = PageLayoutState(epubSpreadPosition: SpreadPairing.secondOfPairPosition(viewer.readingDirection))
        harness.library.layouts.setPageLayoutState(for: book, pageKey: book.pages[2].sortKey, state: first)
        harness.library.layouts.setPageLayoutState(for: book, pageKey: book.pages[3].sortKey, state: second)
        await viewer.settle()

        // 見開きでは「2枚目」へ直接着地すると組の起点へ寄せる(今までどおり)。
        viewer.jump(toPageIndex: 3)
        await viewer.settle()
        #expect(viewer.currentIndex == 2)
        #expect(viewer.partnerPageIndex == 3)

        // V-6: 相方(番号 3)のブックマークは「次」にならない。以前は 3 を選んで起点 2 へ寄せ戻し、何度押しても止まった。
        viewer.addBookmark(atIndex: 3)
        viewer.addBookmark(atIndex: 5)
        viewer.jumpToNextBookmark()
        await viewer.settle()
        #expect(viewer.currentIndex == 5)

        // V-5: 単ページでは寄せない。以前は番号 2 が出て、指定したページを表示できなかった。
        viewer.toggleDisplayMode()
        await viewer.settle()
        viewer.jump(toPageIndex: 3)
        await viewer.settle()
        #expect(viewer.currentIndex == 3)

        // V-10: そこから見開きへ切り替えると組の起点へ寄せ、2 枚組で出す(寄せないと片側が空白の見開きになる)。
        viewer.toggleDisplayMode()
        await viewer.settle()
        #expect(viewer.currentIndex == 2)
        #expect(viewer.currentImages.count == 2)
    }

    @Test("ブックマークへ飛ぶのはこの本のブックマークだけ。並びが変わっても同じページへ(2026-10-04 の監査 M-1)")
    func jumpingToABookmarkChecksTheBook() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)
        let viewer = await harness.open(book)
        // 単ページで見る(見開きの起点への寄せで、着地のページが 1 つずれないように)。
        if viewer.displayMode == .spread { viewer.toggleDisplayMode() }
        await viewer.settle()

        // メニューの一覧が前の本のまま残った(別の本のブックマーク)。以前は同じ番号のページへ黙って飛んだ。
        let foreign = Bookmark(bookID: "/somewhere/else", pageIndex: 4, name: "foreign")
        #expect(!viewer.jump(to: foreign))
        await viewer.settle()
        #expect(viewer.currentIndex == 0)

        let own = Bookmark(bookID: book.id, pageIndex: 4, pageKey: book.pages[3].sortKey, name: "own")
        #expect(viewer.jump(to: own))
        await viewer.settle()
        // 番号ではなく鍵で引く。
        #expect(viewer.book.pages[viewer.currentIndex].sortKey == book.pages[3].sortKey)
    }

    @Test("ほかの窓でレイアウトが変わると、メニューの写しを作り直す印が進む(2026-10-04 の監査 V-7)")
    func layoutChangesElsewhereAdvanceTheRevision() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)
        let viewer = await harness.open(book)
        let start = viewer.layoutDataRevision
        #expect(!viewer.hasPageLayoutOverride(atIndex: viewer.currentIndex))

        // 編集ウインドウ・自動レイアウトと同じ知らせ(.layoutDataDidChange)で届く。並び・見開きの枚数が変わらない変更。
        harness.library.layouts.setPageLayoutState(for: book, pageKey: book.pages[0].sortKey, state: .single)
        await viewer.settle()
        #expect(viewer.layoutDataRevision != start)
        #expect(viewer.hasPageLayoutOverride(atIndex: viewer.currentIndex))
    }

    @Test("記録を残さない本でメモリの上だけ切り替えた見開き・読み方向・補正は、レイアウトの知らせで DB の値へ戻らない(V-14)")
    func inMemoryTogglesSurviveLayoutNotifications() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)
        let layouts = harness.library.layouts
        layouts.setForcedDisplayMode(for: book, .spread)
        layouts.setReadingDirectionOverride(for: book, .rightToLeft)
        let viewer = await harness.open(book, skipsPersistence: true)
        #expect(viewer.displayMode == .spread)
        #expect(viewer.readingDirection == .rightToLeft)

        viewer.toggleDisplayMode()
        viewer.toggleReadingDirection()
        viewer.toggleContrastCorrection()
        await viewer.settle()

        // 関係の無い変更(ほかのウインドウでのページの指定)の知らせで読み直しが走る。
        layouts.setPageLayoutState(for: book, pageKey: book.pages[3].sortKey, state: .single)
        await viewer.settle()
        #expect(viewer.displayMode == .single)
        #expect(viewer.readingDirection == .leftToRight)
        #expect(viewer.isContrastCorrectionEnabled)
        // DB は書いていない。
        #expect(layouts.bookLayoutSettings(forBookID: book.id)?.forcedDisplayMode == .spread)
        #expect(layouts.bookLayoutSettings(forBookID: book.id)?.contrastCorrectionEnabled != true)
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

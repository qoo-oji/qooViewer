import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting
import Testing

@testable import qooViewer

/// ビューアからの書き戻し(StackNestViewerKit の StackNestProgressReporter)。番号は StackNest の番号・シークレットウインドウでは
/// 送らない・閉じるときに待たずに送る・失敗の知らせ。まとめ待ち・1 件ずつ・恒久的な失敗で止まる・終了時の送り切りといった役
/// そのものの振る舞いは部品の試験が押さえる。
@MainActor
struct StackNestReadingSyncTests {
    @Test("書き戻すのは今の並びの位置ではなく、ページの名前が持つ StackNest の番号(鍵と名乗りを付けて POST)")
    func progressUsesStackNestPageNumbers() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 3)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        // StackNest の 0 番を除外する。今の並びの 0 番目は StackNest の 1 番になる。
        harness.library.layouts.setPageLayoutState(for: book, pageKey: book.pages[0].sortKey, state: .excluded)
        let viewer = await harness.openInWindow(book)
        #expect(viewer.book.pages[viewer.currentIndex].sortKey == "000003.jpg")
        viewer.jump(toPageIndex: 0)
        await viewer.settle()
        viewer.flushPendingSave()
        await viewer.stackNestProgress?.waitUntilIdle()
        #expect(fixture.progressPages == [1])
        let post = try #require(fixture.requests.last { $0.route == .progress })
        #expect(post.method == "POST")
        #expect(post.carriesExpectedToken)
        #expect(post.viewerHeader == StackNestViewerIdentification.forMainBundle(format: 1).headerValue)
    }

    @Test("本を閉じる(releaseResources)と、まとめ待ち(3 秒)を待たずに位置を送る")
    func closingSendsThePendingPage() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        let viewer = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        // まとめ待ち(3 秒)はページが動いた時に始まる。動かす前から測る: 閉じる前の待ち(settle)が長くても、閉じたことが
        // 送らせていなければ、ここから送り終わるまでに必ず 3 秒かかる。
        let movedAt = ContinuousClock.now
        viewer.jump(toPageIndex: 2)
        await viewer.settle()
        let progress = try #require(viewer.stackNestProgress)
        // まとめ待ち(3 秒)の間に閉じる。
        #expect(fixture.progressPages.isEmpty)
        #expect(progress.hasUnsentWork)
        viewer.releaseResources()
        await progress.waitUntilIdle()
        // 閉じたこと自体が送った(まとめ待ちの 3 秒を待っていれば、ページを動かしてからここまでに 3 秒かかる)。
        #expect(ContinuousClock.now - movedAt < .seconds(2))
        #expect(fixture.progressPages == [2])
        #expect(!progress.hasUnsentWork)
    }

    @Test("シークレットウインドウでは書き戻さない(ページは同じセッションで読む)")
    func privateWindowsDoNotWriteBack() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        let viewer = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL), isPrivateWindow: true)
        #expect(viewer.stackNestProgress == nil)
        #expect(viewer.stackNestBook != nil)
        viewer.jump(toPageIndex: 2)
        await viewer.settle()
        viewer.flushPendingSave()
        #expect(fixture.progressPages.isEmpty)
    }

    @Test("書き戻しが 401 で失敗したら、読書は続けたまま「StackNest から開き直して」を表示言語で知らせる")
    func failureIsShownAsANotice() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        fixture.server.respond(.progress, with: .status(401))
        let harness = try ViewerHarness()
        defer { harness.close() }
        let viewer = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        viewer.jump(toPageIndex: 1)
        await viewer.settle()
        viewer.flushPendingSave()
        await viewer.stackNestProgress?.waitUntilIdle()
        #expect(
            viewer.stackNestNotice?.message
                == StackNestText.message(for: StackNestViewerError(.unauthorized), locale: harness.preferences.effectiveLocale)
        )
        #expect(viewer.currentIndex == 1)
    }

    @Test("開いたままの本を StackNest が開き直したら(同じパス・新しい鍵)、新しく開いたビューアは新しい鍵で読み、古いビューアは古いまま")
    func reopenedReferenceGetsANewSession() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        let first = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        let firstBook = try #require(first.stackNestBook)
        try fixture.writeReference(token: "renewed-token-0123456789", pageCount: 6, startPage: 2)
        let second = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        let secondBook = try #require(second.stackNestBook)
        #expect(secondBook !== firstBook)
        #expect(secondBook.reference.token == "renewed-token-0123456789")
        #expect(firstBook.reference.token == StackNestTestBook.token)
        // 新しいビューアの要求(開いた後のページ)は新しい鍵を持つ(見立ては新しい鍵を期待している)。
        second.jump(toPageIndex: 4)
        await second.settle()
        let page = try #require(fixture.requests.last { $0.route == .page(4) })
        #expect(page.carriesExpectedToken)
    }

    @Test("ビューアのページの reader と書き戻しの役は、同じセッションを使う(開いている間はビューアが持つ)")
    func viewerHoldsTheSharedSession() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        let viewer = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        let held = try #require(viewer.stackNestBook)
        let reader = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        #expect(reader.book === held)
    }
}

/// 終了のときの送り切り(部品 0.2.0 の `StackNestProgressRegistry.flushAllBlocking`。AppDelegate が `shared` に対して呼ぶ)。
/// 部品の役そのものの振る舞いは部品の試験が押さえる。ここは、ビューアの役がその登録簿に載り、メインで待っても送り切れることを見る。
@MainActor
struct StackNestQuitFlushTests {
    @Test("終了のときは、送っていない位置をメインキューを使わずに送り切る(メインの仕事の中から呼んでも止まらない)")
    func flushesWithoutTheMainQueue() async throws {
        let fixture = try StackNestTestBook(pageCount: 6, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        let viewer = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        let progress = try #require(viewer.stackNestProgress)
        viewer.jump(toPageIndex: 3)
        await viewer.settle()
        #expect(progress.hasUnsentWork)
        #expect(fixture.progressPages.isEmpty)
        // このテストはメインアクター(= メインキューの仕事)の上: ここで待つ作りなら、送りがメインを要るときに止まる。
        let started = ContinuousClock.now
        #expect(harness.stackNestProgressRegistry.flushAllBlocking(timeout: TestPatience.condition) == 1)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(fixture.progressPages == [3])
        // 送り切りへ渡した役は、以後は送らない(送るものが無いので待たない)。
        #expect(!progress.hasUnsentWork)
        let idleStarted = ContinuousClock.now
        #expect(harness.stackNestProgressRegistry.flushAllBlocking(timeout: TestPatience.condition) == 0)
        #expect(ContinuousClock.now - idleStarted < .seconds(1))
    }
}

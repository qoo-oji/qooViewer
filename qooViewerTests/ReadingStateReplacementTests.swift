import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// 「本が差し替えられた」の誤判定で、読書位置の記録(読み方向・読書位置)とブックマークが消えないこと。
///
/// 1.71 で「右開き/左開きの選択が記憶されない」と報告があり、2026-09-25 に 2 つの経路を再現した:
/// 読んでいる途中でページを除外すると、次に開いたとき枚数が合わない(記録は除外後の枚数だった)/ フォルダの本で、
/// Finder が `.DS_Store` を書くなどしてフォルダの更新日時が変わる。どちらも `ContentFingerprint` の食い違いとして
/// 扱われ、`ViewerViewModel.init` が読書位置の記録とブックマークを消していた。
@MainActor
struct ReadingStateReplacementTests {
    /// 開いて左右を切り替え、4 ページ目へ進んでブックマークを付け、`change` をしてから開き直す。
    private func reopenAfter(_ change: (ViewerHarness, MangaBook) async throws -> Void) async throws
        -> (toggled: ReadingDirection, reopened: ViewerViewModel, harness: ViewerHarness)
    {
        let harness = try ViewerHarness()
        harness.preferences.reopenBehavior = .resume
        let book = try await harness.makeBook(pageCount: 6)
        let first = await harness.open(book)
        first.toggleReadingDirection()
        first.jump(toPageIndex: 3)
        first.addBookmark()
        await first.settle()
        let toggled = first.readingDirection
        try await change(harness, book)
        harness.close()
        let reopened = await harness.open(try await harness.reloadBook())
        return (toggled, reopened, harness)
    }

    @Test("何もしなければ、読み方向・読書位置・ブックマークは残る(対照)")
    func nothingChanged() async throws {
        let (toggled, reopened, harness) = try await reopenAfter { _, _ in }
        defer { harness.close() }
        #expect(reopened.readingDirection == toggled)
        #expect(reopened.currentIndex == 3)
        #expect(reopened.bookmarks.count == 1)
    }

    @Test("読んでいる途中でページを除外しても、開き直したときに消えない")
    func excludingAPageKeepsTheReadingState() async throws {
        let (toggled, reopened, harness) = try await reopenAfter { harness, book in
            harness.library.layouts.setPageLayoutState(for: book, pageKey: book.pages[1].sortKey, state: .excluded)
        }
        defer { harness.close() }
        #expect(reopened.readingDirection == toggled)
        #expect(reopened.bookmarks.count == 1)
        // 除外した 2 ページ目が抜けるので、同じページ(元の 4 ページ目)は 3 番目になる。
        #expect(reopened.book.pages[reopened.currentIndex].sortKey.hasSuffix("p04.png"))
    }

    @Test("フォルダの本: フォルダの中に .DS_Store ができても(更新日時が変わっても)消えない")
    func aFolderTouchedByFinderKeepsTheReadingState() async throws {
        let (toggled, reopened, harness) = try await reopenAfter { _, book in
            // 更新日時の分解能(秒)を跨いでから書く。
            try await Task.sleep(for: .milliseconds(1100))
            try Data([0]).write(to: book.sourceURL.appendingPathComponent(".DS_Store"))
        }
        defer { harness.close() }
        #expect(reopened.readingDirection == toggled)
        #expect(reopened.currentIndex == 3)
        #expect(reopened.bookmarks.count == 1)
    }

    @Test("フォルダの本: ページが本当に増えたら、これまでどおり差し替えとして扱う")
    func aFolderWithAnAddedPageIsStillAReplacement() async throws {
        let (_, reopened, harness) = try await reopenAfter { _, book in
            try FileManager.default.copyItem(
                at: book.sourceURL.appendingPathComponent("p01.png"), to: book.sourceURL.appendingPathComponent("p07.png"))
        }
        defer { harness.close() }
        #expect(reopened.readingDirection == harness.preferences.defaultReadingDirection)
        #expect(reopened.currentIndex == 0)
        #expect(reopened.bookmarks.isEmpty)
    }

    @Test("1.71 までの記録(除外を当てた後の枚数)も同じ本とみなし、除外前の枚数に記録し直す")
    func aRecordFromBeforeTheFixIsAccepted() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.reopenBehavior = .resume
        let book = try await harness.makeBook(pageCount: 6)
        let first = await harness.open(book)
        first.toggleReadingDirection()
        await first.settle()
        let toggled = first.readingDirection
        harness.library.layouts.setPageLayoutState(for: book, pageKey: book.pages[1].sortKey, state: .excluded)
        harness.close()
        // 1.71 の書き方: 除外を当てた後の枚数(5)。
        let states = try harness.library.context.fetch(FetchDescriptor<BookReadingState>())
        let row = try #require(states.first { $0.bookID == book.id })
        row.recordedPageCount = 5
        try harness.library.context.save()

        let reopened = await harness.open(try await harness.reloadBook())
        #expect(reopened.readingDirection == toggled)
        let rewritten = try #require(try harness.library.context.fetch(FetchDescriptor<BookReadingState>())
            .first { $0.bookID == book.id })
        #expect(rewritten.recordedPageCount == 6)
    }
}

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

    @Test("ページが本当に増えたら差し替えとして扱うが、読み方向とブックマークは残し、読書位置だけ先頭に戻す")
    func anAddedPageResetsOnlyThePosition() async throws {
        let (toggled, reopened, harness) = try await reopenAfter { _, book in
            try FileManager.default.copyItem(
                at: book.sourceURL.appendingPathComponent("p01.png"), to: book.sourceURL.appendingPathComponent("p07.png"))
        }
        defer { harness.close() }
        #expect(reopened.readingDirection == toggled)
        #expect(reopened.currentIndex == 0)
        // ブックマークを付けた 4 ページ目(p04)は今もある。
        #expect(reopened.bookmarks.count == 1)
    }

    @Test("差し替えとして扱うとき、指しているページが無くなったブックマークだけを消す")
    func aBookmarkOnARemovedPageIsDropped() async throws {
        let (toggled, reopened, harness) = try await reopenAfter { _, book in
            // ブックマークを付けた 4 ページ目を消す(ページ数が変わる)。
            try FileManager.default.removeItem(at: book.sourceURL.appendingPathComponent("p04.png"))
        }
        defer { harness.close() }
        #expect(reopened.readingDirection == toggled)
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

    @Test("ComicInfo.xml の読み方向を取り込み終える前に切り替えても、利用者の向きが残る(画面でも、開き直しても)")
    func aToggleBeforeTheComicInfoImportWins() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let pagesFolder = harness.temporary.file("pages")
        try FixtureFolder.make(at: pagesFolder, pages: (1...4).map {
            FixtureFolder.Page(String(format: "p%02d.png", $0), number: UInt8($0))
        })
        var builder = ZipFixtureBuilder()
        for index in 1...4 {
            let name = String(format: "p%02d.png", index)
            builder.add(name, try Data(contentsOf: pagesFolder.appendingPathComponent(name)), stored: true)
        }
        builder.add("ComicInfo.xml", text: "<?xml version=\"1.0\"?><ComicInfo><Manga>YesAndRightToLeft</Manga></ComicInfo>")
        let url = harness.temporary.file("book.cbz")
        try builder.write(to: url)
        let book = try await FixtureBook.load(url)

        // ViewerHarness.open は起動時の Task を待つので、その前に切り替えるために直接作る。
        let viewer = ViewerViewModel(
            book: book, modelContext: harness.library.context, preferences: harness.preferences,
            layoutStore: harness.library.layouts, metadataStore: harness.library.metadata,
            skipsPersistence: false, usesDiskCaches: false
        )
        if viewer.readingDirection == .leftToRight { viewer.toggleReadingDirection() }   // ファイルと逆の向きから始める
        viewer.toggleReadingDirection()   // 取り込み(起動時の Task)が走る前に左開きへ
        #expect(viewer.readingDirection == .leftToRight)
        await viewer.settle()
        #expect(viewer.readingDirection == .leftToRight)
        viewer.flushPendingSave()
        viewer.releaseResources()

        let reopened = await harness.open(book)
        #expect(reopened.readingDirection == .leftToRight)
    }

    @Test("同じ本を 2 つのウインドウで開いていても、片方で変えた読み方向をもう片方がページ送りで書き戻さない")
    func anotherWindowDoesNotWriteBackTheOldDirection() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.reopenBehavior = .resume
        let book = try await harness.makeBook(pageCount: 6)
        let windowA = await harness.open(book)
        let windowB = await harness.open(book)
        windowB.toggleReadingDirection()
        await windowB.settle()
        let chosen = windowB.readingDirection
        // A は古い向きのままページを送る(読書位置を書く)。
        windowA.jump(toPageIndex: 2)
        await windowA.settle()
        windowA.flushPendingSave()
        windowB.flushPendingSave()
        harness.close()

        let reopened = await harness.open(book)
        #expect(reopened.readingDirection == chosen)
        #expect(reopened.currentIndex == 2)
    }
}

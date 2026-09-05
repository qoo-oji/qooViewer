import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// 「ブックマーク・レイアウトの編集」ウインドウの右ペイン
/// (ViewModels/BookLayoutEditorViewModel.swift)。
///
/// 本は `load(book:usesDiskCaches:)` で渡す ―― 通常の `load()` は共有のディスクキャッシュ
/// (`BookPageListCache.shared`)を読み書きするため、テストからは通れない。
@MainActor
struct BookLayoutEditorTests {
    private func makeEditor(
        _ harness: ViewerHarness, _ book: MangaBook
    ) -> BookLayoutEditorViewModel {
        let editor = BookLayoutEditorViewModel(
            bookID: book.id, layoutStore: harness.library.layouts,
            preferences: harness.preferences, bookmarkStore: harness.library.bookmarks
        )
        editor.load(book: book, usesDiskCaches: false)
        return editor
    }

    /// 一覧が実際に描いている並び(除外ページは末尾へファイル名順)。`movePages` はこの
    /// 空間のインデックスを受け取る(`BookmarkListView.displayedRows` と同じ組み立て)。
    private func displayedKeys(_ editor: BookLayoutEditorViewModel) -> [String] {
        let readable = editor.rows.filter { $0.effectiveReadingIndex != nil }.map(\.pageKey)
        let excluded = editor.rows.filter { $0.effectiveReadingIndex == nil }
            .map(\.pageKey).sorted()
        return readable + excluded
    }

    @Test("行は本のページ順に並び、除外ページだけ読書順の番号を持たない")
    func rowsFollowThePageOrder() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 4)
        let editor = makeEditor(harness, book)

        #expect(editor.rows.map(\.pageKey) == book.pages.map(\.sortKey))
        #expect(editor.rows.map(\.effectiveReadingIndex) == [0, 1, 2, 3])

        await editor.setPageLayout(
            pageKey: book.pages[1].sortKey, to: .excluded, scope: .thisPageOnly
        )
        #expect(editor.rows.map(\.effectiveReadingIndex) == [0, nil, 1, 2])
    }

    @Test("並べ替えで、除外ページは直前の読めるページに付いて動く")
    func excludedPagesFollowThePageTheyHangFrom() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 4)
        let keys = book.pages.map(\.sortKey)
        let editor = makeEditor(harness, book)
        // 2ページ目を除外する(1ページ目に付いている扱いになる)。
        await editor.setPageLayout(pageKey: keys[1], to: .excluded, scope: .thisPageOnly)

        // 一覧では [p1, p3, p4, (p2)]。先頭の p1 を末尾へドラッグする。
        let displayed = displayedKeys(editor)
        #expect(displayed == [keys[0], keys[2], keys[3], keys[1]])
        editor.movePages(displayedPageKeys: displayed, fromOffsets: IndexSet(integer: 0), toOffset: 3)

        // 読めるページの新しい相対順は p3, p4, p1。除外の p2 は p1 の直後のまま。
        #expect(editor.rows.map(\.pageKey) == [keys[2], keys[3], keys[0], keys[1]])
    }

    @Test("並べ替えで解除されるのは、隣が変わった見開き左右だけ")
    func onlyTheSpreadSidesWhoseNeighborChangedAreCleared() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 4)
        let keys = book.pages.map(\.sortKey)
        let layouts = harness.library.layouts
        layouts.setPageLayoutState(for: book, pageKey: keys[0], state: .spreadLeft)
        layouts.setPageLayoutState(for: book, pageKey: keys[2], state: .spreadRight)
        layouts.setPageLayoutState(for: book, pageKey: keys[3], state: .single)
        let editor = makeEditor(harness, book)

        // 3ページ目と4ページ目を入れ替える。
        editor.movePageDown(at: 2)

        #expect(editor.rows.map(\.pageKey) == [keys[0], keys[1], keys[3], keys[2]])
        // p1(見開き左)の次は p2 のまま → 残る。
        #expect(layouts.pageOverride(forBookID: book.id, pageKey: keys[0])?.state == .spreadLeft)
        // p3(見開き右)の直前は p2 → p4 に変わった → 解除される。
        #expect(layouts.pageOverride(forBookID: book.id, pageKey: keys[2])?.state == nil)
        // 「単一ページ」は隣接関係に依存しないページ自体の性質なので残る。
        #expect(layouts.pageOverride(forBookID: book.id, pageKey: keys[3])?.state == .single)
        #expect(editor.reorderWarningMessage != nil)
        editor.dismissReorderWarning()
        #expect(editor.reorderWarningMessage == nil)
    }

    @Test("並べ替えると、ブックマークはページ番号ではなくファイルに追従する")
    func bookmarksFollowTheFileWhenPagesAreReordered() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 4)
        let keys = book.pages.map(\.sortKey)
        harness.library.bookmarks.addBookmark(
            bookID: book.id, pageIndex: 2, pageKey: keys[2], name: "third"
        )
        let editor = makeEditor(harness, book)

        editor.movePageDown(at: 2)

        // ユーザー報告: 画像は入れ替わったのにブックマークが元のページ順に居座っていた。
        #expect(harness.bookmarks(for: book).first?.pageIndex == 3)
        #expect(harness.bookmarks(for: book).first?.pageKey == keys[2])
    }

    @Test("「表示順を初期化する」は自然順へ戻す")
    func resettingTheOrderGoesBackToTheNaturalOrder() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 4)
        let keys = book.pages.map(\.sortKey)
        let editor = makeEditor(harness, book)

        editor.movePageDown(at: 0)
        #expect(editor.rows.map(\.pageKey) == [keys[1], keys[0], keys[2], keys[3]])
        #expect(harness.library.layouts.bookLayoutSettings(forBookID: book.id)?.pageOrderOverride != nil)

        editor.resetOrder()
        #expect(editor.rows.map(\.pageKey) == keys)
        #expect(harness.library.layouts.bookLayoutSettings(forBookID: book.id)?.pageOrderOverride == nil)
    }

    // MARK: - 伝播範囲(3.3節)

    @Test("「このページだけ」は、指示していない相方のページに触れない")
    func thisPageOnlyLeavesThePartnerAlone() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 4)
        let keys = book.pages.map(\.sortKey)
        harness.library.layouts.setReadingDirectionOverride(for: book, .leftToRight)
        let editor = makeEditor(harness, book)

        await editor.setPageLayout(pageKey: keys[1], to: .spreadLeft, scope: .thisPageOnly)

        // ユーザー報告:「ページ2を見開き左に設定すると、指示していないページ3まで見開き右に
        // 変わる」。相方は表示時に自動でペアと判定されるので、書き換える必要は無い。
        #expect(harness.library.layouts.pageOverride(forBookID: book.id, pageKey: keys[1])?.state == .spreadLeft)
        #expect(harness.library.layouts.pageOverride(forBookID: book.id, pageKey: keys[2]) == nil)
        #expect(harness.library.layouts.pageOverride(forBookID: book.id, pageKey: keys[0]) == nil)
    }

    @Test("「このページより後」は、そのページより前を書き換えない")
    func afterThisPageLeavesTheEarlierPagesAlone() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)
        let keys = book.pages.map(\.sortKey)
        let layouts = harness.library.layouts
        // 読み方向は実行環境(システムの言語)で既定が変わるので、必ず明示する。
        layouts.setReadingDirectionOverride(for: book, .leftToRight)
        let editor = makeEditor(harness, book)

        await editor.setPageLayout(pageKey: keys[2], to: .spreadLeft, scope: .afterThisPage)

        #expect(layouts.pageOverride(forBookID: book.id, pageKey: keys[0]) == nil)
        #expect(layouts.pageOverride(forBookID: book.id, pageKey: keys[1]) == nil)
        // 起点(左開きなので次のページと組む)は、その組ごと固定される。
        #expect(layouts.pageOverride(forBookID: book.id, pageKey: keys[2])?.state == .spreadLeft)
        #expect(layouts.pageOverride(forBookID: book.id, pageKey: keys[3])?.state == .spreadRight)
        // 起点より後ろは、その組を保つように振り直される。
        #expect(layouts.pageOverride(forBookID: book.id, pageKey: keys[4])?.state == .spreadLeft)
        #expect(layouts.pageOverride(forBookID: book.id, pageKey: keys[5])?.state == .spreadRight)
    }

    @Test("除外を解除すると、ファイル名から想定される位置へ戻る")
    func unexcludingAPageMovesItBackToItsFilenamePosition() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 4)
        let keys = book.pages.map(\.sortKey)
        let editor = makeEditor(harness, book)

        // 2ページ目を除外してから、並べ替えで末尾へ動かす。
        await editor.setPageLayout(pageKey: keys[1], to: .excluded, scope: .thisPageOnly)
        editor.movePageDown(at: 1)
        editor.movePageDown(at: 2)
        #expect(editor.rows.map(\.pageKey) == [keys[0], keys[2], keys[3], keys[1]])

        await editor.setPageLayout(pageKey: keys[1], to: .single, scope: .thisPageOnly)

        // 除外前にたまたま置かれていた位置ではなく、ファイル名順で来るはずの位置へ。
        #expect(editor.rows.map(\.pageKey) == keys)
    }
}

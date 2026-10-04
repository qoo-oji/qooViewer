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

    @Test("読み方向は ビューアで開いたときと同じ順(上書き > 未取り込みのファイルの指定 > 最後の表示 > 既定)で決まる")
    func theEffectiveReadingDirectionMatchesTheViewer() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.defaultReadingDirectionSetting = .rightToLeft
        var book = try await harness.makeBook(pageCount: 4)

        // 何も無ければ既定。
        #expect(makeEditor(harness, book).effectiveReadingDirection == .rightToLeft)

        // ビューアの r キーで切り替えた本(上書きは作られず BookReadingState にだけ残る)。2026-09-26 まで無視されていた。
        let viewer = await harness.open(book)
        viewer.toggleReadingDirection()
        await viewer.settle()
        #expect(harness.library.layouts.bookLayoutSettings(forBookID: book.id)?.readingDirectionOverride == nil)
        #expect(makeEditor(harness, book).effectiveReadingDirection == .leftToRight)

        // まだ取り込んでいないファイル自身の指定は、最後の表示より先。
        book.sourceLayoutHint = SourceLayoutHint(pageProgressionDirection: .rightToLeft, forcedDisplayMode: nil)
        #expect(makeEditor(harness, book).effectiveReadingDirection == .rightToLeft)

        // 取り込んだ後に利用者が変えた上書きは、ファイルの指定より強い(以前はファイルの指定が勝っていた)。
        harness.library.layouts.importSourceLayoutIfNeeded(for: book)
        harness.library.layouts.setReadingDirectionOverride(for: book, .leftToRight)
        #expect(makeEditor(harness, book).effectiveReadingDirection == .leftToRight)

        // 上の 2 回の書き込みは、開いたままのビューアにレイアウト変更として届き、約 1 フレーム後に読み直し(と保存)が走る。
        // 待たずに終えると、テストの後始末でコンテナが解放された後にその保存が走り、テストホストごと落ちる
        // (「ModelContext.save() called after its ModelContainer has been deallocated」。2026-09-26 に CI の macOS 27 で踏んだ)。
        await viewer.settle()
    }

    @Test("開いたままの右ペインも、ビューアの r キーで変えた向きへ付いていく(2026-10-04 の監査 BE-5)")
    func anOpenEditorFollowsTheViewersReadingDirection() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.defaultReadingDirectionSetting = .rightToLeft
        let book = try await harness.makeBook(pageCount: 4)
        let editor = makeEditor(harness, book)
        #expect(editor.effectiveReadingDirection == .rightToLeft)

        let viewer = await harness.open(book)
        viewer.toggleReadingDirection()
        await viewer.settle()

        // 上書きは作られない(BookReadingState にだけ残る)。以前は、作り直さない限り右ペインは古い向きのままだった。
        #expect(harness.library.layouts.bookLayoutSettings(forBookID: book.id)?.readingDirectionOverride == nil)
        #expect(editor.effectiveReadingDirection == .leftToRight)
        await viewer.settle()
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
        // 2ページ目を除外したまま、並びの末尾に置かれている(2026-10-04 から上へ/下へは除外ページを動かさないので
        // ―― 監査 BE-8 ―― 並びは保存データとして用意する)。
        harness.library.layouts.setPageLayoutState(for: book, pageKey: keys[1], state: .excluded)
        harness.library.layouts.setPageOrderOverride(for: book, [keys[0], keys[2], keys[3], keys[1]])
        let editor = makeEditor(harness, book)
        #expect(editor.rows.map(\.pageKey) == [keys[0], keys[2], keys[3], keys[1]])

        await editor.setPageLayout(pageKey: keys[1], to: .single, scope: .thisPageOnly)

        // 除外前にたまたま置かれていた位置ではなく、ファイル名順で来るはずの位置へ。
        #expect(editor.rows.map(\.pageKey) == keys)
    }

    // MARK: - 2026-10-04 の監査(状態と画面の食い違い)

    @Test("ブックマークは鍵で行に結ぶ。除外で番号が詰まると番号を振り直し、除外したページのものはその行に出る(監査 BE-1)")
    func bookmarksAreMatchedByKeyAndRenumbered() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 6)
        let keys = book.pages.map(\.sortKey)
        let bookmarks = harness.library.bookmarks
        bookmarks.addBookmark(bookID: book.id, pageIndex: 5, pageKey: keys[5], name: "six")
        bookmarks.addBookmark(bookID: book.id, pageIndex: 2, pageKey: keys[2], name: "three")
        let editor = makeEditor(harness, book)

        // どのビューアでも開いていない本で、3 ページ目を除外する。
        await editor.setPageLayout(pageKey: keys[2], to: .excluded, scope: .thisPageOnly)

        // 6 ページ目のブックマークは番号が 4 へ詰まる(以前は 5 のまま残り、7 枚目 ―― 存在しない ―― や別の行に出た)。
        let rows = harness.bookmarks(for: book)
        #expect(rows.first { $0.name == "six" }?.pageIndex == 4)
        // 行との突き合わせは鍵。除外したページのブックマークはその(除外)行に出て、詰まった番号 2 の行(4 ページ目)には出ない。
        let byRow = BookLayoutEditorViewModel.bookmarksByRowKey(bookmarks.bookmarks(forBookID: book.id), rows: editor.rows)
        #expect(byRow[keys[5]]?.name == "six")
        #expect(byRow[keys[2]]?.name == "three")
        #expect(byRow[keys[3]] == nil)
        // 4 ページ目(今の番号 2)の ＋ は足せる(以前は除外ページの古い番号 2 と重なり、黙って何もしなかった)。
        #expect(bookmarks.addBookmark(bookID: book.id, pageIndex: 2, pageKey: keys[3], name: "four"))
    }

    @Test("他所でページ順が変わると行を組み直し、古い並びを書き戻さない(監査 BE-4)")
    func rowsFollowAPageOrderChangedElsewhere() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 4)
        let keys = book.pages.map(\.sortKey)
        let layouts = harness.library.layouts
        layouts.setPageOrderOverride(for: book, [keys[3], keys[2], keys[1], keys[0]])
        let editor = makeEditor(harness, book)
        #expect(editor.rows.map(\.pageKey) == [keys[3], keys[2], keys[1], keys[0]])

        // 「一括操作… ▸ レイアウトをすべて削除」(ほかに保存データの読み込みの上書きなど)。知らせは `.main` の上で届く。
        layouts.discardPageLayout(forBookID: book.id)
        await Task.yield()
        #expect(editor.rows.map(\.pageKey) == keys)

        // ここで下へ 1 つ動かしても、消したはずの逆順は復活しない。
        editor.movePageDown(at: 0)
        #expect(layouts.bookLayoutSettings(forBookID: book.id)?.pageOrderOverride == [keys[1], keys[0], keys[2], keys[3]])
    }

    @Test("上へ/下へは読めるページの並びで動かし、除外ページは動かさない。見開きの隣り合いは読めるページで比べる(監査 BE-8)")
    func movingUsesTheReadableOrder() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        let book = try await harness.makeBook(pageCount: 4)
        let keys = book.pages.map(\.sortKey)
        let layouts = harness.library.layouts
        layouts.setReadingDirectionOverride(for: book, .leftToRight)
        // A(見開き左)・X(除外)・B・C。A は読めるページの次の B と組む。
        layouts.setPageLayoutState(for: book, pageKey: keys[0], state: .spreadLeft)
        layouts.setPageLayoutState(for: book, pageKey: keys[1], state: .excluded)
        let editor = makeEditor(harness, book)

        // 除外ページ X を上へ: 何もしない(以前は真の並びで A と入れ替え、読む順は同じなのに A の見開き左を外した)。
        editor.movePageUp(at: 1)
        #expect(editor.rows.map(\.pageKey) == keys)
        #expect(layouts.pageOverride(forBookID: book.id, pageKey: keys[0])?.state == .spreadLeft)
        #expect(editor.reorderWarningMessage == nil)

        // B を上へ: 読めるページの並びで A の前へ。X は A に付いたまま。A の読む次は B → C に変わったので見開き左は外れる
        // (以前は除外ページを含む並びで比べ、A の次は X のままに見えて外さなかった)。
        editor.movePageUp(at: 2)
        #expect(editor.rows.map(\.pageKey) == [keys[2], keys[0], keys[1], keys[3]])
        #expect(layouts.pageOverride(forBookID: book.id, pageKey: keys[0])?.state == nil)
    }
}

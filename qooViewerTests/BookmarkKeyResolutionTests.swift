import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// ブックマークが「どのページを指しているか」を決める 3 つの経路(ViewModels/BookmarkStore.swift)。
///
/// - `resolveKeys`: 本を開いた時点で、鍵を持たない古い行に鍵を埋め、番号を今の並びへ振り直す。
///   **この計算は 1 か所にしか無い**(型コメントの警告)ので、規則はここで固定しておく。
/// - `updatePageIndices`: ページを並べ替えたとき、ブックマークがスロットではなくファイルへ追従する。
/// - `renameBookmarks`: 一括リネーム。
@MainActor
struct BookmarkKeyResolutionTests {
    private func bookmark(_ pageIndex: Int, key: String? = nil, name: String = "しおり",
                          bookID: String = "/books/a.cbz") -> Bookmark {
        Bookmark(bookID: bookID, pageIndex: pageIndex, pageKey: key, name: name)
    }

    // MARK: - resolveKeys

    @Test("対象が無ければ何も起きない")
    func anEmptyTargetListChangesNothing() {
        let result = BookmarkStore.resolveKeys(
            for: [], legacyOrderedKeys: ["a", "b"], currentOrderedKeys: ["b", "a"], persists: true)
        #expect(result.resolved.isEmpty)
        #expect(!result.didChange)
    }

    @Test("鍵を持つ行は、今の並びでの位置へ番号を振り直す")
    func aKeyedBookmarkFollowsItsPage() {
        let target = bookmark(0, key: "c.jpg")
        let result = BookmarkStore.resolveKeys(
            for: [target],
            legacyOrderedKeys: ["a.jpg", "b.jpg", "c.jpg"],
            currentOrderedKeys: ["a.jpg", "b.jpg", "c.jpg"],
            persists: true)
        #expect(result.resolved[target.id] == 2)
        #expect(target.pageIndex == 2)
        #expect(result.didChange)
    }

    @Test("既に正しい位置なら書き換えない")
    func aBookmarkAlreadyInPlaceIsLeftAlone() {
        let target = bookmark(1, key: "b.jpg")
        let result = BookmarkStore.resolveKeys(
            for: [target], legacyOrderedKeys: ["a.jpg", "b.jpg"], currentOrderedKeys: ["a.jpg", "b.jpg"],
            persists: true)
        #expect(result.resolved[target.id] == 1)
        #expect(!result.didChange)
    }

    @Test("鍵の無い古い行は、必ず**従来順**から鍵を求める(今の並びを使うと別のページを焼き込む)")
    func aLegacyBookmarkTakesItsKeyFromTheLegacyOrder() {
        // 1.36 以前に「3 番目のページ」として保存された行。従来順の 3 番目は c.jpg。
        let target = bookmark(2)
        let result = BookmarkStore.resolveKeys(
            for: [target],
            legacyOrderedKeys: ["a.jpg", "b.jpg", "c.jpg"],
            currentOrderedKeys: ["c.jpg", "b.jpg", "a.jpg"],  // 利用者が並べ替えた今の順
            persists: true)
        #expect(target.pageKey == "c.jpg")
        #expect(result.resolved[target.id] == 0)   // 今の並びでは先頭
        #expect(target.pageIndex == 0)
        #expect(result.didChange)
    }

    @Test("鍵に当たるページが今の本に無ければ、番号はそのまま(消えたページを勝手に付け替えない)")
    func aBookmarkWhosePageIsGoneKeepsItsIndex() {
        let target = bookmark(5, key: "removed.jpg")
        let result = BookmarkStore.resolveKeys(
            for: [target], legacyOrderedKeys: ["a.jpg"], currentOrderedKeys: ["a.jpg"], persists: true)
        #expect(result.resolved[target.id] == 5)
        #expect(target.pageIndex == 5)
        #expect(target.pageKey == "removed.jpg")
        #expect(!result.didChange)
    }

    @Test("古い行の番号が従来順の範囲外なら、鍵は埋めずに番号もそのまま")
    func aLegacyIndexBeyondTheLegacyOrderIsLeftAlone() {
        let target = bookmark(9)
        let result = BookmarkStore.resolveKeys(
            for: [target], legacyOrderedKeys: ["a.jpg", "b.jpg"], currentOrderedKeys: ["a.jpg", "b.jpg"],
            persists: true)
        #expect(target.pageKey == nil)
        #expect(result.resolved[target.id] == 9)
        #expect(!result.didChange)
    }

    @Test("persists: false は行に触れないが、対応表は同じ(シークレットウインドウ)")
    func withoutPersistenceTheRowsAreUntouched() {
        let keyed = bookmark(0, key: "c.jpg")
        let legacy = bookmark(2)
        let result = BookmarkStore.resolveKeys(
            for: [keyed, legacy],
            legacyOrderedKeys: ["a.jpg", "b.jpg", "c.jpg"],
            currentOrderedKeys: ["c.jpg", "b.jpg", "a.jpg"],
            persists: false)
        #expect(result.resolved[keyed.id] == 0)
        #expect(result.resolved[legacy.id] == 0)
        #expect(!result.didChange)
        // DB の行は 1 つも書き換わっていない。
        #expect(keyed.pageIndex == 0)
        #expect(legacy.pageIndex == 2)
        #expect(legacy.pageKey == nil)
    }

    @Test("同じ鍵が今の並びに 2 度出てきたら、先に出てきた方を指す")
    func aDuplicateKeyResolvesToItsFirstOccurrence() {
        let target = bookmark(0, key: "dup.jpg")
        let result = BookmarkStore.resolveKeys(
            for: [target], legacyOrderedKeys: ["dup.jpg"],
            currentOrderedKeys: ["a.jpg", "dup.jpg", "dup.jpg"], persists: true)
        #expect(result.resolved[target.id] == 1)
    }

    @Test("複数の行をまとめて解決できる")
    func severalBookmarksResolveTogether() {
        let first = bookmark(0, key: "a.jpg")
        let second = bookmark(1, key: "b.jpg")
        let third = bookmark(2)
        let result = BookmarkStore.resolveKeys(
            for: [first, second, third],
            legacyOrderedKeys: ["a.jpg", "b.jpg", "c.jpg"],
            currentOrderedKeys: ["c.jpg", "b.jpg", "a.jpg"],
            persists: true)
        #expect(result.resolved[first.id] == 2)
        #expect(result.resolved[second.id] == 1)
        #expect(result.resolved[third.id] == 0)
        #expect(third.pageKey == "c.jpg")
        #expect(result.didChange)
    }

    // MARK: - updatePageIndices

    private func seedBookmarks(_ library: InMemoryLibrary, bookID: String, indices: [Int]) {
        for index in indices {
            library.bookmarks.addBookmark(
                bookID: bookID, pageIndex: index, pageKey: String(format: "%03d.jpg", index),
                name: "しおり\(index)")
        }
    }

    @Test("並べ替えの対応表どおりに番号を書き換える(対応の無い行には触れない)")
    func onlyTheMappedIndicesMove() throws {
        let library = try InMemoryLibrary(label: "bookmark-move")
        defer { library.close() }
        let bookID = "/books/a.cbz"
        seedBookmarks(library, bookID: bookID, indices: [0, 3, 7])

        library.bookmarks.updatePageIndices(forBookID: bookID, oldIndexToNewIndex: [3: 5, 7: 2])
        #expect(library.bookmarkRows(forBookID: bookID).map(\.pageIndex) == [0, 2, 5])
    }

    @Test("対応表が空なら何もしない")
    func anEmptyMappingIsANoOp() throws {
        let library = try InMemoryLibrary(label: "bookmark-empty-map")
        defer { library.close() }
        let bookID = "/books/a.cbz"
        seedBookmarks(library, bookID: bookID, indices: [0, 3])
        library.bookmarks.updatePageIndices(forBookID: bookID, oldIndexToNewIndex: [:])
        #expect(library.bookmarkRows(forBookID: bookID).map(\.pageIndex) == [0, 3])
    }

    @Test("他の本のブックマークは動かさない")
    func anotherBooksBookmarksAreNotTouched() throws {
        let library = try InMemoryLibrary(label: "bookmark-other-book")
        defer { library.close() }
        seedBookmarks(library, bookID: "/books/a.cbz", indices: [3])
        seedBookmarks(library, bookID: "/books/b.cbz", indices: [3])

        library.bookmarks.updatePageIndices(forBookID: "/books/a.cbz", oldIndexToNewIndex: [3: 9])
        #expect(library.bookmarkRows(forBookID: "/books/a.cbz").map(\.pageIndex) == [9])
        #expect(library.bookmarkRows(forBookID: "/books/b.cbz").map(\.pageIndex) == [3])
    }

    @Test("位置の補正では updatedAt を触らない(「更新順」の並びを乱さない)")
    func aMechanicalReindexDoesNotBumpUpdatedAt() throws {
        let library = try InMemoryLibrary(label: "bookmark-updatedat")
        defer { library.close() }
        let bookID = "/books/a.cbz"
        seedBookmarks(library, bookID: bookID, indices: [3])
        let target = try #require(library.bookmarks.bookmarks(forBookID: bookID).first)
        let before = target.updatedAt

        library.bookmarks.updatePageIndices(forBookID: bookID, oldIndexToNewIndex: [3: 8])
        #expect(target.pageIndex == 8)
        #expect(target.updatedAt == before)
    }

    // MARK: - renameBookmarks

    @Test("まとめて改名し、実際に変えた件数を返す")
    func renamingReportsHowManyRowsChanged() throws {
        let library = try InMemoryLibrary(label: "bookmark-rename")
        defer { library.close() }
        let bookID = "/books/a.cbz"
        seedBookmarks(library, bookID: bookID, indices: [0, 1, 2])
        let rows = library.bookmarks.bookmarks(forBookID: bookID).sorted { $0.pageIndex < $1.pageIndex }

        let changed = library.bookmarks.renameBookmarks(
            bookID: bookID,
            renames: [(rows[0], "表紙"), (rows[1], "第 1 話"), (rows[2], "第 2 話")])
        #expect(changed == 3)
        #expect(library.bookmarkRows(forBookID: bookID).map(\.name) == ["表紙", "第 1 話", "第 2 話"])
    }

    @Test("名前の前後の空白は落とし、空になる名前は飛ばす(件数にも数えない)")
    func blankNamesAreSkipped() throws {
        let library = try InMemoryLibrary(label: "bookmark-blank")
        defer { library.close() }
        let bookID = "/books/a.cbz"
        seedBookmarks(library, bookID: bookID, indices: [0, 1])
        let rows = library.bookmarks.bookmarks(forBookID: bookID).sorted { $0.pageIndex < $1.pageIndex }

        let changed = library.bookmarks.renameBookmarks(
            bookID: bookID, renames: [(rows[0], "  表紙  "), (rows[1], "   ")])
        #expect(changed == 1)
        #expect(rows[0].name == "表紙")
        #expect(rows[1].name == "しおり1")
    }

    @Test("1 件も変えなければ 0 を返す")
    func renamingNothingReturnsZero() throws {
        let library = try InMemoryLibrary(label: "bookmark-rename-none")
        defer { library.close() }
        let bookID = "/books/a.cbz"
        seedBookmarks(library, bookID: bookID, indices: [0])
        let rows = library.bookmarks.bookmarks(forBookID: bookID)

        #expect(library.bookmarks.renameBookmarks(bookID: bookID, renames: []) == 0)
        #expect(library.bookmarks.renameBookmarks(bookID: bookID, renames: [(rows[0], "")]) == 0)
        #expect(rows[0].name == "しおり0")
    }

    @Test("改名は updatedAt を進める(位置の補正との違い)")
    func renamingBumpsUpdatedAt() throws {
        let library = try InMemoryLibrary(label: "bookmark-rename-updatedat")
        defer { library.close() }
        let bookID = "/books/a.cbz"
        seedBookmarks(library, bookID: bookID, indices: [0])
        let target = try #require(library.bookmarks.bookmarks(forBookID: bookID).first)
        let before = target.updatedAt

        library.bookmarks.renameBookmarks(bookID: bookID, renames: [(target, "表紙")])
        #expect(target.updatedAt > before)
    }
}

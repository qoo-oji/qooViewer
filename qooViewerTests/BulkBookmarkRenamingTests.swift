import Foundation
import Testing

@testable import qooViewer

/// ブックマークの一括リネームの命名規則(Models/BulkBookmarkRenaming.swift)。
///
/// プレビューと実行に同じ規則が二重に書かれていた場所。1 つにまとめたので、ここで固定する
/// ―― **プレビュー欄に出た並びと名前が、そのまま結果になる**こと。
struct BulkBookmarkRenamingTests {
    private func targets(_ pageIndices: [Int]) -> [BulkBookmarkRenaming.Target] {
        pageIndices.map {
            BulkBookmarkRenaming.Target(id: UUID(), pageIndex: $0, currentName: "old\($0)")
        }
    }

    @Test("既定は、ページ順に連番を振るだけ")
    func theDefaultIsPlainNumbering() {
        let renames = BulkBookmarkRenaming.renames(
            for: targets([0, 3, 7]), options: .init(startNumber: 1)
        )
        #expect(renames.map(\.newName) == ["1", "2", "3"])
        #expect(renames.map(\.currentName) == ["old0", "old3", "old7"])
    }

    @Test("開始番号と前後の文字列は、連番のぶんにだけ効く")
    func thePrefixAndSuffixApplyToTheNumberedOnes() {
        let renames = BulkBookmarkRenaming.renames(
            for: targets([0, 1, 2]),
            options: .init(
                assignsFixedCover: true, coverName: "表紙", startNumber: 10,
                prefix: "第", suffix: "話"
            )
        )
        #expect(renames.map(\.newName) == ["表紙", "第10話", "第11話"])
    }

    @Test("順序は「表紙 → 最後の固定名 → 残りに連番」")
    func theCoverAndTheLastPageAreAssignedFirst() {
        let renames = BulkBookmarkRenaming.renames(
            for: targets([0, 2, 4, 9]),
            options: .init(
                assignsFixedCover: true, coverName: "表紙", lastBookmarkFixedName: "奥付",
                startNumber: 1
            )
        )
        // 連番は表紙と最後を除いたぶんにだけ、1 から振られる。
        #expect(renames.map(\.newName) == ["表紙", "1", "2", "奥付"])
    }

    @Test("表紙になるのはページ番号0のブックマークだけ")
    func onlyTheBookmarkOnTheFirstPageBecomesTheCover() {
        // 先頭ページにブックマークが無ければ、表紙は割り当てない
        // (画面側が1件追加してから、改めてこの規則へ通す)。
        let renames = BulkBookmarkRenaming.renames(
            for: targets([1, 2]), options: .init(assignsFixedCover: true, coverName: "表紙")
        )
        #expect(renames.map(\.newName) == ["1", "2"])
    }

    @Test("表紙が最後のブックマークでもあるときは、表紙が勝つ")
    func theCoverWinsWhenItIsAlsoTheLastBookmark() {
        let renames = BulkBookmarkRenaming.renames(
            for: targets([0]),
            options: .init(
                assignsFixedCover: true, coverName: "表紙", lastBookmarkFixedName: "奥付"
            )
        )
        #expect(renames.map(\.newName) == ["表紙"])
    }

    @Test("戻り値は必ずページ順(プレビュー欄の並びがそのまま結果になる)")
    func theResultIsAlwaysInPageOrder() {
        let renames = BulkBookmarkRenaming.renames(
            for: targets([0, 5, 8]),
            options: .init(
                assignsFixedCover: true, coverName: "表紙", lastBookmarkFixedName: "奥付"
            )
        )
        // 割り当ての順序(表紙 → 奥付 → 連番)とは違う、ページ順に並べ直して返す。
        #expect(renames.map(\.newName) == ["表紙", "1", "奥付"])
        #expect(renames.map(\.currentName) == ["old0", "old5", "old8"])
    }

    @Test("対象が無ければ何も返さない")
    func anEmptyListYieldsNothing() {
        #expect(BulkBookmarkRenaming.renames(for: [], options: .init()).isEmpty)
        #expect(BulkBookmarkRenaming.renames(
            for: [], options: .init(assignsFixedCover: true, lastBookmarkFixedName: "奥付")
        ).isEmpty)
    }
}

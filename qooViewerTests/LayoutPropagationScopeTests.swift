import Foundation
import Testing

@testable import qooViewer

/// レイアウト変更の伝播範囲(Models/LayoutPropagationScope.swift)。
///
/// 選択肢の絞り込みは、元は `ViewerView` と `BookmarkListView` に同じ規則が 2 度書かれていた。
/// 違うのは「どの空間の位置で見るか」だけ ―― ビューアはページ番号、編集ウインドウは除外ページを
/// 除いた読書順 ―― なので、位置を呼び出し側が解決してこの 1 つの規則へ渡す形にまとめてある。
/// 元になったのはユーザー報告「先頭ページなのに『このページより前のページ全体』が出る」。
@MainActor
struct LayoutPropagationScopeTests {
    private func available(_ index: Int?, last: Int?) -> [LayoutPropagationScope] {
        LayoutPropagationScope.available(forIndex: index, lastIndex: last)
    }

    @Test("rawValue は保存データの識別子ではないが、選択肢は 4 つで id と一致する")
    func theOptionsAreFour() {
        #expect(LayoutPropagationScope.allCases.count == 4)
        #expect(LayoutPropagationScope.allCases.map(\.id) == LayoutPropagationScope.allCases.map(\.rawValue))
    }

    @Test("真ん中のページには 4 つすべて出す")
    func aPageInTheMiddleGetsEveryOption() {
        #expect(available(5, last: 10) == LayoutPropagationScope.allCases)
    }

    @Test("先頭のページには「このページより前」を出さない")
    func theFirstPageHasNothingBeforeIt() {
        #expect(available(0, last: 10) == [.thisPageOnly, .wholeBook, .afterThisPage])
    }

    @Test("末尾のページには「このページより後」を出さない")
    func theLastPageHasNothingAfterIt() {
        #expect(available(10, last: 10) == [.thisPageOnly, .wholeBook, .beforeThisPage])
    }

    @Test("1 ページしかない本では、前も後も出さない")
    func aSinglePageBookHasNeitherDirection() {
        #expect(available(0, last: 0) == [.thisPageOnly, .wholeBook])
    }

    @Test("「このページだけ」と「本全体」は必ず出す",
          arguments: [(0, 0), (0, 10), (5, 10), (10, 10), (0, -1)])
    func theTwoUnconditionalOptionsAreAlwaysPresent(index: Int, last: Int) {
        let scopes = available(index, last: last)
        #expect(scopes.contains(.thisPageOnly))
        #expect(scopes.contains(.wholeBook))
    }

    @Test("位置が決まっていないページ(除外中)には、判定せずすべて出す(安全側)")
    func aPageWithNoResolvedPositionGetsEveryOption() {
        // 変更後にどの位置へ入るかは事前に分からない。実害は「前/後を選んでも対象が 0 件」程度。
        #expect(available(nil, last: 10) == LayoutPropagationScope.allCases)
        #expect(available(nil, last: nil) == LayoutPropagationScope.allCases)
    }

    @Test("末尾が決まっていなければ「このページより後」は出さない")
    func anUnknownLastIndexHidesTheAfterOption() {
        // 編集ウインドウで、読書順の位置を持つ行が 1 つも無い(全ページ除外)ときの形。
        #expect(available(0, last: nil) == [.thisPageOnly, .wholeBook])
        #expect(available(5, last: nil) == [.thisPageOnly, .wholeBook, .beforeThisPage])
    }

    @Test("ページが 0 枚の本(末尾が -1)でも前後は出さない")
    func anEmptyBookOffersNeitherDirection() {
        // ビューア側は `pages.count - 1` を渡すので、0 枚だと -1 になる。
        #expect(available(0, last: -1) == [.thisPageOnly, .wholeBook])
    }

    @Test("並びは allCases の順のまま(ダイアログのボタンの並びが入れ替わらない)")
    func theOrderFollowsAllCases() {
        for last in [0, 1, 5, 10] {
            for index in 0...last {
                let scopes = available(index, last: last)
                #expect(scopes == LayoutPropagationScope.allCases.filter { scopes.contains($0) })
            }
        }
    }
}

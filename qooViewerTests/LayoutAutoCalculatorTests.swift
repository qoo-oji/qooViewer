import Foundation
import Testing

@testable import qooViewer

/// 自動レイアウトのパリティ計算(Services/LayoutAutoCalculator.swift)。
///
/// 何度もユーザー報告で直してきた箇所なので、直した性質をそのまま固定する:
/// - 起点から**前後へ**ペアを広げる(端数は起点から最も遠い側へ押し出す)
/// - 横長画像は常に単独。**ペアの相手が横長でも**ペアにしない
/// - 「見開き左/見開き右」のラベルは、読み方向を考慮して常に画面上の左右と一致させる
struct LayoutAutoCalculatorTests {
    /// p0 … p6 の 7 ページ。起点は真ん中の p3(=前も後も 3 ページの奇数)。
    private let keys = (0...6).map { "p\($0)" }
    private let anchor = LayoutAutoCalculator.Anchor(pageKeys: ["p3"])

    private func recalculate(
        scope: LayoutPropagationScope,
        anchor: LayoutAutoCalculator.Anchor? = nil,
        keys: [String]? = nil,
        wide: Set<String> = [],
        isRightToLeft: Bool = false
    ) -> [String: PageLayoutState] {
        LayoutAutoCalculator.recalculate(
            orderedPageKeys: keys ?? self.keys, anchor: anchor ?? self.anchor, scope: scope,
            isWideImage: { wide.contains($0) }, isRightToLeft: isRightToLeft
        )
    }

    // MARK: - 伝播範囲

    @Test("このページだけ、は何も返さない(呼び出し側が1ページ分を直接書く)")
    func thisPageOnlyReturnsNothing() {
        #expect(recalculate(scope: .thisPageOnly).isEmpty)
    }

    @Test("起点より前は、起点の隣からペアにして、端数は本の先頭へ押し出す")
    func beforeThisPagePairsFromTheAnchorSide() {
        // ユーザー報告: 以前は本の先頭から前方へ計算していたため、端数の単独ページが
        // 起点のすぐ隣(p2)に生まれていた。
        #expect(recalculate(scope: .beforeThisPage) == [
            "p0": .single,
            "p1": .spreadLeft, "p2": .spreadRight,
        ])
    }

    @Test("起点より後は、起点の隣からペアにして、端数は本の末尾に残る")
    func afterThisPagePairsFromTheAnchorSide() {
        #expect(recalculate(scope: .afterThisPage) == [
            "p4": .spreadLeft, "p5": .spreadRight,
            "p6": .single,
        ])
    }

    @Test("「前」「後」は起点自身を含まない")
    func theAnchorItselfIsNotTouchedByBeforeOrAfter() {
        #expect(recalculate(scope: .beforeThisPage)["p3"] == nil)
        #expect(recalculate(scope: .afterThisPage)["p3"] == nil)
    }

    @Test("本全体は、起点自身を固定した上で前と後を合わせたもの")
    func wholeBookIsTheAnchorPlusBothSides() {
        let whole = recalculate(scope: .wholeBook)
        #expect(whole["p3"] == .single)
        for (key, state) in recalculate(scope: .beforeThisPage) { #expect(whole[key] == state) }
        for (key, state) in recalculate(scope: .afterThisPage) { #expect(whole[key] == state) }
        #expect(whole.count == keys.count)
    }

    // MARK: - 起点の固定

    @Test("2ページ表示が起点なら、その組み合わせをそのまま固定する")
    func twoPageAnchorIsPinnedAsASpread() {
        let anchor = LayoutAutoCalculator.Anchor(pageKeys: ["p2", "p3"])
        let ltr = recalculate(scope: .wholeBook, anchor: anchor)
        #expect(ltr["p2"] == .spreadLeft)
        #expect(ltr["p3"] == .spreadRight)
        // 右開きでは、先に読む p2 が画面の右。ラベルもそれに合わせる。
        let rtl = recalculate(scope: .wholeBook, anchor: anchor, isRightToLeft: true)
        #expect(rtl["p2"] == .spreadRight)
        #expect(rtl["p3"] == .spreadLeft)
    }

    @Test("起点が本に無ければ何も返さない")
    func unknownAnchorReturnsNothing() {
        let anchor = LayoutAutoCalculator.Anchor(pageKeys: ["ghost"])
        #expect(recalculate(scope: .wholeBook, anchor: anchor).isEmpty)
    }

    @Test("起点が空でも落ちない")
    func emptyAnchorReturnsNothing() {
        let anchor = LayoutAutoCalculator.Anchor(pageKeys: [])
        #expect(recalculate(scope: .wholeBook, anchor: anchor).isEmpty)
    }

    // MARK: - 読み方向

    @Test("右開きは左開きの鏡(単独ページはそのまま)")
    func rightToLeftMirrorsTheLabels() {
        let ltr = recalculate(scope: .wholeBook)
        let rtl = recalculate(scope: .wholeBook, isRightToLeft: true)
        #expect(ltr.keys.sorted() == rtl.keys.sorted())
        for (key, state) in ltr {
            switch state {
            case .single: #expect(rtl[key] == .single)
            case .spreadLeft: #expect(rtl[key] == .spreadRight)
            case .spreadRight: #expect(rtl[key] == .spreadLeft)
            case .excluded: Issue.record("自動レイアウトが除外を書き込んではいけない")
            }
        }
    }

    @Test("自動レイアウトは除外を書き込まない")
    func exclusionIsNeverWritten() {
        #expect(!recalculate(scope: .wholeBook).values.contains(.excluded))
    }

    // MARK: - 横長画像

    @Test("横長画像は常に単独ページ")
    func wideImagesAreAlwaysSingle() {
        let result = recalculate(scope: .afterThisPage, wide: ["p4"])
        #expect(result["p4"] == .single)
        #expect(result["p5"] == .spreadLeft)
        #expect(result["p6"] == .spreadRight)
    }

    @Test("ペアの相手が横長なら、ペアにしない")
    func aWidePartnerBreaksThePair() {
        // ユーザー報告の決定表: 横長ページを相手にした見開きは常に不成立。
        // 以前は cursor 自身の横長判定しか無く、p4 が p5 を見開き右として巻き込んでいた。
        let result = recalculate(scope: .afterThisPage, wide: ["p5"])
        #expect(result["p4"] == .single)
        #expect(result["p5"] == .single)
        #expect(result["p6"] == .single)
    }

    @Test("「前」側でも、相手が横長ならペアにしない")
    func aWidePartnerBreaksThePairGoingBackward() {
        // 逆順に走査する側(simulateBackward)にも同じ判定が効いている。
        let result = recalculate(scope: .beforeThisPage, wide: ["p1"])
        #expect(result["p2"] == .single)
        #expect(result["p1"] == .single)
        #expect(result["p0"] == .single)
    }

    @Test("全ページが横長なら、全ページが単独ページ")
    func allWideMeansAllSingle() {
        let result = recalculate(scope: .wholeBook, wide: Set(keys))
        #expect(result == Dictionary(uniqueKeysWithValues: keys.map { ($0, PageLayoutState.single) }))
    }

    // MARK: - 端

    @Test("起点が先頭なら「前」は空、末尾なら「後」は空")
    func rangesAtTheEdgesAreEmpty() {
        let first = LayoutAutoCalculator.Anchor(pageKeys: ["p0"])
        let last = LayoutAutoCalculator.Anchor(pageKeys: ["p6"])
        #expect(recalculate(scope: .beforeThisPage, anchor: first).isEmpty)
        #expect(recalculate(scope: .afterThisPage, anchor: last).isEmpty)
    }

    @Test("1ページだけの本")
    func singlePageBook() {
        let anchor = LayoutAutoCalculator.Anchor(pageKeys: ["only"])
        let result = recalculate(scope: .wholeBook, anchor: anchor, keys: ["only"])
        #expect(result == ["only": .single])
    }

    @Test("偶数ページなら、片側に端数は出ない")
    func evenRangesPairUpCompletely() {
        let keys = (0...5).map { "p\($0)" } // 起点 p3 の前は 3 ページ・後は 2 ページ
        let after = recalculate(scope: .afterThisPage, keys: keys)
        #expect(after == ["p4": .spreadLeft, "p5": .spreadRight])
    }
}

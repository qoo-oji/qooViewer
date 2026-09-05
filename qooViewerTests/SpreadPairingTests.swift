import Foundation
import Testing

@testable import qooViewer

/// 見開きの組の作り方(Models/SpreadPairing.swift)と、組とは関係なく決まる着地先
/// (`PageLanding`)。
///
/// この規則は `ViewerViewModel` の 5 か所へ同じ形で書かれていた ―― どれも利用者報告を受けて
/// 別々の時期に足されたもので、実機でしか確かめられなかった。純粋型へ出したので、ここで
/// 表引きにして固定する。
///
/// `PageSpreadPosition`(EPUB の `page-spread-left` / `right`)は**画面上の絶対位置**で、
/// 読み順の 1 枚目・2 枚目とは読み方向によって入れ替わる。表はどちらの読み方向でも同じ形で
/// 書けるよう、`first`(読み順の 1 枚目の位置)/`second`(2 枚目の位置)から組み立てる。
@MainActor
struct SpreadPairingTests {
    private let directions: [ReadingDirection] = [.rightToLeft, .leftToRight]

    /// ページごとのヒントを配列で与える閉包。
    private func hints(_ values: [PageSpreadPosition?]) -> (Int) -> PageSpreadPosition? {
        { index in values.indices.contains(index) ? values[index] : nil }
    }

    // MARK: - 画面上の位置と読み順

    @Test("読み順の1枚目/2枚目が画面のどちら側かは、読み方向で入れ替わる")
    func theSidesSwapWithTheReadingDirection() {
        #expect(SpreadPairing.firstOfPairPosition(.rightToLeft) == .right)
        #expect(SpreadPairing.secondOfPairPosition(.rightToLeft) == .left)
        #expect(SpreadPairing.firstOfPairPosition(.leftToRight) == .left)
        #expect(SpreadPairing.secondOfPairPosition(.leftToRight) == .right)
    }

    // MARK: - 明示指定だけでの組の可否(規則の本体)

    @Test("明示指定だけで組の可否が決まる16通り(読み方向によらず同じ形)")
    func theExplicitPairingTable() {
        for direction in directions {
            let first = SpreadPairing.firstOfPairPosition(direction)
            let second = SpreadPairing.secondOfPairPosition(direction)
            // (1枚目の指定, 2枚目の指定) → 期待。nil は「明示指定では決まらない」。
            let table: [(PageSpreadPosition?, PageSpreadPosition?, Bool?)] = [
                (nil, nil, nil),
                // 1枚目の側:「1枚目の位置」なら組める。「2枚目の位置」「center」なら組めない。
                (first, nil, true), (second, nil, false), (.center, nil, false),
                // 2枚目の側:「2枚目の位置」なら組める。「1枚目の位置」「center」なら組めない。
                (nil, second, true), (nil, first, false), (nil, .center, false),
                // 両方に指定があるとき。整合していれば組める。
                (first, second, true),
                (first, first, false), (first, .center, false),
                (second, second, false), (second, first, false), (second, .center, false),
                (.center, second, false), (.center, first, false), (.center, .center, false),
            ]
            for (a, b, expected) in table {
                let actual = SpreadPairing.explicitPairing(
                    first: a, second: b, readingDirection: direction
                )
                #expect(actual == expected, "\(direction) / first=\(String(describing: a)) second=\(String(describing: b))")
            }
        }
    }

    // MARK: - 次のページと組むか

    @Test("単ページ表示モードと最後のページでは組まない")
    func neverPairsInSinglePageModeOrAtTheEnd() {
        for direction in directions {
            #expect(
                SpreadPairing.shouldPairWithNextPage(
                    at: 0, pageCount: 2, displayMode: .single, readingDirection: direction,
                    hint: hints([nil, nil]), isFirstImageWide: { false }
                ) == false
            )
            #expect(
                SpreadPairing.shouldPairWithNextPage(
                    at: 1, pageCount: 2, displayMode: .spread, readingDirection: direction,
                    hint: hints([nil, nil]), isFirstImageWide: { false }
                ) == false
            )
        }
    }

    @Test("明示指定が無いときだけ、横長画像は単独ページになる")
    func theWideImageHeuristicAppliesOnlyWithoutExplicitHints() {
        for direction in directions {
            let first = SpreadPairing.firstOfPairPosition(direction)
            #expect(
                SpreadPairing.shouldPairWithNextPage(
                    at: 0, pageCount: 2, displayMode: .spread, readingDirection: direction,
                    hint: hints([nil, nil]), isFirstImageWide: { true }
                ) == false
            )
            #expect(
                SpreadPairing.shouldPairWithNextPage(
                    at: 0, pageCount: 2, displayMode: .spread, readingDirection: direction,
                    hint: hints([nil, nil]), isFirstImageWide: { false }
                ) == true
            )
            // 明示指定は横長ヒューリスティックに勝つ。
            #expect(
                SpreadPairing.shouldPairWithNextPage(
                    at: 0, pageCount: 2, displayMode: .spread, readingDirection: direction,
                    hint: hints([first, nil]), isFirstImageWide: { true }
                ) == true
            )
        }
    }

    @Test("明示指定で結論が出るときは、横長判定を評価しない(判定のキャッシュに触れない)")
    func theWideImageCheckIsNotEvaluatedWhenTheHintDecides() {
        for direction in directions {
            var evaluated = false
            _ = SpreadPairing.shouldPairWithNextPage(
                at: 0, pageCount: 2, displayMode: .spread, readingDirection: direction,
                hint: hints([.center, nil]), isFirstImageWide: { evaluated = true; return false }
            )
            // 本体(ViewerViewModel.isWideImage)は判定結果をキャッシュへ書き込む副作用を持つ。
            #expect(evaluated == false)
        }
    }

    @Test("直前に表示していたページは、明示指定が無いときに限り相方として再利用しない")
    func aPreviouslyDisplayedPageIsNotReusedAsAPartner() {
        for direction in directions {
            let first = SpreadPairing.firstOfPairPosition(direction)
            // 「1ページだけ送る」でずらした組が、前後のページ送りで勝手に組み直されるのを防ぐ。
            #expect(
                SpreadPairing.shouldPairWithNextPage(
                    at: 0, pageCount: 3, displayMode: .spread, readingDirection: direction,
                    hint: hints([nil, nil, nil]), previousDisplayedRange: 1..<3,
                    isFirstImageWide: { false }
                ) == false
            )
            // 明示指定があるときは、そちらの権威的な指定を優先する。
            #expect(
                SpreadPairing.shouldPairWithNextPage(
                    at: 0, pageCount: 3, displayMode: .spread, readingDirection: direction,
                    hint: hints([first, nil, nil]), previousDisplayedRange: 1..<3,
                    isFirstImageWide: { false }
                ) == true
            )
        }
    }

    // MARK: - ページ送りの幅

    @Test("戻り幅は、直前の見開きが何枚で構成されているかで決まる")
    func theBackwardStepFollowsThePreviousSpread() {
        for direction in directions {
            let first = SpreadPairing.firstOfPairPosition(direction)
            let second = SpreadPairing.secondOfPairPosition(direction)
            let noHints = hints([nil, nil, nil, nil])

            // 単ページ表示・手前が無い場合は従来どおりの近似。
            #expect(SpreadPairing.backwardStepSize(
                from: 2, fallback: 9, displayMode: .single, readingDirection: direction,
                hint: noHints, cachedIsWide: { _ in nil }) == 9)
            #expect(SpreadPairing.backwardStepSize(
                from: 0, fallback: 9, displayMode: .spread, readingDirection: direction,
                hint: noHints, cachedIsWide: { _ in nil }) == 9)
            // 手前が1ページしか無いなら、戻り幅は1で確定。
            #expect(SpreadPairing.backwardStepSize(
                from: 1, fallback: 9, displayMode: .spread, readingDirection: direction,
                hint: noHints, cachedIsWide: { _ in nil }) == 1)
            // 明示指定で組と分かれば2、組めないと分かれば1。
            #expect(SpreadPairing.backwardStepSize(
                from: 2, fallback: 9, displayMode: .spread, readingDirection: direction,
                hint: hints([first, second, nil]), cachedIsWide: { _ in nil }) == 2)
            #expect(SpreadPairing.backwardStepSize(
                from: 2, fallback: 9, displayMode: .spread, readingDirection: direction,
                hint: hints([.center, nil, nil]), cachedIsWide: { _ in nil }) == 1)
            // 明示指定が無いときは、一度でも表示したページの横長判定を使う。
            // 経緯(ユーザー報告): 1ページ目だけ横長で単独の本を見開きで読み進め、戻ると
            // 1・2ページ目をまとめて飛び越えていた(近似のfallbackを使っていたため)。
            #expect(SpreadPairing.backwardStepSize(
                from: 2, fallback: 9, displayMode: .spread, readingDirection: direction,
                hint: noHints, cachedIsWide: { $0 == 0 ? true : nil }) == 1)
            #expect(SpreadPairing.backwardStepSize(
                from: 2, fallback: 9, displayMode: .spread, readingDirection: direction,
                hint: noHints, cachedIsWide: { $0 == 0 ? false : nil }) == 2)
            // 判定結果がどこにも無いときだけ近似へ落ちる。
            #expect(SpreadPairing.backwardStepSize(
                from: 2, fallback: 9, displayMode: .spread, readingDirection: direction,
                hint: noHints, cachedIsWide: { _ in nil }) == 9)
        }
    }

    @Test("進み幅は、いま表示中のページなら実際の表示枚数を信じる")
    func theForwardStepTrustsTheRenderedCountForTheDisplayedPage() {
        for direction in directions {
            let first = SpreadPairing.firstOfPairPosition(direction)
            let second = SpreadPairing.secondOfPairPosition(direction)
            let noHints = hints([nil, nil, nil, nil])

            #expect(SpreadPairing.forwardStepSize(
                from: 0, fallback: 9, pageCount: 3, isDisplayedIndex: true, displayMode: .single,
                readingDirection: direction, hint: noHints, cachedIsWide: { _ in nil }) == 9)
            #expect(SpreadPairing.forwardStepSize(
                from: 2, fallback: 9, pageCount: 3, isDisplayedIndex: true, displayMode: .spread,
                readingDirection: direction, hint: noHints, cachedIsWide: { _ in nil }) == 9)
            // 明示指定はいちばん強い(表示中かどうかに関わらず)。
            #expect(SpreadPairing.forwardStepSize(
                from: 0, fallback: 9, pageCount: 3, isDisplayedIndex: true, displayMode: .spread,
                readingDirection: direction, hint: hints([first, second, nil]),
                cachedIsWide: { _ in nil }) == 2)
            #expect(SpreadPairing.forwardStepSize(
                from: 0, fallback: 9, pageCount: 3, isDisplayedIndex: true, displayMode: .spread,
                readingDirection: direction, hint: hints([nil, first, nil]),
                cachedIsWide: { _ in nil }) == 1)
            // 表示中のページなら、横長判定より実際の表示枚数(fallback)を優先する。
            // 経緯(ユーザー報告): 直前の相方を再利用しない制約で単ページ化されている場合を
            // 横長判定は知らないため、2ページ進んで次のページを飛び越えていた。
            #expect(SpreadPairing.forwardStepSize(
                from: 0, fallback: 1, pageCount: 3, isDisplayedIndex: true, displayMode: .spread,
                readingDirection: direction, hint: noHints, cachedIsWide: { _ in false }) == 1)
            // 表示中でない(待ち行列に目的地が積まれている)ときは、横長判定のほうがまし。
            #expect(SpreadPairing.forwardStepSize(
                from: 0, fallback: 1, pageCount: 3, isDisplayedIndex: false, displayMode: .spread,
                readingDirection: direction, hint: noHints, cachedIsWide: { _ in false }) == 2)
            #expect(SpreadPairing.forwardStepSize(
                from: 0, fallback: 2, pageCount: 3, isDisplayedIndex: false, displayMode: .spread,
                readingDirection: direction, hint: noHints, cachedIsWide: { _ in true }) == 1)
            #expect(SpreadPairing.forwardStepSize(
                from: 0, fallback: 9, pageCount: 3, isDisplayedIndex: false, displayMode: .spread,
                readingDirection: direction, hint: noHints, cachedIsWide: { _ in nil }) == 9)
        }
    }

    // MARK: - 見開きが維持できるか

    @Test("レイアウト更新後も見開きが成立するかは、明示指定 → 残っている横長判定の順で見る")
    func theAnchorPairSurvivesOnlyWhenItCanBeDecided() {
        for direction in directions {
            let first = SpreadPairing.firstOfPairPosition(direction)
            let second = SpreadPairing.secondOfPairPosition(direction)
            #expect(SpreadPairing.spreadPairStillDisplayable(
                atAnchorIndex: 0, pageCount: 2, displayMode: .spread, readingDirection: direction,
                hint: hints([first, second]), cachedIsWide: { _ in nil }) == true)
            #expect(SpreadPairing.spreadPairStillDisplayable(
                atAnchorIndex: 0, pageCount: 2, displayMode: .spread, readingDirection: direction,
                hint: hints([nil, first]), cachedIsWide: { _ in nil }) == false)
            #expect(SpreadPairing.spreadPairStillDisplayable(
                atAnchorIndex: 0, pageCount: 2, displayMode: .spread, readingDirection: direction,
                hint: hints([nil, nil]), cachedIsWide: { _ in false }) == true)
            // 判定結果が残っていなければ、見開きの維持はあきらめる(安全側)。
            #expect(SpreadPairing.spreadPairStillDisplayable(
                atAnchorIndex: 0, pageCount: 2, displayMode: .spread, readingDirection: direction,
                hint: hints([nil, nil]), cachedIsWide: { _ in nil }) == false)
            // 相方が無い・単ページ表示。
            #expect(SpreadPairing.spreadPairStillDisplayable(
                atAnchorIndex: 1, pageCount: 2, displayMode: .spread, readingDirection: direction,
                hint: hints([nil, nil]), cachedIsWide: { _ in false }) == false)
            #expect(SpreadPairing.spreadPairStillDisplayable(
                atAnchorIndex: 0, pageCount: 2, displayMode: .single, readingDirection: direction,
                hint: hints([nil, nil]), cachedIsWide: { _ in false }) == false)
        }
    }

    // MARK: - 着地先の補正

    @Test("「2枚目」を指定されたページへ直接着地しようとしたら、組の起点へ寄せる")
    func landingOnASecondOfPairMovesToTheAnchor() {
        for direction in directions {
            let first = SpreadPairing.firstOfPairPosition(direction)
            let second = SpreadPairing.secondOfPairPosition(direction)
            for mode in [DisplayMode.spread, .single] {
                #expect(SpreadPairing.normalizedAnchorIndex(
                    1, pageCount: 3, displayMode: mode, readingDirection: direction,
                    hint: hints([first, second, nil])) == 0)
            }
            // 先頭ページと範囲外はそのまま。
            #expect(SpreadPairing.normalizedAnchorIndex(
                0, pageCount: 3, displayMode: .spread, readingDirection: direction,
                hint: hints([second, nil, nil])) == 0)
            #expect(SpreadPairing.normalizedAnchorIndex(
                3, pageCount: 3, displayMode: .spread, readingDirection: direction,
                hint: hints([nil, nil, nil])) == 3)
        }
    }

    @Test("指定の無いページでも、直前のページが「1枚目」を主張していれば組の起点へ寄せる")
    func landingRespectsThePredecessorsClaim() {
        for direction in directions {
            let first = SpreadPairing.firstOfPairPosition(direction)
            // 経緯(ユーザー報告): 自動レイアウトの右開きの本で、見開きの左ページの
            // 「レイアウト情報を削除する」を実行すると見開きが単ページ表示に崩れていた。
            #expect(SpreadPairing.normalizedAnchorIndex(
                1, pageCount: 3, displayMode: .spread, readingDirection: direction,
                hint: hints([first, nil, nil])) == 0)
            // 「今の位置の描き直し」では適用しない(ずらした組が勝手に引き戻される)。
            #expect(SpreadPairing.normalizedAnchorIndex(
                1, pageCount: 3, displayMode: .spread, readingDirection: direction,
                honorsPredecessorClaim: false, hint: hints([first, nil, nil])) == 1)
            // 単ページ表示中は組の判定に意味が無い(指定したページが表示されなくなる)。
            #expect(SpreadPairing.normalizedAnchorIndex(
                1, pageCount: 3, displayMode: .single, readingDirection: direction,
                hint: hints([first, nil, nil])) == 1)
            // そのページ自身に指定があるなら、直前の主張は見ない。
            #expect(SpreadPairing.normalizedAnchorIndex(
                1, pageCount: 3, displayMode: .spread, readingDirection: direction,
                hint: hints([first, first, nil])) == 1)
        }
    }

    // MARK: - 組とは関係なく決まる着地先

    @Test("消えたページの代わりは、元の並びで後ろ → 前の順に探す")
    func theFallbackIndexPrefersTheFollowingPage() {
        let old = ["a", "b", "c", "d"].map(Self.page)
        #expect(PageLanding.fallbackIndex(
            oldPages: old, currentIndex: 1, newPages: ["a", "c", "d"].map(Self.page)) == 1)
        // 後ろに現存ページが無ければ手前へさかのぼる。
        #expect(PageLanding.fallbackIndex(
            oldPages: old, currentIndex: 2, newPages: ["a", "b"].map(Self.page)) == 1)
        // 1ページも残っていない・現在位置が範囲外なら先頭。
        #expect(PageLanding.fallbackIndex(oldPages: old, currentIndex: 1, newPages: []) == 0)
        #expect(PageLanding.fallbackIndex(
            oldPages: old, currentIndex: 9, newPages: ["a"].map(Self.page)) == 0)
    }

    @Test("数字キーのジャンプは、全体に対する割合でページを選ぶ")
    func thePercentileJumpPicksTheProportionalPage() {
        #expect(PageLanding.pageIndex(forPercentile: 0, pageCount: 10) == 0)
        #expect(PageLanding.pageIndex(forPercentile: 50, pageCount: 10) == 5)
        #expect(PageLanding.pageIndex(forPercentile: 90, pageCount: 10) == 9)
        // 100%は最後のページ(切り上がって範囲外にならない)。
        #expect(PageLanding.pageIndex(forPercentile: 100, pageCount: 10) == 9)
        #expect(PageLanding.pageIndex(forPercentile: 0, pageCount: 0) == 0)
    }

    private static func page(_ key: String) -> PageRef {
        PageRef(id: key, sortKey: key, source: .file(URL(fileURLWithPath: "/tmp/\(key).jpg")))
    }
}

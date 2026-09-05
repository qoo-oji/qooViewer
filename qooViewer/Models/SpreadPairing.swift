import Foundation

/// **見開きの組の作り方**。どの 2 ページが 1 つの見開きになるか、という規則だけを取り出した型。
///
/// この規則は `ViewerViewModel` の 5 か所(`shouldPairWithNextPage` / `backwardStepSize` /
/// `forwardStepSize` / `spreadPairStillDisplayable` / `normalizedAnchorIndex`)へ同じ形で
/// 書かれていた。どれも利用者報告を受けて別々の時期に足されたもので、**同じ規則が別々に
/// 書かれている**という形そのものが、片方だけ直してもう片方が古いまま残るという不具合の
/// 温床になる。規則の本体をここに 1 つだけ置き、5 か所はここを呼ぶ。
///
/// `nonisolated` なのは、画面も本の実体も持たない純粋な計算だから(テストから直接叩ける)。
/// ページのヒントと横長判定は、呼び出し側が閉包で渡す ―― 本体は `ViewerViewModel` の
/// `layoutHint(at:)`(DB > ファイル の優先順位)と `wideImageCache` にある。
///
/// ■ 画面上の左右は読み方向で入れ替わる
/// `PageSpreadPosition`(EPUB の `page-spread-left` / `right`)は**画面上の絶対位置**を表す。
/// 一方この規則が問うのは「読み順で先に読むページか、後に読むページか」なので、右開き
/// (右→左)と左開き(左→右)で見る位置が入れ替わる。
nonisolated enum SpreadPairing {
    /// 見開きの **1 枚目**(読み順で先に読むページ)が置かれる画面上の位置。
    /// 右開きなら画面右、左開きなら画面左。
    static func firstOfPairPosition(_ direction: ReadingDirection) -> PageSpreadPosition {
        direction == .rightToLeft ? .right : .left
    }

    /// 見開きの **2 枚目**(読み順で後に読むページ)が置かれる画面上の位置。
    /// この位置を明示されたページは、常に直前のページと組む ―― 自分が見開きの起点には
    /// なれない(EPUB Publications 仕様の `page-spread-right` の意味そのもの)。
    static func secondOfPairPosition(_ direction: ReadingDirection) -> PageSpreadPosition {
        direction == .rightToLeft ? .left : .right
    }

    /// 隣り合う 2 ページが 1 つの見開きになるかどうかを、**EPUB / DB 由来の明示指定だけ**で
    /// 判定する。決められない場合は nil ―― 呼び出し側が横長画像のヒューリスティック
    /// (横長なら 1 ページとして単独表示)へ落とす。
    ///
    /// - `center` はどちらの側でも単独表示なので組めない。
    /// - 1 枚目の側に「2 枚目の位置」が指定されていれば組めない(そのページは直前と組む)。
    /// - 2 枚目の側に「1 枚目の位置」が指定されていれば組めない(そのページは次と組む)。
    /// - どちらか一方にでも指定があり、上のどれにも当たらなければ組める
    ///   (**明示指定は横長ヒューリスティックに勝つ**)。
    static func explicitPairing(
        first: PageSpreadPosition?, second: PageSpreadPosition?, readingDirection: ReadingDirection
    ) -> Bool? {
        if first == .center || first == secondOfPairPosition(readingDirection) { return false }
        if second == .center || second == firstOfPairPosition(readingDirection) { return false }
        if first != nil || second != nil { return true }
        return nil
    }

    /// `index` のページが次のページと組んで見開きになるか。
    ///
    /// - Parameters:
    ///   - isFirstImageWide: 明示指定で決まらなかったときだけ評価される、1 枚目の画像が
    ///     横長かどうか(横長なら単独表示)。閉包にしてあるのは、本体(`isWideImage`)が
    ///     判定結果をキャッシュへ書く副作用を持つため ―― 結論が先に出た場合は呼ばない。
    ///   - previousDisplayedRange: 直前に実際に表示していたページの範囲。明示指定が
    ///     どちらにも無いときに限り、**その範囲のページを新しい組の相方として再利用しない**
    ///     (「1 ページだけ送る」でずらした組が、前後のページ送りで勝手に組み直される
    ///     のを防ぐ。`ViewerViewModel.lastDisplayedPageRange` のコメント参照)。
    static func shouldPairWithNextPage(
        at index: Int, pageCount: Int, displayMode: DisplayMode, readingDirection: ReadingDirection,
        hint: (Int) -> PageSpreadPosition?, previousDisplayedRange: Range<Int>? = nil,
        isFirstImageWide: () -> Bool
    ) -> Bool {
        guard displayMode == .spread, index + 1 < pageCount else { return false }
        if let explicit = explicitPairing(
            first: hint(index), second: hint(index + 1), readingDirection: readingDirection
        ) {
            return explicit
        }
        if let previousDisplayedRange, previousDisplayedRange.contains(index + 1) { return false }
        return !isFirstImageWide()
    }

    /// 「前のページへ戻る」で戻る幅(1 か 2)。
    ///
    /// 正しい戻り幅は、**いま表示している枚数ではなく、直前にある見開きが何枚で構成されて
    /// いるか**(`index - 2` と `index - 1` が組かどうか)で決まる。明示指定で決まらない
    /// ときは、一度でも表示したページなら残っている横長判定(`cachedIsWide`)を使い、それも
    /// 無ければ従来どおりの近似(`fallback` = いま表示している枚数)へ落とす。
    static func backwardStepSize(
        from index: Int, fallback: Int, displayMode: DisplayMode, readingDirection: ReadingDirection,
        hint: (Int) -> PageSpreadPosition?, cachedIsWide: (Int) -> Bool?
    ) -> Int {
        guard displayMode == .spread else { return fallback }
        guard index - 1 >= 0 else { return fallback }
        guard index - 2 >= 0 else { return 1 }
        if let explicit = explicitPairing(
            first: hint(index - 2), second: hint(index - 1), readingDirection: readingDirection
        ) {
            return explicit ? 2 : 1
        }
        if let earlierIsWide = cachedIsWide(index - 2) { return earlierIsWide ? 1 : 2 }
        return fallback
    }

    /// 「次のページへ進む」で進む幅(1 か 2)。上の前進版。
    ///
    /// - Parameter isDisplayedIndex: `index` が、いま画面に実際に出ているページかどうか。
    ///   真なら `fallback`(= 実際にレンダリングされた枚数)が横長判定より信頼できる ――
    ///   `previousDisplayedRange` による単ページ化まで含んだ「実際の結果」だから。
    ///   偽(ホイールを速く回して待ち行列に目的地が積まれている)のとき、`fallback` は
    ///   別の位置の枚数を指すので、横長判定のほうがましになる。
    static func forwardStepSize(
        from index: Int, fallback: Int, pageCount: Int, isDisplayedIndex: Bool,
        displayMode: DisplayMode, readingDirection: ReadingDirection,
        hint: (Int) -> PageSpreadPosition?, cachedIsWide: (Int) -> Bool?
    ) -> Int {
        guard displayMode == .spread else { return fallback }
        guard index >= 0, index + 1 < pageCount else { return fallback }
        if let explicit = explicitPairing(
            first: hint(index), second: hint(index + 1), readingDirection: readingDirection
        ) {
            return explicit ? 2 : 1
        }
        if isDisplayedIndex { return fallback }
        if let currentIsWide = cachedIsWide(index) { return currentIsWide ? 1 : 2 }
        return fallback
    }

    /// いま画面に出ている見開き(起点 `index` と相方 `index + 1`)が、更新後のレイアウトでも
    /// 2 枚組のまま成立するか。画像を読み込めない同期的な判定なので、明示指定で決まらない
    /// ときは残っている横長判定だけを見て、それも無ければ false(見開きの維持をあきらめる
    /// 安全側)に倒す。
    static func spreadPairStillDisplayable(
        atAnchorIndex index: Int, pageCount: Int, displayMode: DisplayMode,
        readingDirection: ReadingDirection,
        hint: (Int) -> PageSpreadPosition?, cachedIsWide: (Int) -> Bool?
    ) -> Bool {
        guard displayMode == .spread, index >= 0, index + 1 < pageCount else { return false }
        if let explicit = explicitPairing(
            first: hint(index), second: hint(index + 1), readingDirection: readingDirection
        ) {
            return explicit
        }
        return cachedIsWide(index) == false
    }

    /// 生のページ番号を、正しい組の**起点**へ補正する。
    ///
    /// 通常のページ送りは組の判定に従って進むので自然に正しい起点へ着地する。この補正が要る
    /// のは、それまでの経緯を無視してどこかへ直接着地する経路(ジャンプ・再開位置・ループの
    /// 折り返し・レイアウト再読込)だけ。
    ///
    /// 補正の条件は 2 つ(どちらも結論は「1 つ前のページを起点にする」):
    /// 1. そのページ自身に「2 枚目」の明示指定がある(そのページは直前と組む)。
    /// 2. そのページには指定が無く、**直前のページに「1 枚目」の明示指定がある**。
    ///    明示指定は横長ヒューリスティックに勝つので、直前のページは必ずこのページと組む ――
    ///    そのまま着地するとその組を割ってしまう。組の判定が意味を持つ見開き表示中だけ。
    ///
    /// - Parameter honorsPredecessorClaim: false なら条件 2 を適用しない。「どこかへ着地し直す」
    ///   のではなく「いまの位置の描き直し」のときに使う ―― 描き直しにまで効かせると、
    ///   「1 ページだけ送る」で意図的にずらした組が、無関係な再読込のたびに元へ引き戻される。
    static func normalizedAnchorIndex(
        _ rawIndex: Int, pageCount: Int, displayMode: DisplayMode,
        readingDirection: ReadingDirection, honorsPredecessorClaim: Bool = true,
        hint: (Int) -> PageSpreadPosition?
    ) -> Int {
        guard rawIndex > 0, rawIndex < pageCount else { return rawIndex }
        let position = hint(rawIndex)
        if position == secondOfPairPosition(readingDirection) { return rawIndex - 1 }
        if honorsPredecessorClaim, position == nil, displayMode == .spread,
           hint(rawIndex - 1) == firstOfPairPosition(readingDirection) {
            return rawIndex - 1
        }
        return rawIndex
    }
}

/// 見開きの組とは関係なく決まる**着地先**。`SpreadPairing` と同じ理由でここに出してある。
nonisolated enum PageLanding {
    /// 除外(非表示)に設定されたことで、直前まで表示していたページ自体が新しい並びから
    /// 消えてしまったときの着地先。元の並びで**現在位置以降**にある現存ページを優先し、
    /// 無ければ手前へさかのぼる。1 ページも残っていなければ 0。
    static func fallbackIndex(oldPages: [PageRef], currentIndex: Int, newPages: [PageRef]) -> Int {
        guard !newPages.isEmpty else { return 0 }
        guard oldPages.indices.contains(currentIndex) else { return 0 }
        for oldPage in oldPages[currentIndex...] {
            if let index = newPages.firstIndex(where: { $0.sortKey == oldPage.sortKey }) {
                return index
            }
        }
        for oldPage in oldPages[..<currentIndex].reversed() {
            if let index = newPages.firstIndex(where: { $0.sortKey == oldPage.sortKey }) {
                return index
            }
        }
        return 0
    }

    /// 数字キー(0〜9)のページジャンプ。全体に対する割合(0〜100)からページ番号を出す。
    static func pageIndex(forPercentile percentile: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return max(0, min(pageCount - 1, pageCount * percentile / 100))
    }
}

import CoreGraphics

/// **プログレスバーの当たり判定とフィルムストリップの表示範囲**。カーソルの x 座標から
/// 「どのページか」「フィルムストリップの何番目に置くか」、そして「どのページを並べるか」を
/// 決める計算だけを取り出した型。
///
/// `ProgressBarView` の中に private な関数として置かれていて、実機でしか確かめられなかった。
/// 読み方向による左右の反転がどこに効いて、どこに効かないのかが要。
nonisolated enum FilmstripLayout {
    /// 画面上の x 座標(バーの左端が 0)に対応するページ番号。
    ///
    /// **右開きのときは割合を左右反転させる** ―― バーが右から左へ進むため。
    static func pageIndex(
        atX x: CGFloat, width: CGFloat, pageCount: Int, isRightToLeft: Bool
    ) -> Int {
        guard width > 0, pageCount > 0 else { return 0 }
        let rawFraction = min(max(x / width, 0), 1)
        let fraction = isRightToLeft ? (1 - rawFraction) : rawFraction
        return min(Int(fraction * CGFloat(pageCount)), pageCount - 1)
    }

    /// カーソルの下のページを、フィルムストリップの何番目(0 が画面左端)に置くか。
    ///
    /// **こちらは反転させない**。読む方向によらず、画面上の実際の左右位置とスロット番号が
    /// そのまま対応してほしいため(カーソルの下にそのページが来る)。
    static func highlightSlot(atX x: CGFloat, width: CGFloat, visibleCount: Int) -> Int {
        guard visibleCount > 0 else { return 0 }
        guard width > 0 else { return visibleCount / 2 }
        let rawFraction = min(max(x / width, 0), 1)
        let slot = Int((rawFraction * CGFloat(visibleCount - 1)).rounded())
        return min(max(slot, 0), visibleCount - 1)
    }

    /// フィルムストリップに並べるページの範囲。
    ///
    /// `centerIndex` がスロットの `slot` 番目に来るように取り、**端に近いときはページ数の
    /// 範囲内へ寄せる**(そのとき `centerIndex` は `slot` 番目には来ない)。
    /// 右開きでは表示配列を反転して並べるため、「右から数えたスロット」が画面上の左からの
    /// 位置と一致するよう、`centerIndex` を範囲の上端側から数える。
    static func visibleRange(
        centeredOn centerIndex: Int, slot: Int, pageCount: Int, visibleCount: Int,
        isRightToLeft: Bool
    ) -> ClosedRange<Int> {
        guard pageCount > 0, visibleCount > 0 else { return 0...0 }
        if pageCount <= visibleCount {
            return 0...(pageCount - 1)
        }
        let clampedSlot = min(max(slot, 0), visibleCount - 1)
        var start: Int
        var end: Int
        if isRightToLeft {
            end = centerIndex + clampedSlot
            start = end - visibleCount + 1
        } else {
            start = centerIndex - clampedSlot
            end = start + visibleCount - 1
        }
        if start < 0 {
            start = 0
            end = visibleCount - 1
        }
        if end > pageCount - 1 {
            end = pageCount - 1
            start = end - visibleCount + 1
        }
        return start...end
    }
}

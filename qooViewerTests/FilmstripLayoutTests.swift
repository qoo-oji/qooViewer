import CoreGraphics
import Testing

@testable import qooViewer

/// プログレスバーの当たり判定とフィルムストリップの表示範囲(Models/FilmstripLayout.swift)。
///
/// 要は**読み方向による左右の反転がどこに効いて、どこに効かないか**。
struct FilmstripLayoutTests {

    // MARK: - クリック位置からページ番号

    @Test("左開きは左が先頭、右開きは右が先頭")
    func theBarRunsInTheReadingDirection() {
        func index(_ x: CGFloat, isRightToLeft: Bool) -> Int {
            FilmstripLayout.pageIndex(atX: x, width: 100, pageCount: 10, isRightToLeft: isRightToLeft)
        }
        #expect(index(0, isRightToLeft: false) == 0)
        #expect(index(50, isRightToLeft: false) == 5)
        #expect(index(100, isRightToLeft: false) == 9)
        // 右開きはバーが右から左へ進む。
        #expect(index(0, isRightToLeft: true) == 9)
        // ちょうど中央は、割合が 0.5 のまま(反転しても 0.5)なので両方とも5ページ目。
        #expect(index(50, isRightToLeft: true) == 5)
        #expect(index(100, isRightToLeft: true) == 0)
    }

    @Test("バーの外へはみ出した座標は端に丸める")
    func coordinatesOutsideTheBarAreClamped() {
        #expect(FilmstripLayout.pageIndex(atX: -50, width: 100, pageCount: 10, isRightToLeft: false) == 0)
        #expect(FilmstripLayout.pageIndex(atX: 500, width: 100, pageCount: 10, isRightToLeft: false) == 9)
        // 大きさもページ数もまだ無いうちは先頭。
        #expect(FilmstripLayout.pageIndex(atX: 50, width: 0, pageCount: 10, isRightToLeft: false) == 0)
        #expect(FilmstripLayout.pageIndex(atX: 50, width: 100, pageCount: 0, isRightToLeft: false) == 0)
    }

    // MARK: - カーソル下のページを置くスロット

    @Test("スロットは画面上の左右そのもの(読み方向で反転しない)")
    func theHighlightSlotIsNotMirrored() {
        for isRightToLeft in [true, false] {
            _ = isRightToLeft  // 読み方向は引数に取らない ―― それがこの関数の要点。
            #expect(FilmstripLayout.highlightSlot(atX: 0, width: 100, visibleCount: 9) == 0)
            #expect(FilmstripLayout.highlightSlot(atX: 50, width: 100, visibleCount: 9) == 4)
            #expect(FilmstripLayout.highlightSlot(atX: 100, width: 100, visibleCount: 9) == 8)
        }
        // 大きさが取れないうちは真ん中。
        #expect(FilmstripLayout.highlightSlot(atX: 50, width: 0, visibleCount: 9) == 4)
        #expect(FilmstripLayout.highlightSlot(atX: 500, width: 100, visibleCount: 9) == 8)
    }

    // MARK: - 表示範囲

    @Test("ページ数が枚数以下なら、全部並べる")
    func aShortBookShowsEveryPage() {
        #expect(FilmstripLayout.visibleRange(
            centeredOn: 1, slot: 4, pageCount: 3, visibleCount: 9, isRightToLeft: false) == 0...2)
        #expect(FilmstripLayout.visibleRange(
            centeredOn: 0, slot: 0, pageCount: 0, visibleCount: 9, isRightToLeft: false) == 0...0)
    }

    @Test("左開きは指定のスロットに、右開きは右から数えた位置に来る")
    func theCenterPageLandsOnTheRequestedSlot() {
        // 左開き: スロット4(中央)に20ページ目 → 16...24。
        #expect(FilmstripLayout.visibleRange(
            centeredOn: 20, slot: 4, pageCount: 100, visibleCount: 9, isRightToLeft: false)
            == 16...24)
        // 右開きは表示配列を反転して並べるので、範囲の上端側から数える。
        #expect(FilmstripLayout.visibleRange(
            centeredOn: 20, slot: 4, pageCount: 100, visibleCount: 9, isRightToLeft: true)
            == 16...24)
        // 中央以外だと差が出る(左端のスロットを指定した場合)。
        #expect(FilmstripLayout.visibleRange(
            centeredOn: 20, slot: 0, pageCount: 100, visibleCount: 9, isRightToLeft: false)
            == 20...28)
        #expect(FilmstripLayout.visibleRange(
            centeredOn: 20, slot: 0, pageCount: 100, visibleCount: 9, isRightToLeft: true)
            == 12...20)
    }

    @Test("端に近いときは、ページ数の範囲へ寄せる")
    func theRangeIsPushedInsideAtTheEnds() {
        for isRightToLeft in [true, false] {
            #expect(FilmstripLayout.visibleRange(
                centeredOn: 0, slot: 4, pageCount: 100, visibleCount: 9,
                isRightToLeft: isRightToLeft) == 0...8)
            #expect(FilmstripLayout.visibleRange(
                centeredOn: 99, slot: 4, pageCount: 100, visibleCount: 9,
                isRightToLeft: isRightToLeft) == 91...99)
        }
        // 範囲外のスロットを渡されても、必ず枚数ぶんの範囲になる。
        let range = FilmstripLayout.visibleRange(
            centeredOn: 50, slot: 99, pageCount: 100, visibleCount: 9, isRightToLeft: false
        )
        #expect(range.count == 9)
    }
}

import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// コントラスト補正(Services/ContrastCorrector.swift)。
///
/// 押さえたいのは3つ:
/// - **カラーページには一切手を加えない**(ユーザー要望)。判定に迷ったら元の画像をそのまま返す。
/// - 白黒ページはチャンネルごとにオートレベルする ―― 紙の黄ばみ(青チャンネルの白点だけが低い)を
///   取るには、全チャンネル共通の補正では足りない。
/// - ほぼ単色のページは補正しない(暴走しうるため)。
struct ContrastCorrectorTests {
    private let size = 64

    /// 画素を交互に 2 色で塗った画像(ヒストグラムが 2 本になる)。
    private func twoTone(
        _ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)
    ) -> CGImage {
        PixelGrid.image(width: size, height: size) { x, y in (x + y).isMultiple(of: 2) ? a : b }
    }

    private func corners(of image: CGImage) -> (dark: (Int, Int, Int), light: (Int, Int, Int)) {
        let (rgb, _, _) = PixelGrid.pixels(of: image)
        // (0,0) と (1,0) は市松模様の別の色。
        let first = rgb(0, 0)
        let second = rgb(1, 0)
        return first.1 < second.1 ? (first, second) : (second, first)
    }

    // MARK: - 手を加えない場合

    @Test("カラーページは元の画像をそのまま返す")
    func colorPagesAreLeftUntouched() {
        // 色相が複数のビンにまたがると「実際のカラーページ」と判定される。
        let hues: [(UInt8, UInt8, UInt8)] = [(220, 40, 40), (40, 220, 40), (40, 40, 220), (220, 220, 40)]
        let image = PixelGrid.image(width: size, height: size) { x, y in hues[(x + y) % hues.count] }
        #expect(ContrastCorrector.apply(to: image) === image)
    }

    @Test("ほぼ単色のページは補正しない")
    func nearlyUniformPagesAreLeftUntouched() {
        // 黒点と白点の差が 10 未満なら、補正しても意味が無い・暴走しうるので無補正。
        let image = twoTone((200, 200, 200), (205, 205, 205))
        #expect(ContrastCorrector.apply(to: image) === image)
    }

    @Test("完全な単色のページも補正しない")
    func aSolidPageIsLeftUntouched() {
        let image = PixelGrid.image(width: size, height: size) { _, _ in (128, 128, 128) }
        #expect(ContrastCorrector.apply(to: image) === image)
    }

    // MARK: - 補正する場合

    @Test("眠い白黒ページは、黒点・白点まで引き伸ばす")
    func aWashedOutGrayPageIsStretched() {
        let image = twoTone((100, 100, 100), (180, 180, 180))
        let corrected = ContrastCorrector.apply(to: image)
        #expect(corrected !== image)
        #expect((corrected.width, corrected.height) == (size, size))

        let (dark, light) = corners(of: corrected)
        #expect(dark.0 <= 8 && dark.1 <= 8 && dark.2 <= 8)
        #expect(light.0 >= 247 && light.1 >= 247 && light.2 >= 247)
    }

    @Test("紙の黄ばみは、チャンネルごとの補正で取れる")
    func aYellowedPageLosesItsColorCast() {
        // 紙(R=G=200, B=150)とインク(60)。青だけ白点が低いので、共通の補正では黄色が残る。
        let image = twoTone((60, 60, 60), (200, 200, 150))
        let corrected = ContrastCorrector.apply(to: image)
        #expect(corrected !== image)

        let (dark, light) = corners(of: corrected)
        #expect(dark.0 <= 8 && dark.1 <= 8 && dark.2 <= 8)
        // 紙が白へ ―― 3 チャンネルが揃うことが「色被りが取れた」ということ。
        #expect(light.0 >= 247 && light.1 >= 247 && light.2 >= 247)
    }

    @Test("色の付いた画素がごく僅かなら、カラーページとは見なさない")
    func aFewColoredPixelsDoNotMakeItAColorPage() {
        // 2% 未満なら色相のばらつきを見るまでもなく白黒ページ扱い。
        let image = PixelGrid.image(width: size, height: size) { x, y in
            if x == 0, y < 10 { return (220, 40, 40) }
            return (x + y).isMultiple(of: 2) ? (100, 100, 100) : (180, 180, 180)
        }
        #expect(ContrastCorrector.apply(to: image) !== image)
    }

    @Test("既にきっちりした白黒のページは、そのまま白黒のまま")
    func anAlreadyCorrectPageStaysCorrect() {
        let image = twoTone((0, 0, 0), (255, 255, 255))
        let corrected = ContrastCorrector.apply(to: image)
        let (dark, light) = corners(of: corrected)
        #expect(dark.0 <= 8)
        #expect(light.0 >= 247)
    }
}

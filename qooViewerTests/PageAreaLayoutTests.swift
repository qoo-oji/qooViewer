import CoreGraphics
import Testing

@testable import qooViewer

/// ページ表示領域の幾何(Models/PageAreaLayout.swift)。
///
/// `ViewerView` の中の private な関数だったため、実機でしか確かめられなかった計算。
/// 画像そのものは要らず寸法だけで決まるので、純粋型へ出して表引きで固定する。
struct PageAreaLayoutTests {
    private let tall = PageAreaLayout.Slot.image(CGSize(width: 100, height: 200))
    private let wide = PageAreaLayout.Slot.image(CGSize(width: 400, height: 200))

    // MARK: - 枠の並べ方

    @Test("実画像が1枚だけで画面上の位置の明示があるときだけ、反対側へ空白を差し込む")
    func aBlankIsInsertedOppositeTheForcedSide() {
        // EPUB Reading Systems 3.3 の 6.1.4(相方が無くても指定した側に置く)。
        #expect(PageAreaLayout.placements(imageCount: 1, soleImageForcedPosition: .left)
            == [.image(0), .blank])
        #expect(PageAreaLayout.placements(imageCount: 1, soleImageForcedPosition: .right)
            == [.blank, .image(0)])
        // center は単独表示そのものなので空白は要らない。
        #expect(PageAreaLayout.placements(imageCount: 1, soleImageForcedPosition: .center)
            == [.image(0)])
        #expect(PageAreaLayout.placements(imageCount: 1, soleImageForcedPosition: nil)
            == [.image(0)])
        // 2枚揃っているときは、指定があっても空白は入らない。
        #expect(PageAreaLayout.placements(imageCount: 2, soleImageForcedPosition: .left)
            == [.image(0), .image(1)])
        #expect(PageAreaLayout.placements(imageCount: 0, soleImageForcedPosition: .left) == [])
    }

    // MARK: - 基準の高さと幅

    @Test("基準の高さは見開き内で最大(空白は数えない)")
    func theReferenceHeightIsTheTallestImage() {
        #expect(PageAreaLayout.referenceHeight(for: [tall, .image(CGSize(width: 50, height: 300))])
            == 300)
        #expect(PageAreaLayout.referenceHeight(for: [.blank]) == 0)
        #expect(PageAreaLayout.referenceHeight(for: []) == 0)
    }

    @Test("幅は縦横比を保ったまま基準の高さへ合わせる")
    func theDisplayWidthKeepsTheAspectRatio() {
        #expect(PageAreaLayout.displayWidth(for: tall, atHeight: 400, mirrorAspectRatio: 1) == 200)
        // 空白は相方の縦横比を借りる。
        #expect(PageAreaLayout.displayWidth(for: .blank, atHeight: 400, mirrorAspectRatio: 0.5) == 200)
        // 高さ0の画像は幅0(0除算を避ける)。
        #expect(PageAreaLayout.displayWidth(
            for: .image(CGSize(width: 100, height: 0)), atHeight: 400, mirrorAspectRatio: 1) == 0)
    }

    @Test("解像度の違う2ページは、物理的な高さを揃えて横に並べる")
    func twoPagesAreLinedUpAtTheSameHeight() {
        // 左は 100x200、右は 200x400(同じ縦横比で解像度だけ2倍)。基準は 400。
        let slots: [PageAreaLayout.Slot] = [tall, .image(CGSize(width: 200, height: 400))]
        let height = PageAreaLayout.referenceHeight(for: slots)
        #expect(height == 400)
        // 画素数をそのまま使うと低解像度の側が小さく見える。高さを揃えれば同じ幅になる。
        #expect(PageAreaLayout.totalContentSize(for: slots, referenceHeight: height)
            == CGSize(width: 400, height: 400))
    }

    @Test("空白の幅は、並んでいる実画像の縦横比から決める")
    func theBlankBorrowsTheAspectRatioOfTheRealPage() {
        let slots: [PageAreaLayout.Slot] = [tall, .blank]
        #expect(PageAreaLayout.referenceAspectRatio(for: slots) == 0.5)
        #expect(PageAreaLayout.totalContentSize(for: slots, referenceHeight: 200)
            == CGSize(width: 200, height: 200))
        // 実画像が1枚も無ければ正方形とみなす(実際には起こらない組み合わせ)。
        #expect(PageAreaLayout.referenceAspectRatio(for: [.blank]) == 1)
        #expect(PageAreaLayout.totalContentSize(for: [], referenceHeight: 200) == .zero)
        #expect(PageAreaLayout.totalContentSize(for: slots, referenceHeight: 0) == .zero)
    }

    // MARK: - 表示倍率

    private func scale(
        _ mode: ScalingMode, content: CGSize, container: CGSize,
        maxUpscalePercent: Double = 10_000, threshold: Double = 1.0
    ) -> CGFloat {
        PageAreaLayout.renderScale(
            contentSize: content, containerSize: container, scalingMode: mode,
            maxUpscalePercent: maxUpscalePercent, singlePageAspectRatioThreshold: threshold
        )
    }

    @Test("「画面内に収める」は縦横の収まる方に合わせる")
    func fitToScreenUsesTheSmallerOfTheTwo() {
        // 横は 2 倍、縦は 1.5 倍まで入る → 1.5 倍。
        #expect(scale(.fitToScreen, content: CGSize(width: 100, height: 200),
                      container: CGSize(width: 200, height: 300)) == 1.5)
    }

    @Test("「横幅に合わせる」は横だけを見る")
    func fitWidthOnlyLooksAtTheWidth() {
        #expect(scale(.fitWidth, content: CGSize(width: 100, height: 200),
                      container: CGSize(width: 300, height: 100)) == 3)
    }

    @Test("「横幅に合わせる(単ページ)」は、分割する意味のある内容だけ半分の幅で合わせる")
    func fitWidthSplitDividesOnlyWhenItMakesSense() {
        // 見開き相当(横長)の内容 → 半分が画面幅いっぱいになる倍率。
        #expect(scale(.fitWidthSplit, content: CGSize(width: 400, height: 200),
                      container: CGSize(width: 400, height: 100)) == 2)
        // 縦長の内容は分割しても読みにくいだけなので、「横幅に合わせる」と同じ結果にする。
        #expect(scale(.fitWidthSplit, content: CGSize(width: 100, height: 200),
                      container: CGSize(width: 400, height: 100)) == 4)
        // 判定の境目は環境設定の「単ページとみなす縦横比」。
        #expect(scale(.fitWidthSplit, content: CGSize(width: 300, height: 200),
                      container: CGSize(width: 300, height: 100), threshold: 1.6) == 1)
        #expect(scale(.fitWidthSplit, content: CGSize(width: 400, height: 200),
                      container: CGSize(width: 400, height: 100), threshold: 1.6) == 2)
    }

    @Test("最大拡大率は、拡大するモードすべてに効く")
    func theMaximumUpscaleCapsEveryZoomingMode() {
        let content = CGSize(width: 100, height: 100)
        let container = CGSize(width: 1000, height: 1000)
        for mode in [ScalingMode.fitToScreen, .fitWidth, .fitWidthSplit] {
            #expect(scale(mode, content: content, container: container, maxUpscalePercent: 200) == 2)
        }
        // 「拡大縮小しない」は常に等倍。
        #expect(scale(.noScale, content: content, container: container) == 1)
        // 大きさが取れないうちは等倍(0除算を避ける)。
        #expect(scale(.fitToScreen, content: .zero, container: container) == 1)
        #expect(scale(.fitToScreen, content: content, container: .zero) == 1)
    }

    // MARK: - スクロールできる中身の大きさ

    @Test("表示領域より小さい方向は、表示領域の大きさを下限にする(縦は画面内に収めるときだけ)")
    func theViewportIsAFloorForTheScrollableContent() {
        let content = CGSize(width: 100, height: 100)
        let viewport = CGSize(width: 400, height: 400)

        // 「画面内に収める」(ピンチ拡大中)は縦も持ち上げる ―― 片方の辺だけ画面に収まって
        // いる状態でも画像が隅に寄らないように。
        #expect(PageAreaLayout.scrollContentSize(
            contentSize: content, scale: 1, viewport: viewport, scalingMode: .fitToScreen)
            == viewport)
        // 他のモードの見え方は変えない(縦が短いときは上詰めのまま)。
        #expect(PageAreaLayout.scrollContentSize(
            contentSize: content, scale: 1, viewport: viewport, scalingMode: .fitWidth)
            == CGSize(width: 400, height: 100))
        // はみ出す方向は拡大後の大きさをそのまま使う。
        #expect(PageAreaLayout.scrollContentSize(
            contentSize: content, scale: 8, viewport: viewport, scalingMode: .noScale)
            == CGSize(width: 800, height: 800))
    }
}

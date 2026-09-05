import CoreGraphics

/// **ページ表示領域の幾何**。見開きのスロットの並べ方、基準の高さ、表示倍率、スクロールできる
/// 中身の大きさ ―― 画面に何を出すかを決める計算だけを取り出した型。
///
/// `ViewerView` の中に private な関数として置かれていて、実機でしか確かめられなかった。
/// 画像そのものは要らず**寸法(`CGSize`)だけ**で決まる計算なので、`nonisolated` な型へ出して
/// ある(`ViewerView` 側の同名の関数は、`SpreadPageSlot` をここの `Slot` に写して呼ぶだけ)。
nonisolated enum PageAreaLayout {
    /// 見開きの1枠。実画像は寸法だけを持ち、空白は寸法を持たない。
    enum Slot: Equatable {
        case image(CGSize)
        case blank
    }

    /// 実画像と空白の並び。`placements` が返す「何番目の実画像か / 空白か」の列。
    enum Placement: Equatable {
        case image(Int)
        case blank
    }

    /// 表示順(画面上の左→右)に並んだ実画像から、見開きの枠の並びを決める。
    ///
    /// 実画像が1枚だけで、そのページに画面上の位置の明示(EPUB の `page-spread-left` /
    /// `right`、または DB の同等の設定)があるときだけ、**反対側へ空白を差し込む** ――
    /// EPUB Reading Systems 3.3 の 6.1.4「相方が見つからなくても指定した側に置く(MUST)」を
    /// 満たすため。`center` は単独表示そのものなので空白は要らない。
    static func placements(
        imageCount: Int, soleImageForcedPosition: PageSpreadPosition?
    ) -> [Placement] {
        guard imageCount == 1, let position = soleImageForcedPosition else {
            return (0..<max(imageCount, 0)).map { .image($0) }
        }
        switch position {
        case .left: return [.image(0), .blank]
        case .right: return [.blank, .image(0)]
        case .center: return [.image(0)]
        }
    }

    /// 見開き内で最大の高さ。
    ///
    /// 左右で解像度が違う本(スキャン元がバラバラ)でも、実際の本のように**物理的な高さを
    /// 揃えて**表示したい。画素数をそのまま使うと、解像度の低い側が小さく表示されてしまう。
    static func referenceHeight(for slots: [Slot]) -> CGFloat {
        slots.compactMap { slot -> CGFloat? in
            if case .image(let size) = slot { return size.height }
            return nil
        }.max() ?? 0
    }

    /// スロット列の中の実画像のうち、最初に見つかったものの縦横比(幅/高さ)。
    /// 空白スロットの幅を決めるための近似値。実画像が1枚も無ければ 1(正方形)。
    static func referenceAspectRatio(for slots: [Slot]) -> CGFloat {
        for slot in slots {
            if case .image(let size) = slot, size.height > 0 {
                return size.width / size.height
            }
        }
        return 1
    }

    /// 基準の高さに揃えたときの、このスロットの幅(縦横比は保つ)。
    static func displayWidth(
        for slot: Slot, atHeight height: CGFloat, mirrorAspectRatio: CGFloat
    ) -> CGFloat {
        switch slot {
        case .image(let size):
            guard size.height > 0 else { return 0 }
            return height * size.width / size.height
        case .blank:
            return height * mirrorAspectRatio
        }
    }

    /// スロット列を横に並べたときの、拡大前の中身の大きさ。
    static func totalContentSize(for slots: [Slot], referenceHeight: CGFloat) -> CGSize {
        guard !slots.isEmpty, referenceHeight > 0 else { return .zero }
        let mirrorAspectRatio = referenceAspectRatio(for: slots)
        let width = slots.reduce(CGFloat(0)) {
            $0 + displayWidth(for: $1, atHeight: referenceHeight, mirrorAspectRatio: mirrorAspectRatio)
        }
        return CGSize(width: width, height: referenceHeight)
    }

    /// 表示倍率。上限は環境設定の「最大拡大率」(`maxUpscalePercent`)。
    ///
    /// `fitWidthSplit`(横幅に合わせる・単ページ)は、**中身の横幅の半分**が画面幅いっぱいに
    /// なる倍率まで拡大する(cooViewer の `fitScreenMode == 3` と同じ式)。分割する意味が無い
    /// 内容(単ページ表示中の縦長ページなど)まで2倍に引き伸ばすと読みにくいだけなので、
    /// その場合は `fitWidth` と同じ結果になるよう割る数を 1 に落とす。
    ///
    /// 判定に使うのは個々のページの縦横比ではなく、**実際に表示している内容を合成したあと**の
    /// 縦横比。これで「単ページ表示中の横長スキャン」と「見開きで縦長2ページを合成した状態」の
    /// 両方が、追加の判定なしに等しく分割の対象になる。
    static func renderScale(
        contentSize: CGSize, containerSize: CGSize, scalingMode: ScalingMode,
        maxUpscalePercent: Double, singlePageAspectRatioThreshold: Double
    ) -> CGFloat {
        guard contentSize.width > 0, contentSize.height > 0,
              containerSize.width > 0, containerSize.height > 0
        else { return 1 }
        let maxUpscale = CGFloat(maxUpscalePercent / 100)
        switch scalingMode {
        case .fitToScreen:
            let fitScale = min(
                containerSize.width / contentSize.width, containerSize.height / contentSize.height
            )
            return min(fitScale, maxUpscale)
        case .fitWidth:
            return min(containerSize.width / contentSize.width, maxUpscale)
        case .fitWidthSplit:
            let contentAspectRatio = contentSize.width / contentSize.height
            let isDividable = contentAspectRatio >= CGFloat(singlePageAspectRatioThreshold)
            let widthScale = containerSize.width / (contentSize.width / (isDividable ? 2 : 1))
            return min(widthScale, maxUpscale)
        case .noScale:
            return 1
        }
    }

    /// スクロールできる中身の大きさ。
    ///
    /// 画像が表示領域より小さい方向には、表示領域の大きさを下限にする(SwiftUI がその中で
    /// 中央に置いてくれるので、ピンチ拡大で片方の辺だけ画面に収まっている状態でも隅に寄らない)。
    /// **縦を持ち上げるのは「画面内に収める」のときだけ** ―― 他のモードの見え方は変えない。
    static func scrollContentSize(
        contentSize: CGSize, scale: CGFloat, viewport: CGSize, scalingMode: ScalingMode
    ) -> CGSize {
        let scaledWidth = contentSize.width * scale
        let scaledHeight = contentSize.height * scale
        return CGSize(
            width: max(scaledWidth, viewport.width),
            height: scalingMode == .fitToScreen ? max(scaledHeight, viewport.height) : scaledHeight
        )
    }
}

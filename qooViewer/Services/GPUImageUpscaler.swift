import CoreGraphics
import CoreImage

/// Core Image(GPU)を使って、画像のごく一部だけを高品質に拡大するための汎用ヘルパー。
///
/// ページ全体のような大きな画像に対しては、GPUを使ってもフレームごとに実行するには重すぎる
/// 補間処理(Lanczosなど)であっても、拡大鏡(ルーペ)のように「画面のごく一部(数百px四方)
/// だけを対象にした処理」に限定すれば、マウス移動のたびに実行しても十分な速度で行える
/// (LoupeOverlayView.swift参照)。将来、拡大鏡以外の「狭い範囲だけを高品質に拡大したい」
/// 機能が出てきた場合にも、この型をそのまま再利用できるように、拡大鏡に依存しない汎用の
/// インターフェースにしてある。
///
/// CIContextの生成コストは高い(GPUパイプラインの構築を伴う)ため、呼び出し側は使い捨てず、
/// 1つのインスタンスを保持して使い回すこと。
final class GPUImageUpscaler {
    private let context: CIContext

    init() {
        self.context = CIContext()
    }

    /// `source`のうち、`centerPixel`を中心とした一辺`cropSize`の正方形の範囲だけを切り出し、
    /// 一辺`targetSize`まで拡縮したCGImageを返す。
    ///
    /// `targetSize`が実際の切り出し幅(cropRect.width)より大きい場合(=元画像に存在しない
    /// ディテールを補間で再構成する必要がある、本来の「拡大」)だけ、Lanczosカーネルによる
    /// 補間(CILanczosScaleTransform)を使う。逆に切り出し幅以下(超高解像度なソース画像などで、
    /// 元画像の解像度がレンズの表示に必要な解像度を既に満たしている場合)は、補間で新しい
    /// ディテールを作り出す必要が無い。Lanczosは補間の副作用として輪郭にリンギング
    /// (オーバーシュート)を生じることがあり、この必要の無い場面で使うと無用に画質を
    /// 損ないかねないため、その場合は単純な等方拡縮(リンギングの無いなめらかな縮小)に
    /// とどめる。
    ///
    /// - Parameters:
    ///   - source: 切り出し元の画像。
    ///   - centerPixel: 切り出しの中心。`source`のピクセル空間で、原点が左上・Yが下向きに
    ///     増える座標系(CGImageのビットマップ行の並び順そのままの座標系。呼び出し側が
    ///     `CGContext`へ描画する際の一般的な座標系とは異なる場合があるので注意)。
    ///   - cropSize: 切り出す正方形の一辺の長さ(`source`のピクセル単位)。
    ///   - targetSize: 拡縮後の一辺の長さ(点単位)。
    /// - Returns: 拡縮後のCGImage。`source`の端に近く切り出し範囲がはみ出す場合は、
    ///   実際に切り出せた範囲だけを拡縮するため、返るCGImageの一辺は`targetSize`よりわずかに
    ///   小さくなることがある。切り出し範囲が完全に画像外の場合はnil。
    func upscaledCrop(
        from source: CGImage,
        centerPixel: CGPoint,
        cropSize: CGFloat,
        targetSize: CGFloat
    ) -> CGImage? {
        guard cropSize > 0, targetSize > 0 else { return nil }

        let ciImage = CIImage(cgImage: source)
        // CIImageの座標系は原点が左下、Yは上向きに増える(Core Image標準の規約で、CGImageの
        // ビットマップ行の並び順とは上下が逆)。centerPixelはCGImageのビットマップ座標系
        // (原点が左上)で渡される前提のため、ここで変換する。
        let centerYFromBottom = CGFloat(source.height) - centerPixel.y
        let cropRect = CGRect(
            x: centerPixel.x - cropSize / 2,
            y: centerYFromBottom - cropSize / 2,
            width: cropSize,
            height: cropSize
        ).intersection(ciImage.extent)
        guard !cropRect.isEmpty else { return nil }

        let cropped = ciImage.cropped(to: cropRect)
        let scaleFactor = targetSize / cropRect.width

        let scaled: CIImage
        if scaleFactor > 1 {
            guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
            filter.setValue(cropped, forKey: kCIInputImageKey)
            filter.setValue(scaleFactor, forKey: kCIInputScaleKey)
            filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
            guard let output = filter.outputImage else { return nil }
            scaled = output
        } else {
            scaled = cropped.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
        }

        return context.createCGImage(scaled, from: scaled.extent)
    }
}

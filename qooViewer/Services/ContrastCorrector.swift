import Foundation
import CoreGraphics
import CoreImage

/// 古いスキャン画像(紙の黄ばみ等でコントラストが甘く見える白黒ページ)を、きっちりした
/// 白黒に見えるよう補正するための汎用ヘルパー。PageLoaderが、本単位で記憶された
/// コントラスト補正設定(BookLayoutSettings.contrastCorrectionEnabled)がONの本のページ画像に
/// 対して、デコード直後に呼ぶ。
///
/// この本がONであっても、個々のページが実際にカラー(色付きの口絵・イラストページ等)かどうかは
/// ここで別途判定し、カラーと判定したページには一切手を加えず元の画像をそのまま返す
/// (ユーザー要望: カラー画像には適用しない)。
///
/// 補正内容は「オートレベル」(チャンネルごとに黒点・白点を求めて0〜1へ引き伸ばす)。
/// チャンネル(R/G/B)ごとに独立して行うことで、紙の黄ばみのように青チャンネルの白点だけが
/// 低い(=白のはずの紙が黄色く見える)ケースでも、色被りの解消とコントラストの最大化を
/// 同時に行える(単純なグレースケール化や、全チャンネル共通のコントラスト強調では色被り
/// 自体は取れない)。
///
/// nonisolated: ImageDecoder.swiftと同じ理由(Xcode 26既定のMainActor自動分離の対象外にする)。
/// PageLoader(actor)のTask.detached、およびactor自身の直接呼び出し(PDF描画経路)の両方から
/// 呼ばれるため、どのアクターからでも呼べる必要がある。
nonisolated enum ContrastCorrector {
    /// 分析(カラー判定・ヒストグラム計算)に使うダウンサンプル画像の長辺の上限。
    /// フルサイズ(最大4096〜20000px)を毎回スキャンするのは無駄なため、十分小さい解像度に
    /// 落としてから計算する。ページ全体の色・階調の傾向を掴むにはこの程度で十分。
    ///
    /// あまり小さくしすぎると、細い罫線・文字ストローク(黒)が周囲の紙面(白/黄ばみ)と
    /// ブレンドされて中間調に薄まってしまい、「真の黒点・真の白点」がヒストグラムから
    /// 実質的に失われてオートレベル補正が弱く(効いていないように)なる不具合があったため、
    /// downsampledRGBAPixels(of:)側で補間無し(ニアレストネイバー)の点サンプリングに
    /// している(コメント参照)ことと合わせて、この値自体もある程度余裕を持たせてある。
    private static let analysisMaxDimension = 512

    /// 本ごとのコントラスト補正がONのとき、PageLoaderがデコード直後の画像に対して呼ぶ。
    /// カラーページと判定した場合、または分析・補正処理が何らかの理由で失敗した場合は、
    /// 安全側に倒して元の画像をそのまま返す(呼び出し元はこの関数が常に何らかのCGImageを
    /// 返すことだけを期待すればよい)。
    static func apply(to image: CGImage) -> CGImage {
        guard let analysis = analyze(image), !analysis.isLikelyColorImage else { return image }
        return levelsCorrected(image, using: analysis) ?? image
    }

    // MARK: - 分析

    private struct Analysis {
        var isLikelyColorImage: Bool
        /// R/G/Bそれぞれの256階調ヒストグラム(ダウンサンプル画像から集計)。
        var histograms: (r: [Int], g: [Int], b: [Int])
        var pixelCount: Int
    }

    /// ダウンサンプルした画像を1回だけ走査し、(1)カラーページかどうかの判定材料
    /// (色相のばらつき)と、(2)白黒補正用のチャンネルごとのヒストグラムを同時に求める。
    private static func analyze(_ image: CGImage) -> Analysis? {
        guard let (pixels, width, height) = downsampledRGBAPixels(of: image) else { return nil }

        var histR = [Int](repeating: 0, count: 256)
        var histG = [Int](repeating: 0, count: 256)
        var histB = [Int](repeating: 0, count: 256)
        // 色相を24分割(15度刻み)したヒストグラム。「紙の黄ばみ」のような単一方向の色被りは
        // 少数のビンに集中し、実際のカラーイラストは複数のビンにまたがって分布することを
        // 利用してカラーページを判定する(このファイル冒頭のコメント参照)。
        var hueHistogram = [Int](repeating: 0, count: 24)
        var coloredPixelCount = 0

        let pixelCount = width * height
        var index = 0
        for _ in 0..<pixelCount {
            let r = Int(pixels[index])
            let g = Int(pixels[index + 1])
            let b = Int(pixels[index + 2])
            index += 4

            histR[r] += 1
            histG[g] += 1
            histB[b] += 1

            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let chroma = maxC - minC
            // 8未満の色差はJPEG圧縮ノイズ・アンチエイリアシング等による揺らぎとみなし、
            // 「無彩色(白黒スキャンのインク・紙)」として扱う(色相計算の対象から外す)。
            guard chroma >= 8 else { continue }
            coloredPixelCount += 1

            let hue = hueDegrees(r: r, g: g, b: b, maxC: maxC, chroma: chroma)
            let bin = min(23, Int(hue / 15))
            hueHistogram[bin] += 1
        }

        let isLikelyColorImage: Bool
        // 色の付いたピクセルが全体の2%未満なら、色相のばらつきを見るまでもなくカラー
        // ページではないと判断できる(単なる紙の黄ばみ・スキャンノイズ程度)。
        if coloredPixelCount == 0 || Double(coloredPixelCount) / Double(pixelCount) < 0.02 {
            isLikelyColorImage = false
        } else {
            // 色の付いたピクセルのうち、上位3ビン(45度分)が占める割合。単一方向の色被り
            // (黄ばみ)ならこの割合は高く(1つの色相付近にほぼ集中)、実際のカラーページは
            // 複数の色相にまたがるためこの割合が低くなる。
            let topBinsTotal = hueHistogram.sorted(by: >).prefix(3).reduce(0, +)
            let concentration = Double(topBinsTotal) / Double(coloredPixelCount)
            isLikelyColorImage = concentration < 0.85
        }

        return Analysis(
            isLikelyColorImage: isLikelyColorImage,
            histograms: (histR, histG, histB),
            pixelCount: pixelCount
        )
    }

    /// 0以上360未満の色相(度)。RGBからHSVへの標準的な変換式(chromaは呼び出し元で
    /// 計算済みのmax-minをそのまま渡す。chroma == 0の場合はここへ来ない)。
    private static func hueDegrees(r: Int, g: Int, b: Int, maxC: Int, chroma: Int) -> Double {
        let c = Double(chroma)
        let hue: Double
        if maxC == r {
            hue = 60 * (Double(g - b) / c).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            hue = 60 * (Double(b - r) / c + 2)
        } else {
            hue = 60 * (Double(r - g) / c + 4)
        }
        return hue < 0 ? hue + 360 : hue
    }

    /// 画像を分析用の小さいRGBAバッファへ描画する。戻り値のバッファは各ピクセル4byte
    /// (R, G, B, 未使用)、アルファ乗算なし(.noneSkipLast)。
    private static func downsampledRGBAPixels(of image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = Double(analysisMaxDimension) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let byteCount = width * height * 4

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: byteCount)

        guard let context = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // 補間(ブレンド)を伴うダウンサンプルにすると、細い罫線・文字ストロークの黒が周囲の
        // 紙面色と混ざり合って中間調に薄まり、ヒストグラムから「真の黒点」が実質的に失われて
        // しまう(オートレベル補正が効いているのかわからないほど弱くなる不具合の原因だった)。
        // .noneで補間を無効化し、ニアレストネイバー(点サンプリング)にすることで、
        // 各サンプル点が常に元画像のどこか1点の生の色をそのまま反映するようにする。
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let pixels = Array(UnsafeBufferPointer(start: buffer, count: byteCount))
        return (pixels, width, height)
    }

    // MARK: - 補正

    /// チャンネルごとのヒストグラムから低域・高域のパーセンタイル点を黒点・白点とする
    /// 「オートレベル」補正をCore Image(GPU)で適用する。
    private static func levelsCorrected(_ image: CGImage, using analysis: Analysis) -> CGImage? {
        let (scaleR, biasR) = channelTransform(histogram: analysis.histograms.r, pixelCount: analysis.pixelCount)
        let (scaleG, biasG) = channelTransform(histogram: analysis.histograms.g, pixelCount: analysis.pixelCount)
        let (scaleB, biasB) = channelTransform(histogram: analysis.histograms.b, pixelCount: analysis.pixelCount)

        // 3チャンネルとも実質的に無補正(scale=1,bias=0)なら、GPUパイプラインを起動するだけ
        // 無駄なので元の画像をそのまま返す。
        guard scaleR != 1 || scaleG != 1 || scaleB != 1 || biasR != 0 || biasG != 0 || biasB != 0 else {
            return image
        }

        guard let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // downsampledRGBAPixels(of:)側の分析(黒点・白点の計算)は、CGContextへ描画して得た
        // sRGBガンマ符号化のまま(リニア化しない)の0〜255の値を基準にしている。
        // 一方Core Imageは既定では色管理を行い、フィルタ内部の実際の演算をリニア(シーンリニア)
        // 空間で行う(sRGBガンマ符号化値をいったんリニアへ変換してから演算し、出力時に
        // またガンマ符号化へ戻す)。CIColorMatrixのscale/biasを分析時のガンマ符号化値の土俵で
        // 計算しているため、色管理された(リニア空間で演算される)ままCIColorMatrixへ渡すと、
        // 想定と全く異なる(大幅に弱い)結果になってしまう不具合があった。
        // .colorSpace: NSNull() / CIContextのworkingColorSpace: NSNull() を指定することで
        // Core Imageの色管理そのものを無効化し、ピクセルの生の数値をそのまま(リニア変換無しで)
        // 演算・入出力させる。これにより分析時と処理時の数値の土俵が一致する。
        guard let matrixFilter = CIFilter(name: "CIColorMatrix") else { return nil }
        let ciImage = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
        matrixFilter.setValue(ciImage, forKey: kCIInputImageKey)
        matrixFilter.setValue(CIVector(x: scaleR, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrixFilter.setValue(CIVector(x: 0, y: scaleG, z: 0, w: 0), forKey: "inputGVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: scaleB, w: 0), forKey: "inputBVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrixFilter.setValue(CIVector(x: biasR, y: biasG, z: biasB, w: 0), forKey: "inputBiasVector")
        guard let matrixOutput = matrixFilter.outputImage else { return nil }

        // CIColorMatrixの出力は0...1に収まらないことがある(黒点・白点の外側にはみ出した値)
        // ため、最終的に0...1へ明示的にクランプしてから描画する。
        guard let clampFilter = CIFilter(name: "CIColorClamp") else { return nil }
        clampFilter.setValue(matrixOutput, forKey: kCIInputImageKey)
        clampFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
        clampFilter.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")
        guard let output = clampFilter.outputImage else { return nil }

        // CIContextの生成コストは高い(GPUImageUpscaler.swiftのコメント参照)が、ここは
        // ページのデコード1回につき1回しか呼ばれない(ルーペのようにマウス移動のたびに
        // 呼ばれるホットパスではない)ため、都度生成しても実用上問題にならない。PageLoaderの
        // Task.detached(複数ページを並行してデコードしうる)から同時に呼ばれうるため、
        // インスタンスを使い回さずその都度作ることで、共有状態への並行アクセスを考える
        // 必要が無いようにしている。
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        // 出力を書き出す段になって初めてsRGBとしてタグ付けする。入力・演算はリニア変換無し
        // (ガンマ符号化値のまま)で行っているため、出力される生の数値もsRGBガンマ符号化値と
        // 同じ意味を持つ。元画像のcolorSpaceをそのまま使わないのは、元画像のプロファイルが
        // 何であれ(このアプリが想定する古いスキャン画像はプロファイルが不定・不一致なことも
        // 珍しくない)、常に「分析・演算の土俵として使ったsRGBガンマ符号化」と同じ意味で
        // 出力をタグ付けする必要があるため。
        return context.createCGImage(output, from: ciImage.extent, format: .RGBA8, colorSpace: outputColorSpace)
    }

    /// 1チャンネル分のヒストグラムから、下側0.5%点・上側99.5%点を黒点・白点として
    /// (scale, bias)を求める(0...1空間、CIColorMatrixにそのまま渡せる値)。単純な最小値・
    /// 最大値ではなく percentile を使うのは、単一の外れ値ピクセル(ノイズ)に引きずられて
    /// 黒点・白点が暴れないようにするため。黒点・白点の差が小さすぎる場合(ほぼ単色に近い
    /// ページ等)は補正しても意味が無い・暴走しうるため、無補正(1, 0)を返す。
    private static func channelTransform(histogram: [Int], pixelCount: Int) -> (scale: CGFloat, bias: CGFloat) {
        guard pixelCount > 0 else { return (1, 0) }
        let lowCutoff = Int(Double(pixelCount) * 0.005)
        let highCutoff = Int(Double(pixelCount) * 0.995)

        var cumulative = 0
        var low = 0
        for value in 0..<256 {
            cumulative += histogram[value]
            if cumulative > lowCutoff {
                low = value
                break
            }
        }
        cumulative = 0
        var high = 255
        for value in 0..<256 {
            cumulative += histogram[value]
            if cumulative >= highCutoff {
                high = value
                break
            }
        }

        guard high - low >= 10 else { return (1, 0) }

        let lowN = CGFloat(low) / 255
        let highN = CGFloat(high) / 255
        let scale = 1 / (highN - lowN)
        let bias = -lowN * scale
        return (scale, bias)
    }
}

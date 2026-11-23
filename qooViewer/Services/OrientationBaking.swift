import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 書き出す画像の向きを、**向きの指定(EXIF/TIFF の Orientation)ではなく画素そのもの**で表すための処理(2026-11-23)。
///
/// ■ なぜ(ユーザー判断)
/// 書き出した CBZ・EPUB・PDF を読むアプリが、画像の向きの指定に従うとは限らない(Android の CBZ リーダーの多くは従わない
/// はず、Kindle・Kobo は未確認)。指定に頼ると、読むアプリによって qooViewer で見たのと違う向きになる。そこで書き出しでは:
/// - CBZ・EPUB: 向きの指定(1 以外)を持つ画像は、指定どおりに回した画素で**同じ形式に**書き直し、指定は付けない
///   (`bakedForExport`。JPEG は `jpegQuality` で圧縮し直す)。ファイル名・拡張子は変わらない。
/// - PDF: 画像を貼るときの座標変換で向きを付け、埋め込む JPEG の指定は**圧縮し直さずに** 1 へ戻す
///   (`losslesslyResettingOrientation`。PDF の描画は指定を無視するが、従う描き手があっても二重に回らないように)。
/// - PDF の本のページ(`/Rotate`)も同じ描き直し(`drawn`)で回す(PDFImageExtractor)。
///
/// ImageIO が書けない形式(WebP。2026-11-23 の macOS 27 で `CGImageDestinationCopyTypeIdentifiers` に無い)は書き直せないので、
/// 元のまま渡す(向きの指定を持つ WebP は実際にはまず無い)。アニメーション GIF は向きの指定を持たないので触らない。
nonisolated enum OrientationBaking {
    /// 書き直す JPEG の品質。見た目の差がほぼ出ない高さ(ユーザー判断 2026-11-23: 向きのある画像だけを再圧縮する)。
    static let jpegQuality: CGFloat = 0.95

    private static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    /// 画像の向きの指定(1〜8)。無い・分からない値なら 1。
    static func orientation(of source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let value = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        return (1...8).contains(value) ? value : 1
    }

    static func orientation(of data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return 1 }
        return orientation(of: source)
    }

    /// PDF の `/Rotate`(時計回り、0/90/180/270)と同じ回し方の向きの指定(EXIF の 6 = 時計回り 90°)。
    static func orientation(forClockwiseRotation rotation: Int) -> Int {
        switch rotation {
        case 90: 6
        case 180: 3
        case 270: 8
        default: 1
        }
    }

    /// CBZ・EPUB へ入れる画像: 向きの指定があれば、回した画素で同じ形式に書き直したもの(指定なし)。
    /// **書き直す必要が無い(指定が無い・1)か、書き直せない(書けない形式・読めない・大きすぎる)なら nil** ―― 呼ぶ側は元のまま使う。
    /// - Parameter orientationOverride: ファイルの指定の**代わりに**使う向き(1〜8。利用者がビューアで回したページ ――
    ///   PageRotationOverride。2026-11-23)。1 を渡すと「回さない」(ファイルに指定があれば、それを外すだけ ―― JPEG は圧縮し直さない)。
    static func bakedForExport(_ data: Data, orientationOverride: Int? = nil) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let fileOrientation = orientation(of: source)
        let target = orientationOverride.map { (1...8).contains($0) ? $0 : 1 } ?? fileOrientation
        guard target != 1 || fileOrientation != 1 else { return nil }
        if target == 1, let reset = losslesslyResettingOrientation(data) { return reset }
        guard let type = CGImageSourceGetType(source) as String?,
              writableTypes.contains(type),
              hasAcceptablePixelCount(source),
              // CGImageSourceCreateImageAtIndex は向きの指定を反映しない(貼られた画素のまま)。
              let image = CGImageSourceCreateImageAtIndex(source, 0, sourceOptions),
              let oriented = drawn(image, orientation: target)
        else { return nil }
        return encoded(oriented, type: type)
    }

    /// JPEG の向きの指定を、**圧縮データに触れずに** 1 へ書き換えたもの(PDF の書き出し用。圧縮データ・画素とも元と同一なことを
    /// 2026-11-23 に実測)。JPEG でない・指定が 1・書き換えられないなら nil。
    static func losslesslyResettingOrientation(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              orientation(of: source) != 1,
              let type = CGImageSourceGetType(source) as String?,
              UTType(type)?.conforms(to: .jpeg) == true
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(
            destination, source, [kCGImageDestinationOrientation: 1] as CFDictionary, &error
        ) else {
            error?.release()
            return nil
        }
        return output as Data
    }

    /// 画像を向きの指定 `orientation`(1〜8)どおりに描き直したもの(1 ならそのまま)。
    /// 色空間と成分あたりのビット数はなるべく元のまま(グレーはグレー、CMYK は CMYK、16bit は 16bit、アルファも残す。インデックスカラーと
    /// 1〜4bit は 8bit の基底の色空間へ広げる ―― 値は変わらない)。等倍の写しなので補間はしない。
    static func drawn(_ image: CGImage, orientation: Int) -> CGImage? {
        guard orientation != 1 else { return image }
        let drawing = ImageDecoder.orientedDrawing(of: image, orientation: orientation)
        guard let context = canvas(for: image, width: drawing.width, height: drawing.height) else { return nil }
        context.interpolationQuality = .none
        drawing.prepare(context)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// 向きの指定を付けずに `type` の形式で書く。描き先から作った CGImage はメタデータを持たないので、元の EXIF も写らない。
    static func encoded(_ image: CGImage, type: String) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if UTType(type)?.conforms(to: .jpeg) == true || UTType(type)?.conforms(to: .heic) == true {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - 下回り

    private static let writableTypes: Set<String> = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

    /// 書き直しは画素を全部展開するので、読み込み全体と同じ画素数の上限を掛ける(ImageDecoder.maxSourcePixelCount)。
    private static func hasAcceptablePixelCount(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 65_535, height <= 65_535
        else { return false }
        return width * height <= ImageDecoder.maxSourcePixelCount
    }

    /// 描き先(CGBitmapContext が受け付ける組み合わせだけ)。描き先にできない色空間(ICC の中身による)なら sRGB の 8bit へ
    /// (色の見え方は CoreGraphics が変換する)。
    private static func canvas(for image: CGImage, width: Int, height: Int) -> CGContext? {
        let wide = image.bitsPerComponent == 16
        let hasAlpha = ![.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
        var space = image.colorSpace
        if space?.model == .indexed { space = space?.baseColorSpace }
        let opaqueRGB = CGImageAlphaInfo.noneSkipLast.rawValue
        let alphaRGB = CGImageAlphaInfo.premultipliedLast.rawValue
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let format: (CGColorSpace, Int, UInt32)
        switch space?.model {
        case .monochrome? where !hasAlpha:
            format = (space ?? CGColorSpaceCreateDeviceGray(), wide ? 16 : 8, CGImageAlphaInfo.none.rawValue)
        case .rgb?:
            format = (space ?? srgb, wide ? 16 : 8, hasAlpha ? alphaRGB : opaqueRGB)
        case .cmyk?:
            // CMYK にアルファを持たせた描き先は作れない(アルファ付きの CMYK 画像は実際にはまず無い)。
            format = (space ?? CGColorSpaceCreateDeviceCMYK(), wide ? 16 : 8, CGImageAlphaInfo.none.rawValue)
        default:
            // アルファ付きのグレーも描き先にできないので RGB へ(値は同じ灰色)。
            format = (srgb, 8, hasAlpha ? alphaRGB : opaqueRGB)
        }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: format.1, bytesPerRow: 0,
            space: format.0, bitmapInfo: format.2
        ) ?? CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb, bitmapInfo: hasAlpha ? alphaRGB : opaqueRGB
        )
    }
}

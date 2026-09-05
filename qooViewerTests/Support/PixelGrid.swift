import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 画素を1つずつ指定して `CGImage` を作り、結果の画素を読み戻すための道具。
///
/// `PageImageFactory` は「番号を色に埋めた単色のページ画像」専用なので、階調やチャンネルごとの
/// 偏りを作りたいテスト(`ContrastCorrector`)にはこちらを使う。
nonisolated enum PixelGrid {
    /// `body` が返す RGB(不透明)で埋めた画像を作る。原点は左上。
    static func image(width: Int, height: Int, _ body: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = body(x, y)
                let offset = (y * width + x) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
            }
        }
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        guard let image else { preconditionFailure("CGImage を作れない") }
        return image
    }

    /// 画像を等倍で RGBA8 へ描き直して、画素を読めるようにする。
    static func pixels(of image: CGImage) -> (rgb: (Int, Int) -> (Int, Int, Int), width: Int, height: Int) {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let snapshot = buffer
        return ({ x, y in
            let offset = (y * width + x) * 4
            return (Int(snapshot[offset]), Int(snapshot[offset + 1]), Int(snapshot[offset + 2]))
        }, width, height)
    }

    /// 画像を1つのファイル形式へ書き出す。`orientation` を渡すと EXIF の回転指定を埋める
    /// (`ImageDecoder.decode` が向きを反映するかどうかを見るため)。
    static func encoded(
        _ image: CGImage, as type: UTType, orientation: CGImagePropertyOrientation? = nil
    ) -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil
        ) else {
            preconditionFailure("\(type.identifier) を書けない")
        }
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation.rawValue
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            preconditionFailure("\(type.identifier) の書き込みに失敗")
        }
        return output as Data
    }
}

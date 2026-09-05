import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 生成フィクスチャのページ画像。scripts/fixtures/make-page-image.py と同じ約束事:
/// 単色で **R = ページ番号**、G = 0x66、B = 0x99。通常 8x12 px、横長は 24x12 px。
///
/// 番号を色に埋めてあるので、書き出しのラウンドトリップの後で「どのページがどこへ行ったか」を
/// ファイル名ではなく中身で追える(PageColorReader)。
nonisolated enum PageImageFactory {
    static let width = 8
    static let wideWidth = 24
    static let height = 12

    static func cgImage(number: UInt8, wide: Bool = false) -> CGImage {
        let width = wide ? wideWidth : width
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            preconditionFailure("CGContext を作れない")
        }
        context.setFillColor(red: CGFloat(number) / 255, green: CGFloat(0x66) / 255, blue: CGFloat(0x99) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { preconditionFailure("CGImage を作れない") }
        return image
    }

    static func data(number: UInt8, wide: Bool = false, type: UTType) -> Data {
        let image = cgImage(number: number, wide: wide)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            preconditionFailure("\(type.identifier) を書けない")
        }
        var properties: [CFString: Any] = [:]
        if type == .jpeg {
            // 単色なので高品質なら R の誤差は ±1 に収まる(PageColorReader は近さで比べる)。
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { preconditionFailure("\(type.identifier) の書き込みに失敗") }
        return output as Data
    }

    static func png(number: UInt8, wide: Bool = false) -> Data {
        data(number: number, wide: wide, type: .png)
    }

    static func jpeg(number: UInt8, wide: Bool = false) -> Data {
        data(number: number, wide: wide, type: .jpeg)
    }

    /// 拡張子で形式を選ぶ(png / jpg / jpeg / tif / tiff / gif / bmp / heic)。
    static func data(number: UInt8, wide: Bool = false, fileExtension: String) -> Data {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": return data(number: number, wide: wide, type: .jpeg)
        case "tif", "tiff": return data(number: number, wide: wide, type: .tiff)
        case "gif": return data(number: number, wide: wide, type: .gif)
        case "bmp": return data(number: number, wide: wide, type: .bmp)
        case "heic": return data(number: number, wide: wide, type: .heic)
        default: return data(number: number, wide: wide, type: .png)
        }
    }
}

/// PageImageFactory が埋めたページ番号を、画像の中身(中央の画素の R)から読み戻す。
nonisolated enum PageColorReader {
    static func number(in data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return number(in: image)
    }

    static func number(in image: CGImage) -> Int? {
        guard let center = image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)) else {
            return nil
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? Int(pixel[0]) : nil
    }

    /// JPEG の誤差(±2)を許して、期待する番号かどうか。
    static func matches(_ data: Data, number expected: Int) -> Bool {
        guard let read = Self.number(in: data) else { return false }
        return abs(read - expected) <= 2
    }
}

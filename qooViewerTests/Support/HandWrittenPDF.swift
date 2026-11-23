import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `/Rotate`・`/CropBox`・親の `/Pages` からの継承など、CoreGraphics の PDF コンテキストでは書けないページ辞書を持つ PDF を、
/// 手で組み立てて書く(PDFPageGeometry と、PDF の向きを PDF で見たとおりに焼き込む書き出しのテスト用)。
///
/// 各ページには 1 枚の画像を MediaBox いっぱいに貼る(`q w 0 0 h x y cm /Im0 Do Q`)。画像は `Quadrants` の四色の絵 ―― 四隅の色で
/// 向きを読み戻せる。
nonisolated enum HandWrittenPDF {
    enum Image {
        /// JPEG のバイト列をそのまま `/DCTDecode` で貼る(EXIF の向きを付けたものも渡せる)。
        case jpeg(Data, width: Int, height: Int)
        /// 圧縮しない RGB のサンプル値(`/Filter` 無し = 可逆側の経路)。
        case rawRGB(Data, width: Int, height: Int)
    }

    struct Page {
        var image: Image
        var mediaBox = CGRect(x: 0, y: 0, width: Quadrants.width, height: Quadrants.height)
        var cropBox: CGRect?
        /// ページ辞書の `/Rotate`(nil なら書かない)。
        var rotate: Int?
    }

    /// `pagesRotate` は親の `/Pages` に書く `/Rotate`(継承のテスト)。
    static func write(_ pages: [Page], pagesRotate: Int? = nil, to url: URL) throws {
        var objects: [Data] = []
        func add(_ body: Data) -> Int {
            objects.append(body)
            return objects.count
        }
        func ascii(_ string: String) -> Data { Data(string.utf8) }
        func box(_ rect: CGRect) -> String {
            "[\(number(rect.minX)) \(number(rect.minY)) \(number(rect.maxX)) \(number(rect.maxY))]"
        }

        let catalog = add(Data()) // 後で埋める
        let pagesObject = add(Data())
        var pageObjects: [Int] = []
        for page in pages {
            let (imageDictionary, imageData): (String, Data)
            switch page.image {
            case .jpeg(let data, let width, let height):
                imageDictionary = "/Width \(width) /Height \(height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode"
                imageData = data
            case .rawRGB(let data, let width, let height):
                imageDictionary = "/Width \(width) /Height \(height) /ColorSpace /DeviceRGB /BitsPerComponent 8"
                imageData = data
            }
            var imageStream = ascii("<< /Type /XObject /Subtype /Image \(imageDictionary) /Length \(imageData.count) >>\nstream\n")
            imageStream.append(imageData)
            imageStream.append(ascii("\nendstream"))
            let imageObject = add(imageStream)

            let media = page.mediaBox
            let content = "q \(number(media.width)) 0 0 \(number(media.height)) \(number(media.minX)) \(number(media.minY)) cm /Im0 Do Q"
            let contentObject = add(ascii("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"))

            var dictionary = "<< /Type /Page /Parent \(pagesObject) 0 R /MediaBox \(box(media))"
            if let crop = page.cropBox { dictionary += " /CropBox \(box(crop))" }
            if let rotate = page.rotate { dictionary += " /Rotate \(rotate)" }
            dictionary += " /Resources << /XObject << /Im0 \(imageObject) 0 R >> >> /Contents \(contentObject) 0 R >>"
            pageObjects.append(add(ascii(dictionary)))
        }
        objects[catalog - 1] = ascii("<< /Type /Catalog /Pages \(pagesObject) 0 R >>")
        let kids = pageObjects.map { "\($0) 0 R" }.joined(separator: " ")
        let inherited = pagesRotate.map { " /Rotate \($0)" } ?? ""
        objects[pagesObject - 1] = ascii("<< /Type /Pages /Kids [\(kids)] /Count \(pageObjects.count)\(inherited) >>")

        var output = ascii("%PDF-1.4\n")
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(output.count)
            output.append(ascii("\(index + 1) 0 obj\n"))
            output.append(body)
            output.append(ascii("\nendobj\n"))
        }
        let xref = output.count
        output.append(ascii("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"))
        for offset in offsets { output.append(ascii(String(format: "%010d 00000 n \n", offset))) }
        output.append(ascii("trailer\n<< /Size \(objects.count + 1) /Root \(catalog) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"))
        try output.write(to: url)
    }

    private static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(Double(value))
    }
}

/// 四隅が違う色の絵(左上 赤・右上 緑・左下 青・右下 黄)。描いた結果の四隅を読めば、回転・反転・切り取りが分かる。
/// 一辺を 16 の倍数にしてあるので、JPEG にしても色の境目が四隅の読み取り位置まで滲まない。
nonisolated enum Quadrants {
    static let width = 32
    static let height = 48

    enum Color: String, CustomStringConvertible {
        case red = "赤", green = "緑", blue = "青", yellow = "黄", white = "白", other = "?"
        var description: String { rawValue }
    }

    /// 左上・右上・左下・右下。
    struct Corners: Equatable, CustomStringConvertible {
        let topLeft: Color, topRight: Color, bottomLeft: Color, bottomRight: Color
        var description: String { "\(topLeft)\(topRight)/\(bottomLeft)\(bottomRight)" }

        static let upright = Corners(topLeft: .red, topRight: .green, bottomLeft: .blue, bottomRight: .yellow)
        /// 時計回りに `rotation` 度回したもの(/Rotate と同じ向き)。
        static func uprightRotatedClockwise(_ rotation: Int) -> Corners {
            switch rotation {
            case 90: Corners(topLeft: .blue, topRight: .red, bottomLeft: .yellow, bottomRight: .green)
            case 180: Corners(topLeft: .yellow, topRight: .blue, bottomLeft: .green, bottomRight: .red)
            case 270: Corners(topLeft: .green, topRight: .yellow, bottomLeft: .red, bottomRight: .blue)
            default: upright
            }
        }
    }

    static func image() -> CGImage {
        PixelGrid.image(width: width, height: height) { x, y in
            switch (x < width / 2, y < height / 2) {
            case (true, true): (255, 0, 0)
            case (false, true): (0, 255, 0)
            case (true, false): (0, 0, 255)
            case (false, false): (255, 255, 0)
            }
        }
    }

    /// JPEG(`orientation` を渡すと EXIF の向きを付ける)。
    static func jpeg(orientation: CGImagePropertyOrientation? = nil) -> HandWrittenPDF.Image {
        .jpeg(PixelGrid.encoded(image(), as: .jpeg, orientation: orientation), width: width, height: height)
    }

    /// 圧縮しない RGB のサンプル値。
    static func rawRGB() -> HandWrittenPDF.Image {
        let pixels = PixelGrid.pixels(of: image())
        var data = Data(capacity: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixels.rgb(x, y)
                data.append(contentsOf: [UInt8(r), UInt8(g), UInt8(b)])
            }
        }
        return .rawRGB(data, width: width, height: height)
    }

    /// 四隅(各辺の 1/4・3/4 の位置)の色。
    static func corners(of image: CGImage) -> Corners {
        let pixels = PixelGrid.pixels(of: image)
        func color(_ x: Int, _ y: Int) -> Color {
            let (r, g, b) = pixels.rgb(x, y)
            func high(_ v: Int) -> Bool { v > 170 }
            func low(_ v: Int) -> Bool { v < 85 }
            switch (high(r), high(g), high(b)) {
            case (true, false, false) where low(g) && low(b): return .red
            case (false, true, false) where low(r) && low(b): return .green
            case (false, false, true) where low(r) && low(g): return .blue
            case (true, true, false) where low(b): return .yellow
            case (true, true, true): return .white
            default: return .other
            }
        }
        let w = pixels.width, h = pixels.height
        return Corners(
            topLeft: color(w / 4, h / 4), topRight: color(w * 3 / 4, h / 4),
            bottomLeft: color(w / 4, h * 3 / 4), bottomRight: color(w * 3 / 4, h * 3 / 4)
        )
    }

    static func corners(of data: Data) -> Corners? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return corners(of: image)
    }
}

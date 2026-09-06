import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// デコード済みページ画像の入れ物(Services/PagePixelBuffer.swift)。
///
/// `CGImage` をキャッシュすると CoreAnimation のコピーで実質 3 倍のメモリを占める、という実測から
/// 生まれた型なので、**占めるバイト数がキャッシュの上限計算と食い違わないこと**が要。
/// 白黒の本を 1 バイト/画素のまま持つ(4 倍に広げない)のもここの仕事。
struct PagePixelBufferTests {
    /// 行頭を 16 バイト境界に揃えた 1 行のバイト数(実装と同じ式)。
    private func alignedBytesPerRow(width: Int, bytesPerPixel: Int) -> Int {
        (width * bytesPerPixel + 15) / 16 * 16
    }

    private func colorImage(width: Int, height: Int) -> CGImage {
        PixelGrid.image(width: width, height: height) { x, y in
            (UInt8(x % 256), UInt8(y % 256), 128)
        }
    }

    /// 8bit グレー・アルファ無しの画像(ImageIO が白黒 JPEG に対して返す形)。
    private func grayImage(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for index in pixels.indices { pixels[index] = UInt8(index % 256) }
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        guard let image else { preconditionFailure("グレースケールの CGImage を作れない") }
        return image
    }

    // MARK: - 形式の判定

    @Test("8bit グレー・アルファ無しだけを 1 バイト/画素として扱う")
    func onlyGrayscaleWithoutAlphaTakesTheOneBytePath() {
        #expect(PagePixelBuffer.isGrayscaleWithoutAlpha(grayImage(width: 8, height: 4)))
        #expect(!PagePixelBuffer.isGrayscaleWithoutAlpha(colorImage(width: 8, height: 4)))
    }

    @Test("カラーの保存先は元が RGB 系ならそのまま(広色域の画像で色を変えない)")
    func anRGBImageKeepsItsColorSpace() throws {
        let image = colorImage(width: 8, height: 4)
        let space = try #require(PagePixelBuffer.storageColorSpace(for: image))
        #expect(space.model == .rgb)
        #expect(space == image.colorSpace)
    }

    @Test("グレースケールの保存先は元の色空間のまま")
    func aGrayImageKeepsItsColorSpace() throws {
        let image = grayImage(width: 8, height: 4)
        let space = try #require(PagePixelBuffer.storageColorSpace(for: image))
        #expect(space.model == .monochrome)
    }

    // MARK: - 占めるバイト数

    @Test("カラーは 4 バイト/画素、行頭は 16 バイト境界へ揃える")
    func aColorBufferCostsFourBytesPerPixelWithAlignedRows() throws {
        let buffer = try #require(PagePixelBuffer(rendering: colorImage(width: 10, height: 5)))
        #expect(buffer.width == 10)
        #expect(buffer.height == 5)
        #expect(buffer.byteCount == alignedBytesPerRow(width: 10, bytesPerPixel: 4) * 5)
        #expect(buffer.byteCount == 48 * 5)
    }

    @Test("白黒は 1 バイト/画素のまま(4 倍に広げない ―― 以前はキャッシュの 1/4 しか使えていなかった)")
    func aGrayscaleBufferStaysOneBytePerPixel() throws {
        let color = try #require(PagePixelBuffer(rendering: colorImage(width: 64, height: 64)))
        let gray = try #require(PagePixelBuffer(rendering: grayImage(width: 64, height: 64)))
        #expect(gray.byteCount == alignedBytesPerRow(width: 64, bytesPerPixel: 1) * 64)
        #expect(gray.byteCount * 4 == color.byteCount)
    }

    @Test("大きさが 0 ならバッファは作れない")
    func aZeroSizedBufferIsRejected() {
        #expect(PagePixelBuffer(width: 0, height: 10, grayscale: false) { _ in } == nil)
        #expect(PagePixelBuffer(width: 10, height: 0, grayscale: false) { _ in } == nil)
        #expect(PagePixelBuffer(width: -1, height: 10, grayscale: false) { _ in } == nil)
    }

    // MARK: - 画素の往復

    @Test("描き写した画素はそのまま戻る(等倍なので補間で変わらない)")
    func thePixelsSurviveTheRoundTrip() throws {
        let source = PixelGrid.image(width: 4, height: 3) { x, y in
            (UInt8(x * 60), UInt8(y * 80), 200)
        }
        let buffer = try #require(PagePixelBuffer(rendering: source))
        let image = try #require(buffer.makeImage())
        let read = PixelGrid.pixels(of: image)
        #expect(read.width == 4 && read.height == 3)
        for y in 0..<3 {
            for x in 0..<4 {
                #expect(read.rgb(x, y) == (x * 60, y * 80, 200), "(\(x), \(y))")
            }
        }
    }

    @Test("直接描く経路(PDF のページ)でも同じ形のバッファになる")
    func drawingDirectlyProducesTheSameShape() throws {
        let buffer = try #require(PagePixelBuffer(width: 20, height: 10, grayscale: false) { context in
            // 色空間を明示して作る ―― CGColor(red:green:blue:alpha:) は generic RGB なので、
            // sRGB のバッファへ描くと画素の値がわずかにずれる。
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        })
        #expect(buffer.byteCount == alignedBytesPerRow(width: 20, bytesPerPixel: 4) * 10)
        let read = PixelGrid.pixels(of: try #require(buffer.makeImage()))
        #expect(read.rgb(10, 5) == (255, 0, 0))
    }

    @Test("CGImage は何枚作ってもバイト列は 1 つのまま(コピーしない)")
    func makingManyImagesDoesNotCopyThePixels() throws {
        let buffer = try #require(PagePixelBuffer(rendering: colorImage(width: 32, height: 32)))
        let before = buffer.byteCount
        var images: [CGImage] = []
        for _ in 0..<20 { images.append(try #require(buffer.makeImage())) }
        #expect(images.count == 20)
        #expect(buffer.byteCount == before)
        #expect(images.allSatisfy { $0.width == 32 && $0.height == 32 })
    }

    // MARK: - 縮小

    @Test("長辺が指定以下なら縮小しない(自分自身をそのまま返す)")
    func aSmallBufferIsReturnedUnchanged() throws {
        let buffer = try #require(PagePixelBuffer(rendering: colorImage(width: 100, height: 50)))
        #expect(buffer.downscaled(toFit: 100) === buffer)
        #expect(buffer.downscaled(toFit: 200) === buffer)
    }

    @Test("縮小後の寸法は切り捨て(元ファイルから作ったサムネイルと 1px も違わないように)")
    func theDownscaledSizeIsRoundedDown() throws {
        let buffer = try #require(PagePixelBuffer(rendering: colorImage(width: 100, height: 50)))
        let small = try #require(buffer.downscaled(toFit: 25))
        #expect(small.width == 25)
        #expect(small.height == 12)  // 12.5 の切り捨て
    }

    @Test("縮小しても幅・高さは最低 1 画素")
    func theDownscaledSizeIsAtLeastOnePixel() throws {
        let buffer = try #require(PagePixelBuffer(rendering: colorImage(width: 1000, height: 4)))
        let small = try #require(buffer.downscaled(toFit: 10))
        #expect(small.width == 10)
        #expect(small.height == 1)
    }

    @Test("白黒のまま縮小する(縮小でカラーに広がらない)")
    func aGrayscaleBufferStaysGrayscaleWhenDownscaled() throws {
        let buffer = try #require(PagePixelBuffer(rendering: grayImage(width: 100, height: 100)))
        let small = try #require(buffer.downscaled(toFit: 50))
        #expect(small.width == 50 && small.height == 50)
        #expect(small.byteCount == alignedBytesPerRow(width: 50, bytesPerPixel: 1) * 50)
    }
}

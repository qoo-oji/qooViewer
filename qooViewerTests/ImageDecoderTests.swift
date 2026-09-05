import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import qooViewer

/// 画像のデコード(Services/ImageDecoder.swift)。
///
/// 見るのは3つ ―― `Info.plist` に書いてある対応形式を実際に読めること、EXIF の回転を
/// 反映すること、そして壊れた入力で落ちずに nil を返すこと。
///
/// webp と avif だけはコミット済みのフィクスチャ(`Fixtures/images/`)を使う。macOS に WebP の
/// エンコーダが無く、テストの中では作れないため(scripts/fixtures/make-webp.py 参照)。
struct ImageDecoderTests {
    // MARK: - ヘッダーだけを読む

    @Test("その場で作れる形式のヘッダーを読む",
          arguments: ["png", "jpg", "gif", "bmp", "tif", "heic"])
    func headerInfoForGeneratedFormats(fileExtension: String) throws {
        let data = PageImageFactory.data(number: 1, fileExtension: fileExtension)
        let info = try #require(ImageDecoder.headerInfo(of: data), "\(fileExtension) を読めない")
        #expect(info.pixelWidth == PageImageFactory.width)
        #expect(info.pixelHeight == PageImageFactory.height)
        #expect(ImageDecoder.pixelSize(of: data)! == (PageImageFactory.width, PageImageFactory.height))
    }

    @Test("コミット済みの webp / avif のヘッダーを読む",
          arguments: [("images/image-solid.webp", 8), ("images/image-wide.webp", 24), ("images/image-solid.avif", 8)])
    func headerInfoForCommittedFormats(path: String, width: Int) throws {
        let data = try Data(contentsOf: Fixtures.url(path))
        let info = try #require(ImageDecoder.headerInfo(of: data), "\(path) を読めない")
        #expect(info.pixelWidth == width)
        #expect(info.pixelHeight == PageImageFactory.height)
    }

    @Test("ファイルから読む版も、データから読む版と同じ結果になる")
    func theFileOverloadAgreesWithTheDataOverload() throws {
        let workspace = try TemporaryDirectory("header")
        let url = workspace.file("001.png")
        let data = PageImageFactory.png(number: 1)
        try data.write(to: url)

        let fromFile = try #require(ImageDecoder.headerInfo(ofFileAt: url))
        let fromData = try #require(ImageDecoder.headerInfo(of: data))
        #expect(fromFile.pixelWidth == fromData.pixelWidth)
        #expect(fromFile.pixelHeight == fromData.pixelHeight)
        #expect(fromFile.colorModel == fromData.colorModel)
        #expect(ImageDecoder.pixelSize(ofFileAt: url)! == (8, 12))
    }

    @Test("ヘッダーには色の情報も入る")
    func headerInfoCarriesTheColorInformation() throws {
        let info = try #require(ImageDecoder.headerInfo(of: PageImageFactory.png(number: 1)))
        #expect(info.colorModel == "RGB")
        #expect(!info.hasAlpha)
    }

    // MARK: - デコード

    /// 中身の番号に許す幅は、**非可逆な形式だけ**広く取る。
    ///
    /// 可逆(png / gif / bmp / tif)は単色なので誤差ゼロで戻るべきで、そこはぴったり見る。
    /// jpg / heic は encoder が環境で違い、**同じコードでも手元と CI で結果が変わる**
    /// ―― 実測(2026-09-06): 手元(macOS 26.6)は heic も誤差ゼロだったが、CI(macos-26 の
    /// ランナー)は 4 ずれて落ちた。ここで見たいのは「そのページの画像が返ること」であって
    /// encoder の色再現ではないので、非可逆の側は「まったく別の色ではない」程度に緩める。
    private static func colorTolerance(for fileExtension: String) -> Int {
        ["jpg", "jpeg", "heic"].contains(fileExtension) ? 8 : 0
    }

    @Test("その場で作れる形式をデコードして、中身の番号まで戻る",
          arguments: ["png", "jpg", "gif", "bmp", "tif", "heic"])
    func decodeGeneratedFormats(fileExtension: String) throws {
        let data = PageImageFactory.data(number: 42, fileExtension: fileExtension)
        let image = try #require(ImageDecoder.decode(data, maxPixelSize: 4096))
        #expect(image.width == PageImageFactory.width)
        #expect(image.height == PageImageFactory.height)
        let read = PageColorReader.number(in: image) ?? -1
        #expect(abs(read - 42) <= Self.colorTolerance(for: fileExtension), "読めた番号: \(read)")
    }

    @Test("コミット済みの webp / avif もデコードできる",
          arguments: [("images/image-solid.webp", 8, 1), ("images/image-wide.webp", 24, 2), ("images/image-solid.avif", 8, 1)])
    func decodeCommittedFormats(path: String, width: Int, number: Int) throws {
        let data = try Data(contentsOf: Fixtures.url(path))
        let image = try #require(ImageDecoder.decode(data, maxPixelSize: 4096))
        #expect(image.width == width)
        #expect(image.height == PageImageFactory.height)
        // avif は非可逆なので、番号は幅を持たせて見る。
        #expect(abs((PageColorReader.number(in: image) ?? -1) - number) <= 2)
    }

    @Test("maxPixelSize は長辺の上限")
    func maxPixelSizeLimitsTheLongerSide() throws {
        let source = PixelGrid.image(width: 64, height: 96) { _, _ in (1, 0x66, 0x99) }
        let data = PixelGrid.encoded(source, as: .png)

        let small = try #require(ImageDecoder.decode(data, maxPixelSize: 16))
        #expect(max(small.width, small.height) <= 16)
        #expect(small.width < small.height) // 縦横比は保つ

        let full = try #require(ImageDecoder.decode(data, maxPixelSize: 4096))
        #expect((full.width, full.height) == (64, 96))
    }

    @Test("EXIF の回転指定はデコード時に反映する")
    func exifOrientationIsAppliedOnDecode() throws {
        // 8x12 を「右へ 90 度回して見せる」指定。ヘッダーは生の寸法のまま、デコードは回した後。
        let data = PixelGrid.encoded(
            PageImageFactory.cgImage(number: 1), as: .jpeg, orientation: .right
        )
        let header = try #require(ImageDecoder.headerInfo(of: data))
        #expect((header.pixelWidth, header.pixelHeight) == (8, 12))

        let image = try #require(ImageDecoder.decode(data, maxPixelSize: 4096))
        #expect((image.width, image.height) == (12, 8))
    }

    @Test("PagePixelBuffer としてのデコードも同じ寸法になる")
    func decodePixelsMatchesDecode() throws {
        let data = PageImageFactory.png(number: 7)
        let buffer = try #require(ImageDecoder.decodePixels(data, maxPixelSize: 4096))
        #expect((buffer.width, buffer.height) == (8, 12))
        let image = try #require(buffer.makeImage())
        #expect(PageColorReader.number(in: image) == 7)
    }

    // MARK: - 壊れた入力

    @Test("空のデータは nil")
    func emptyDataDecodesToNil() {
        #expect(ImageDecoder.decode(Data(), maxPixelSize: 4096) == nil)
        #expect(ImageDecoder.headerInfo(of: Data()) == nil)
        #expect(ImageDecoder.pixelSize(of: Data()) == nil)
    }

    @Test("画像ではないデータは nil")
    func nonImageDataDecodesToNil() {
        let data = Data("これは画像ではない".utf8)
        #expect(ImageDecoder.decode(data, maxPixelSize: 4096) == nil)
        #expect(ImageDecoder.headerInfo(of: data) == nil)
    }

    @Test("途中で切れた画像は、落ちずに nil を返す")
    func truncatedDataDecodesToNil() throws {
        let data = PageImageFactory.png(number: 1)
        let truncated = data.prefix(data.count / 2)
        #expect(ImageDecoder.decode(Data(truncated), maxPixelSize: 4096) == nil)
        // ヘッダー(PNG の IHDR)だけは先頭にあるので、寸法は読めることがある ――
        // ここで確かめたいのは「落ちない」こと。
        _ = ImageDecoder.headerInfo(of: Data(truncated))
    }

    @Test("無いファイルを読もうとしても nil")
    func aMissingFileGivesNil() throws {
        let workspace = try TemporaryDirectory("missing")
        #expect(ImageDecoder.headerInfo(ofFileAt: workspace.file("ghost.png")) == nil)
        #expect(ImageDecoder.pixelSize(ofFileAt: workspace.file("ghost.png")) == nil)
    }

    // MARK: - PNG への変換(EPUB 書き出し)

    @Test("EPUB に直接入れられない形式は PNG へ変換できる",
          arguments: ["images/image-solid.webp", "images/image-solid.avif"])
    func pngDataConvertsForeignFormats(path: String) throws {
        // 実測で、WebP / HEIC / BMP / TIFF / AVIF は Kindle Previewer が変換に失敗するか、
        // EPUBCheck が RSC-032 でエラーにする。PNG は可逆なので画質は落ちない。
        let data = try Data(contentsOf: Fixtures.url(path))
        let png = try #require(ImageDecoder.pngData(from: data))
        #expect(ImageDecoder.headerInfo(of: png)?.pixelWidth == 8)
        #expect(ImageDecoder.headerInfo(of: png)?.pixelHeight == 12)
        #expect(CGImageSourceGetType(CGImageSourceCreateWithData(png as CFData, nil)!) as String? == UTType.png.identifier)
    }

    @Test("PNG への変換でも EXIF の回転を反映する")
    func pngDataAppliesTheOrientation() throws {
        let data = PixelGrid.encoded(PageImageFactory.cgImage(number: 1), as: .jpeg, orientation: .right)
        let png = try #require(ImageDecoder.pngData(from: data))
        #expect(ImageDecoder.pixelSize(of: png)! == (12, 8))
    }

    @Test("画像でないものは PNG へ変換できない")
    func pngDataRejectsNonImages() {
        #expect(ImageDecoder.pngData(from: Data("x".utf8)) == nil)
    }
}

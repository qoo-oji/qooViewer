import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import qooViewer

/// 画像の向きの指定(EXIF/TIFF の Orientation)の扱い(2026-11-23)。
///
/// - 表示は以前から指定に従う。寸法(横長の判定・「情報を見る」・書き出しの寸法)も指定を反映した値にする(ImageDecoder.HeaderInfo)。
/// - 書き出す CBZ・EPUB・PDF は、**読むアプリが指定に従わなくても**見たとおりの向きになるようにする(ユーザー判断。OrientationBaking):
///   CBZ・EPUB は回した画素で同じ形式に書き直し指定を付けない、PDF は座標変換で向きを付け埋め込み JPEG の指定を無劣化で 1 に戻す。
///
/// 正解は ImageIO が向きを反映して読んだ絵(`displayedCorners` = Finder・プレビューの見え方)。
struct ImageOrientationExportTests {

    // MARK: - OrientationBaking

    @Test("向きの指定のある JPEG は、見たとおりの画素の JPEG に書き直し、指定は付けない", arguments: 2...8)
    func jpegIsBaked(orientation: Int) throws {
        let data = Self.jpeg(orientation: orientation)
        let baked = try #require(OrientationBaking.bakedForExport(data))
        #expect(Self.type(of: baked) == UTType.jpeg.identifier)
        #expect(OrientationBaking.orientation(of: baked) == 1)
        #expect(Quadrants.corners(of: baked) == Self.displayedCorners(data))
    }

    @Test("向きの指定が無い・1 の画像は書き直さない(元のバイト列のまま)")
    func uprightImagesAreLeftAlone() {
        #expect(OrientationBaking.bakedForExport(Self.jpeg(orientation: nil)) == nil)
        #expect(OrientationBaking.bakedForExport(Self.jpeg(orientation: 1)) == nil)
    }

    @Test("PNG も同じ形式のまま書き直し、アルファも残す")
    func pngIsBakedKeepingAlpha() throws {
        // 左上だけ透明な絵(向き 3 = 180°で、右下へ行く)。
        let width = Quadrants.width, height = Quadrants.height
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CG の座標は左下が原点なので、上半分の左 = y が大きい側。
        context.clear(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        let image = try #require(context.makeImage())
        let data = PixelGrid.encoded(image, as: .png, orientation: .down)

        let baked = try #require(OrientationBaking.bakedForExport(data))
        #expect(Self.type(of: baked) == UTType.png.identifier)
        #expect(OrientationBaking.orientation(of: baked) == 1)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(baked as CFData, nil)!, 0, nil))
        #expect(Self.alpha(of: decoded, x: width * 3 / 4, y: height * 3 / 4) == 0)
        #expect(Self.alpha(of: decoded, x: width / 4, y: height / 4) == 255)
    }

    @Test("PDF 用: JPEG の向きの指定は、圧縮データに触れずに 1 へ戻せる")
    func jpegOrientationResetIsLossless() throws {
        let data = Self.jpeg(orientation: 6)
        let reset = try #require(OrientationBaking.losslesslyResettingOrientation(data))
        #expect(OrientationBaking.orientation(of: reset) == 1)
        #expect(Self.scanData(reset) == Self.scanData(data))
        #expect(OrientationBaking.losslesslyResettingOrientation(Self.jpeg(orientation: nil)) == nil)
    }

    // MARK: - 寸法

    @Test("寸法は向きの指定を反映する(5〜8 は幅と高さが入れ替わる)", arguments: 1...8)
    func headerSizeFollowsOrientation(orientation: Int) throws {
        let size = try #require(ImageDecoder.pixelSize(of: Self.jpeg(orientation: orientation)))
        let sideways = orientation >= 5
        #expect(size.width == (sideways ? Quadrants.height : Quadrants.width))
        #expect(size.height == (sideways ? Quadrants.width : Quadrants.height))
    }

    @Test("本のページの寸法も向きを反映する(横長の判定が表示と揃う)")
    func pageSizeFollowsOrientation() async throws {
        let temporary = try TemporaryDirectory("orientation-page-size")
        let folder = try Self.folderBook(in: temporary, orientation: 6)
        let book = try await FixtureBook.load(folder)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        defer { Task { await loader.releaseAllResources() } }
        let size = try #require(await loader.pageSize(at: 0))
        #expect(size.width == Quadrants.height && size.height == Quadrants.width)
        let shown = try #require(await loader.pageImage(at: 0))
        #expect(shown.width > shown.height)
        #expect(Quadrants.corners(of: shown) == .uprightRotatedClockwise(90))
    }

    @Test("保存したページ寸法は、測り方の版が今のものでなければ使わない(向きを反映する前の寸法を捨てる)")
    func storedPageSizesFromBeforeTheOrientationFixAreIgnored() async throws {
        let temporary = try TemporaryDirectory("pagelists-version")
        let cache = BookPageListCache(directory: temporary.url)
        let fingerprint = BookPageListCache.Entry.Fingerprint(
            modificationDate: Date(timeIntervalSinceReferenceDate: 0), fileSize: 100
        )
        var old = BookPageListCache.Entry(
            pages: [BookPageListCache.Entry.Page(sortKey: "p1", displayName: "p1", folderPath: nil)],
            schemaVersion: BookPageListCache.Entry.currentSchemaVersion,
            rootPath: "/books/a", fingerprint: fingerprint, hasNestedArchives: false
        )
        old.pageSizes = ["p1": [10, 20]] // 版の無い(= 以前の)寸法
        await cache.store(old, forBookID: "/books/a")
        #expect(await cache.pageSizes(forBookID: "/books/a", fingerprint: fingerprint) == nil)

        // 測り直した寸法を書けば、古いものは混ざらずに今の版で読める。
        await cache.storePageSizes(["p2": [30, 40]], forBookID: "/books/a", fingerprint: fingerprint)
        #expect(await cache.pageSizes(forBookID: "/books/a", fingerprint: fingerprint) == ["p2": [30, 40]])
    }

    // MARK: - 書き出し

    @Test("CBZ: 向きの指定のある画像は見たとおりの画素で入り、指定は無く、ComicInfo の寸法も回した後のもの")
    func cbzExportBakesOrientation() async throws {
        let temporary = try TemporaryDirectory("orientation-cbz")
        let folder = try Self.folderBook(in: temporary, orientation: 6)
        let source = ExportSource(temp: temporary, book: try await FixtureBook.load(folder))
        let destination = source.destination("out.cbz")
        try await CbzExporter.export(ExportInputs.cbz(source), options: ExportInputs.cbzOptions, to: destination)

        let data = try await Self.firstPageRawData(of: destination)
        #expect(Self.type(of: data) == UTType.jpeg.identifier)
        #expect(OrientationBaking.orientation(of: data) == 1)
        #expect(Quadrants.corners(of: data) == .uprightRotatedClockwise(90))
        let info = try #require(ComicInfoXML.parse(try ZipArchiveReader(url: destination).data(at: ComicInfoXML.fileName)))
        let page = try #require(info.pages.first)
        #expect(page.imageWidth == Quadrants.height && page.imageHeight == Quadrants.width)
    }

    @Test("EPUB: 向きの指定のある画像は見たとおりの画素で入り、指定は無い")
    func epubExportBakesOrientation() async throws {
        let temporary = try TemporaryDirectory("orientation-epub")
        let folder = try Self.folderBook(in: temporary, orientation: 8)
        let source = ExportSource(temp: temporary, book: try await FixtureBook.load(folder))
        let destination = source.destination("out.epub")
        try await EpubExporter.export(ExportInputs.epub(source), options: ExportInputs.epubOptions, to: destination)

        let data = try await Self.firstPageRawData(of: destination)
        #expect(OrientationBaking.orientation(of: data) == 1)
        #expect(Quadrants.corners(of: data) == .uprightRotatedClockwise(270))
    }

    @Test("PDF: 向きは座標変換で付き(ページは回した寸法)、埋め込みの JPEG は圧縮し直さず指定だけ 1 になる")
    func pdfExportAppliesOrientationLosslessly() async throws {
        let temporary = try TemporaryDirectory("orientation-pdf")
        let folder = try Self.folderBook(in: temporary, orientation: 6)
        let original = try Data(contentsOf: folder.appendingPathComponent("001.jpg"))
        let source = ExportSource(temp: temporary, book: try await FixtureBook.load(folder))
        let destination = source.destination("out.pdf")
        try await PDFExporter.export(ExportInputs.pdf(source), options: ExportInputs.pdfOptions, to: destination)

        let page = try #require(CGPDFDocument(destination as CFURL)?.page(at: 1))
        #expect(page.getBoxRect(.mediaBox).size == CGSize(width: Quadrants.height, height: Quadrants.width))
        let reopened = try await FixtureBook.load(destination)
        let loader = PageLoader(book: reopened, usesThumbnailDiskCache: false)
        defer { Task { await loader.releaseAllResources() } }
        let shown = try #require(await loader.pageImage(at: 0))
        #expect(Quadrants.corners(of: shown) == .uprightRotatedClockwise(90))
        // 埋め込まれた JPEG はそのまま取り出せる(/Rotate も EXIF の向きも無いので素通し)。圧縮データは元と同一。
        let embedded = try #require(try await loader.exportableImage(at: 0))
        #expect(OrientationBaking.orientation(of: embedded.data) == 1)
        #expect(Self.scanData(embedded.data) == Self.scanData(original))
    }

    // MARK: - 道具

    private static func jpeg(orientation: Int?) -> Data {
        PixelGrid.encoded(
            Quadrants.image(), as: .jpeg,
            orientation: orientation.flatMap { CGImagePropertyOrientation(rawValue: UInt32($0)) }
        )
    }

    /// 向きの指定 `orientation` の JPEG が 1 ページだけ入ったフォルダの本。
    private static func folderBook(in temporary: TemporaryDirectory, orientation: Int) throws -> URL {
        let folder = temporary.file("book")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg(orientation: orientation).write(to: folder.appendingPathComponent("001.jpg"))
        return folder
    }

    /// ImageIO が向きを反映して読んだ絵の四隅(Finder・プレビューの見え方)。
    private static func displayedCorners(_ data: Data) -> Quadrants.Corners? {
        ImageDecoder.decode(data, maxPixelSize: 4096).map(Quadrants.corners(of:))
    }

    private static func type(of data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    /// JPEG の圧縮データ(SOS マーカーから後ろ)。
    private static func scanData(_ data: Data) -> Data? {
        data.range(of: Data([0xFF, 0xDA])).map { data[$0.lowerBound...] }
    }

    private static func firstPageRawData(of url: URL) async throws -> Data {
        let book = try await FixtureBook.load(url)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        defer { Task { await loader.releaseAllResources() } }
        return try #require(await loader.rawImageData(at: 0))
    }

    /// (x, y)(左上が原点)の画素のアルファ。
    private static func alpha(of image: CGImage, x: Int, y: Int) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .none
            // (x, y) の画素が描き先の (0, 0) に来るようにずらして描く(CG は左下が原点)。
            context.draw(image, in: CGRect(
                x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height
            ))
        }
        return Int(pixel[3])
    }
}

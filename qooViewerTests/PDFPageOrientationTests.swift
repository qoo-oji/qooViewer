import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import qooViewer

/// PDF のページを Finder(PDFKit)で見たとおりの向き・範囲で扱うこと(PDFPageGeometry、2026-11-23)。
///
/// 発端は「一部の PDF が qooViewer でだけ天地逆に表示される」報告。ビューアの描画が `/Rotate` を見ていなかった。
/// ここでは手で組んだ PDF(HandWrittenPDF: `/Rotate`・`/CropBox`・親からの継承)を、
/// - 表示(PageLoader.pageImage)・寸法(pageSize)が **PDFKit の描画と同じ**になること
/// - EPUB/CBZ・1 ページの書き出しに渡す画像(exportableImage)が、**向きの指定(EXIF)を持たず、画素が PDF で見たとおり**であること
///   (ユーザー判断「描画ソフトに依存しないように」。`/Rotate` の無い、EXIF の向きも無い JPEG は元のバイト列のまま)
/// - PDF の書き出しが向き・範囲を保つこと
/// で確かめる。
struct PDFPageOrientationTests {

    // MARK: - PDFPageGeometry

    @Test("/Rotate は 0/90/180/270 へ正規化する(負の値・360 超え・90 の倍数でない値は PDFKit と同じに丸める)", arguments: [
        (0, 0), (90, 90), (180, 180), (270, 270), (360, 0), (-90, 270), (-180, 180), (540, 180),
        (45, 90), (135, 180), (100, 90), (44, 0),
    ])
    func rotationIsNormalized(angle: Int, expected: Int) {
        #expect(PDFPageGeometry.normalizedRotation(angle) == expected)
    }

    @Test("表示する枠は CropBox ∩ MediaBox。重ならない壊れた CropBox なら MediaBox。90°/270° は縦横が入れ替わる")
    func boxIsTheCropBoxClippedToTheMediaBox() throws {
        let media = CGRect(x: 0, y: 0, width: 100, height: 200)
        let inside = try #require(PDFPageGeometry(mediaBox: media, cropBox: CGRect(x: 10, y: 20, width: 80, height: 160), rotationAngle: 0))
        #expect(inside.box == CGRect(x: 10, y: 20, width: 80, height: 160))
        let overhanging = try #require(PDFPageGeometry(mediaBox: media, cropBox: CGRect(x: 50, y: 50, width: 250, height: 250), rotationAngle: 0))
        #expect(overhanging.box == CGRect(x: 50, y: 50, width: 50, height: 150))
        let disjoint = try #require(PDFPageGeometry(mediaBox: media, cropBox: CGRect(x: 500, y: 500, width: 10, height: 10), rotationAngle: 0))
        #expect(disjoint.box == media)
        let sideways = try #require(PDFPageGeometry(mediaBox: media, cropBox: media, rotationAngle: -90))
        #expect(sideways.displayedSize == CGSize(width: 200, height: 100))
        #expect(PDFPageGeometry(mediaBox: .zero, cropBox: .zero, rotationAngle: 0) == nil)
    }

    // MARK: - 表示と寸法(PDFKit = Finder と同じに)

    /// 回転ごとの PDF を作って、表示・寸法・PDFKit の描画を比べる。
    @Test("表示は /Rotate を反映し、PDFKit(Finder)の描画と同じ向きになる。寸法も回転後のもの", arguments: [0, 90, 180, 270, -90, 540])
    func displayFollowsRotate(rotate: Int) async throws {
        let temporary = try TemporaryDirectory("pdf-rotate-display")
        let url = temporary.file("book.pdf")
        try HandWrittenPDF.write([.init(image: Quadrants.jpeg(), rotate: rotate)], to: url)
        let normalized = PDFPageGeometry.normalizedRotation(rotate)
        let expected = Quadrants.Corners.uprightRotatedClockwise(normalized)

        #expect(try Self.pdfKitCorners(of: url) == expected, "前提: PDFKit はこの向きで描く")

        let book = try await FixtureBook.load(url)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        defer { Task { await loader.releaseAllResources() } }
        let image = try #require(await loader.pageImage(at: 0))
        #expect(Quadrants.corners(of: image) == expected)
        let sideways = normalized == 90 || normalized == 270
        #expect((image.width > image.height) == sideways)
        let size = try #require(await loader.pageSize(at: 0))
        #expect(size.width == (sideways ? Quadrants.height : Quadrants.width))
        #expect(size.height == (sideways ? Quadrants.width : Quadrants.height))
        let thumbnail = try #require(await loader.thumbnail(at: 0))
        #expect(Quadrants.corners(of: thumbnail) == expected)
    }

    @Test("親の /Pages から継承した /Rotate 180 も反映する")
    func inheritedRotateIsApplied() async throws {
        let temporary = try TemporaryDirectory("pdf-rotate-inherited")
        let url = temporary.file("book.pdf")
        try HandWrittenPDF.write([.init(image: Quadrants.jpeg())], pagesRotate: 180, to: url)
        #expect(try Self.pdfKitCorners(of: url) == .uprightRotatedClockwise(180))

        let book = try await FixtureBook.load(url)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        defer { Task { await loader.releaseAllResources() } }
        let image = try #require(await loader.pageImage(at: 0))
        #expect(Quadrants.corners(of: image) == .uprightRotatedClockwise(180))
    }

    @Test("CropBox の外は描かず、寸法も CropBox のもの(Finder と同じ範囲)")
    func cropBoxLimitsWhatIsShown() async throws {
        let temporary = try TemporaryDirectory("pdf-cropbox")
        let url = temporary.file("book.pdf")
        // 左半分だけを見せる。
        let crop = CGRect(x: 0, y: 0, width: Quadrants.width / 2, height: Quadrants.height)
        try HandWrittenPDF.write([.init(image: Quadrants.jpeg(), cropBox: crop)], to: url)
        let leftHalf = Quadrants.Corners(topLeft: .red, topRight: .red, bottomLeft: .blue, bottomRight: .blue)
        #expect(try Self.pdfKitCorners(of: url) == leftHalf)

        let book = try await FixtureBook.load(url)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        defer { Task { await loader.releaseAllResources() } }
        let image = try #require(await loader.pageImage(at: 0))
        #expect(Quadrants.corners(of: image) == leftHalf)
        let size = try #require(await loader.pageSize(at: 0))
        #expect(size.width == Quadrants.width / 2)
        #expect(size.height == Quadrants.height)
    }

    @Test("ファイルブラウザのアイコン(BookThumbnailer)も同じ向き・範囲")
    func fileBrowserThumbnailMatches() throws {
        let temporary = try TemporaryDirectory("pdf-rotate-thumbnailer")
        let url = temporary.file("book.pdf")
        try HandWrittenPDF.write([.init(image: Quadrants.jpeg(), rotate: 90)], to: url)
        let page = try #require(CGPDFDocument(url as CFURL)?.page(at: 1))
        let image = try #require(BookThumbnailer.render(page, maxPixelSize: 96))
        #expect(Quadrants.corners(of: image) == .uprightRotatedClockwise(90))
        #expect(image.width > image.height)
    }

    // MARK: - EPUB/CBZ・1 ページの書き出しに渡す画像

    @Test("/Rotate の無い JPEG のページは、埋め込みの JPEG をバイト列のまま渡す")
    func uprightJPEGPassesThrough() async throws {
        let temporary = try TemporaryDirectory("pdf-export-passthrough")
        let url = temporary.file("book.pdf")
        let image = Quadrants.jpeg()
        guard case .jpeg(let embedded, _, _) = image else { Issue.record("JPEG ではない"); return }
        try HandWrittenPDF.write([.init(image: image)], to: url)
        let exportable = try #require(try await Self.exportable(url))
        #expect(exportable.fileExtension == "jpg")
        #expect(exportable.data == embedded)
    }

    @Test("/Rotate のある JPEG のページは、回した画素で JPEG に圧縮し直し、向きの指定は付けない", arguments: [90, 180, 270])
    func rotatedJPEGIsBakedIn(rotate: Int) async throws {
        let temporary = try TemporaryDirectory("pdf-export-rotated-jpeg")
        let url = temporary.file("book.pdf")
        try HandWrittenPDF.write([.init(image: Quadrants.jpeg(), rotate: rotate)], to: url)
        let exportable = try #require(try await Self.exportable(url))
        #expect(exportable.fileExtension == "jpg")
        try Self.expectNoOrientation(exportable.data, type: "public.jpeg")
        #expect(Quadrants.corners(of: exportable.data) == .uprightRotatedClockwise(rotate))
        let size = try #require(ImageDecoder.pixelSize(of: exportable.data))
        let sideways = rotate == 90 || rotate == 270
        #expect(size.width == (sideways ? Quadrants.height : Quadrants.width))
        // 拡張子だけを先に決める経路も同じ答え(EPUB の目次はこれで先に組む)。
        let book = try await FixtureBook.load(url)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        defer { Task { await loader.releaseAllResources() } }
        #expect(try await loader.exportableImageFileExtension(at: 0) == "jpg")
    }

    @Test("/Rotate のある可逆形式のページは、回した画素の PNG(値は変わらない)")
    func rotatedLosslessIsBakedIn() async throws {
        let temporary = try TemporaryDirectory("pdf-export-rotated-png")
        let url = temporary.file("book.pdf")
        try HandWrittenPDF.write([.init(image: Quadrants.rawRGB(), rotate: 180)], to: url)
        let exportable = try #require(try await Self.exportable(url))
        #expect(exportable.fileExtension == "png")
        try Self.expectNoOrientation(exportable.data, type: "public.png")
        let source = try #require(CGImageSourceCreateWithData(exportable.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let original = PixelGrid.pixels(of: Quadrants.image())
        let rotated = PixelGrid.pixels(of: decoded)
        #expect(rotated.width == original.width && rotated.height == original.height)
        // 180° 回した画素が一致する(可逆)。
        var mismatches = 0
        for y in 0..<original.height {
            for x in 0..<original.width where rotated.rgb(original.width - 1 - x, original.height - 1 - y) != original.rgb(x, y) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    @Test("EXIF の向きを持つ JPEG は、PDF の描画がその向きを無視するので、貼られた画素のまま・向きの指定なしで出し直す")
    func exifOrientationIsDroppedToMatchThePDF() async throws {
        let temporary = try TemporaryDirectory("pdf-export-exif")
        let url = temporary.file("book.pdf")
        try HandWrittenPDF.write([.init(image: Quadrants.jpeg(orientation: .down))], to: url)
        // 前提(2026-11-23 の実測): PDFKit も qooViewer の表示も EXIF の向きを見ず、貼った画素のまま描く。
        #expect(try Self.pdfKitCorners(of: url) == .upright)
        let book = try await FixtureBook.load(url)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        defer { Task { await loader.releaseAllResources() } }
        let shown = try #require(await loader.pageImage(at: 0))
        #expect(Quadrants.corners(of: shown) == .upright)

        let exportable = try #require(try await loader.exportableImage(at: 0))
        try Self.expectNoOrientation(exportable.data, type: "public.jpeg")
        #expect(Quadrants.corners(of: exportable.data) == .upright)
    }

    // MARK: - PDF の書き出し

    @Test("PDF の書き出しは、回転と CropBox を焼き込んだページを書く(開き直すと /Rotate 無しで同じ向き・範囲)")
    func pdfExportKeepsTheAppearance() async throws {
        let temporary = try TemporaryDirectory("pdf-export-rotate")
        let url = temporary.file("book.pdf")
        let crop = CGRect(x: 0, y: 0, width: Quadrants.width / 2, height: Quadrants.height)
        try HandWrittenPDF.write([
            .init(image: Quadrants.jpeg(), rotate: 90),
            .init(image: Quadrants.jpeg(), cropBox: crop, rotate: 180),
        ], to: url)
        let source = ExportSource(temp: temporary, book: try await FixtureBook.load(url))
        let destination = source.destination("out.pdf")
        try await PDFExporter.export(ExportInputs.pdf(source), options: ExportInputs.pdfOptions, to: destination)

        let document = try #require(CGPDFDocument(destination as CFURL))
        #expect(document.numberOfPages == 2)
        let first = try #require(document.page(at: 1))
        #expect(first.rotationAngle == 0)
        #expect(first.getBoxRect(.mediaBox).size == CGSize(width: Quadrants.height, height: Quadrants.width))
        let second = try #require(document.page(at: 2))
        #expect(second.getBoxRect(.mediaBox).size == CGSize(width: Quadrants.width / 2, height: Quadrants.height))

        let reopened = try await FixtureBook.load(destination)
        let loader = PageLoader(book: reopened, usesThumbnailDiskCache: false)
        defer { Task { await loader.releaseAllResources() } }
        let firstImage = try #require(await loader.pageImage(at: 0))
        #expect(Quadrants.corners(of: firstImage) == .uprightRotatedClockwise(90))
        // 左半分(赤・青)を 180° 回したもの。
        let secondImage = try #require(await loader.pageImage(at: 1))
        #expect(Quadrants.corners(of: secondImage)
            == Quadrants.Corners(topLeft: .blue, topRight: .blue, bottomLeft: .red, bottomRight: .red))
    }

    // MARK: - サムネイルのディスクキャッシュ

    @Test("PDF を含む本だけ、サムネイルのディスクキャッシュの鍵に PDF の描き方の世代が入る(古い天地逆の絵を使わない)")
    func thumbnailKeyCarriesThePDFRenderingGeneration() {
        func key(_ containsPDF: Bool) -> ThumbnailDiskCache.BookKey {
            ThumbnailDiskCache.BookKey(
                bookID: "/book", modificationDate: nil, fileSize: 1, contrastCorrectionEnabled: false, maxPixelSize: 96,
                containsPDFPages: containsPDF
            )
        }
        #expect(key(false).fingerprint == "/book|-|1|false|96.0")
        #expect(key(true).fingerprint == "/book|-|1|false|96.0|pdf\(ThumbnailDiskCache.pdfRenderingGeneration)")
    }

    // MARK: - 道具

    /// PDFKit(Finder・Quick Look の描画)で 1 ページ目を描いた四隅。
    private static func pdfKitCorners(of url: URL) throws -> Quadrants.Corners {
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let bounds = page.bounds(for: .cropBox)
        let sideways = page.rotation % 180 != 0
        let size = sideways ? CGSize(width: bounds.height * 4, height: bounds.width * 4) : CGSize(width: bounds.width * 4, height: bounds.height * 4)
        let thumbnail = withExtendedLifetime(document) { page.thumbnail(of: size, for: .cropBox) }
        var rect = CGRect(origin: .zero, size: thumbnail.size)
        let image = try #require(thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        return Quadrants.corners(of: image)
    }

    private static func exportable(_ url: URL) async throws -> (data: Data, fileExtension: String)? {
        let book = try await FixtureBook.load(url)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        defer { Task { await loader.releaseAllResources() } }
        return try await loader.exportableImage(at: 0)
    }

    /// 向きの指定(EXIF/TIFF の Orientation)を持たない(または 1)。
    private static func expectNoOrientation(_ data: Data, type: String) throws {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == type)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        #expect(orientation == 1)
    }
}

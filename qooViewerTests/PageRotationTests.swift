import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import qooViewer

/// ビューアでの画像の回転(PageRotationOverride、2026-11-23 のユーザー要望)。
///
/// - 記録するのは**元の画素から見た向き**で、ファイルの向きの指定(EXIF・PDF の `/Rotate`)を**置き換える**(食い違えばアプリが勝つ)
/// - 表示・寸法・サムネイル・書き出し(CBZ・EPUB・PDF)・表紙がその向きに従う
/// - シークレットでなければ記録する(保存データ・JSON・移動への追従)。記録を残さない本ではメモリの上だけで回る
///
/// 絵の向きは四隅の色で読む(Quadrants。左上 赤・右上 緑・左下 青・右下 黄)。
@MainActor
struct PageRotationTests {

    // MARK: - LayoutStore

    @Test("向きは記録・上書き・消去でき、記録のある本は「レイアウト情報がある本」に入る")
    func storeRecordsAndClearsRotations() throws {
        let library = try InMemoryLibrary(label: "rotation-store")
        defer { library.close() }
        let book = MangaBook(id: "/books/a.cbz", title: "a", sourceURL: URL(filePath: "/books/a.cbz"), pages: [])
        library.layouts.setPageRotation(for: book, pageKey: "001.jpg", rotation: 90)
        library.layouts.setPageRotation(for: book, pageKey: "002.jpg", rotation: -90)
        #expect(library.layouts.pageRotations(forBookID: book.id) == ["001.jpg": 90, "002.jpg": 270])
        #expect(library.layouts.layoutBookIDs.contains(book.id))

        library.layouts.setPageRotation(for: book, pageKey: "001.jpg", rotation: 180)
        library.layouts.setPageRotation(for: book, pageKey: "002.jpg", rotation: nil)
        #expect(library.layouts.pageRotations(forBookID: book.id) == ["001.jpg": 180])

        // 「レイアウト」を消す操作(編集ウインドウの「レイアウトをすべて削除」など)は向きも消す。
        library.layouts.discardPageLayout(forBookID: book.id)
        #expect(library.layouts.pageRotations(forBookID: book.id).isEmpty)
        #expect(!library.layouts.layoutBookIDs.contains(book.id))

        // その本の保存データをすべて消す操作も。
        library.layouts.setPageRotation(for: book, pageKey: "003.jpg", rotation: 90)
        library.layouts.deleteLayoutRow(forBookID: book.id)
        #expect(library.layouts.pageRotations(forBookID: book.id).isEmpty)
    }

    @Test("フォルダの本を移すと、向きの記録の鍵(絶対パス)も新しいパスへ付け替わる")
    func rotationsFollowARelocatedFolderBook() throws {
        let library = try InMemoryLibrary(label: "rotation-relocate")
        defer { library.close() }
        let old = "/books/old", new = "/books/new"
        let book = MangaBook(id: old, title: "old", sourceURL: URL(filePath: old, directoryHint: .isDirectory), pages: [])
        library.layouts.setPageRotation(for: book, pageKey: old + "/001.jpg", rotation: 90)
        library.layouts.applyBookRelocation(BookRelocationPlan(bookIDs: [old: new], locators: [:], directoryBookIDs: []))
        #expect(library.layouts.pageRotations(forBookID: old).isEmpty)
        #expect(library.layouts.pageRotations(forBookID: new) == [new + "/001.jpg": 90])
    }

    @Test("向きの記録は、ストアを閉じて開き直しても残る")
    func rotationsSurviveReopeningTheStore() throws {
        let store = try DisposableStore("rotation-persist")
        let book = MangaBook(id: "/books/a.cbz", title: "a", sourceURL: URL(filePath: "/books/a.cbz"), pages: [])
        do {
            let container = try store.openCurrent()
            let layouts = LayoutStore(
                modelContext: container.mainContext,
                coverSourceStore: CollectionCoverSourceStore(directory: store.file("CollectionCoverSources"))
            )
            layouts.setPageRotation(for: book, pageKey: "001.jpg", rotation: 270)
        }
        let container = try store.openCurrent()
        let layouts = LayoutStore(
            modelContext: container.mainContext,
            coverSourceStore: CollectionCoverSourceStore(directory: store.file("CollectionCoverSources"))
        )
        #expect(layouts.pageRotations(forBookID: book.id) == ["001.jpg": 270])
    }

    @Test("保存データの JSON は向きの記録を書き出し、取り込むと戻る(マージでは手元の記録を上書きしない)")
    func rotationsRoundTripThroughTheSavedDataJSON() async throws {
        let source = try await ExportSource.zip(pages: 3, label: "rotation-json")
        let from = try InMemoryLibrary(label: "rotation-json-from")
        defer { from.close() }
        from.layouts.setPageRotation(for: source.book, pageKey: source.key(1), rotation: 90)
        from.layouts.setPageRotation(for: source.book, pageKey: source.key(2), rotation: 180)
        let (file, _) = await from.buildExportFile(.everything)
        let entry = try #require(file.layouts?.first { $0.bookID == source.book.id })
        #expect(entry.layout.rotations == [source.key(1): 90, source.key(2): 180])

        let to = try InMemoryLibrary(label: "rotation-json-to")
        defer { to.close() }
        to.layouts.setPageRotation(for: source.book, pageKey: source.key(2), rotation: 270)
        _ = await to.apply(file, policies: .all(.merge))
        #expect(to.layouts.pageRotations(forBookID: source.book.id) == [source.key(1): 90, source.key(2): 270])

        _ = await to.apply(file, policies: .all(.overwrite))
        #expect(to.layouts.pageRotations(forBookID: source.book.id) == [source.key(1): 90, source.key(2): 180])
    }

    // MARK: - PageLoader

    @Test("記録した向きはファイルの EXIF の向きを置き換える(表示・寸法・ファイルの向きの問い合わせ)")
    func overrideReplacesTheFileOrientation() async throws {
        let temporary = try TemporaryDirectory("rotation-loader-exif")
        let folder = try Self.folderBook(in: temporary, orientations: [6])
        let book = try await FixtureBook.load(folder)
        let key = try #require(book.pages.first?.sortKey)

        // 記録が無ければファイルどおり(向き 6 = 時計回り 90°)。
        let plain = PageLoader(book: book, usesThumbnailDiskCache: false)
        #expect(await plain.fileRotation(at: 0) == 90)
        #expect(await plain.effectiveRotation(at: 0) == 90)
        #expect(Quadrants.corners(of: try #require(await plain.pageImage(at: 0))) == .uprightRotatedClockwise(90))
        await plain.releaseAllResources()

        // 0° を記録すると、EXIF の指定があっても回さない(元の画素のまま)。寸法も回さない値。
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false, rotationOverrides: [key: 0])
        defer { Task { await loader.releaseAllResources() } }
        #expect(await loader.effectiveRotation(at: 0) == 0)
        let image = try #require(await loader.pageImage(at: 0))
        #expect(Quadrants.corners(of: image) == .upright)
        let size = try #require(await loader.pageSize(at: 0))
        #expect(size.width == Quadrants.width && size.height == Quadrants.height)
        #expect(Quadrants.corners(of: try #require(await loader.thumbnail(at: 0))) == .upright)
        let grid = try #require(await loader.gridThumbnail(at: 0, maxPixelSize: 96, usesDiskCache: false))
        #expect(Quadrants.corners(of: grid) == .upright)
    }

    @Test("向きを差し替えると、キャッシュに古い向きの絵があっても新しい向きで描き直す(寸法も入れ替わる)")
    func changingTheOverrideRedrawsWithTheNewOrientation() async throws {
        let temporary = try TemporaryDirectory("rotation-loader-change")
        let folder = try Self.folderBook(in: temporary, orientations: [nil])
        let book = try await FixtureBook.load(folder)
        let key = try #require(book.pages.first?.sortKey)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        defer { Task { await loader.releaseAllResources() } }
        #expect(Quadrants.corners(of: try #require(await loader.pageImage(at: 0))) == .upright)

        await loader.setRotationOverrides([key: 90])
        #expect(Quadrants.corners(of: try #require(await loader.pageImage(at: 0))) == .uprightRotatedClockwise(90))
        #expect(Quadrants.corners(of: try #require(await loader.cachedPageImage(at: 0))) == .uprightRotatedClockwise(90))
        let size = try #require(await loader.pageSize(at: 0))
        #expect(size.width == Quadrants.height && size.height == Quadrants.width)
        #expect(Quadrants.corners(of: try #require(await loader.thumbnail(at: 0))) == .uprightRotatedClockwise(90))

        await loader.setRotationOverrides([:])
        #expect(Quadrants.corners(of: try #require(await loader.pageImage(at: 0))) == .upright)
    }

    @Test("PDF のページも、記録した向きが /Rotate を置き換える")
    func overrideReplacesThePDFRotate() async throws {
        let temporary = try TemporaryDirectory("rotation-loader-pdf")
        let url = temporary.file("book.pdf")
        try HandWrittenPDF.write([.init(image: Quadrants.jpeg(), rotate: 180)], to: url)
        let book = try await FixtureBook.load(url)
        let key = try #require(book.pages.first?.sortKey)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false, rotationOverrides: [key: 90])
        defer { Task { await loader.releaseAllResources() } }
        #expect(await loader.fileRotation(at: 0) == 180)
        #expect(Quadrants.corners(of: try #require(await loader.pageImage(at: 0))) == .uprightRotatedClockwise(90))
        let size = try #require(await loader.pageSize(at: 0))
        #expect(size.width == Quadrants.height && size.height == Quadrants.width)
        // 書き出しに渡す画像も同じ向き(指定は付けない)。
        let exportable = try #require(try await loader.exportableImage(at: 0))
        #expect(OrientationBaking.orientation(of: exportable.data) == 1)
        #expect(Quadrants.corners(of: exportable.data) == .uprightRotatedClockwise(90))
    }

    @Test("書き出しに渡す画像: 記録した向きの画素で同じ形式に書き直す。0° の記録は EXIF の指定を外すだけ(JPEG は圧縮し直さない)")
    func exportableImageFollowsTheOverride() async throws {
        let temporary = try TemporaryDirectory("rotation-loader-export")
        let folder = try Self.folderBook(in: temporary, orientations: [nil, 6])
        let book = try await FixtureBook.load(folder)
        let keys = book.pages.map(\.sortKey)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false, rotationOverrides: [keys[0]: 270, keys[1]: 0])
        defer { Task { await loader.releaseAllResources() } }

        let rotated = try #require(try await loader.exportableImage(at: 0))
        #expect(rotated.fileExtension == "jpg")
        #expect(OrientationBaking.orientation(of: rotated.data) == 1)
        #expect(Quadrants.corners(of: rotated.data) == .uprightRotatedClockwise(270))

        let original = try Data(contentsOf: try #require(book.pages[1].fileURL))
        let reset = try #require(try await loader.exportableImage(at: 1))
        #expect(OrientationBaking.orientation(of: reset.data) == 1)
        #expect(Quadrants.corners(of: reset.data) == .upright)
        #expect(Self.scanData(reset.data) == Self.scanData(original))
    }

    // MARK: - ビューア

    @Test("ビューアで回すと、今の向きから回して記録し、表示も変わる。「元の向きに戻す」は記録を消してファイルの向きに戻す")
    func viewerRotatesAndRecords() async throws {
        let harness = try ViewerHarness(label: "rotation-viewer")
        defer { harness.close() }
        let folder = try Self.folderBook(in: harness.temporary, orientations: [6, nil])
        let book = try await FixtureBook.load(folder)
        let viewer = await harness.open(book)
        let key = viewer.book.pages[0].sortKey
        #expect(Quadrants.corners(of: try #require(viewer.currentImages.first)) == .uprightRotatedClockwise(90))

        // ファイルの向き(90°)から右へ 90° → 180° を記録する。
        await viewer.rotatePage(atIndex: 0, .rotateRight)
        await viewer.settle()
        #expect(harness.library.layouts.pageRotations(forBookID: book.id) == [key: 180])
        #expect(viewer.hasPageRotationOverride(atIndex: 0))
        #expect(Quadrants.corners(of: try #require(viewer.currentImages.first)) == .uprightRotatedClockwise(180))

        await viewer.rotatePage(atIndex: 0, .rotateLeft)
        await viewer.settle()
        // ファイルの向きと同じになっても記録は残す(アプリが決めた向き)。
        #expect(harness.library.layouts.pageRotations(forBookID: book.id) == [key: 90])

        await viewer.rotatePage(atIndex: 0, .reset)
        await viewer.settle()
        #expect(harness.library.layouts.pageRotations(forBookID: book.id).isEmpty)
        #expect(!viewer.hasPageRotationOverride(atIndex: 0))
        #expect(Quadrants.corners(of: try #require(viewer.currentImages.first)) == .uprightRotatedClockwise(90))
    }

    @Test("記録を残さない本(シークレットウインドウ)でも回せるが、保存データには書かない")
    func privateWindowRotatesInMemoryOnly() async throws {
        let harness = try ViewerHarness(label: "rotation-private")
        defer { harness.close() }
        let folder = try Self.folderBook(in: harness.temporary, orientations: [nil])
        let book = try await FixtureBook.load(folder)
        let viewer = await harness.open(book, skipsPersistence: true)
        await viewer.rotatePage(atIndex: 0, .rotate180)
        await viewer.settle()
        #expect(Quadrants.corners(of: try #require(viewer.currentImages.first)) == .uprightRotatedClockwise(180))
        #expect(viewer.hasPageRotationOverride(atIndex: 0))
        #expect(harness.library.layouts.pageRotations(forBookID: book.id).isEmpty)
        #expect(!harness.library.layouts.layoutBookIDs.contains(book.id))

        await viewer.rotatePage(atIndex: 0, .reset)
        await viewer.settle()
        #expect(Quadrants.corners(of: try #require(viewer.currentImages.first)) == .upright)
    }

    // MARK: - 書き出し

    @Test("CBZ・PDF の書き出しは記録した向きに従う(ファイルの EXIF の向きと食い違えば記録が勝つ)")
    func exportsFollowTheRecordedOrientation() async throws {
        let temporary = try TemporaryDirectory("rotation-export")
        let folder = try Self.folderBook(in: temporary, orientations: [6])
        let source = ExportSource(temp: temporary, book: try await FixtureBook.load(folder))
        let key = source.key(1)

        var cbzInput = ExportInputs.cbz(source)
        cbzInput.pageRotations = [key: 180]
        let cbz = source.destination("out.cbz")
        try await CbzExporter.export(cbzInput, options: ExportInputs.cbzOptions, to: cbz)
        let cbzBook = try await FixtureBook.load(cbz)
        let cbzLoader = PageLoader(book: cbzBook, usesThumbnailDiskCache: false)
        defer { Task { await cbzLoader.releaseAllResources() } }
        let cbzData = try #require(await cbzLoader.rawImageData(at: 0))
        #expect(OrientationBaking.orientation(of: cbzData) == 1)
        #expect(Quadrants.corners(of: cbzData) == .uprightRotatedClockwise(180))

        var pdfInput = ExportInputs.pdf(source)
        pdfInput.pageRotations = [key: 270]
        let pdf = source.destination("out.pdf")
        try await PDFExporter.export(pdfInput, options: ExportInputs.pdfOptions, to: pdf)
        let page = try #require(CGPDFDocument(pdf as CFURL)?.page(at: 1))
        #expect(page.getBoxRect(.mediaBox).size == CGSize(width: Quadrants.height, height: Quadrants.width))
        let pdfBook = try await FixtureBook.load(pdf)
        let pdfLoader = PageLoader(book: pdfBook, usesThumbnailDiskCache: false)
        defer { Task { await pdfLoader.releaseAllResources() } }
        #expect(Quadrants.corners(of: try #require(await pdfLoader.pageImage(at: 0))) == .uprightRotatedClockwise(270))
    }

    @Test("コレクション表紙も記録した向きで作る")
    func coverExtractionFollowsTheRecordedOrientation() async throws {
        let temporary = try TemporaryDirectory("rotation-cover")
        let folder = try Self.folderBook(in: temporary, orientations: [nil])
        let book = try await FixtureBook.load(folder)
        let key = try #require(book.pages.first?.sortKey)
        let cover = try #require(await CoverImageResolver.coverImage(
            bookAt: folder, snapshot: .init(pageRotations: [key: 90]), maxPixelSize: 96, cachesPageList: false
        ))
        #expect(Quadrants.corners(of: cover) == .uprightRotatedClockwise(90))
    }

    // MARK: - 道具

    /// Quadrants の JPEG を、向きの指定 `orientations` ごとに 1 ページずつ並べたフォルダの本(001.jpg …)。
    private static func folderBook(in temporary: TemporaryDirectory, orientations: [Int?]) throws -> URL {
        let folder = temporary.file("book")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, orientation) in orientations.enumerated() {
            let data = PixelGrid.encoded(
                Quadrants.image(), as: .jpeg,
                orientation: orientation.flatMap { CGImagePropertyOrientation(rawValue: UInt32($0)) }
            )
            try data.write(to: folder.appendingPathComponent(String(format: "%03d.jpg", index + 1)))
        }
        return folder
    }

    /// JPEG の圧縮データ(SOS マーカーから後ろ)。
    private static func scanData(_ data: Data) -> Data? {
        data.range(of: Data([0xFF, 0xDA])).map { data[$0.lowerBound...] }
    }
}

private extension PageRef {
    /// フォルダの本のページのファイル(それ以外は nil)。
    var fileURL: URL? {
        if case .file(let url) = source { return url }
        return nil
    }
}

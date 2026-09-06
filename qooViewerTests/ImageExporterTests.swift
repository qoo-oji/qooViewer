import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import qooViewer

/// 画像の書き出し(Services/ImageExporter.swift)。
///
/// 担当は 2 つ ―― 既定のファイル名・形式の決定と、見開き 2 枚の結合。結合は拡大鏡
/// (見開きの境目をまたぐ)でも使われるので、「高さの低い方に合わせて縮小し、歪めない」という
/// 仕様は見た目に直結する。
///
/// 形式の決定でいちばん効くのは **ImageIO が書けない形式(webp)を PNG へ倒すこと**。倒す場所は
/// `mergedFileExtension` の 1 箇所だけで、名前・保存パネルの形式・エンコードがそこから決まる
/// ―― 3 つが同じ値から決まっていないと、中身が PNG なのに名前が `.webp` のファイルができる。
struct ImageExporterTests {
    private func filePage(_ path: String) -> PageRef {
        PageRef(id: path, sortKey: path, source: .file(URL(fileURLWithPath: path)))
    }

    private func archivePage(_ entryPath: String, archive: String = "/books/a.cbz") -> PageRef {
        PageRef(
            id: "\(archive)#\(entryPath)", sortKey: entryPath,
            source: .archive(locator: ArchiveLocator(rootURL: URL(fileURLWithPath: archive)),
                             entryPath: entryPath)
        )
    }

    private func pdfPage(_ index: Int, pdf: String = "/books/scan.pdf") -> PageRef {
        PageRef(id: "\(pdf)#\(index)", sortKey: String(index),
                source: .pdf(container: .file(URL(fileURLWithPath: pdf)), pageIndex: index))
    }

    // MARK: - 形式の決定

    @Test("フォルダ・書庫のページは元の拡張子を小文字で使う")
    func theExtensionFollowsTheOriginalFile() {
        #expect(ImageExporter.fileExtension(for: filePage("/books/vol1/001.PNG")) == "png")
        #expect(ImageExporter.fileExtension(for: filePage("/books/vol1/001.jpeg")) == "jpeg")
        #expect(ImageExporter.fileExtension(for: archivePage("ch01/002.WebP")) == "webp")
    }

    @Test("拡張子が無ければ jpg、PDF のページも jpg(元の形式が無いため)")
    func theFallbackExtensionIsJpeg() {
        #expect(ImageExporter.fileExtension(for: filePage("/books/vol1/001")) == "jpg")
        #expect(ImageExporter.fileExtension(for: archivePage("ch01/002")) == "jpg")
        #expect(ImageExporter.fileExtension(for: pdfPage(0)) == "jpg")
    }

    @Test("結合後の形式は「読み順で先のページ」に合わせる")
    func theMergedExtensionFollowsTheLeadingPage() {
        let leading = filePage("/books/vol1/001.png")
        let trailing = filePage("/books/vol1/002.jpg")
        #expect(ImageExporter.mergedFileExtension(leadingPage: leading, trailingPage: trailing) == "png")
        #expect(ImageExporter.mergedFileExtension(leadingPage: trailing, trailingPage: leading) == "jpg")
    }

    @Test("ImageIO が書けるのは webp 以外(ページとして開ける 10 形式のうち)")
    func onlyWebPCannotBeWritten() {
        for ext in ["jpg", "jpeg", "png", "gif", "bmp", "heic", "tif", "tiff", "avif"] {
            #expect(ImageExporter.canWrite(fileExtension: ext), "\(ext) が書けない")
        }
        #expect(!ImageExporter.canWrite(fileExtension: "webp"))
        // 未知の拡張子も「書けない」。`UTType(filenameExtension:)` は `dyn.…` という動的な UTI を
        // 作って返し nil にならないので、「解決できたか」では判定できない。
        #expect(!ImageExporter.canWrite(fileExtension: "zzz-not-a-format"))
    }

    @Test("ImageIO が書けない形式は、結合の出力を PNG(可逆)へ倒す")
    func anUnwritableSourceFormatFallsBackToPNG() {
        let webp = filePage("/books/vol1/001.webp")
        let jpeg = filePage("/books/vol1/002.jpg")
        // 「元の画像に揃える」は揃えられる形式のときの話。webp のままだとエンコードできず、
        // 見開きの結合そのものが不可能になる。
        #expect(ImageExporter.mergedFileExtension(leadingPage: webp, trailingPage: jpeg) == "png")
        // 名前も PNG になる(名前と中身が食い違わない)。
        #expect(ImageExporter.defaultMergedFileName(leadingPage: webp, trailingPage: jpeg) == "001-002.png")
        // 後のページが webp でも、揃える先は前のページなので影響しない。
        #expect(ImageExporter.mergedFileExtension(leadingPage: jpeg, trailingPage: webp) == "jpg")
    }

    @Test("結合の出力形式は必ず ImageIO が書けるものになる",
          arguments: ["jpg", "jpeg", "png", "gif", "bmp", "heic", "tif", "tiff", "avif", "webp"])
    func theMergedExtensionIsAlwaysWritable(sourceExtension: String) {
        let page = filePage("/books/vol1/001.\(sourceExtension)")
        let merged = ImageExporter.mergedFileExtension(leadingPage: page, trailingPage: page)
        #expect(ImageExporter.canWrite(fileExtension: merged))
    }

    @Test("拡張子から UTType を引く")
    func theContentTypeComesFromTheExtension() {
        #expect(ImageExporter.contentType(forExtension: "png") == .png)
        #expect(ImageExporter.contentType(forExtension: "jpg") == .jpeg)
        // 単一ページの書き出しは生データの複製なので、書けない形式もそのまま返す
        // (webp のページは webp のまま保存できる)。
        #expect(ImageExporter.contentType(forExtension: "webp") == UTType("org.webmproject.webp"))
    }

    @Test("どの形式とも結び付かない拡張子は PNG(可逆)へ落とす")
    func anUnknownExtensionFallsBackToPNG() {
        #expect(ImageExporter.contentType(forExtension: "zzz-not-a-format") == .png)
        #expect(ImageExporter.contentType(forExtension: "") == .png)
    }

    // MARK: - ファイル名の決定

    @Test("単一ページの既定名は元の名前 + 拡張子")
    func theDefaultNameKeepsTheOriginalBaseName() {
        #expect(ImageExporter.defaultFileName(for: filePage("/books/vol1/001.png")) == "001.png")
        #expect(ImageExporter.defaultFileName(for: archivePage("ch01/002.jpg")) == "002.jpg")
    }

    @Test("PDF のページは「PDF 名-ページ番号(1 始まり)」")
    func aPDFPageIsNamedAfterTheDocumentAndPageNumber() {
        #expect(ImageExporter.defaultFileName(for: pdfPage(0)) == "scan-1.jpg")
        #expect(ImageExporter.defaultFileName(for: pdfPage(41)) == "scan-42.jpg")
    }

    @Test("拡張子を指定できる(PDF のページは中の画像の形式を呼び出し側が解決して渡す)")
    func theExtensionCanBeOverridden() {
        #expect(ImageExporter.defaultFileName(for: pdfPage(0), fileExtension: "png") == "scan-1.png")
        #expect(ImageExporter.defaultFileName(for: filePage("/books/001.png"), fileExtension: "jpg")
                == "001.jpg")
    }

    @Test("結合後の既定名は「前-後.拡張子」(前後は画面の左右ではなく読み順)")
    func theMergedNameJoinsBothBaseNamesInReadingOrder() {
        let leading = filePage("/books/vol1/001.png")
        let trailing = filePage("/books/vol1/002.png")
        #expect(ImageExporter.defaultMergedFileName(leadingPage: leading, trailingPage: trailing)
                == "001-002.png")
        // 右開きでも「前」は読み順で先のページ。呼び出し側が解決済みの PageRef を渡す。
        #expect(ImageExporter.defaultMergedFileName(leadingPage: trailing, trailingPage: leading)
                == "002-001.png")
    }

    @Test("書庫の中のページ名はフォルダを含まない(最後の要素だけ)")
    func anArchiveEntryContributesOnlyItsLastComponent() {
        #expect(ImageExporter.defaultMergedFileName(
            leadingPage: archivePage("vol1/ch01/001.jpg"),
            trailingPage: archivePage("vol1/ch01/002.jpg")) == "001-002.jpg")
    }

    @Test("書き出す名前は NFC へ揃える(そのまま Windows へ渡されうるため)")
    func theExportedNameIsNFCNormalized() {
        // 濁点を分解した形(NFD)の「が」。書庫の中のエントリ名はこの形のまま届く
        // (`URL(fileURLWithPath:)` を通すと Foundation が NFC へ直してしまうので、
        // フォルダの本ではこの経路を試せない)。
        let decomposed = "\u{304B}\u{3099}ぞう001"
        let composed = "がぞう001"
        // Swift の `==` は正規等価で比べるので、NFD と NFC は文字列としては等しい。
        // 実際に何バイト並んでいるか(= 書庫やファイルシステムへ出ていく形)はスカラー列で見る。
        #expect(Array(decomposed.unicodeScalars) != Array(composed.unicodeScalars))

        let name = ImageExporter.defaultFileName(for: archivePage("ch01/\(decomposed).png"))
        #expect(Array(name.unicodeScalars) == Array("\(composed).png".unicodeScalars))

        let merged = ImageExporter.defaultMergedFileName(
            leadingPage: archivePage("ch01/\(decomposed).png"),
            trailingPage: archivePage("ch01/002.png"))
        #expect(Array(merged.unicodeScalars) == Array("\(composed)-002.png".unicodeScalars))
    }

    // MARK: - 見開きの結合

    /// 左右で色を変えた 2 枚。境目がどこに来たかを画素で確かめられる。
    private func solid(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) -> CGImage {
        PixelGrid.image(width: width, height: height) { _, _ in rgb }
    }

    @Test("同じ高さなら、幅は合計・高さはそのまま")
    func twoImagesOfEqualHeightAreJoinedSideBySide() throws {
        let left = solid(width: 40, height: 60, rgb: (255, 0, 0))
        let right = solid(width: 30, height: 60, rgb: (0, 0, 255))
        let combined = try #require(ImageExporter.combinedCGImage(leftImage: left, rightImage: right))
        #expect(combined.width == 70)
        #expect(combined.height == 60)

        let read = PixelGrid.pixels(of: combined)
        #expect(read.rgb(5, 30) == (255, 0, 0))    // 左の側
        #expect(read.rgb(60, 30) == (0, 0, 255))   // 右の側
    }

    @Test("高さが違えば低い方に合わせ、もう一方はアスペクト比を保ったまま縮小する")
    func theTallerImageIsScaledDownToMatch() throws {
        // 左: 100x100 → 高さ 50 に合わせて 50x50 へ縮小。右: 40x50 はそのまま。
        let left = solid(width: 100, height: 100, rgb: (255, 0, 0))
        let right = solid(width: 40, height: 50, rgb: (0, 0, 255))
        let combined = try #require(ImageExporter.combinedCGImage(leftImage: left, rightImage: right))
        #expect(combined.height == 50)
        #expect(combined.width == 90)  // 50 + 40 ―― 引き伸ばさず縮小だけで揃える
    }

    @Test("縮小しても幅は最低 1 画素(極端に細長い画像で 0 幅にならない)")
    func aVeryThinImageKeepsAtLeastOnePixelOfWidth() throws {
        let left = solid(width: 1, height: 1000, rgb: (255, 0, 0))
        let right = solid(width: 40, height: 10, rgb: (0, 0, 255))
        let combined = try #require(ImageExporter.combinedCGImage(leftImage: left, rightImage: right))
        #expect(combined.height == 10)
        #expect(combined.width == 41)
    }

    @Test("結合したデータは指定した形式で読み戻せる", arguments: ["png", "jpg"])
    func theCombinedDataIsEncodedInTheRequestedFormat(ext: String) throws {
        let left = solid(width: 20, height: 30, rgb: (255, 0, 0))
        let right = solid(width: 20, height: 30, rgb: (0, 0, 255))
        let data = try ImageExporter.combine(leftImage: left, rightImage: right, outputExtension: ext)

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try #require(CGImageSourceGetType(source) as String?)
        #expect(type == ImageExporter.contentType(forExtension: ext).identifier)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 40)
        #expect(decoded.height == 30)
    }

    @Test("ページとして開けるどの形式の本でも、見開きを結合して書き出せる",
          arguments: ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "tif", "tiff", "avif"])
    func everySupportedPageFormatCanBeExportedAsASpread(sourceExtension: String) throws {
        // 画面の経路(ViewerView.exportImage の .mergedSpread)と同じ順序 ―― 先に拡張子を
        // 決め、その拡張子で名前・保存パネルの形式・エンコードのすべてを揃える。
        let leading = filePage("/books/vol1/001.\(sourceExtension)")
        let trailing = filePage("/books/vol1/002.\(sourceExtension)")
        let ext = ImageExporter.mergedFileExtension(leadingPage: leading, trailingPage: trailing)
        let name = ImageExporter.defaultMergedFileName(leadingPage: leading, trailingPage: trailing)
        #expect(name.hasSuffix(".\(ext)"))

        let image = solid(width: 10, height: 10, rgb: (128, 128, 128))
        let data = try ImageExporter.combine(leftImage: image, rightImage: image, outputExtension: ext)
        #expect(!data.isEmpty)

        // 書き出したバイト列が、名前どおりの形式として読み戻せる。
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == ImageExporter.contentType(forExtension: ext).identifier)
    }

    @Test("webp の本の見開きは PNG として書き出される(利用者から見た結末)")
    func aWebPSpreadIsExportedAsPNG() throws {
        let leading = filePage("/books/vol1/001.webp")
        let trailing = filePage("/books/vol1/002.webp")
        let ext = ImageExporter.mergedFileExtension(leadingPage: leading, trailingPage: trailing)
        #expect(ImageExporter.defaultMergedFileName(leadingPage: leading, trailingPage: trailing)
                == "001-002.png")

        let left = solid(width: 20, height: 30, rgb: (255, 0, 0))
        let right = solid(width: 20, height: 30, rgb: (0, 0, 255))
        let data = try ImageExporter.combine(leftImage: left, rightImage: right, outputExtension: ext)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        // 可逆なので、結合した画素がそのまま残る。
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let read = PixelGrid.pixels(of: decoded)
        #expect(read.rgb(5, 15) == (255, 0, 0))
        #expect(read.rgb(30, 15) == (0, 0, 255))
    }

    @Test("結合は黙って形式を倒さない(名前と中身が食い違わないよう、決定は入口の 1 箇所)")
    func combineItselfStaysStrict() {
        // `mergedFileExtension` を通さずに書けない形式を渡したら、PNG を書くのではなく失敗させる
        // ―― ここで倒すと、保存パネルに出した `.webp` という名前のファイルに PNG が入る。
        let image = solid(width: 10, height: 10, rgb: (128, 128, 128))
        #expect(throws: ImageExporter.ExportError.self) {
            try ImageExporter.combine(leftImage: image, rightImage: image, outputExtension: "webp")
        }
    }

    // MARK: - 書き込み

    @Test("単一ページの書き出しは生データをそのまま置く(再エンコードしない)")
    func writingASinglePageCopiesTheRawBytes() throws {
        let temporary = try TemporaryDirectory("image-export")
        let source = PageImageFactory.data(number: 7, wide: false, fileExtension: "png")
        let url = temporary.file("out.png")
        try ImageExporter.writeSinglePage(data: source, to: url)
        #expect(try Data(contentsOf: url) == source)
    }

    @Test("書き込めない場所へのエラーは writeFailed に包む")
    func aFailedWriteIsWrappedInExportError() throws {
        let temporary = try TemporaryDirectory("image-export-fail")
        // 存在しない中間フォルダ ―― `Data.write` は失敗する。
        let url = temporary.file("no-such-directory/out.png")
        #expect(throws: ImageExporter.ExportError.self) {
            try ImageExporter.writeSinglePage(data: Data([1, 2, 3]), to: url)
        }
        #expect(throws: ImageExporter.ExportError.self) {
            try ImageExporter.writeCombinedImage(data: Data([1, 2, 3]), to: url)
        }
    }
}

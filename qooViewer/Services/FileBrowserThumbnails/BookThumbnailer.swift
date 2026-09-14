import CoreGraphics
import Foundation
import ImageIO

/// ファイルブラウザのアイコン表示に出す**本・画像の絵**を作る(改善要望7 段階 7a、2026-09-14)。
///
/// ■ 本を丸ごと開かない
/// `BookLoader.load` は本の全ページを数え上げる(入れ子の書庫は取り出して開き、フォルダは再帰で走査する)。
/// 棚の表紙の抽出(CollectionCoverExtractor)は 1 冊ずつ順に行うのでそれで足りるが、アイコン表示は
/// 1 画面に数十個のセルが並ぶ。ここでは**先頭の絵 1 枚だけ**を安い経路で取る(検討メモ §6.1):
///
/// | 形式 | 何を読むか |
/// |---|---|
/// | 画像ファイル | そのファイルを ImageIO で縮小して読む |
/// | zip / cbz / rar / cbr / 7z / cb7 | 書庫の索引だけを読み、画像のエントリのうち正準順の先頭を 1 件だけ取り出す |
/// | EPUB | package document の spine の先頭の画像 |
/// | PDF | 1 ページ目を描く |
/// | フォルダ | **直下の**画像のうち正準順の先頭(サブフォルダには降りない) |
///
/// 並びは本を開いたときと同じ `compareCanonicalPageOrder`・同じ除外(`isExcludedArchiveEntry`)なので、
/// 並べ替え・除外をしていない本なら 1 ページ目と同じ絵になる。**違いうるのは次の場合だけ**(一覧の絵であって
/// 表紙の保証ではない、と割り切った):
/// - 書庫の中に書庫・PDF・EPUB が入っていて、その中のページが先頭に来る本(入れ子は開かない。直下に画像が
///   1 枚も無ければ絵を出さない)
/// - フォルダの本で、直下の画像よりサブフォルダの中の画像が先に並ぶもの・画像をサブフォルダにだけ持つもの
///
/// ■ スレッド
/// どれもブロッキングする読み取りなので、**FileIO の上で呼ぶ**(`FileBrowserThumbnailProvider`)。
nonisolated enum BookThumbnailer {
    /// 絵を作る対象の種類。**名前(とフォルダかどうか)だけで決める**(ファイルに触らない)。
    enum Kind: Sendable, Equatable {
        case image
        case archive
        case pdf
        case epub
        /// 直下に画像を持つかもしれないフォルダ(持っていなければ絵は無い)。
        case folder
    }

    /// 絵を作る対象か。ボリューム・パッケージ・記号リンクは作らない(リンクの先は別の場所で、
    /// その場所の読み取りの許可を持っているとは限らない)。
    static func kind(forName name: String, isNavigableFolder: Bool, isPackage: Bool, isSymbolicLink: Bool) -> Kind? {
        guard !isPackage, !isSymbolicLink else { return nil }
        if isNavigableFolder { return .folder }
        if isImageFile(name) { return .image }
        if isArchiveFile(name) { return .archive }
        if isEpubFile(name) { return .epub }
        if isPDFFile(name) { return .pdf }
        return nil
    }

    /// 取り出してよい画像エントリの大きさの上限(宣言サイズ)。ページ画像がこれを超えることはまず無く、
    /// 細工された書庫の伸長爆弾で一覧を読むたびにメモリを食わないための歯止め。
    static let maxEntryBytes: Int64 = 64 * 1024 * 1024

    /// 絵を作る。作れなければ nil(画像が無い・読めない・壊れている)。
    ///
    /// - Parameter maxPixelSize: 長辺の上限(画素)。これより小さい画像は拡大しない。
    static func thumbnail(of url: URL, kind: Kind, maxPixelSize: CGFloat) -> CGImage? {
        switch kind {
        case .image:
            return ImageDecoder.decode(fileAt: url, maxPixelSize: maxPixelSize)
        case .folder:
            guard let first = firstImageFile(inFolder: url) else { return nil }
            return ImageDecoder.decode(fileAt: first, maxPixelSize: maxPixelSize)
        case .archive:
            guard let reader = try? makeArchiveReader(for: url),
                  let path = try? firstImageEntryPath(in: reader)
            else { return nil }
            return decodeEntry(path, in: reader, maxPixelSize: maxPixelSize)
        case .epub:
            guard let reader = try? ZipArchiveReader(url: url),
                  let structure = try? EpubStructureResolver.resolve(reader: reader),
                  let path = structure.pages.first?.entryPath
            else { return nil }
            return decodeEntry(path, in: reader, maxPixelSize: maxPixelSize)
        case .pdf:
            guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
            return render(page, maxPixelSize: maxPixelSize)
        }
    }

    // MARK: - 先頭の絵の選び方

    /// 書庫の直下(入れ子の書庫の中は見ない)の画像エントリのうち、本を開いたときと同じ並びの先頭。
    static func firstImageEntryPath(in reader: ArchiveReading) throws -> String? {
        try firstInCanonicalOrder(reader.listFilePaths().filter { !isExcludedArchiveEntry($0) && isImageFile($0) })
    }

    /// フォルダの直下の画像ファイルのうち、正準順の先頭。**サブフォルダには降りない**(型コメント)。
    ///
    /// 数える規則はフォルダの本(`BookLoader.collectPages(inFolder:)` の `.skipsHiddenFiles`)と揃える:
    /// 名前が `.` で始まるもの・`UF_HIDDEN` のものは数えない。記号リンクは辿らない。`readdir` なので
    /// 1 件ごとの `stat` は画像の名前のものだけ(`DirectoryProbe` と同じ手)。
    static func firstImageFile(inFolder url: URL) -> URL? {
        guard let directory = opendir(url.path) else { return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            var value = entry.pointee
            let name = withUnsafePointer(to: &value.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard !name.hasPrefix("."), isImageFile(name) else { continue }
            let type = Int32(value.d_type)
            guard type == DT_REG || type == DT_UNKNOWN else { continue }
            var status = stat()
            guard lstat(url.appendingPathComponent(name).path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_flags & UInt32(UF_HIDDEN) == 0
            else { continue }
            names.append(name)
        }
        return firstInCanonicalOrder(names).map { url.appendingPathComponent($0, isDirectory: false) }
    }

    static func firstInCanonicalOrder(_ keys: [String]) -> String? {
        keys.min { compareCanonicalPageOrder($0, $1) == .orderedAscending }
    }

    // MARK: - 復号

    private static func decodeEntry(_ path: String, in reader: ArchiveReading, maxPixelSize: CGFloat) -> CGImage? {
        if let declared = reader.entryUncompressedSize(at: path), declared > maxEntryBytes { return nil }
        guard let data = try? reader.data(at: path), Int64(data.count) <= maxEntryBytes else { return nil }
        return ImageDecoder.decode(data, maxPixelSize: maxPixelSize)
    }

    /// PDF のページを長辺 `maxPixelSize` で描く(白地。透明な PDF が一覧の地の色に溶けないように)。
    /// 本の表示(PageLoader.renderPDFPixels)と違って埋め込み画像の解像度は見ない ―― 一覧の絵は小さいので、
    /// 要求どおりの大きさで描けば足りる。
    static func render(_ page: CGPDFPage, maxPixelSize: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let isSideways = rotation == 90 || rotation == 270
        let width = isSideways ? box.height : box.width
        let height = isSideways ? box.width : box.height
        let scale = min(maxPixelSize / width, maxPixelSize / height)
        let pixelWidth = max(1, Int((width * scale).rounded()))
        let pixelHeight = max(1, Int((height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        // `getDrawingTransform` は拡大しない(縮小だけ)ので使わず、倍率・回転(/Rotate は時計回り)・箱の原点を自分で掛ける。
        context.scaleBy(x: scale, y: scale)
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: box.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: box.width, y: box.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: box.height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}

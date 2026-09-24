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
        /// 動画(段階 7b)。QuickLook で作るので**ここでは作らない**(`thumbnail(of:kind:)` は nil)。
        /// 作るのは `FileBrowserThumbnailProvider` が `VideoThumbnailLoading` で。
        case video
        /// アプリケーション(.app。2026-09-14)。中の絵ではなく**アプリのアイコン**を `FileBrowserApplicationIcon` で描く
        /// (ここでは作らない。`make` は `.unavailable`)。
        case application
    }

    /// 絵を作る対象か。ボリューム・パッケージ・記号リンクは作らない(リンクの先は別の場所で、
    /// その場所の読み取りの許可を持っているとは限らない)。パッケージのうちアプリケーション(記号リンクでないもの)だけは
    /// `.application`(アイコンを描く)。
    ///
    /// - Parameter includesVideo: 動画も対象にするか(環境設定「動画のサムネイルを生成」)。
    static func kind(
        forName name: String, isNavigableFolder: Bool, isPackage: Bool, isSymbolicLink: Bool, includesVideo: Bool = true
    ) -> Kind? {
        if FileBrowserApplicationIcon.isApplication(name: name, isPackage: isPackage, isSymbolicLink: isSymbolicLink) {
            return .application
        }
        guard !isPackage, !isSymbolicLink else { return nil }
        if isNavigableFolder { return .folder }
        if isImageFile(name) { return .image }
        if isArchiveFile(name) { return .archive }
        if isEpubFile(name) { return .epub }
        if isPDFFile(name) { return .pdf }
        if includesVideo, VideoThumbnailer.isVideoFile(name) { return .video }
        return nil
    }

    /// 取り出してよい画像エントリの大きさの上限。ページ画像がこれを超えることはまず無く、
    /// 細工された書庫の伸長爆弾で一覧を読むたびにメモリを食わないための歯止め。**宣言サイズだけでなく、伸長しながら数える**
    /// (`decodeEntry`)。
    static let maxEntryBytes: Int64 = 64 * 1024 * 1024

    /// 間引いて読めない形式(無圧縮の BMP など)の画像の画素数の上限(2026-09-14 の 2 回目の監査 24)。縮小でも元の大きさぶん展開するので、
    /// 16000² の BMP 1 枚で約 2GB を確保した。一覧は 4 件ずつ同時に作る。3200 万画素(8000×4000)なら 1 枚あたり数百 MB で済み、
    /// スキャンしたページ画像(数百万〜1000 万画素)は通る。JPEG・PNG・TIFF・HEIC は間引いて読むので掛けない(`ImageDecoder.subsamplingTypeIdentifiers`)。
    static let maxFullDecodePixelCount = 32_000_000

    /// 書庫の中で、先頭の画像より**前にある**エントリの宣言サイズの合計の上限(2026-09-14 の 2 回目の監査 21)。ソリッドの 7z / rar は
    /// 先頭の画像を読むために前のエントリを全部伸長する(64MB の上限は画像自身にしか掛かっていなかった)。書庫の順は、ほぼ名前順に
    /// 並ぶのでページの本では 0 に近い。ソリッドかどうかは見分けない(非ソリッドの書庫では読み飛ばしは安いが、この形は稀なので
    /// 絵が出ない側に倒す)。
    static let maxBytesBeforeFirstImage: Int64 = 256 * 1024 * 1024

    /// 絵を作った結果。
    enum Outcome {
        case image(CGImage)
        /// 作れなかった(画像が無い・読めない・壊れている)。
        case unavailable
        /// 使う絵の実体が手元に無い(iCloud などに追い出されている)ので作らなかった。落としてくれば作れる
        /// (呼び出し側は「作れなかった」とは覚えない)。
        case notDownloaded
    }

    /// 絵を作る。作れなければ nil(画像が無い・読めない・壊れている・実体が手元に無い)。
    ///
    /// - Parameter maxPixelSize: 長辺の上限(画素)。これより小さい画像は拡大しない。
    static func thumbnail(of url: URL, kind: Kind, maxPixelSize: CGFloat) -> CGImage? {
        if case .image(let image) = make(of: url, kind: kind, maxPixelSize: maxPixelSize) { return image }
        return nil
    }

    /// 絵を作る(`thumbnail(of:kind:maxPixelSize:)` の、作らなかった理由を返す版)。
    ///
    /// ■ 追い出されたファイルをダウンロードさせない(2026-09-14 の監査 6)
    /// 一覧の絵のために、iCloud などに追い出されたファイルを落としてこない(Finder も作らない。動画は以前から
    /// `VideoThumbnailer.isDataless` で避けていた)。「ストレージを最適化」したデスクトップをアイコン表示で開くと、
    /// 並んだ書庫が 4 本ずつ落ちてきていた。項目そのもの・フォルダの中の先頭の画像は `SF_DATALESS` を見て作らず、
    /// さらに**読み取り全体をこのスレッドだけ「実体化しない」方針で包む**(`DatalessFiles.withoutDownloading`)ので、
    /// 確かめた後に追い出された・EPUB の中から辿った、などの取りこぼしも読み取りの失敗になるだけでダウンロードは起きない。
    static func make(of url: URL, kind: Kind, maxPixelSize: CGFloat) -> Outcome {
        guard kind != .video, kind != .application else { return .unavailable }
        if DatalessFiles.isDataless(url) { return .notDownloaded }
        return DatalessFiles.withoutDownloading { () -> Outcome in
            switch kind {
            case .image:
                return outcome(ImageDecoder.decode(fileAt: url, maxPixelSize: maxPixelSize, maxFullDecodePixelCount: maxFullDecodePixelCount))
            case .folder:
                guard let first = firstImageFile(inFolder: url) else { return .unavailable }
                if DatalessFiles.isDataless(first) { return .notDownloaded }
                return outcome(ImageDecoder.decode(fileAt: first, maxPixelSize: maxPixelSize, maxFullDecodePixelCount: maxFullDecodePixelCount))
            case .archive:
                guard let reader = try? makeArchiveReader(for: url),
                      let path = try? firstImageEntryPath(in: reader),
                      !readsTooMuchBefore(path, in: reader)
                else { return .unavailable }
                // BCJ2 などストリーミングできない 7z のブロックは丸ごと伸長される。画像自身の上限を超える大きさのブロックは読まない
                // (2026-09-14 の 2 回目の監査 20。800MB のブロックを持つ 143KB の cb7 で 845MB を確保した。フォークの `maxWholeBlockBytes`)。
                (reader as? SevenZipArchiveReader)?.maxWholeBlockBytes = UInt64(maxEntryBytes)
                return outcome(decodeEntry(path, in: reader, maxPixelSize: maxPixelSize))
            case .epub:
                // 絵に要るのは先頭の 1 ページだけ。spine の残りの XHTML は読まない。
                guard let reader = try? makeArchiveReader(kind: .zip, url: url),
                      let structure = try? EpubStructureResolver.resolve(reader: reader, maxPages: 1),
                      let path = structure.pages.first?.entryPath
                else { return .unavailable }
                return outcome(decodeEntry(path, in: reader, maxPixelSize: maxPixelSize))
            case .pdf:
                guard let document = openPDFDocument(at: url), let page = document.page(at: 1) else { return .unavailable }
                return outcome(render(page, maxPixelSize: maxPixelSize))
            case .video, .application:
                return .unavailable
            }
        }
    }

    private static func outcome(_ image: CGImage?) -> Outcome {
        image.map { .image($0) } ?? .unavailable
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

    /// エントリを取り出して縮小する。**上限は伸長しながら数えて、超えた時点で打ち切る**(2026-09-14 の監査 7)。
    /// 以前は宣言サイズを見てから `data(at:)` で全部伸長し、後から大きさを見ていた ―― 宣言を小さく偽った伸長爆弾は
    /// フォルダを表示しただけで数 GB を確保させられた。`dataPrefix` は rar が全体読みに落ちるので使わず、3 形式とも
    /// チャンクで渡す `readEntry` で数える。
    static func decodeEntry(_ path: String, in reader: ArchiveReading, maxPixelSize: CGFloat) -> CGImage? {
        guard let data = boundedEntryData(path, in: reader, maxByteCount: maxEntryBytes) else { return nil }
        return ImageDecoder.decode(data, maxPixelSize: maxPixelSize, maxFullDecodePixelCount: maxFullDecodePixelCount)
    }

    /// 書庫の順で `path` より前にあるファイルの宣言サイズの合計が `limit` を超えるか(`maxBytesBeforeFirstImage`)。zip は
    /// エントリごとに直接読めるので見ない。一覧が引けなければ超えない扱い(読んでみて失敗するだけ)。
    static func readsTooMuchBefore(_ path: String, in reader: ArchiveReading, limit: Int64 = maxBytesBeforeFirstImage) -> Bool {
        guard !(reader is ZipArchiveReader), let entries = try? reader.entriesInArchiveOrder() else { return false }
        var total: Int64 = 0
        for entry in entries where entry.kind == .file {
            if entry.path == path { return false }
            let (sum, overflow) = total.addingReportingOverflow(Int64(clamping: entry.uncompressedSize))
            total = overflow ? .max : sum
            if total > limit { return true }
        }
        return false
    }

    /// エントリの中身。宣言か実際の伸長が `maxByteCount` を超えたら nil(テストのための口)。
    static func boundedEntryData(_ path: String, in reader: ArchiveReading, maxByteCount: Int64) -> Data? {
        if let declared = reader.entryUncompressedSize(at: path), declared > maxByteCount { return nil }
        var data = Data()
        do {
            try reader.readEntry(at: path) { chunk in
                guard Int64(data.count) + Int64(chunk.count) <= maxByteCount else { throw ArchiveReaderError.entryTooLarge }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        return data
    }

    /// PDF のページを長辺 `maxPixelSize` で描く(白地。透明な PDF が一覧の地の色に溶けないように)。
    /// 本の表示(PageLoader.renderPDFPixels)と違って埋め込み画像の解像度は見ない ―― 一覧の絵は小さいので、
    /// 要求どおりの大きさで描けば足りる。
    static func render(_ page: CGPDFPage, maxPixelSize: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        guard box.hasUsablePDFPageSize else { return nil }
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

/// iCloud などに追い出された(実体が手元に無い)ファイルの扱い(2026-09-14 の監査 6)。
nonisolated enum DatalessFiles {
    /// 実体が手元に無い(`SF_DATALESS`)か。判定できなければ false。lstat は実体を落としてこない。
    static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// `root` 自身か、その中(リンクの先へは入らない)に実体が手元に無い項目があるか。**`lstat` と `readdir` だけで歩く**(実体を落としてこない)。
    /// 読めないフォルダは飛ばす。
    static func treeContainsDataless(_ root: URL) -> Bool {
        var pending = [root.path]
        while let path = pending.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if info.st_flags & UInt32(SF_DATALESS) != 0 { return true }
            guard info.st_mode & S_IFMT == S_IFDIR, let directory = opendir(path) else { continue }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                if name != ".", name != ".." { pending.append(path + "/" + name) }
            }
        }
        return false
    }

    /// `body` の間だけ、**このスレッドの**読み取りが追い出されたファイルを落としてこないようにする
    /// (`setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, …_OFF)`)。そういうファイルの読み取りは
    /// 失敗する。FileIO の借りたスレッドは使い回されうるので、終わったら元の方針へ戻す。
    /// ImageIO・CGPDFDocument の読み取りも `body` の中で同じスレッドの上で起きるので効く。
    static func withoutDownloading<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let changed = setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        ) == 0
        defer {
            if changed, previous >= 0 {
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
            }
        }
        return try body()
    }
}

nonisolated extension CGRect {
    /// PDF のページの箱として、描く大きさの計算に使えるか。**有限で、正で、桁が常識の範囲**(1 辺 1,000 万 pt 未満)。
    /// 壊れた・細工された PDF の箱は巨大な実数になりうり、`Int(_:)` へ渡すと `Int.max` を超えてトラップする
    /// (2026-09-14 の監査。`width > 0` だけでは無限大も通る)。
    var hasUsablePDFPageSize: Bool {
        width.isFinite && height.isFinite && minX.isFinite && minY.isFinite
            && width > 0 && height > 0 && width < 10_000_000 && height < 10_000_000
    }
}

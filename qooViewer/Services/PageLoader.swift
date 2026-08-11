import Foundation
import CoreGraphics

/// NSCacheはAnyObjectに準拠する値しか保存できない。CGImageはCore Foundationの
/// トールフリーブリッジ型でAnyObjectとしての扱いが不確実なため、
/// 安全のためこの薄いラッパークラスに包んでからキャッシュに保存する。
/// nonisolated: PageLoader(actor、メインスレッド外)から生成されるため、Xcode 26既定の
/// MainActor自動分離の対象外にしている(詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) {
        self.image = image
    }
}

/// 1ページ分の画像ファイル情報(コンテキストメニュー「情報を見る」、ユーザー要望)。
/// PageLoader.pageImageInfo(at:)が、ピクセルデコードを伴わないヘッダー読み取りだけで
/// 組み立てる。PDFソースの場合はcolorModel/colorProfileName/hasAlphaChannel/fileSizeBytesが
/// 常にnilになる(独立した画像ファイルではなく、PDF自体の1ページのため。pageImageInfo(at:)の
/// コメント参照)。
struct PageImageInfo {
    let fileName: String
    /// 例: "JPEG"、"PDF"。
    let formatDescription: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// 例: "RGB"、"Gray"、"CMYK"。取得できない場合はnil。
    let colorModel: String?
    /// 画像ファイル自体のバイト数(アーカイブ内エントリは展開後のサイズ)。PDFはnil。
    let fileSizeBytes: Int64?
    /// ファイル(アーカイブ内エントリの場合はアーカイブファイル自体)が置かれている場所。
    /// アーカイブ内エントリでは、アーカイブファイルのフルパスにエントリのアーカイブ内
    /// フォルダパスを続けたもの(pageImageInfo(at:)のコメント参照)。取得できない場合はnil。
    let location: String?
    /// アーカイブ形式によっては取得できない(ArchiveReading.entryDates(at:)のコメント参照)。
    let createdDate: Date?
    let modifiedDate: Date?
    /// ICCカラープロファイル名(例: "sRGB IEC61966-2.1")。取得できない場合はnil。
    let colorProfileName: String?
    let hasAlphaChannel: Bool?
}

/// 1冊分のページ画像の読み込みを担当するactor。
///
/// - アーカイブの読み込み(ArchiveReading)はスレッドセーフではないため、
///   actorによる排他制御下でのみ触る。
/// - デコード自体(ImageDecoder.decode)はCPU負荷が高いため、actorの外の
///   バックグラウンドタスクで行い、他のページの読み込みリクエストをブロックしないようにする。
/// - 結果はNSCacheに保存する。NSCacheはメモリが逼迫すると自動的に古いエントリを
///   破棄してくれるため、素のDictionaryと違って際限なくメモリを消費し続けない。
/// - 現在ページの前後を先読み(プリフェッチ)し、ページ送りの体感速度を上げる。
///   スクロールが速くて不要になった先読みはキャンセルする。
actor PageLoader {
    /// varなのは、updateBook(_:)でViewerViewModelから最新のbookを渡し直せるようにするため
    /// (詳細はupdateBook(_:)のコメント参照)。
    private var book: MangaBook

    private var readers: [String: ArchiveReading] = [:]
    /// PDFファイルごとにCGPDFDocumentを使い回す(アーカイブのreaders同様、actorの外から
    /// 同時に触られることはないため安全に直列化される)。
    private var pdfDocuments: [String: CGPDFDocument] = [:]
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]
    /// 進行中の読み込み(アーカイブ展開+デコード)を、ページ+キャッシュの組ごとに覚えておく。
    /// 例えば先読み中のページへちょうどページ送りしたとき、先読みタスクの結果を待たずに
    /// 同じページをもう一度アーカイブ展開・デコードしてしまうと、無駄な二重作業になるうえ
    /// アーカイブ展開(actorで直列化される)が詰まって他のページの表示も遅れてしまう。
    /// そのため、同じページへの読み込みが既に進行中ならその結果を待ち合わせる(合流させる)。
    private var inFlightTasks: [String: Task<CGImage?, Never>] = [:]

    // countLimitは64。環境設定の「先読みする画像数」は最大10まで設定できるため、
    // 前後合わせて最大21枚(2*10+1)が先読み対象になる。NSCacheの上限はヒントに過ぎず
    // 厳密なLRUでもないため、ウィンドウぎりぎりの数に合わせるとプリフェッチしたばかりの
    // 画像がすぐ追い出されて再デコードされる「キャッシュスラッシング」が起こりうる。
    // 余裕を持たせることでこれを防ぐ。totalCostLimit(実質的なメモリ上限)は変えていないので、
    // 上限に達すればそちらが優先され、際限なくメモリを使うことはない。
    private let imageCache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 64
        cache.totalCostLimit = 300 * 1024 * 1024 // 約300MB
        return cache
    }()

    private let thumbnailCache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 300
        cache.totalCostLimit = 60 * 1024 * 1024 // 約60MB
        return cache
    }()

    init(book: MangaBook) {
        self.book = book
    }

    /// この本のページ構成(並び順・除外)が変わったとき、呼び出し元(ViewerViewModel)から
    /// 最新のbookを渡し直すために使う。ユーザー要望により、除外(非表示)・並べ替えの変更を
    /// この本を開き直さずに画像ビューアの表示へ即座に反映できるようにした
    /// (ViewerViewModel.reloadLayoutData参照)。
    ///
    /// 画像そのもののキャッシュ(imageCache/thumbnailCache)はpage.id(内容ベースの安定した
    /// キーで、並び順やインデックスには依存しない)をキーにしているため、ここでは無効化せず
    /// そのまま使い回せる。一方、index基準の参照(image(at:)/prefetch(around:)/
    /// rawImageData(at:))は、この呼び出し以降、新しいbook.pagesの並びに基づいて解決される
    /// ようになる。
    func updateBook(_ book: MangaBook) {
        self.book = book
    }

    /// 指定ページのフルサイズ画像を取得する(キャッシュ済みなら即座に、なければ読み込んでキャッシュする)
    func pageImage(at index: Int) async -> CGImage? {
        await image(at: index, cache: imageCache, maxPixelSize: ImageDecoder.pageMaxPixelSize)
    }

    /// プログレスバー用の小さいサムネイルを取得する
    func thumbnail(at index: Int) async -> CGImage? {
        await image(at: index, cache: thumbnailCache, maxPixelSize: ImageDecoder.progressBarThumbnailMaxPixelSize)
    }

    /// 生の画像データ(デコード前)を返す。EPUB書き出し(EpubExporter、7節)で、画質を落とさず
    /// 元の画像ファイルをそのまま複製するために使う。pageImage/thumbnailと異なりキャッシュは
    /// 行わない(書き出し中に一度読めば十分で、同じページへ二度アクセスすることが無いため)。
    /// PDFソースの場合は常にnil(EPUB書き出しの対象はフォルダ・zip/cbz・rar/cbr・7z/cb7のみで、
    /// PDF/EPUB自体は対象外のため。7.1節参照)。
    func rawImageData(at index: Int) async -> Data? {
        guard book.pages.indices.contains(index) else { return nil }
        return rawData(for: book.pages[index].source)
    }

    /// 指定ページの画像サイズ(幅・高さ、ピクセル単位)だけを取得する。ピクセルデータの
    /// デコードを一切伴わないため、画像の解像度に関わらずほぼ一瞬で終わる
    /// (ViewerViewModelの横長/縦長判定(isWideImage)向け。以前はthumbnail(at:)でサムネイルを
    /// デコードして幅・高さを得ていたが、判定に必要なのは縦横比だけで実際のピクセルは
    /// 使わないため、ImageDecoder.pixelSize(of:)(フォーマットのヘッダー部分だけを読む)に
    /// 置き換えた)。
    ///
    /// PDFソースの場合は、ページ描画(renderPDFPage)と同じCGPDFPage.getBoxRect(.mediaBox)から
    /// 直接取得する(レンダリング不要)。
    ///
    /// 注意: JPEG等のEXIF回転タグが付いた画像は、この関数が返す値がタグ適用前の生の
    /// ピクセルサイズになる(thumbnail(at:)側はkCGImageSourceCreateThumbnailWithTransformで
    /// 回転を反映してから幅・高さを見ているため、回転タグ付きの画像では結果が食い違いうる)。
    /// このアプリが主に扱うマンガのスキャン・アーカイブ画像はカメラ写真と異なりEXIF回転タグを
    /// 持つことが稀なため、実用上の影響は小さいと判断している。
    func pageSize(at index: Int) async -> (width: Int, height: Int)? {
        guard book.pages.indices.contains(index) else { return nil }
        switch book.pages[index].source {
        case .pdf(let pdfURL, let pageIndex):
            guard let document = pdfDocument(for: pdfURL), let page = document.page(at: pageIndex + 1) else {
                return nil
            }
            let box = page.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { return nil }
            return (Int(box.width.rounded()), Int(box.height.rounded()))
        case .file, .zip, .sevenZip, .rar:
            guard let data = rawData(for: book.pages[index].source) else { return nil }
            return ImageDecoder.pixelSize(of: data)
        }
    }

    /// コンテキストメニュー「情報を見る」(ユーザー要望)向けに、指定ページの画像ファイル情報を
    /// 取得する。pageSize(at:)と同じくヘッダー情報の読み取りのみ(ピクセルデコード無し)。
    func pageImageInfo(at index: Int) async -> PageImageInfo? {
        guard book.pages.indices.contains(index) else { return nil }
        let page = book.pages[index]
        switch page.source {
        case .pdf(let pdfURL, let pageIndex):
            // PDFのページは独立した画像ファイルではない(PDF自体の1ページ)ため、色空間・
            // カラープロファイル・アルファチャンネル・ファイルサイズはページ単位では
            // 意味を持たない(nilのまま)。場所・作成日・変更日はPDFファイル自体のもの。
            guard let document = pdfDocument(for: pdfURL), let pdfPage = document.page(at: pageIndex + 1) else {
                return nil
            }
            let box = pdfPage.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { return nil }
            let dates = Self.fileSystemDates(for: pdfURL)
            return PageImageInfo(
                fileName: page.displayName,
                formatDescription: "PDF",
                pixelWidth: Int(box.width.rounded()),
                pixelHeight: Int(box.height.rounded()),
                colorModel: nil,
                fileSizeBytes: nil,
                location: pdfURL.deletingLastPathComponent().path,
                createdDate: dates.created,
                modifiedDate: dates.modified,
                colorProfileName: nil,
                hasAlphaChannel: nil
            )
        case .file(let url):
            guard let data = rawData(for: page.source),
                  let header = ImageDecoder.headerInfo(of: data)
            else { return nil }
            let dates = Self.fileSystemDates(for: url)
            return PageImageInfo(
                fileName: page.displayName,
                formatDescription: Self.imageFormatDescription(forFileName: page.displayName),
                pixelWidth: header.pixelWidth,
                pixelHeight: header.pixelHeight,
                colorModel: header.colorModel,
                fileSizeBytes: Int64(data.count),
                location: url.deletingLastPathComponent().path,
                createdDate: dates.created,
                modifiedDate: dates.modified,
                colorProfileName: header.colorProfileName,
                hasAlphaChannel: header.hasAlpha
            )
        case .zip(let archiveURL, let entryPath), .sevenZip(let archiveURL, let entryPath), .rar(let archiveURL, let entryPath):
            guard let data = rawData(for: page.source),
                  let header = ImageDecoder.headerInfo(of: data)
            else { return nil }
            let dates = reader(for: archiveURL)?.entryDates(at: entryPath) ?? (created: nil, modified: nil)
            // アーカイブ内エントリ自身はディスク上のパスを持たないため、アーカイブファイルの
            // フルパスに、エントリのアーカイブ内フォルダパス(サブフォルダが無ければ空文字列)を
            // 続けたものを「場所」とする。
            let internalFolder = (entryPath as NSString).deletingLastPathComponent
            let location = internalFolder.isEmpty ? archiveURL.path : "\(archiveURL.path)/\(internalFolder)"
            return PageImageInfo(
                fileName: page.displayName,
                formatDescription: Self.imageFormatDescription(forFileName: page.displayName),
                pixelWidth: header.pixelWidth,
                pixelHeight: header.pixelHeight,
                colorModel: header.colorModel,
                fileSizeBytes: Int64(data.count),
                location: location,
                createdDate: dates.created,
                modifiedDate: dates.modified,
                colorProfileName: header.colorProfileName,
                hasAlphaChannel: header.hasAlpha
            )
        }
    }

    /// url自体(フォルダ内の画像ファイル、またはPDFファイル)の、ファイルシステム上の
    /// 作成日時・更新日時。取得できない場合はnil(pageImageInfo(at:)向け)。
    private static func fileSystemDates(for url: URL) -> (created: Date?, modified: Date?) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return (values?.creationDate, values?.contentModificationDate)
    }

    /// ファイル名の拡張子から、表示用のフォーマット名を求める。EpubExporter.imageMediaType
    /// (forExtension:)と同じ発想(拡張子ベースの簡易判定で十分)。
    private static func imageFormatDescription(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "png": return "PNG"
        case "gif": return "GIF"
        case "bmp": return "BMP"
        case "webp": return "WebP"
        case "heic": return "HEIC"
        case "tif", "tiff": return "TIFF"
        case "avif": return "AVIF"
        default: return ext.uppercased()
        }
    }

    /// 画像のエクスポート機能(要望)向け: 「見開きを結合してエクスポート」で、2枚の画像を
    /// 実際に合成するために使う、ダウンサンプリングしない(ImageDecoder.exportMaxPixelSize相当の
    /// 上限のみ持つ)フルサイズのCGImage。pageImage/thumbnailと異なりimageCache/thumbnailCacheには
    /// 保存しない(rawImageDataと同じ理由: エクスポート中に一度読めば十分で、通常の表示キャッシュを
    /// 圧迫したくないため)。decodedImage(for:maxPixelSize:)をそのまま再利用することで、
    /// フォルダ・アーカイブ内画像・PDFのどのソースでも同じ経路(PDFはrenderPDFPageへの描画)で
    /// 扱える。
    func fullResolutionImage(at index: Int) async -> CGImage? {
        guard book.pages.indices.contains(index) else { return nil }
        return await decodedImage(for: book.pages[index].source, maxPixelSize: ImageDecoder.exportMaxPixelSize)
    }

    /// index を中心に前後 radius ページ分を先読みする。
    /// 範囲外になった先読みタスクはキャンセルする。
    func prefetch(around index: Int, radius: Int = 3) {
        guard !book.pages.isEmpty else { return }
        let lower = max(0, index - radius)
        let upper = min(book.pages.count - 1, index + radius)
        guard lower <= upper else { return }

        for (existingIndex, task) in prefetchTasks where existingIndex < lower || existingIndex > upper {
            task.cancel()
            prefetchTasks.removeValue(forKey: existingIndex)
        }

        for pageIndex in lower...upper {
            guard prefetchTasks[pageIndex] == nil else { continue }
            let key = book.pages[pageIndex].id as NSString
            guard imageCache.object(forKey: key) == nil else { continue }

            prefetchTasks[pageIndex] = Task { [weak self] in
                guard let self else { return }
                _ = await self.pageImage(at: pageIndex)
                await self.clearPrefetchTask(for: pageIndex)
            }
        }
    }

    private func clearPrefetchTask(for index: Int) {
        prefetchTasks.removeValue(forKey: index)
    }

    private func image(at index: Int, cache: NSCache<NSString, CGImageBox>, maxPixelSize: CGFloat) async -> CGImage? {
        guard book.pages.indices.contains(index) else { return nil }
        let page = book.pages[index]
        let key = page.id as NSString

        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        // cache(フルサイズ用/サムネイル用)ごとに分けて合流させるため、キーにcacheの識別子も含める
        let inFlightKey = "\(ObjectIdentifier(cache))#\(page.id)"
        if let existingTask = inFlightTasks[inFlightKey] {
            return await existingTask.value
        }

        // 呼び出し元(ViewerViewModel側)のタスクがすでにキャンセルされているなら、
        // ここから先の読み込み/デコードは無駄になるので行わない。
        // スクロールホイールなどで素早く連続してページ送りされたときに、
        // 表示されないとわかっているページのデコードでCPUを使い切ってしまい、
        // 最新のページの表示が遅れるのを防ぐための早期リターン。
        guard !Task.isCancelled else { return nil }

        let task = Task<CGImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.decodedImage(for: page.source, maxPixelSize: maxPixelSize)
        }
        inFlightTasks[inFlightKey] = task

        let decoded = await task.value
        inFlightTasks[inFlightKey] = nil

        guard let decoded else { return nil }
        cache.setObject(CGImageBox(decoded), forKey: key, cost: decoded.width * decoded.height * 4)
        return decoded
    }

    /// ページ1枚分の実際の取得+デコード(またはPDFの場合は描画)を行う。このメソッド自体は
    /// actorに分離されているため、readers/pdfDocumentsなどのactor隔離プロパティへ安全に
    /// アクセスできる(image(at:)内のTaskクロージャは静的にはこのactorに分離されているとは
    /// 保証されないため、`await self.decodedImage(...)`という形でここへ入ってくる)。
    ///
    /// フォルダ内画像・アーカイブ内画像は、rawDataでバイト列を取り出したうえで、デコード自体
    /// (CPU負荷が高い)をactorの外のバックグラウンドタスクで行う。一方PDFのページ描画は、
    /// CGPDFDocument/CGPDFPageというCore Graphicsの参照型をactorの外(Task.detached、
    /// @Sendableクロージャ)へ持ち出さずに使うため、actor内で直接CGImageまで作る
    /// (1ページ分の描画は画像デコードほど重くなく、actorを長時間ブロックする心配は小さい)。
    private func decodedImage(for source: PageSource, maxPixelSize: CGFloat) async -> CGImage? {
        switch source {
        case .pdf(let pdfURL, let pageIndex):
            guard !Task.isCancelled else { return nil }
            return renderPDFPage(pdfURL: pdfURL, pageIndex: pageIndex, maxPixelSize: maxPixelSize)
        case .file, .zip, .sevenZip, .rar:
            guard let data = rawData(for: source) else { return nil }
            guard !Task.isCancelled else { return nil }
            // デコードはactorの外(バックグラウンドタスク)で行い、
            // 他のページのリクエストをここで足止めしないようにする。
            // (Task.detachedのトレーリングクロージャに対する戻り値の型推論がXcodeのバージョンによって
            //  不安定なことがあるため、クロージャの戻り値の型を明示し、Taskの生成とvalueの待ち受けを
            //  分けて書くことで確実に型が決まるようにしている)
            let decodeTask = Task.detached(priority: .userInitiated) { () -> CGImage? in
                ImageDecoder.decode(data, maxPixelSize: maxPixelSize)
            }
            return await decodeTask.value
        }
    }

    private func rawData(for source: PageSource) -> Data? {
        switch source {
        case .file(let url):
            return try? Data(contentsOf: url)
        case .zip(let archiveURL, let entryPath),
             .sevenZip(let archiveURL, let entryPath),
             .rar(let archiveURL, let entryPath):
            return try? reader(for: archiveURL)?.data(at: entryPath)
        case .pdf:
            // PDFはdecodedImage(for:maxPixelSize:)側で直接renderPDFPageに振り分けられるため、
            // ここが実際に呼ばれることはない(switchを網羅させるためのプレースホルダー)。
            return nil
        }
    }

    /// PDFファイルごとにCGPDFDocumentを使い回す。アーカイブのreader(for:)と同様の考え方。
    private func pdfDocument(for pdfURL: URL) -> CGPDFDocument? {
        if let cached = pdfDocuments[pdfURL.path] { return cached }
        guard let document = CGPDFDocument(pdfURL as CFURL) else { return nil }
        pdfDocuments[pdfURL.path] = document
        return document
    }

    /// PDFの指定ページ(0始まり)を、長辺がmaxPixelSizeに収まる解像度でCGImageとして描画する。
    /// 透過を持つPDFページ(白紙部分が透明になっている場合など)でも、他の画像ページと同様に
    /// 不透明な画像として扱えるよう、白背景の上に描画する。
    private func renderPDFPage(pdfURL: URL, pageIndex: Int, maxPixelSize: CGFloat) -> CGImage? {
        guard let document = pdfDocument(for: pdfURL) else { return nil }
        // CGPDFDocumentのページ番号は1始まり(pageIndexは0始まり)。
        guard let page = document.page(at: pageIndex + 1) else { return nil }

        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return nil }

        let scale = min(maxPixelSize / mediaBox.width, maxPixelSize / mediaBox.height)
        let pixelWidth = max(1, Int((mediaBox.width * scale).rounded()))
        let pixelHeight = max(1, Int((mediaBox.height * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))

        context.scaleBy(x: scale, y: scale)
        // メディアボックスの原点が(0, 0)でない場合に備えて平行移動しておく。
        context.translateBy(x: -mediaBox.origin.x, y: -mediaBox.origin.y)
        context.drawPDFPage(page)

        return context.makeImage()
    }

    /// アーカイブごとにReaderを使い回す。actorの外から同時に触られることはないので、
    /// ここでの読み込みは安全に直列化される。
    private func reader(for archiveURL: URL) -> ArchiveReading? {
        if let cached = readers[archiveURL.path] { return cached }
        guard let created = try? makeArchiveReader(for: archiveURL) else { return nil }
        readers[archiveURL.path] = created
        return created
    }
}

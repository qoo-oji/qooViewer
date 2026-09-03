import Foundation
import CoreGraphics
import ImageIO

/// PDF書き出しのオプション。EpubExportOptionsと異なりrenumberImagesSequentially相当の項目は
/// 無い(PDFはページごとに独立したファイルを持たず、1つのファイルへ直接描画するため、
/// 画像ファイル名という概念自体が無い)。
struct PDFExportOptions {
    /// 除外(非表示)ページを含めるか。false(既定)なら除外ページはPDFに含めない
    /// (EpubExportOptions.includeExcludedPagesと同じ既定)。
    var includeExcludedPages: Bool
}

/// 1冊分のPDF書き出しに必要な材料。EpubExportInputのPDF版だが、以下の理由でEPUB版に
/// あった項目の一部を持たない(呼び出し元のPDFExportViewModel.exportOneのコメント参照)。
///
/// - coverOverride: PDFにはEPUBのproperties="cover-image"のような「ページではない埋め込み
///   画像メタデータ」の仕組みが無く、実質的にPDFの1ページ目がカバーとして扱われる(Finderの
///   Quick Look・Acrobat等の慣習)。カバー専用の指定機能自体をPDF出力からは省いた
///   (ユーザーの意向)。
/// - ページ単位のレイアウト: EPUBのrendition:page-spread-left/rightに相当するものがPDFには
///   無い(本全体への指定である`/PageLayout`しかない)。qooViewer独自の表現を作ることもできるが、
///   他のアプリが一切解釈できない形式を新たに増やさない方針(ユーザー選択)。
struct PDFExportInput {
    /// BookLoaderで読み込んだ、並べ替え前・除外前の生のMangaBook(EpubExportInput.bookと同じ)。
    let book: MangaBook
    let pageOrderOverride: [String]?
    /// pageKey(PageRef.sortKey) -> レイアウト状態。除外(excluded)判定にのみ使う
    /// (見開き配置の情報自体はPDFには埋め込まないため、それ以外の値は参照しない)。
    let pageOverrides: [String: PageLayoutState]
    /// ページ順に並んでいる必要はない(書き出し側で実際の出力順に変換する)。
    let bookmarks: [ExportBookmark]
    /// Apple Books互換性の項目と同じ考え方(EpubExportInput.titleOverride参照)。
    /// 空文字/nilの場合はbook.titleをそのまま使う。
    let titleOverride: String?
    /// 空文字/nilの場合はPDFのAuthorメタデータを出力しない。
    let author: String?
    /// メタデータDBに登録されているシリーズ名。空文字/nilならXMPメタデータ自体を埋め込まない
    /// (理由はPDFXMPMetadata.packetのコメント参照)。
    let series: String?
    /// 巻数。seriesが空の場合は使わない。
    ///
    /// **数値として解釈できる文字列(または空文字/nil)だけを渡すこと。** Calibreの
    /// `calibreSI:series_index`は数値(float)として読まれるため、非数値を書くと往復できない
    /// (EpubExportInput.seriesIndexと同じ制約。呼び出し側は
    /// BookMetadata.exportableSeriesIndexを通してから渡す)。
    let seriesIndex: String?
    /// 本全体の読み方向。`/ViewerPreferences`の`/Direction`として埋め込む。
    /// PreparedBook.readingDirectionと同じく常に確定した値で、環境設定の既定値まで解決済み。
    let readingDirection: ReadingDirection
    /// 本ごとの見開き/単ページの強制指定。`/PageLayout`として埋め込む。
    /// 指定が無ければnil(その場合は`/PageLayout`自体を書かない)。
    let forcedDisplayMode: DisplayMode?
}

enum PDFExportError: LocalizedError {
    /// 除外設定・空のページ一覧などにより、書き出せるページが1枚も無かった。
    case noEligiblePages
    /// PDFコンテキスト自体の作成に失敗した(書き込み先に書き込めない等)。
    case creationFailed
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noEligiblePages:
            return String(localized: "This book has no pages to export (all pages may be excluded).", language: AppLanguage.currentLocale)
        case .creationFailed:
            return String(localized: "Couldn't create the PDF file.", language: AppLanguage.currentLocale)
        case .writeFailed(let underlying):
            return String(
                format: String(localized: "Couldn't write the PDF file: %@", language: AppLanguage.currentLocale),
                underlying.localizedDescription
            )
        }
    }
}

/// フォルダ・zip/cbz・rar/cbr・7z/cb7から読み込んだMangaBookとブックマーク情報を、qooViewer
/// 自身のブックマークをPDFのアウトライン(しおり)として埋め込んだ1つのPDFファイルとして
/// 書き出す。EpubExporterのPDF版(設計としてはEPUB書き出し機能と対になる)。
///
/// シリーズ名・巻数(Calibre互換のXMP)と、本全体の読み方向・見開き強制(`/ViewerPreferences`・
/// `/PageLayout`)は、CoreGraphicsのPDFコンテキストからは書き込めないため、閉じたあとに
/// PDFCatalogAugmenterが増分更新で書き加える(理由と仕組みはそちらのコメント参照)。
///
/// 画像を直接PDFページとして描画する(EpubExporterのようなXHTMLラッパー相当のものは無い)。
/// PDFの生成自体はCoreGraphicsのCGContext(PDFコンテキスト)を使う。ページ描画に使っている
/// 既存のCGPDFDocument(読み取り専用)とは別のAPI(CGPDFContextCreateWithURL系)だが、
/// 同じCoreGraphicsフレームワークの標準APIのため追加の依存は不要。
///
/// nonisolated: BookLoader/EpubExporterと同じくメインスレッド外(PDFExportWindowが管理する
/// バックグラウンドタスク)から呼ばれるため、Xcode 26既定のMainActor自動分離の対象外にしている。
nonisolated enum PDFExporter {
    static func export(_ input: PDFExportInput, options: PDFExportOptions, to destinationURL: URL) async throws {
        let excludedKeys: Set<String> = options.includeExcludedPages
            ? []
            : Set(input.pageOverrides.filter { $0.value == .excluded }.map(\.key))
        let orderedPages = EffectivePageOrder.orderedPages(
            for: input.book, pageOrderOverride: input.pageOrderOverride, excludedKeys: excludedKeys
        )
        guard !orderedPages.isEmpty else { throw PDFExportError.noEligiblePages }

        // pageKey -> 元のbook.pagesのインデックス(PageLoaderは元の並びのままbookを保持しているため。
        // EpubExporter.exportの同名の変数と同じ役割)。
        var originalIndexByKey: [String: Int] = [:]
        for (index, page) in input.book.pages.enumerated() { originalIndexByKey[page.sortKey] = index }

        let pageLoader = PageLoader(book: input.book)

        let trimmedTitleOverride = input.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookTitle = (trimmedTitleOverride?.isEmpty == false) ? trimmedTitleOverride! : input.book.title
        let trimmedAuthor = input.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (trimmedAuthor?.isEmpty == false) ? trimmedAuthor : nil

        var auxiliaryInfo: [String: Any] = [kCGPDFContextTitle as String: bookTitle]
        if let author {
            auxiliaryInfo[kCGPDFContextAuthor as String] = author
        }
        // シリーズ名・巻数はここ(Document Info辞書)には書かない。以前はKeywordsへ
        // `series:シリーズ名, series_index:巻数番号`という独自形式で埋めていたが、
        // Calibre互換のXMPへ移行した(経緯はPDFXMPMetadataのコメント参照)。XMPは
        // CGPDFContextからは書けないため、下でPDFを閉じたあとに書き加える。

        // ブックマーク → アウトライン用に、元のpageKeyから実際に書き出したPDFページ番号
        // (1始まり、kCGPDFOutlineDestinationの仕様に合わせる)を求める。画像の取得に失敗して
        // ページ自体を書き出せなかった場合はここに追加しないため、そのページを指すブックマークは
        // 後段で自動的に読み飛ばされる。
        //
        // 画像はpageLoader.fullResolutionImage(ImageDecoder.decode経由)ではなく、
        // rawImageData(生のバイト列)からCGImageSourceCreateImageAtIndexで直接作る。
        // ImageDecoder.decodeはCGImageSourceCreateThumbnailAtIndexを使っており、
        // (ページ表示用に)常に新規のビットマップとして再デコードする作りのため、元がJPEGの場合
        // でも圧縮元データとの結び付きが失われる。これをそのままCGContextへdraw()すると、
        // CoreGraphics側はPDF内に再度(可逆圧縮相当で)エンコードし直すため、ファイルサイズが
        // 元のアーカイブより大幅に(実測で1桁以上)膨れ上がることを確認した。
        // CGImageSourceCreateImageAtIndexで作ったCGImageは圧縮元データへの参照を保持したままに
        // なるため、等倍(スケーリング無し)でPDFページへ描画すると、CoreGraphicsが元のJPEG
        // 圧縮データをそのまま(再エンコードせずに)埋め込む「パススルー」が働き、EPUB書き出し
        // (zip内にraw bytesをそのまま格納)と同等のファイルサイズに収まる。
        //
        // 代償として、EXIFの回転情報の自動反映(kCGImageSourceCreateThumbnailWithTransform)は
        // 行われなくなるが、EpubExporter.exportも同じくrawImageDataをそのまま埋め込んでおり
        // (書き出し先のEPUBリーダー側でもEXIF回転は反映されない)、この点は既存のEPUB書き出しと
        // 挙動を揃えているだけで新たな制約ではない。
        //
        // バグ修正: 以前はこのループの前でPDFコンテキストを作り、ループを抜けた後で
        // 「1ページも書き出せなかった」と分かった時点でnoEligiblePagesを投げていた。この経路は
        // closePDF()を通らないうえ、その時点では既に上書き先の既存ファイルを削除し、空の
        // PDFファイルを作った後だったため、書き出しに失敗すると「元のPDFは消え、壊れた
        // ファイルだけが残る」状態になっていた。
        // 「書き出せるページが1枚でもあるか」の判定をコンテキスト生成より前に行うため、
        // 最初に描画できるページが見つかるまでコンテキストを作らない(=既存ファイルにも
        // 触れない)構成にする。1枚も無ければ、そもそも何も作らずにthrowするだけで済む。
        // ユーザー要望により、元がPDFの本もPDF書き出しの対象になった。その場合は画像を
        // 取り出して描き直すのではなく、元のページをそのままコピーする(CGContext.drawPDFPage)。
        // ページの内容をベクター・テキストも含めて丸ごと写すため、埋め込まれている画像の形式を
        // 問わず無劣化で、かつ再エンコードも発生しない
        // (ユーザー指示: PDF→PDFについては画像形式に関する制約は考えない)。
        let sourcePDFDocument: CGPDFDocument? = {
            guard case .pdf(let pdfURL, _) = input.book.pages.first?.source else { return nil }
            return CGPDFDocument(pdfURL as CFURL)
        }()

        var pageNumberByOriginalKey: [String: Int] = [:]
        var pageNumber = 0
        var context: CGContext?
        for page in orderedPages {
            guard let originalIndex = originalIndexByKey[page.sortKey] else { continue }

            // 描画に必要な材料(元PDFのページ、または画像)を先に用意する。用意できない
            // ページは飛ばす(この時点ではまだ書き出し先に触れない)。
            var sourcePage: CGPDFPage?
            var image: CGImage?
            var mediaBox: CGRect
            if let sourcePDFDocument, case .pdf(_, let pdfPageIndex) = page.source {
                guard let pdfPage = sourcePDFDocument.page(at: pdfPageIndex + 1) else { continue }
                let box = pdfPage.getBoxRect(.mediaBox)
                guard box.width > 0, box.height > 0 else { continue }
                sourcePage = pdfPage
                mediaBox = CGRect(origin: .zero, size: box.size)
            } else {
                guard let data = await pageLoader.rawImageData(at: originalIndex),
                      let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                      let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
                else { continue }
                image = decoded
                mediaBox = CGRect(x: 0, y: 0, width: CGFloat(decoded.width), height: CGFloat(decoded.height))
            }

            // 最初に描画できるページが確定した、このタイミングで初めて書き出し先を作る。
            let pdfContext: CGContext
            if let context {
                pdfContext = context
            } else {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
                guard let created = CGContext(
                    destinationURL as CFURL, mediaBox: nil, auxiliaryInfo as CFDictionary
                ) else {
                    throw PDFExportError.creationFailed
                }
                context = created
                pdfContext = created
            }

            pageNumber += 1
            pageNumberByOriginalKey[page.sortKey] = pageNumber

            pdfContext.beginPage(mediaBox: &mediaBox)
            if let sourcePage {
                // 元ページの原点がmediaBoxの左下と一致しない場合に備えて平行移動してから写す。
                //
                // `/Rotate`(ページの回転指定)は考慮していない。ビューア側の描画
                // (PageLoader.renderPDFPage)もmediaBoxをそのまま使って同じように写しており、
                // 画面で見たとおりのものが書き出される。どちらか一方だけを直すと表示と出力が
                // 食い違うため、直すなら両方を`CGPDFPageGetDrawingTransform`ベースに揃えること。
                let box = sourcePage.getBoxRect(.mediaBox)
                pdfContext.saveGState()
                pdfContext.translateBy(x: -box.origin.x, y: -box.origin.y)
                pdfContext.drawPDFPage(sourcePage)
                pdfContext.restoreGState()
            } else if let image {
                pdfContext.draw(image, in: mediaBox)
            }
            pdfContext.endPage()
        }
        // contextがnilであることと「1ページも書き出せなかった」ことは同値(上のとおり、最初の
        // 1ページを描画する直前にしか生成しないため)。この時点ではまだ何も作っていないので、
        // 後始末の必要なくそのままthrowできる。
        guard let context else { throw PDFExportError.noEligiblePages }

        if let outline = makeOutline(bookmarks: input.bookmarks, pageNumberByOriginalKey: pageNumberByOriginalKey) {
            CGPDFContextSetOutline(context, outline)
        }
        context.closePDF()

        // Document Catalogにしか置けない情報を、書き終わったファイルへ追記する。
        // CGPDFContextにはこれらを書き込む手段が無い(PDFCatalogAugmenterのコメント参照)。
        try PDFCatalogAugmenter.apply(
            PDFCatalogAugmenter.Augmentation(
                xmpPacket: PDFXMPMetadata.packet(
                    title: bookTitle, author: author,
                    series: input.series ?? "", seriesIndex: input.seriesIndex
                ),
                // 読み方向は常に書く。本ごとの上書きが無い場合でも環境設定の既定値まで
                // 解決済みの値が渡ってくるので、EPUB書き出しがspineの
                // page-progression-directionを常に出力しているのと同じ扱いにする
                // (EpubExportInput/PreparedBook.readingDirectionのコメント参照)。
                viewerPreferencesDirection: PDFStructureResolver.catalogDirectionName(
                    for: input.readingDirection
                ),
                pageLayout: PDFStructureResolver.catalogPageLayoutName(
                    for: input.forcedDisplayMode, direction: input.readingDirection
                )
            ),
            to: destinationURL
        )
    }

    /// ブックマーク一覧を、CGPDFContextSetOutlineが受け取る形式のCFDictionary木へ変換する
    /// (kCGPDFOutlineTitle/kCGPDFOutlineDestination/kCGPDFOutlineChildrenの3キー。
    /// kCGPDFOutlineDestinationの値は1始まりのページ番号を表すCFNumber。
    /// CGPDFDocument.hのコメント、およびPDFStructureResolver.resolveOutlineが読み取り側で
    /// 使っているkCGPDFOutlineキー一式と対になる)。ネスト(章立て)は行わず、EPUBの目次と同じく
    /// フラットな一覧として埋め込む。1件も無ければnilを返す(アウトライン自体を設定しない)。
    private static func makeOutline(
        bookmarks: [ExportBookmark], pageNumberByOriginalKey: [String: Int]
    ) -> CFDictionary? {
        var children: [[String: Any]] = []
        for bookmark in bookmarks {
            guard let pageNumber = pageNumberByOriginalKey[bookmark.pageKey] else { continue }
            children.append([
                kCGPDFOutlineTitle as String: bookmark.name,
                kCGPDFOutlineDestination as String: pageNumber as NSNumber
            ])
        }
        guard !children.isEmpty else { return nil }
        return [kCGPDFOutlineChildren as String: children] as CFDictionary
    }
}

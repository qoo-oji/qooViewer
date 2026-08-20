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

/// PDFのアウトライン(しおり)へ書き出す1件のブックマーク。EpubExportBookmarkのPDF版。
struct PDFExportBookmark {
    /// 元のPageRef.sortKey(BookLoaderが読み込んだ、並べ替え前のページキー)。
    let pageKey: String
    let name: String
}

/// 1冊分のPDF書き出しに必要な材料。EpubExportInputのPDF版だが、以下の理由でEPUB版に
/// あった項目の一部を持たない(呼び出し元のPDFExportViewModel.exportOneのコメント参照)。
///
/// - coverOverride: PDFにはEPUBのproperties="cover-image"のような「ページではない埋め込み
///   画像メタデータ」の仕組みが無く、実質的にPDFの1ページ目がカバーとして扱われる(Finderの
///   Quick Look・Acrobat等の慣習)。カバー専用の指定機能自体をPDF出力からは省いた
///   (ユーザーの意向)。
/// - readingDirectionOverride/forcedDisplayMode: PDFのDocument Catalogの
///   `/ViewerPreferences/Direction`・`/PageLayout`は読み取り専用のAPI
///   (CGPDFDictionaryGetName等)しか無く、PDFの書き出し側(CGPDFContext/PDFKitのどちらにも)には
///   これらを書き込むための公式APIが存在しない。そのため見開き/読み方向の情報はPDF書き出しでは
///   埋め込まない(PDFExportWindowに警告文を表示してユーザーに伝える)。
struct PDFExportInput {
    /// BookLoaderで読み込んだ、並べ替え前・除外前の生のMangaBook(EpubExportInput.bookと同じ)。
    let book: MangaBook
    let pageOrderOverride: [String]?
    /// pageKey(PageRef.sortKey) -> レイアウト状態。除外(excluded)判定にのみ使う
    /// (見開き配置の情報自体はPDFには埋め込まないため、それ以外の値は参照しない)。
    let pageOverrides: [String: PageLayoutState]
    /// ページ順に並んでいる必要はない(書き出し側で実際の出力順に変換する)。
    let bookmarks: [PDFExportBookmark]
    /// Apple Books互換性の項目と同じ考え方(EpubExportInput.titleOverride参照)。
    /// 空文字/nilの場合はbook.titleをそのまま使う。
    let titleOverride: String?
    /// 空文字/nilの場合はPDFのAuthorメタデータを出力しない。
    let author: String?
    /// メタデータDBに登録されているシリーズ名。空文字/nilならKeywordsへ何も書かない。
    let series: String?
    /// 巻数。seriesが空の場合は使わない。
    ///
    /// **数値として解釈できる文字列(または空文字/nil)だけを渡すこと。** 読み戻す
    /// PDFStructureResolver.parseSeriesKeywordsは数字しか受け付けないため、非数値を書くと
    /// 往復できない(EpubExportInput.seriesIndexと同じ制約。呼び出し側は
    /// BookMetadata.exportableSeriesIndexを通してから渡す)。
    let seriesIndex: String?
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
            return String(localized: "This book has no pages to export (all pages may be excluded).")
        case .creationFailed:
            return String(localized: "Couldn't create the PDF file.")
        case .writeFailed(let underlying):
            return String(
                format: String(localized: "Couldn't write the PDF file: %@"),
                underlying.localizedDescription
            )
        }
    }
}

/// フォルダ・zip/cbz・rar/cbr・7z/cb7から読み込んだMangaBookとブックマーク情報を、qooViewer
/// 自身のブックマークをPDFのアウトライン(しおり)として埋め込んだ1つのPDFファイルとして
/// 書き出す。EpubExporterのPDF版(設計としてはEPUB書き出し機能と対になるが、ページレイアウト
/// (見開き/読み方向)は埋め込まない。PDFExportInputのコメント参照)。
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
        // ユーザー要望: PDFにはシリーズ名・巻数を表す標準的なフィールドが無いため、
        // Keywordsへ`series:シリーズ名, series_index:巻数番号`の形式で埋め込む。
        // 書式の定義は読み取り側(PDFStructureResolver.parseSeriesKeywords)と共有している。
        if let keywords = PDFStructureResolver.formatSeriesKeywords(
            series: input.series ?? "", seriesIndex: input.seriesIndex ?? ""
        ) {
            auxiliaryInfo[kCGPDFContextKeywords as String] = keywords
        }

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
    }

    /// ブックマーク一覧を、CGPDFContextSetOutlineが受け取る形式のCFDictionary木へ変換する
    /// (kCGPDFOutlineTitle/kCGPDFOutlineDestination/kCGPDFOutlineChildrenの3キー。
    /// kCGPDFOutlineDestinationの値は1始まりのページ番号を表すCFNumber。
    /// CGPDFDocument.hのコメント、およびPDFStructureResolver.resolveOutlineが読み取り側で
    /// 使っているkCGPDFOutlineキー一式と対になる)。ネスト(章立て)は行わず、EPUBの目次と同じく
    /// フラットな一覧として埋め込む。1件も無ければnilを返す(アウトライン自体を設定しない)。
    private static func makeOutline(
        bookmarks: [PDFExportBookmark], pageNumberByOriginalKey: [String: Int]
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

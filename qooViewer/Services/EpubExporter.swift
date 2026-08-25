import Foundation
import ImageIO
import ZIPFoundation

/// EPUB書き出し(設計コンセプト7.2節)のオプション。
struct EpubExportOptions {
    /// 画像ファイルの連番リネーム。ONの場合、書き出す順序(2.3節のページ順補正を反映済み)を
    /// 基準に、桁数可変の連番("000.jpg"など)へリネームする。
    var renumberImagesSequentially: Bool
    /// 除外(非表示)ページを含めるか。false(既定)なら除外ページはEPUBに含めない。
    var includeExcludedPages: Bool
}

/// 1冊分の書き出しに必要な材料。呼び出し側(EpubExportWindow)が、対象の本ごとにBookLoaderで
/// 読み込んだMangaBookと、LayoutStore/BookmarkStoreから集めたデータをまとめて渡す。
struct EpubExportInput {
    /// BookLoaderで読み込んだ、並べ替え前・除外前の生のMangaBook(4節の編集ウインドウと同じく、
    /// ViewerViewModelが加工した後のbookではなく、除外済みページも含む全ページ一覧が必要)。
    let book: MangaBook
    let pageOrderOverride: [String]?
    /// pageKey(PageRef.sortKey) -> レイアウト状態。
    let pageOverrides: [String: PageLayoutState]
    let readingDirectionOverride: ReadingDirection?
    let forcedDisplayMode: DisplayMode?
    /// ページ順に並んでいる必要はない(書き出し側で実際の出力順に変換する)。
    let bookmarks: [ExportBookmark]
    let coverOverride: ExportCoverOverride?
    /// Apple Books互換性(ユーザー要望): EPUB出力ウインドウのタイトル欄で編集された値。
    /// 空文字/nilの場合はbook.title(元のファイル/フォルダ名相当)をそのまま使う。
    let titleOverride: String?
    /// Apple Books互換性(ユーザー要望): EPUB出力ウインドウの著者名欄で編集された値。
    /// 空文字/nilの場合はdc:creatorを出力しない。
    let author: String?
    /// メタデータDBに登録されているシリーズ名。空文字/nilならシリーズ情報を出力しない。
    let series: String?
    /// 巻数。seriesが空の場合は使わない。
    ///
    /// **数値として解釈できる文字列(または空文字/nil)だけを渡すこと。** EPUB3の
    /// group-positionは数値必須で、非数値を書くとepubcheckがエラーにする。呼び出し側は
    /// BookMetadata.exportableSeriesIndexを通してから渡す(値を決める責任は呼び出し側に
    /// 寄せてある。languageと同じ方針)。
    let seriesIndex: String?
    /// dc:languageに書き出すBCP 47の言語タグ("ja"/"en"など)。
    ///
    /// ユーザー報告: 以前はここを常に"und"(undetermined。ISO 639-2の「言語不明」を表す
    /// 正規のコード)で出力していたが、Kindle Previewerはこれをエラーとして弾く。qooViewerが
    /// 扱うのは画像ベースのコミックで、本文テキストが無く言語を機械的に判定する手立てが
    /// 無いため、アプリの表示言語設定(AppPreferences.displayLanguage、「システムに従う」なら
    /// OSのロケール)から解決した言語コードを入れる(EpubExportViewModel参照)。
    /// 空文字/nilの場合は"en"にフォールバックする(dc:languageはEPUB3の必須要素のため、
    /// 省略という選択肢は取れない)。
    let language: String?
}

enum EpubExportError: LocalizedError {
    /// 除外設定・空のページ一覧などにより、書き出せるページが1枚も無かった。
    case noEligiblePages
    /// あるページの画像データを読み出せなかった(書庫が壊れている、PDFを開けない等)。
    ///
    /// 黙ってそのページを飛ばすことはしない。package document(OPF)のmanifestは
    /// **全ページぶん**を先に組み立ててあるため、画像だけ書き込まずに進むと、実体の無い
    /// ファイルを参照するmanifestを持ったEPUBが出来上がる。EPUBの仕様上これは不正で、
    /// リーダーによってはファイル自体を開けなくなる。PDFの非対応画像形式を
    /// エラーにしているのと同じ考え方(PDFImageExtractor参照)。
    case pageImageUnavailable(pageName: String)
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noEligiblePages:
            return String(localized: "This book has no pages to export (all pages may be excluded).")
        case .pageImageUnavailable(let pageName):
            return String(
                format: String(localized: "Couldn't read the image for page “%@”, so this book can't be exported."),
                pageName
            )
        case .writeFailed(let underlying):
            return String(
                format: String(localized: "Couldn't write the EPUB file: %@"),
                underlying.localizedDescription
            )
        }
    }
}

/// EpubStructureResolverの逆方向。フォルダ・zip/cbz・rar/cbr・7z/cb7から読み込んだMangaBookと
/// レイアウト・ブックマーク情報を、固定レイアウト(pre-paginated)のコミックEPUBとして書き出す
/// (設計コンセプト7節)。
///
/// 画像を直接spineに置く簡易方式ではなく、ページごとに画像を全画面表示する最小限のXHTML
/// ラッパー(+インラインCSS)を生成する(7.4節、他の一般的なEPUBリーダーでも正しく開けるように
/// するため)。zip書き込み自体はZIPFoundation(既存の依存、ZipArchiveReaderが読み込みに使っている
/// のと同じパッケージ)の書き込みAPIを使う。
///
/// nonisolated: BookLoader/PageLoaderと同じくメインスレッド外(EpubExportWindowが管理する
/// バックグラウンドタスク)から呼ばれるため、Xcode 26既定のMainActor自動分離の対象外にしている。
nonisolated enum EpubExporter {
    private static let textDirectory = "Text"
    private static let imagesDirectory = "Images"

    /// ページ画像のピクセル寸法。Kindle向けのoriginal-resolutionメタデータを決めるために
    /// ページごとの実寸を集計するので、辞書のキーにできるHashableな型にしてある。
    private struct PixelSize: Hashable {
        let width: Int
        let height: Int
    }

    private struct PreparedPage {
        /// 元のPageRef.sortKey(pageOverrides/bookmarksとの突き合わせに使う)。
        let originalPageKey: String
        let imageFileName: String
        let xhtmlFileName: String
        let spreadPosition: PageSpreadPosition?
    }

    /// カバー画像の解決結果(ユーザー要望: EPUB出力時のカバー画像を選択・変更できるように
    /// したい)。
    private struct ResolvedCover {
        /// カバーが、書き出し済みのprepared配列内の既存ページと同じ画像を指す場合、その
        /// インデックス。この場合は新たにファイルを追加せず、既存の画像manifest項目に
        /// properties="cover-image"を付け足すだけで済む。
        let existingPageIndex: Int?
        /// 既存ページの画像を使い回せない(専用ファイル、または除外設定によりspineに
        /// 含まれない既存ページをカバーに選んだ)場合に、別途zipへ追加する画像ファイルの情報。
        let standaloneFile: (fileName: String, data: Data, mediaType: String)?
    }

    /// input.coverOverrideに従って、実際にカバーとして使う画像を決定する。nilの場合は
    /// 呼び出し元がカバー指定を諦める(book.pagesが空でpreparedも空、という通常起こりえない
    /// ケースのみ)。
    private static func resolveCover(
        input: EpubExportInput, prepared: [PreparedPage], originalIndexByKey: [String: Int], pageLoader: PageLoader
    ) async -> ResolvedCover? {
        switch input.coverOverride {
        case .existingPage(let pageKey):
            if let index = prepared.firstIndex(where: { $0.originalPageKey == pageKey }) {
                return ResolvedCover(existingPageIndex: index, standaloneFile: nil)
            }
            // 除外設定により選んだページが実際のspineに含まれていない場合でも、カバーとしては
            // 使えるようにする(ユーザー要望を汲んだ挙動)。専用ファイルとして別途埋め込む。
            if let originalIndex = originalIndexByKey[pageKey], input.book.pages.indices.contains(originalIndex),
               let exportable = try? await pageLoader.exportableImage(at: originalIndex),
               let cover = standaloneCoverFile(data: exportable.data, sourceExtension: exportable.fileExtension) {
                return ResolvedCover(existingPageIndex: nil, standaloneFile: cover)
            }
            return defaultCover(prepared: prepared)
        case .externalFile(let data, let ext):
            // 変換に失敗した(壊れている・デコードできない)場合は、カバー指定だけを諦めて
            // 既定のカバー(先頭ページ)へ落とす。本の書き出し自体は続けられる。
            if let cover = standaloneCoverFile(data: data, sourceExtension: ext) {
                return ResolvedCover(existingPageIndex: nil, standaloneFile: cover)
            }
            return defaultCover(prepared: prepared)
        case nil:
            return defaultCover(prepared: prepared)
        }
    }

    /// 本に含まれない専用ファイルとして埋め込むカバー画像。EPUBへそのまま入れられない形式は
    /// ページ画像と同じくPNGへ変換する(passthroughImageExtensions参照)。
    private static func standaloneCoverFile(
        data: Data, sourceExtension ext: String
    ) -> (fileName: String, data: Data, mediaType: String)? {
        let exportExtension = epubImageFileExtension(forSource: ext)
        guard let exportData = epubImageData(data, sourceExtension: ext) else { return nil }
        return ("cover.\(exportExtension)", exportData, imageMediaType(forExtension: exportExtension))
    }

    /// 既定のカバー(書き出し後の実質的な先頭ページ)。
    private static func defaultCover(prepared: [PreparedPage]) -> ResolvedCover? {
        guard prepared.indices.contains(0) else { return nil }
        return ResolvedCover(existingPageIndex: 0, standaloneFile: nil)
    }

    static func export(_ input: EpubExportInput, options: EpubExportOptions, to destinationURL: URL) async throws {
        let excludedKeys: Set<String> = options.includeExcludedPages
            ? []
            : Set(input.pageOverrides.filter { $0.value == .excluded }.map(\.key))
        let orderedPages = EffectivePageOrder.orderedPages(
            for: input.book, pageOrderOverride: input.pageOrderOverride, excludedKeys: excludedKeys
        )
        guard !orderedPages.isEmpty else { throw EpubExportError.noEligiblePages }

        // pageKey -> 元のbook.pagesのインデックス(PageLoaderは元の並びのままbookを保持しているため)。
        var originalIndexByKey: [String: Int] = [:]
        for (index, page) in input.book.pages.enumerated() { originalIndexByKey[page.sortKey] = index }

        let pageLoader = PageLoader(book: input.book)

        // 出力ファイル名の決定(7.2節)。連番の桁数は出力するページ数の桁数に応じて可変にする
        // (例: 100ページなら3桁で"000"〜)。
        //
        // 元がPDFの本(ユーザー要望により対象に追加)は、ページに「元のファイル名」という単位が
        // 無いため、連番リネームの設定に関わらず常にページ順の6桁連番にする(ユーザー指定)。
        let isPDFSource = orderedPages.first.map { if case .pdf = $0.source { true } else { false } } ?? false
        let digitWidth = max(String(orderedPages.count).count, 1)
        var usedFileNames: Set<String> = []
        var prepared: [PreparedPage] = []
        for (sequenceIndex, page) in orderedPages.enumerated() {
            // 拡張子は、PDFの場合だけ実際に埋め込まれている画像の形式(JPEG→jpg /
            // 可逆形式→png)から決まるため、PageLoaderに問い合わせる。対応していない形式や
            // 読み出せないページが含まれていればここでエラーになり、書き出し先を作る前に
            // 中断できる(下の書き込みループで初めて気付くと、途中まで書いたEPUBが残る)。
            guard let originalIndex = originalIndexByKey[page.sortKey] else {
                throw EpubExportError.pageImageUnavailable(pageName: page.displayName)
            }
            // EPUBへそのまま入れられない形式は、ここでPNGに決めておく(実際の変換は下の
            // 書き込みループ。passthroughImageExtensions参照)。
            let ext = epubImageFileExtension(
                forSource: try await pageLoader.exportableImageFileExtension(at: originalIndex)
            )
            let imageFileName: String
            if isPDFSource {
                imageFileName = String(format: "%06d.%@", sequenceIndex + 1, ext)
                usedFileNames.insert(imageFileName)
            } else if options.renumberImagesSequentially {
                imageFileName = String(format: "%0\(digitWidth)d.%@", sequenceIndex, ext)
                usedFileNames.insert(imageFileName)
            } else {
                imageFileName = uniqueFileName(basedOn: originalBaseName(for: page), extension: ext, used: &usedFileNames)
            }
            let xhtmlFileName = (imageFileName as NSString).deletingPathExtension + ".xhtml"
            let state = input.pageOverrides[page.sortKey]
            prepared.append(
                PreparedPage(
                    originalPageKey: page.sortKey,
                    imageFileName: imageFileName,
                    xhtmlFileName: xhtmlFileName,
                    spreadPosition: state?.asEpubEquivalentSpreadPosition
                )
            )
        }

        // ブックマーク → 目次(7.5節、順方向)。元のpageKeyから、書き出し後のxhtmlファイル名を求める。
        var xhtmlFileNameByOriginalKey: [String: String] = [:]
        for item in prepared { xhtmlFileNameByOriginalKey[item.originalPageKey] = item.xhtmlFileName }
        var tocEntries: [(href: String, title: String)] = []
        for bookmark in input.bookmarks {
            guard let xhtmlFileName = xhtmlFileNameByOriginalKey[bookmark.pageKey] else { continue }
            tocEntries.append((href(textDirectory, xhtmlFileName), bookmark.name))
        }

        // Apple Books互換性(ユーザー要望): タイトル・著者名をEPUB出力ウインドウで編集できる
        // ようにしたい。空文字/空白のみの場合は編集していない扱いとし、元のbook.titleを使う。
        let trimmedTitleOverride = input.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookTitle = (trimmedTitleOverride?.isEmpty == false) ? trimmedTitleOverride! : input.book.title
        let trimmedAuthor = input.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (trimmedAuthor?.isEmpty == false) ? trimmedAuthor : nil
        // dc:languageはEPUB3の必須要素のため、値が渡ってこなかった場合も省略はせず"en"にする
        // (EpubExportInput.languageのコメント参照)。
        let trimmedLanguage = input.language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = (trimmedLanguage?.isEmpty == false) ? trimmedLanguage! : "en"
        let identifier = "urn:uuid:\(UUID().uuidString)"

        // カバー画像の決定(ユーザー要望: EPUB出力時のカバー画像を選択・変更できるようにしたい)。
        let resolvedCover = await resolveCover(
            input: input, prepared: prepared, originalIndexByKey: originalIndexByKey, pageLoader: pageLoader
        )

        // Apple Books互換性(ユーザー要望): カバー画像をproperties="cover-image"だけで
        // マークしていたが、それに加えてEPUB2互換の<guide><reference type="cover">を
        // (XHTMLページへのhrefとして)併記しておくと、カバーの認識がより安定するリーダーが
        // 多いことが知られている。既存ページをカバーに使う場合はそのページ自身のxhtmlを
        // 指せば済むが、本に含まれない専用ファイルをカバーにした場合(standaloneFile)は
        // 参照先のXHTMLページが無いため、ここで専用の"cover.xhtml"を追加で書き出す。
        var coverGuideHref: String?
        var standaloneCoverXHTMLFileName: String?
        if let resolvedCover {
            if let existingIndex = resolvedCover.existingPageIndex, prepared.indices.contains(existingIndex) {
                coverGuideHref = href(textDirectory, prepared[existingIndex].xhtmlFileName)
            } else if let standalone = resolvedCover.standaloneFile {
                let xhtmlFileName = (standalone.fileName as NSString).deletingPathExtension + ".xhtml"
                standaloneCoverXHTMLFileName = xhtmlFileName
                coverGuideHref = href(textDirectory, xhtmlFileName)
            }
        }

        let containerXML = makeContainerDocument()
        let trimmedSeries = input.series?.trimmingCharacters(in: .whitespacesAndNewlines)
        let series = (trimmedSeries?.isEmpty == false) ? trimmedSeries : nil
        let seriesIndex = input.seriesIndex?.trimmingCharacters(in: .whitespacesAndNewlines)

        let firstPageHref = prepared.first.map { href(textDirectory, $0.xhtmlFileName) }
        let navXML = makeNavDocument(title: bookTitle, tocEntries: tocEntries, fallbackHref: firstPageHref)

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            let archive = try Archive(url: destinationURL, accessMode: .create)

            // mimetypeファイルはEPUB仕様上、zip内の最初のエントリかつ無圧縮(格納)である必要がある。
            try addEntry(to: archive, path: "mimetype", data: Data("application/epub+zip".utf8), compressed: false)
            try addEntry(to: archive, path: "META-INF/container.xml", data: Data(containerXML.utf8), compressed: true)
            try addEntry(to: archive, path: "OEBPS/nav.xhtml", data: Data(navXML.utf8), compressed: true)

            // 画像の生データ(デコードなし、画質を落とさない)は、以前は全ページぶんを先に
            // imageDataByFileName辞書へ集めてからまとめて書き込んでいたが、ページ数が多い本では
            // 全ページの生データを同時にメモリ上に保持することになり無駄が大きかった。
            // 1ページぶんずつ「取得 → (必要ならピクセルサイズを算出) → 書き込み → 破棄」する形に
            // まとめることで、同時に保持する画像データを常に1ページぶんだけにする
            // (書き出されるzipの内容・順序はどちらの実装でも同一)。
            //
            // package.opfのKindle向けoriginal-resolutionメタデータ(makePackageDocument参照)には
            // 全ページの実寸が要るため、ここで1ページずつ算出済みのピクセルサイズを集めておき、
            // package.opf自体はこのループの後で書き出す(サイズを得るためだけに画像をもう一度
            // 読み直すのは、ページ数の多い本では無駄が大きい)。zip内のエントリ順は
            // mimetypeが先頭であることだけが仕様上の要件で、package.opfの位置は自由。
            var pageResolutions: [PixelSize] = []
            for (page, item) in zip(orderedPages, prepared) {
                // 画像が読めないページがあれば、そこで書き出しを中断する。飛ばして進むと
                // 実体の無いファイルを参照するmanifestを持った不正なEPUBが出来上がる
                // (EpubExportError.pageImageUnavailableのコメント参照)。
                guard let originalIndex = originalIndexByKey[page.sortKey],
                      let exportable = try await pageLoader.exportableImage(at: originalIndex)
                else {
                    throw EpubExportError.pageImageUnavailable(pageName: page.displayName)
                }
                guard let imageData = epubImageData(exportable.data, sourceExtension: exportable.fileExtension)
                else {
                    throw EpubExportError.pageImageUnavailable(pageName: page.displayName)
                }
                let pixelSize = ImageDecoder.pixelSize(of: imageData)
                if let pixelSize {
                    pageResolutions.append(PixelSize(width: pixelSize.width, height: pixelSize.height))
                }
                let pageXHTML = makePageDocument(title: bookTitle, imageFileName: item.imageFileName, pixelSize: pixelSize)
                try addEntry(
                    to: archive, path: "OEBPS/\(textDirectory)/\(item.xhtmlFileName)",
                    data: Data(pageXHTML.utf8), compressed: true
                )
                try addEntry(
                    to: archive, path: "OEBPS/\(imagesDirectory)/\(item.imageFileName)",
                    data: imageData, compressed: true
                )
            }

            // カバー専用ファイル(本に含まれない専用ファイル、または除外設定によりspineに
            // 含まれない既存ページをカバーに選んだ場合)は、通常のページとは別にここで書き出す。
            // spineには追加しない(通常の読書対象ではなく、カバーとしてのみ扱う)。
            if let standalone = resolvedCover?.standaloneFile {
                try addEntry(
                    to: archive, path: "OEBPS/\(imagesDirectory)/\(standalone.fileName)",
                    data: standalone.data, compressed: true
                )
                // <guide>のカバー参照先として使う専用XHTML(上のcoverGuideHref算出箇所参照)。
                if let standaloneCoverXHTMLFileName {
                    // 固定レイアウトのページはviewportで実寸を宣言する必要があるため、
                    // 通常のページと同じくカバー画像のピクセルサイズを渡す。
                    let coverXHTML = makePageDocument(
                        title: bookTitle, imageFileName: standalone.fileName,
                        pixelSize: ImageDecoder.pixelSize(of: standalone.data)
                    )
                    try addEntry(
                        to: archive, path: "OEBPS/\(textDirectory)/\(standaloneCoverXHTMLFileName)",
                        data: Data(coverXHTML.utf8), compressed: true
                    )
                }
            }

            // package.opfは、上のページ書き出しループで集めたピクセルサイズが要るため最後に書く
            // (ループ冒頭のコメント参照)。
            let opfXML = makePackageDocument(
                title: bookTitle, author: author, language: language,
                series: series, seriesIndex: (seriesIndex?.isEmpty == false) ? seriesIndex : nil,
                identifier: identifier, pages: prepared,
                readingDirection: input.readingDirectionOverride, forcedDisplayMode: input.forcedDisplayMode,
                cover: resolvedCover, coverGuideHref: coverGuideHref,
                originalResolution: representativeResolution(of: pageResolutions)
            )
            try addEntry(to: archive, path: "OEBPS/package.opf", data: Data(opfXML.utf8), compressed: true)
        } catch let error as EpubExportError {
            throw error
        } catch {
            throw EpubExportError.writeFailed(underlying: error)
        }
    }

    // MARK: - ZIPFoundationへの書き込み

    private static func addEntry(to archive: Archive, path: String, data: Data, compressed: Bool) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compressed ? .deflate : .none
        ) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }

    // MARK: - ファイル名の決定(7.2節)

    private static func originalBaseName(for page: PageRef) -> String {
        switch page.source {
        case .file(let url):
            return url.deletingPathExtension().lastPathComponent
        case .archive(_, let entryPath):
            return ((entryPath as NSString).lastPathComponent as NSString).deletingPathExtension
        case .pdf:
            // 元がPDFの本は、この関数を通らない常時6桁連番の経路になる(export内の
            // isPDFSource参照)ため到達しない。
            return "page"
        }
    }

    /// 連番リネームがOFFの場合、元のファイル名をできるだけそのまま使うが、異なるサブフォルダに
    /// 同名ファイルがあった場合の衝突を避けるため、必要なら"-2"のような連番を付けて一意にする
    /// (7.1節は連番リネームOFF時の衝突回避策そのものには触れていないため、ここでの判断)。
    private static func uniqueFileName(basedOn baseName: String, extension ext: String, used: inout Set<String>) -> String {
        let sanitizedBase = baseName.isEmpty ? "page" : baseName
        var candidate = "\(sanitizedBase).\(ext)"
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(sanitizedBase)-\(suffix).\(ext)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    // MARK: - 画像形式の調整

    /// 元のバイト列をそのままEPUBへ入れてよい画像形式(拡張子)。
    ///
    /// 実測(Kindle Previewer 3.106 / EPUBCheck 5.2.1)では、これ以外の形式は次のように扱われる:
    /// - WebP・HEIC・BMP・AVIF: Kindle Previewerの変換がE21019で失敗する(画像を復号できない)。
    /// - HEIC・BMP・TIFF・AVIF: EPUBのコア画像形式ではないため、代替(fallback)の無いリソースとして
    ///   EPUBCheckがRSC-032のエラーにする。
    /// そのため、ここに無い形式は書き出し時にPNG(可逆)へ変換する。
    private static let passthroughImageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif"]

    /// 書き出すページ画像の拡張子。画像データを読まずに決まるため、ファイル名(=manifest)を
    /// 先に確定させる必要のあるprepareの段階でも使える。
    private static func epubImageFileExtension(forSource ext: String) -> String {
        passthroughImageExtensions.contains(ext.lowercased()) ? ext.lowercased() : "png"
    }

    /// epubImageFileExtension(forSource:)がPNGへの変換を選んだ形式なら、実際に変換したデータを返す。
    /// 変換が不要な形式ならバイト列をそのまま返す(元の画質・ファイルサイズを保つ)。
    private static func epubImageData(_ data: Data, sourceExtension ext: String) -> Data? {
        guard epubImageFileExtension(forSource: ext) != ext.lowercased() else { return data }
        return ImageDecoder.pngData(from: data)
    }

    private static func imageMediaType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        case "avif": return "image/avif"
        default: return "image/jpeg"
        }
    }

    // MARK: - qooViewer側 → EPUB側の語彙変換(7.4節の対応表)

    private static func epubPageProgressionDirection(_ direction: ReadingDirection?) -> String? {
        switch direction {
        case .rightToLeft: return "rtl"
        case .leftToRight: return "ltr"
        case nil: return nil
        }
    }

    /// Kindle独自メタデータprimary-writing-mode(ページ送り方向)への変換。
    /// 縦書き(vertical-rl)は扱わない — 本アプリが書き出すのは画像だけのコミックEPUBで、
    /// Kindleが見るのはページ送りの向きだけのため、右開き=horizontal-rlで足りる。
    private static func kindlePrimaryWritingMode(_ direction: ReadingDirection?) -> String? {
        switch direction {
        case .rightToLeft: return "horizontal-rl"
        case .leftToRight: return "horizontal-lr"
        case nil: return nil
        }
    }

    private static func epubRenditionSpread(_ mode: DisplayMode?) -> String? {
        switch mode {
        case .single: return "none"
        case .spread: return "both"
        case nil: return nil
        }
    }

    private static func epubSpreadProperty(_ position: PageSpreadPosition?) -> String? {
        switch position {
        case .left: return "page-spread-left"
        case .right: return "page-spread-right"
        case .center: return "rendition:page-spread-center"
        case nil: return nil
        }
    }

    /// Kindleのoriginal-resolutionメタデータに書く「この本の代表的なページ寸法」を求める。
    ///
    /// 判型が途中で変わる本(見開き結合ページ、巻末のおまけページなど)もあるため、
    /// 先頭ページを無条件に使うのではなく、最も多くのページで使われている寸法を採用する。
    /// 同数の場合は先に現れた(＝巻頭に近い)ほうを選び、出力を安定させる。
    private static func representativeResolution(of sizes: [PixelSize]) -> PixelSize? {
        var counts: [PixelSize: Int] = [:]
        for size in sizes { counts[size, default: 0] += 1 }
        var best: PixelSize?
        var bestCount = 0
        for size in sizes where counts[size, default: 0] > bestCount {
            best = size
            bestCount = counts[size, default: 0]
        }
        return best
    }

    // MARK: - XML生成

    /// エンコードせずに残す文字(RFC 3986のunreserved)。CharacterSet.alphanumericsは日本語などの
    /// 非ASCII文字も「英数字」として含んでしまい、そのまま素通しになるため使わない。
    private static let urlPathAllowedCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        set.insert(charactersIn: "0123456789")
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// OPFのhref・XHTMLのsrcに書くための、ファイル名1つ分のパーセントエンコード。
    ///
    /// 連番リネームがOFFのときは元のファイル名をそのまま使うため、名前に空白や記号、非ASCII文字が
    /// 入りうる。エンコードせずに書くと、実測で次のように壊れる:
    /// - "&"を含む名前: OPFがXMLとして壊れる(EPUBCheckはRSC-016のFATAL)。Kindle Previewerは
    ///   その画像を見つけられず、W14010の警告を出したうえでページが空のまま変換される。
    /// - 空白を含む名前: EPUBCheckが「有効なURLではない」(RSC-020)としてエラーにする。
    ///
    /// zip内のエントリ名は元のファイル名のままにし、参照側だけをエンコードする(リーダーがURLとして
    /// 解決すると元の名前に戻るため、両者は一致する)。
    private static func urlPathComponent(_ fileName: String) -> String {
        fileName.addingPercentEncoding(withAllowedCharacters: urlPathAllowedCharacters) ?? fileName
    }

    /// ディレクトリ名 + パーセントエンコードしたファイル名。OPF・XHTML・目次のすべてで使う。
    private static func href(_ directory: String, _ fileName: String) -> String {
        "\(directory)/\(urlPathComponent(fileName))"
    }

    /// XMLのテキスト・属性値としての最小限のエスケープに加えて、XML 1.0が文書内に持てない
    /// 制御文字を取り除く。
    ///
    /// 取り除きが必要なのは、ここへ来る文字列にユーザーが自由入力したブックマーク名・
    /// タイトル・著者名・シリーズ名が含まれるため(nav.xhtmlの目次項目、package.opfの
    /// dc:title/dc:creator/belongs-to-collection)。制御文字が1文字混ざっただけでEPUBは
    /// XMLとして不正になり、リーダーによってはファイル自体を開けなくなる
    /// (ファイル名の"&"をエスケープせずに書いてOPFが壊れたのと同じ種類の問題。
    ///  ComicInfoXML.escapeも同じ理由で同じ処理を行っている)。
    private static func xmlEscape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                guard isAllowedInXML(scalar) else { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// XML 1.0のChar生成規則で許される文字かどうか(ComicInfoXML.isAllowedInXMLと同じ判定)。
    private static func isAllowedInXML(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD: return true
        case 0x20...0xD7FF: return true
        case 0xE000...0xFFFD: return true
        case 0x10000...0x10FFFF: return true
        default: return false
        }
    }

    private static func makeContainerDocument() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }

    private static func makePackageDocument(
        title: String, author: String?, language: String, series: String?, seriesIndex: String?,
        identifier: String, pages: [PreparedPage],
        readingDirection: ReadingDirection?, forcedDisplayMode: DisplayMode?, cover: ResolvedCover?,
        coverGuideHref: String?, originalResolution: PixelSize?
    ) -> String {
        let modifiedFormatter = DateFormatter()
        modifiedFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        modifiedFormatter.timeZone = TimeZone(identifier: "UTC")
        modifiedFormatter.locale = Locale(identifier: "en_US_POSIX")
        let modified = modifiedFormatter.string(from: Date())

        var metadataLines = [
            "    <dc:identifier id=\"book-id\">\(xmlEscape(identifier))</dc:identifier>",
            "    <dc:title>\(xmlEscape(title))</dc:title>",
            "    <dc:language>\(xmlEscape(language))</dc:language>",
            "    <meta property=\"dcterms:modified\">\(modified)</meta>",
            "    <meta property=\"rendition:layout\">pre-paginated</meta>"
        ]
        if let spread = epubRenditionSpread(forcedDisplayMode) {
            metadataLines.append("    <meta property=\"rendition:spread\">\(spread)</meta>")
        }

        // Kindle互換性(ユーザー報告: Kindle Previewerが変換に失敗し、エラーE34002
        // 「幅 x 高さの形式で、元の解像度のメタデータ値を指定してください」を返す)。
        // Kindleはrendition:layout=pre-paginatedのEPUBを固定レイアウト本として扱うが、その際は
        // EPUB2形式のname/content属性で書かれたKindle独自メタデータ、特にoriginal-resolution
        // (基準となるページの実寸)を必須としており、無いと変換自体が失敗する。
        // 他のEPUBリーダーはname/content属性のmetaを単に無視するため、併記しても害はない
        // (calibre:seriesや<meta name="cover">と同じ扱い)。
        //
        // 値の内訳はKindle Comic Converterが出力するものに合わせている:
        // - fixed-layout: 固定レイアウト本であることの明示。
        // - original-resolution: 基準ページの「幅x高さ」(representativeResolution参照)。
        // - book-type=comic: コミックとして扱わせる(ページ送り・表示の最適化)。
        // - primary-writing-mode: ページ送り方向。右開き(rtl)ならhorizontal-rl。
        // - zero-gutter / zero-margin: ページ画像を余白なしで全画面に敷く(生成CSSと同じ意図)。
        // - orientation-lock=none: 端末の向きを固定しない(横向きでの見開き表示を妨げない)。
        if let originalResolution {
            metadataLines.append("    <meta name=\"fixed-layout\" content=\"true\"/>")
            metadataLines.append(
                "    <meta name=\"original-resolution\" content=\""
                    + "\(originalResolution.width)x\(originalResolution.height)\"/>"
            )
            metadataLines.append("    <meta name=\"book-type\" content=\"comic\"/>")
            if let writingMode = kindlePrimaryWritingMode(readingDirection) {
                metadataLines.append("    <meta name=\"primary-writing-mode\" content=\"\(writingMode)\"/>")
            }
            metadataLines.append("    <meta name=\"zero-gutter\" content=\"true\"/>")
            metadataLines.append("    <meta name=\"zero-margin\" content=\"true\"/>")
            metadataLines.append("    <meta name=\"orientation-lock\" content=\"none\"/>")
        }

        // Apple Books互換性(ユーザー要望): タイトルに加えて著者名も設定できるようにしたい。
        // id="creator"を付けたうえでrole(aut=著者)を明示しておく(EPUB3の推奨形式)。
        if let author {
            metadataLines.append("    <dc:creator id=\"creator\">\(xmlEscape(author))</dc:creator>")
            metadataLines.append(
                "    <meta refines=\"#creator\" property=\"role\" scheme=\"marc:relators\">aut</meta>"
            )
        }

        // ユーザー要望: メタデータのシリーズ名と巻数を、2種類の形式の両方で埋め込む。
        // 読み取る側のソフトによって対応している形式が違うため、片方だけでは取りこぼす。
        //
        // 1. EPUB3の標準形式。belongs-to-collectionにidを振り、collection-typeとgroup-positionを
        //    refinesでそれに結び付ける(EpubStructureResolver.resolveMetadataが読む形と同じ)。
        // 2. Calibre独自の拡張メタデータ。EPUB2形式のname/content属性で書く。
        //    Calibreをはじめ、この形式にしか対応していない読み手が多いため併記する。
        if let series {
            metadataLines.append(
                "    <meta property=\"belongs-to-collection\" id=\"series\">\(xmlEscape(series))</meta>"
            )
            metadataLines.append(
                "    <meta refines=\"#series\" property=\"collection-type\">series</meta>"
            )
            if let seriesIndex {
                metadataLines.append(
                    "    <meta refines=\"#series\" property=\"group-position\">\(xmlEscape(seriesIndex))</meta>"
                )
            }
            metadataLines.append("    <meta name=\"calibre:series\" content=\"\(xmlEscape(series))\"/>")
            if let seriesIndex {
                metadataLines.append(
                    "    <meta name=\"calibre:series_index\" content=\"\(xmlEscape(seriesIndex))\"/>"
                )
            }
        }

        var manifestLines = [
            "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        ]
        var spineLines: [String] = []
        for (index, page) in pages.enumerated() {
            let itemID = "page\(index)"
            let imageID = "img\(index)"
            let ext = (page.imageFileName as NSString).pathExtension
            // ユーザー要望: カバー画像を選択・変更できるようにしたい。既存ページがカバーに
            // 選ばれている場合(既定の先頭ページ、または明示的に選んだ既存ページ)は、新たに
            // ファイルを追加せず、その画像のmanifest項目にproperties="cover-image"を
            // 付け足すだけにする。
            let isCoverImage = cover?.existingPageIndex == index
            let imageProperties = isCoverImage ? " properties=\"cover-image\"" : ""
            manifestLines.append(
                "    <item id=\"\(itemID)\" href=\"\(href(textDirectory, page.xhtmlFileName))\" "
                    + "media-type=\"application/xhtml+xml\"/>"
            )
            manifestLines.append(
                "    <item id=\"\(imageID)\" href=\"\(href(imagesDirectory, page.imageFileName))\" "
                    + "media-type=\"\(imageMediaType(forExtension: ext))\"\(imageProperties)/>"
            )
            if let property = epubSpreadProperty(page.spreadPosition) {
                spineLines.append("    <itemref idref=\"\(itemID)\" properties=\"\(property)\"/>")
            } else {
                spineLines.append("    <itemref idref=\"\(itemID)\"/>")
            }
        }

        // カバー専用ファイル(本に含まれない専用ファイル、または除外設定によりspineに
        // 含まれない既存ページをカバーに選んだ場合)を、通常のページとは別のmanifest項目として
        // 追加する。spineには加えない(通常の読書対象ではなくカバーとしてのみ扱う)。
        var coverItemID: String?
        if let cover {
            if let existingIndex = cover.existingPageIndex {
                coverItemID = "img\(existingIndex)"
            } else if let standalone = cover.standaloneFile {
                let id = "cover-image"
                manifestLines.append(
                    "    <item id=\"\(id)\" href=\"\(href(imagesDirectory, standalone.fileName))\" "
                        + "media-type=\"\(standalone.mediaType)\" properties=\"cover-image\"/>"
                )
                coverItemID = id
                // coverGuideHrefが指す専用cover.xhtml(export側で生成済み)もmanifestへ追加する。
                // spineには含めない(通常の読書対象ではなくカバーとしてのみ扱うため)。
                if let coverGuideHref {
                    manifestLines.append(
                        "    <item id=\"cover-page\" href=\"\(coverGuideHref)\" media-type=\"application/xhtml+xml\"/>"
                    )
                }
            }
        }
        // EPUB2互換のカバー指定(<meta name="cover">)。EPUB3のproperties="cover-image"だけでは
        // 認識しないリーダー向けの互換措置として両方書いておく。
        if let coverItemID {
            metadataLines.append("    <meta name=\"cover\" content=\"\(coverItemID)\"/>")
        }

        let spineAttribute = epubPageProgressionDirection(readingDirection)
            .map { " page-progression-direction=\"\($0)\"" } ?? ""

        // Apple Books互換性(ユーザー要望: カバー画像を認識しない): EPUB3のproperties=
        // "cover-image"だけでなく、EPUB2互換の<guide><reference type="cover">も併記しておく。
        // 一部のリーダー/カタログ表示(ライブラリのサムネイル生成)は、こちらの古い形式を
        // 優先または併用して参照することが知られているため、両対応にしておくのが安全。
        let guideBlock = coverGuideHref.map { href in
            """

              <guide>
                <reference type="cover" title="Cover" href="\(xmlEscape(href))"/>
              </guide>
            """
        } ?? ""

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        \(metadataLines.joined(separator: "\n"))
          </metadata>
          <manifest>
        \(manifestLines.joined(separator: "\n"))
          </manifest>
          <spine\(spineAttribute)>
        \(spineLines.joined(separator: "\n"))
          </spine>\(guideBlock)
        </package>
        """
    }

    /// EPUB3のnav文書。`<nav epub:type="toc">`にブックマークを目次として埋め込む(7.5節)。
    /// ブックマークが1件も無い場合は、目次自体を完全に空にはせず、先頭ページへのリンクを
    /// 1件だけ入れておく(有効なEPUBとして開けることを優先した、こちら側の判断)。
    private static func makeNavDocument(
        title: String, tocEntries: [(href: String, title: String)], fallbackHref: String?
    ) -> String {
        let entries: [(href: String, title: String)]
        if tocEntries.isEmpty, let fallbackHref {
            entries = [(fallbackHref, title)]
        } else {
            entries = tocEntries
        }
        let listItems = entries
            .map { "      <li><a href=\"\($0.href)\">\(xmlEscape($0.title))</a></li>" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
          <meta charset="UTF-8"/>
          <title>\(xmlEscape(title))</title>
        </head>
        <body>
          <nav epub:type="toc" id="toc">
            <h1>\(xmlEscape(title))</h1>
            <ol>
        \(listItems)
            </ol>
          </nav>
        </body>
        </html>
        """
    }

    /// ページ1枚分のXHTMLラッパー(7.4節)。画像を画面いっぱいに表示する最小限のインラインCSSのみ。
    private static func makePageDocument(title: String, imageFileName: String, pixelSize: (width: Int, height: Int)?) -> String {
        let viewportMeta = pixelSize.map {
            "\n  <meta name=\"viewport\" content=\"width=\($0.width), height=\($0.height)\"/>"
        } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <meta charset="UTF-8"/>
          <title>\(xmlEscape(title))</title>\(viewportMeta)
          <style>
            html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000000; }
            img { display: block; width: 100%; height: 100%; object-fit: contain; }
          </style>
        </head>
        <body>
          <img src="../\(href(imagesDirectory, imageFileName))" alt=""/>
        </body>
        </html>
        """
    }
}

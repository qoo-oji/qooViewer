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

/// 目次(nav.xhtml)へ書き出す1件のブックマーク。
struct EpubExportBookmark {
    /// 元のPageRef.sortKey(BookLoaderが読み込んだ、並べ替え前のページキー)。
    let pageKey: String
    let name: String
}

/// カバー画像の上書き指定(ユーザー要望: EPUB出力時のカバー画像を選択・変更できるように
/// したい)。EpubExportInput.coverOverrideがnilの場合は、書き出し後の実質的な先頭ページ
/// (除外・並べ替え反映後の1ページ目)を既定のカバーとして使う。
enum EpubCoverOverride {
    /// 本に含まれる既存ページをカバーにする(pageKeyは元のPageRef.sortKey)。除外設定により
    /// このページ自体は通常の読書順(spine)に含まれない場合でも、カバーとしては使える
    /// ようにする(ユーザー要望を汲んだ挙動)。
    case existingPage(pageKey: String)
    /// 本に含まれない専用ファイルをカバーにする。
    case externalFile(data: Data, fileExtension: String)
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
    let bookmarks: [EpubExportBookmark]
    let coverOverride: EpubCoverOverride?
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
               let exportable = try? await pageLoader.exportableImage(at: originalIndex) {
                let ext = exportable.fileExtension
                return ResolvedCover(
                    existingPageIndex: nil,
                    standaloneFile: ("cover.\(ext)", exportable.data, imageMediaType(forExtension: ext))
                )
            }
            return defaultCover(prepared: prepared)
        case .externalFile(let data, let ext):
            return ResolvedCover(
                existingPageIndex: nil,
                standaloneFile: ("cover.\(ext)", data, imageMediaType(forExtension: ext))
            )
        case nil:
            return defaultCover(prepared: prepared)
        }
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
            let ext = try await pageLoader.exportableImageFileExtension(at: originalIndex)
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
            tocEntries.append(("\(textDirectory)/\(xhtmlFileName)", bookmark.name))
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
                coverGuideHref = "\(textDirectory)/\(prepared[existingIndex].xhtmlFileName)"
            } else if let standalone = resolvedCover.standaloneFile {
                let xhtmlFileName = (standalone.fileName as NSString).deletingPathExtension + ".xhtml"
                standaloneCoverXHTMLFileName = xhtmlFileName
                coverGuideHref = "\(textDirectory)/\(xhtmlFileName)"
            }
        }

        let containerXML = makeContainerDocument()
        let trimmedSeries = input.series?.trimmingCharacters(in: .whitespacesAndNewlines)
        let series = (trimmedSeries?.isEmpty == false) ? trimmedSeries : nil
        let seriesIndex = input.seriesIndex?.trimmingCharacters(in: .whitespacesAndNewlines)

        let opfXML = makePackageDocument(
            title: bookTitle, author: author, language: language,
            series: series, seriesIndex: (seriesIndex?.isEmpty == false) ? seriesIndex : nil,
            identifier: identifier, pages: prepared,
            readingDirection: input.readingDirectionOverride, forcedDisplayMode: input.forcedDisplayMode,
            cover: resolvedCover, coverGuideHref: coverGuideHref
        )
        let firstPageHref = prepared.first.map { "\(textDirectory)/\($0.xhtmlFileName)" }
        let navXML = makeNavDocument(title: bookTitle, tocEntries: tocEntries, fallbackHref: firstPageHref)

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            let archive = try Archive(url: destinationURL, accessMode: .create)

            // mimetypeファイルはEPUB仕様上、zip内の最初のエントリかつ無圧縮(格納)である必要がある。
            try addEntry(to: archive, path: "mimetype", data: Data("application/epub+zip".utf8), compressed: false)
            try addEntry(to: archive, path: "META-INF/container.xml", data: Data(containerXML.utf8), compressed: true)
            try addEntry(to: archive, path: "OEBPS/package.opf", data: Data(opfXML.utf8), compressed: true)
            try addEntry(to: archive, path: "OEBPS/nav.xhtml", data: Data(navXML.utf8), compressed: true)

            // 画像の生データ(デコードなし、画質を落とさない)は、以前は全ページぶんを先に
            // imageDataByFileName辞書へ集めてからまとめて書き込んでいたが、ページ数が多い本では
            // 全ページの生データを同時にメモリ上に保持することになり無駄が大きかった。
            // 1ページぶんずつ「取得 → (必要ならピクセルサイズを算出) → 書き込み → 破棄」する形に
            // まとめることで、同時に保持する画像データを常に1ページぶんだけにする
            // (書き出されるzipの内容・順序はどちらの実装でも同一)。
            for (page, item) in zip(orderedPages, prepared) {
                // 画像が読めないページがあれば、そこで書き出しを中断する。飛ばして進むと
                // 実体の無いファイルを参照するmanifestを持った不正なEPUBが出来上がる
                // (EpubExportError.pageImageUnavailableのコメント参照)。
                guard let originalIndex = originalIndexByKey[page.sortKey],
                      let exportable = try await pageLoader.exportableImage(at: originalIndex)
                else {
                    throw EpubExportError.pageImageUnavailable(pageName: page.displayName)
                }
                let imageData = exportable.data
                let pixelSize = ImageDecoder.pixelSize(of: imageData)
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
                    let coverXHTML = makePageDocument(
                        title: bookTitle, imageFileName: standalone.fileName, pixelSize: nil
                    )
                    try addEntry(
                        to: archive, path: "OEBPS/\(textDirectory)/\(standaloneCoverXHTMLFileName)",
                        data: Data(coverXHTML.utf8), compressed: true
                    )
                }
            }
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
        case .zip(_, let entryPath), .sevenZip(_, let entryPath), .rar(_, let entryPath):
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

    // MARK: - XML生成

    private static func xmlEscape(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        return result
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
        coverGuideHref: String?
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
                "    <item id=\"\(itemID)\" href=\"\(textDirectory)/\(page.xhtmlFileName)\" media-type=\"application/xhtml+xml\"/>"
            )
            manifestLines.append(
                "    <item id=\"\(imageID)\" href=\"\(imagesDirectory)/\(page.imageFileName)\" "
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
                    "    <item id=\"\(id)\" href=\"\(imagesDirectory)/\(standalone.fileName)\" "
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
          <img src="../\(imagesDirectory)/\(imageFileName)" alt=""/>
        </body>
        </html>
        """
    }
}

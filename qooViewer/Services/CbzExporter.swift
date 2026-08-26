import Foundation
import ZIPFoundation

/// CBZ書き出しのオプション。
struct CbzExportOptions {
    /// 画像ファイルの連番リネーム。**CBZでは既定ON**(CbzExportViewModelのinit参照)。
    ///
    /// CBZには読み順を表すメタデータが存在せず、どのリーダーもアーカイブ内のファイル名の
    /// 並び順だけでページ順を決める。そのためqooViewerでページを並べ替えたり除外したりして
    /// いる本は、連番へ振り直さない限り、書き出した先で元のファイル名順に戻ってしまう
    /// (spineが読み順を持つEPUBとは事情が異なる)。
    var renumberImagesSequentially: Bool
    /// 除外(非表示)ページを含めるか。false(既定)なら除外ページはCBZに含めない。
    var includeExcludedPages: Bool
    /// ComicInfo.xmlの`Volume`要素にも巻数を書き出すか(既定OFF)。
    ///
    /// Kavitaは`Volume`を「巻」として扱うためONにすると表示が正確になるが、Komgaは
    /// `Volume`をシリーズ名へ`<Series> (<Volume>)`の形で連結するため、巻ごとに別シリーズへ
    /// 分裂しうる(ComicInfo.volumeのコメント参照)。どちらのサーバーを使うかで正解が
    /// 変わるので、ユーザーが選べるようにしてある。
    var writesVolumeElement: Bool
}

/// 1冊分のCBZ書き出しに必要な材料。EpubExportInputのCBZ版。
struct CbzExportInput {
    /// BookLoaderで読み込んだ、並べ替え前・除外前の生のMangaBook。
    let book: MangaBook
    let pageOrderOverride: [String]?
    /// pageKey(PageRef.sortKey) -> レイアウト状態。除外の判定と、ComicInfoの
    /// `Page@DoublePage`(「単一ページ」指定のページ)の両方に使う。
    let pageOverrides: [String: PageLayoutState]
    /// ComicInfoの`Manga`要素の決定に使う。右開きなら`YesAndRightToLeft`。
    let readingDirection: ReadingDirection
    let bookmarks: [ExportBookmark]
    let coverOverride: ExportCoverOverride?
    /// 空文字/nilの場合はbook.title(元のファイル/フォルダ名相当)をそのまま使う。
    let titleOverride: String?
    /// 空文字/nilの場合は`Writer`/`Penciller`を出力しない。
    let author: String?
    /// メタデータDBに登録されているシリーズ名。空の場合はタイトルを`Series`に入れる
    /// (Kavitaはシリーズ名を重視するため、単巻の本でも1つのシリーズとして認識させたい)。
    let series: String?
    /// 巻数。**EPUB/PDFと違い、数値へ変換せず生の文字列のまま渡してよい** —
    /// ComicInfoの`Number`はxs:stringで、「上」「下」のような値もそのまま書けるため。
    let seriesIndex: String?
    /// `LanguageISO`に書き出すBCP 47の言語タグ。空文字/nilなら要素自体を出力しない。
    let language: String?
}

enum CbzExportError: LocalizedError {
    /// 除外設定・空のページ一覧などにより、書き出せるページが1枚も無かった。
    case noEligiblePages
    /// あるページの画像データを読み出せなかった(書庫が壊れている、PDFを開けない等)。
    ///
    /// 黙ってそのページを飛ばすことはしない。ComicInfo.xmlの`<Pages>`とPageCountは
    /// 実際に書き込んだ枚数と一致している必要があり、途中で欠けると、ページ番号を根拠に
    /// しているブックマーク(Page@Bookmark)がすべて1つずつずれるため。
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
                format: String(localized: "Couldn't write the CBZ file: %@"),
                underlying.localizedDescription
            )
        }
    }
}

/// フォルダ・zip/cbz・rar/cbr・7z/cb7・PDF・EPUBから読み込んだMangaBookを、ページ画像を
/// そのまま格納したzip(=CBZ)として書き出し、DB上の書誌メタデータ・ブックマーク・
/// レイアウトをルート直下の`ComicInfo.xml`として同梱する。
///
/// 設計上の要点:
/// - **画像は再エンコードしない。** 元のバイト列をそのままzipへ入れる(EpubExporterと同じ方針)。
///   CBZにはEPUBのような「コア画像形式」の制約が無いため、EPUBで必要だったPNGへの変換
///   (WebP/HEIC/AVIF等)も行わない — 変換すると可逆でもファイルサイズが数倍に膨らむうえ、
///   Komga/Kavita/YACReaderはいずれもこれらの形式を扱えるため、変換は害のほうが大きい。
/// - **既に圧縮されている画像形式は無圧縮(格納)でzipへ入れる。** JPEG/PNG等をdeflateしても
///   数%も縮まらず、ページ数ぶんのCPU時間だけが積み上がるため(alreadyCompressedExtensions参照)。
/// - **元ファイルにComicInfo.xmlがあれば引き継ぐ。** qooViewerが管理しない項目(出版社・
///   あらすじ・発行年・ジャンルなど)を、書き出しのたびに失わないようにする。
///
/// nonisolated: BookLoader/EpubExporterと同じくメインスレッド外から呼ばれるため、
/// Xcode 26既定のMainActor自動分離の対象外にしている。
nonisolated enum CbzExporter {
    /// zipへ入れる前に改めてdeflateしても、ほぼ縮まらない(既に圧縮済みの)画像形式。
    /// これらは圧縮方式`.none`(格納)で入れる。
    private static let alreadyCompressedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "jp2"
    ]

    /// zipへ書き込む1エントリぶんの計画。ファイル名(=読み順)を先に全部確定させてから
    /// 書き込みループへ入るのは、EpubExporterがmanifestを先に組み立てるのと同じ理由:
    /// 途中で「このページは読めなかった」と分かってから引き返せる作りにしないと、
    /// 中途半端なファイルが出力先に残る。
    private struct PlannedEntry {
        /// 元のPageRef.sortKey。本に含まれない専用カバーファイルの場合はnil。
        let pageKey: String?
        /// 画像データの取得元。
        let source: ImageSource
        let fileName: String
        /// ComicInfoの`Page@Type="FrontCover"`を付けるページかどうか。
        let isFrontCover: Bool
        /// ComicInfoの`Page@DoublePage`の判定に使う、DB上のレイアウト状態。
        let layoutState: PageLayoutState?

        enum ImageSource {
            /// input.book.pagesのインデックス(PageLoaderは元の並びのままbookを保持している)。
            case page(originalIndex: Int)
            /// 本に含まれない専用カバーファイルの、既に読み込み済みのバイト列。
            case rawData(Data)
        }
    }

    static func export(_ input: CbzExportInput, options: CbzExportOptions, to destinationURL: URL) async throws {
        let excludedKeys: Set<String> = options.includeExcludedPages
            ? []
            : Set(input.pageOverrides.filter { $0.value == .excluded }.map(\.key))
        let orderedPages = EffectivePageOrder.orderedPages(
            for: input.book, pageOrderOverride: input.pageOrderOverride, excludedKeys: excludedKeys
        )
        guard !orderedPages.isEmpty else { throw CbzExportError.noEligiblePages }

        // pageKey -> 元のbook.pagesのインデックス(EpubExporter.exportの同名の変数と同じ役割)。
        var originalIndexByKey: [String: Int] = [:]
        for (index, page) in input.book.pages.enumerated() { originalIndexByKey[page.sortKey] = index }

        let pageLoader = PageLoader(book: input.book)
        let planned = try await planEntries(
            input: input, options: options, orderedPages: orderedPages,
            originalIndexByKey: originalIndexByKey, pageLoader: pageLoader
        )

        // 元ファイルが既にComicInfo.xmlを持っているなら、それを土台にする(型コメント参照)。
        // 持っていない・読めない場合は空のComicInfoから始める。
        //
        // 書庫の場合は、上で作ったpageLoaderが既に開いているReaderをそのまま使う
        // (同じ書庫を開き直さずに済ませるため。詳細はPageLoader.sourceComicInfo参照)。
        var comicInfo = await pageLoader.sourceComicInfo(bookSourceURL: input.book.sourceURL) ?? ComicInfo()

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            let archive = try Archive(url: destinationURL, accessMode: .create)

            // ComicInfoの`Page@Image`は「アーカイブ内の画像を名前順に並べたときの位置」を
            // 指す(0始まり)。書き込んだ順ではない。
            //
            // 連番リネームがONなら両者は一致するが、OFFのときは元のファイル名をそのまま使う
            // ため、qooViewerの並べ替えを反映した書き込み順と、リーダーが見る名前順とが
            // 食い違いうる。書き込み順のまま番号を振ると、カバー指定(FrontCover)や
            // ブックマークがすべて別のページに付いてしまうため、ここで名前順の位置へ
            // 変換してから番号を振る。
            //
            // 比較にoptions: .numericを使うのは、BookLoaderが本のページを並べるときと同じ
            // 自然順(数字を数値として比較する)に揃えるため。
            let readerOrder = planned.indices.sorted {
                planned[$0].fileName.compare(planned[$1].fileName, options: .numeric) == .orderedAscending
            }
            var imageIndexByPlannedIndex = [Int](repeating: 0, count: planned.count)
            for (imageIndex, plannedIndex) in readerOrder.enumerated() {
                imageIndexByPlannedIndex[plannedIndex] = imageIndex
            }

            // 画像を1ページぶんずつ「取得 → 寸法を算出 → 書き込み → 破棄」する
            // (全ページの生データを同時にメモリへ載せないため。EpubExporterと同じ方針)。
            // ComicInfoの<Pages>には各ページの実寸とバイト数が要るので、ここで集めておき、
            // ComicInfo.xml自体はこのループの後で書き出す(寸法を得るためだけに画像を
            // もう一度読み直すのは、ページ数の多い本では無駄が大きい)。zip内のエントリ順に
            // 仕様上の制約は無く、ComicInfo.xmlが末尾にあってもリーダーは名前で引くだけなので
            // 問題にならない。
            var comicInfoPages = [ComicInfoPage?](repeating: nil, count: planned.count)
            for (outputIndex, entry) in planned.enumerated() {
                let imageData: Data
                switch entry.source {
                case .rawData(let data):
                    imageData = data
                case .page(let originalIndex):
                    guard let exportable = try await pageLoader.exportableImage(at: originalIndex) else {
                        throw CbzExportError.pageImageUnavailable(
                            pageName: input.book.pages[originalIndex]
                                .location(inBookAt: input.book.sourceURL).fullPath
                        )
                    }
                    imageData = exportable.data
                }

                try addEntry(to: archive, path: entry.fileName, data: imageData, compressed: shouldCompress(entry.fileName))

                var page = ComicInfoPage(image: imageIndexByPlannedIndex[outputIndex])
                if entry.isFrontCover {
                    page.type = .frontCover
                }
                // 「単一ページ」指定 = 見開き表示中でも単独で表示するページ、つまり実質的に
                // 横長の見開き合成画像。ComicInfoのDoublePage(「1枚に2ページ分入っている」)
                // が表しているのはまさにこれなので、そこへ写す(ComicInfoPage.doublePage参照)。
                // falseは既定値のため、trueのときだけ属性を出す。
                if entry.layoutState == .single {
                    page.doublePage = true
                }
                page.imageSize = Int64(imageData.count)
                if let pixelSize = ImageDecoder.pixelSize(of: imageData) {
                    page.imageWidth = pixelSize.width
                    page.imageHeight = pixelSize.height
                }
                comicInfoPages[page.image] = page
            }

            // ブックマーク(元のpageKey)→ ComicInfo上のページ番号。
            var imageIndexByPageKey: [String: Int] = [:]
            for (outputIndex, entry) in planned.enumerated() {
                // 合成カバーが本文ページと同じpageKeyを指すことは無い(planEntriesで
                // 実際の本文ページに含まれないページだけを合成カバーにしているため)。
                if let pageKey = entry.pageKey, imageIndexByPageKey[pageKey] == nil {
                    imageIndexByPageKey[pageKey] = imageIndexByPlannedIndex[outputIndex]
                }
            }
            for bookmark in input.bookmarks {
                guard let imageIndex = imageIndexByPageKey[bookmark.pageKey],
                      comicInfoPages.indices.contains(imageIndex)
                else { continue }
                comicInfoPages[imageIndex]?.bookmark = bookmark.name
            }

            // 全要素が必ず埋まる(imageIndexByPlannedIndexは0..<countの並べ替えのため)ので、
            // compactMapで落ちる要素は無い。
            applyMetadata(to: &comicInfo, input: input, options: options, pages: comicInfoPages.compactMap { $0 })
            if !comicInfo.isEmpty {
                try addEntry(
                    to: archive, path: ComicInfoXML.fileName,
                    data: Data(ComicInfoXML.makeDocument(comicInfo).utf8), compressed: true
                )
            }
        } catch let error as CbzExportError {
            throw error
        } catch {
            throw CbzExportError.writeFailed(underlying: error)
        }
    }

    // MARK: - 書き出す順序とファイル名の決定

    /// カバー(必要なら)＋本文ページを、実際にzipへ書く順序で並べ、ファイル名まで確定させる。
    private static func planEntries(
        input: CbzExportInput, options: CbzExportOptions, orderedPages: [PageRef],
        originalIndexByKey: [String: Int], pageLoader: PageLoader
    ) async throws -> [PlannedEntry] {
        // 元がPDFの本は、ページに「元のファイル名」という単位が無いため、連番リネームの
        // 設定に関わらず常にページ順の6桁連番にする(EpubExporterと同じ扱い)。
        let isPDFSource = orderedPages.first.map { if case .pdf = $0.source { true } else { false } } ?? false

        // 本文ページとは別に先頭へ差し込むカバー(本に含まれない専用ファイル、または除外設定に
        // より本文に含まれない既存ページを選んだ場合)。CBZではzipに入れた画像がそのまま
        // 1ページになるため、EPUBのように「読書対象ではないカバー」を持つことはできず、
        // ページ数が1増える形になる。
        let standaloneCover = await resolveStandaloneCover(
            input: input, orderedPages: orderedPages, originalIndexByKey: originalIndexByKey,
            pageLoader: pageLoader
        )

        // 本文ページのうち、どれをカバー(Type="FrontCover")として印を付けるか。
        // 専用カバーを差し込む場合は、そちらが唯一のカバーになる。
        let coverPageKey: String? = {
            guard standaloneCover == nil else { return nil }
            if case .existingPage(let pageKey) = input.coverOverride,
               orderedPages.contains(where: { $0.sortKey == pageKey }) {
                return pageKey
            }
            // 上書き指定が無い(または解決できない)場合は、実質的な先頭ページをカバーにする。
            return orderedPages.first?.sortKey
        }()

        let totalCount = orderedPages.count + (standaloneCover == nil ? 0 : 1)
        let digitWidth = max(String(totalCount).count, 1)
        var usedFileNames: Set<String> = []
        var planned: [PlannedEntry] = []

        /// 出力順に応じたファイル名を決める。連番リネームがOFFのときだけ元の名前を活かす。
        func fileName(sequenceIndex: Int, baseName: String, extension ext: String) -> String {
            if isPDFSource {
                return String(format: "%06d.%@", sequenceIndex + 1, ext)
            }
            if options.renumberImagesSequentially {
                return String(format: "%0\(digitWidth)d.%@", sequenceIndex, ext)
            }
            return uniqueFileName(basedOn: baseName, extension: ext, used: &usedFileNames)
        }

        if let standaloneCover {
            // 連番リネームがOFFのときは、カバーが確実に先頭へ並ぶ名前を保証できない
            // (元の名前を活かす以上、既存ページの名前との大小関係は本ごとに変わる)。
            // 記号"!"はASCIIで数字・英字より小さく、実用上ほぼ確実に先頭へ来るため
            // これを使う。順序を確実にしたい場合は連番リネーム(既定ON)を使ってもらう。
            let name = options.renumberImagesSequentially || isPDFSource
                ? fileName(sequenceIndex: 0, baseName: "cover", extension: standaloneCover.fileExtension)
                : "!cover.\(standaloneCover.fileExtension)"
            usedFileNames.insert(name)
            planned.append(
                PlannedEntry(
                    pageKey: nil, source: .rawData(standaloneCover.data), fileName: name,
                    isFrontCover: true, layoutState: nil
                )
            )
        }

        for page in orderedPages {
            // 拡張子は、PDFの場合だけ実際に埋め込まれている画像の形式から決まるため
            // PageLoaderに問い合わせる。読み出せないページがあればここでエラーになり、
            // 書き出し先を作る前に中断できる(EpubExporterと同じ理由)。
            guard let originalIndex = originalIndexByKey[page.sortKey] else {
                throw CbzExportError.pageImageUnavailable(
                    pageName: page.location(inBookAt: input.book.sourceURL).fullPath
                )
            }
            let ext = try await pageLoader.exportableImageFileExtension(at: originalIndex)
            let name = fileName(
                sequenceIndex: planned.count, baseName: originalBaseName(for: page), extension: ext
            )
            if options.renumberImagesSequentially || isPDFSource {
                usedFileNames.insert(name)
            }
            planned.append(
                PlannedEntry(
                    pageKey: page.sortKey, source: .page(originalIndex: originalIndex), fileName: name,
                    isFrontCover: page.sortKey == coverPageKey,
                    layoutState: input.pageOverrides[page.sortKey]
                )
            )
        }
        return planned
    }

    /// 本文ページとは別に先頭へ差し込む必要があるカバー画像。差し込む必要が無ければnil。
    private static func resolveStandaloneCover(
        input: CbzExportInput, orderedPages: [PageRef], originalIndexByKey: [String: Int], pageLoader: PageLoader
    ) async -> (data: Data, fileExtension: String)? {
        switch input.coverOverride {
        case .externalFile(let data, let ext):
            return (data, normalizedExtension(ext))
        case .existingPage(let pageKey):
            // 本文に含まれているページなら、差し込まずにそのページへ印を付けるだけでよい。
            guard !orderedPages.contains(where: { $0.sortKey == pageKey }) else { return nil }
            // 除外設定により本文から外れているページをカバーに選んだ場合(ユーザー要望を
            // 汲んだ挙動)。画像を取り出して先頭へ差し込む。取り出せなければカバー指定だけを
            // 諦め、本の書き出し自体は続ける。
            guard let originalIndex = originalIndexByKey[pageKey],
                  let exportable = try? await pageLoader.exportableImage(at: originalIndex)
            else { return nil }
            return (exportable.data, normalizedExtension(exportable.fileExtension))
        case nil:
            return nil
        }
    }

    private static func normalizedExtension(_ ext: String) -> String {
        let lowered = ext.lowercased()
        return lowered.isEmpty ? "jpg" : lowered
    }

    private static func originalBaseName(for page: PageRef) -> String {
        switch page.source {
        case .file(let url):
            return url.deletingPathExtension().lastPathComponent
        case .archive(_, let entryPath):
            return ((entryPath as NSString).lastPathComponent as NSString).deletingPathExtension
        case .pdf:
            // 元がPDFの本は常時6桁連番の経路になる(planEntriesのisPDFSource参照)ため到達しない。
            return "page"
        }
    }

    /// 連番リネームがOFFの場合、元のファイル名をできるだけそのまま使うが、異なるサブフォルダに
    /// 同名ファイルがあった場合の衝突を避けるため、必要なら"-2"のような連番を付けて一意にする
    /// (EpubExporterの同名メソッドと同じ)。
    ///
    /// CBZではzip内をフラットに並べる(サブフォルダを作らない)。サブフォルダがあっても
    /// たいていのリーダーはパス全体で並べ替えるだけなので読めるが、フラットにしておくほうが
    /// ページ順の解釈がリーダー間でぶれない。
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

    // MARK: - ComicInfo.xmlの組み立て

    /// 元ファイルから引き継いだComicInfo(または空のComicInfo)へ、qooViewerが管理している
    /// 情報を上書きする。**qooViewerが値を持たない項目には触れない** — 引き継いだ内容を
    /// 消さないため(型コメント参照)。
    private static func applyMetadata(
        to info: inout ComicInfo, input: CbzExportInput, options: CbzExportOptions, pages: [ComicInfoPage]
    ) {
        let title = trimmedOrNil(input.titleOverride) ?? input.book.title
        info.title = title
        // シリーズ名が未登録の本では、タイトルをそのままSeriesにも入れる(ユーザー選択)。
        // Komgaはフォルダからシリーズを決めるためSeriesが空でも困らないが、Kavitaは
        // ファイル名のパースに戻ってしまうため、単巻の本が意図せず分裂することがある。
        info.series = trimmedOrNil(input.series) ?? title

        // 巻数。ComicInfoのNumberはxs:stringのため、「上」「下」のような値もそのまま書ける
        // (EPUBのgroup-positionやPDFのcalibreSI:series_indexと違い、数値へ丸める必要が無い)。
        if let seriesIndex = trimmedOrNil(input.seriesIndex) {
            info.number = seriesIndex
            // Volumeはxs:intのため、整数として解釈できる場合だけ書ける。
            if options.writesVolumeElement, let volume = Int(seriesIndex) {
                info.volume = volume
            }
        }

        // 著者は原作(Writer)と作画(Penciller)の両方へ入れる(ユーザー選択)。日本の漫画は
        // 同一人物であることが多く、Komga/Kavitaはどちらも役割ごとに著者を表示するため、
        // 片方だけだと「作画者不明」のように見えてしまう。
        if let author = trimmedOrNil(input.author) {
            info.writer = author
            info.penciller = author
        }

        info.pageCount = pages.count
        // 言語は、本の内容ではなくアプリの表示言語設定から決めた推定値にすぎない
        // (BookExportViewModel.exportLanguageCode参照)。元ファイルに明示的な値が書かれて
        // いた場合はそちらのほうが確かなので、空のときだけ埋める。
        if info.languageISO.isEmpty, let language = trimmedOrNil(input.language) {
            info.languageISO = language
        }
        // 右開きを表せるのはYesAndRightToLeftだけ(ComicInfoMangaのコメント参照)。
        if input.readingDirection == .rightToLeft {
            info.manga = .yesAndRightToLeft
        } else if info.manga == nil || info.manga == .unknown || info.manga == .yesAndRightToLeft {
            // 左開き。Yesは「漫画である」という意味しか持たず方向は未指定だが、読み手は既定の
            // 左開きで開くため結果として正しく表示される。
            // 元ファイルがNo(西洋コミックである、という明示)だった場合だけは触らない —
            // qooViewer側の読み方向は「左開き」としか言っておらず、Noという申告を
            // Yesへ書き換えるだけの根拠が無いため。
            info.manga = .yes
        }
        // ページ構成そのものが変わっている(並べ替え・除外・カバーの差し込み)ため、
        // 引き継いだ<Pages>は必ず作り直したもので置き換える。
        info.pages = pages
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - ZIPFoundationへの書き込み

    /// 既に圧縮済みの画像形式は格納(無圧縮)、それ以外(BMP/TIFFなど)とComicInfo.xmlは
    /// deflateする(型コメント参照)。
    private static func shouldCompress(_ fileName: String) -> Bool {
        !alreadyCompressedExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

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
}

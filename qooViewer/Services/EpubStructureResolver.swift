import Foundation

/// EPUB(固定レイアウトのコミック向けEPUBを主な対象とする)の内部構造を解決した結果。
/// container.xml → package document(OPF)のmanifest/spineをたどり、実際にページとして
/// 表示すべき画像ファイルを正しい読み順で並べたもの。
struct EpubStructure {
    /// 読み順に並んだページ(アーカイブ内の画像エントリパスと、見開き配置の指定)
    let pages: [EpubPageEntry]
    /// spine要素のpage-progression-direction属性から得た読み方向(未指定ならnil)
    let pageProgressionDirection: ReadingDirection?
    /// package document metadataのrendition:spreadから得た、本全体での見開き強制
    /// (未指定/強制対象外の値ならnil。詳細はMangaBook.swiftのSourceLayoutHintのコメント参照)
    let forcedDisplayMode: DisplayMode?
}

struct EpubPageEntry {
    /// アーカイブ(zipコンテナとしてのEPUB自体)内の画像ファイルのパス
    let entryPath: String
    let spreadPosition: PageSpreadPosition?
    /// このページに対応するspine項目自体(manifest item)が指すパス。通常は画像を包む
    /// XHTMLラッパーのパスで、entryPathとは異なる(media-typeが画像そのものの場合はentryPathと
    /// 同じ値になる)。目次(nav.xhtml)のリンク先とページを対応付けるために使う
    /// (7.5節「逆方向」、resolveTableOfContents参照)。
    let sourceHref: String
}

/// EPUBの目次(nav.xhtml)から読み取った1項目。設計コンセプト7.5節「逆方向」
/// (目次があり、その本にまだブックマークが1件も無い場合に自動でブックマークとして取り込む)で使う。
/// EPUB3のnav.xhtmlのみに対応し、EPUB2のtoc.ncxへのフォールバックは行わない
/// (未対応であることを明示。13節の未確定事項の一つとして扱う)。
struct EpubTOCEntry {
    let title: String
    /// EpubStructure.pagesのインデックス(=BookLoader.loadEpubが作るMangaBook.pagesのインデックスと
    /// 同じ空間。EPUBはPageLayoutOverrideの対象外のため、この2つの配列の並びは常に一致する)。
    let pageIndex: Int
}

/// EPUB/PDFのファイル自身が持つ書誌メタデータ(タイトル・著者・シリーズ・巻数)。
///
/// ユーザー要望: ファイルを初めて開いたとき、ファイルに埋め込まれているメタデータを読み込んで
/// DBに登録し、以降の表示はDB側に従う(ファイル側の情報はDBの初期値としてのみ扱う)。
/// EpubStructureResolver.resolveMetadata / PDFStructureResolver.resolveMetadataが返す。
///
/// 各項目は「ファイルに書かれていなければ空文字」。すべてが空の場合、呼び出し側は
/// 「取り込むものが無かった」として何も登録しない(BookMetadataStore.upsertは、4項目すべてが
/// 空の内容での登録を行として作らない)。
nonisolated struct SourceBookMetadata: Equatable, Sendable {
    var title: String = ""
    var author: String = ""
    var series: String = ""
    /// 巻数。数値として解釈できる文字列(Calibreのseries_indexは"3.0"のような小数もありうる)。
    var seriesIndex: String = ""

    var isEmpty: Bool {
        title.isEmpty && author.isEmpty && series.isEmpty && seriesIndex.isEmpty
    }
}

enum EpubStructureError: Error {
    /// META-INF/container.xmlが読めない、またはrootfileが見つからない
    case containerNotReadable
    /// package document(OPF)が読めない、またはspineが解釈できない(空も含む)
    case packageDocumentNotReadable
}

/// EPUBの内部構造(container.xml・package document・spine)を解決するための処理をまとめたもの。
/// zipコンテナとしての読み出し自体はArchiveReading(実体はZipArchiveReader)に委譲し、
/// ここではEPUB固有のXML構造の解釈だけを担当する。
///
/// 対象を「固定レイアウトの画像ベースのコミックEPUB」に絞っているため、リフロー型
/// (文章主体)のEPUBの本文レンダリングは行わない。各spine項目からちょうど1枚の画像を
/// 特定できるページだけをページとして採用し、画像を特定できない項目は読み飛ばす
/// (詳細はresolveImagePath参照)。1枚も画像が見つからなければ、呼び出し元(BookLoader)が
/// 「絵本形式のEPUBではない」と判断してエラーにする。
///
/// nonisolated: PageLoader/BookLoaderと同じくメインスレッド外(Task.detached)から呼ばれるため、
/// Xcode 26既定のMainActor自動分離の対象外にしている(詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated enum EpubStructureResolver {
    private static let containerPath = "META-INF/container.xml"

    /// EPUB内部のマークアップ(container.xml・package document(OPF)・nav.xhtml・各ページの
    /// XHTMLラッパー)を読むときの、展開後バイト数の上限(8MB)。
    ///
    /// これらは正常なEPUBでは数KBに収まる。上限を設けているのは、zipコンテナとしてのEPUBの
    /// 中身が信用できない入力だからである。XMLはよく圧縮が効くため、小さな圧縮エントリが
    /// 展開すると数GBになる(いわゆる解凍爆弾)。それをそのままメモリへ載せると、EPUBを
    /// 開いて構造を解決するだけでアプリを落とせる(ComicInfoResolver.maxByteCountと同じ考え方)。
    /// zipでは伸長そのものを途中で打ち切れる(ArchiveReading.dataPrefix参照)ため、上限を
    /// 超える細工エントリは途中で切り詰められ、XMLとして壊れて解析に失敗する=「読めない」
    /// のと同じ扱いになる(正常なファイルがこの大きさに達することはない)。
    private static let maxMarkupByteCount = 8 * 1024 * 1024

    /// EPUB内部のマークアップを、解凍爆弾よけの上限つきで読む(maxMarkupByteCountのコメント参照)。
    private static func markupData(reader: ArchiveReading, at path: String) throws -> Data {
        try reader.dataPrefix(at: path, maxByteCount: maxMarkupByteCount)
    }

    static func resolve(reader: ArchiveReading) throws -> EpubStructure {
        let opfPath = try resolveOPFPath(reader: reader)
        let opfData = try markupData(reader: reader, at: opfPath)
        let packageDocument = try parsePackageDocument(data: opfData)

        let opfDirectory = directory(of: opfPath)
        let allPaths = Set(try reader.listFilePaths())

        var pages: [EpubPageEntry] = []
        for itemRef in packageDocument.spineItemRefs {
            guard let manifestItem = packageDocument.manifestItems[itemRef.idref] else { continue }
            guard let entryPath = resolveImagePath(
                for: manifestItem,
                baseDirectory: opfDirectory,
                reader: reader,
                allPaths: allPaths
            ) else { continue }

            let itemPath = resolvedPath(base: opfDirectory, relative: manifestItem.href)
            let sourceHref = matchExistingPath(itemPath, in: allPaths) ?? itemPath
            pages.append(
                EpubPageEntry(
                    entryPath: entryPath, spreadPosition: spreadPosition(from: itemRef.properties), sourceHref: sourceHref
                )
            )
        }

        return EpubStructure(
            pages: pages,
            pageProgressionDirection: readingDirection(from: packageDocument.pageProgressionDirection),
            forcedDisplayMode: displayMode(from: packageDocument.renditionSpread)
        )
    }

    // MARK: - container.xml

    private static func resolveOPFPath(reader: ArchiveReading) throws -> String {
        guard let data = try? markupData(reader: reader, at: containerPath) else {
            throw EpubStructureError.containerNotReadable
        }
        let delegate = ContainerDocumentParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let opfPath = delegate.opfPath, !opfPath.isEmpty else {
            throw EpubStructureError.containerNotReadable
        }
        return opfPath
    }

    // MARK: - package document (OPF)

    private static func parsePackageDocument(data: Data) throws -> PackageDocumentParserDelegate {
        let delegate = PackageDocumentParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.spineItemRefs.isEmpty else {
            throw EpubStructureError.packageDocumentNotReadable
        }
        return delegate
    }

    // MARK: - 各spine項目 → 実際の画像パスの解決

    /// manifest上の1項目(spineから参照されている)から、実際に表示する画像のエントリパスを求める。
    /// - 画像そのもの(media-typeがimage/*)ならそのパスをそのまま使う。
    /// - XHTML/HTMLなら、その文書の中身から最初の<img>/<image>参照を1つだけ取り出し、
    ///   その文書自身の場所を基準に相対パスを解決する(固定レイアウトのコミックEPUBは、
    ///   1ページ=1つのXHTML+1枚の画像という構成がほとんどのため、これで十分カバーできる)。
    /// - media-typeが省略されている(一部の簡易な生成ツールで見られる)場合は、拡張子から
    ///   画像かXHTML/HTMLかを推測するフォールバックを行う。
    /// - どの方法でも画像が見つからない場合はnil(そのspine項目はページとして採用しない)。
    private static func resolveImagePath(
        for manifestItem: PackageDocumentParserDelegate.ManifestItem,
        baseDirectory: String,
        reader: ArchiveReading,
        allPaths: Set<String>
    ) -> String? {
        let itemPath = resolvedPath(base: baseDirectory, relative: manifestItem.href)
        let mediaType = manifestItem.mediaType

        let looksLikeImage = mediaType.hasPrefix("image/")
            || (mediaType.isEmpty && isImageFile(manifestItem.href))
        if looksLikeImage {
            return matchExistingPath(itemPath, in: allPaths)
        }

        let looksLikeMarkup = mediaType.contains("html") || mediaType.contains("xml")
            || (mediaType.isEmpty && looksLikeMarkupExtension(manifestItem.href))
        guard looksLikeMarkup else { return nil }

        guard let resolvedItemPath = matchExistingPath(itemPath, in: allPaths),
              let contentData = try? markupData(reader: reader, at: resolvedItemPath) else {
            return nil
        }

        guard let imageHref = firstImageReference(in: contentData) else { return nil }
        let contentDirectory = directory(of: resolvedItemPath)
        let imagePath = resolvedPath(base: contentDirectory, relative: imageHref)
        return matchExistingPath(imagePath, in: allPaths)
    }

    private static func looksLikeMarkupExtension(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "xhtml" || ext == "html" || ext == "htm" || ext == "xml"
    }

    /// XHTML/HTMLの中身から、最初の<img src="...">、またはSVGの<image xlink:href="...">/
    /// <image href="...">を1つだけ取り出す。
    /// 一部のEPUB生成ツールは厳密なXHTMLとして解釈できない(閉じタグ漏れ等の)HTMLを出力する
    /// ことがあるため、まずXMLParserで試み、失敗した場合は正規表現によるゆるい抽出にフォールバック
    /// する(ZipArchiveReaderの文字コード自動判定と同じく、実用上のロバストさを優先する方針)。
    private static func firstImageReference(in data: Data) -> String? {
        let delegate = FirstImageReferenceParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        if parser.parse(), let href = delegate.imageHref {
            return href
        }
        return firstImageReferenceUsingRegex(in: data)
    }

    private static func firstImageReferenceUsingRegex(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        let patterns = [
            #"<img[^>]+src=["']([^"']+)["']"#,
            #"<image[^>]+(?:xlink:href|href)=["']([^"']+)["']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let hrefRange = Range(match.range(at: 1), in: text) {
                return String(text[hrefRange])
            }
        }
        return nil
    }

    // MARK: - spine itemrefのproperties → PageSpreadPosition

    private static func spreadPosition(from properties: Set<String>) -> PageSpreadPosition? {
        if properties.contains("page-spread-left") { return .left }
        if properties.contains("page-spread-right") { return .right }
        if properties.contains("rendition:page-spread-center") { return .center }
        return nil
    }

    // MARK: - package document metadata → 読み方向/見開き強制

    private static func readingDirection(from rawValue: String?) -> ReadingDirection? {
        switch rawValue?.lowercased() {
        case "rtl": return .rightToLeft
        case "ltr": return .leftToRight
        default: return nil
        }
    }

    /// rendition:spreadは none/both/landscape/portrait/auto の5値を取り得るが、macOSの
    /// ウインドウ表示には「端末の向き」という概念が無いため、noneとbothだけを強制値として扱う
    /// (詳細はMangaBook.swiftのSourceLayoutHintのコメント参照)。
    private static func displayMode(from rawValue: String?) -> DisplayMode? {
        switch rawValue?.lowercased() {
        case "none": return .single
        case "both": return .spread
        default: return nil
        }
    }

    // MARK: - package document metadata → 書誌メタデータ

    /// package document(OPF)のmetadataから、タイトル・著者・シリーズ名・巻数を読み取る。
    /// 本を初めて開いたときにDBへ取り込むために使う(ユーザー要望)。
    ///
    /// シリーズ情報の出どころは2種類あり、両方が書かれている場合はCalibre側を優先する
    /// (ユーザー指定)。Calibreで管理している本はCalibre側の値が最新である可能性が高く、
    /// EPUB3形式のほうは書き出し時に生成されたまま古くなっていることがあるため。
    ///
    /// - Calibre独自の拡張メタデータ: `<meta name="calibre:series" content="シリーズ名"/>` と
    ///   `<meta name="calibre:series_index" content="3.0"/>`(EPUB2形式のname/content属性)。
    /// - EPUB3の標準形式: `<meta property="belongs-to-collection" id="c1">シリーズ名</meta>` に、
    ///   `<meta refines="#c1" property="collection-type">series</meta>` と
    ///   `<meta refines="#c1" property="group-position">3</meta>` がid経由で紐づく。
    ///
    /// EPUB3側では、collection-typeが`series`のものを優先して採用する。ただしcollection-typeを
    /// 省略しているファイルも実在するため、`series`が1つも見つからない場合は、typeの無い
    /// belongs-to-collectionを次善の候補として採用する(`set`など明示的に別の種類だと
    /// 書かれているものだけを除外する)。
    static func resolveMetadata(reader: ArchiveReading) -> SourceBookMetadata {
        guard let opfPath = try? resolveOPFPath(reader: reader),
              let opfData = try? markupData(reader: reader, at: opfPath),
              let packageDocument = try? parsePackageDocument(data: opfData)
        else { return SourceBookMetadata() }

        var metadata = SourceBookMetadata()
        metadata.title = packageDocument.dcTitle ?? ""
        metadata.author = packageDocument.dcCreator ?? ""

        if let calibreSeries = packageDocument.metaByName["calibre:series"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !calibreSeries.isEmpty {
            metadata.series = calibreSeries
            metadata.seriesIndex = normalizedSeriesIndex(packageDocument.metaByName["calibre:series_index"])
            return metadata
        }

        guard let collection = preferredCollection(in: packageDocument) else { return metadata }
        metadata.series = collection.text
        let position = packageDocument.propertyMetas.first {
            $0.property == "group-position" && $0.refines != nil && $0.refines == collection.id
        }
        metadata.seriesIndex = normalizedSeriesIndex(position?.text)
        return metadata
    }

    /// belongs-to-collectionのうち、シリーズとして採用すべきものを1つ選ぶ
    /// (collection-typeが"series"のものを優先し、無ければtype未指定のものを使う)。
    private static func preferredCollection(
        in packageDocument: PackageDocumentParserDelegate
    ) -> PackageDocumentParserDelegate.PropertyMeta? {
        let collections = packageDocument.propertyMetas.filter {
            $0.property == "belongs-to-collection" && !$0.text.isEmpty
        }
        guard !collections.isEmpty else { return nil }

        /// このcollectionに紐づくcollection-typeの値(未指定ならnil)。
        func collectionType(of collection: PackageDocumentParserDelegate.PropertyMeta) -> String? {
            guard let id = collection.id else { return nil }
            return packageDocument.propertyMetas.first {
                $0.property == "collection-type" && $0.refines == id
            }?.text.lowercased()
        }

        if let series = collections.first(where: { collectionType(of: $0) == "series" }) {
            return series
        }
        return collections.first { collectionType(of: $0) == nil }
    }

    /// 巻数として使える形に整える。Calibreは巻数を常に小数第2位まで("3.00"、"3.50")で
    /// 書き出すため、そのまま表示すると不自然になる。整数で表せる値は整数の文字列にし、
    /// そうでない値も小数部の末尾の0を落とす。
    /// 数値として解釈できない文字列は、そのまま(前後の空白だけ落として)通す。
    ///
    /// 末尾の0を文字列のまま削っているのは、Doubleへ通して書式化し直すと二進小数の丸め誤差が
    /// 表に出ることがあるため("3.125"のような値をそのまま保ちたい)。
    ///
    /// この整形はEPUBのcalibre:series_index/group-positionだけでなく、PDFのXMP
    /// (PDFXMPMetadata)と旧Keywords形式(PDFStructureResolver.parseSeriesKeywords)からも
    /// 共通で通す。qooViewer自身のPDF書き出しもCalibreに合わせて"3.50"の形で書くので、
    /// ここで戻さないと「3.5」と入力した巻数が書き出して開き直すたびに「3.50」へ変わってしまう。
    static func normalizedSeriesIndex(_ rawValue: String?) -> String {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return ""
        }
        guard let value = Double(trimmed) else { return trimmed }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        // 指数表記("3.5e1")は末尾の0が桁の意味を持つため触らない。
        guard trimmed.contains("."), !trimmed.contains(where: { $0 == "e" || $0 == "E" }) else {
            return trimmed
        }
        var stripped = trimmed
        while stripped.hasSuffix("0") { stripped.removeLast() }
        // 整数は上の分岐で処理済みなので"3."の形にはならないが、念のため。
        if stripped.hasSuffix(".") { stripped.removeLast() }
        return stripped.isEmpty ? trimmed : stripped
    }

    // MARK: - 目次(nav.xhtml) → ブックマーク(7.5節「逆方向」)

    /// EPUB3のnav.xhtml(manifest上でproperties="nav"の項目)を探し、その中の
    /// `<nav epub:type="toc">`が指すリンクを、resolve(reader:)が返したEpubStructure.pagesの
    /// インデックスへ対応付ける。nav.xhtmlが無い、目次(toc)navが無い、リンク先がどのページにも
    /// 一致しない、のいずれの場合も空配列を返す(エラーにはしない。呼び出し元(ViewerViewModel)は
    /// 「取り込めるものが無かった」として何もしないだけでよいため)。
    ///
    /// EPUB2のtoc.ncxへのフォールバックは行わない(未対応。13節)。
    static func resolveTableOfContents(reader: ArchiveReading, structure: EpubStructure) -> [EpubTOCEntry] {
        guard let opfPath = try? resolveOPFPath(reader: reader),
              let opfData = try? markupData(reader: reader, at: opfPath),
              let packageDocument = try? parsePackageDocument(data: opfData)
        else { return [] }

        guard let navItem = packageDocument.manifestItems.values.first(where: { $0.properties.contains("nav") })
        else { return [] }

        let opfDirectory = directory(of: opfPath)
        let allPaths = Set((try? reader.listFilePaths()) ?? [])
        let candidateNavPath = resolvedPath(base: opfDirectory, relative: navItem.href)
        guard let navPath = matchExistingPath(candidateNavPath, in: allPaths),
              let navData = try? markupData(reader: reader, at: navPath)
        else { return [] }

        let delegate = NavTOCParserDelegate()
        let parser = XMLParser(data: navData)
        parser.delegate = delegate
        guard parser.parse(), !delegate.entries.isEmpty else { return [] }

        var hrefToPageIndex: [String: Int] = [:]
        for (index, page) in structure.pages.enumerated() {
            hrefToPageIndex[page.sourceHref] = index
        }

        let navDirectory = directory(of: navPath)
        var result: [EpubTOCEntry] = []
        for entry in delegate.entries {
            let candidatePath = resolvedPath(base: navDirectory, relative: entry.href)
            let resolvedHref = matchExistingPath(candidatePath, in: allPaths) ?? candidatePath
            guard let pageIndex = hrefToPageIndex[resolvedHref] else { continue }
            result.append(EpubTOCEntry(title: entry.title, pageIndex: pageIndex))
        }
        return result
    }

    // MARK: - パス解決のユーティリティ

    /// パス(スラッシュ区切り)からディレクトリ部分だけを取り出す。ファイル自身がアーカイブの
    /// ルート直下にある場合は空文字列を返す。
    private static func directory(of path: String) -> String {
        guard let slashIndex = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slashIndex])
    }

    /// base(ディレクトリ)を基準に、relative(URI形式の可能性がある相対パス)を解決する。
    /// EPUB内のhref/srcはURIとしてpercent-encodingされていることがあるためデコードし、
    /// フラグメント(#...)があれば取り除いたうえで、".."を解決して正規化する。
    private static func resolvedPath(base: String, relative: String) -> String {
        var relative = relative
        if let hashIndex = relative.firstIndex(of: "#") {
            relative = String(relative[..<hashIndex])
        }
        if let decoded = relative.removingPercentEncoding {
            relative = decoded
        }
        if relative.hasPrefix("/") {
            return String(relative.dropFirst())
        }

        var components = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for part in relative.split(separator: "/") {
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
            } else if part == "." || part.isEmpty {
                continue
            } else {
                components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }

    /// 計算したパスが実際のアーカイブ内エントリと完全一致しない場合に備えた保険。
    /// (先頭の"./"の有無など、ごく軽微な表記ゆれのみを吸収する。大文字小文字の違いなど
    /// 本質的に異なるパスまでは救わない)
    private static func matchExistingPath(_ candidate: String, in allPaths: Set<String>) -> String? {
        if allPaths.contains(candidate) { return candidate }
        let trimmed = candidate.hasPrefix("./") ? String(candidate.dropFirst(2)) : candidate
        if allPaths.contains(trimmed) { return trimmed }
        return allPaths.first { $0 == trimmed || $0.hasSuffix("/\(trimmed)") }
    }
}

/// META-INF/container.xmlから、package document(OPF)のパスを取り出すためのXMLパーサ委譲先。
/// nonisolated: 上のEpubStructureResolver(nonisolated enum)から、メインスレッド外で
/// インスタンス化・アクセスされるため、こちらもXcode既定のMainActor自動分離の対象外にしておく
/// 必要がある(ZipArchiveReader.swiftのString.Encoding拡張と同じ理由・同じ対処)。
private nonisolated final class ContainerDocumentParserDelegate: NSObject, XMLParserDelegate {
    private(set) var opfPath: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard opfPath == nil, localName(of: elementName) == "rootfile" else { return }
        opfPath = attributeDict["full-path"]
    }
}

/// package document(OPF)から、manifest・spine・一部のmetadataを取り出すためのXMLパーサ委譲先。
/// nonisolated: ContainerDocumentParserDelegateと同じ理由。
private nonisolated final class PackageDocumentParserDelegate: NSObject, XMLParserDelegate {
    struct ManifestItem {
        let href: String
        let mediaType: String
        /// item要素のproperties属性(スペース区切り)。EPUB3のnav文書は"nav"を持つことで識別される
        /// (resolveTableOfContents参照)。
        let properties: Set<String>
    }
    struct SpineItemRef {
        let idref: String
        let properties: Set<String>
    }

    /// `<meta property="..." id="..." refines="...">テキスト</meta>` を1件そのまま保持したもの。
    /// EPUB3のシリーズ情報は、本体のmeta(belongs-to-collection)と、それをid経由で参照して
    /// 補足するmeta(collection-type / group-position)の組で表されるため、解析中は素の形で
    /// 集めておき、あとからまとめて突き合わせる(resolveMetadata参照)。
    struct PropertyMeta {
        let property: String
        let id: String?
        /// 他のmetaを補足する場合、その相手のid(先頭の"#"は取り除いてある)。
        let refines: String?
        let text: String
    }

    private(set) var manifestItems: [String: ManifestItem] = [:]
    private(set) var spineItemRefs: [SpineItemRef] = []
    private(set) var pageProgressionDirection: String?
    private(set) var renditionSpread: String?

    // MARK: - 書誌メタデータ(resolveMetadataが使う)

    private(set) var dcTitle: String?
    private(set) var dcCreator: String?
    /// EPUB2形式の`<meta name="..." content="..."/>`。Calibreのシリーズ情報
    /// (calibre:series / calibre:series_index)がこの形式で書かれる。
    private(set) var metaByName: [String: String] = [:]
    /// EPUB3形式の`<meta property="...">`一式。
    private(set) var propertyMetas: [PropertyMeta] = []

    /// テキストを蓄積している最中の要素の種類。要素をまたいで文字が届くこともあるため、
    /// 開始タグで種類を決め、終了タグで確定させる。
    private enum TextCapture {
        case meta(property: String, id: String?, refines: String?)
        case dcTitle
        case dcCreator
    }
    private var currentCapture: TextCapture?
    private var currentMetaText = ""

    /// いま`<metadata>`の中にいるかどうか。
    ///
    /// このパーサーは名前空間を見ずに要素のローカル名だけで分岐しているため、これが無いと
    /// `<metadata>`の外にある`<title>`(EPUB3の`<collection>`は自分の`<dc:title>`を持てる)まで
    /// 本のタイトルとして拾ってしまう。`<metadata>`はpackage documentの先頭に来るので実害が
    /// 出る場面は限られるが、判定の根拠を「たまたま先に現れるから」に頼らないようにしておく。
    private var isInsideMetadata = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(of: elementName) {
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                let properties = Set(
                    (attributeDict["properties"] ?? "").split(separator: " ").map(String.init)
                )
                manifestItems[id] = ManifestItem(
                    href: href, mediaType: attributeDict["media-type"] ?? "", properties: properties
                )
            }
        case "metadata":
            isInsideMetadata = true
        case "spine":
            pageProgressionDirection = attributeDict["page-progression-direction"]
        case "itemref":
            if let idref = attributeDict["idref"] {
                let properties = Set(
                    (attributeDict["properties"] ?? "")
                        .split(separator: " ")
                        .map(String.init)
                )
                spineItemRefs.append(SpineItemRef(idref: idref, properties: properties))
            }
        case "meta":
            currentMetaText = ""
            if let property = attributeDict["property"] {
                // EPUB3形式。値は要素のテキストとして書かれるため、終了タグまで蓄積する。
                let refines = attributeDict["refines"].map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
                currentCapture = .meta(property: property, id: attributeDict["id"], refines: refines)
            } else if let name = attributeDict["name"], let content = attributeDict["content"] {
                // EPUB2形式(Calibreのシリーズ情報など)。値は属性に入っているためその場で確定する。
                // 同じnameが複数あった場合は最初の1件を採用する(EPUB2のmetaに重複の規定は無く、
                // 実ファイルでも先頭が主たる値である場合が多いため)。
                if metaByName[name] == nil { metaByName[name] = content }
                currentCapture = nil
            } else {
                currentCapture = nil
            }
        case "title":
            // dc:title。複数ある(主題名と副題など)場合は最初の1件だけを使う。
            currentCapture = (isInsideMetadata && dcTitle == nil) ? .dcTitle : nil
            currentMetaText = ""
        case "creator":
            // dc:creator。同じく最初の1件だけを使う(共著は先頭の著者を代表として扱う)。
            currentCapture = (isInsideMetadata && dcCreator == nil) ? .dcCreator : nil
            currentMetaText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentCapture != nil else { return }
        currentMetaText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if localName(of: elementName) == "metadata" { isInsideMetadata = false }
        guard let currentCapture else { return }
        let text = currentMetaText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch currentCapture {
        case .meta(let property, let id, let refines):
            guard localName(of: elementName) == "meta" else { return }
            if property == "rendition:spread" {
                renditionSpread = text
            }
            propertyMetas.append(PropertyMeta(property: property, id: id, refines: refines, text: text))
        case .dcTitle:
            guard localName(of: elementName) == "title" else { return }
            if !text.isEmpty { dcTitle = text }
        case .dcCreator:
            guard localName(of: elementName) == "creator" else { return }
            if !text.isEmpty { dcCreator = text }
        }
        self.currentCapture = nil
        currentMetaText = ""
    }
}

/// XHTML/HTMLの中身から、最初の<img>または<image>(SVG)の参照先を1つだけ取り出すための
/// XMLパーサ委譲先。見つかった時点で以降の要素は無視してよいが、XMLParserを途中で止めるAPIは
/// 無いため、単純にimageHrefが既に設定済みなら何もしないという形で「最初の1つだけ」を保証する。
private nonisolated final class FirstImageReferenceParserDelegate: NSObject, XMLParserDelegate {
    private(set) var imageHref: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard imageHref == nil else { return }
        switch localName(of: elementName) {
        case "img":
            imageHref = attributeDict["src"]
        case "image":
            imageHref = attributeDict["xlink:href"] ?? attributeDict["href"]
        default:
            break
        }
    }
}

/// nav.xhtml内の`<nav epub:type="toc">`(EPUB3目次)から、リンク(href)とリンクテキストの組を
/// 順番に取り出すためのXMLパーサ委譲先。ネストしたnav要素は通常のEPUBには現れない前提で、
/// 単純なフラグの真偽で「今toc navの中にいるか」を管理する(FirstImageReferenceParserDelegateと
/// 同じく実用上のロバストさを優先する方針)。
private nonisolated final class NavTOCParserDelegate: NSObject, XMLParserDelegate {
    private(set) var entries: [(href: String, title: String)] = []
    private var isInsideTOCNav = false
    private var currentHref: String?
    private var currentTitle = ""
    private var isCapturingLinkText = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(of: elementName)
        if name == "nav" {
            if attributeDict["epub:type"] == "toc" || attributeDict["type"] == "toc" {
                isInsideTOCNav = true
            }
            return
        }
        guard isInsideTOCNav, name == "a", let href = attributeDict["href"] else { return }
        currentHref = href
        currentTitle = ""
        isCapturingLinkText = true
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isCapturingLinkText else { return }
        currentTitle += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(of: elementName)
        if name == "a", isCapturingLinkText {
            isCapturingLinkText = false
            if let href = currentHref {
                let trimmedTitle = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedTitle.isEmpty {
                    entries.append((href: href, title: trimmedTitle))
                }
            }
            currentHref = nil
        } else if name == "nav" {
            isInsideTOCNav = false
        }
    }
}

/// "dc:title"のような名前空間プレフィックス付き要素名から、プレフィックスを除いた要素名だけを
/// 取り出す。XMLParserはshouldResolveNamespaces未指定(既定false)で使っているため、
/// elementNameにはプレフィックスが付いたまま渡ってくる。
private nonisolated func localName(of elementName: String) -> String {
    guard let colonIndex = elementName.lastIndex(of: ":") else { return elementName }
    return String(elementName[elementName.index(after: colonIndex)...])
}

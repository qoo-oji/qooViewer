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
    /// (未指定/強制対象外の値ならnil。詳細はMangaBook.swiftのEpubLayoutHintのコメント参照)
    let forcedDisplayMode: DisplayMode?
}

struct EpubPageEntry {
    /// アーカイブ(zipコンテナとしてのEPUB自体)内の画像ファイルのパス
    let entryPath: String
    let spreadPosition: PageSpreadPosition?
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

    static func resolve(reader: ArchiveReading) throws -> EpubStructure {
        let opfPath = try resolveOPFPath(reader: reader)
        let opfData = try reader.data(at: opfPath)
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

            pages.append(EpubPageEntry(entryPath: entryPath, spreadPosition: spreadPosition(from: itemRef.properties)))
        }

        return EpubStructure(
            pages: pages,
            pageProgressionDirection: readingDirection(from: packageDocument.pageProgressionDirection),
            forcedDisplayMode: displayMode(from: packageDocument.renditionSpread)
        )
    }

    // MARK: - container.xml

    private static func resolveOPFPath(reader: ArchiveReading) throws -> String {
        guard let data = try? reader.data(at: containerPath) else {
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
              let contentData = try? reader.data(at: resolvedItemPath) else {
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
    /// (詳細はMangaBook.swiftのEpubLayoutHintのコメント参照)。
    private static func displayMode(from rawValue: String?) -> DisplayMode? {
        switch rawValue?.lowercased() {
        case "none": return .single
        case "both": return .spread
        default: return nil
        }
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
private final class ContainerDocumentParserDelegate: NSObject, XMLParserDelegate {
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
private final class PackageDocumentParserDelegate: NSObject, XMLParserDelegate {
    struct ManifestItem {
        let href: String
        let mediaType: String
    }
    struct SpineItemRef {
        let idref: String
        let properties: Set<String>
    }

    private(set) var manifestItems: [String: ManifestItem] = [:]
    private(set) var spineItemRefs: [SpineItemRef] = []
    private(set) var pageProgressionDirection: String?
    private(set) var renditionSpread: String?

    /// <meta property="...">テキスト</meta> の解析用。開始タグを見た時点のproperty名と、
    /// didEndElementまでに蓄積したテキストを対応付ける。
    private var currentMetaProperty: String?
    private var currentMetaText = ""

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
                manifestItems[id] = ManifestItem(href: href, mediaType: attributeDict["media-type"] ?? "")
            }
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
            currentMetaProperty = attributeDict["property"]
            currentMetaText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentMetaProperty != nil else { return }
        currentMetaText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard localName(of: elementName) == "meta" else { return }
        if currentMetaProperty == "rendition:spread" {
            renditionSpread = currentMetaText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        currentMetaProperty = nil
        currentMetaText = ""
    }
}

/// XHTML/HTMLの中身から、最初の<img>または<image>(SVG)の参照先を1つだけ取り出すための
/// XMLパーサ委譲先。見つかった時点で以降の要素は無視してよいが、XMLParserを途中で止めるAPIは
/// 無いため、単純にimageHrefが既に設定済みなら何もしないという形で「最初の1つだけ」を保証する。
private final class FirstImageReferenceParserDelegate: NSObject, XMLParserDelegate {
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

/// "dc:title"のような名前空間プレフィックス付き要素名から、プレフィックスを除いた要素名だけを
/// 取り出す。XMLParserはshouldResolveNamespaces未指定(既定false)で使っているため、
/// elementNameにはプレフィックスが付いたまま渡ってくる。
private func localName(of elementName: String) -> String {
    guard let colonIndex = elementName.lastIndex(of: ":") else { return elementName }
    return String(elementName[elementName.index(after: colonIndex)...])
}

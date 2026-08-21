import Foundation
import CoreGraphics

/// PDFのXMPメタデータ(Document Catalogの`/Metadata`が指すXMLストリーム)の組み立てと解析。
///
/// PDFにはシリーズ名・巻数を表す標準的なフィールドが存在しない。以前のqooViewerはこれを
/// Document Info辞書のKeywordsへ`series:シリーズ名, series_index:巻数`という独自形式で
/// 書いていたが、これはqooViewer以外の誰も解釈できないうえ、Keywordsは本来「タグ」の欄
/// なので他アプリからは意味不明なタグが1つ付いているようにしか見えなかった。
///
/// 代わりに、この領域で事実上の標準になっているCalibreのXMP表現に合わせる:
///
/// ```xml
/// <rdf:Description rdf:about=""
///     xmlns:calibre="http://calibre-ebook.com/xmp-namespace"
///     xmlns:calibreSI="http://calibre-ebook.com/xmp-namespace-series-index">
///  <calibre:series rdf:parseType="Resource">
///   <rdf:value>シリーズ名</rdf:value>
///   <calibreSI:series_index>3.00</calibreSI:series_index>
///  </calibre:series>
/// </rdf:Description>
/// ```
///
/// 出典はCalibre本体の`src/calibre/ebooks/metadata/xmp.py`(`create_series`/`read_series`、
/// および名前空間表`NS_MAP`)。同じ形式はKomga/Kavita系のサーバでも読まれる
/// (Kavitaはv0.8.5で「Calibreの埋め込みに準拠したPDFのXMP」の読み取りに対応した)ため、
/// qooViewerが書き出したPDFをそのままライブラリサーバへ置ける。
///
/// ■ なぜdc:title/dc:creatorも一緒に書くのか
/// XMPパケットが存在する場合、PDF/XMPの仕様上XMPのほうがDocument Info辞書より優先される。
/// シリーズ情報だけの最小パケットを埋め込むと、XMPを優先するリーダーからは
/// 「タイトルも著者も指定されていない本」に見えてしまう。Calibreのmetadata_to_xmp_packetが
/// 常にdc:title/dc:creatorを含めているのと同じ理由で、こちらも一緒に書く。
///
/// nonisolated: PDFExporter/PDFStructureResolverと同じくメインスレッド外から呼ばれるため
/// (詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated enum PDFXMPMetadata {

    // MARK: - 名前空間

    /// XMPで使う名前空間URI。**接頭辞(`calibre:`など)ではなくURIが同一性の根拠**であり、
    /// 解析側は接頭辞を一切見ない(他ツールが同じ名前空間に別の接頭辞を割り当てて書き出す
    /// ことがあるため。Calibre自身もmerge_xmp_packetで接頭辞を付け替えることがある)。
    private enum Namespace {
        static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        static let dc = "http://purl.org/dc/elements/1.1/"
        static let xmp = "http://ns.adobe.com/xap/1.0/"
        static let calibre = "http://calibre-ebook.com/xmp-namespace"
        static let calibreSeriesIndex = "http://calibre-ebook.com/xmp-namespace-series-index"
    }

    // MARK: - 書き出し

    /// 書き出すXMPパケット(`<?xpacket …?>`で囲まれたUTF-8のバイト列)を組み立てる。
    ///
    /// シリーズ名が空の場合はnilを返す = パケット自体を埋め込まない。タイトル・著者は
    /// Document Info辞書にも同じ値が入っており、XMPが無くてもすべてのリーダーが読める。
    /// 一方でXMPを置くと上のとおりInfo辞書より優先されるようになるため、**シリーズ情報という
    /// 「XMPでしか表せないもの」が無いのにパケットを足しても、得るものが無いまま優先順位だけを
    /// 動かすことになる**。この機能の目的そのものが無い場合は、素のQuartz製PDFのままにしておく。
    ///
    /// - Parameters:
    ///   - seriesIndex: 数値として解釈できる文字列(BookMetadata.exportableSeriesIndexの戻り値)。
    ///     解釈できない場合はseries_indexを省略する(Calibre側の既定値1.0として読まれる)。
    ///   - date: `xmp:MetadataDate`へ書く時刻。テスト以外では省略する(現在時刻)。
    static func packet(
        title: String, author: String?, series: String, seriesIndex: String?, date: Date = Date()
    ) -> Data? {
        let series = series.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !series.isEmpty else { return nil }

        var descriptions: [String] = []

        var dublinCore = ["   <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escape(title))</rdf:li></rdf:Alt></dc:title>"]
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            dublinCore.append("   <dc:creator><rdf:Seq><rdf:li>\(escape(author))</rdf:li></rdf:Seq></dc:creator>")
        }
        descriptions.append("""
              <rdf:Description rdf:about="" xmlns:dc="\(Namespace.dc)">
            \(dublinCore.joined(separator: "\n"))
              </rdf:Description>
            """)

        descriptions.append("""
              <rdf:Description rdf:about="" xmlns:xmp="\(Namespace.xmp)">
               <xmp:MetadataDate>\(Self.timestampFormatter.string(from: date))</xmp:MetadataDate>
              </rdf:Description>
            """)

        var seriesChildren = ["    <rdf:value>\(escape(series))</rdf:value>"]
        if let index = formattedSeriesIndex(seriesIndex) {
            seriesChildren.append("    <calibreSI:series_index>\(index)</calibreSI:series_index>")
        }
        descriptions.append("""
              <rdf:Description rdf:about="" xmlns:calibre="\(Namespace.calibre)" \
            xmlns:calibreSI="\(Namespace.calibreSeriesIndex)">
               <calibre:series rdf:parseType="Resource">
            \(seriesChildren.joined(separator: "\n"))
               </calibre:series>
              </rdf:Description>
            """)

        // 末尾の空白の詰め物はAdobeのXMP仕様の推奨(2KB程度)。qooViewer自身はこのパケットを
        // 後から書き換えないので必須ではないが、他のツール(exiftool等)がファイル全体を作り直さず
        // その場で書き換えられるようにしておく。詰め物があることを`end="w"`(writable)で示す。
        let padding = Array(repeating: String(repeating: " ", count: 100), count: 20).joined(separator: "\n")
        let packet = """
            <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="\(Namespace.rdf)">
            \(descriptions.joined(separator: "\n"))
             </rdf:RDF>
            </x:xmpmeta>
            \(padding)
            <?xpacket end="w"?>
            """
        return Data(packet.utf8)
    }

    /// `xmp:MetadataDate`の書式(ISO 8601、ローカルタイムゾーン)。
    /// Adobeの仕様がローカル時刻を推奨しており、Calibreも`isoformat(now(), as_utc=False)`で
    /// ローカル時刻を書いている。
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// `calibreSI:series_index`へ書く文字列。数値として解釈できなければnil。
    ///
    /// Calibreは常に小数第2位まで(`f'{series_index:.2f}'`)で書き出すため、まずそれに合わせる。
    /// ただし2桁では表せない値(「3.125」のような手入力)ではそこで丸めると往復で値が変わって
    /// しまうので、その場合だけ元の表記をそのまま使う(読み取り側はCalibreも含めて`float()`
    /// 相当の解釈をするため、桁数は問われない)。
    private static func formattedSeriesIndex(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty,
              let value = Double(trimmed), value.isFinite
        else { return nil }
        // String(format:)はロケール非依存(小数点は必ず".")。ロケールを見るのは
        // localizedStringWithFormatのほうで、こちらではない。
        let twoDecimals = String(format: "%.2f", value)
        return Double(twoDecimals) == value ? twoDecimals : trimmed
    }

    /// XML本文へ埋め込む文字列のエスケープ(EpubExporter.xmlEscape / ComicInfoXML.escapeと同じ)。
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - 読み取り

    /// Document Catalogの`/Metadata`が指すXMPパケットを取り出す。無ければnil。
    ///
    /// `CGPDFStreamCopyData`はストリームのフィルタを解いたデータを返すため、Calibreが書き出す
    /// `/Filter /FlateDecode` 付きのパケットもそのまま読める(実測で確認済み)。
    static func readPacket(from document: CGPDFDocument) -> Data? {
        guard let catalog = document.catalog else { return nil }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return nil }
        var format = CGPDFDataFormat.raw
        return CGPDFStreamCopyData(stream, &format) as Data?
    }

    /// XMPパケットから書誌メタデータを取り出す。読めない項目は空文字のまま返す。
    ///
    /// ■ nodeLoadExternalEntitiesNever は必須
    /// ここへ渡ってくるのは、ユーザーがどこから入手したか分からないPDFの中身であり、まったく
    /// 信用できない入力である。しかもPDFを**初めて開くたびに自動で**この解析が走る。
    /// 理由と実害はComicInfoXML.parseのコメントに詳しい(取り込まれた値はDBへ登録され、
    /// 書き出せば外部へ出ていく)。同じ対策をここにも入れておく。
    ///
    /// サイズ上限も同じ考え方で入れている。`/Metadata`は圧縮されていることがあり
    /// (Calibreは常にFlateDecodeで書く)、展開後のサイズは事前には分からない。
    static func parse(_ packet: Data) -> SourceBookMetadata {
        guard !packet.isEmpty, packet.count <= maximumPacketSize,
              let document = try? XMLDocument(data: packet, options: [.nodeLoadExternalEntitiesNever]),
              let root = document.rootElement()
        else { return SourceBookMetadata() }

        var elements: [XMLElement] = []
        collectElements(from: root, into: &elements)

        var metadata = SourceBookMetadata()
        if let title = firstElement(in: elements, uri: Namespace.dc, localName: "title") {
            metadata.title = languageAlternativeValue(of: title)
        }
        if let creator = firstElement(in: elements, uri: Namespace.dc, localName: "creator") {
            // 共著は先頭の著者を代表として扱う(EpubStructureResolverのdc:creatorと同じ方針)。
            metadata.author = languageAlternativeValue(of: creator)
        }
        if let series = firstElement(in: elements, uri: Namespace.calibre, localName: "series") {
            var seriesElements: [XMLElement] = []
            collectElements(from: series, into: &seriesElements)
            let value = firstElement(in: seriesElements, uri: Namespace.rdf, localName: "value")
            metadata.series = trimmedText(of: value)
            if !metadata.series.isEmpty {
                let index = firstElement(
                    in: seriesElements, uri: Namespace.calibreSeriesIndex, localName: "series_index"
                )
                // Calibreは"3.00"のように小数で書くため、EPUB/Keywords側と同じ整形を通す。
                metadata.seriesIndex = EpubStructureResolver.normalizedSeriesIndex(trimmedText(of: index))
            }
        }
        return metadata
    }

    /// 展開後のXMPパケットとして受け付ける上限(4MB)。現実のパケットは数KBに収まる。
    private static let maximumPacketSize = 4 * 1024 * 1024

    /// elementとその子孫の要素をすべて集める(XMPは高々数十要素のため、都度XPathを組むより
    /// 一度平らにしてから名前で引くほうが単純で速い)。
    ///
    /// XPathを使っていないのは、Foundationの`XMLDocument.nodes(forXPath:)`では
    /// **`namespace-uri()`関数が機能しない**ことを実測で確認したため(`namespace-uri()=''`
    /// すら常に0件を返す)。`local-name()`だけでは名前空間の異なる同名要素を区別できず、
    /// 接頭辞での比較は上のNamespaceのコメントのとおり当てにならない。要素の`uri`/`localName`
    /// プロパティは正しく解決されるので、そちらを使う。
    private static func collectElements(from element: XMLElement, into elements: inout [XMLElement]) {
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            elements.append(child)
            collectElements(from: child, into: &elements)
        }
    }

    private static func firstElement(in elements: [XMLElement], uri: String, localName: String) -> XMLElement? {
        elements.first { $0.uri == uri && $0.localName == localName }
    }

    /// `dc:title`/`dc:creator`のような、値がrdf:Alt / rdf:Seq / rdf:Bagに包まれている項目の値。
    ///
    /// rdf:Altの場合は`xml:lang="x-default"`の項目を優先し、無ければ最初の項目を使う。
    /// 包み無しで直接テキストが書かれている(仕様上は正しくないが、実際に書き出すツールがある)
    /// 場合にも対応するため、rdf:liが1つも無ければ要素自身のテキストを使う。
    private static func languageAlternativeValue(of element: XMLElement) -> String {
        var elements: [XMLElement] = []
        collectElements(from: element, into: &elements)
        let items = elements.filter { $0.uri == Namespace.rdf && $0.localName == "li" }
        guard !items.isEmpty else { return trimmedText(of: element) }
        let preferred = items.first {
            $0.attribute(forName: "xml:lang")?.stringValue == "x-default"
        }
        return trimmedText(of: preferred ?? items[0])
    }

    private static func trimmedText(of node: XMLNode?) -> String {
        (node?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

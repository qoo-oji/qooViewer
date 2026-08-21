import Foundation
import CoreGraphics
import PDFKit

/// PDFの目次(アウトライン、Acrobatでいう「しおり」)から読み取った1項目。
/// EpubStructureResolver.EpubTOCEntryのPDF版。
struct PDFOutlineEntry {
    let title: String
    /// MangaBook.pagesのインデックス(=BookLoader.loadPDFが作るPageRef配列のインデックスと
    /// 同じ空間、0始まり)。CGPDFDocumentのページ番号(BookLoader.loadPDF/PageLoader.
    /// renderPDFPageでは1始まりに変換して使っている)とは異なり、ここで扱うのはPDFKitの
    /// PDFDocument.index(for:)がそのまま返す0始まりの値であり、変換不要。
    let pageIndex: Int
}

/// PDFファイルの内部構造のうち、ページ描画そのものには関わらない「メタ情報」
/// (本全体の読み方向・見開き強制ヒント、目次=アウトライン)を読み取るための処理をまとめたもの。
/// EpubStructureResolverのPDF版に相当する。
///
/// ページ描画自体は引き続きCGPDFDocument(PageLoader.renderPDFPage)で行い、ここでは触れない。
/// アウトラインの読み取りだけはPDFKitのPDFOutline/PDFDestinationを使う。CGPDFDocumentの生の
/// アウトライン辞書(カタログの`/Outlines`)を`/First`・`/Next`・`/Down`で手繰る実装は、木構造の
/// 走査に加えてPDF文字列(PDFDocEncoding/UTF-16BE)のデコードや、宛先ページの辞書参照から
/// ページ番号を逆引きする処理まで自前で行う必要がありかなり煩雑になるため、同じ情報を
/// 高レベルAPIとして提供するPDFKitに任せる(ページ描画に使っているCGPDFDocumentを置き換える
/// ものではなく、本を開くタイミングで一度だけ行う軽量なメタ情報読み取りに限定して使う)。
///
/// nonisolated: BookLoader/EpubStructureResolverと同じくメインスレッド外(Task.detached)から
/// 呼ばれるため、Xcode 26既定のMainActor自動分離の対象外にしている
/// (詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated enum PDFStructureResolver {

    // MARK: - Document Catalog(/ViewerPreferences/Direction, /PageLayout) → SourceLayoutHint

    /// PDFのDocument Catalogから、EPUBのspine `page-progression-direction`/`rendition:spread`に
    /// 相当する、本全体のレイアウトヒントを読み取る。BookLoader.loadPDFが既に開いている
    /// CGPDFDocumentをそのまま受け取り、二重にファイルを開かない。
    ///
    /// - `/ViewerPreferences/Direction`(`L2R`/`R2L`): 読み方向。ISO 32000上は「複数ページを
    ///   並べて表示する際の並び順に使うヒント」と定義されており、EPUBのpage-progression-direction
    ///   と同じ役割を果たす。
    /// - `/PageLayout`: `TwoPageLeft`/`TwoPageRight`のときのみ見開き強制として扱う。それ以外
    ///   (`SinglePage`/`OneColumn`/`TwoColumnLeft`/`TwoColumnRight`/未設定)は単ページ強制とは
    ///   みなさない。`/PageLayout`の既定値はSinglePageだが、多くのPDF生成ツールはこの項目自体を
    ///   意図せず省略しているため、EPUBのrendition:spread=none(明示的な強制)と同じ信頼度では
    ///   扱えない。見開き強制側(TwoPageLeft/TwoPageRight)は通常のPDF生成では意図せず付くことが
    ///   ない値のため、こちらは信頼できる。
    ///
    /// どちらも読み取れなければnilを返す(EPUB以外のMangaBook.sourceLayoutHintと同じく、値が
    /// 無ければ従来通りユーザー設定/既定値に従う。EPUBと異なり、PDFであること自体の判定には
    /// この戻り値を使わない。ViewerViewModelの自動インポート判定はisPDFFileで直接判定する)。
    static func resolveLayoutHint(document: CGPDFDocument) -> SourceLayoutHint? {
        guard let catalog = document.catalog else { return nil }
        let direction = readingDirection(fromCatalog: catalog)
        let forcedMode = forcedDisplayMode(fromCatalog: catalog)
        guard direction != nil || forcedMode != nil else { return nil }
        return SourceLayoutHint(pageProgressionDirection: direction, forcedDisplayMode: forcedMode)
    }

    private static func readingDirection(fromCatalog catalog: CGPDFDictionaryRef) -> ReadingDirection? {
        var viewerPreferences: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "ViewerPreferences", &viewerPreferences),
              let viewerPreferences
        else { return nil }

        var directionName: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(viewerPreferences, "Direction", &directionName), let directionName else {
            return nil
        }
        switch String(cString: directionName) {
        case "R2L": return .rightToLeft
        case "L2R": return .leftToRight
        default: return nil
        }
    }

    private static func forcedDisplayMode(fromCatalog catalog: CGPDFDictionaryRef) -> DisplayMode? {
        var pageLayoutName: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(catalog, "PageLayout", &pageLayoutName), let pageLayoutName else {
            return nil
        }
        switch String(cString: pageLayoutName) {
        case "TwoPageLeft", "TwoPageRight": return .spread
        default: return nil
        }
    }

    // MARK: - SourceLayoutHint → Document Catalog(書き出し側)

    /// `/ViewerPreferences`の`/Direction`へ書く名前(上のreadingDirectionと対)。
    ///
    /// 書き込みそのものはCoreGraphicsのPDFコンテキストでは行えないため、書き出し済みの
    /// ファイルへPDFCatalogAugmenterが後から追記する。読み取りと書き出しで表記がずれないよう、
    /// 対応表はこのファイルにまとめてある(以前のformatSeriesKeywordsと同じ方針)。
    static func catalogDirectionName(for direction: ReadingDirection) -> String {
        switch direction {
        case .rightToLeft: return "R2L"
        case .leftToRight: return "L2R"
        }
    }

    /// `/PageLayout`へ書く名前(上のforcedDisplayModeと対)。本ごとの強制指定が無ければnil
    /// (= `/PageLayout`自体を書かない。既定値のSinglePageを明示すると「単ページ強制」の
    /// 意味になってしまうため)。
    ///
    /// TwoPageLeft/TwoPageRightは「奇数ページを左右どちらに置くか」の指定なので、読み方向に
    /// よって選び分ける。読み取り側はどちらも見開き強制として同じに扱うが、Acrobat・
    /// プレビュー.appはこの区別どおりに並べる。
    static func catalogPageLayoutName(
        for displayMode: DisplayMode?, direction: ReadingDirection
    ) -> String? {
        switch displayMode {
        case .spread: return direction == .rightToLeft ? "TwoPageRight" : "TwoPageLeft"
        case .single: return "SinglePage"
        case nil: return nil
        }
    }

    // MARK: - Document Info → 書誌メタデータ

    /// PDFから、タイトル・著者・シリーズ名・巻数を読み取る。
    /// 本を初めて開いたときにDBへ取り込むために使う(EpubStructureResolver.resolveMetadataのPDF版)。
    ///
    /// ■ 読み取り先とその優先順位
    /// PDFにはシリーズ名・巻数を表す標準的なフィールドが存在せず、この領域ではCalibreが使う
    /// XMP表現(Document Catalogの`/Metadata`)が事実上の標準になっている。qooViewer自身の
    /// PDF書き出しもこの形式で書く(PDFXMPMetadata参照)。
    ///
    /// 1. XMP(`/Metadata`)。PDF/XMPの仕様上XMPのほうがDocument Info辞書より優先されるため、
    ///    シリーズ名・巻数だけでなくタイトル・著者もこちらを先に見る(Calibre本体の
    ///    consolidate_metadataと同じ考え方)。
    /// 2. Document Info辞書のTitle/Author。XMPに無い項目を補う。
    /// 3. Document Info辞書のKeywordsの`series:シリーズ名, series_index:巻数番号`。
    ///    **これはqooViewerが以前使っていた独自形式**で、書き出しでは既に使っていない。
    ///    その頃に書き出したPDFを今でも正しく読めるようにするためだけに残してある
    ///    (parseSeriesKeywords参照)。
    static func resolveMetadata(url: URL) -> SourceBookMetadata {
        var metadata = SourceBookMetadata()
        if let document = CGPDFDocument(url as CFURL), let packet = PDFXMPMetadata.readPacket(from: document) {
            metadata = PDFXMPMetadata.parse(packet)
        }

        guard let document = PDFDocument(url: url) else { return metadata }
        let attributes = document.documentAttributes ?? [:]

        if metadata.title.isEmpty {
            metadata.title = string(from: attributes[PDFDocumentAttribute.titleAttribute])
        }
        if metadata.author.isEmpty {
            metadata.author = string(from: attributes[PDFDocumentAttribute.authorAttribute])
        }
        if metadata.series.isEmpty {
            let keywords = string(from: attributes[PDFDocumentAttribute.keywordsAttribute])
            let parsed = parseSeriesKeywords(keywords)
            metadata.series = parsed.series
            metadata.seriesIndex = parsed.seriesIndex
        }
        return metadata
    }

    /// Document Info辞書の値を文字列にする。KeywordsはPDFKitが配列で返すことがあるため
    /// (PDFの仕様上は1つの文字列だが、カンマ区切りを分解して返す実装が観測されている)、
    /// 配列の場合はカンマで連結してから解析にかける。
    private static func string(from value: Any?) -> String {
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let list = value as? [String] { return list.joined(separator: ", ") }
        return ""
    }

    /// Keywordsから`series:`と`series_index:`を取り出す。
    ///
    /// **これは読み取り専用の後方互換の経路である。** qooViewerが以前この独自形式でシリーズ名・
    /// 巻数を書き出していた頃のPDFを、今でも同じように読めるようにするためだけに残してある。
    /// 現在の書き出しはCalibre互換のXMP(PDFXMPMetadata)を使い、Keywordsには何も書かない
    /// (Keywordsは本来「タグ」の欄であり、この形式は他のどのアプリからも意味不明なタグ1つに
    /// しか見えなかった)。したがって、これと対になっていた書き出し側のformatSeriesKeywordsは
    /// 削除してある。
    ///
    /// シリーズ名は次の区切り(半角/全角のカンマ・セミコロン)までを値とみなす。したがって
    /// シリーズ名自体にカンマを含む場合は正しく読めないが、これはこの「キー:値をカンマで並べる」
    /// という形式そのものが持つ制約である(この制約が無いXMPへ移行した理由の1つでもある)。
    ///
    /// `series_index:`は`series:`を接頭辞に持つが、`series`の直後が`_`であって`:`ではないため、
    /// `series\s*:`のパターンが誤って`series_index:`に一致することは無い。
    static func parseSeriesKeywords(_ keywords: String) -> (series: String, seriesIndex: String) {
        guard !keywords.isEmpty else { return ("", "") }
        let series = firstCaptureGroup(
            in: keywords, pattern: #"(?:^|[,;、；])\s*series\s*:\s*([^,;、；]*)"#
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawIndex = firstCaptureGroup(
            in: keywords, pattern: #"series_index\s*:\s*([0-9]+(?:\.[0-9]+)?)"#
        )
        // Calibre同様"3.0"のような小数で書かれている場合があるため、EPUB側と同じ整形を通す。
        return (series, EpubStructureResolver.normalizedSeriesIndex(rawIndex))
    }

    private static func firstCaptureGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange])
    }

    // MARK: - アウトライン(しおり) → ブックマーク

    /// PDFのアウトラインを、EpubStructureResolver.resolveTableOfContentsと同じ形の
    /// (タイトル, ページインデックス)の配列にフラット化する。アウトラインが無い/開けない場合は
    /// 空配列を返す(呼び出し元のViewerViewModelは、EPUBの目次が無い場合と同様に何もしない)。
    ///
    /// 木構造は深さ優先で辿り、出現順にフラット化する。ラベルまたは宛先ページのどちらかが
    /// 取れない項目(URIアクションなど、ページ以外へのリンクを持つ項目)は読み飛ばす。
    static func resolveOutline(url: URL) -> [PDFOutlineEntry] {
        guard let document = PDFDocument(url: url), let root = document.outlineRoot else { return [] }
        var entries: [PDFOutlineEntry] = []
        collect(outline: root, document: document, into: &entries)
        return entries
    }

    private static func collect(outline: PDFOutline, document: PDFDocument, into entries: inout [PDFOutlineEntry]) {
        for childIndex in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: childIndex) else { continue }
            if let label = child.label, !label.isEmpty, let page = child.destination?.page {
                let pageIndex = document.index(for: page)
                if pageIndex != NSNotFound {
                    entries.append(PDFOutlineEntry(title: label, pageIndex: pageIndex))
                }
            }
            collect(outline: child, document: document, into: &entries)
        }
    }
}

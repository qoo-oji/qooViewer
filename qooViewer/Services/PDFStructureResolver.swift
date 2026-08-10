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

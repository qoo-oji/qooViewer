import Foundation

/// 1ページ分の画像データがどこから取得できるかを表す
enum PageSource {
    /// フォルダ内の画像ファイル
    case file(URL)
    /// zip / cbz アーカイブ内のエントリ
    case zip(archiveURL: URL, entryPath: String)
    /// 7z / cb7 アーカイブ内のエントリ
    case sevenZip(archiveURL: URL, entryPath: String)
    /// rar / cbr アーカイブ内のエントリ
    case rar(archiveURL: URL, entryPath: String)
    /// PDFファイル内の1ページ(0始まりのページ番号)
    case pdf(pdfURL: URL, pageIndex: Int)

    /// フォルダ内の独立した画像ファイルかどうか(書庫内エントリ・PDFのページではない)。
    /// この場合だけ、ファイルを丸ごと読まずにヘッダーだけを読むURLベースの経路が使える
    /// (PageLoader.pageSize/pageImageInfo、ImageDecoder.headerInfo(ofFileAt:)参照)。
    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}

/// EPUBのpackage document内で、そのページに明示的に指定された見開き内の配置。
/// EPUB Publications仕様の`page-spread-left`/`page-spread-right`(spine itemrefのproperties)、
/// および`rendition:page-spread-center`に対応する。
///
/// - left: 見開きの左側に配置する(通常は次のページと組んで、自身が起点になる)
/// - right: 見開きの右側に配置する(常に直前のページと組む。自身が見開きの起点にはならない)
/// - center: 見開き表示中でも単独の1ページとして中央に表示する(前後のページとは組まない)
///
/// EPUB以外のPageSource(フォルダ・cbz/cbr/cb7・PDF)では常にnil。
enum PageSpreadPosition: String, Codable, Hashable {
    case left
    case right
    case center
}

/// 本の中の1ページを表す
struct PageRef: Identifiable, Hashable {
    /// 一意なキー(画像キャッシュや SwiftUI の List/ForEach 用)
    let id: String
    /// 自然順ソート用のキー(ファイル名やアーカイブ内パス)
    let sortKey: String
    let source: PageSource
    /// EPUBがこのページの見開き内配置を明示している場合のみ値を持つ。詳細はPageSpreadPosition参照。
    /// EPUB以外のソースでは常にnil(デフォルト値のため、他のPageRef生成箇所は変更不要)。
    var epubSpreadPosition: PageSpreadPosition? = nil

    static func == (lhs: PageRef, rhs: PageRef) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// プログレスバーのフィルムストリップなどに表示する、ファイル名だけの短い表示名。
    var displayName: String {
        switch source {
        case .file(let url):
            return url.lastPathComponent
        case .zip(_, let entryPath), .sevenZip(_, let entryPath), .rar(_, let entryPath):
            return (entryPath as NSString).lastPathComponent
        case .pdf(let pdfURL, let pageIndex):
            // PDFのページ自体には(アーカイブ内エントリのような)個別のファイル名がないため、
            // 元のPDFファイル名とページ番号(1始まりで表示)を組み合わせて表示する。
            return "\(pdfURL.deletingPathExtension().lastPathComponent) (\(pageIndex + 1))"
        }
    }
}

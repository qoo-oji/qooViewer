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
}

/// 本の中の1ページを表す
struct PageRef: Identifiable, Hashable {
    /// 一意なキー(画像キャッシュや SwiftUI の List/ForEach 用)
    let id: String
    /// 自然順ソート用のキー(ファイル名やアーカイブ内パス)
    let sortKey: String
    let source: PageSource

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

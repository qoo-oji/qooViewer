import Foundation

/// 開いている1冊の漫画(画像フォルダ、または zip/rar/7z アーカイブ)
struct MangaBook: Identifiable, Hashable {
    /// 一意なID。フォルダ/アーカイブのファイルパスをそのまま使う
    let id: String
    /// ビューワーに表示するタイトル
    let title: String
    /// 元になったフォルダ、またはアーカイブファイルの場所
    let sourceURL: URL
    /// 自然順(数字を考慮した順序)に並んだページ一覧
    let pages: [PageRef]

    static func == (lhs: MangaBook, rhs: MangaBook) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

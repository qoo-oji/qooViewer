import SwiftUI

/// ブックマーク一覧画面(BookmarkListView)を並べる基準。
///
/// お気に入りのFavoritesSortOptionと違い、ブックマークにはフォルダの概念も「更新日時」の
/// 概念も無い。代わりに「本の中の位置」という、お気に入りには無い基準(pageIndex)を持つため、
/// ページ番号/名前(ブックマーク名)/追加日時のそれぞれについて昇順・降順の2種類ずつ、
/// 計6種類を用意する。
///
/// 名前順とページ番号順は必ずしも一致しない点に注意。ブックマークは追加時こそ「ページ N」と
/// いう規則的な名前が自動で付くが、後から自由にリネームできるため、リネームした時点で
/// 名前順とページ番号順はずれる(例えば「クライマックス」のような名前に変えると、
/// アルファベット順の位置は本来のページ位置と無関係になる)。これは不具合ではなく、
/// 名前順・ページ番号順という異なる基準を両方選べるようにした結果の当然の挙動。
///
/// 名前/追加日時(nameAscending〜/dateAddedAscending〜)のtitleKeyは、FavoritesSortOptionの
/// 対応するケースと同じ文字列にしてある(「お気に入りの編集」画面のプルダウンと表記を
/// 揃えるための指定。Xcodeの文字列カタログ上も同じキーとして扱われるため、
/// Localizable.xcstringsに新たなエントリを追加する必要はない)。
enum BookmarkSortOption: String, CaseIterable, Identifiable, Codable, Hashable {
    case pageNumberAscending
    case pageNumberDescending
    case nameAscending
    case nameDescending
    case dateAddedAscending
    case dateAddedDescending

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .pageNumberAscending: return "Page Number (Ascending)"
        case .pageNumberDescending: return "Page Number (Descending)"
        case .nameAscending: return "Name (A–Z)"
        case .nameDescending: return "Name (Z–A)"
        case .dateAddedAscending: return "Date Added (Oldest First)"
        case .dateAddedDescending: return "Date Added (Newest First)"
        }
    }

    /// ソートメニューに添えるアイコン。
    var systemImage: String {
        switch self {
        case .pageNumberAscending, .pageNumberDescending: return "number"
        case .nameAscending, .nameDescending: return "textformat"
        case .dateAddedAscending, .dateAddedDescending: return "calendar"
        }
    }
}

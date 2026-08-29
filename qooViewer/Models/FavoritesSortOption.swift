import SwiftUI

/// 「名前」「追加日時」「更新日時」という3つの基準で、それぞれ昇順・降順に並べ替えるための
/// 汎用的な列挙。以下の2箇所で共通して使う(名称は歴史的経緯で"Favorites"のままだが、
/// 中身はお気に入り固有のものではない)。
///
/// - お気に入り一覧(「お気に入りの整理」ウインドウ、およびメニューバー/ツールバーのサブメニュー):
///   FavoritesStoreが公開するrootFolders/rootBooksとsubfolders(of:)/books(in:)は常にこの並び順で
///   結果を返すため、ここを切り替えるだけで両方の画面に同時に反映される。
/// - ブックマークの編集ウインドウ(「すべての本を横断したブックマーク編集」への変更に伴い、
///   以前あった専用のBookmarkSortOption(ページ番号ソートを含む6種)を廃止し、こちらを
///   そのまま流用することにした。ブックマークにはページ番号という固有の基準もあったが、
///   お気に入りと表記・挙動を完全に揃えるため、そちらは削除した。BookmarkSortOption.swift参照)。
///
/// (以前あった「登録順(手動の並び)」は廃止した。お気に入りでフォルダ・お気に入りをどちらを
/// 上に表示するかは、この並び替え基準とは独立したFavoritesStore.foldersAlwaysOnTopで扱う)。
///
/// - 追加日時: FavoriteBook.addedAt / FavoriteFolder.createdAt(登録・作成した日時。以後変わらない)、
///   またはBookmark.createdAt(追加した日時)。
/// - 更新日時: FavoriteBook.updatedAt / FavoriteFolder.updatedAt(お気に入りが別フォルダへ
///   移動された、またはフォルダ直下でお気に入り/サブフォルダの追加・移動・削除があった日時)、
///   またはBookmark.updatedAt(リネームされた日時)。詳細は各モデルのupdatedAtのコメント、
///   およびFavoritesStore/BookmarkStoreの各メソッド参照。
enum FavoritesSortOption: String, CaseIterable, Identifiable, Codable, Hashable {
    case nameAscending
    case nameDescending
    case dateAddedAscending
    case dateAddedDescending
    case dateUpdatedAscending
    case dateUpdatedDescending

    var id: String { rawValue }

    /// 並べ替えの基準そのもの(昇順・降順を含まない3種類)。
    ///
    /// 6つのcaseは「基準3種類 × 昇順/降順」の組み合わせでしかないため、その2つの軸を別々の
    /// メニューとして選ばせる画面(ブックマーク・レイアウトの編集ウインドウの左ペイン、
    /// およびお気に入りの整理ウインドウ。いずれもユーザー要望)のために、分解して読み書き
    /// できるようにしてある。保存される値・並べ替えの実装は従来どおりFavoritesSortOptionのまま
    /// (メニューバー等に残っている6項目を平らに並べる見せ方とも、同じ設定値を共有できる)。
    enum Field: String, CaseIterable, Identifiable, Hashable {
        case name
        case dateAdded
        case dateUpdated

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .name: return "Name"
            case .dateAdded: return "Date Added"
            case .dateUpdated: return "Date Updated"
            }
        }

        var systemImage: String {
            switch self {
            case .name: return "textformat"
            case .dateAdded: return "calendar"
            case .dateUpdated: return "clock.arrow.circlepath"
            }
        }
    }

    var field: Field {
        switch self {
        case .nameAscending, .nameDescending: return .name
        case .dateAddedAscending, .dateAddedDescending: return .dateAdded
        case .dateUpdatedAscending, .dateUpdatedDescending: return .dateUpdated
        }
    }

    var isAscending: Bool {
        switch self {
        case .nameAscending, .dateAddedAscending, .dateUpdatedAscending: return true
        case .nameDescending, .dateAddedDescending, .dateUpdatedDescending: return false
        }
    }

    init(field: Field, ascending: Bool) {
        switch field {
        case .name: self = ascending ? .nameAscending : .nameDescending
        case .dateAdded: self = ascending ? .dateAddedAscending : .dateAddedDescending
        case .dateUpdated: self = ascending ? .dateUpdatedAscending : .dateUpdatedDescending
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .nameAscending: return "Name (A–Z)"
        case .nameDescending: return "Name (Z–A)"
        case .dateAddedAscending: return "Date Added (Oldest First)"
        case .dateAddedDescending: return "Date Added (Newest First)"
        case .dateUpdatedAscending: return "Date Updated (Oldest First)"
        case .dateUpdatedDescending: return "Date Updated (Newest First)"
        }
    }

    /// ソートメニューに添えるアイコン。
    var systemImage: String {
        switch self {
        case .nameAscending, .nameDescending: return "textformat"
        case .dateAddedAscending, .dateAddedDescending: return "calendar"
        case .dateUpdatedAscending, .dateUpdatedDescending: return "clock.arrow.circlepath"
        }
    }
}

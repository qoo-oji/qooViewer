import SwiftUI

/// お気に入り一覧(「お気に入りの整理」ウインドウ、およびメニューバー/ツールバーのサブメニュー)
/// を並べる基準。FavoritesStoreが公開するrootFolders/rootBooksとsubfolders(of:)/books(in:)は
/// 常にこの並び順で結果を返すため、ここを切り替えるだけで両方の画面に同時に反映される。
///
/// 名前(ファイル名)/追加日時/更新日時のそれぞれについて、昇順・降順の2種類ずつを用意する。
/// (以前あった「登録順(手動の並び)」は廃止した。フォルダ・お気に入りをどちらを上に
/// 表示するかは、この並び替え基準とは独立したFavoritesStore.foldersAlwaysOnTopで扱う)。
///
/// - 追加日時: FavoriteBook.addedAt / FavoriteFolder.createdAt(登録・作成した日時。以後変わらない)。
/// - 更新日時: FavoriteBook.updatedAt / FavoriteFolder.updatedAt(お気に入りが別フォルダへ
///   移動された、またはフォルダ直下でお気に入り/サブフォルダの追加・移動・削除があった日時。
///   詳細は各モデルのupdatedAtのコメント、およびFavoritesStoreの各メソッド参照)。
enum FavoritesSortOption: String, CaseIterable, Identifiable, Codable, Hashable {
    case nameAscending
    case nameDescending
    case dateAddedAscending
    case dateAddedDescending
    case dateUpdatedAscending
    case dateUpdatedDescending

    var id: String { rawValue }

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

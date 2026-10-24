import SwiftUI

/// 「名前」「タイトル」「追加日時」「更新日時」などの基準で、それぞれ昇順・降順に並べ替えるための汎用的な列挙。
/// ライブラリ・コレクション(ホーム、サイドパネル)とブックマークの編集ウインドウで共通して使う
/// (2026-10-24 までの名前は FavoritesSortOption。最初に使ったお気に入り機能を削除したときに改名した。
/// 保存している値は rawValue なので、改名で変わらない)。
///
/// - ブックマークの編集ウインドウ(「すべての本を横断したブックマーク編集」への変更に伴い、
///   以前あった専用のBookmarkSortOption(ページ番号ソートを含む6種)を廃止し、こちらを
///   そのまま流用することにした。BookmarkSortOption.swiftはその後しばらく空ファイルとして
///   残っていたが、2026-09に削除済み)。
///
/// **「タイトル」だけは、どの画面にも出す基準ではない**(ユーザー要望 2026-09-10)。書誌の
/// タイトルを持つのは本だけで、コレクション・ブックマークには名前しか無いためである。
/// 出すのはコレクションの中(CollectionDetailView)だけで、それ以外の並べ替えメニューは
/// `Field.withoutTitle`を渡して候補から外す ―― 選んでも何も起きない選択肢を並べないため
/// (CollectionCoverCaptionStyleを別に立てたときと同じ判断)。
///
/// - 追加日時: CollectionItem / BookCollection の追加・作成日時、またはBookmark.createdAt(追加した日時)。
/// - 更新日時: 各モデルの updatedAt(Bookmark ならリネームされた日時)。詳細は各モデルのupdatedAtのコメント、
///   およびCollectionStore/BookmarkStoreの各メソッド参照。
enum ItemSortOption: String, CaseIterable, Identifiable, Codable, Hashable {
    case nameAscending
    case nameDescending
    case titleAscending
    case titleDescending
    case dateAddedAscending
    case dateAddedDescending
    case dateUpdatedAscending
    case dateUpdatedDescending
    /// 本のファイル/フォルダの作成日・変更日(Finderの「作成日」「変更日」と同じ値)。
    /// **本を並べる画面だけに出す**(ユーザー要望 2026-09-13。「タイトル」と同じ扱い ――
    /// ファイルシステム上の日付を持つのは本だけ。ブックマーク・コレクションの
    /// 並べ替えでは名前として扱う)。
    case dateCreatedAscending
    case dateCreatedDescending
    case dateModifiedAscending
    case dateModifiedDescending

    var id: String { rawValue }

    /// 並べ替えの基準そのもの(昇順・降順を含まない3種類)。
    ///
    /// 6つのcaseは「基準3種類 × 昇順/降順」の組み合わせでしかないため、その2つの軸を別々の
    /// メニューとして選ばせる画面(ブックマーク・レイアウトの編集ウインドウの左ペイン。
    /// ユーザー要望)のために、分解して読み書きできるようにしてある。保存される値・並べ替えの実装は従来どおりItemSortOptionのまま
    /// (メニューバー等に残っている6項目を平らに並べる見せ方とも、同じ設定値を共有できる)。
    enum Field: String, CaseIterable, Identifiable, Hashable {
        case name
        /// 書誌メタデータのタイトル(登録済みならDBの値、未登録ならファイル名からの推測値。
        /// BookTitleResolver参照)。**本を並べる画面だけに出す**(型コメント参照)。
        case title
        case dateAdded
        case dateUpdated
        /// 本のファイル/フォルダの作成日(Finderの「作成日」)。本を並べる画面だけに出す。
        case dateCreated
        /// 本のファイル/フォルダの変更日(Finderの「変更日」)。本を並べる画面だけに出す。
        case dateModified

        var id: String { rawValue }

        /// タイトルを持たないもの(ブックマーク・コレクションそのもの)を並べる
        /// メニューに出す基準。`allCases`をそのまま渡すと「タイトル」まで並んでしまう。
        static let withoutTitle: [Field] = [.name, .dateAdded, .dateUpdated]

        var titleKey: LocalizedStringKey {
            switch self {
            case .name: return "Name"
            case .title: return "Title"
            case .dateAdded: return "Date Added"
            case .dateUpdated: return "Date Updated"
            case .dateCreated: return "Date Created"
            case .dateModified: return "Date Modified"
            }
        }

        var systemImage: String {
            switch self {
            case .name: return "textformat"
            case .title: return "text.book.closed"
            case .dateAdded: return "calendar"
            case .dateUpdated: return "clock.arrow.circlepath"
            case .dateCreated: return "calendar.badge.plus"
            case .dateModified: return "pencil.and.list.clipboard"
            }
        }
    }

    var field: Field {
        switch self {
        case .nameAscending, .nameDescending: return .name
        case .titleAscending, .titleDescending: return .title
        case .dateAddedAscending, .dateAddedDescending: return .dateAdded
        case .dateUpdatedAscending, .dateUpdatedDescending: return .dateUpdated
        case .dateCreatedAscending, .dateCreatedDescending: return .dateCreated
        case .dateModifiedAscending, .dateModifiedDescending: return .dateModified
        }
    }

    var isAscending: Bool {
        switch self {
        case .nameAscending, .titleAscending, .dateAddedAscending, .dateUpdatedAscending,
             .dateCreatedAscending, .dateModifiedAscending:
            return true
        case .nameDescending, .titleDescending, .dateAddedDescending, .dateUpdatedDescending,
             .dateCreatedDescending, .dateModifiedDescending:
            return false
        }
    }

    init(field: Field, ascending: Bool) {
        switch field {
        case .name: self = ascending ? .nameAscending : .nameDescending
        case .title: self = ascending ? .titleAscending : .titleDescending
        case .dateAdded: self = ascending ? .dateAddedAscending : .dateAddedDescending
        case .dateUpdated: self = ascending ? .dateUpdatedAscending : .dateUpdatedDescending
        case .dateCreated: self = ascending ? .dateCreatedAscending : .dateCreatedDescending
        case .dateModified: self = ascending ? .dateModifiedAscending : .dateModifiedDescending
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .nameAscending: return "Name (A–Z)"
        case .nameDescending: return "Name (Z–A)"
        case .titleAscending: return "Title (A–Z)"
        case .titleDescending: return "Title (Z–A)"
        case .dateAddedAscending: return "Date Added (Oldest First)"
        case .dateAddedDescending: return "Date Added (Newest First)"
        case .dateUpdatedAscending: return "Date Updated (Oldest First)"
        case .dateUpdatedDescending: return "Date Updated (Newest First)"
        case .dateCreatedAscending: return "Date Created (Oldest First)"
        case .dateCreatedDescending: return "Date Created (Newest First)"
        case .dateModifiedAscending: return "Date Modified (Oldest First)"
        case .dateModifiedDescending: return "Date Modified (Newest First)"
        }
    }

    /// ソートメニューに添えるアイコン。
    var systemImage: String {
        switch self {
        case .nameAscending, .nameDescending: return "textformat"
        case .titleAscending, .titleDescending: return "text.book.closed"
        case .dateAddedAscending, .dateAddedDescending: return "calendar"
        case .dateUpdatedAscending, .dateUpdatedDescending: return "clock.arrow.circlepath"
        case .dateCreatedAscending, .dateCreatedDescending: return "calendar.badge.plus"
        case .dateModifiedAscending, .dateModifiedDescending: return "pencil.and.list.clipboard"
        }
    }
}

import Foundation
import SwiftData

/// 本の特定のページに付けるブックマーク。SwiftDataで永続化する。
/// bookID には MangaBook.id (フォルダ/アーカイブファイルのパス) を使う。
@Model
final class Bookmark {
    @Attribute(.unique) var id: UUID
    var bookID: String
    var pageIndex: Int
    var name: String
    var createdAt: Date
    /// 最後に更新された日時。並び替え基準「更新順」に使う(FavoritesSortOption/BookmarkStore参照)。
    /// ブックマークにはお気に入りのようなフォルダ移動の概念が無く、後から変えられる唯一の値が
    /// 名前(リネーム)であるため、リネームしたときにのみ更新する(登録時点ではcreatedAtと同じ値。
    /// BookmarkStore.rename(_:to:)参照)。
    ///
    /// `= Date()`という宣言時のデフォルト値は、この属性を後から追加したことによる
    /// ライトウェイトマイグレーション(SwiftDataが自動で行うスキーマ移行)のために必須。
    /// これが無いと、この属性が存在しなかった以前のバージョンで保存済みのデータを開こうとした際に
    /// 「Validation error missing attribute values on mandatory destination attribute」という
    /// エラーで起動できなくなる(FavoriteBook.updatedAtで実際に踏んだ不具合と同じ原因。詳細は
    /// そちらのコメント参照)。
    var updatedAt: Date = Date()

    init(bookID: String, pageIndex: Int, name: String) {
        self.id = UUID()
        self.bookID = bookID
        self.pageIndex = pageIndex
        self.name = name
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}

/// ブックマークの追加・削除・リネームが、この変更を直接行った側(ViewerViewModelまたは
/// BookmarkStore)以外にも通知されるようにするための共通の通知名。
///
/// ブックマークは「今開いている本の中の一覧」(ViewerViewModel.bookmarks)と「すべての本を
/// 横断した一覧」(BookmarkStore、「ブックマークの編集」ウインドウ)の2箇所から同時に同じ
/// SwiftDataのBookmarkを参照しうる(例: ある本を開いたまま、独立ウインドウの「ブックマークの
/// 編集」でその本のブックマークを削除する)。どちらも内部にキャッシュした配列
/// (ViewerViewModel.bookmarks/BookmarkStoreが公開する一覧)を都度re-fetchして持っているため、
/// 一方が変更した内容がもう一方に自動的には伝わらない。この通知を変更後に毎回投げ、
/// 双方がobserveして自分のキャッシュを読み直すことで、開いているウインドウがいくつあっても
/// 表示が食い違わないようにする。
///
/// userInfoの"bookID"(String)には、変更があった本のbookIDを入れる
/// (ViewerViewModel側が「自分の本に関係する変更か」を判定するために使う。BookmarkStore側は
/// 横断的に全件を扱うため、bookIDに関わらず常に読み直す)。
extension Notification.Name {
    static let bookmarksDidChange = Notification.Name("qooViewer.bookmarksDidChange")
}

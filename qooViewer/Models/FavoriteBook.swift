import Foundation
import SwiftData

/// お気に入りに登録した本(フォルダ/アーカイブファイル/PDF/EPUB)。
///
/// サンドボックス環境では単なるファイルパスの文字列を保存しても、次回アプリを起動したときに
/// そのURLへアクセスする権限がない。そのため、RecentFilesStore/FolderAccessStore/
/// LastActiveBookStoreと同じく「セキュリティスコープ付きブックマーク」(bookmarkData)として
/// 保持する(それらはUserDefaultsに保存しているが、お気に入りは階層構造・件数上限・並び順など
/// 扱うデータが多いため、SwiftDataのモデルとして持たせる。Dataは通常の属性として保存できる)。
@Model
final class FavoriteBook {
    @Attribute(.unique) var id: UUID
    /// 登録した時点でのMangaBook.id(フォルダ/アーカイブファイルのパス)と同じ形式の文字列。
    /// 「同じ本を再登録しようとしたときの重複チェック」の検索キーとして使う
    /// (FavoritesStore.existingFavorite(forBookID:)参照)。
    var bookID: String
    /// セキュリティスコープ付きブックマーク。開くときはこれを解決してURLを得る。
    var bookmarkData: Data
    /// 表示用タイトル(登録時点のファイル/フォルダ名)。
    var title: String
    /// 同じフォルダ内での並び順(小さいほど上に表示)。
    var sortOrder: Int
    /// 登録した日時。ウェルカム画面の「最近お気に入りに追加したファイル」の並び替えに使う。
    var addedAt: Date

    /// 所属フォルダ。nilの場合は「フォルダ分けせず、お気に入りの一番上の階層に直接置く」
    /// ことを表す(FavoriteFolder.parentがnilならルート直下のフォルダを表すのと同じ考え方)。
    var folder: FavoriteFolder?

    init(
        bookID: String,
        bookmarkData: Data,
        title: String,
        folder: FavoriteFolder?,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.bookID = bookID
        self.bookmarkData = bookmarkData
        self.title = title
        self.folder = folder
        self.sortOrder = sortOrder
        self.addedAt = Date()
    }
}

// Identifiableへの明示的な適合は付けていない(FavoriteFolder.swiftと同じ理由。
// SwiftUI側では`ForEach(..., id: \.id)`のように明示的にidを指定して使う)。

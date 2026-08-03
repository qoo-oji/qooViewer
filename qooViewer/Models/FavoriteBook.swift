import Foundation
import SwiftData

/// お気に入りに登録した本(フォルダ/アーカイブファイル/PDF/EPUB)。
///
/// サンドボックス環境では単なるファイルパスの文字列を保存しても、次回アプリを起動したときに
/// そのURLへアクセスする権限がない。そのため、RecentFilesStore/FolderAccessStore/
/// LastActiveBookStoreと同じく「セキュリティスコープ付きブックマーク」(bookmarkData)として
/// 保持する(それらはUserDefaultsに保存しているが、お気に入りは階層構造・件数上限・並び順など
/// 扱うデータが多いため、SwiftDataのモデルとして持たせる。Dataは通常の属性として保存できる)。
/// 以前はidに`@Attribute(.unique)`の一意制約を付けていたが、外した。Bookmark.id/
/// PageLayoutOverride.compositeKey/BookLayoutSettings.bookIDと同じ理由(詳細はBookmark.swiftの
/// コメント参照)。idはinit時に毎回`UUID()`で新規生成するだけのため、SwiftData側の一意制約に
/// 頼る必要は元々無い。
@Model
final class FavoriteBook {
    var id: UUID
    /// 登録した時点でのMangaBook.id(フォルダ/アーカイブファイルのパス)と同じ形式の文字列。
    /// 「同じ本を再登録しようとしたときの重複チェック」の検索キーとして使う
    /// (FavoritesStore.existingFavorite(forBookID:)参照)。
    var bookID: String
    /// セキュリティスコープ付きブックマーク。開くときはこれを解決してURLを得る。
    var bookmarkData: Data
    /// 表示用タイトル(登録時点のファイル/フォルダ名)。
    var title: String
    /// 同じフォルダ内へ登録/移動された順番(小さいほど先)。現在は表示の並び替えには使って
    /// いない(表示順はFavoritesStore.sortOption/foldersAlwaysOnTopに従う。詳細はentries(in:)
    /// 参照)。将来、手動ドラッグでの並べ替えを再度実装する場合に備えて値自体は保持している。
    var sortOrder: Int
    /// 登録した日時。ウェルカム画面の「最近お気に入りに追加したファイル」の並び替え、および
    /// 並び替え基準「追加日時」に使う。
    var addedAt: Date
    /// 最後に更新された日時。並び替え基準「更新順」に使う。現在は「別のフォルダへ移動した」
    /// ときにのみ更新する(登録時点ではaddedAtと同じ値。FavoritesStore.move(_:to:)参照。
    /// 上書き登録(同じフォルダへの再登録)ではあえて更新しない)。
    ///
    /// `= Date()`という宣言時のデフォルト値は、この属性を後から追加したことによる
    /// ライトウェイトマイグレーション(SwiftDataが自動で行うスキーマ移行)のために必須。
    /// これが無いと、この属性が存在しなかった以前のバージョンで保存済みのデータを開こうとした際に
    /// 「Validation error missing attribute values on mandatory destination attribute」という
    /// エラーで起動できなくなる(必須(非Optional)属性を後から追加する場合、SwiftDataは
    /// 既存データの欠けている値をこのデフォルト値で埋める。実際にinitでは常に明示的に
    /// 値を設定し直すため、新規作成時にこのデフォルト値自体が使われることはない)。
    var updatedAt: Date = Date()

    /// 所属フォルダ。nilの場合は「フォルダ分けせず、お気に入りの一番上の階層に直接置く」
    /// ことを表す(FavoriteFolder.parentがnilならルート直下のフォルダを表すのと同じ考え方)。
    var folder: FavoriteFolder?

    /// ユーザー要望: お気に入りをファイルパスだけでなくファイルノード(iノード番号)でも
    /// 識別し、同一ボリューム内での移動・リネームを引き継げるようにしたい。登録時点の
    /// FileNodeIdentifierを記録しておく(取得できなかった場合はnilのまま)。
    /// FavoritesStore.reconcileBookIDIfMoved(book:)が、この本を開き直したときに
    /// bookID(パス)が変わっていないかをこれと照合し、変わっていれば自動的に追従させる。
    var inodeNumber: Int64?
    var volumeDeviceNumber: Int64?

    init(
        bookID: String,
        bookmarkData: Data,
        title: String,
        folder: FavoriteFolder?,
        sortOrder: Int = 0,
        fileNodeIdentifier: FileNodeIdentifier? = nil
    ) {
        self.id = UUID()
        self.bookID = bookID
        self.bookmarkData = bookmarkData
        self.title = title
        self.folder = folder
        self.sortOrder = sortOrder
        self.inodeNumber = fileNodeIdentifier?.inodeNumber
        self.volumeDeviceNumber = fileNodeIdentifier?.volumeDeviceNumber
        let now = Date()
        self.addedAt = now
        self.updatedAt = now
    }

    /// inodeNumber/volumeDeviceNumberが両方揃っている場合のみFileNodeIdentifierとして返す
    /// (どちらか一方だけ記録されていることは無い想定だが、念のため両方の存在を要求する)。
    var fileNodeIdentifier: FileNodeIdentifier? {
        guard let inodeNumber, let volumeDeviceNumber else { return nil }
        return FileNodeIdentifier(inodeNumber: inodeNumber, volumeDeviceNumber: volumeDeviceNumber)
    }
}

// Identifiableへの明示的な適合は付けていない(FavoriteFolder.swiftと同じ理由。
// SwiftUI側では`ForEach(..., id: \.id)`のように明示的にidを指定して使う)。

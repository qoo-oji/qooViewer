import Foundation
import SwiftData

/// コレクションのカバー画像(登録時に1回だけ抽出したJPEG)の状態。
/// 生の`Int`としてCollectionItem.coverStatusに保存する(SwiftDataのモデルに列挙型をそのまま
/// 置くと、後から`case`を足したときの移行が面倒になるため。PageLayoutOverride.stateRawと
/// 同じ考え方)。
enum CollectionCoverStatus: Int, Sendable, CaseIterable {
    /// まだ抽出していない(CollectionCoverExtractorの待ち行列に入る)。
    case pending = 0
    /// 抽出済み。CollectionCoverStoreに`<itemID>.jpg`がある。
    case ready = 1
    /// 抽出を試みたが失敗した(壊れた本・実体が見つからない等)。灰色の枠と形式バッジで描く。
    case failed = 2
}

/// コレクションに入っている本1冊。
///
/// お気に入り(FavoriteBook)と同じく、本そのものへの参照はセキュリティスコープ付き
/// ブックマーク(bookmarkData)として保持する ―― コレクションは「本を開いていない状態から
/// 後で開く」ためのものなので、パス文字列だけでは次回起動時にアクセス権が無い
/// (詳細はFavoriteBook.swiftのコメント参照)。
///
/// `@Attribute(.unique)`を付けない理由もFavoriteBookと同じ。同じコレクションの中での本の
/// 重複はCollectionStore.add(_:to:)がパス/iノードの両方で弾く。
@Model
final class CollectionItem {
    /// この行のid。**カバー画像のファイル名にもそのまま使う**
    /// (~/Library/Application Support/<bundleID>/CollectionCovers/<id>.jpg。
    /// CollectionCoverStore参照)。
    var id: UUID
    /// 登録した時点でのMangaBook.id(フォルダ/アーカイブファイルのパス)。
    var bookID: String
    /// セキュリティスコープ付きブックマーク。開くときはこれを解決してURLを得る。
    var bookmarkData: Data
    /// この本のファイル/フォルダ名(フォルダはそのまま、ファイルは拡張子を落とす。
    /// `CollectionStore.itemTitle(for:isDirectory:)`)。ツールチップ(`.help`)、
    /// 「本が見つかりません」のアラート、カバー下のキャプション(設定が「ファイル名」のとき)で使う。
    ///
    /// 登録時の名前で固定ではなく、**iノードで同一ファイルと確定したリネームには追従する**
    /// (`CollectionStore.reconcileBookIDIfMoved`。FavoriteBook.titleと違い、ユーザーが表示名を
    /// 付け替える操作は無いので、上書きして構わない)。
    var title: String
    var addedAt: Date
    /// コレクション内へ追加された順(小さいほど先)。表示順はCollectionStoreの並び替え設定に
    /// 従うため、現在は表示には使っていない(FavoriteBook.sortOrderと同じ扱い)。
    var sortOrder: Int

    /// カバー画像の抽出状態(CollectionCoverStatusのrawValue)。
    var coverStatus: Int = 0
    /// 保存してあるカバー画像の縦横比(幅 ÷ 高さ)。0 = まだ抽出できていない。
    ///
    /// カバーは**切らずに**保存し、枠の比(ライブラリごと)へ合わせるのは表示のたびに行う
    /// (CoverImageResolver.cropped(_:to:anchor:)のコメント参照)。この値を行に持っておくのは、
    /// メタデータ編集で「残す位置」の指定が効くかどうかを、画像を復号せずに判定するため。
    var coverAspect: Double = 0

    /// 所属コレクション。
    var collection: BookCollection?

    /// 登録時点のファイルノード識別子。同一ボリューム内での移動・リネームに追従するために
    /// 使う(FavoriteBook.inodeNumberと同じ役割。CollectionStore.reconcileBookIDIfMoved参照)。
    var inodeNumber: Int64?
    var volumeDeviceNumber: Int64?

    init(
        bookID: String,
        bookmarkData: Data,
        title: String,
        collection: BookCollection?,
        sortOrder: Int = 0,
        fileNodeIdentifier: FileNodeIdentifier? = nil
    ) {
        self.id = UUID()
        self.bookID = bookID
        self.bookmarkData = bookmarkData
        self.title = title
        self.collection = collection
        self.sortOrder = sortOrder
        self.addedAt = Date()
        self.coverStatus = CollectionCoverStatus.pending.rawValue
        self.coverAspect = 0
        self.inodeNumber = fileNodeIdentifier?.inodeNumber
        self.volumeDeviceNumber = fileNodeIdentifier?.volumeDeviceNumber
    }

    /// inodeNumber/volumeDeviceNumberが両方揃っている場合のみFileNodeIdentifierとして返す
    /// (FavoriteBook.fileNodeIdentifierと同じ)。
    var fileNodeIdentifier: FileNodeIdentifier? {
        guard let inodeNumber, let volumeDeviceNumber else { return nil }
        return FileNodeIdentifier(inodeNumber: inodeNumber, volumeDeviceNumber: volumeDeviceNumber)
    }

    /// 保存済みのrawValueを列挙型として読む(未知の値は`.pending`として扱い、抽出をやり直させる)。
    var coverState: CollectionCoverStatus {
        get { CollectionCoverStatus(rawValue: coverStatus) ?? .pending }
        set { coverStatus = newValue.rawValue }
    }
}

// Identifiableへの明示的な適合は付けていない(FavoriteFolder.swiftと同じ理由)。

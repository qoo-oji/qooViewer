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
    /// 登録時のファイル/フォルダ名。グリッドには表示せず、ツールチップ(`.help`)と
    /// 「本が見つかりません」のアラートでだけ使う。
    var title: String
    var addedAt: Date
    /// コレクション内へ追加された順(小さいほど先)。表示順はCollectionStoreの並び替え設定に
    /// 従うため、現在は表示には使っていない(FavoriteBook.sortOrderと同じ扱い)。
    var sortOrder: Int

    /// カバー画像の抽出状態(CollectionCoverStatusのrawValue)。
    var coverStatus: Int = 0
    /// 抽出したカバーの**どこを切ったか**(CoverCropSideのrawValue)。
    ///
    /// 横長の画像は縦長(2:3)へトリミングして保存する(CoverImageResolver.croppedForGrid)。
    /// どちら側を残したかを覚えておくのは、読み方向の既定が変わったときに「作り直すべき本」を
    /// 選び出すため ―― 切っていない(=縦長だった)カバーは読み方向が変わっても変化しない。
    var coverCropSide: Int = 0

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
        self.coverCropSide = CoverCropSide.none.rawValue
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

    var coverCrop: CoverCropSide {
        get { CoverCropSide(rawValue: coverCropSide) ?? .none }
        set { coverCropSide = newValue.rawValue }
    }
}

// Identifiableへの明示的な適合は付けていない(FavoriteFolder.swiftと同じ理由)。

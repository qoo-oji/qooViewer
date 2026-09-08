import Foundation
import SwiftData

/// ウェルカム画面の上部の帯に並ぶ「ライブラリ」。コレクション(BookCollection)を束ねるだけの
/// 器で、本を直接持つことはない(改善要望5)。
///
/// お気に入りのFavoriteFolderと違い、階層は作れない(ライブラリ → コレクション → 本、の
/// 2段で固定)。ユーザーが「マンガ」「同人誌」「資料」のように大きく分けるためのもので、
/// それ以上の入れ子は棚の一覧としてかえって扱いにくい、という判断による
/// (検討メモ library-collections-study.md §2.1)。
///
/// `@Attribute(.unique)`は付けない。FavoriteBook/Bookmark/BookLayoutSettingsと同じ理由で、
/// 同じModelContextへ短時間に連続してinsert()+save()すると既存の無関係な行が消えて見える
/// 不具合を踏んでいる(詳細はBookmark.swiftのコメント参照)。idはinit時に毎回`UUID()`で
/// 新規生成するだけなので、SwiftData側の一意制約に頼る必要は元々無い。
/// 名前の重複はCollectionStore.hasLibraryNamed(_:excluding:)がアプリ側で防ぐ。
@Model
final class BookLibrary {
    var id: UUID
    var name: String
    /// 帯に並ぶ順(作成順)。手動での並べ替えは用意していないが、FavoriteFolder.sortOrderと
    /// 同じく値自体は持っておく(将来ドラッグで並べ替えられるようにする場合に備えて)。
    var sortOrder: Int
    var createdAt: Date

    /// このライブラリに属するコレクション。ライブラリを削除したら中のコレクションも
    /// 連鎖して削除する(その先のCollectionItemもBookCollection.items側のcascadeで消える)。
    @Relationship(deleteRule: .cascade, inverse: \BookCollection.library)
    var collections: [BookCollection] = []

    init(name: String, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }
}

// Identifiableへの明示的な適合は付けていない(FavoriteFolder.swiftと同じ理由。
// SwiftUI側では`ForEach(..., id: \.id)`のように明示的にidを指定して使う)。

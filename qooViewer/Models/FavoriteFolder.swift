import Foundation
import SwiftData

/// お気に入りを整理するためのフォルダ。フォルダ同士は親子関係(自己参照)を持ち、階層構造を作る。
/// 階層の深さの上限はFavoritesLimits.maxFolderDepthで管理する(このモデル自体には上限は持たせない。
/// 上限チェックはFavoritesStore側で、フォルダを作成しようとした時点で行う)。
@Model
final class FavoriteFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    /// 同じ階層内へ登録/移動された順番(小さいほど先)。現在は表示の並び替えには使っていない
    /// (表示順はFavoritesStore.sortOption/foldersAlwaysOnTopに従う。FavoriteBook.sortOrderの
    /// コメントと同じ理由)。
    var sortOrder: Int
    var createdAt: Date
    /// 最後に更新された日時。並び替え基準「更新順」に使う。このフォルダ「直下」への
    /// お気に入り/サブフォルダの追加・移動・削除のたびに更新される(FavoritesStoreの
    /// createFolder/forceAddFavorite/move/deleteの各メソッド参照)。フォルダ自身がよそへ
    /// 移動されたりリネームされたりしただけでは更新しない(このフォルダの中身自体は
    /// 変わっていないため)。作成時点ではcreatedAtと同じ値。
    ///
    /// `= Date()`という宣言時のデフォルト値は、FavoriteBook.updatedAtと同じ理由で必須
    /// (この属性を後から追加したことによるライトウェイトマイグレーションのため。詳細は
    /// FavoriteBook.updatedAtのコメント参照)。
    var updatedAt: Date = Date()

    /// 親フォルダ。nilならルート直下のフォルダを表す。
    var parent: FavoriteFolder?

    /// このフォルダの直下にあるサブフォルダ一覧。親フォルダが削除されたら配下のフォルダも
    /// 連鎖して削除する(cascade)。
    @Relationship(deleteRule: .cascade, inverse: \FavoriteFolder.parent)
    var children: [FavoriteFolder] = []

    /// このフォルダに直接登録されているお気に入り一覧。フォルダが削除されたら、
    /// その配下のお気に入り登録(ブックマークデータそのもの)も一緒に削除する。
    @Relationship(deleteRule: .cascade, inverse: \FavoriteBook.folder)
    var books: [FavoriteBook] = []

    init(name: String, parent: FavoriteFolder? = nil, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.parent = parent
        self.sortOrder = sortOrder
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }

    /// ルートから自分自身までの深さ。ルート直下のフォルダを1階層目として数える
    /// (FavoritesLimits.maxFolderDepth = 3 の場合、ルート直下・その子・その孫の3階層まで作成できる)。
    var depth: Int {
        var count = 1
        var current = parent
        while let p = current {
            count += 1
            current = p.parent
        }
        return count
    }

    /// ルートからこのフォルダまでの名前の並び(パンくず表示用)。
    /// 例: ["マイフォルダ", "少年漫画"]
    var pathComponents: [String] {
        // insert(at: 0)は毎回残り全要素をずらすためO(n^2)になる。末尾へのappendだけで
        // 「自分から根へ」の順に集め、最後に反転して「根から自分へ」の順(従来と同じ結果)にする。
        var names: [String] = [name]
        var current = parent
        while let p = current {
            names.append(p.name)
            current = p.parent
        }
        names.reverse()
        return names
    }

    /// UIで「マイフォルダ ＞ 少年漫画」のように表示するためのパンくず文字列。
    var breadcrumb: String {
        pathComponents.joined(separator: " \u{203A} ")
    }
}

// Identifiableへの明示的な適合は付けていない(付けるとMainActor自動分離の影響で
// 「Type 'FavoriteFolder' does not conform to protocol 'PersistentModel'」という
// ビルドエラーになった。nonisolatedを付けても解消しなかったため、Identifiableを
// 諦める方針にした)。idプロパティ自体は普通に公開されているので、SwiftUI側では
// `ForEach(..., id: \.id)`のように明示的にidを指定して使う(FavoritesStore.swiftを
// 参照する各Viewファイル参照)。

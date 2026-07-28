import Foundation
import SwiftData

/// お気に入りを整理するためのフォルダ。フォルダ同士は親子関係(自己参照)を持ち、階層構造を作る。
/// 階層の深さの上限はFavoritesLimits.maxFolderDepthで管理する(このモデル自体には上限は持たせない。
/// 上限チェックはFavoritesStore側で、フォルダを作成しようとした時点で行う)。
@Model
final class FavoriteFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    /// 同じ階層内での並び順(小さいほど上に表示)。
    var sortOrder: Int
    var createdAt: Date

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
        self.createdAt = Date()
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
        var names: [String] = [name]
        var current = parent
        while let p = current {
            names.insert(p.name, at: 0)
            current = p.parent
        }
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

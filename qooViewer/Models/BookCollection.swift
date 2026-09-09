import Foundation
import SwiftData

/// ライブラリ(BookLibrary)の中に並ぶ「コレクション」。本(CollectionItem)を束ねた1つの棚で、
/// ウェルカム画面ではカバー画像3×2のタイルとして描かれる(改善要望5)。
///
/// `@Attribute(.unique)`を付けない理由はBookLibraryと同じ。同じライブラリ内での名前の重複は
/// CollectionStore.hasCollectionNamed(_:in:excluding:)がアプリ側で防ぐ(別のライブラリなら
/// 同名でよい)。
@Model
final class BookCollection {
    var id: UUID
    var name: String
    var createdAt: Date
    /// 最後に中身が変わった日時。本の追加・削除・コレクションのリネームで更新する
    /// (並び替え基準「更新順」用。FavoriteFolder.updatedAtと同じ考え方だが、あちらと違い
    /// リネームでも更新する ―― コレクションは名前そのものが棚の見出しであるため)。
    var updatedAt: Date

    /// 所属ライブラリ。ライブラリは必ず1つ以上存在する(CollectionStore.ensureDefaultLibrary)
    /// ため実質非nilだが、SwiftDataの逆リレーションはOptionalで持つ必要がある。
    var library: BookLibrary?

    /// このコレクションに入っている本。コレクションを削除したら中身も連鎖して削除する。
    /// **カバー画像のファイル(CollectionCoverStore)は連鎖しない**ので、削除する側が
    /// 消える前にitemのidを集めてcoverStore.remove(_:)を呼ぶこと(CollectionStore.delete参照)。
    @Relationship(deleteRule: .cascade, inverse: \CollectionItem.collection)
    var items: [CollectionItem] = []

    /// **自動登録フォルダ**(ユーザー要望 2026-09-09)。このフォルダの直下に並んだ本を、
    /// ウェルカム画面を見にきたタイミングで自動的にこのコレクションへ足す
    /// (走査はCollectionAutoFolderScanner)。nil = 自動登録なし。
    ///
    /// ■ なぜセキュリティスコープ付きブックマークではなく**パスの文字列**なのか
    /// このアプリでフォルダを列挙する権限は、すべてFolderAccessStoreが一手に持っている
    /// (許可済みフォルダのブックマークをUserDefaultsへ保存し、その配下すべてを起動中ずっと
    /// 開いたままにする。FolderAccessStore.accessedURLsByPathのコメント参照)。ここに別の
    /// ブックマークを持たせると、同じフォルダの権限を2箇所が別々に開閉することになり、
    /// 過去に漏れを出したのと同じ形になる。走査する側はFolderAccessStore.isPathCoveredで
    /// 「いま列挙してよいか」を訊き、覆われていなければ黙って見送る(設定の面が
    /// 「アクセスを許可」を出す)。
    ///
    /// 代償として、フォルダを移動・リネームすると自動登録は静かに止まる。設定の面には
    /// 常にパスが出ているので、選び直せば直る。
    ///
    /// **属性の後追加なのでOptional**(SwiftDataの軽量マイグレーション。既存の行はnil =
    /// 自動登録なしで入る)。
    var autoFolderPath: String?

    /// 自動登録フォルダ(nil = 自動登録なし)。
    var autoFolderURL: URL? {
        get { autoFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { autoFolderPath = newValue?.path }
    }

    init(name: String, library: BookLibrary?) {
        self.id = UUID()
        self.name = name
        self.library = library
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}

/// ライブラリ・コレクション・その中の本の変更を、変更した側以外のウインドウへも伝えるための
/// 通知名(Notification.Name.bookmarksDidChange / .layoutDataDidChangeと同じ考え方)。
///
/// userInfoの`"bookID"`(String)には、**本に関わる変更**(追加・削除・カバーの抽出結果)の
/// ときだけ、その本のbookIDを入れる。ライブラリ/コレクション自体の作成・リネーム・削除では
/// userInfoを付けない。
extension Notification.Name {
    static let collectionsDidChange = Notification.Name("qooViewer.collectionsDidChange")
}

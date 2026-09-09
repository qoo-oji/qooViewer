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
    /// ユーザーが付けた名前。**既定のライブラリでは読まない**(`displayName(language:)`参照)。
    var name: String
    /// 帯に並ぶ順(作成順)。手動での並べ替えは用意していないが、FavoriteFolder.sortOrderと
    /// 同じく値自体は持っておく(将来ドラッグで並べ替えられるようにする場合に備えて)。
    var sortOrder: Int
    var createdAt: Date

    /// **まだ名前を付けていない**、アプリが自分で作った既定のライブラリか(ユーザー報告:
    /// 帯が「Library」と英語のまま)。
    ///
    /// 名前をDBの文字列として持つと、**作った時点の文字列がそのまま残る** ―― 日本語訳を
    /// 入れる前のビルドで一度起動していると英語のままになり、表示言語を切り替えても直らない。
    /// そこで、アプリが仮に付けた見出しは「名前を持たない」ことにして、表示のたびに
    /// 表示言語で組み立てる(`displayName(language:)`)。ユーザーが名前を付けた時点で
    /// falseになり、以後その文字列だけを使う(CollectionStore.rename)。
    ///
    /// **属性の後追加なので宣言時のデフォルト値が要る**(SwiftDataの軽量マイグレーション)。
    /// 既定値はfalse ―― 既存の行はすべて「名前がある」として入り、そのうち既定名のままの
    /// ものだけをCollectionStore.adoptDefaultLibraryName()が拾い直す。
    var usesDefaultName: Bool = false

    /// 表示・書き出し・重複判定に使う名前。既定のライブラリだけ、DBの文字列ではなく
    /// 表示言語の訳を返す(型コメント参照)。
    ///
    /// - Parameter language: 表示言語のLocale。ビューは`@Environment(\.locale)`、
    ///   それ以外は`AppLanguage.currentLocale`(Localization の決まりごと。CLAUDE.md)。
    func displayName(language: Locale) -> String {
        usesDefaultName ? Self.defaultName(language: language) : name
    }

    /// 既定のライブラリの見出し。
    static func defaultName(language: Locale) -> String {
        String(localized: "Library", language: language)
    }

    /// 表示言語ごとの既定名すべて。
    static var allDefaultNames: Set<String> {
        Set(AppLanguage.allCases.map { defaultName(language: $0.locale) })
    }

    /// 名前の重複判定(CollectionStore.hasLibraryNamed)で塞ぐ名前。
    ///
    /// 既定のライブラリは**すべての言語の既定名を塞ぐ**。日本語表示で「ライブラリ」を別に
    /// 作れてしまうと、表示言語を英語へ切り替えた瞬間に同じ名前が2つ帯に並ぶため。
    var occupiedNames: Set<String> {
        var names: Set<String> = [name.trimmingCharacters(in: .whitespacesAndNewlines)]
        if usesDefaultName { names.formUnion(Self.allDefaultNames) }
        return names
    }

    /// このライブラリのカバーを並べるときの縦横比(ユーザー要望 2026-09-09)。
    /// CoverAspectRatio.rawValue("portrait" = 2:3 / "square" = 1:1)を保存する。
    ///
    /// **ライブラリ単位**にしてある理由と、`.square`を足した動機はCoverAspectRatioの
    /// コメント参照。**属性の後追加なので宣言時のデフォルト値が要る**(SwiftDataの軽量
    /// マイグレーション)。既存の行はすべて従来どおりの2:3で入る。
    var coverAspectRatioRaw: String = CoverAspectRatio.portrait.rawValue

    /// 画像の比が上の枠と違うとき、既定でどこを残すか。CoverCropAnchor.rawValueを保存する。
    ///
    /// 本ごとの上書き(BookLayoutSettings.coverCropAnchorRaw)があればそちらが勝つ。
    /// こちらは非Optional ―― ライブラリは「従う先」がこれ以上無い一番外側なので、
    /// 「未設定」の状態を持たせず必ず具体的な値にしておく。既定は中央。
    var coverCropAnchorRaw: String = CoverCropAnchor.center.rawValue

    /// **もう読み書きしていない属性。** コレクションの札の地の色をライブラリごとに持って
    /// いたときの名残で、スキーマのマイグレーションを起こさないためだけに残してある
    /// (BookLayoutSettings.hasEpubLayoutLockと同じ扱い)。
    ///
    /// 札の地の色はアプリ全体で1つの設定になり、環境設定「外観」→「パネル」→
    /// 「ウェルカム画面」→「ライブラリ」へ移した(ユーザー指示 2026-09-09。経緯は
    /// AppPreferences.collectionTileBackgroundColor参照)。
    var coverBackgroundColorRaw: String?

    /// このライブラリに属するコレクション。ライブラリを削除したら中のコレクションも
    /// 連鎖して削除する(その先のCollectionItemもBookCollection.items側のcascadeで消える)。
    @Relationship(deleteRule: .cascade, inverse: \BookCollection.library)
    var collections: [BookCollection] = []

    /// カバーの縦横比。保存済みの値が読めない(将来caseを消した等)ときは既定の2:3。
    var coverAspectRatio: CoverAspectRatio {
        get { CoverAspectRatio(rawValue: coverAspectRatioRaw) ?? .portrait }
        set { coverAspectRatioRaw = newValue.rawValue }
    }

    /// 画像の比が枠と違うときに残す位置(既定は中央)。旧「自動」時代の値の読み替えは
    /// CoverCropAnchor.stored(_:)が行う。
    var coverCropAnchor: CoverCropAnchor {
        get { CoverCropAnchor.stored(coverCropAnchorRaw) ?? .center }
        set { coverCropAnchorRaw = newValue.rawValue }
    }


    /// - Parameter usesDefaultName: アプリが自分で作った既定のライブラリならtrue
    ///   (CollectionStore.ensureDefaultLibraryだけが渡す)。`name`にはそのときの表示言語の
    ///   既定名を入れておく ―― 表示には使わないが、列を空にしないため、また古いビルドや
    ///   書き出しJSONから読んだときに名前が消えて見えないようにするため。
    init(name: String, sortOrder: Int = 0, usesDefaultName: Bool = false) {
        self.id = UUID()
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.usesDefaultName = usesDefaultName
    }
}

// Identifiableへの明示的な適合は付けていない(FavoriteFolder.swiftと同じ理由。
// SwiftUI側では`ForEach(..., id: \.id)`のように明示的にidを指定して使う)。

import Foundation
import SwiftData

/// ページ単位のレイアウト設定(2.2節: 単一ページ/見開き右/見開き左/除外)。SwiftDataで永続化する。
/// `Bookmark`と同じく、本ごとにこの行が対象ページの数だけ複数存在しうる。
///
/// `bookID`だけでは一意にならない(1本の中に複数ページがある)ため、`bookID`と`pageKey`を
/// 合成した`compositeKey`を持たせている。
///
/// `pageKey`には`PageRef.sortKey`をそのまま使う(アーカイブなら内部エントリパス、フォルダなら
/// ファイルの絶対パス、PDFならゼロ埋めしたページ番号。詳細はBookLoader.swift参照)。
/// EPUBのPageRef.sortKeyは連番(spineのインデックス)であり本来のファイル名を持たないが、
/// この機能の対象はEPUB以外(フォルダ・zip/cbz・rar/cbr・7z/cb7・PDF)のため問題にならない
/// (EPUBは自身のpackage documentが権威的なレイアウト指定を持つため、PageLayoutOverrideの
/// 対象外。詳細は設計コンセプト2.4節「優先順位」参照)。
///
/// 以前はcompositeKeyに`@Attribute(.unique)`の一意制約を付けていたが、これを外した。
/// 「1ページ目をthisPageOnlyで設定した直後、間を置かずに2ページ目もthisPageOnlyで設定すると、
/// 1ページ目(と、2ページ目自身)の設定が消え、最後に書き込んだページの設定だけが残る」という
/// 不具合(ユーザー報告。ビューアウインドウが開いているかどうか、別の本を表示しているかどうかに
/// 関わらず、この編集ウインドウ単体の操作だけで再現することが確認された)を切り分けた結果、
/// 「同じModelContextに対して短時間に複数回、@Attribute(.unique)を持つ同じエンティティ型の
/// 行をinsert()+save()する」というパターンが疑わしいと判断した(SwiftDataの一意制約付き
/// upsert処理に起因すると思われる、既知のフレームワーク側の不具合カテゴリと一致する)。
/// 一意性自体は元々アプリ側でも保証している(setPageLayoutState/setPageLayoutStatesが、
/// insertする前に必ずpageOverride(forBookID:pageKey:)/pageOverrides(forBookID:)で
/// 既存行の有無を確認してから分岐しているため、同じ(bookID, pageKey)の組み合わせで重複行が
/// 作られることは無い)ため、SwiftData側の一意制約に頼る必要が無い。
@Model
final class PageLayoutOverride {
    /// bookID + pageKeyを合成したキー(重複防止用のDB制約としてではなく、デバッグ・ログ表示上の
    /// 識別子として残している)。区切り文字にはパス文字列に出現しないNUL文字を使う
    /// (makeCompositeKey参照)。
    var compositeKey: String
    var bookID: String
    var pageKey: String
    var stateRaw: String
    var updatedAt: Date = Date()

    init(bookID: String, pageKey: String, state: PageLayoutState) {
        self.bookID = bookID
        self.pageKey = pageKey
        self.stateRaw = state.rawValue
        self.compositeKey = Self.makeCompositeKey(bookID: bookID, pageKey: pageKey)
        self.updatedAt = Date()
    }

    var state: PageLayoutState {
        get { PageLayoutState(rawValue: stateRaw) ?? .single }
        set {
            stateRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    /// bookIDとpageKeyはどちらも任意のファイルパス/エントリパス由来の文字列で、区切りに
    /// 使えそうな"/"や"#"は普通に出現しうる。ファイルパスに現れることのないNUL文字(\u{0})を
    /// 区切りに使うことで、異なる(bookID, pageKey)の組み合わせが同じcompositeKeyに
    /// 衝突することを避ける。
    static func makeCompositeKey(bookID: String, pageKey: String) -> String {
        "\(bookID)\u{0}\(pageKey)"
    }
}

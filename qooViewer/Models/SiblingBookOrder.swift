import Foundation

/// 「次の本へ」「前の本へ」と、ファイルメニューの「同じフォルダのファイルを開く」が、同じ
/// フォルダの中にある本を**どう並べ、どう辿るか**の決め方一式(ユーザー要望: 移動する順番を
/// サイドパネル上段のフォルダブラウザの並べ替えに合わせたい)。
///
/// この2つの機能は同じ一覧を見ているが、使い方が違う。
///   ・「同じフォルダのファイルを開く」は一覧をそのまま全件並べる → `sort`だけを使う
///   ・「次の本へ」「前の本へ」は一覧の中を1歩ずつ動く → `restrictsToSameType`も効く
///
/// nonisolated: 実際に一覧を組み立てるSiblingFinder/DirectoryBrowserがnonisolated enum
/// (メインスレッド外のTask.detachedから使う)のため、そこから読める必要がある。プロジェクト
/// 既定の「Default Actor Isolation = MainActor」の対象外にする理由はArchiveReading.swift冒頭の
/// コメント参照。
nonisolated struct SiblingBookOrder: Equatable, Hashable {
    /// 一覧の並べ替え。フォルダブラウザ(DirectoryBrowser)へ渡すものとまったく同じ値なので、
    /// パネルに見えている並びと、移動する順番が必ず一致する。
    var sort: FolderBrowserSort

    /// 「次の本へ」「前の本へ」の移動を、今開いている本と同じ側(フォルダの本同士 /
    /// ファイルの本同士)に限るかどうか。
    ///
    /// 名前順に固定していた頃からの挙動(種類の異なる本を挟まない)を表す。ブラウザの並び順に
    /// 合わせる設定をONにしたときはfalseになり、パネルに見えているとおりフォルダの本と
    /// ファイルの本を混ぜて1行ずつ辿る(ユーザーの指示: 「パネルの並びをそのまま辿る」)。
    ///
    /// **「同じフォルダのファイルを開く」の一覧には効かない。** あちらは従来から種類を問わず
    /// 全件を並べており、一覧するだけで「次はどこへ行くか」を決めるものではないため。
    var restrictsToSameType: Bool

    /// フォルダブラウザの並べ替えに合わせない場合 ―― 設定がOFFのとき、およびサイドパネル機能
    /// 自体がOFFのとき(AppPreferences.siblingBookOrder参照)。
    ///
    /// 並べ替えそのものはDirectoryBrowserに任せる(SiblingFinderの型コメント参照)ので、
    /// フォールバックも`FolderBrowserSort`の値として表す。これで「名前順」の意味がフォルダ
    /// ブラウザと1つに揃い、比較の規則が2箇所に散らばらない。
    ///
    /// ■ グループ分けが`FolderBrowserSort.default`(= `.foldersFirst`)ではない理由
    /// フォールバックは**サイドパネルの設定から完全に独立した「名前順」**でなければならない
    /// (サイドパネル機能をOFFにしている人にも同じ並びを返す必要がある)。フォルダを先に
    /// まとめるのは名前順とは別の軸なので、ここでは掛けない。実際、これが効くのは
    /// 「同じフォルダのファイルを開く」の一覧だけで(「次の本へ」「前の本へ」は
    /// `restrictsToSameType`によってそもそもどちらか一方しか並ばない)、`.mixedByName`に
    /// しておくことで、この設定を入れる前とまったく同じ「全部まとめて名前順」になる。
    ///
    /// ■ 名前の比較だけは従来と変わる
    /// この設定を入れる前の名前順は`lastPathComponent`の`.numeric`比較で、ロケールを見ず
    /// 大文字始まりの名前がすべて小文字始まりより先に来ていた。DirectoryBrowserの
    /// `localizedStandardCompare`へ揃えたことで、Finderやアプリ内の他の一覧と同じ並びになる
    /// 代わりに、その点だけ従来と並びが変わる(ユーザーの判断。フォルダブラウザ自身も、
    /// 並べ替え機能を入れたときに同じ乗り換えをしている ―― DirectoryBrowser.compare参照)。
    static let byName = SiblingBookOrder(
        sort: FolderBrowserSort(grouping: .mixedByName, key: .name, direction: .ascending),
        restrictsToSameType: true
    )

    /// フォルダブラウザの並べ替えにそのまま合わせる場合。
    static func followingFolderBrowser(_ sort: FolderBrowserSort) -> SiblingBookOrder {
        SiblingBookOrder(sort: sort, restrictsToSameType: false)
    }
}

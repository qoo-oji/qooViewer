import SwiftUI

/// サイドパネル上段(フォルダブラウザ)で、フォルダとファイルをどう並べるかの設定(ユーザー要望)。
///
/// 下段(本の中身ブラウザ)には効かない。あちらの並びは常に本のページ順そのもので、
/// フォルダを上にまとめる余地を持たせない(理由はAppPreferences.sidePanelSortOrderの
/// コメント参照)。
enum SidePanelSortOrder: String, CaseIterable, Identifiable, Codable, Hashable {
    /// フォルダをまとめて上に表示し、フォルダ・ファイルそれぞれの中では名前順に並べる
    /// (Finderと同じ考え方)。
    case foldersFirst
    /// フォルダ・ファイルを区別せず、すべて名前順に混ぜて並べる。
    case mixedByName

    var id: String { rawValue }
}

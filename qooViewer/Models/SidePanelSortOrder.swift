import SwiftUI

/// サイドパネル(上段のフォルダブラウザ、下段の本の中身ブラウザのどちらも)で、フォルダと
/// ファイルをどう並べるかの設定(ユーザー要望)。
enum SidePanelSortOrder: String, CaseIterable, Identifiable, Codable, Hashable {
    /// フォルダをまとめて上に表示し、フォルダ・ファイルそれぞれの中では名前順に並べる
    /// (Finderと同じ考え方)。
    case foldersFirst
    /// フォルダ・ファイルを区別せず、すべて名前順に混ぜて並べる。
    case mixedByName

    var id: String { rawValue }
}

import SwiftUI

/// サイドパネルの表示モード(ユーザー要望: パネル最上部のスイッチで、ワンクリックで直接
/// 切り替えられるようにする)。将来モードを増やす場合もここへcaseを追加すれば、スイッチ
/// (SidePanelModeSwitcher)は`allCases`をそのまま並べるだけなので追随する。
enum SidePanelMode: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 従来のサイドパネル。上段=フォルダブラウザ、下段=本の中身ブラウザ。
    case browser
    /// 上段=お気に入りのツリー、下段=今開いている本のブックマーク一覧。
    case bookmarks

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .browser: return "Browser"
        case .bookmarks: return "Bookmarks"
        }
    }

    /// スイッチのボタンに表示するアイコン。ツールバーのお気に入り/ブックマークのアイコン
    /// (ViewerView参照: star/bookmark)と揃えたいが、ブックマークモードはお気に入りと
    /// ブックマークの両方を含むため、より広い意味を持つ"star"側は使わず、モード名と一致する
    /// "bookmark"にしている。
    var systemImage: String {
        switch self {
        case .browser: return "folder"
        case .bookmarks: return "bookmark"
        }
    }
}

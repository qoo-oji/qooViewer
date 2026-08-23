import SwiftUI

/// サイドパネルの表示モード(ユーザー要望: パネル最上部のスイッチで、ワンクリックで直接
/// 切り替えられるようにする)。将来モードを増やす場合もここへcaseを追加すれば、スイッチ
/// (SidePanelModeSwitcher)は`allCases`をそのまま並べるだけなので追随する。
enum SidePanelMode: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 従来のサイドパネル。上段=フォルダブラウザ、下段=本の中身ブラウザ。
    case browser
    /// 上段=お気に入りのツリー、下段=今開いている本のブックマーク一覧。
    case bookmarks
    /// 最近開いた本の履歴一覧(上下の分割は持たず、1つの一覧で全高を使う)。
    case history
    /// 今開いている本のページ一覧(サムネイル付き。履歴モードと同じく1つの一覧で全高を使う)。
    case pages
    /// このアプリのリソース消費(CPU・メモリ・ディスクのグラフ、本のキャッシュ、ディスク容量、
    /// 検出した異常)。履歴モードと同じく1列で全高を使う(SidePanelResourcesSectionView参照)。
    case resources

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .browser: return "Browser"
        case .bookmarks: return "Bookmarks"
        case .history: return "History"
        case .pages: return "Pages"
        case .resources: return "Resources"
        }
    }

    /// スイッチのボタンに表示するアイコン。ツールバーのお気に入り/ブックマークのアイコン
    /// (ViewerView参照: star/bookmark)と揃えたいが、ブックマークモードはお気に入りと
    /// ブックマークの両方を含むため、より広い意味を持つ"star"側は使わず、モード名と一致する
    /// "bookmark"にしている。リソースモードは、最初は計器(gauge)だったが履歴の時計と
    /// 見分けにくいとの指摘で折れ線グラフにした(中身もグラフが主役)。
    var systemImage: String {
        switch self {
        case .browser: return "folder"
        case .bookmarks: return "bookmark"
        case .history: return "clock"
        case .pages: return "photo.on.rectangle"
        case .resources: return "chart.xyaxis.line"
        }
    }
}

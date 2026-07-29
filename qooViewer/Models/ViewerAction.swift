import SwiftUI

/// キーボード/マウスに割り当てられる操作の一覧。
/// キー設定・マウス設定の両方から共通で参照する。
///
/// rawValue はケース名そのまま(例: "spatialLeft")を使い、UserDefaults/JSONへの永続化用の
/// 安定した識別子として扱う。画面に表示する名前は displayLanguage 設定に応じて切り替わる必要が
/// あるため、下の titleKey (LocalizedStringKey) を使う。rawValueに日本語を直接使ってしまうと、
/// 表示言語を切り替えたときに保存済みのキー割り当てデータの互換性が壊れてしまうため、
/// 表示名と永続化用の識別子をこのように分離している。
enum ViewerAction: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 画面の左方向へページを送る(読み方向により「次」「前」いずれかになる)
    case spatialLeft
    /// 画面の右方向へページを送る(読み方向により「次」「前」いずれかになる)
    case spatialRight
    /// 読み方向(右開き/左開き)に関わらず、常に物語的な「次のページ」へ進む。
    /// spatialLeft/spatialRightが画面上の位置(左右)を基準にするのに対し、こちらは
    /// 常に同じ意味(次/前)になる。マウスホイールのように、画面上の位置とは無関係に
    /// 「進む/戻る」という一定の操作感を期待される入力に向く(メニューバーの「移動」メニュー
    /// 「次へ移動」と同じ考え方。QooViewerApp.swift・ViewerView.swiftのcontextMenuContent参照)。
    case moveNext
    /// 読み方向に関わらず、常に物語的な「前のページ」へ戻る。moveNext参照。
    case movePrevious
    /// 見開き/単ページ設定にかかわらず、常にちょうど1ページだけ左方向へ送る。
    /// 見開きのページの組み合わせ(奇数/偶数ペア)がずれたときの調整用
    case shiftOnePageLeft
    /// 見開き/単ページ設定にかかわらず、常にちょうど1ページだけ右方向へ送る(調整用)
    case shiftOnePageRight
    case firstPage
    case lastPage
    /// 数字キー(0〜9)によるページジャンプ。0キーは先頭ページ(0%)、9キーは
    /// 全ページ数の90%に相当するページへジャンプする(以降10%刻み)。
    /// ページ番号は `全ページ数 * (キーの数字 * 10) / 100` を切り捨てて求める
    /// (KeyBindingStore.defaultKeyBindingsで0〜9の数字キーに既定で割り当てている)。
    case jumpToPercentile0
    case jumpToPercentile10
    case jumpToPercentile20
    case jumpToPercentile30
    case jumpToPercentile40
    case jumpToPercentile50
    case jumpToPercentile60
    case jumpToPercentile70
    case jumpToPercentile80
    case jumpToPercentile90
    case toggleDisplayMode
    case toggleReadingDirection
    case cycleScalingMode
    case previousBook
    case nextBook
    /// 現在のページのブックマークを追加/削除する(付いていなければ追加、付いていれば削除する、
    /// 1つのボタン/ショートカットにまとめたトグル操作)。
    case toggleBookmark
    case nextBookmark
    case previousBookmark
    case showBookmarkList
    case showThumbnailGrid
    case toggleSlideshow
    case showActualSizeLeft
    case showActualSizeRight
    /// 現在の本をお気に入りに追加/削除する(未登録なら登録先フォルダを選ぶダイアログを開いて
    /// 追加し、登録済みなら削除する。複数フォルダに登録されている場合はすべて削除する、
    /// 1つのボタン/ショートカットにまとめたトグル操作)。
    case toggleFavorite
    /// お気に入り一覧を(階層構造のまま)表示する。
    case showFavoritesList
    /// 「お気に入りの整理」ウインドウを開く。
    case showFavoritesOrganizer
    /// 何も割り当てない
    case none

    var id: String { rawValue }

    /// jumpToPercentileNN系のアクションであれば、その割合(0〜90)を返す。それ以外はnil。
    /// ViewerViewModel側でのページ番号計算(全ページ数 * percentile / 100)や、
    /// titleKeyの組み立てに使う。
    var jumpPercentile: Int? {
        switch self {
        case .jumpToPercentile0: return 0
        case .jumpToPercentile10: return 10
        case .jumpToPercentile20: return 20
        case .jumpToPercentile30: return 30
        case .jumpToPercentile40: return 40
        case .jumpToPercentile50: return 50
        case .jumpToPercentile60: return 60
        case .jumpToPercentile70: return 70
        case .jumpToPercentile80: return 80
        case .jumpToPercentile90: return 90
        default: return nil
        }
    }

    /// 設定画面(キー・マウス操作)に表示する名前
    var titleKey: LocalizedStringKey {
        switch self {
        case .spatialLeft: return "Move Left"
        case .spatialRight: return "Move Right"
        case .moveNext: return "Move to Next"
        case .movePrevious: return "Move to Previous"
        case .shiftOnePageLeft: return "Shift One Page Left"
        case .shiftOnePageRight: return "Shift One Page Right"
        case .firstPage: return "Go to First Page"
        case .lastPage: return "Go to Last Page"
        case .jumpToPercentile0: return "Jump to Page at 0% (First Page)"
        case .jumpToPercentile10: return "Jump to Page at 10%"
        case .jumpToPercentile20: return "Jump to Page at 20%"
        case .jumpToPercentile30: return "Jump to Page at 30%"
        case .jumpToPercentile40: return "Jump to Page at 40%"
        case .jumpToPercentile50: return "Jump to Page at 50%"
        case .jumpToPercentile60: return "Jump to Page at 60%"
        case .jumpToPercentile70: return "Jump to Page at 70%"
        case .jumpToPercentile80: return "Jump to Page at 80%"
        case .jumpToPercentile90: return "Jump to Page at 90%"
        case .toggleDisplayMode: return "Toggle Spread/Single Page"
        case .toggleReadingDirection: return "Switch Reading Direction"
        case .cycleScalingMode: return "Cycle Display Mode"
        case .previousBook: return "Previous Book"
        case .nextBook: return "Next Book"
        case .toggleBookmark: return "Toggle Bookmark"
        case .nextBookmark: return "Go to Next Bookmark"
        case .previousBookmark: return "Go to Previous Bookmark"
        case .showBookmarkList: return "Edit Bookmarks…"
        case .showThumbnailGrid: return "Show Page Grid"
        case .toggleSlideshow: return "Start/Stop Slideshow"
        case .showActualSizeLeft: return "Show Left Page at Actual Size"
        case .showActualSizeRight: return "Show Right Page at Actual Size"
        case .toggleFavorite: return "Toggle Favorite"
        case .showFavoritesList: return "Show Favorites List"
        case .showFavoritesOrganizer: return "Edit Favorites…"
        case .none: return "(None)"
        }
    }
}

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
    /// 物語的な先頭ページ(ページ番号1)へ。読み方向に関わらず意味は同じ
    /// (moveNext/movePreviousと同じ考え方)。メニューバー「移動」→「最初へ移動」と
    /// コンテキストメニューの同項目もこれを呼ぶ。
    case firstPage
    /// 物語的な最終ページへ。firstPage参照。
    case lastPage
    /// **画面上でいちばん右に来る端のページ**へ飛ぶ。読み方向により、先頭ページと
    /// 最終ページのどちらになるかが変わる(右開きなら先頭、左開きなら最終)。
    ///
    /// firstPage/lastPageが物語的な先頭/末尾を指すのに対し、こちらは画面上の位置を基準にする
    /// (spatialLeft/spatialRightと同じ考え方の、端まで飛ぶ版)。option+→やoption+クリックの
    /// ように**方向そのものを指し示す入力**に割り当てるためのもので、読み方向を切り替えても
    /// 「右を指したら右端へ」という対応が崩れない。
    ///
    /// 以前はoption+→にfirstPageを割り当てていたが、これは右開きを前提にした固定の対応で、
    /// 左開きの本では矢印の向きと飛び先が逆になっていた(素の←→は実行時に読み方向で反転するのに、
    /// optionを足した途端に反転しなくなる、という非対称があった)。
    case spatialEndRight
    /// spatialEndRightの逆。**画面上でいちばん左に来る端のページ**へ飛ぶ。
    case spatialEndLeft
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
    /// 1画面分スクロールし、スクロールしきっていたら次のページへ進む。
    /// cooViewerの「1画面分下へ+次のページ」(action 27)相当。
    ///
    /// 具体的な動作は3段階(cooViewerのCustomImageView.next/prevと同じ):
    /// 1. まだ下にスクロールできるなら、1画面分下へスクロールする
    /// 2. 下端に着いていて、横にまだ余地があるなら、読み方向へ1画面分ずらして最上部へ戻る
    ///    (単ページ幅に合わせた状態で「右半分を読み終えたら左半分の先頭へ」に相当する)
    /// 3. どちらにも余地が無ければ、次のページへ進む
    ///
    /// スクロールできない「画面内に収める」モードでは1・2が成立しないため、実質的に
    /// moveNextと同じ「次のページへ」になる。この文脈依存の縮退があるおかげで、cooViewerが
    /// モード別のキー設定で実現していた既定の操作感(ノーマルではspace=次のページ、
    /// スクロール可能なモードではspace=1画面分下へ+次のページ)を、同じ1つの割り当てで
    /// 再現できる(KeyBindingStore.modeKeyBindings参照)。
    case scrollAndMoveNext
    /// scrollAndMoveNextの逆方向。cooViewerの「1画面分上へ+前のページ」(action 26)相当。
    /// 前のページへ戻ったときは、そのページの末尾(読み終わり側の隅)から表示を始める
    /// (cooViewerのsetStartFromEnd:YES相当)。
    case scrollAndMovePrevious
    /// scrollAndMoveNext/Previousの「画面上の左右」版。読み方向により、進む/戻るのどちらに
    /// なるかが変わる(spatialLeft/spatialRightと同じ考え方)。
    ///
    /// cooViewerのマウス操作の既定(action 42)は、**1つの割り当てでクリックした側によって
    /// 進む/戻るが決まる**作りになっており、しかもその左右の判定は読み方向で入れ替わる
    /// (Controller_input.mのmouseAction:でreadModeに応じてleft/rightの矩形を入れ替えている)。
    /// qooViewerは左右のクリックゾーンを別々のトリガーとして持つため、同じ操作感を出すには
    /// 「画面左方向へのスクロール送り」「画面右方向へのスクロール送り」という2つの操作が要る。
    case scrollAndMoveSpatialLeft
    /// scrollAndMoveSpatialLeftの逆。
    case scrollAndMoveSpatialRight
    /// 1画面分下へスクロールする(ページ送りはしない)。cooViewerのaction 25相当。
    case scrollScreenDown
    /// 1画面分上へスクロールする(ページ送りはしない)。cooViewerのaction 24相当。
    case scrollScreenUp
    /// 今のページの先頭へスクロールする。読み方向により右上/左上が変わる。
    /// cooViewerの「最初へスクロール」(action 28)相当。
    case scrollToPageStart
    /// 今のページの末尾へスクロールする。読み方向により左下/右下が変わる。
    /// cooViewerの「最後へスクロール」(action 29)相当。
    case scrollToPageEnd
    /// 決まった量だけ上へスクロールする(1画面分ではなく、少しずつ動かすためのもの)。
    /// cooViewerの「上へスクロール」(action 30)相当。移動量は表示モードごとの設定
    /// (KeyBindingStore.scrollStep(in:))で決まる。
    case scrollUp
    /// scrollUpの逆方向。cooViewerの「下へスクロール」(action 31)相当。
    case scrollDown
    /// 決まった量だけ左へスクロールする。cooViewerの「左へスクロール」(action 32)相当。
    /// 原寸表示や「横幅に合わせる(単ページ)」のように横に長い状態で、キーボードから
    /// 横方向へ動かすための操作。
    case scrollLeft
    /// scrollLeftの逆方向。cooViewerの「右へスクロール」(action 33)相当。
    case scrollRight
    case toggleDisplayMode
    case toggleReadingDirection
    case cycleScalingMode
    /// 古いスキャン本を白黒補正して表示する機能(ユーザー要望)のON/OFF。本単位で記憶する
    /// (BookLayoutSettings.contrastCorrectionEnabled)。
    case toggleContrastCorrection
    /// 「現在の表示を基準に自動でレイアウトする」(ツールバーの四角いアイコンのボタン、
    /// メニューバー「Layout」→「Auto-Layout Based on Current View」と同じ操作)。
    /// 本全体を上書きするため、実行すると確認ダイアログを挟む(ViewerView.perform参照)。
    case autoLayoutFromCurrentView
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
    /// カーソル位置を中心に画像の一部を拡大表示する「ルーペ」の表示/非表示を切り替える。
    case toggleLoupe
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

    /// スクロールできる表示モードでしか意味を持たない操作かどうか。
    /// 「入力」タブ(表示モードに依存しない設定、KeyBindingSettingsView)の一覧から外し、
    /// 「入力2」タブ(ModeInputSettingsView)側へ回すための振り分けに使う。
    var isScrollableModeOnly: Bool {
        switch self {
        case .scrollAndMoveNext, .scrollAndMovePrevious,
             .scrollAndMoveSpatialLeft, .scrollAndMoveSpatialRight,
             .scrollScreenDown, .scrollScreenUp, .scrollToPageStart, .scrollToPageEnd,
             .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return true
        default:
            return false
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
        case .spatialEndRight: return "Go to Rightmost Page"
        case .spatialEndLeft: return "Go to Leftmost Page"
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
        case .scrollAndMoveNext: return "Scroll One Screen / Next Page"
        case .scrollAndMovePrevious: return "Scroll One Screen / Previous Page"
        case .scrollScreenDown: return "Scroll Down One Screen"
        case .scrollScreenUp: return "Scroll Up One Screen"
        case .scrollToPageStart: return "Scroll to Page Start"
        case .scrollToPageEnd: return "Scroll to Page End"
        case .scrollAndMoveSpatialLeft: return "Scroll One Screen / Move Left"
        case .scrollAndMoveSpatialRight: return "Scroll One Screen / Move Right"
        case .scrollUp: return "Scroll Up"
        case .scrollDown: return "Scroll Down"
        case .scrollLeft: return "Scroll Left"
        case .scrollRight: return "Scroll Right"
        case .toggleDisplayMode: return "Toggle Spread/Single Page"
        case .toggleReadingDirection: return "Switch Reading Direction"
        case .cycleScalingMode: return "Cycle Display Mode"
        case .toggleContrastCorrection: return "Contrast Correction"
        case .autoLayoutFromCurrentView: return "Auto-Layout Based on Current View"
        case .previousBook: return "Previous Book"
        case .nextBook: return "Next Book"
        case .toggleBookmark: return "Toggle Bookmark"
        case .nextBookmark: return "Go to Next Bookmark"
        case .previousBookmark: return "Go to Previous Bookmark"
        case .showBookmarkList: return "Edit Bookmarks…"
        case .showThumbnailGrid: return "Show Page Grid"
        case .toggleSlideshow: return "Start/Stop Slideshow"
        case .toggleLoupe: return "Toggle Loupe"
        case .showActualSizeLeft: return "Show Left Page at Actual Size"
        case .showActualSizeRight: return "Show Right Page at Actual Size"
        case .toggleFavorite: return "Toggle Favorite"
        case .showFavoritesList: return "Show Favorites List"
        case .showFavoritesOrganizer: return "Edit Favorites…"
        case .none: return "(None)"
        }
    }
}

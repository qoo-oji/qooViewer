import SwiftUI

/// 見開き表示(実際に2ページ組でペア表示されている状態)で、クリック位置の情報が無い経路
/// (ツールバーのボタン、メニューバー「お気に入り」メニュー、キーボードショートカット)から
/// 「現在のページをブックマークに追加」を実行したときに、見開きのどちら側のページを
/// 対象にするかを決める設定(ユーザー要望)。
///
/// コンテキストメニュー(右クリック)からの追加は、常にクリックした側のページを一意に対象にできる
/// ため、この設定の影響を受けない(ViewerView.contextMenuContent参照)。単一ページ表示中
/// (見開きの相方がEPUB仕様上の空白ページのため実際には1枚しか表示していない場合を含む)も、
/// 対象が1ページしかなくどちらのページかを問うまでもないため、この設定の影響を受けない
/// (ViewerView.toggleCurrentPageBookmark参照)。
enum SpreadBookmarkTargetBehavior: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 読み方向に応じた既定側(右開きなら見開き右のページ、左開きなら見開き左のページ)を
    /// 常に対象にする(この設定を導入する以前からの既定の挙動と同じ)
    case defaultSide
    /// 実行するたびに、見開きの左右どちらのページを対象にするかダイアログで尋ねる
    case askEachTime

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .defaultSide: return "Always Use the Default Side (Based on Reading Direction)"
        case .askEachTime: return "Ask Each Time"
        }
    }
}

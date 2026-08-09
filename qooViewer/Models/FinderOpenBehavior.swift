import SwiftUI

/// qooViewerが既に本を表示している状態で、Finderから(ダブルクリックや「このアプリケーションで
/// 開く」で)別の本を開こうとしたときの挙動。まだ本を表示していない(Welcome画面)状態のときは、
/// この設定に関わらず常にそのウインドウでそのまま開く(AppDelegate.application(_:open:)参照)。
enum FinderOpenBehavior: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 現在表示中の本を閉じて、同じウインドウで新しい本を開く(以前からの既定の挙動)
    case replaceCurrentBook
    /// 現在のウインドウに新しいタブとして新しい本を開く
    case newTab
    /// 新しいウインドウで新しい本を開く
    case newWindow

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .replaceCurrentBook: return "Close This Book and Open the New One"
        case .newTab: return "Open in a New Tab"
        case .newWindow: return "Open in a New Window"
        }
    }
}

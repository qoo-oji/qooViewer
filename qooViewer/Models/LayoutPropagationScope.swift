import SwiftUI

/// 3.2節の操作(個別ページへの直接操作。「レイアウト情報を削除する」を除く)、および
/// 4節の編集ウインドウでレイアウト設定を変更した際に選ぶ、伝播範囲(設計コンセプト3.3節)。
enum LayoutPropagationScope: String, CaseIterable, Identifiable {
    /// このページだけ更新する。
    case thisPageOnly
    /// このページを基準に本全体のレイアウトを更新する。
    case wholeBook
    /// このページより前のページ全体を更新する。
    case beforeThisPage
    /// このページより後のページ全体を更新する。
    case afterThisPage

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .thisPageOnly: return "Update This Page Only"
        case .wholeBook: return "Update the Whole Book, Based on This Page"
        case .beforeThisPage: return "Update All Pages Before This One"
        case .afterThisPage: return "Update All Pages After This One"
        }
    }
}

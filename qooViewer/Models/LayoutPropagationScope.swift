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

    /// 基準のページの位置に応じて、意味のある伝播範囲だけに絞り込む(ユーザー報告: 先頭ページ
    /// なのに「このページより前のページ全体」が選択肢に出てしまうのはおかしい)。
    ///
    /// - 先頭のページには「このページより前」を出さない(対象になるページが存在しないため)。
    /// - 末尾のページには「このページより後」を出さない(同上)。
    /// - `index`がnil(対象ページが除外(非表示)中で、まだ読書順の位置を持たない)場合は、
    ///   変更後にどの位置へ入るか事前には分からないため、判定を省略してすべての選択肢を出す
    ///   (安全側に倒す。実害は「前/後を選んでも対象が0件」程度に留まる)。
    ///
    /// **この規則を2か所に書かないこと。** 元はViewerViewとBookmarkListViewにそれぞれ
    /// 書かれていた。「どの位置を基準にするか」だけが違い(ビューアはページ番号、編集
    /// ウインドウは除外ページを除いた読書順の位置)、規則そのものは同じなので、呼び出し側が
    /// 位置を解決してここへ渡す形にまとめてある。
    ///
    /// - Parameters:
    ///   - index: 基準のページの位置。nilなら位置が決まっていない。
    ///   - lastIndex: 同じ空間での末尾の位置。nilなら末尾が決まっていない(=「後」を出さない)。
    static func available(forIndex index: Int?, lastIndex: Int?) -> [LayoutPropagationScope] {
        guard let index else { return allCases }
        return allCases.filter { scope in
            switch scope {
            case .thisPageOnly, .wholeBook: return true
            case .beforeThisPage: return index > 0
            case .afterThisPage: return lastIndex.map { index < $0 } ?? false
            }
        }
    }
}

import AppKit
import SwiftUI

/// 「ブックマークの編集」「お気に入りの整理」ウインドウの左ペイン(サイドバー)の幅を、
/// ウインドウを開いた時点で登録されている項目のフルネームに応じて動的に決めるための計算ロジック。
///
/// 要望: 左ペインの幅が狭く、本/フォルダの名前が省略表示("…")になりがちなので、ウインドウを
/// 開いた時点で登録されている名前の長さに応じて、あらかじめ広めに開いてほしい、というもの。
/// リストの中身は開いた後も増減しうるが、追加・削除のたびに勝手にリサイズされると使い勝手が
/// 悪いため、「ウインドウを開いた時点」の内容だけを見て1回だけ計算する(呼び出し側の
/// onAppearで一度だけ実行する運用を想定)。
enum SidebarWidthEstimator {
    /// サイドバーの1行のうち、名前のテキスト部分以外がおおよそ占める幅
    /// (アイコン・「Now Reading」バッジ・件数・行の左右パディングなど)。
    /// ブックマーク編集画面の本の行(アイコン+バッジ+件数)、お気に入りの整理画面のフォルダ行
    /// (アイコン+ディスクロージャ三角)のどちらで使っても大きく破綻しないよう、
    /// やや余裕を持たせた値にしている。
    private static let baseChromeWidth: CGFloat = 110
    /// 階層が1段深くなるごとに増える、ディスクロージャの字下げ幅のおおよその値
    /// (お気に入りの整理画面のフォルダツリー用。ブックマーク編集画面のように階層が無い場合は
    /// 常にdepth 0として扱えばよい)。
    private static let indentPerDepth: CGFloat = 20

    /// - Parameters:
    ///   - items: (表示名, 階層の深さ。ルート直下は0)の一覧。
    ///   - minWidth: 名前が短い/1件も無い場合でも、これより狭くはしない下限。
    ///   - maxWidth: 名前が極端に長い場合でも、右ペインを圧迫しすぎないための上限。
    static func idealWidth(
        for items: [(name: String, depth: Int)],
        minWidth: CGFloat = 220,
        maxWidth: CGFloat = 560
    ) -> CGFloat {
        guard !items.isEmpty else { return minWidth }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = items.map { item -> CGFloat in
            let textWidth = (item.name as NSString).size(withAttributes: [.font: font]).width
            return textWidth + baseChromeWidth + CGFloat(item.depth) * indentPerDepth
        }.max() ?? minWidth
        return min(maxWidth, max(minWidth, widest.rounded(.up)))
    }

    /// 階層を持たない(常にdepth 0の)名前一覧から計算する簡易版。ブックマーク編集画面用。
    static func idealWidth(forNames names: [String], minWidth: CGFloat = 220, maxWidth: CGFloat = 560) -> CGFloat {
        idealWidth(for: names.map { (name: $0, depth: 0) }, minWidth: minWidth, maxWidth: maxWidth)
    }
}

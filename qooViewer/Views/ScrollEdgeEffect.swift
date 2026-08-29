import SwiftUI

/// ツールバーの下へスクロールして潜るコンテンツの、上端の縁の効果を「くっきり」にする
/// (macOS 26の`scrollEdgeEffectStyle`。macOS 15にはこのAPIが無いので何もしない)。
///
/// 既定(`.automatic`)はぼかし寄りの効果で、このアプリのように上端へ不透明な列タイトル行や
/// バーが来る画面では差がほとんど出ない。それでも、ツールバーとコンテンツの境目の描き方を
/// 全ウインドウで揃えておくために、クロームをツールバーへ載せた4つのウインドウ
/// (メタデータの編集・書き出し3種・ブックマーク/レイアウトの編集・お気に入りの整理)へ
/// 同じ指定を入れてある。
extension View {
    func hardTopScrollEdgeEffect() -> some View {
        modifier(HardTopScrollEdgeEffect())
    }
}

private struct HardTopScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

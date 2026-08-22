import SwiftUI

/// アイコンだけのボタン(サイドパネルの戻る/進む/1階層上、ツールバー、プログレスバーの
/// 各ボタン)の見た目を1か所にまとめたもの(ユーザー要望: ツールバー・プログレスバーの
/// ボタンをサイドパネルのボタンと同じデザインに揃える)。
///
/// 元々はサイドパネルのSidePanelNavButtonだけがこの見た目(枠なし・15ptのアイコン・
/// 32x28のタップ領域)で、ツールバーとプログレスバーはmacOS既定の枠付きボタン
/// (bezel付きのプッシュボタン)のままだった。3か所それぞれで同じ数値を書くと片方だけ
/// 直して食い違うため、装飾をこのViewModifierに集約し、呼び出し側は
/// `.panelIconButtonLabel()` + `.buttonStyle(.borderless)` の組み合わせだけを使う。
///
/// `.buttonStyle`自体をここで指定しないのは、ボタンのラベルにしか適用できない装飾
/// (frame/background)とボタン全体のスタイルを1つのAPIにまとめると、無効時
/// (`.disabled`)の淡色表示をButtonStyle側で自前に再現しなければならなくなるため。
/// 呼び出し側で`.borderless`を指定しておけば、サイドパネルの既存のボタンと
/// 押下中・無効時の見た目まで完全に同じになる。
struct PanelIconButtonLabel: ViewModifier {
    /// 「登録済み」状態を前景色・背景色の反転で示すかどうか(ツールバーのブックマーク/
    /// お気に入りトグル専用。詳細はViewerView.toggleToolbarIconのコメント参照)。
    var isHighlighted: Bool = false

    /// サイドパネルのボタンの寸法。既定のボタンサイズは小さく操作しづらいため、
    /// アイコンサイズ・タップ領域とも一回り大きくしている(ユーザー要望)。
    static let width: CGFloat = 32
    static let height: CGFloat = 28
    static let cornerRadius: CGFloat = 6

    func body(content: Content) -> some View {
        // 反転表示のときだけ前景色を明示する。通常状態で`.foregroundStyle`を指定して
        // しまうと、`.disabled`のときにSwiftUIが行う淡色表示を打ち消してしまい、
        // 押せないボタン(ページシフトのロック中など)が押せるように見えてしまう。
        Group {
            if isHighlighted {
                content.foregroundStyle(Color(nsColor: .controlBackgroundColor))
            } else {
                content
            }
        }
        .font(.system(size: 15, weight: .medium))
        // 面ごとの設定ぶんの輪郭(環境設定「外観」の「文字の影」)。ツールバー・プログレスバー・
        // サイドパネルのアイコンボタンはすべてこの見た目を通るので、ここ1箇所で行き渡る
        // (詳細はpanelOutlinedContentのコメント参照)。
        .panelOutlinedContent()
        .frame(width: Self.width, height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(isHighlighted ? Color.primary : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

extension View {
    /// アイコンだけのボタンのラベルに、サイドパネルのボタンと同じ装飾を与える。
    /// `.buttonStyle(.borderless)`と組みで使う(詳細はPanelIconButtonLabel参照)。
    func panelIconButtonLabel(isHighlighted: Bool = false) -> some View {
        modifier(PanelIconButtonLabel(isHighlighted: isHighlighted))
    }
}

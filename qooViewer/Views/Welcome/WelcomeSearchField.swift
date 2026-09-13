import SwiftUI

/// ウェルカム画面の検索欄(ユーザー要望 2026-09-13)。一覧ではコレクションを、コレクションの
/// 中では本を絞り込む。置き場所は操作列の行の中央(WelcomePaneHeaderLayout)。
///
/// ■ 輪郭(すりガラス面の決まりごと)
/// **不透明な地を持つ部品**として扱い、輪郭は掛けない。地はテキスト欄の色(`textBackgroundColor`)
/// を不透明のまま敷く ―― サイドパネルの絞り込み欄(SidePanelSearchField)は地が50%で、
/// 面を文字色で塗ると欄ごと消えかねない(CLAUDE.mdの「faint ground は地ではない」)。
/// 縁は`separatorColor`の細線で、面の色によらず欄の形が読める。
struct WelcomeSearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey

    static let height: CGFloat = PanelIconButtonLabel.height

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelIconButtonLabel.cornerRadius, style: .continuous)
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                // 欄の外をクリックしたらフォーカスを外す(文字は残す。FocusReleasingField参照)。
                .releasesFocusOnOutsideClick()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(shape.fill(Color(nsColor: .textBackgroundColor)))
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

/// 操作列の行を「左・中央・右」の3つに割り付ける(ユーザー要望 2026-09-13: 検索欄は行の中央)。
///
/// ■ なぜHStack + Spacerで書かないのか
/// 左(コレクションの中なら戻るボタンと名前)と右(ボタンの列)は幅が違うので、Spacerを
/// 両側に置いても検索欄は**行の中央には来ない**(残りの幅を左右に等分するだけ)。ここでは
/// 右の列の幅を左右両側に予約した上で中央へ置き、左の部品には検索欄の左に残った幅だけを渡す
/// (名前が長ければ中略される)。
///
/// ウインドウが狭くて中央に置くと欄が`centerMinWidth`を割るときは、中央に置くのを諦めて
/// 右の列の隣へ寄せる ―― 欄が潰れて打てなくなるより、中央から外れるほうがよい。
///
/// 子は必ず3つ(左・中央・右の順)。左に何も置かない画面は`Color.clear`を渡す。
struct WelcomePaneHeaderLayout: Layout {
    /// 左の部品が、行の外側の余白を自分の中に取り込んでいるぶん(戻るボタンの押せる範囲。
    /// CollectionDetailView.backButton)。行の左端がそのぶん外へ出ているので、中央はその分だけ
    /// 右へずらして求める ―― 一覧の画面(余白を取り込まない)と検索欄の位置を揃えるため。
    var leadingInset: CGFloat = 0
    var spacing: CGFloat = 12
    var centerIdealWidth: CGFloat = 280
    var centerMinWidth: CGFloat = 140

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = sizes.map(\.height).max() ?? 0
        let width = proposal.width
            ?? (sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0)))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0]
        let center = subviews[1]
        let trailing = subviews[2]
        let trailingWidth = trailing.sizeThatFits(.unspecified).width

        // まず左右対称に置けるか(右の列の幅を両側に予約して、残りに欄が収まるか)。
        let symmetricWidth = bounds.width - leadingInset
        let midX = bounds.minX + leadingInset + symmetricWidth / 2
        var centerWidth = min(centerIdealWidth, symmetricWidth - 2 * (trailingWidth + spacing))
        let centerX: CGFloat
        if centerWidth >= centerMinWidth {
            centerX = midX - centerWidth / 2
        } else {
            // 収まらない。右の列の隣へ寄せ、左の部品の幅を削る。
            centerWidth = max(0, min(centerMinWidth, bounds.width - trailingWidth - spacing))
            centerX = bounds.maxX - trailingWidth - spacing - centerWidth
        }

        trailing.place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
            proposal: ProposedViewSize(width: trailingWidth, height: bounds.height)
        )
        center.place(
            at: CGPoint(x: centerX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: centerWidth, height: nil)
        )
        leading.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: max(0, centerX - spacing - bounds.minX), height: nil)
        )
    }
}

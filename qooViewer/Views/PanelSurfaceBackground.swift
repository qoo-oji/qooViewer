import SwiftUI

/// すりガラスで描く面の背景を、環境設定「外観」の設定(`PanelSurfaceStyle`)に従って敷く。
///
/// ユーザー要望: ページ一覧パネル・ツールバー・プログレスバー・サイドパネルの背景色と
/// 透明度を個別に設定したい。ただし**今のデザインは気に入っているので、その見た目を
/// 維持したうえで**調整できるようにしてほしい。
///
/// そのため、既定値ではこのモディファイアの描画結果が
/// `.background(material, in: shape)`(従来の書き方)と**完全に一致する**ようにしてある。
///   ・`materialOpacity` = 1 なので、すりガラスの層はそのままの濃さで描かれる
///   ・`tintOpacity` = 0 なので、上に重ねる色は完全な透明になり、何も足されない
/// つまり設定を触っていない人の画面は1ピクセルも変わらない。
///
/// ■ 2層に分けてある理由
/// すりガラスの層と色の層を別々の不透明度で持つことで、次の3つをすべて1組の設定で
/// 表せる(詳しくは`PanelSurfaceStyle`の型コメント参照)。
///   ・今より透けさせたい      → すりガラスの濃さを下げる
///   ・好きな色に染めたい      → 色を選び、色の濃さを少し上げる
///   ・すりガラスをやめたい    → 色の濃さを100%にする(背後が完全に隠れる)
///
/// ■ サイドパネルはこれを使わない
/// サイドパネルだけはAppKitの`NSVisualEffectView`で描いており(SidebarVisualEffectView参照)、
/// SwiftUIの`Material`を渡せない。同じ2層構成を、そちらは`SidePanelSurfaceBackground`が
/// 受け持つ。
extension View {
    /// - Parameters:
    ///   - style: 環境設定「外観」で決まったこの面の見た目。
    ///   - material: 設定を触っていないときに使う、従来どおりのマテリアル。
    ///     **`nil`を渡すと色の層だけを敷く。**
    ///
    ///     ツールバーとプログレスバーは、自動的に隠す設定のときだけ画像の上へ浮かべる
    ///     半透明の帯として描かれ、常に表示する設定のときは`VStack`の一員として
    ///     ビューアの背景色の上に不透明に置かれる。後者にはそもそもすりガラスが無いので、
    ///     ここでマテリアルまで足すと**設定を触っていない人の見た目が変わってしまう**。
    ///     一方で「ツールバーの色」を決めたのに常時表示だと何も起きない、というのも
    ///     分かりにくい。そこで常時表示側には色の層だけを敷いて、色の設定は両方の
    ///     状態に効き、すりガラスの濃さは浮かせているときにだけ効く、という形にしてある。
    ///   - shape: 面の輪郭(ツールバー等は`Rectangle`、ページ一覧パネルは角丸)。
    func panelSurfaceBackground<S: Shape>(
        _ style: PanelSurfaceStyle,
        material: Material?,
        in shape: S
    ) -> some View {
        background {
            ZStack {
                if let material {
                    shape.fill(material)
                        .opacity(style.materialOpacity)
                }
                shape.fill(style.resolvedTint)
            }
        }
    }
}

/// サイドパネルの背景。上の`panelSurfaceBackground`のAppKit版で、層の構成も意味も同じ。
///
/// すりガラス本体が`NSVisualEffectView`(SidebarVisualEffectView)である点だけが違う。
/// SwiftUIの`.regularMaterial`へ置き換えてしまうと、フル高さでタイトルバー直下から続く
/// サイドバー配置のときにウインドウがキーだと境界へ青い線が描かれる不具合が再発するため、
/// **マテリアルの実体は差し替えないこと**(SidebarVisualEffectViewのコメント参照)。
struct SidePanelSurfaceBackground: View {
    let style: PanelSurfaceStyle

    var body: some View {
        ZStack {
            SidebarVisualEffectView()
                .opacity(style.materialOpacity)
            style.resolvedTint
        }
    }
}

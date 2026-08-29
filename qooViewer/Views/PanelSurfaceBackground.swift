import AppKit
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
    ///
    ///     SwiftUIの`Material`は**同じウインドウ内の、背後に描かれている内容**をぼかす方式。
    ///     画像の上へ浮かべる帯やパネルはこれでよいが、常時表示(自動的に隠さない設定)の
    ///     ツールバー・プログレスバーのように**背後(ウインドウ内)に何も描かれていない面**では
    ///     ぼかす対象が無く、単なる灰色の板になる。そちらは下の`behindWindowMaterial:`版を使う。
    ///   - shape: 面の輪郭(ツールバー等は`Rectangle`、ページ一覧パネルは角丸)。
    func panelSurfaceBackground<S: Shape>(
        _ style: PanelSurfaceStyle,
        material: Material,
        in shape: S
    ) -> some View {
        panelContentOutline(width: PanelContentShadow.outlineWidth(forLevel: style.contentShadowLevel))
            .background {
                ZStack {
                    shape.fill(material)
                        .opacity(style.materialOpacity)
                    shape.fill(style.resolvedTint)
                }
            }
    }

    /// 上のSwiftUI `Material`版と同じ2層構成を、ウインドウの**背後**(デスクトップ/
    /// 他のウインドウ)を透かして見せるAppKitのすりガラス(`.behindWindow`)で敷く版。
    ///
    /// 常時表示(自動的に隠さない設定)のツールバー・プログレスバーが使う。あの帯は
    /// `VStack`の一員としてウインドウの端に置かれ、帯の背後(ウインドウ内)には何も
    /// 描かれていないため、SwiftUIの`Material`では何もぼかせず単なる灰色の板になって
    /// しまう(ユーザー要望: ウェルカム画面と、隠していない状態のツールバー・
    /// プログレスバー・サイドパネルがのっぺりして見える。背後のウインドウやデスクトップが
    /// 少しだけ透けて見えるようにしたい)。
    ///
    /// - Parameter material: **`nil`なら色の層だけを敷く**(すりガラス無し)。
    ///   環境設定「外観」の「ウインドウの背後を透かす」スイッチ
    ///   (AppPreferences.toolbarDockedGlassなど)がOFFのときの、従来どおりの描画。
    ///   既定はOFF ―― 従来からのユーザーが設定を変更しなければ、常時表示の帯は
    ///   以前と同じく色の層だけになる(重ね色の設定は従来から常時表示にも効いていた)。
    ///   ONのときだけすりガラスの層が加わり、濃さ(materialOpacity)の設定も帯に効く。
    func panelSurfaceBackground<S: Shape>(
        _ style: PanelSurfaceStyle,
        behindWindowMaterial material: NSVisualEffectView.Material?,
        in shape: S
    ) -> some View {
        panelContentOutline(width: PanelContentShadow.outlineWidth(forLevel: style.contentShadowLevel))
            .background {
                ZStack {
                    if let material {
                        BehindWindowVisualEffectView(material: material)
                            .clipShape(shape)
                            .opacity(style.materialOpacity)
                    }
                    shape.fill(style.resolvedTint)
                }
            }
    }

    /// この面に載る文字・アイコンへ掛ける輪郭の太さを、子孫へ配る。
    ///
    /// **輪郭そのものはここでは掛けない。** `.shadow`は親に掛けると子孫すべての葉に及び、
    /// **子側から打ち消すことができない**(`.shadow(radius: 0)`でも`.shadow(color: .clear)`でも
    /// 消えないことを検証アプリで実測済み)。パネル全体に掛けると、スライダーのつまみ・検索欄・
    /// サムネイル画像といった「輪郭が要らないもの」にまで光輪が付いてしまう
    /// (ユーザー報告: ページ一覧パネルのスライダーの丸に影がにじむ)。
    ///
    /// そのため、太さだけを環境経由で配り、**実際に輪郭を掛けるのは文字とアイコンの側**
    /// (`panelOutlinedContent()`)にしている。新しく文字やアイコンを足したときは、そこに
    /// `.panelOutlinedContent()`を付ければこの設定に乗る。付け忘れても輪郭が付かないだけで、
    /// 誤って他の部品に付くことはない。
    func panelContentOutline(width: CGFloat) -> some View {
        environment(\.panelContentOutlineWidth, width)
    }

    /// 文字・アイコンに、面ごとの設定ぶんの輪郭を掛ける。太さは`panelContentOutline(width:)`が
    /// 配った環境値から読む(0なら何もしない = 既定)。
    ///
    /// **輪郭の色は文字色の反対色**(ライト外観なら白、ダーク外観なら黒)。文字自体の色も形も
    /// 一切変えず、ひと回り太らせた同じ形を後ろへ敷くだけなので、**グリフはぼけない** ――
    /// 黒く塗り潰した面の上の黒い文字も、まっ白なページの上の白い文字も、縁取りが付くことで
    /// 読めるようになる。面の明るさを推定して文字色を反転させる案を採らなかった理由と、
    /// ぼかした影をやめた理由は`PanelContentShadow`のコメント参照。
    ///
    /// `.foregroundStyle`ではなく輪郭で解決していることには、もう1つ利点がある ―― アイコンだけの
    /// ボタンは、無効時(`.disabled`)にSwiftUIが行う淡色表示を殺さないために**あえて前景色を
    /// 指定していない**(PanelIconButtonLabelのコメント参照)。前景色に触らなければ、その配慮を
    /// そのまま残せる。
    /// - Parameters:
    ///   - isEnabled: `false`を渡すと何もしない。呼び出し側が「この部品は自前の不透明な地を
    ///     持っているので輪郭は要らない」と場合分けするための口
    ///     (サイドパネルのモードスイッチャが、選択中かどうかで使い分ける)。
    ///   - color: 輪郭の色を明示する。既定(nil)は文字色の反対色。
    ///
    ///     **原則は「その部品自身の色の反対色」**で、文字・アイコンは`Color.primary`(外観に
    ///     追従)なので既定でよい。一方、プログレスバーの本体のように**外観に関わらず白で
    ///     描いている部品**は、外観がライトのときに反対色が白になってしまい輪郭にならない。
    ///     そういう部品だけ、自分の色に対する反対色をここで明示する。
    func panelOutlinedContent(isEnabled: Bool = true, color: Color? = nil) -> some View {
        modifier(PanelContentOutline(isEnabled: isEnabled, explicitColor: color))
    }

    /// ネイティブの`Slider`など、**輪郭が使えない部品**の下へ、反対色の薄い「溝」を敷く。
    ///
    /// スライダーのつまみは白く、明るい面(重ね色を白にした場合など)の上ではほとんど見えなく
    /// なる。ただし`panelOutlinedContent()`は使えない ―― あれはシルエットを太らせる仕組みで、
    /// **つまみ自身が持つ落ち影までシルエットに含まれてしまい**、つまみのまわりに同心円状の
    /// にじみが出る(ユーザー報告: ページ一覧パネルのスライダーの丸に影がにじむ。ぼかしを
    /// やめた後も残っていた)。つまみの位置に輪郭線を自分で描く案も作って見比べたが、
    /// **部品全体を溝に収めるこちらのほうが収まりが良い**という判断になった(ユーザーの選択)。
    ///
    /// 濃さを控えめにしてあるのは、溝そのものを主張させず、あくまで部品が浮かんで見える程度に
    /// とどめるため。
    ///
    /// 太さの設定(「文字の影」)が0のときは何もしない ―― 既定では1ピクセルも変わらない。
    func panelControlWell() -> some View {
        modifier(PanelControlWell())
    }
}

extension View {
    /// 強調色(アクセントカラー)で塗った部品の縁を、反対色の線で囲む。
    ///
    /// パネルの重ね色をアクセントカラーに近い色にすると、**選択中のモードボタンや選択行の
    /// ハイライトが地の色に溶けて、どれが選ばれているのか分からなくなる**(実測: 重ね色を
    /// `#007AFF`100%にすると選択中のモードボタンの枠が消えた)。文字は白のまま読めるので
    /// 読みにくさの問題ではなく、**状態が伝わらない**問題。
    ///
    /// 「パネルの色とアクセントカラーが近ければアクセント側をずらす」自動調整も考えられるが、
    /// ここでは採っていない ―― ずらした先が今度は別の部品とぶつからない保証が無く、
    /// 「近い」の線引きも恣意的になる。輪郭なら、**地が何色でも縁が出る**ぶん確実で、
    /// しかも文字・アイコンと同じ1つの設定で足並みが揃う。
    ///
    /// - Parameters:
    ///   - shape: 縁取る形(モードボタンは角丸、行のハイライトは矩形)。
    ///   - isEnabled: 選択されていない行・ボタンには縁を出さないための口。
    func panelOutlinedAccent<S: InsettableShape>(in shape: S, isEnabled: Bool = true) -> some View {
        modifier(PanelAccentOutline(shape: shape, isEnabled: isEnabled))
    }
}

private struct PanelAccentOutline<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelContentOutlineWidth) private var width

    let shape: S
    let isEnabled: Bool

    func body(content: Content) -> some View {
        guard isEnabled, width > 0 else { return AnyView(content) }
        return AnyView(
            content.overlay {
                shape
                    .strokeBorder(
                        colorScheme == .dark ? Color.black : Color.white,
                        lineWidth: width
                    )
                    .allowsHitTesting(false)
            }
        )
    }
}

private struct PanelControlWell: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelContentOutlineWidth) private var width

    func body(content: Content) -> some View {
        guard width > 0 else { return AnyView(content) }
        let color: Color = colorScheme == .dark ? .black : .white
        return AnyView(
            content
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.22)))
        )
    }
}

/// `panelContentOutline(width:)`が配り、`panelOutlinedContent()`が読む輪郭の太さ(pt)。
private struct PanelContentOutlineWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var panelContentOutlineWidth: CGFloat {
        get { self[PanelContentOutlineWidthKey.self] }
        set { self[PanelContentOutlineWidthKey.self] = newValue }
    }
}

private struct PanelContentOutline: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelContentOutlineWidth) private var width

    let isEnabled: Bool
    let explicitColor: Color?

    func body(content: Content) -> some View {
        guard isEnabled, width > 0 else { return AnyView(content) }
        // 半径0(ぼかさない)の影を上下左右へずらして重ね、元の形をひと回り太らせた輪郭にする。
        return PanelContentShadow.outlineDirections.reduce(AnyView(content)) { view, direction in
            AnyView(
                view.shadow(
                    color: outlineColor, radius: 0,
                    x: direction.x * width, y: direction.y * width
                )
            )
        }
    }

    /// 文字色の反対色。ライト外観の文字は黒なので白、ダーク外観の文字は白なので黒。
    /// 呼び出し側が明示した場合はそちらを使う(引数のコメント参照)。
    private var outlineColor: Color {
        explicitColor ?? (colorScheme == .dark ? .black : .white)
    }
}

/// サイドパネルの背景。上の`panelSurfaceBackground`のAppKit版で、層の構成も意味も同じ。
///
/// すりガラス本体が`NSVisualEffectView`(SidebarVisualEffectView)である点だけが違う。
/// SwiftUIの`.regularMaterial`へ置き換えてしまうと、フル高さでタイトルバー直下から続く
/// サイドバー配置のときにウインドウがキーだと境界へ青い線が描かれる不具合が再発するため、
/// **マテリアルの実体は差し替えないこと**(SidebarVisualEffectViewのコメント参照)。
///
/// `blendingMode`は、常時表示(HStackへの組み込み)かつ「ウインドウの背後を透かす」
/// (AppPreferences.sidePanelDockedGlass。既定OFF)がONなら`.behindWindow`、それ以外
/// (ホバーによる一時表示、またはスイッチOFF)は従来どおり`.withinWindow`を渡す ――
/// 使い分けの理由はSidebarVisualEffectViewのコメント参照。
struct SidePanelSurfaceBackground: View {
    let style: PanelSurfaceStyle
    let blendingMode: NSVisualEffectView.BlendingMode

    var body: some View {
        ZStack {
            SidebarVisualEffectView(blendingMode: blendingMode)
                .opacity(style.materialOpacity)
            style.resolvedTint
        }
    }
}

/// ウインドウの背後(デスクトップ/他のウインドウ)を透かして見せる`.behindWindow`方式の
/// すりガラス。SwiftUIの`Material`はウインドウ**内**の背後の内容しかぼかせないため、
/// 背後に何も描かれていない面 ―― 常時表示のツールバー/プログレスバーの帯
/// (`panelSurfaceBackground(_:behindWindowMaterial:in:)`)とウェルカム画面(WelcomeView) ――
/// ではこちらを使う。
///
/// サイドパネルのホバー表示で確認された震えの不具合(SidebarVisualEffectViewのコメント参照)が
/// ここで問題にならないのは、この面はウインドウ内の不透明な描画(ViewerViewの画像)と
/// 重なる場所には敷かれないため。
struct BehindWindowVisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // ウインドウが非アクティブのときも質感を保つ。既定の.followsWindowActiveStateだと
        // 非アクティブになった瞬間にただの灰色の板へ戻り、「のっぺりして見える」が再発する。
        // サイドパネル(SidebarVisualEffectView)と同じ判断。
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

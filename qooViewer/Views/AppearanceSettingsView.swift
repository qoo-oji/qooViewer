import SwiftUI

/// 環境設定ウインドウの「外観」画面。
///
/// ■ この画面が生まれた経緯
/// ユーザー要望: 「すりガラス」で描かれている面(ページ一覧パネル・ツールバー・
/// プログレスバー・サイドパネル)の背景色と透明度を、それぞれ個別に設定したい。加えて、
/// アプリの見た目に関する設定が複数のタブに散らばっていたので、この画面へ集約する。
///
/// 移してきたのは次の3つ。
///   ・ビューアの背景色(旧「画像の表示」)
///   ・ページ一覧の見え方すべて(旧「閲覧中の動作」のサイズ・間隔・余白)
///   ・自動的に隠れる3面(ツールバー・プログレスバー・サイドパネル)の「表示までの時間」
///     ―― 当初は「閲覧中の動作」に3本まとめて置いていたが、その部分の設定は既に
///     面ごとのページにあるので、そちらへ統合した(ユーザーの指示)
/// ページ一覧は「色や文字だけをこちらへ、寸法は元のまま」という分け方も考えたが、
/// 1つのパネルの見た目を決める設定が2画面に分かれるほうが探しづらいという判断で、
/// **一括でこちらへ**移した(ユーザーの指示)。逆に、ページ一覧に関する設定でも
/// ホバー拡大プレビューとホイールのスクロール量は「閲覧中の動作」に残してある ――
/// あれらは見た目ではなく操作への応答の設定で、しかもページ一覧以外にも効くため。
///
/// ■ 面ごとの設定は子ページに分けてある(2階層)
/// 以前はこの1枚に、アプリ・ビューア・ページ一覧・6つの面・プログレスバーのサムネイルの
/// 全セクション(約45行)を縦に並べていた。面ごとのセクションは見出しも中の行名も同じものが
/// 6回繰り返されるため、スクロールしながら見出しを読んでもどの面なのか見分けにくく、
/// 目的の項目にたどり着けない、というのがユーザーの指摘。
///
/// そこで、この画面は「アプリ」「ビューア」と**面の一覧**(6行)だけにし、面の行を押すと
/// その面の設定だけを載せた子ページ(`PanelSurfaceSettingsView`)へ進む形にした
/// (macOSのシステム設定「通知」→アプリ名、と同じ動き)。ページ一覧のサムネイルと
/// プログレスバーのサムネイルは、それぞれの面の子ページの中にある ―― 1つのパネルの
/// 見た目を決める設定は必ず同じページに揃う、という上記の方針を保つため。
///
/// 検討して採らなかった案:
///   ・セクションの折り畳み ―― 既定で開いていれば今と長さが変わらず、既定で畳むと
///     毎回クリックが増えるだけで「10個の見出しから探す」作業は残る。`Form(.grouped)`に
///     畳む純正の仕組みも無い。
///   ・面をポップアップで切り替えて1枚に収める ―― 画面は1枚で済むが、6面の値を
///     一覧して見比べることができなくなる。一覧を残すことを優先して2階層を選んだ(ユーザーの決定)。
///
/// ■ 子ページは次回に持ち越さない
/// 環境設定を開き直したときは必ず一覧から始める(ユーザーの決定)。開いている子ページ
/// (SettingsNavigator.openedAppearanceSurface)を保存せず、この画面が閉じる(ウインドウを
/// 閉じる、別の画面へ移る)たびにnilへ戻すのはそのため(body末尾のonDisappear参照)。「前に見ていた面の子ページがいきなり開く」戸惑いを避ける。
///
/// ■ 並び順
/// 一覧の面は、上から「ビューアの中で目に入る面積が大きい順」(ページ一覧 → 帯や側面の3面 →
/// ウェルカム画面 → 小さな浮かぶ表示)で、`PanelSurface.allCases`の順をそのまま使っている
/// (面を足してもこのファイルは触らなくてよい)。
struct AppearanceSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    /// 「調整…」(PanelPartContextMenu)から預けられた行き先と、いま開いている子ページ
    /// (SettingsNavigator.openedAppearanceSurface参照)。
    /// `@ObservedObject`にしてあるのは、この画面が既に開いている状態で別の面の「調整…」を
    /// 選ばれたときにも`onChange`で拾うため、また子ページの開閉に追従するため。
    @ObservedObject private var navigator = SettingsNavigator.shared
    /// 環境設定「表示言語」。子ページのタイトルを引くのに使う(SettingsView参照)。
    @Environment(\.locale) private var locale


    /// 色の指定ダイアログの編集対象。この画面が持つのはビューアの背景色だけ
    /// (面ごとの色は子ページが持つ。PanelSurfaceSettingsView参照)。
    /// `.sheet(isPresented:)`ではなく`.sheet(item:)`にしてあるのは、子ページと形を揃えるため。
    private enum ColorTarget: Identifiable, Hashable {
        /// ビューアの背景色(「カスタム」を選んだとき)。
        case background

        var id: Self { self }
    }

    @State private var colorTarget: ColorTarget?
    /// 「カスタム」を選んでダイアログを開いた直前の選択。キャンセルされたら戻す(revert参照)。
    @State private var backgroundOptionBeforeCustomizing: BackgroundColorOption?

    var body: some View {
        // 詳細ペイン(SettingsViewのNavigationSplitViewの右側)の中で、一覧と子ページを
        // 自前で切り替える。子ページの間に効く「戻る」は、ウインドウのタイトルバー
        // (SettingsViewのツールバー)にある。
        //
        // ■ なぜ`NavigationStack`を使わないのか
        // `NavigationSplitView`の詳細ペインに`NavigationStack`を置いて`navigationDestination`で
        // 進む形も試したが、進んだ先のページの標準の「戻る」はSwiftUIが詳細ペインの中に描くもので、
        // ウインドウのタイトルバーには出ない(Apple Developer Forums thread 767943
        // 「MacOS SwiftUI: Back button in NavigationSplitView detail view」でも同じ報告があり、
        // そこでの回避策も「標準の戻るボタンを隠して自前のツールバー項目を置く」だった)。
        // それなら`NavigationStack`を挟む意味が無いので、状態1つと`if`で切り替えている。
        Group {
            if let surface = navigator.openedAppearanceSurface {
                PanelSurfaceSettingsView(surface: surface)
            } else {
                rootPage
            }
        }
        // 「調整…」の行き先を拾うタイミングは2つある。
        //   1. 開いた瞬間(環境設定ウインドウが閉じていた、または別の画面を開いていた場合)
        //   2. 既にこの画面が開いたまま、別の面の「調整…」を選ばれた場合
        // 1はonAppear、2はonChangeで拾う。
        //
        // ■ 「一覧から始める」の戻しはonDisappearで行う(onAppearではない)
        // 当初は「onAppearで、行き先が無ければ一覧へ戻す」としていたが、実機で
        // 「調整…」から開くと一覧のままになる不具合が出た。環境設定ウインドウを閉じても
        // SwiftUIはこの画面のViewを捨てずに残すことがあり、その状態で「調整…」を選ぶと
        // **onChangeが先に走って行き先を消費し、そのあとでonAppearが「行き先無し」と見て
        // 一覧へ戻してしまう**ため。閉じる/別の画面へ移るときに戻せば、この順序の問題は起きない。
        .onAppear { openPendingTarget() }
        .onChange(of: navigator.appearanceTarget) { _, _ in
            openPendingTarget()
        }
        .onDisappear { navigator.openedAppearanceSurface = nil }
    }

    /// 一覧のページ(アプリ・ビューア・面の一覧・初期設定に戻す)。
    private var rootPage: some View {
        SettingsPaneContainer {
            appSection
            viewerSection
            panelsSection

            SettingsResetSection(
                help: "Restores every setting on this page and on every panel’s page, including the color of every frosted surface. Other pages are not affected."
            ) {
                preferences.resetToDefaults(.appearance)
            }
        }
        // シートは行ではなく画面の土台側に付ける(理由はSettingsColorRowのコメント参照)。
        .sheet(item: $colorTarget) { target in
            CustomColorPickerSheet(
                titleKey: "Custom Background Color",
                initialColor: preferences.customBackgroundColor,
                onCommit: { commit($0, for: target) },
                onCancel: { revert(target) }
            )
        }
    }

    /// 行き先が入っていればその面の子ページを開き、行き先を空に戻す。
    ///
    /// 既に同じ面の子ページを開いているときは値が変わらないので何も起きない。
    /// 別の面の子ページを開いているときは差し替わる(戻れば一覧。前に見ていた面のページは
    /// 残さない)。どの経路で来ても子ページの下には一覧があり、「戻る」で一覧へ出られる。
    private func openPendingTarget() {
        guard let surface = navigator.appearanceTarget else { return }
        navigator.openedAppearanceSurface = surface
        navigator.appearanceTarget = nil
    }

    // MARK: - アプリ全体

    /// アプリ全体のライト/ダーク(ユーザー要望: システム設定とは独立して選びたい)。
    ///
    /// この画面のいちばん上に置いてあるのは、ここだけが**アプリのすべての面**に効く設定で、
    /// 以下(ビューア・面ごとのページ)がその上に重なる関係にあるため。
    /// リセットの担当もこの画面(AppPreferences.keys(for:)の.appearance参照。
    /// **画面の置き場所とkeys(for:)は必ず揃えること**)。
    ///
    /// ビューアの背景色(下の「ビューア」)はこの設定とは独立していて、ライト/ダークで
    /// 勝手に変わることはない ―― 好きな色で絵を見るための設定なので、そちらが正しい。
    private var appSection: some View {
        Section {
            SettingsPicker(
                "Appearance Mode",
                selection: $preferences.appAppearance,
                help: "Applies to qooViewer only, whatever the system Light/Dark setting is. The viewer's background color is a separate setting."
            )
        } header: {
            Text("App")
        }
    }

    // MARK: - ビューア

    private var viewerSection: some View {
        Section {
            SettingsPicker("Background Color", selection: backgroundColorSelection)
        } header: {
            Text("Viewer")
        }
    }

    // MARK: - 面の一覧

    /// 面ごとの子ページへ進む行の一覧。行の右側に、その面の現在の値の要約(色見本と、
    /// すりガラスと色の濃さ)を添えてあるのは、**子ページへ進まなくても6面を見比べられる**
    /// ようにするため(ポップアップで切り替える案ではなく2階層を選んだ理由がこれ)。
    private var panelsSection: some View {
        Section {
            ForEach(PanelSurface.allCases) { surface in
                PanelSurfaceRow(surface: surface, style: preferences.surfaceStyle(for: surface)) {
                    navigator.openedAppearanceSurface = surface
                }
            }
        } header: {
            Text("Panels")
        }
    }

    // MARK: - プリセット付きポップアップ

    /// 「背景色」ポップアップ用のBinding。値を保存するだけでなく、「カスタム」が選ばれたら
    /// その場で色の指定ダイアログを開く。
    ///
    /// `.onChange`ではなくBindingの`set`側で開いているのは、**既に「カスタム」が選ばれている
    /// 状態でもう一度「カスタム」を選び直したとき**にも開けるようにするため。`.onChange`は
    /// 値が変わったときにしか呼ばれないので、その場合に何も起きず、一度別のプリセットへ
    /// 逃げてから戻る以外に色を編集し直す方法が無くなってしまう。
    private var backgroundColorSelection: Binding<BackgroundColorOption> {
        Binding(
            get: { preferences.backgroundColorOption },
            set: { newValue in
                let previous = preferences.backgroundColorOption
                preferences.backgroundColorOption = newValue
                guard newValue == .custom else { return }
                backgroundOptionBeforeCustomizing = previous
                colorTarget = .background
            }
        )
    }

    // MARK: - ダイアログの読み書き

    private func commit(_ color: RGBColorValue, for target: ColorTarget) {
        switch target {
        case .background:
            // 背景色そのものは「カスタム」を選んだ時点で既に切り替わっている
            // (backgroundColorSelection参照)ので、ここでは色だけを保存する。
            preferences.customBackgroundColor = color
        }
    }

    /// キャンセルされたときの後始末。プリセットのポップアップから「カスタム」を選んで
    /// 開いた場合だけ、その選択自体を開く前の値へ戻す(「キャンセルしたのに色の種類だけ
    /// 変わってしまった」を防ぐため)。直前も「カスタム」だったなら、色だけが元のまま残る。
    private func revert(_ target: ColorTarget) {
        switch target {
        case .background:
            if let previous = backgroundOptionBeforeCustomizing {
                preferences.backgroundColorOption = previous
            }
            backgroundOptionBeforeCustomizing = nil
        }
    }
}

// MARK: - 面の一覧の1行

/// 「外観」の面の一覧の1行。左に面の名前、右にその面の現在の値の要約と、子ページへ進む「>」。
/// 押すと子ページへ進む(`open`)。
///
/// 要約は「すりガラスの濃さ・色の濃さ + 色見本」。色見本には重ねる色を**濃さまで込みで**
/// 描く(`resolvedTint`)ので、色を重ねていない面(既定)は見本が空に見え、
/// 「この面はまだ何も変えていない」ことが一覧の中でひと目で分かる。
///
/// `NavigationLink`ではなく行全体を1つのボタンにしてある(`NavigationStack`を使っていない
/// 理由はAppearanceSettingsView.body参照)。`.plain`にしているのは、Formの行の地の上に
/// ボタンの枠を描かせないため。行のどこを押しても進めるよう当たり判定を矩形にしてある。
private struct PanelSurfaceRow: View {
    let surface: PanelSurface
    let style: PanelSurfaceStyle
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Text(surface.titleKey)
                Spacer(minLength: 12)
                Text("Frosted Glass \(percentText(style.materialOpacity)) · Color \(percentText(style.tintOpacity))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(style.resolvedTint)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            // 白や透明の見本が行の地に溶けないよう、常に薄い枠線を敷く
                            // (SettingsColorRowと同じ)。
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .frame(width: 36, height: 16)
                    // 見本は数値の言い換えなので読み上げない(数値のテキストが読まれる)。
                    .accessibilityHidden(true)
                // 「押すと進む」印。システム設定の一覧の行と同じ。
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

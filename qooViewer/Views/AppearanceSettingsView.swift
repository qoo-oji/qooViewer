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
///     ―― 当初は「閲覧中の動作」に3本まとめて置いていたが、その部分の設定は既にこの画面の
///     面ごとのセクションにあるので、そちらへ統合した(ユーザーの指示)
/// ページ一覧は「色や文字だけをこちらへ、寸法は元のまま」という分け方も考えたが、
/// 1つのパネルの見た目を決める設定が2画面に分かれるほうが探しづらいという判断で、
/// **一括でこちらへ**移した(ユーザーの指示)。逆に、ページ一覧に関する設定でも
/// ホバー拡大プレビューとホイールのスクロール量は「閲覧中の動作」に残してある ――
/// あれらは見た目ではなく操作への応答の設定で、しかもページ一覧以外にも効くため。
///
/// ■ 並び順
/// 上から「ビューア(いちばん面積が大きい)」→「ページ一覧」→ 残りの3面、という
/// 目に入る面積の順にしてある。すりガラスの3項目(すりガラスの濃さ・重ねる色・色の濃さ)は
/// 4面すべてで同じ並びで、`PanelSurface.allCases`から機械的に生成している(面を足しても
/// このファイルは触らなくてよい)。
struct AppearanceSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    /// ツールバー/プログレスバー/サイドパネル/ページ一覧パネルを右クリック →「調整…」で
    /// 開かれたとき、対応するセクションまでスクロールして見せるための行き先
    /// (SettingsNavigator参照)。
    @ObservedObject private var navigator = SettingsNavigator.shared

    /// いま色の指定ダイアログを開いている対象。`nil`なら閉じている。
    ///
    /// この画面には色を選ぶ場所が複数(背景色・枠の色・面ごとの重ね色)あるが、
    /// `.sheet`は画面の土台側に1つだけ置く方針(SettingsColorRowのコメント参照)なので、
    /// 「どの色を編集中か」をこの1つの状態で表す。
    @State private var colorTarget: ColorTarget?
    /// 「カスタム」を選んだことでダイアログが開いた場合に、キャンセルされたら戻す先。
    /// プリセットのポップアップを持つ2つ(背景色・枠の色)だけが使う。
    @State private var backgroundOptionBeforeCustomizing: BackgroundColorOption?
    @State private var borderOptionBeforeCustomizing: PageBorderColorOption?
    @State private var filmstripHighlightOptionBeforeCustomizing: PageBorderColorOption?

    /// 濃さが0%のまま色を選んだときに、代わりに設定する濃さ(上のcommitのコメント参照)。
    /// 選んだ色がはっきり分かり、かつすりガラスの質感も残る程度。
    private static let tintOpacityWhenFirstColored: Double = 0.25

    /// 色の指定ダイアログの編集対象。`.sheet(item:)`へ渡すため`Identifiable`にしてある。
    private enum ColorTarget: Identifiable, Hashable {
        /// ビューアの背景色(「カスタム」を選んだとき)。
        case background
        /// ページ一覧で表示中のページを示す枠の色(同上)。
        case pageBorder
        /// プログレスバーのフィルムストリップで、カーソル位置のページを示す色(同上)。
        case filmstripHighlight
        /// すりガラスの面に重ねる色。こちらはプリセットを持たず、常にこのダイアログで決める。
        case surfaceTint(PanelSurface)

        var id: String {
            switch self {
            case .background: "background"
            case .pageBorder: "pageBorder"
            case .filmstripHighlight: "filmstripHighlight"
            case .surfaceTint(let surface): "surfaceTint.\(surface.rawValue)"
            }
        }

        var titleKey: LocalizedStringKey {
            switch self {
            case .background: "Custom Background Color"
            // 「表示中のページ」と「カーソル位置のページ」で指す対象は違うが、どちらも
            // 「サムネイル1枚を色で示す」ためのカスタム色なので、同じ見出しでよい。
            case .pageBorder, .filmstripHighlight: "Custom Highlight Color"
            case .surfaceTint: "Custom Panel Color"
            }
        }
    }

    var body: some View {
        // 面ごとのセクションへ直接飛べるようにするためのScrollViewReader
        // (ユーザー要望: 帯の右クリック →「調整…」でその面の設定まで一気に開きたい)。
        // Formは内部にスクロールビューを持つので、ここで包めばproxy.scrollToが効く。
        ScrollViewReader { proxy in
            SettingsPaneContainer {
                viewerSection
                // スクロールの行き先の目印(AppearanceSection参照)。ページ一覧パネルの
                // 右クリック →「調整…」はここへ着地する。
                pageListSection
                    .id(AppearanceSection.pageList)
                ForEach(PanelSurface.allCases) { surface in
                    surfaceSection(surface)
                        // 同じく行き先の目印。PanelSurfaceから機械的に作っているので、
                        // 面を1つ増やしてもここは触らなくてよい。
                        .id(AppearanceSection.surface(surface))
                    // フィルムストリップ(プログレスバーの中身)のセクションだけ、面の並びの
                    // 途中へ差し込む。**プログレスバーの帯を右クリック →「調整…」の着地点は
                    // 上のsurfaceSectionの先頭**なので、ページ一覧と同じように中身のセクションを
                    // 面より前へ置くと、そこから飛んできた人の画面の外(上)へ隠れてしまう。
                    if surface == .progressBar {
                        filmstripSection
                    }
                }

                SettingsResetSection(
                    help: "Restores every setting on this page, including the color of every frosted surface. Other pages are not affected."
                ) {
                    preferences.resetToDefaults(.appearance)
                }
            }
            // 開いた瞬間に行き先が入っている場合(環境設定ウインドウが閉じていた、または
            // 別の画面を開いていた場合)と、既にこの画面が開いたまま別の面の「調整…」を
            // 選ばれた場合の両方を拾う必要があるため、onAppearとonChangeの2本立てにする。
            .onAppear { scrollToPendingTarget(using: proxy) }
            .onChange(of: navigator.appearanceTarget) { _, _ in
                scrollToPendingTarget(using: proxy)
            }
        }
        // シートは行ではなく画面の土台側に付ける(理由はSettingsColorRowのコメント参照)。
        .sheet(item: $colorTarget) { target in
            CustomColorPickerSheet(
                titleKey: target.titleKey,
                initialColor: currentColor(for: target),
                onCommit: { commit($0, for: target) },
                onCancel: { revert(target) }
            )
        }
    }

    /// 行き先が入っていればそこまでスクロールし、行き先を空に戻す。
    ///
    /// 1フレーム待ってからスクロールしているのは、onAppearの時点ではFormの中身がまだ
    /// レイアウトされておらず、その場でscrollToを呼んでも何も起きないことがあるため
    /// (環境設定ウインドウが閉じた状態から開いた場合に起きる)。
    /// 行き先を空へ戻すのも同じTaskの中で行い、次に環境設定を開いたときに勝手に
    /// 飛ばないようにする。
    private func scrollToPendingTarget(using proxy: ScrollViewProxy) {
        guard let section = navigator.appearanceTarget else { return }
        Task { @MainActor in
            await Task.yield()
            withAnimation { proxy.scrollTo(section, anchor: .top) }
            navigator.appearanceTarget = nil
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

    // MARK: - ページ一覧

    private var pageListSection: some View {
        Section {
            SettingsSlider(
                "Thumbnail Size",
                value: $preferences.thumbnailGridCellSize,
                in: AppPreferences.thumbnailGridCellSizeRange,
                step: 10
            ) { value in
                "\(Int(value)) pt"
            }
            SettingsSlider(
                "Horizontal Spacing",
                value: $preferences.thumbnailGridHorizontalSpacing,
                in: AppPreferences.thumbnailGridSpacingRange,
                step: 2
            ) { value in
                "\(Int(value)) pt"
            }
            SettingsSlider(
                "Vertical Spacing",
                value: $preferences.thumbnailGridVerticalSpacing,
                in: AppPreferences.thumbnailGridSpacingRange,
                step: 2
            ) { value in
                "\(Int(value)) pt"
            }
            SettingsSlider(
                "Side Margins",
                value: $preferences.thumbnailGridHorizontalMarginPercent,
                in: AppPreferences.thumbnailGridMarginPercentRange,
                step: 1,
                help: "Percentage of the viewer area left empty on each side of the page list. The number of columns is calculated from the remaining width, the thumbnail size, and the spacing."
            ) { value in
                "\(Int(value))%"
            }
            SettingsSlider(
                "Top and Bottom Margins",
                value: $preferences.thumbnailGridVerticalMarginPercent,
                in: AppPreferences.thumbnailGridMarginPercentRange,
                step: 1
            ) { value in
                "\(Int(value))%"
            }
            // ここから下がユーザー要望による追加分。
            SettingsPicker("Caption Under Each Thumbnail", selection: $preferences.thumbnailGridCaptionStyle)
            SettingsSlider(
                "Caption Size",
                value: $preferences.thumbnailGridCaptionFontSize,
                in: AppPreferences.thumbnailGridCaptionFontSizeRange,
                step: 1
            ) { value in
                "\(Int(value)) pt"
            }
            // キャプションを出さない設定のときは、大きさを決めても何も起きない。
            .disabled(preferences.thumbnailGridCaptionStyle == .none)
            SettingsPicker("Current Page Highlight", selection: borderColorSelection)
            // サムネイルにカーソルを合わせたときの拡大プレビュー。**この2つはページ一覧に
            // しか効かない**ため、環境設定「閲覧中の動作」の「サムネイルプレビュー」から
            // ここへ移した(ユーザーの指摘: あちらには4箇所すべてに効く「表示までの時間」も
            // 並んでいて、どれがどこに効くのか分からない)。あちらには共通の項目だけが残っている。
            //
            // サイドパネルのページモード・ブックマーク/レイアウトの編集・書き出しウインドウの
            // 同種のプレビューは、この設定に関わらず常に出る(ユーザー指示: あれらのサムネイルは
            // サイズ調整が無く、拡大が無いと何のページか分からなくなるため)。
            SettingsToggle(
                "Show a Larger Preview on Hover",
                isOn: $preferences.showThumbnailHoverPreview,
                help: "Applies to the page list only."
            )
            // 「表示中のサムネイルの拡大画像を先読み」は、メモリの使用量に直結する設定を
            // 1画面に集める方針(ユーザー要望)により「キャッシュ」画面へ移した
            // (CacheSettingsView参照。ページ一覧にしか効かない点は変わらない)。
            // ホイールのスクロール行数。見た目の設定ではないが、**ページ一覧パネルにしか
            // 効かない**のでここへ移した(ユーザーの指示。移す前は環境設定「閲覧中の動作」に
            // 「ページ一覧」という別のセクションとして置かれていた)。
            SettingsSlider(
                "Rows per Wheel Notch",
                value: $preferences.thumbnailGridWheelScrollRows,
                in: AppPreferences.thumbnailGridWheelScrollRowsRange,
                step: 0.1,
                help: "Applies to a physical mouse wheel only. Trackpad scrolling is unchanged.",
                showsStepper: true
            ) { value in
                // 0.1刻みなので、整数のときも「1.0」と書いて桁数を揃える
                // (ドラッグ中に小数点が出たり消えたりして行が揺れるのを防ぐ)。
                String(format: "%.1f", value)
            }
        } header: {
            Text("Page List")
        }
    }

    // MARK: - プログレスバーのフィルムストリップ

    /// プログレスバーにカーソルを合わせたときに出るフィルムストリップの見え方
    /// (ユーザー要望: グレーアウトの有無・文字の大きさ・枚数・強調の色と太さを選びたい)。
    ///
    /// 表示のON/OFF(「カーソルを合わせたページをプレビュー」)も、以前あった環境設定
    /// 「閲覧中の動作」からこのセクションへ移してある ―― ON/OFFだけ別の画面に残すと、
    /// ページ一覧の設定が2画面に分かれていたときとまったく同じ
    /// 「どれがどこに効くのか分からない」状態になるため。
    /// リセットの担当も一緒に移してある(AppPreferences.keys(for:)の.appearance参照。
    /// **画面の置き場所とkeys(for:)は必ず揃えること**)。
    ///
    /// OFFのときはサムネイル自体が出ないので、以下の項目は何も変えない。効かない設定を
    /// 触れるままにしておくと壊れているように見えるため、まとめて灰色にする
    /// (ページ一覧の「文字の大きさ」がキャプション無しのときに灰色になるのと同じ)。
    private var filmstripSection: some View {
        Section {
            SettingsToggle(
                "Preview the Page Under the Pointer",
                isOn: $preferences.showProgressBarThumbnailPreview,
                help: "When off, hovering over the progress bar shows just the page number under the pointer, and no thumbnails are loaded."
            )
            Group {
                SettingsSlider(
                    "Number of Thumbnails",
                    value: $preferences.filmstripThumbnailCount,
                    in: AppPreferences.filmstripThumbnailCountRange,
                    step: 1,
                    help: "The thumbnails always fill the width of the bar, so showing fewer of them makes each one larger."
                ) { value in
                    "\(Int(value))"
                }
                // ページ一覧の同名の設定と同じ意味・同じ名前(効く先だけが違う)。選択肢は
                // あちらより1つ多い ―― フィルムストリップは元々2行出しているため
                // (FilmstripCaptionStyle参照)。
                SettingsPicker(
                    "Caption Under Each Thumbnail",
                    selection: $preferences.filmstripCaptionStyle,
                    help: "The page number under the pointer is always shown. When file names are hidden, so is the location line above thumbnails that live in a folder inside the book."
                )
                // ページ一覧の同名の設定とまったく同じ意味(サムネイルに添える文字の大きさ)なので、
                // 同じ名前にしてある。効く先はこちらがフィルムストリップ、あちらがページ一覧。
                SettingsSlider(
                    "Caption Size",
                    value: $preferences.filmstripFontSize,
                    in: AppPreferences.filmstripFontSizeRange,
                    step: 1,
                    help: "Applies to the file name, the page number, and the location shown above thumbnails that live in a folder inside the book."
                ) { value in
                    "\(Int(value)) pt"
                }
                SettingsToggle(
                    "Dim the Other Pages",
                    isOn: $preferences.filmstripDimsOtherPages,
                    help: "Dimming every thumbnail except the one under the pointer makes that one stand out. Turn this off to see them all at full brightness — the one under the pointer is still marked by its border and page number."
                )
                SettingsPicker("Highlight Color", selection: filmstripHighlightColorSelection)
                SettingsSlider(
                    "Highlight Thickness",
                    value: $preferences.filmstripHighlightBorderWidth,
                    in: AppPreferences.filmstripHighlightBorderWidthRange,
                    step: 1,
                    help: "The thickness of the border around the thumbnail under the pointer."
                ) { value in
                    "\(Int(value)) pt"
                }
            }
            .disabled(!preferences.showProgressBarThumbnailPreview)
        } header: {
            // 見出しに「フィルムストリップ」は使わない ―― この機能を指す言葉として
            // ユーザーには通じない(ユーザーの指摘)。コード内のコメント・型名は開発者向けなので
            // 従来どおり「フィルムストリップ」のままにしてある。
            Text("Progress Bar Thumbnails")
        }
    }

    // MARK: - すりガラスの面

    /// 1つの面ぶんのセクション。すりガラスの4項目はどの面も共通で、`PanelSurface`から生成する。
    /// 自動的に隠れる3面(ツールバー・プログレスバー・サイドパネル)だけ、末尾に
    /// 「表示までの時間」が加わる(revealDelayBinding(for:)参照)。
    private func surfaceSection(_ surface: PanelSurface) -> some View {
        let style = preferences.surfaceStyleBinding(for: surface)
        return Section {
            SettingsSlider(
                "Frosted Glass",
                value: style.materialOpacity,
                in: 0...1,
                step: 0.05,
                help: "Lowering this makes the panel more see-through. At 0% the blur is gone entirely and only the color below is left."
            ) { value in
                "\(Int((value * 100).rounded()))%"
            }
            SettingsColorRow(
                "Panel Color",
                color: style.wrappedValue.tintColor.color,
                help: "The color only shows once Color Strength is above 0%. Picking a color while it is 0% raises it for you, so you can see what you chose."
            ) {
                colorTarget = .surfaceTint(surface)
            }
            SettingsSlider(
                "Color Strength",
                value: style.tintOpacity,
                in: 0...1,
                step: 0.05,
                help: "0% leaves the panel exactly as it looks by default. 100% fills it with the color, which hides the frosted glass completely."
            ) { value in
                "\(Int((value * 100).rounded()))%"
            }
            SettingsSlider(
                "Shadow Behind Text",
                value: contentShadowLevelBinding(style),
                in: Double(PanelContentShadow.range.lowerBound)...Double(PanelContentShadow.range.upperBound),
                step: 1,
                help: "Outlines the text and icons so they stay readable whatever is behind them — a dark panel color, or a page showing through. 1 is the tightest outline and 5 spreads the most."
            ) { value in
                PanelContentShadow.displayText(forLevel: Int(value.rounded()), locale: preferences.effectiveLocale)
            }
            // ウインドウの背後(デスクトップ/他のウインドウ)を透かすすりガラスのスイッチ
            // (ユーザー要望)。持つのは、隠していない状態を持つ3面とウェルカム画面だけ
            // (behindWindowGlassBinding(for:)参照)。**既定はOFF** ―― 従来からのユーザーが
            // 設定を変更しなければ見た目が変わらないようにするため(ユーザーの指定。
            // AppPreferences.toolbarDockedGlassのコメント参照)。
            if let glassEnabled = behindWindowGlassBinding(for: surface) {
                SettingsToggle(
                    "Show What’s Behind the Window",
                    isOn: glassEnabled,
                    help: surface == .welcome
                        ? "Other windows and the desktop show through the welcome screen faintly, following the settings above. When off, the welcome screen stays plain, as before."
                        : "Other windows and the desktop show through faintly while this part is set to always show, following the settings above. When off, the always-visible look stays as before. The floating version shown while hidden is unaffected."
                )
            }
            // 自動的に隠れる3面(ツールバー・プログレスバー・サイドパネル)にだけ、
            // 「隠しているとき、端にカーソルを近づけてから表示されるまでの待ち時間」を添える
            // (ユーザーの指示で、この面ごとのセクションへ統合した)。すりガラスの4項目と
            // 違って全面に共通ではないので、面ごとの分岐はrevealDelayBinding(for:)が持つ。
            if let revealDelay = revealDelayBinding(for: surface) {
                SettingsSlider(
                    "Delay Before Showing",
                    value: revealDelay,
                    in: AppPreferences.autoRevealDelayRange,
                    step: 0.1,
                    help: "How long the pointer has to stay near the window edge before this part appears while it is hidden. In full screen the toolbar and progress bar are always hidden, so it applies there too."
                ) { value in
                    String(format: "%.1f s", value)
                }
            }
        } header: {
            Text(surface.titleKey)
        }
    }

    /// 「表示までの時間」のBinding。自動的に隠れる面だけが持ち、それ以外はnil
    /// (ページ一覧パネルはキー/メニューで開閉するもので、浮かぶ表示は操作の結果として出る
    /// ものなので、どちらもカーソルを端へ近づけて出す仕組みを持たない)。
    private func revealDelayBinding(for surface: PanelSurface) -> Binding<Double>? {
        switch surface {
        case .toolbar: $preferences.toolbarRevealDelay
        case .progressBar: $preferences.progressBarRevealDelay
        case .sidePanel: $preferences.sidePanelRevealDelay
        case .pageList, .welcome, .overlays: nil
        }
    }

    /// 「ウインドウの背後を透かす」スイッチのBinding。隠していない(常に表示の)状態を
    /// 持つ3面と、ウェルカム画面だけが持つ。ページ一覧と浮かぶ表示は常にウインドウ内の
    /// 内容(ページ画像)の上に重なる面なので、背後のウインドウを透かす形は持たない。
    private func behindWindowGlassBinding(for surface: PanelSurface) -> Binding<Bool>? {
        switch surface {
        case .toolbar: $preferences.toolbarDockedGlass
        case .progressBar: $preferences.progressBarDockedGlass
        case .sidePanel: $preferences.sidePanelDockedGlass
        case .welcome: $preferences.welcomeGlass
        case .pageList, .overlays: nil
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

    /// 「表示中のページを示す枠の色」ポップアップ用のBinding(上とまったく同じ考え方)。
    private var borderColorSelection: Binding<PageBorderColorOption> {
        Binding(
            get: { preferences.thumbnailGridBorderColorOption },
            set: { newValue in
                let previous = preferences.thumbnailGridBorderColorOption
                preferences.thumbnailGridBorderColorOption = newValue
                guard newValue == .custom else { return }
                borderOptionBeforeCustomizing = previous
                colorTarget = .pageBorder
            }
        )
    }

    /// フィルムストリップの「カーソル位置の強調色」ポップアップ用のBinding(同上)。
    private var filmstripHighlightColorSelection: Binding<PageBorderColorOption> {
        Binding(
            get: { preferences.filmstripHighlightColorOption },
            set: { newValue in
                let previous = preferences.filmstripHighlightColorOption
                preferences.filmstripHighlightColorOption = newValue
                guard newValue == .custom else { return }
                filmstripHighlightOptionBeforeCustomizing = previous
                colorTarget = .filmstripHighlight
            }
        )
    }

    // MARK: - ダイアログの読み書き

    /// 影の段階(Int)を`SettingsSlider`が扱う`Double`に橋渡しする。段階そのものは整数で
    /// 持っている(`PanelSurfaceStyle.contentShadowLevel`)ので、ここで丸めて往復させる。
    private func contentShadowLevelBinding(_ style: Binding<PanelSurfaceStyle>) -> Binding<Double> {
        Binding(
            get: { Double(style.wrappedValue.contentShadowLevel) },
            set: { style.wrappedValue.contentShadowLevel = Int($0.rounded()) }
        )
    }

    private func currentColor(for target: ColorTarget) -> RGBColorValue {
        switch target {
        case .background: preferences.customBackgroundColor
        case .pageBorder: preferences.thumbnailGridBorderCustomColor
        case .filmstripHighlight: preferences.filmstripHighlightCustomColor
        case .surfaceTint(let surface): preferences.surfaceStyle(for: surface).tintColor
        }
    }

    private func commit(_ color: RGBColorValue, for target: ColorTarget) {
        switch target {
        case .background:
            // 背景色そのものは「カスタム」を選んだ時点で既に切り替わっている
            // (backgroundColorSelection参照)ので、ここでは色だけを保存する。
            preferences.customBackgroundColor = color
        case .pageBorder:
            preferences.thumbnailGridBorderCustomColor = color
        case .filmstripHighlight:
            preferences.filmstripHighlightCustomColor = color
        case .surfaceTint(let surface):
            var style = preferences.surfaceStyle(for: surface)
            style.tintColor = color
            // ユーザー報告: 色を変えても見た目が変わらない。
            //
            // 原因は不具合ではなく、この2段構えの分かりにくさだった。既定の「背景色の濃さ」は
            // 0%(=完全に透明)なので、**色を選んでも1ピクセルも変わらない**。保存も描画も
            // 正しく動いているのに、操作の結果が画面のどこにも現れないため、壊れているように見える。
            //
            // 色をわざわざ選ぶのは「その色にしたい」という明確な意思表示なので、濃さが
            // まだ0のときだけ、見える濃さまで上げる。すでに自分で濃さを決めている場合
            // (0より大きい)は、その値を尊重して触らない。上げすぎると今度は
            // すりガラスが完全に潰れてしまうため、控えめな値にしてある。
            if style.tintOpacity == 0 {
                style.tintOpacity = Self.tintOpacityWhenFirstColored
            }
            preferences.setSurfaceStyle(style, for: surface)
        }
    }

    /// キャンセルされたときの後始末。プリセットのポップアップから「カスタム」を選んで
    /// 開いた場合だけ、その選択自体を開く前の値へ戻す(「キャンセルしたのに色の種類だけ
    /// 変わってしまった」を防ぐため)。直前も「カスタム」だったなら、色だけが元のまま残る。
    ///
    /// 面の重ね色にはプリセットが無く、ダイアログを開くこと自体が設定を変えないので、
    /// 戻すものが無い。
    private func revert(_ target: ColorTarget) {
        switch target {
        case .background:
            if let previous = backgroundOptionBeforeCustomizing {
                preferences.backgroundColorOption = previous
            }
            backgroundOptionBeforeCustomizing = nil
        case .pageBorder:
            if let previous = borderOptionBeforeCustomizing {
                preferences.thumbnailGridBorderColorOption = previous
            }
            borderOptionBeforeCustomizing = nil
        case .filmstripHighlight:
            if let previous = filmstripHighlightOptionBeforeCustomizing {
                preferences.filmstripHighlightColorOption = previous
            }
            filmstripHighlightOptionBeforeCustomizing = nil
        case .surfaceTint:
            break
        }
    }
}

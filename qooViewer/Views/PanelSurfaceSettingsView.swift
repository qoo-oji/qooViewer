import SwiftUI

/// 環境設定「外観」から進む、すりガラスの面1つ分の子ページ。
///
/// 「外観」の面の一覧(AppearanceSettingsView.panelsSection)の行を押すか、ビューアの
/// 帯や枠を右クリック →「調整…」(PanelPartContextMenu)で開く。ウインドウのタイトルは
/// 面の名前になり、ツールバーの「戻る」で一覧へ戻る。
///
/// ■ 載っているもの
/// 1. 「背景」: すりガラスの4項目(濃さ・重ねる色・色の濃さ・文字の影)。どの面も共通で、
///    `PanelSurface`から機械的に組み立てる(面を足してもここは触らなくてよい)。
///    隠していない状態を持つ3面とウェルカム画面には「ウインドウの背後を透かす」、
///    自動的に隠れる3面には「表示までの時間」が末尾に加わる(面ごとの分岐は
///    behindWindowGlassBinding(for:) / revealDelayBinding(for:) が持つ)。
/// 2. その面だけが持つもの:
///    ・ページ一覧パネル → サムネイルの大きさ・間隔・余白・キャプション・枠の色・
///      ホバー拡大・ホイールのスクロール量(thumbnailGridSection)
///    ・プログレスバー → カーソルを合わせたときのサムネイル(filmstripSection)
///    1つのパネルの見た目を決める設定は必ず同じページに揃える、という「外観」の方針
///    (AppearanceSettingsView冒頭参照)に従って、ここに同居させている。以前は1枚の長い画面の
///    中で「ページ一覧」「プログレスバーのサムネイル」という独立したセクションだった。
///
/// ■ 「初期設定に戻す」は置かない
/// 「外観」の一覧ページ末尾のものが、全部の面の設定ごと戻す。面ごとに戻すボタンを
/// 足すと、同じ名前のボタンで戻る範囲が違うものが2つ並ぶことになる(SettingsResetSectionの
/// 「文言は全画面で同じ」の方針と噛み合わない)。
struct PanelSurfaceSettingsView: View {
    let surface: PanelSurface

    @EnvironmentObject private var preferences: AppPreferences
    /// 環境設定「表示言語」。ウインドウのタイトル(面の名前)を引くのに使う。
    @Environment(\.locale) private var locale

    /// 色の指定ダイアログの編集対象。`.sheet(item:)`へ渡すため`Identifiable`にしてある。
    private enum ColorTarget: Identifiable, Hashable {
        /// この面に重ねる色。プリセットを持たず、常にこのダイアログで決める。
        case surfaceTint
        /// ページ一覧で表示中のページを示す枠の色(「カスタム」を選んだとき)。
        case pageBorder
        /// プログレスバーのサムネイルで、カーソル位置のページを示す色(同上)。
        case filmstripHighlight

        var id: Self { self }

        var titleKey: LocalizedStringKey {
            switch self {
            case .surfaceTint: "Custom Panel Color"
            // 「表示中のページ」と「カーソル位置のページ」で指す対象は違うが、どちらも
            // 「サムネイル1枚を色で示す」ためのカスタム色なので、同じ見出しでよい。
            case .pageBorder, .filmstripHighlight: "Custom Highlight Color"
            }
        }
    }

    @State private var colorTarget: ColorTarget?
    /// 「カスタム」を選んでダイアログを開いた直前の選択。キャンセルされたら戻す(revert参照)。
    @State private var borderOptionBeforeCustomizing: PageBorderColorOption?
    @State private var filmstripHighlightOptionBeforeCustomizing: PageBorderColorOption?

    /// 濃さが0%のまま色を選んだときに、代わりに設定する濃さ(commitのコメント参照)。
    /// 選んだ色がはっきり分かり、かつすりガラスの質感も残る程度。
    private static let tintOpacityWhenFirstColored: Double = 0.25

    var body: some View {
        SettingsPaneContainer {
            backgroundSection
            switch surface {
            case .pageList: thumbnailGridSection
            case .progressBar: filmstripSection
            case .toolbar, .sidePanel, .welcome, .overlays: EmptyView()
            }
        }
        // 子ページの間はウインドウのタイトルを面の名前にする(一覧では「外観」)。
        // `Text(key)`ではなく表示言語で引いたStringを渡す(PanelSurface.titleValue参照)。
        .navigationTitle(surface.title(language: locale))
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

    // MARK: - 背景(すりガラス)

    private var backgroundSection: some View {
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
                colorTarget = .surfaceTint
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
            // (ユーザーの指示で、面ごとの設定へ統合した)。すりガラスの4項目と
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
            Text("Background")
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

    /// 影の段階(Int)を`SettingsSlider`が扱う`Double`に橋渡しする。段階そのものは整数で
    /// 持っている(`PanelSurfaceStyle.contentShadowLevel`)ので、ここで丸めて往復させる。
    private func contentShadowLevelBinding(_ style: Binding<PanelSurfaceStyle>) -> Binding<Double> {
        Binding(
            get: { Double(style.wrappedValue.contentShadowLevel) },
            set: { style.wrappedValue.contentShadowLevel = Int($0.rounded()) }
        )
    }

    // MARK: - ページ一覧のサムネイル

    private var thumbnailGridSection: some View {
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
            Text("Thumbnails")
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
            // ページの名前が「プログレスバー」なので、見出しは「サムネイル」だけでよい
            // (ページ一覧パネルのページのサムネイルのセクションと同じ見出し)。
            Text("Thumbnails")
        }
    }

    // MARK: - プリセット付きポップアップ

    /// 「表示中のページを示す枠の色」ポップアップ用のBinding。値を保存するだけでなく、
    /// 「カスタム」が選ばれたらその場で色の指定ダイアログを開く。
    ///
    /// `.onChange`ではなくBindingの`set`側で開いているのは、**既に「カスタム」が選ばれている
    /// 状態でもう一度「カスタム」を選び直したとき**にも開けるようにするため。`.onChange`は
    /// 値が変わったときにしか呼ばれないので、その場合に何も起きず、一度別のプリセットへ
    /// 逃げてから戻る以外に色を編集し直す方法が無くなってしまう。
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

    private func currentColor(for target: ColorTarget) -> RGBColorValue {
        switch target {
        case .surfaceTint: preferences.surfaceStyle(for: surface).tintColor
        case .pageBorder: preferences.thumbnailGridBorderCustomColor
        case .filmstripHighlight: preferences.filmstripHighlightCustomColor
        }
    }

    private func commit(_ color: RGBColorValue, for target: ColorTarget) {
        switch target {
        case .surfaceTint:
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
        case .pageBorder:
            preferences.thumbnailGridBorderCustomColor = color
        case .filmstripHighlight:
            preferences.filmstripHighlightCustomColor = color
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
        case .surfaceTint:
            break
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
        }
    }
}

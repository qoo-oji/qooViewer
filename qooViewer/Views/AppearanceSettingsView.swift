import SwiftUI

/// 環境設定ウインドウの「外観」画面。
///
/// ■ この画面が生まれた経緯
/// ユーザー要望: 「すりガラス」で描かれている面(ページ一覧パネル・ツールバー・
/// プログレスバー・サイドパネル)の背景色と透明度を、それぞれ個別に設定したい。加えて、
/// アプリの見た目に関する設定が複数のタブに散らばっていたので、この画面へ集約する。
///
/// 移してきたのは次の2つ。
///   ・ビューアの背景色(旧「画像の表示」)
///   ・ページ一覧の見え方すべて(旧「閲覧中の動作」のサイズ・間隔・余白)
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

    /// 色の指定ダイアログの編集対象。`.sheet(item:)`へ渡すため`Identifiable`にしてある。
    private enum ColorTarget: Identifiable, Hashable {
        /// ビューアの背景色(「カスタム」を選んだとき)。
        case background
        /// ページ一覧で表示中のページを示す枠の色(同上)。
        case pageBorder
        /// すりガラスの面に重ねる色。こちらはプリセットを持たず、常にこのダイアログで決める。
        case surfaceTint(PanelSurface)

        var id: String {
            switch self {
            case .background: "background"
            case .pageBorder: "pageBorder"
            case .surfaceTint(let surface): "surfaceTint.\(surface.rawValue)"
            }
        }

        var titleKey: LocalizedStringKey {
            switch self {
            case .background: "Custom Background Color"
            case .pageBorder: "Custom Highlight Color"
            case .surfaceTint: "Custom Panel Color"
            }
        }
    }

    var body: some View {
        SettingsPaneContainer {
            viewerSection
            pageListSection
            ForEach(PanelSurface.allCases) { surface in
                surfaceSection(surface)
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
        } header: {
            Text("Page List")
        }
    }

    // MARK: - すりガラスの面

    /// 1つの面ぶんのセクション。4面とも中身は同じ3項目で、`PanelSurface`から生成する。
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
            SettingsColorRow("Panel Color", color: style.wrappedValue.tintColor.color) {
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
        } header: {
            Text(surface.titleKey)
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

    // MARK: - ダイアログの読み書き

    private func currentColor(for target: ColorTarget) -> RGBColorValue {
        switch target {
        case .background: preferences.customBackgroundColor
        case .pageBorder: preferences.thumbnailGridBorderCustomColor
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
        case .surfaceTint(let surface):
            var style = preferences.surfaceStyle(for: surface)
            style.tintColor = color
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
        case .surfaceTint:
            break
        }
    }
}

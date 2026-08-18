import SwiftUI
import Foundation

/// 環境設定ウインドウの「画像の表示」画面。画像そのものの描画・表示のされ方に関する設定
/// (拡大率・補間品質・背景色・既定表示モード・見開き判定の閾値・先読み枚数)をまとめる。
struct RenderingSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var isShowingBackgroundColorPicker = false
    /// カスタム背景色のダイアログを開く直前に選ばれていた背景色。キャンセルされたときに
    /// ここへ戻す(「キャンセルしたのに背景色だけ変わってしまった」を防ぐため)。
    @State private var backgroundOptionBeforeCustomizing: BackgroundColorOption?

    var body: some View {
        SettingsPaneContainer {
            Section {
                SettingsPicker(
                    "Default Display Mode",
                    selection: $preferences.defaultScalingMode,
                    help: "Used the first time a book is opened. Changing it later affects only that book."
                )
                SettingsPicker("Background Color", selection: backgroundColorSelection)
                SettingsSlider(
                    "Maximum Upscale for Images Smaller Than the Window",
                    value: $preferences.maxUpscalePercent,
                    in: 100...800,
                    step: 10
                ) { value in
                    "\(Int(value))%"
                }
                SettingsSlider(
                    "Maximum Pinch Zoom on a Trackpad",
                    value: $preferences.maxPinchZoomPercent,
                    in: 100...800,
                    step: 10,
                    help: "100% turns pinch zoom off."
                ) { value in
                    "\(Int(value))%"
                }
            } header: {
                Text("Display")
            }

            Section {
                SettingsPicker(
                    "Interpolation Quality",
                    selection: $preferences.interpolationQuality
                )
            } header: {
                Text("Image Quality")
            }

            Section {
                // Sectionヘッダが「ルーペ」なので、ラベルで繰り返さない。
                // 説明文(「カーソルの下の画像をどれだけ拡大するか」)もラベルの言い換えでしかなく、
                // 読んでも何も増えないため落とした。
                SettingsSlider(
                    "Magnification",
                    value: $preferences.loupeMagnificationPercent,
                    in: 100...800,
                    step: 10
                ) { value in
                    "\(Int(value))%"
                }
                SettingsSlider(
                    "Diameter",
                    value: $preferences.loupeDiameter,
                    in: 200...600,
                    step: 10
                ) { value in
                    "\(Int(value))pt"
                }
            } header: {
                Text("Loupe")
            }

            Section {
                // 何と何の比なのかだけラベルへ引き上げ、判定の全文は吹き出しに残す
                // (「〜以上なら単ページ」という規則はラベルに収まらない)。
                SettingsSlider(
                    "Single-Page Threshold (Width ÷ Height)",
                    value: $preferences.singlePageAspectRatioThreshold,
                    in: 0.5...3.0,
                    step: 0.05,
                    help: "An image whose width ÷ height is at least this value is shown on its own instead of being paired into a spread."
                ) { value in
                    String(format: "%.2f", value)
                }
            } header: {
                Text("Spread Display")
            }

            Section {
                SettingsSlider(
                    "Pages to Preload on Each Side",
                    value: $preferences.prefetchPageCount,
                    in: 0...10,
                    step: 1,
                    help: "Higher values turn pages faster but use more memory."
                ) { value in
                    "\(Int(value))"
                }
            } header: {
                Text("Performance")
            }
        }
        // シートは行ではなく画面の土台側に付ける。Formのセクション内のViewに付けると、
        // 行のライフサイクル(スクロールによる再生成など)に表示状態が引きずられうるため。
        .sheet(isPresented: $isShowingBackgroundColorPicker) {
            BackgroundColorPickerSheet(
                initialColor: preferences.customBackgroundColor,
                onCommit: { chosen in
                    preferences.customBackgroundColor = chosen
                    // 背景色そのものは「カスタム」を選んだ時点で既に切り替わっている
                    // (backgroundColorSelection参照)ので、ここでは色だけを保存する。
                },
                onCancel: {
                    // 開く前の選択に戻す。「カスタム」を選んだこと自体を取り消す形になるので、
                    // 直前が黒ならそのまま黒に戻り、直前も「カスタム」なら色だけが元のまま残る。
                    if let previous = backgroundOptionBeforeCustomizing {
                        preferences.backgroundColorOption = previous
                    }
                }
            )
        }
    }

    /// 「背景色」ポップアップ用のBinding。値を保存するだけでなく、「カスタム」が選ばれたら
    /// その場でカスタム背景色のダイアログを開く。
    ///
    /// `.onChange`ではなくBindingの`set`側でダイアログを開いているのは、**既に「カスタム」が
    /// 選ばれている状態でもう一度「カスタム」を選び直したとき**にも開けるようにするため。
    /// `.onChange`は値が変わったときにしか呼ばれないので、その場合に何も起きず、
    /// 一度別のプリセットへ逃げてから戻る以外に色を編集し直す方法が無くなってしまう。
    private var backgroundColorSelection: Binding<BackgroundColorOption> {
        Binding(
            get: { preferences.backgroundColorOption },
            set: { newValue in
                let previous = preferences.backgroundColorOption
                preferences.backgroundColorOption = newValue
                guard newValue == .custom else { return }
                backgroundOptionBeforeCustomizing = previous
                isShowingBackgroundColorPicker = true
            }
        )
    }
}

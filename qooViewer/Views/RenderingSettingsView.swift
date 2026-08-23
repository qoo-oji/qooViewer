import SwiftUI
import Foundation

/// 環境設定ウインドウの「画像の表示」画面。画像そのものの描画・表示のされ方に関する設定
/// (拡大率・補間品質・既定表示モード・見開き判定の閾値・先読み枚数)をまとめる。
///
/// 背景色は、アプリの外観に関する設定を1画面へ集約する方針(ユーザー要望)により
/// 「外観」画面(AppearanceSettingsView)へ移した。背景色は「画像がどう描かれるか」ではなく
/// 「アプリがどう見えるか」の設定であり、ページ一覧パネルやサイドパネルの色と並べて
/// 見比べられるほうが決めやすいため。
struct RenderingSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        SettingsPaneContainer {
            Section {
                SettingsPicker(
                    "Default Display Mode",
                    selection: $preferences.defaultScalingMode,
                    help: "Used the first time a book is opened. Changing it later affects only that book."
                )
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

            // 「前後に先読みするページ数」は、メモリの使用量に直結する設定を1画面に集める方針
            // (ユーザー要望)により「キャッシュ」画面へ移した(CacheSettingsView参照)。
            SettingsResetSection(
                help: "Restores every setting on this page. Other pages, and your favorites, bookmarks and reading history, are not affected."
            ) {
                preferences.resetToDefaults(.rendering)
            }
        }
    }
}

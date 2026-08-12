import SwiftUI
import Foundation

/// 環境設定ウインドウの「描画」タブ。画像そのものの描画・表示のされ方に関する設定
/// (拡大率・補間品質・背景色・既定表示モード・見開き判定の閾値・先読み枚数)をまとめる。
struct RenderingSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        SettingsTabContainer {
            Section {
                SettingsPicker(
                    "Default Display Mode",
                    selection: $preferences.defaultScalingMode,
                    caption: "Used the first time a book is opened. Changing it later affects only that book."
                )
                SettingsPicker("Background Color", selection: $preferences.backgroundColorOption)
                SettingsSlider(
                    "Maximum Upscale",
                    value: $preferences.maxUpscalePercent,
                    in: 100...500,
                    step: 10,
                    caption: "Images smaller than the window are never enlarged beyond this percentage."
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
                SettingsSlider(
                    "Loupe Magnification",
                    value: $preferences.loupeMagnificationPercent,
                    in: 150...400,
                    step: 10,
                    caption: "How much the loupe enlarges the image under the cursor."
                ) { value in
                    "\(Int(value))%"
                }
                SettingsSlider(
                    "Loupe Size",
                    value: $preferences.loupeDiameter,
                    in: 200...600,
                    step: 10,
                    caption: "Diameter of the loupe."
                ) { value in
                    "\(Int(value))pt"
                }
            } header: {
                Text("Loupe")
            }

            Section {
                SettingsSlider(
                    "Single-Page Threshold",
                    value: $preferences.singlePageAspectRatioThreshold,
                    in: 0.5...3.0,
                    step: 0.05,
                    caption: "An image whose width ÷ height is at least this value is shown on its own instead of being paired into a spread."
                ) { value in
                    String(format: "%.2f", value)
                }
            } header: {
                Text("Spread Display")
            }

            Section {
                SettingsSlider(
                    "Pages to Preload",
                    value: $preferences.prefetchPageCount,
                    in: 0...10,
                    step: 1,
                    caption: "Decoded ahead on each side of the current page. Higher values turn pages faster but use more memory."
                ) { value in
                    "\(Int(value))"
                }
            } header: {
                Text("Performance")
            }
        }
    }
}

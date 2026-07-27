import SwiftUI
import Foundation

/// 環境設定ウインドウの「描画」タブ。画像そのものの描画・表示のされ方に関する設定
/// (拡大率・補間品質・背景色・既定表示モード・見開き判定の閾値・先読み枚数)をまとめる。
/// 以前はすべて「一般」タブに含まれていたが、項目が増えて長くなったため独立させた
/// (カーソル自動非表示やページ送り・スライドショーなど、描画そのものというより閲覧の
/// 挙動に関する設定はReadingSettingsView.swiftの「閲覧」タブへ移した)。
struct RenderingSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Display") {
                VStack(alignment: .leading) {
                    Text("Max Upscale: ") + Text("\(Int(preferences.maxUpscalePercent))") + Text("%")
                    Slider(value: $preferences.maxUpscalePercent, in: 100...500, step: 10)
                }

                Picker("Image Interpolation Quality", selection: $preferences.interpolationQuality) {
                    ForEach(InterpolationQuality.allCases) { quality in
                        Text(quality.titleKey).tag(quality)
                    }
                }

                Picker("Background Color", selection: $preferences.backgroundColorOption) {
                    ForEach(BackgroundColorOption.allCases) { option in
                        Text(option.titleKey).tag(option)
                    }
                }

                Picker("Default Display Mode for New Books", selection: $preferences.defaultScalingMode) {
                    ForEach(ScalingMode.allCases) { mode in
                        Text(mode.titleKey).tag(mode)
                    }
                }
            }

            Section("Spread Display") {
                VStack(alignment: .leading) {
                    Text("Threshold for Single-Page Wide Images (Width ÷ Height): ") + Text("\(String(format: "%.2f", preferences.singlePageAspectRatioThreshold))")
                    Slider(value: $preferences.singlePageAspectRatioThreshold, in: 0.5...3.0, step: 0.05)
                }
            }

            Section("Performance") {
                VStack(alignment: .leading) {
                    Text("Pages to Preload (each side: ") + Text("\(Int(preferences.prefetchPageCount))") + Text(" pages)")
                    Slider(value: $preferences.prefetchPageCount, in: 0...10, step: 1)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

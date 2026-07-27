import SwiftUI
import Foundation

/// 環境設定ウインドウの「閲覧」タブ。ページ送り・スライドショー・マウスカーソルの
/// 自動非表示など、画像そのものの描画内容ではなく閲覧中の操作・挙動に関する設定をまとめる。
/// 画像の拡大率や補間品質など、描画そのものに関する設定はRenderingSettingsView.swiftの
/// 「描画」タブへ分離した(以前はどちらも「一般」タブに含まれていたが、項目が増えて
/// 長くなったため独立させた)。
struct ReadingSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Page Turning") {
                Picker("Behavior at the first/last page", selection: $preferences.loopBehavior) {
                    ForEach(LoopBehavior.allCases) { behavior in
                        Text(behavior.titleKey).tag(behavior)
                    }
                }
                Toggle("Turn pages using trackpad flicks", isOn: $preferences.treatTrackpadFlickAsWheel)
            }

            Section("Progress Bar") {
                Toggle(
                    "Show Thumbnail Preview When Hovering the Progress Bar",
                    isOn: $preferences.showProgressBarThumbnailPreview
                )
            }

            Section("Slideshow") {
                VStack(alignment: .leading) {
                    Text("Interval: ") + Text("\(Int(preferences.slideshowInterval))") + Text(" sec")
                    Slider(value: $preferences.slideshowInterval, in: 1...30, step: 1)
                }
            }

            Section("Cursor") {
                Toggle("Automatically hide the mouse cursor after inactivity", isOn: $preferences.autoHideCursor)
                VStack(alignment: .leading) {
                    Text("Time Until Hidden: ") + Text("\(String(format: "%.1f", preferences.cursorAutoHideDelay))") + Text(" sec")
                    Slider(value: $preferences.cursorAutoHideDelay, in: 0.5...10, step: 0.5)
                }
                .disabled(!preferences.autoHideCursor)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

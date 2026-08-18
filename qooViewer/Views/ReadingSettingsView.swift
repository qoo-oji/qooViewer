import SwiftUI
import Foundation

/// 環境設定ウインドウの「閲覧中の動作」画面。ページ送り・スライドショー・マウスカーソルの
/// 自動非表示など、画像そのものの描画内容ではなく閲覧中の操作・挙動に関する設定をまとめる。
struct ReadingSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        SettingsPaneContainer {
            Section {
                // 説明文は「最初/最後のページで」というラベルの言い換えだったので落とした。
                SettingsPicker("At the First/Last Page", selection: $preferences.loopBehavior)
                SettingsToggle(
                    "Trackpad Flicks Turn Pages",
                    isOn: $preferences.treatTrackpadFlickAsWheel
                )
            } header: {
                Text("Page Turning")
            }

            Section {
                SettingsToggle(
                    "Invert Two-Finger Scrolling",
                    isOn: $preferences.invertTwoFingerScrolling,
                    help: "Reverses the direction the image moves — both vertically and horizontally — when you scroll with two fingers on a trackpad. The mouse wheel is not affected, and neither are the actions assigned to wheel or flick directions."
                )
            } header: {
                Text("Scrolling")
            }

            Section {
                // Sectionヘッダが「プログレスバー」なので、「プログレスバーにカーソルを
                // 合わせたとき」は繰り返さずに済む。
                SettingsToggle(
                    "Preview the Page Under the Pointer",
                    isOn: $preferences.showProgressBarThumbnailPreview
                )
            } header: {
                Text("Progress Bar")
            }

            Section {
                SettingsSlider(
                    "Interval",
                    value: $preferences.slideshowInterval,
                    in: 1...30,
                    step: 1
                ) { value in
                    "\(Int(value)) s"
                }
            } header: {
                Text("Slideshow")
            }

            Section {
                // 「自動的に」が何を指すのか(=動かしていないあいだ)をラベルへ入れて、
                // 言い換えでしかなかった説明文を無くした。
                SettingsToggle(
                    "Hide the Pointer While You Are Not Moving It",
                    isOn: $preferences.autoHideCursor
                )
                SettingsSlider(
                    "Delay Before Hiding",
                    value: $preferences.cursorAutoHideDelay,
                    in: 0.5...10,
                    step: 0.5
                ) { value in
                    String(format: "%.1f s", value)
                }
                .disabled(!preferences.autoHideCursor)
            } header: {
                Text("Pointer")
            }
        }
    }
}

import SwiftUI
import Foundation

/// 環境設定ウインドウの「閲覧」タブ。ページ送り・スライドショー・マウスカーソルの
/// 自動非表示など、画像そのものの描画内容ではなく閲覧中の操作・挙動に関する設定をまとめる。
struct ReadingSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        SettingsTabContainer {
            Section {
                SettingsPicker(
                    "At the First/Last Page",
                    selection: $preferences.loopBehavior,
                    caption: "What happens when you try to turn past the beginning or the end of a book."
                )
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
                    caption: "Reverses the direction the image moves — both vertically and horizontally — when you scroll with two fingers on a trackpad. The mouse wheel is not affected, and neither are the actions assigned to wheel or flick directions."
                )
            } header: {
                Text("Scrolling")
            }

            Section {
                SettingsToggle(
                    "Thumbnail Preview",
                    isOn: $preferences.showProgressBarThumbnailPreview,
                    caption: "Shows a preview of the page under the pointer while hovering the progress bar."
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
                SettingsToggle(
                    "Hide the Pointer Automatically",
                    isOn: $preferences.autoHideCursor,
                    caption: "Hides the mouse pointer while you are not moving it."
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

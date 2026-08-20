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

            // ページ一覧(サムネイルグリッド)。ユーザー要望: サイズ・間隔・余白を調整したい。
            // サイズはパネル上部のスライダーと同じ値(その場で変えたいときはそちら)。
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
            } header: {
                Text("Page List")
            }

            // サムネイルのホバー拡大プレビュー(ページ一覧・サイドパネル・ブックマーク編集・
            // 書き出しウインドウ共通)。ユーザー要望: 出るまでを速くしたい/出ないようにしたい。
            Section {
                // ON/OFFはページ一覧だけ(ユーザー指示: サイドパネルやブックマーク編集のサムネイルは
                // サイズ調整が無く、拡大が無いと何のページか分からなくなる)。遅延は全箇所共通。
                SettingsToggle(
                    "Show a Larger Preview on Hover",
                    isOn: $preferences.showThumbnailHoverPreview,
                    help: "Applies to the page list only."
                )
                SettingsSlider(
                    "Delay Before Showing",
                    value: $preferences.thumbnailHoverPreviewDelay,
                    in: AppPreferences.thumbnailHoverPreviewDelayRange,
                    step: 0.05,
                    help: "Applies to thumbnails in the page list, the side panel's page mode, the bookmark editor, and the export windows."
                ) { value in
                    String(format: "%.2f s", value)
                }
                SettingsToggle(
                    "Preload Previews for Visible Thumbnails",
                    isOn: $preferences.preloadThumbnailGridPreviews,
                    help: "In the page list, decodes the full-size image of every thumbnail on screen in advance so the preview appears immediately. Uses more memory and CPU."
                )
                .disabled(!preferences.showThumbnailHoverPreview)
            } header: {
                Text("Thumbnail Preview")
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

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

            // ページ一覧(サムネイルグリッド)の**見た目**(サムネイルの大きさ・間隔・余白・
            // キャプション・枠の色)は「外観」画面へ移した(ユーザー要望: アプリの外観に
            // 関するものは1画面へ集約する)。ここに残しているのは、見た目ではなく
            // 「操作にどう応じるか」の設定だけ。
            Section {
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
                // ユーザー要望: 特に10秒未満のときに0.1秒単位で詰めたい。
                // 0.1秒刻みだとスライダーの1ステップが1pt未満になり、ドラッグでは狙った値に
                // 止められないため、ステッパーを添えてある(SettingsSlider.showsStepper参照)。
                // 下限を1秒から0.5秒へ下げたのは、0.1秒単位で詰めたいのは短い側だという
                // 要望の趣旨に沿わせるため。
                //
                // スライダー本体だけ0.5秒刻みにしている。`Slider`は刻みの数だけ目盛りを描くので、
                // 0.1秒刻みのままだと295本が潰れて**1本の直線に見えていた**(ユーザー報告)。
                // ドラッグで0.1秒を狙えないのは元々承知の上でステッパーを添えているので、
                // 目盛りは読み取れる粗さにして、細かい調整はステッパーへ任せる。
                SettingsSlider(
                    "Interval",
                    value: $preferences.slideshowInterval,
                    in: 0.5...30,
                    step: 0.1,
                    showsStepper: true,
                    sliderStep: 0.5
                ) { value in
                    String(format: "%.1f s", value)
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

            SettingsResetSection(
                help: "Restores every setting on this page. Other pages, and your favorites, bookmarks and reading history, are not affected."
            ) {
                preferences.resetToDefaults(.reading)
            }
        }
    }
}
